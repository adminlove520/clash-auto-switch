#!/usr/bin/env python3
"""
Clash Auto Switch - OpenClaw Skill 实现 (v2.0)
优化: 并发测试、重试、JSON 输出、龙虾集成
"""

import json
import os
import sys
import argparse
import time
import logging
from typing import Optional, Dict, List, Tuple
from concurrent.futures import ThreadPoolExecutor, as_completed

try:
    import requests
except ImportError:
    print("请安装 requests: pip install requests")
    sys.exit(1)

logger = logging.getLogger("clash-skill")

# 区域识别映射
REGION_KEYWORDS = {
    "sg": ["新加坡", "🇸🇬", "SG", "Singapore"],
    "hk": ["香港", "🇭🇰", "HK", "Hong Kong"],
    "jp": ["日本", "🇯🇵", "JP", "Japan", "Tokyo"],
    "us": ["美国", "🇺🇲", "US", "USA", "LA"],
    "tw": ["台湾", "🇹🇼", "TW", "Taiwan"],
    "kr": ["韩国", "🇰🇷", "KR", "Korea"],
}
SKIP_NODES = {"DIRECT", "REJECT", "GLOBAL", "PROXY", "节点选择", "故障转移", "自动选择", "负载均衡"}


class ClashAutoSwitch:
    """Clash 代理自动切换工具 (Skill v2.0)"""

    def __init__(self, api_url: str = None, secret: str = None, proxy_url: str = None):
        self.api_url = (api_url or os.environ.get("CLASH_API", "http://127.0.0.1:58871")).rstrip("/")
        self.secret = secret or os.environ.get("CLASH_SECRET", "")
        self.proxy_url = proxy_url or os.environ.get("CLASH_PROXY", "http://127.0.0.1:7890")

        if not self.secret:
            raise ValueError("请设置 CLASH_SECRET 环境变量或提供 --secret 参数")

        self.headers = {"Authorization": f"Bearer {self.secret}"}

    def _request(self, method: str, endpoint: str, **kwargs) -> Optional[Dict]:
        """发送 API 请求 (含重试)"""
        url = f"{self.api_url}{endpoint}"
        for attempt in range(3):
            try:
                r = requests.request(method.upper(), url, headers=self.headers, timeout=10, **kwargs)
                if r.status_code == 204:
                    return {}
                if r.status_code == 200:
                    return r.json()
            except requests.exceptions.ConnectionError:
                return None
            except Exception:
                pass
        return None

    def get_proxies(self) -> Dict:
        return self._request("GET", "/proxies") or {}

    def get_proxy_group(self, name: str) -> Dict:
        encoded = requests.utils.quote(name)
        return self._request("GET", f"/proxies/{encoded}") or {}

    def set_proxy(self, group: str, node: str) -> bool:
        encoded = requests.utils.quote(group)
        result = self._request("PUT", f"/proxies/{encoded}", json={"name": node})
        return result is not None

    def test_delay(self, node: str) -> int:
        encoded = requests.utils.quote(node)
        url = f"{self.api_url}/proxies/{encoded}/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
        try:
            r = requests.get(url, headers=self.headers, timeout=10)
            delay = r.json().get("delay", 0)
            return delay if delay and delay > 0 else 99999
        except Exception:
            return 99999

    @staticmethod
    def detect_region(node_name: str) -> str:
        lower = node_name.lower()
        for code, keywords in REGION_KEYWORDS.items():
            for kw in keywords:
                if kw.lower() in lower:
                    return code
        return "unknown"

    def _is_real_node(self, name: str) -> bool:
        return name not in SKIP_NODES and not any(c in name for c in "♻️🔰⚓️✈️🎬🎮🍎🎨❗🚀")

    def health_check(self, targets: List[str] = None) -> Tuple[int, int, List[Dict]]:
        if targets is None:
            targets = [
                "https://api.telegram.org",
                "https://api.anthropic.com",
                "https://www.google.com",
            ]
        proxies = {"http": self.proxy_url, "https": self.proxy_url}
        details = []
        for target in targets:
            try:
                start = time.time()
                r = requests.get(target, proxies=proxies, timeout=8, verify=False)
                ms = int((time.time() - start) * 1000)
                ok = r.status_code < 500
                details.append({"target": target, "ok": ok, "ms": ms})
            except Exception as e:
                details.append({"target": target, "ok": False, "error": type(e).__name__})
        success = sum(1 for d in details if d.get("ok"))
        return success, len(targets), details

    def list_groups(self) -> Dict[str, Dict]:
        data = self.get_proxies()
        groups = {}
        for name, info in data.get("proxies", {}).items():
            if info.get("type") == "Selector":
                groups[name] = {
                    "current": info.get("now", "未知"),
                    "all": [n for n in info.get("all", []) if self._is_real_node(n)],
                }
        return groups

    def find_best_node(self, region_filter: List[str] = None) -> Tuple[Optional[str], Optional[str], int]:
        preferred = region_filter or ["sg", "hk", "jp", "us"]
        best_node = None
        best_group = None
        best_delay = 99999

        groups = self.list_groups()
        for group_name, group_info in groups.items():
            nodes = group_info["all"]
            if not nodes:
                continue
            # 并发测试
            results = []
            with ThreadPoolExecutor(max_workers=8) as pool:
                futures = {pool.submit(self.test_delay, n): n for n in nodes}
                for f in as_completed(futures):
                    node = futures[f]
                    try:
                        delay = f.result()
                    except Exception:
                        delay = 99999
                    region = self.detect_region(node)
                    is_match = region in preferred
                    results.append((node, delay, is_match))

            # 优先匹配区域
            for node, delay, is_match in sorted(results, key=lambda x: (not x[2], x[1])):
                if region_filter and not is_match:
                    continue
                if delay < best_delay and delay < 5000:
                    best_node = node
                    best_group = group_name
                    best_delay = delay

        return best_node, best_group, best_delay

    def auto_switch(self, region_filter: List[str] = None) -> Dict:
        """自动切换，返回结构化结果 (方便龙虾调用)"""
        success, total, details = self.health_check()
        rate = success * 100 // total if total > 0 else 0

        if rate >= 60:
            groups = self.list_groups()
            current = next((g["current"] for g in groups.values()), "未知")
            return {
                "success": True,
                "message": f"代理健康 ({success}/{total})，无需切换",
                "health_rate": rate,
                "current_node": current,
            }

        node, group, delay = self.find_best_node(region_filter)
        if node and group:
            self.set_proxy(group, node)
            time.sleep(2)
            s2, t2, _ = self.health_check()
            new_rate = s2 * 100 // t2 if t2 > 0 else 0
            return {
                "success": True,
                "message": f"已切换 {group} -> {node} ({delay}ms)，新健康度 {new_rate}%",
                "health_rate": new_rate,
                "switched_to": node,
                "delay_ms": delay,
            }

        return {"success": False, "message": "未找到可用节点", "health_rate": rate}

    def status(self) -> Dict:
        success, total, health = self.health_check()
        groups = self.list_groups()
        rate = success * 100 // total if total > 0 else 0
        return {
            "healthy": rate >= 60,
            "health_rate": rate,
            "health_details": health,
            "groups": {
                name: {"current": info["current"], "node_count": len(info["all"]),
                       "region": self.detect_region(info["current"])}
                for name, info in groups.items()
            },
        }


def main():
    parser = argparse.ArgumentParser(description="Clash Auto Switch - OpenClaw Skill v2.0")
    parser.add_argument("--api", default=None, help="Clash API 地址")
    parser.add_argument("--secret", "-s", default=None, help="API 密钥")
    parser.add_argument("--proxy", default=None, help="代理地址")
    parser.add_argument("--list", "-l", action="store_true", help="列出代理组")
    parser.add_argument("--health", action="store_true", help="健康检查")
    parser.add_argument("--auto", "-a", action="store_true", help="自动切换")
    parser.add_argument("--status", action="store_true", help="查看状态")
    parser.add_argument("--switch", nargs=2, metavar=("GROUP", "NODE"), help="切换节点")
    parser.add_argument("--sg", action="store_true", help="新加坡")
    parser.add_argument("--us", action="store_true", help="美国")
    parser.add_argument("--jp", action="store_true", help="日本")
    parser.add_argument("--hk", action="store_true", help="香港")
    parser.add_argument("--tw", action="store_true", help="台湾")
    parser.add_argument("--kr", action="store_true", help="韩国")
    parser.add_argument("--json", action="store_true", help="JSON 输出")

    args = parser.parse_args()
    output_json = args.json

    try:
        clash = ClashAutoSwitch(args.api, args.secret, args.proxy)
    except ValueError as e:
        print(f"错误: {e}")
        sys.exit(1)

    if args.health:
        s, t, details = clash.health_check()
        rate = s * 100 // t if t > 0 else 0
        if output_json:
            print(json.dumps({"healthy": rate >= 60, "rate": rate, "details": details}, ensure_ascii=False, indent=2))
        else:
            print(f"{'✓' if rate >= 60 else '✗'} 代理健康度: {s}/{t} ({rate}%)")
            for d in details:
                print(f"  {'✓' if d.get('ok') else '✗'} {d['target']}")

    elif args.list:
        groups = clash.list_groups()
        if output_json:
            print(json.dumps(groups, ensure_ascii=False, indent=2))
        else:
            for g, info in groups.items():
                print(f"  {g}: {info['current']} ({len(info['all'])} 节点)")

    elif args.auto:
        result = clash.auto_switch()
        if output_json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(f"{'✓' if result['success'] else '✗'} {result['message']}")

    elif args.status:
        status = clash.status()
        if output_json:
            print(json.dumps(status, ensure_ascii=False, indent=2))
        else:
            print(f"{'✓' if status['healthy'] else '✗'} 健康度: {status['health_rate']}%")
            for g, info in status["groups"].items():
                print(f"  {g}: {info['current']} [{info['region']}]")

    elif args.switch:
        g, n = args.switch
        ok = clash.set_proxy(g, n)
        if output_json:
            print(json.dumps({"success": ok, "group": g, "node": n}, ensure_ascii=False))
        else:
            print(f"{'✓' if ok else '✗'} {'已切换' if ok else '切换失败'} {g} -> {n}")

    elif any([args.sg, args.us, args.jp, args.hk, args.tw, args.kr]):
        rm = {"sg": args.sg, "us": args.us, "jp": args.jp, "hk": args.hk, "tw": args.tw, "kr": args.kr}
        selected = [r for r, v in rm.items() if v]
        result = clash.auto_switch(region_filter=selected)
        if output_json:
            print(json.dumps(result, ensure_ascii=False, indent=2))
        else:
            print(f"{'✓' if result['success'] else '✗'} {result['message']}")

    else:
        parser.print_help()


if __name__ == "__main__":
    main()
