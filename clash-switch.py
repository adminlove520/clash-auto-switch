#!/usr/bin/env python3
"""
Clash Auto Switch - 跨平台版本 (v2.0)
支持: Linux, macOS, Windows
优化: 并发测试、重试机制、JSON 输出、龙虾集成
"""

import os
import sys
import json
import time
import argparse
import logging
from typing import List, Dict, Any, Optional, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, asdict

try:
    import requests
except ImportError:
    print("请安装 requests: pip install requests")
    sys.exit(1)

# 日志配置
logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(asctime)s %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("clash-switch")


@dataclass
class NodeResult:
    """节点测试结果"""
    name: str
    delay: int
    region: str = ""
    is_preferred: bool = False
    is_alive: bool = False


@dataclass
class SwitchResult:
    """切换操作结果"""
    success: bool
    message: str
    health_rate: int = 0
    current_node: str = ""
    switched_to: str = ""
    delay_ms: int = 0
    details: Dict = None

    def to_json(self) -> str:
        d = asdict(self)
        if d["details"] is None:
            d["details"] = {}
        return json.dumps(d, ensure_ascii=False, indent=2)


# 区域识别映射
REGION_KEYWORDS = {
    "sg": ["新加坡", "🇸🇬", "SG", "Singapore"],
    "hk": ["香港", "🇭🇰", "HK", "Hong Kong"],
    "jp": ["日本", "🇯🇵", "JP", "Japan", "Tokyo"],
    "us": ["美国", "🇺🇲", "US", "USA", "LA", "Los Angeles", "San Jose"],
    "tw": ["台湾", "🇹🇼", "TW", "Taiwan"],
    "kr": ["韩国", "🇰🇷", "KR", "Korea"],
    "uk": ["英国", "🇬🇧", "UK", "London"],
    "de": ["德国", "🇩🇪", "DE", "Germany", "Frankfurt"],
}

DEFAULT_PREFERRED = ["sg", "hk", "jp", "us"]

DEFAULT_TEST_TARGETS = [
    "https://api.telegram.org",
    "https://api.anthropic.com",
    "https://www.google.com",
]

# 需要跳过的系统节点
SKIP_NODES = {"DIRECT", "REJECT", "GLOBAL", "PROXY", "节点选择", "故障转移", "自动选择", "负载均衡"}


class ClashAutoSwitch:
    """Clash 代理自动切换工具 (v2.0)"""

    def __init__(
        self,
        api_url: str = None,
        secret: str = None,
        proxy_url: str = None,
        max_workers: int = 8,
        timeout: int = 10,
        retry: int = 2,
    ):
        self.api_url = (api_url or os.environ.get("CLASH_API", "http://127.0.0.1:58871")).rstrip("/")
        self.secret = secret or os.environ.get("CLASH_SECRET", "")
        self.proxy_url = proxy_url or os.environ.get("CLASH_PROXY", "http://127.0.0.1:7890")
        self.max_workers = max_workers
        self.timeout = timeout
        self.retry = retry

        if not self.secret:
            raise ValueError("请提供 CLASH_SECRET 环境变量或 --secret 参数")

        self.headers = {"Authorization": f"Bearer {self.secret}"}

    # ==================== API 层 ====================

    def _request(self, method: str, endpoint: str, **kwargs) -> Optional[Any]:
        """发送 API 请求，含重试"""
        url = f"{self.api_url}{endpoint}"
        for attempt in range(self.retry + 1):
            try:
                r = requests.request(
                    method.upper(), url,
                    headers=self.headers,
                    timeout=self.timeout,
                    **kwargs,
                )
                if r.status_code == 204:
                    return {}
                if r.status_code == 200:
                    return r.json()
                logger.warning(f"API {endpoint} 返回 {r.status_code} (尝试 {attempt+1})")
            except requests.exceptions.Timeout:
                logger.warning(f"API {endpoint} 超时 (尝试 {attempt+1})")
            except requests.exceptions.ConnectionError:
                logger.error(f"无法连接到 Clash API: {self.api_url}")
                return None
            except Exception as e:
                logger.error(f"API 请求异常: {e}")
                return None
        return None

    def get_proxies(self) -> Dict[str, Any]:
        """获取所有代理"""
        return self._request("GET", "/proxies") or {}

    def get_proxy_group(self, name: str) -> Dict[str, Any]:
        """获取代理组详情"""
        encoded = requests.utils.quote(name)
        return self._request("GET", f"/proxies/{encoded}") or {}

    def set_proxy(self, group: str, node: str) -> bool:
        """切换节点"""
        encoded = requests.utils.quote(group)
        result = self._request("PUT", f"/proxies/{encoded}", json={"name": node})
        return result is not None

    def test_delay(self, node: str, test_url: str = "http://www.gstatic.com/generate_204") -> int:
        """测试节点延迟"""
        encoded = requests.utils.quote(node)
        url = f"{self.api_url}/proxies/{encoded}/delay?timeout=5000&url={test_url}"
        try:
            r = requests.get(url, headers=self.headers, timeout=self.timeout)
            data = r.json()
            delay = data.get("delay", 0)
            return delay if delay and delay > 0 else 99999
        except Exception:
            return 99999

    # ==================== 健康检查 ====================

    def health_check(self, targets: List[str] = None) -> Tuple[int, int, List[Dict]]:
        """健康检查，返回 (成功数, 总数, 详情)"""
        targets = targets or DEFAULT_TEST_TARGETS
        proxies = {"http": self.proxy_url, "https": self.proxy_url}
        details = []

        for target in targets:
            try:
                start = time.time()
                r = requests.get(target, proxies=proxies, timeout=8, verify=False)
                elapsed = int((time.time() - start) * 1000)
                ok = r.status_code < 500
                details.append({"target": target, "ok": ok, "status": r.status_code, "ms": elapsed})
            except Exception as e:
                details.append({"target": target, "ok": False, "error": str(type(e).__name__)})

        success = sum(1 for d in details if d.get("ok"))
        return success, len(targets), details

    # ==================== 节点发现 ====================

    @staticmethod
    def detect_region(node_name: str) -> str:
        """识别节点所属区域"""
        lower = node_name.lower()
        for region_code, keywords in REGION_KEYWORDS.items():
            for kw in keywords:
                if kw.lower() in lower:
                    return region_code
        return "unknown"

    def _is_real_node(self, name: str) -> bool:
        """判断是否为真实节点（排除组名、系统节点）"""
        return name not in SKIP_NODES and not any(c in name for c in "♻️🔰⚓️✈️🎬🎮🍎🎨❗🚀")

    def list_groups(self) -> Dict[str, Dict]:
        """列出所有代理组 (Selector 类型)"""
        data = self.get_proxies()
        groups = {}
        for name, info in data.get("proxies", {}).items():
            if info.get("type") == "Selector":
                groups[name] = {
                    "current": info.get("now", "未知"),
                    "all": [n for n in info.get("all", []) if self._is_real_node(n)],
                    "type": info.get("type"),
                }
        return groups

    def test_nodes_concurrent(self, nodes: List[str]) -> List[NodeResult]:
        """并发测试多个节点延迟"""
        results = []

        def _test(node):
            delay = self.test_delay(node)
            region = self.detect_region(node)
            return NodeResult(
                name=node,
                delay=delay,
                region=region,
                is_preferred=region in DEFAULT_PREFERRED,
                is_alive=delay < 5000,
            )

        with ThreadPoolExecutor(max_workers=self.max_workers) as pool:
            futures = {pool.submit(_test, n): n for n in nodes}
            for future in as_completed(futures):
                try:
                    results.append(future.result())
                except Exception:
                    node = futures[future]
                    results.append(NodeResult(name=node, delay=99999))

        return sorted(results, key=lambda r: (not r.is_preferred, r.delay))

    # ==================== 自动切换 ====================

    def find_best_node(self, region_filter: List[str] = None) -> Tuple[Optional[str], Optional[str], int]:
        """找最佳节点，可按区域筛选"""
        best_node = None
        best_group = None
        best_delay = 99999

        groups = self.list_groups()
        for group_name, group_info in groups.items():
            nodes = group_info["all"]
            if not nodes:
                continue

            tested = self.test_nodes_concurrent(nodes)

            for result in tested:
                if not result.is_alive:
                    continue
                # 如果指定了区域筛选
                if region_filter and result.region not in region_filter:
                    continue
                if result.delay < best_delay:
                    best_node = result.name
                    best_group = group_name
                    best_delay = result.delay

        return best_node, best_group, best_delay

    def auto_switch(self, region_filter: List[str] = None) -> SwitchResult:
        """自动切换到最佳节点"""
        # 1. 健康检查
        success, total, details = self.health_check()
        rate = success * 100 // total if total > 0 else 0

        if rate >= 60:
            groups = self.list_groups()
            current = next((g["current"] for g in groups.values()), "未知")
            return SwitchResult(
                success=True,
                message=f"代理健康 ({success}/{total})，无需切换",
                health_rate=rate,
                current_node=current,
                details={"health": details},
            )

        # 2. 找最佳节点
        logger.info("代理不健康，正在寻找最佳节点...")
        node, group, delay = self.find_best_node(region_filter)

        if not node:
            return SwitchResult(
                success=False,
                message="未找到可用节点",
                health_rate=rate,
                details={"health": details},
            )

        # 3. 切换
        if self.set_proxy(group, node):
            time.sleep(2)
            s2, t2, d2 = self.health_check()
            new_rate = s2 * 100 // t2 if t2 > 0 else 0
            return SwitchResult(
                success=True,
                message=f"已切换 {group} -> {node} ({delay}ms)，新健康度 {new_rate}%",
                health_rate=new_rate,
                current_node=node,
                switched_to=node,
                delay_ms=delay,
                details={"health_before": details, "health_after": d2},
            )

        return SwitchResult(
            success=False,
            message=f"切换 {group} -> {node} 失败",
            health_rate=rate,
        )

    # ==================== 状态查询 ====================

    def status(self) -> Dict:
        """获取完整状态信息"""
        success, total, health_details = self.health_check()
        groups = self.list_groups()
        rate = success * 100 // total if total > 0 else 0

        return {
            "healthy": rate >= 60,
            "health_rate": rate,
            "health_details": health_details,
            "groups": {
                name: {
                    "current": info["current"],
                    "node_count": len(info["all"]),
                    "region": self.detect_region(info["current"]),
                }
                for name, info in groups.items()
            },
            "api_url": self.api_url,
            "proxy_url": self.proxy_url,
        }


# ==================== CLI ====================

def main():
    parser = argparse.ArgumentParser(
        description="Clash Auto Switch v2.0 - 代理节点智能切换工具",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python clash-switch.py --health               # 健康检查
  python clash-switch.py --list                  # 列出代理组
  python clash-switch.py --auto                  # 自动切换
  python clash-switch.py --status                # 完整状态
  python clash-switch.py --switch ChatGPT 节点名 # 手动切换
  python clash-switch.py --sg                    # 切换到新加坡
  python clash-switch.py --json --auto           # JSON 输出 (适合龙虾调用)
        """,
    )
    parser.add_argument("--api", "-a", default=None, help="Clash API 地址")
    parser.add_argument("--secret", "-s", default=None, help="API 密钥")
    parser.add_argument("--proxy", "-p", default=None, help="代理地址")
    parser.add_argument("--list", "-l", action="store_true", help="列出所有代理组")
    parser.add_argument("--health", action="store_true", help="健康检查")
    parser.add_argument("--auto", action="store_true", help="自动切换")
    parser.add_argument("--status", action="store_true", help="完整状态")
    parser.add_argument("--switch", nargs=2, metavar=("GROUP", "NODE"), help="切换到指定节点")
    parser.add_argument("--sg", action="store_true", help="切换到新加坡")
    parser.add_argument("--us", action="store_true", help="切换到美国")
    parser.add_argument("--jp", action="store_true", help="切换到日本")
    parser.add_argument("--hk", action="store_true", help="切换到香港")
    parser.add_argument("--tw", action="store_true", help="切换到台湾")
    parser.add_argument("--kr", action="store_true", help="切换到韩国")
    parser.add_argument("--json", action="store_true", help="JSON 格式输出 (适合程序调用)")
    parser.add_argument("--workers", type=int, default=8, help="并发测试线程数")

    args = parser.parse_args()

    try:
        clash = ClashAutoSwitch(
            api_url=args.api, secret=args.secret, proxy_url=args.proxy,
            max_workers=args.workers,
        )
    except ValueError as e:
        print(f"错误: {e}")
        sys.exit(1)

    output_json = args.json

    if args.health:
        success, total, details = clash.health_check()
        rate = success * 100 // total if total > 0 else 0
        if output_json:
            print(json.dumps({"healthy": rate >= 60, "rate": rate, "details": details}, ensure_ascii=False, indent=2))
        else:
            icon = "✓" if rate >= 60 else "✗"
            print(f"{icon} 健康度: {success}/{total} ({rate}%)")
            for d in details:
                status = "✓" if d.get("ok") else "✗"
                print(f"  {status} {d['target']}: {d.get('ms', 'N/A')}ms")

    elif args.list:
        groups = clash.list_groups()
        if output_json:
            print(json.dumps(groups, ensure_ascii=False, indent=2))
        else:
            print("========== 代理组 ==========")
            for name, info in groups.items():
                region = clash.detect_region(info["current"])
                print(f"  {name}: {info['current']} [{region}] ({len(info['all'])} 节点)")

    elif args.status:
        status = clash.status()
        if output_json:
            print(json.dumps(status, ensure_ascii=False, indent=2))
        else:
            icon = "✓" if status["healthy"] else "✗"
            print(f"{icon} 健康度: {status['health_rate']}%")
            print(f"\n代理组:")
            for name, info in status["groups"].items():
                print(f"  {name}: {info['current']} [{info['region']}] ({info['node_count']} 节点)")

    elif args.auto:
        result = clash.auto_switch()
        if output_json:
            print(result.to_json())
        else:
            icon = "✓" if result.success else "✗"
            print(f"{icon} {result.message}")

    elif args.switch:
        group, node = args.switch
        ok = clash.set_proxy(group, node)
        if output_json:
            print(json.dumps({"success": ok, "group": group, "node": node}, ensure_ascii=False))
        else:
            print(f"{'✓' if ok else '✗'} {'已切换' if ok else '切换失败'} {group} -> {node}")

    elif any([args.sg, args.us, args.jp, args.hk, args.tw, args.kr]):
        region_map = {"sg": args.sg, "us": args.us, "jp": args.jp, "hk": args.hk, "tw": args.tw, "kr": args.kr}
        selected = [r for r, v in region_map.items() if v]
        result = clash.auto_switch(region_filter=selected)
        if output_json:
            print(result.to_json())
        else:
            icon = "✓" if result.success else "✗"
            print(f"{icon} {result.message}")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
