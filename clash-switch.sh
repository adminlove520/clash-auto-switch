#!/bin/bash

################################################################################
# Clash 代理自动切换脚本 v2.0
# 修复: 密钥硬编码、区域切换不完整
# 新增: JP/HK/TW/KR 区域切换、环境变量优先
################################################################################

set -e

# 从环境变量读取配置 (不再硬编码密钥!)
CLASH_API="${CLASH_API:-http://127.0.0.1:58871}"
CLASH_SECRET="${CLASH_SECRET:-}"
PROXY_URL="${CLASH_PROXY:-http://127.0.0.1:7890}"

# 检查必填配置
if [ -z "$CLASH_SECRET" ]; then
    echo "[ERROR] 请设置 CLASH_SECRET 环境变量"
    echo '  export CLASH_SECRET="your-secret-here"'
    exit 1
fi

# 测试目标
TEST_TARGETS=(
    "https://api.telegram.org"
    "https://api.anthropic.com"
    "https://www.google.com"
)

# 区域优先级
PREFERRED_REGIONS=("新加坡" "🇸🇬" "SG" "Singapore" "香港" "🇭🇰" "HK" "Hong Kong" "日本" "🇯🇵" "JP" "Japan")

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 日志函数
log_info()    { echo -e "${GREEN}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_success() { echo -e "${CYAN}[OK]${NC} $(date '+%Y-%m-%d %H:%M:%S') $1"; }

# URL 编码函数
urlencode() {
    python3 -c "import urllib.parse; print(urllib.parse.quote('$1'))" 2>/dev/null || \
    echo "$1" | sed 's/ /%20/g'
}

# Clash API 调用
clash_api_get() {
    curl -s -H "Authorization: Bearer ${CLASH_SECRET}" "${CLASH_API}${1}" 2>/dev/null
}

clash_api_put() {
    curl -s -X PUT -H "Authorization: Bearer ${CLASH_SECRET}" \
         -H "Content-Type: application/json" \
         -d "${2}" "${CLASH_API}${1}" 2>/dev/null
}

# 测试代理连通性
test_proxy() {
    curl -x "${PROXY_URL}" -s -m 8 -I "$1" >/dev/null 2>&1
}

# 健康检查
health_check() {
    log_info "开始健康检查..."
    local success_count=0
    local total_count=${#TEST_TARGETS[@]}

    for target in "${TEST_TARGETS[@]}"; do
        if test_proxy "$target"; then
            log_success "  ✓ ${target} 可达"
            ((success_count++))
        else
            log_error "  ✗ ${target} 不可达"
        fi
    done

    local success_rate=$((success_count * 100 / total_count))
    log_info "健康度: ${success_count}/${total_count} (${success_rate}%)"

    [ $success_rate -ge 66 ]
}

# 获取所有可用节点 (过滤系统节点)
get_all_proxies() {
    clash_api_get "/proxies" | jq -r '.proxies | keys[]' 2>/dev/null | \
        grep -v "^GLOBAL$\|^DIRECT$\|^REJECT$\|^PROXY$\|^节点选择$\|^故障转移$\|^自动选择$\|^负载均衡$" | \
        grep -v "♻️\|🔰\|⚓️\|✈️\|🎬\|🎮\|🍎\|🎨\|❗\|🚀"
}

# 获取当前选中的节点
get_current_proxy() {
    clash_api_get "/proxies/PROXY" | jq -r '.now' 2>/dev/null
}

# 切换到指定节点
switch_proxy() {
    local proxy_name="$1"
    clash_api_put "/proxies/PROXY" "{\"name\":\"${proxy_name}\"}"
    if [ $? -eq 0 ]; then
        log_success "已切换到: ${proxy_name}"
    else
        log_error "切换失败: ${proxy_name}"
        return 1
    fi
}

# 测试节点延迟
test_proxy_delay() {
    local proxy_name="$1"
    local encoded_name=$(urlencode "$proxy_name")
    local delay=$(clash_api_get "/proxies/${encoded_name}/delay?timeout=5000&url=http://www.gstatic.com/generate_204" | jq -r '.delay' 2>/dev/null)

    if [ "$delay" != "null" ] && [ -n "$delay" ] && [ "$delay" != "0" ]; then
        echo "$delay"
    else
        echo "99999"
    fi
}

# 检查节点是否属于指定区域
is_in_region() {
    local proxy_name="$1"
    shift
    local keywords=("$@")

    for kw in "${keywords[@]}"; do
        if echo "$proxy_name" | grep -qi "$kw"; then
            return 0
        fi
    done
    return 1
}

# 区域切换 (通用)
region_switch() {
    local region_code="$1"
    local keywords=()

    case "$region_code" in
        sg) keywords=("新加坡" "🇸🇬" "SG" "Singapore") ;;
        hk) keywords=("香港" "🇭🇰" "HK" "Hong Kong") ;;
        jp) keywords=("日本" "🇯🇵" "JP" "Japan" "Tokyo") ;;
        us) keywords=("美国" "🇺🇲" "US" "USA" "LA" "Los Angeles") ;;
        tw) keywords=("台湾" "🇹🇼" "TW" "Taiwan") ;;
        kr) keywords=("韩国" "🇰🇷" "KR" "Korea") ;;
        *)
            log_error "不支持的区域: ${region_code}"
            log_info "支持: sg hk jp us tw kr"
            return 1
            ;;
    esac

    log_info "搜索 ${region_code} 区域节点..."
    local proxies=$(get_all_proxies)
    local best_proxy=""
    local best_delay=99999

    while IFS= read -r proxy; do
        [ -z "$proxy" ] && continue
        if ! is_in_region "$proxy" "${keywords[@]}"; then
            continue
        fi

        local delay=$(test_proxy_delay "$proxy")
        log_info "  ${proxy}: ${delay}ms"

        if [ "$delay" -lt "$best_delay" ]; then
            best_proxy="$proxy"
            best_delay="$delay"
        fi
    done <<< "$proxies"

    if [ -n "$best_proxy" ] && [ "$best_delay" -lt 5000 ]; then
        switch_proxy "$best_proxy"
        sleep 3
        health_check
    else
        log_error "未找到 ${region_code} 区域可用节点"
        return 1
    fi
}

# 自动切换
auto_switch() {
    log_info "========== Clash 自动切换 =========="
    local current_proxy=$(get_current_proxy)
    log_info "当前节点: ${current_proxy}"

    if health_check; then
        log_success "当前代理健康，无需切换"
        return 0
    fi

    log_warn "代理不健康，开始寻找最佳节点..."

    local best_proxy=""
    local best_delay=99999
    local preferred_proxy=""
    local preferred_delay=99999

    local proxies=$(get_all_proxies)
    while IFS= read -r proxy; do
        [ -z "$proxy" ] && continue
        local delay=$(test_proxy_delay "$proxy")
        log_info "  ${proxy}: ${delay}ms"

        if is_in_region "$proxy" "${PREFERRED_REGIONS[@]}"; then
            if [ "$delay" -lt "$preferred_delay" ]; then
                preferred_proxy="$proxy"
                preferred_delay="$delay"
            fi
        fi

        if [ "$delay" -lt "$best_delay" ]; then
            best_proxy="$proxy"
            best_delay="$delay"
        fi
    done <<< "$proxies"

    # 优先选择优先区域节点
    local target_proxy=""
    if [ -n "$preferred_proxy" ] && [ "$preferred_delay" -lt 3000 ]; then
        target_proxy="$preferred_proxy"
    elif [ -n "$best_proxy" ]; then
        target_proxy="$best_proxy"
    fi

    if [ -z "$target_proxy" ]; then
        log_error "未找到可用节点"
        return 1
    fi

    if [ "$target_proxy" != "$current_proxy" ]; then
        switch_proxy "$target_proxy"
        sleep 3
        if health_check; then
            log_success "切换成功！代理已恢复"
        else
            log_error "切换后仍不健康，可能需要手动干预"
            return 1
        fi
    else
        log_info "当前已是最佳节点，但连接仍有问题"
        return 1
    fi
}

# 列出节点
list_proxies() {
    log_info "========== 可用节点 =========="
    local current_proxy=$(get_current_proxy)
    local proxies=$(get_all_proxies)

    while IFS= read -r proxy; do
        [ -z "$proxy" ] && continue
        local marker=" "
        [ "$proxy" = "$current_proxy" ] && marker="★"
        echo -e "${marker} ${proxy}"
    done <<< "$proxies"
}

# 使用说明
usage() {
    cat << EOF
Clash 代理自动切换脚本 v2.0

用法: $0 [命令]

命令:
  check / health  健康检查
  auto            自动切换到最佳节点
  list            列出所有可用节点
  switch <节点名>  手动切换到指定节点
  sg              切换到新加坡节点
  hk              切换到香港节点
  jp              切换到日本节点
  us              切换到美国节点
  tw              切换到台湾节点
  kr              切换到韩国节点
  help            显示帮助

环境变量:
  CLASH_SECRET  (必填) API 密钥
  CLASH_API     Clash API 地址 (默认: http://127.0.0.1:58871)
  CLASH_PROXY   代理地址 (默认: http://127.0.0.1:7890)

EOF
}

# 主函数
main() {
    local command="${1:-help}"

    case "$command" in
        check|health) health_check ;;
        auto)         auto_switch ;;
        list)         list_proxies ;;
        switch)       switch_proxy "$2" ;;
        sg|hk|jp|us|tw|kr) region_switch "$command" ;;
        help|--help|-h)     usage ;;
        *)
            log_error "未知命令: $command"
            usage
            exit 1
            ;;
    esac
}

main "$@"
