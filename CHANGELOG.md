# Changelog

All notable changes to this project will be documented in this file.

## [2.0.0] - 2026-03-27

### Security
- **移除所有硬编码密钥** - .sh/.ps1/.py 全部从环境变量读取，启动时验证
- 添加 `.env.example` 模板

### Fixed
- **PowerShell 语法错误** - 修复 `sg` 区域切换函数中的花括号/语法问题
- **Python bare except** - 替换为具体异常类型
- **Bash 密钥泄露** - 不再在 help 输出中打印密钥
- **v2.sh 状态文件** - 修复 `status` 命令的文件读取逻辑

### Added
- **并发延迟测试** - Python 版使用 `ThreadPoolExecutor` 并发测试节点，速度提升 5-8x
- **重试机制** - API 请求自动重试，提升在不稳定网络下的可靠性
- **JSON 输出模式** - `--json` 参数，方便龙虾或其他程序调用
- **结构化结果** - `SwitchResult` / `NodeResult` 数据类，标准化输出
- **区域扩展** - 新增 TW(台湾)/KR(韩国)/UK(英国)/DE(德国) 区域支持
- **JP/HK 区域切换** - Bash 版补齐 jp/hk/tw/kr 快捷切换
- **智能节点过滤** - 自动跳过系统节点、emoji 标记节点
- **健康检查详情** - 显示每个测试目标的延迟和状态码
- **区域自动识别** - 根据节点名称自动识别所属区域

### Changed
- Python 版本重构为 v2.0，更清晰的类结构
- PowerShell 版重写，修复多处逻辑错误
- Bash 版统一使用 `region_switch()` 函数处理所有区域
- 更新 README 和 SKILL.md 文档

### Platforms
- ✅ Linux / macOS (Bash)
- ✅ Windows (PowerShell)
- ✅ 跨平台 (Python)
- ✅ OpenClaw Skill

---

## [1.0.0] - 2026-03-07

### Added
- 初始版本发布
- Bash 版本 (`clash-switch.sh`)
- 增强版 Bash (`clash-switch-v2.sh`) - 支持日志和状态追踪
- PowerShell 版本 (`clash-switch.ps1`) - Windows 支持
- Python 跨平台版 (`clash-switch.py`) - 推荐使用
- OpenClaw Skill - 支持 `/clash` 命令
- 配置示例文件
- 完整的 README 文档
