"""
Clash Auto Switch - 代理节点智能切换工具 (v2.0)
龙虾可以直接 import 使用:
    from clash_switch import ClashAutoSwitch
    clash = ClashAutoSwitch()
    result = clash.auto_switch()
"""

# 让龙虾可以直接 import
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

# 直接从主模块导出核心类
try:
    # 先尝试把 clash-switch.py 作为模块加载 (文件名含连字符需要特殊处理)
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "clash_switch_module",
        os.path.join(os.path.dirname(__file__), "clash-switch.py")
    )
    _module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(_module)

    ClashAutoSwitch = _module.ClashAutoSwitch
    SwitchResult = _module.SwitchResult
    NodeResult = _module.NodeResult

    __all__ = ["ClashAutoSwitch", "SwitchResult", "NodeResult"]
except Exception as e:
    print(f"[clash-auto-switch] 加载失败: {e}")
    __all__ = []
