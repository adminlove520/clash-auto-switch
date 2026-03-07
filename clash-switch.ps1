################################################################################
# Clash 代理自动切换脚本 (Windows PowerShell 版本)
# 版本: 1.0
# 功能:
#   1. 健康检查：测试当前代理连通性
#   2. 自动切换：检测到故障时自动切换节点
#   3. 区域优先：优先选择美国/新加坡节点
################################################################################

# 解决 PowerShell 中文乱码
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
$CLASH_API = "http://127.0.0.1:58871"
$CLASH_SECRET = "6434ff5a-5b0f-4598-99ec-83ca96c77167"
$PROXY_URL = "http://127.0.0.1:7890"

# 测试目标（用于验证代理连通性）
$TEST_TARGETS = @(
    "https://api.telegram.org",
    "https://api.anthropic.com",
    "https://www.google.com"
)

# 区域优先级
$PREFERRED_REGIONS = @("新加坡", "SG", "Singapore", "香港", "HK", "Hong Kong", "日本", "JP", "Japan", "美国", "US", "USA")

# Headers
$Headers = @{
    "Authorization" = "Bearer $CLASH_SECRET"
}

function log_info {
    param($msg)
    Write-Host "[INFO] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ForegroundColor Green
}

function log_warn {
    param($msg)
    Write-Host "[WARN] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ForegroundColor Yellow
}

function log_error {
    param($msg)
    Write-Host "[ERROR] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ForegroundColor Red
}

function log_success {
    param($msg)
    Write-Host "[OK] $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" -ForegroundColor Cyan
}

# 获取代理组列表
function Get-ProxyGroups {
    try {
        $response = Invoke-RestMethod -Uri "$CLASH_API/proxies" -Headers $Headers
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

# 获取当前节点
function Get-CurrentProxy {
    param($groupName)
    try {
        $response = Invoke-RestMethod -Uri "$CLASH_API/proxies/$groupName" -Headers $Headers
        return $response.now
    } catch {
        return "未知"
    }
}

# 切换节点
function Set-Proxy {
    param($groupName, $nodeName)
    try {
        $body = @{name = $nodeName} | ConvertTo-Json
        $response = Invoke-RestMethod -Uri "$CLASH_API/proxies/$groupName" -Method Put -Headers $Headers -Body $body -ContentType "application/json"
        return $true
    } catch {
        log_error "切换失败: $_"
        return $false
    }
}

# 测试代理连通性
function Test-ProxyConnection {
    param($target)
    try {
        $result = Invoke-WebRequest -Uri $target -Proxy $PROXY_URL -TimeoutSec 10 -UseBasicParsing -ErrorAction SilentlyContinue
        return $result.StatusCode -eq 200
    } catch {
        return $false
    }
}

# 健康检查
function Test-Health {
    log_info "开始健康检查..."
    $success = 0
    $total = $TEST_TARGETS.Count
    
    foreach ($target in $TEST_TARGETS) {
        if (Test-ProxyConnection -target $target) {
            log_success "✓ $target 可达"
            $success++
        } else {
            log_error "✗ $target 不可达"
        }
    }
    
    $rate = [math]::Round(($success / $total) * 100)
    log_info "健康检查完成: $success/$total ($rate%)"
    
    return $rate -ge 66
}

# 列出所有代理组和节点
function Show-ProxyList {
    $groups = Get-ProxyGroups
    foreach ($groupName in $groups.Keys | Sort-Object) {
        $group = $groups[$groupName]
        $current = $group.now
        Write-Host "`n【$groupName】当前: $current" -ForegroundColor Yellow
        Write-Host "  可用节点:"
        foreach ($node in $group.all) {
            Write-Host "    - $node"
        }
    }
}

# 切换到最佳节点
function Switch-ToBestNode {
    param($groupName)
    
    $groups = Get-ProxyGroups
    if (-not $groups.ContainsKey($groupName)) {
        log_error "代理组 '$groupName' 不存在"
        return $false
    }
    
    $group = $groups[$groupName]
    $current = $group.now
    
    log_info "当前节点: $current"
    log_info "测试所有节点延迟..."
    
    $bestNode = ""
    $bestDelay = 99999
    
    foreach ($node in $group.all) {
        if ($node -eq "节点选择") { continue }
        
        try {
            $encodedNode = [System.Uri]::EscapeDataString($node)
            $delayUrl = "$CLASH_API/proxies/$encodedNode/delay?timeout=5000&url=http://www.gstatic.com/generate_204"
            $resp = Invoke-RestMethod -Uri $delayUrl -Headers $Headers -ErrorAction SilentlyContinue
            $delay = $resp.delay
            
            if ($delay -and $delay -gt 0 -and $delay -lt $bestDelay) {
                $bestDelay = $delay
                $bestNode = $node
            }
            Write-Host "  $node : ${delay}ms"
        } catch {
            Write-Host "  $node : 超时" -ForegroundColor Red
        }
    }
    
    if ($bestNode -and $bestDelay -lt 3000) {
        if ($bestNode -ne $current) {
            log_info "切换到最佳节点: $bestNode (${bestDelay}ms)"
            return Set-Proxy -groupName $groupName -nodeName $bestNode
        } else {
            log_info "当前已是最佳节点"
            return $true
        }
    } else {
        log_error "未找到可用节点"
        return $false
    }
}

# 自动切换
function Auto-Switch {
    log_info "========== Clash 自动切换 =========="
    
    if (Test-Health) {
        log_success "当前代理健康，无需切换"
        return
    }
    
    log_warn "当前代理不健康，开始自动切换..."
    
    # 切换每个代理组
    $groups = Get-ProxyGroups
    foreach ($groupName in $groups.Keys) {
        $current = $groups[$groupName].now
        if ($current -eq "节点选择") {
            log_info "正在优化 $groupName..."
            Switch-ToBestNode -groupName $groupName
        }
    }
    
    # 重新检查
    Start-Sleep -Seconds 5
    if (Test-Health) {
        log_success "切换成功！代理已恢复正常"
    } else {
        log_error "切换后仍不健康"
    }
}

# 主函数
function Main {
    param($command)
    
    switch ($command) {
        "check" {
            Test-Health
        }
        "list" {
            Show-ProxyList
        }
        "auto" {
            Auto-Switch
        }
        "switch" {
            param($groupName, $nodeName)
            if ($nodeName) {
                Set-Proxy -groupName $groupName -nodeName $nodeName
            } else {
                Show-ProxyList
            }
        }
        "sg" {
            # 切换到新加坡节点
            $groups = Get-ProxyGroups
            foreach ($g in $groups.Keys) {
                $nodes = $groups[$g].all | Where-Object { $_ -match "新加坡" }
                {
                    Set if ($nodes)-Proxy -groupName $g -nodeName $nodes[0]
                }
            }
        }
        "us" {
            # 切换到美国节点
            $groups = Get-ProxyGroups
            foreach ($g in $groups.Keys) {
                $nodes = $groups[$g].all | Where-Object { $_ -match "美国|US|LA" }
                if ($nodes) {
                    Set-Proxy -groupName $g -nodeName $nodes[0]
                }
            }
        }
        default {
            Write-Host @"

Clash 代理自动切换脚本 v1.0 (Windows PowerShell)

用法: .\clash-switch.ps1 [命令] [参数]

命令:
  check       健康检查当前代理
  auto       自动切换到最佳节点（推荐）
  list       列出所有可用节点
  switch     手动切换到指定节点
  sg         切换到新加坡节点
  us         切换到美国节点

示例:
  .\clash-switch.ps1 check        # 检查当前代理健康状态
  .\clash-switch.ps1 auto         # 自动切换到最佳节点
  .\clash-switch.ps1 list         # 列出所有节点
  .\clash-switch.ps1 switch ChatGPT "新加坡-优化-Gemini-GPT"  # 切换指定组到指定节点
  .\clash-switch.ps1 sg           # 切换到新加坡节点

配置:
  Clash API:  $CLASH_API
  代理地址:   $PROXY_URL
  控制密钥:   $CLASH_SECRET

"@
        }
    }
}

# 执行
$cmd = $args[0]
if (-not $cmd) { $cmd = "help" }

switch ($cmd) {
    "check" { Test-Health }
    "list" { Show-ProxyList }
    "auto" { Auto-Switch }
    "switch" { 
        $groupName = $args[1]
        $nodeName = $args[2]
        if ($nodeName) {
            Set-Proxy -groupName $groupName -nodeName $nodeName
        } else {
            Show-ProxyList
        }
    }
    "sg" {
        $groups = Get-ProxyGroups
        foreach ($g in $groups.Keys) {
            $nodes = $groups[$g].all | Where-Object { $_ -match "新加坡" }
            if ($nodes) {
                Set-Proxy -groupName $g -nodeName $nodes[0]
            }
        }
    }
    "us" {
        $groups = Get-ProxyGroups
        foreach ($g in $groups.Keys) {
            $nodes = $groups[$g].all | Where-Object { $_ -match "美国|US|LA" }
            if ($nodes) {
                Set-Proxy -groupName $g -nodeName $nodes[0]
            }
        }
    }
    default { Show-ProxyList }
}
