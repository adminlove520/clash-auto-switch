# Clash Auto Switch

> 自动切换代理节点的脚本工具，支持 Linux 和 Windows

## 功能

- ✅ 健康检查：测试当前代理连通性
- ✅ 自动切换：检测到故障时自动切换到最佳节点
- ✅ 区域优先：优先选择新加坡/日本/香港/美国节点
- ✅ 手动切换：支持切换到指定节点或区域

## 支持平台

- 🐧 Linux / macOS: `clash-switch.sh` (Bash)
- 🪟 Windows: `clash-switch.ps1` (PowerShell)

## 配置

编辑脚本顶部的配置变量：

### Linux/macOS
```bash
CLASH_API="http://127.0.0.1:9090"
CLASH_SECRET="your-secret"
PROXY_URL="http://127.0.0.1:7890"
```

### Windows
```powershell
$CLASH_API = "http://127.0.0.1:58871"
$CLASH_SECRET = "your-secret"
$PROXY_URL = "http://127.0.0.1:7890"
```

## 使用方法

### Linux/macOS

```bash
# 添加执行权限
chmod +x clash-switch.sh

# 健康检查
./clash-switch.sh check

# 自动切换到最佳节点
./clash-switch.sh auto

# 列出所有节点
./clash-switch.sh list

# 切换到新加坡
./clash-switch.sh sg

# 切换到美国
./clash-switch.sh us

# 手动切换
./clash-switch.sh switch "代理组名" "节点名"
```

### Windows

```powershell
# 健康检查
.\clash-switch.ps1 check

# 自动切换到最佳节点
.\clash-switch.ps1 auto

# 列出所有节点
.\clash-switch.ps1 list

# 切换到新加坡
.\clash-switch.ps1 sg

# 切换到美国
.\clash-switch.ps1 us

# 手动切换
.\clash-switch.ps1 switch "ChatGPT" "新加坡-优化-Gemini-GPT"
```

## 代理组

脚本支持自动管理以下代理组：

- ChatGPT
- Copilot
- GLOBAL
- Netflix
- Steam
- Telegram
- TikTok
- Twitter
- WhatsApp
- 境内使用
- 海外使用
- 节点选择
- 谷歌服务
- 微软服务
- 苹果服务

## 自动切换逻辑

1. 检查当前代理健康状态（测试 Telegram/Google/Anthropic）
2. 如果不健康，自动遍历所有节点
3. 测试每个节点的延迟
4. 优先选择优先区域的节点（日本/新加坡/香港/美国）
5. 切换到最佳节点

## 定时任务

可以使用 cron（Linux）或 Task Scheduler（Windows）实现定时检查：

### Linux crontab 示例
```bash
# 每 15 分钟检查一次
*/15 * * * * /path/to/clash-switch.sh auto >> /var/log/clash-switch.log 2>&1
```

### Windows 计划任务示例
```powershell
# 每 15 分钟执行一次
Register-ScheduledTask -TaskName "ClashAutoSwitch" -Trigger (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)) -Action (New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-File C:\path\to\clash-switch.ps1 auto") -RunLevel Highest
```

## License

MIT
