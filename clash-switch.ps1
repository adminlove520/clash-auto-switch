################################################################################
# Clash 代理自动切换脚本 (Windows PowerShell 版本)
# 版本: 2.0
# 修复: 语法错误、密钥硬编码、区域切换
################################################################################

# 解决 PowerShell 中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# 从环境变量读取配置 (不再硬编码密钥)
$CLASH_API = if ($env:CLASH_API) { $env:CLASH_API } else { "http://127.0.0.1:58871" }
$CLASH_SECRET = if ($env:CLASH_SECRET) { $env:CLASH_SECRET } else { "" }
$PROXY_URL = if ($env:CLASH_PROXY) { $env:CLASH_PROXY } else { "http://127.0.0.1:7890" }

if (-not $CLASH_SECRET) {
    Write-Host "[ERROR] 请设置 CLASH_SECRET 环境变量" -ForegroundColor Red
    Write-Host '  $env:CLASH_SECRET = "your-secret-here"' -ForegroundColor Yellow
    exit 1
}

# 测试目标
$TEST_TARGETS = @(
    "https://api.telegram.org",
    "https://api.anthropic.com",
    "https://www.google.com"
)

# 区域关键词映射
$REGION_MAP = @{
    "sg" = @("新加坡", "SG", "Singapore")
    "hk" = @("香港", "HK", "Hong Kong")
    "jp" = @("日本", "JP", "Japan", "Tokyo")
    "us" = @("美国", "US", "USA", "LA", "Los Angeles")
    "tw" = @("台湾", "TW", "Taiwan")
    "kr" = @("韩国", "KR", "Korea")
}

$Headers = @{
    "Authorization" = "Bearer $CLASH_SECRET"
}

# ========== 日志函数 ==========

function Write-Log {
    param([string]$Level, [string]$Msg, [ConsoleColor]$Color = "White")
    Write-Host "[$Level] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" -ForegroundColor $Color
}

function log_info { param($msg); Write-Log "INFO" $msg "Green" }
function log_warn { param($msg); Write-Log "WARN" $msg "Yellow" }
function log_error { param($msg); Write-Log "ERROR" $msg "Red" }
function log_success { param($msg); Write-Log "OK" $msg "Cyan" }

# ========== 核心功能 ==========

function Get-ProxyGroups {
    try {
        $response = Invoke-RestMethod -Uri "$CLASH_API/proxies" -Headers $Headers -TimeoutSec 10
        $groups = @{}
        foreach ($name in $response.proxies.PSObject.Properties.Name) {
            if ($response.proxies.$name.type -eq "Selector") {
                $groups[$name] = $response.proxies.$name
            }
        }
        return $groups
    } catch {
        log_error "获取代理组失败: $_"
        return @{}
    }
}

function Get-CurrentProxy {
    param([string]$groupName)
    try {
        $encoded = [System.Uri]::EscapeDataString($groupName)
        $response = Invoke-RestMethod -Uri "$CLASH_API/proxies/$encoded" -Headers $Headers -TimeoutSec 10
        return $response.now
    } catch {
        return "未知"
    }
}

function Set-ClashProxy {
    param([string]$groupName, [string]$nodeName)
    try {
        $encoded = [System.Uri]::EscapeDataString($groupName)
        $body = @{name = $nodeName} | ConvertTo-Json
        Invoke-RestMethod -Uri "$CLASH_API/proxies/$encoded" -Method Put -Headers $Headers -Body $body -ContentType "application/json" -TimeoutSec 10 | Out-Null
        return $true
    } catch {
        log_error "切换失败: $_"
        return $false
    }
}

function Test-ProxyConnection {
    param([string]$target)
    try {
        $result = Invoke-WebRequest -Uri $target -Proxy $PROXY_URL -TimeoutSec 8 -UseBasicParsing -ErrorAction Stop
        return $result.StatusCode -lt 500
    } catch {
        return $false
    }
}

function Test-Health {
    log_info "开始健康检查..."
    $success = 0
    $total = $TEST_TARGETS.Count

    foreach ($target in $TEST_TARGETS) {
        if (Test-ProxyConnection -target $target) {
            log_success "  ✓ $target 可达"
            $success++
        } else {
            log_error "  ✗ $target 不可达"
        }
    }

    $rate = [math]::Round(($success / $total) * 100)
    log_info "健康检查完成: $success/$total ($rate%)"

    return $rate -ge 66
}

function Test-NodeDelay {
    param([string]$nodeName)
    try {
        $encoded = [System.Uri]::EscapeDataString($nodeName)
        $delayUrl = "$CLASH_API/proxies/$encoded/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
        $resp = Invoke-RestMethod -Uri $delayUrl -Headers $Headers -TimeoutSec 10 -ErrorAction Stop
        $delay = $resp.delay
        if ($delay -and $delay -gt 0) { return $delay } else { return 99999 }
    } catch {
        return 99999
    }
}

function Get-NodeRegion {
    param([string]$nodeName)
    foreach ($region in $REGION_MAP.Keys) {
        foreach ($kw in $REGION_MAP[$region]) {
            if ($nodeName -match [regex]::Escape($kw)) {
                return $region
            }
        }
    }
    return "unknown"
}

function Show-ProxyList {
    $groups = Get-ProxyGroups
    Write-Host "`n========== 代理组 ==========" -ForegroundColor Yellow
    foreach ($groupName in $groups.Keys | Sort-Object) {
        $group = $groups[$groupName]
        $current = $group.now
        $region = Get-NodeRegion -nodeName $current
        $nodeCount = $group.all.Count
        Write-Host "`n  [$groupName] 当前: $current [$region] ($nodeCount 节点)" -ForegroundColor Cyan
        foreach ($node in $group.all) {
            $marker = if ($node -eq $current) { " ★" } else { "  " }
            $r = Get-NodeRegion -nodeName $node
            Write-Host "  $marker $node [$r]"
        }
    }
}

function Switch-ToBestInRegion {
    param([string[]]$regions)

    log_info "搜索区域节点: $($regions -join ', ')..."
    $groups = Get-ProxyGroups
    $bestNode = ""
    $bestDelay = 99999
    $bestGroup = ""

    foreach ($groupName in $groups.Keys) {
        $group = $groups[$groupName]
        foreach ($node in $group.all) {
            if ($node -eq "节点选择") { continue }
            $nodeRegion = Get-NodeRegion -nodeName $node
            if ($nodeRegion -notin $regions) { continue }

            $delay = Test-NodeDelay -nodeName $node
            Write-Host "  $node [$nodeRegion]: ${delay}ms"

            if ($delay -lt $bestDelay) {
                $bestNode = $node
                $bestDelay = $delay
                $bestGroup = $groupName
            }
        }
    }

    if ($bestNode -and $bestDelay -lt 5000) {
        log_info "切换到: $bestNode (${bestDelay}ms)"
        $ok = Set-ClashProxy -groupName $bestGroup -nodeName $bestNode
        if ($ok) {
            log_success "切换成功!"
            Start-Sleep -Seconds 3
            Test-Health | Out-Null
        }
    } else {
        log_error "未找到指定区域的可用节点"
    }
}

function Auto-Switch {
    log_info "========== Clash 自动切换 =========="

    if (Test-Health) {
        log_success "当前代理健康，无需切换"
        return
    }

    log_warn "代理不健康，开始自动切换..."
    Switch-ToBestInRegion -regions @("sg", "hk", "jp", "us")
}

# ========== 主入口 ==========

$cmd = $args[0]
if (-not $cmd) { $cmd = "help" }

switch ($cmd) {
    "check"  { Test-Health | Out-Null }
    "health" { Test-Health | Out-Null }
    "list"   { Show-ProxyList }
    "auto"   { Auto-Switch }
    "status" {
        $healthy = Test-Health
        Write-Host ""
        Show-ProxyList
    }
    "switch" {
        $groupName = $args[1]
        $nodeName = $args[2]
        if ($groupName -and $nodeName) {
            $ok = Set-ClashProxy -groupName $groupName -nodeName $nodeName
            if ($ok) { log_success "已切换 $groupName -> $nodeName" }
        } else {
            log_error "用法: .\clash-switch.ps1 switch <代理组> <节点名>"
            Show-ProxyList
        }
    }
    "sg" { Switch-ToBestInRegion -regions @("sg") }
    "hk" { Switch-ToBestInRegion -regions @("hk") }
    "jp" { Switch-ToBestInRegion -regions @("jp") }
    "us" { Switch-ToBestInRegion -regions @("us") }
    "tw" { Switch-ToBestInRegion -regions @("tw") }
    "kr" { Switch-ToBestInRegion -regions @("kr") }
    default {
        Write-Host @"

Clash 代理自动切换脚本 v2.0 (Windows PowerShell)

用法: .\clash-switch.ps1 [命令]

命令:
  check / health  健康检查
  auto            自动切换到最佳节点
  list            列出所有节点
  status          完整状态
  switch <组> <节点>  手动切换
  sg / hk / jp / us / tw / kr  区域切换

环境变量:
  CLASH_SECRET  (必填) API 密钥
  CLASH_API     Clash API 地址 (默认: http://127.0.0.1:58871)
  CLASH_PROXY   代理地址 (默认: http://127.0.0.1:7890)

"@
    }
}
