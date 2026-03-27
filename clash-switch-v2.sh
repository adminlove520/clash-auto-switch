#!/bin/bash

################################################################################
# Clash 代理自动切换脚本 - 增强版 v2.0
# 新增功能:
#   1. 日志记录 - 记录切换历史
#   2. 状态文件 - 保存当前状态 (JSON)
#   3. 多测试目标 - 更全面的健康检查
#   4. 区域切换 - 支持 sg/hk/jp/us/tw/kr
# 修复: 密钥硬编码、状态文件读取
################################################################################

set -e

# ========== 从环境变量读取配置 ==========
CLASH_API="${CLASH_API:-http://127.0.0.1:58871}"
CLASH_SECRET="${CLASH_SECRET:-}"
PROXY_URL="${CLASH_PROXY:-http://127.0.0.1:7890}"

if [ -z "$CLASH_SECRET" ]; then
    echo "[ERROR] 请设置 CLASH_SECRET 环境变量"
    echo '  export CLASH_SECRET="your-secret-here"'
    exit 1
fi

# 日志和状态文件
LOG_DIR="${HOME}/.clash-switch"
LOG_FILE="${LOG_DIR}/switch.log"
STATE_FILE="${LOG_DIR}/state.json"
mkdir -p "$LOG_DIR"

# 测试目标 (扩展版)
TEST_TARGETS=(
    "https://api.telegram.org"
    "https://api.anthropic.com"
    "https://www.google.com"
    "https://api.openai.com"
    "https://api.github.com"
)

# 区域关键词
declare -A REGION_KEYWORDS
REGION_KEYWORDS[sg]="新加坡|🇸🇬|SG|Singapore"
REGION_KEYWORDS[hk]="香港|🇭🇰|HK|Hong Kong"
REGION_KEYWORDS[jp]="日本|🇯🇵|JP|Japan|Tokyo"
REGION_KEYWORDS[us]="美国|🇺🇲|US|USA|LA|Los Angeles"
REGION_KEYWORDS[tw]="台湾|🇹🇼|TW|Taiwan"
REGION_KEYWORDS[kr]="韩国|🇰🇷|KR|Korea"

# ========== 日志函数 ==========

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_success() { log "✓ $1"; }
log_error()   { log "✗ $1"; }

# ========== 状态管理 ==========

save_state() {
    local current="$1"
    local status="$2"
    local rate="$3"
    echo "{\"timestamp\":\"$(date -Iseconds 2>/dev/null || date)\",\"current\":\"$current\",\"status\":\"$status\",\"health_rate\":$rate}" > "$STATE_FILE"
}

show_state() {
    if [ -f "$STATE_FILE" ]; then
        log "当前状态:"
        cat "$STATE_FILE"
        echo ""
    else
        log "暂无状态记录"
    fi
}

# ========== 核心功能 ==========

health_check() {
    local success=0
    local total=${#TEST_TARGETS[@]}

    for target in "${TEST_TARGETS[@]}"; do
        if curl -x "$PROXY_URL" -s -m 8 -I "$target" >/dev/null 2>&1; then
            ((success++))
        fi
    done

    local rate=$((success * 100 / total))
    echo $rate
}

get_all_proxies() {
    curl -s -H "Authorization: Bearer ${CLASH_SECRET}" "${CLASH_API}/proxies" | \
        jq -r '.proxies | keys[]' 2>/dev/null | \
        grep -v "^GLOBAL$\|^DIRECT$\|^REJECT$\|^PROXY$\|^节点选择$\|^故障转移$\|^自动选择$\|^负载均衡$"
}

get_current() {
    curl -s -H "Authorization: Bearer ${CLASH_SECRET}" "${CLASH_API}/proxies/ChatGPT" | \
        jq -r '.now' 2>/dev/null
}

switch_to() {
    local proxy="$1"
    curl -s -X PUT -H "Authorization: Bearer ${CLASH_SECRET}" \
         -H "Content-Type: application/json" \
         -d "{\"name\":\"$proxy\"}" \
         "${CLASH_API}/proxies/ChatGPT" >/dev/null 2>&1
}

test_delay() {
    local proxy="$1"
    local encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$proxy'))" 2>/dev/null || echo "$proxy")
    local delay=$(curl -s -H "Authorization: Bearer ${CLASH_SECRET}" \
        "${CLASH_API}/proxies/${encoded}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" | \
        jq -r '.delay' 2>/dev/null)

    if [ "$delay" != "null" ] && [ -n "$delay" ] && [ "$delay" != "0" ]; then
        echo $delay
    else
        echo "99999"
    fi
}

is_in_region() {
    local proxy="$1"
    local pattern="$2"
    echo "$proxy" | grep -qiE "$pattern"
}

find_best() {
    local region_pattern="${1:-}"
    local best=""
    local best_delay=99999

    for proxy in $(get_all_proxies | grep -v "节点选择"); do
        # 如果指定了区域，过滤不匹配的
        if [ -n "$region_pattern" ] && ! is_in_region "$proxy" "$region_pattern"; then
            continue
        fi

        local delay=$(test_delay "$proxy")
        log "  $proxy: ${delay}ms"

        if [ "$delay" -lt "$best_delay" ] && [ "$delay" -lt 5000 ]; then
            best="$proxy"
            best_delay=$delay
        fi
    done

    echo "$best"
}

# ========== 命令处理 ==========

cmd_check() {
    local rate=$(health_check)
    log "健康检查: ${rate}%"
    if [ $rate -ge 60 ]; then
        log_success "代理健康"
        save_state "$(get_current)" "healthy" "$rate"
        return 0
    else
        log_error "代理不健康"
        save_state "$(get_current)" "unhealthy" "$rate"
        return 1
    fi
}

cmd_auto() {
    local current=$(get_current)
    local rate=$(health_check)

    log "========== 自动切换 =========="
    log "当前: $current | 健康度: ${rate}%"

    if [ $rate -ge 60 ]; then
        log_success "代理健康，无需切换"
        save_state "$current" "healthy" "$rate"
        return 0
    fi

    log_error "代理不健康，开始自动切换..."
    local best=$(find_best)

    if [ -n "$best" ]; then
        switch_to "$best"
        sleep 3
        local new_rate=$(health_check)
        if [ $new_rate -ge 60 ]; then
            log_success "切换成功! $current -> $best (健康度: ${new_rate}%)"
            save_state "$best" "fixed" "$new_rate"
        else
            log_error "切换后仍不健康 (${new_rate}%)"
            save_state "$best" "still_unhealthy" "$new_rate"
        fi
    else
        log_error "未找到可用节点"
        save_state "$current" "no_node" "$rate"
    fi
}

cmd_region() {
    local code="$1"
    local pattern="${REGION_KEYWORDS[$code]}"
    if [ -z "$pattern" ]; then
        log_error "不支持的区域: $code (支持: sg hk jp us tw kr)"
        return 1
    fi

    log "搜索 ${code} 区域..."
    local best=$(find_best "$pattern")

    if [ -n "$best" ]; then
        switch_to "$best"
        sleep 3
        local rate=$(health_check)
        log_success "已切换到 $best (健康度: ${rate}%)"
        save_state "$best" "region_switch" "$rate"
    else
        log_error "未找到 ${code} 区域可用节点"
    fi
}

cmd_list() {
    echo "========== 代理组 =========="
    curl -s -H "Authorization: Bearer ${CLASH_SECRET}" "${CLASH_API}/proxies" | \
        jq -r '.proxies | to_entries[] | select(.value.type=="Selector") | "\(.key): \(.value.now)"'
}

# ========== 主入口 ==========

case "${1:-help}" in
    check|health)  cmd_check ;;
    auto)          cmd_auto ;;
    list)          cmd_list ;;
    status)        show_state ;;
    sg|hk|jp|us|tw|kr) cmd_region "$1" ;;
    *)
        echo "Clash Auto Switch v2.0 (增强版)"
        echo ""
        echo "用法: $0 <命令>"
        echo ""
        echo "命令:"
        echo "  check / health  健康检查"
        echo "  auto            自动切换"
        echo "  list            列出代理组"
        echo "  status          显示状态"
        echo "  sg/hk/jp/us/tw/kr  区域切换"
        echo ""
        echo "环境变量:"
        echo "  CLASH_SECRET (必填)  API 密钥"
        echo "  CLASH_API           API 地址"
        echo "  CLASH_PROXY         代理地址"
        echo ""
        ;;
esac
