#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
CONFIG_FILE=${GUET_DRCOM_ENV:-"$SCRIPT_DIR/.env"}

SERVER_IP=${SERVER_IP:-10.0.1.5}
STATUS_URL=${STATUS_URL:-http://${SERVER_IP}/}
LOGOUT_URL=${LOGOUT_URL:-http://${SERVER_IP}:801/eportal/portal/logout}
LOGIN_URL=${LOGIN_URL:-http://${SERVER_IP}/drcom/login}
LOGOUT_DELAY=${LOGOUT_DELAY:-1}
DRY_RUN=${DRY_RUN:-0}
AUTO_LOG=${AUTO_LOG:-"$SCRIPT_DIR/guet_drcom.log"}

CARRIER_NAMES=("校园网" "中国移动" "中国联通" "中国电信" "中国广电")
CARRIER_SUFFIXES=("" "@cmcc" "@unicom" "@telecom" "@glgd")

if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-dumb} != dumb ]]; then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    CYAN=$'\033[36m'
else
    RESET=''
    BOLD=''
    DIM=''
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
fi

ui_header() {
    printf '\n%b%s%b\n' "$BOLD$CYAN" '╭─ GUET Dr.COM ─────────────────────────╮' "$RESET"
    printf '%b  %s%b\n' "$BOLD" "$1" "$RESET"
    printf '%b%s%b\n\n' "$BOLD$CYAN" '╰───────────────────────────────────────╯' "$RESET"
}

ui_section() {
    printf '\n%b%s%b\n' "$BOLD$CYAN" "◆ $1" "$RESET"
}

ui_value() {
    printf '  %b%-10s%b %s\n' "$DIM" "$1" "$RESET" "$2"
}

ui_success() {
    printf '%b✓%b %s\n' "$GREEN" "$RESET" "$1"
}

ui_warning() {
    printf '%b!%b %s\n' "$YELLOW" "$RESET" "$1" >&2
}

ui_step() {
    printf '\n%b%s%b %s\n' "$CYAN" "$1" "$RESET" "$2"
}

fail() {
    printf '%b✗%b %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

usage() {
    local init_status auto_status

    if [[ -f $CONFIG_FILE ]]; then
        init_status='已完成'
    else
        init_status='未完成'
    fi

    auto_status='未启用'
    if command -v crontab >/dev/null 2>&1 \
        && crontab -l 2>/dev/null | grep -Fq '# guet_drcom-auto'; then
        auto_status='已启用'
    fi

    ui_header '校园网认证工具'
    printf '%b用法%b  %s <子命令>\n' "$BOLD" "$RESET" "$(basename "$0")"
    ui_section '子命令'
    printf '  %b%-9s%b %s\n' "$GREEN" 'init' "$RESET" '初始化账号、密码、运营商及路由器 IP/MAC'
    printf '  %b%-9s%b %s\n' "$GREEN" 'login' "$RESET" '注销旧会话后重新登录'
    printf '  %b%-9s%b %s\n' "$GREEN" 'logout' "$RESET" '单独测试注销功能'
    printf '  %b%-9s%b %s\n' "$GREEN" 'auto' "$RESET" '启用每分钟自动检测与重连'
    printf '  %b%-9s%b %s\n' "$GREEN" 'disable' "$RESET" '关闭自动检测与重连'
    printf '  %b%-9s%b %s\n' "$GREEN" 'help' "$RESET" '显示此帮助'

    ui_section '当前状态'
    if [[ $init_status == '已完成' ]]; then
        printf '  %b●%b init    %s\n' "$GREEN" "$RESET" "$init_status"
    else
        printf '  %b○%b init    %s\n' "$YELLOW" "$RESET" "$init_status"
    fi
    if [[ $auto_status == '已启用' ]]; then
        printf '  %b●%b auto    %s\n' "$GREEN" "$RESET" "$auto_status"
    else
        printf '  %b○%b auto    %s\n' "$DIM" "$RESET" "$auto_status"
    fi
    printf '\n%b配置文件：%s%b\n' "$DIM" "$CONFIG_FILE" "$RESET"
}

select_carrier() {
    local selected=0
    local key rest index suffix

    ui_section '选择运营商'
    printf '%b使用 ↑/↓ 移动，Enter 确认，也可按数字选择%b\n\n' "$DIM" "$RESET"
    while true; do
        for index in "${!CARRIER_NAMES[@]}"; do
            suffix=${CARRIER_SUFFIXES[$index]}
            if ((index == selected)); then
                printf '\r\033[2K  %b›  %d  %-10s%s%b\n' \
                    "$BOLD$CYAN" "$((index + 1))" "${CARRIER_NAMES[$index]}" \
                    "${suffix:+ $suffix}" "$RESET"
            else
                printf '\r\033[2K     %d  %-10s%s\n' \
                    "$((index + 1))" "${CARRIER_NAMES[$index]}" "${suffix:+ $suffix}"
            fi
        done

        if ! IFS= read -rsn1 key; then
            fail "读取运营商选择失败"
        fi

        case "$key" in
            $'\x1b')
                rest=''
                IFS= read -rsn2 -t 1 rest || true
                case "$rest" in
                    '[A') selected=$(((selected + ${#CARRIER_NAMES[@]} - 1) % ${#CARRIER_NAMES[@]})) ;;
                    '[B') selected=$(((selected + 1) % ${#CARRIER_NAMES[@]})) ;;
                esac
                ;;
            '')
                SELECTED_CARRIER_ID=$((selected + 1))
                SELECTED_CARRIER_NAME=${CARRIER_NAMES[$selected]}
                SELECTED_CARRIER_SUFFIX=${CARRIER_SUFFIXES[$selected]}
                printf '\n'
                return
                ;;
            [1-5])
                selected=$((key - 1))
                ;;
        esac
        printf '\033[%dA' "${#CARRIER_NAMES[@]}"
    done
}

write_env_value() {
    printf '%s=%q\n' "$1" "$2"
}

init_command() {
    local student_id password account temp_file router_ip router_mac

    [[ -t 0 ]] || fail "init 需要在交互式终端中运行"

    ui_header '初始化认证配置'
    printf '%b学号%b  ' "$BOLD" "$RESET"
    read -r student_id
    [[ $student_id =~ ^[0-9]+$ ]] || fail "学号只能包含数字"

    printf '%b密码%b  ' "$BOLD" "$RESET"
    read -rs password
    printf '\n'
    [[ -n $password ]] || fail "密码不能为空"

    select_carrier
    account="${student_id}${SELECTED_CARRIER_SUFFIX}"

    # 认证门户看到的是路由器 WAN 口的地址，本机网卡信息无用，须由用户填写
    ui_section '路由器 WAN 口信息'
    printf '%b可在路由器管理页的「WAN 口状态 / 上网设置」中查看%b\n\n' "$DIM" "$RESET"
    printf '%bIPv4%b  ' "$BOLD" "$RESET"
    read -r router_ip
    [[ -n $router_ip ]] || fail "路由器 IPv4 地址不能为空"

    printf '%bMAC%b   ' "$BOLD" "$RESET"
    read -r router_mac
    [[ -n $router_mac ]] || fail "路由器 MAC 地址不能为空"

    resolve_network "$router_ip" "$router_mac"
    temp_file="${CONFIG_FILE}.tmp.$$"

    umask 077
    trap 'rm -f -- "$temp_file"' RETURN
    {
        printf '# 由 guet_drcom init 生成，请勿提交或分享此文件。\n'
        write_env_value DRCOM_STUDENT_ID "$student_id"
        write_env_value DRCOM_CARRIER_ID "$SELECTED_CARRIER_ID"
        write_env_value DRCOM_CARRIER_NAME "$SELECTED_CARRIER_NAME"
        write_env_value DRCOM_ACCOUNT "$account"
        write_env_value DRCOM_PASSWORD "$password"
        printf '# 路由器 WAN 口地址；IP 变化后可直接修改此处，无需重新 init。\n'
        write_env_value DRCOM_ROUTER_IP "$client_ip"
        write_env_value DRCOM_ROUTER_MAC "$client_mac"
    } >"$temp_file"
    chmod 600 "$temp_file"
    mv -f -- "$temp_file" "$CONFIG_FILE"
    trap - RETURN

    ui_success '初始化完成'
    ui_value '登录账号' "$account"
    ui_value '运营商' "$SELECTED_CARRIER_NAME"
    print_network
    ui_value '配置文件' "$CONFIG_FILE"
}

load_config() {
    [[ -f $CONFIG_FILE ]] || fail "找不到 ${CONFIG_FILE}，请先运行 $(basename "$0") init"

    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a

    [[ -n ${DRCOM_ACCOUNT:-} ]] || fail "$CONFIG_FILE 缺少 DRCOM_ACCOUNT"
    [[ -n ${DRCOM_PASSWORD:-} ]] || fail "$CONFIG_FILE 缺少 DRCOM_PASSWORD"
    [[ -n ${DRCOM_ROUTER_IP:-} ]] || fail "$CONFIG_FILE 缺少 DRCOM_ROUTER_IP，请重新运行 $(basename "$0") init"
    [[ -n ${DRCOM_ROUTER_MAC:-} ]] || fail "$CONFIG_FILE 缺少 DRCOM_ROUTER_MAC，请重新运行 $(basename "$0") init"

    resolve_network "$DRCOM_ROUTER_IP" "$DRCOM_ROUTER_MAC"
}

# 规范化并校验路由器 WAN 口地址，结果写入 client_ip / client_mac
resolve_network() {
    local octet ipv4_octets
    client_ip=$1
    client_mac=$2

    client_mac=$(tr -d ':-' <<<"$client_mac" | tr '[:upper:]' '[:lower:]' | tr -d '\n')

    [[ $client_mac =~ ^[0-9a-f]{12}$ ]] || fail "MAC 地址格式无效：$client_mac"
    [[ $client_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "IPv4 地址格式无效：$client_ip"
    IFS=. read -r -a ipv4_octets <<<"$client_ip"
    for octet in "${ipv4_octets[@]}"; do
        ((10#$octet <= 255)) || fail "IPv4 地址格式无效：$client_ip"
    done
}

send_logout() {
    local progress_label=${1:-'[logout]'}
    local cache_buster response compact
    LOGOUT_SUCCEEDED=0
    cache_buster=$(date +%s)

    ui_step "$progress_label" '正在注销当前会话…'
    # --noproxy '*': 校园认证须直连门户，避免 http_proxy / 系统代理劫持
    response=$(curl --silent --show-error --compressed --get \
        --noproxy '*' \
        --connect-timeout 5 \
        --max-time 8 \
        --header 'Accept: */*' \
        --header "Referer: http://${SERVER_IP}/" \
        --data-urlencode 'callback=dr1003' \
        --data-urlencode 'login_method=0' \
        --data-urlencode 'user_account=drcom' \
        --data-urlencode 'user_password=123' \
        --data-urlencode 'ac_logout=1' \
        --data-urlencode 'register_mode=1' \
        --data-urlencode "wlan_user_ip=$client_ip" \
        --data-urlencode 'wlan_user_ipv6=' \
        --data-urlencode 'wlan_vlan_id=1' \
        --data-urlencode "wlan_user_mac=$client_mac" \
        --data-urlencode 'wlan_ac_ip=' \
        --data-urlencode 'wlan_ac_name=' \
        --data-urlencode 'jsVersion=4.2' \
        --data-urlencode "v=$cache_buster" \
        --data-urlencode 'lang=zh' \
        "$LOGOUT_URL")
    printf '  %b服务器%b  %s\n' "$DIM" "$RESET" "$response"

    compact=$(tr -d '[:space:]' <<<"$response")
    # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
    if [[ $compact =~ \"result\":1([^0-9]|$) ]]; then
        LOGOUT_SUCCEEDED=1
    else
        ui_warning 'logout 未返回 result=1，将继续尝试登录'
    fi
}

send_login() {
    local cache_buster response compact
    cache_buster=$(date +%s)

    ui_step '[2/2]' '正在提交登录认证…'
    # --noproxy '*': 校园认证须直连门户，避免 http_proxy / 系统代理劫持
    response=$(curl --silent --show-error --compressed --get \
        --noproxy '*' \
        --connect-timeout 5 \
        --max-time 8 \
        --header 'Accept: */*' \
        --header "Referer: http://${SERVER_IP}/" \
        --data-urlencode 'callback=dr1004' \
        --data-urlencode "DDDDD=$DRCOM_ACCOUNT" \
        --data-urlencode "upass=$DRCOM_PASSWORD" \
        --data-urlencode '0MKKey=123456' \
        --data-urlencode 'R1=0' \
        --data-urlencode 'R2=' \
        --data-urlencode 'R3=0' \
        --data-urlencode 'R6=0' \
        --data-urlencode 'para=00' \
        --data-urlencode "v4ip=$client_ip" \
        --data-urlencode 'v6ip=' \
        --data-urlencode 'terminal_type=1' \
        --data-urlencode 'lang=zh-cn' \
        --data-urlencode 'jsVersion=4.2' \
        --data-urlencode "v=$cache_buster" \
        --data-urlencode 'lang=zh' \
        "$LOGIN_URL")
    printf '  %b服务器%b  %s\n' "$DIM" "$RESET" "$response"

    compact=$(tr -d '[:space:]' <<<"$response")
    # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
    [[ $compact =~ \"result\":1([^0-9]|$) ]] || fail "登录失败，服务器未返回 result=1"
    ui_success '登录成功'
}

print_network() {
    ui_section '路由器 WAN 口信息'
    ui_value 'IPv4' "$client_ip"
    ui_value 'MAC' "$client_mac"
}

logout_command() {
    ui_header '注销校园网会话'
    load_config
    print_network

    if [[ $DRY_RUN == 1 ]]; then
        ui_warning 'DRY_RUN=1，未发送 logout 请求'
        return
    fi

    command -v curl >/dev/null 2>&1 || fail "找不到 curl 命令"
    send_logout '[logout]'
    [[ $LOGOUT_SUCCEEDED == 1 ]] || fail "注销失败，服务器未返回 result=1"
    ui_success '注销成功'
}

login_command() {
    ui_header '登录校园网'
    load_config
    print_network
    ui_value '登录账号' "$DRCOM_ACCOUNT"

    if [[ $DRY_RUN == 1 ]]; then
        ui_warning 'DRY_RUN=1，未发送 logout/login 请求'
        return
    fi

    command -v curl >/dev/null 2>&1 || fail "找不到 curl 命令"
    send_logout '[1/2]'
    [[ $LOGOUT_DELAY == 0 ]] || sleep "$LOGOUT_DELAY"
    send_login
}

check_command() {
    local page

    command -v curl >/dev/null 2>&1 || fail "找不到 curl 命令"
    command -v iconv >/dev/null 2>&1 || fail "找不到 iconv 命令"

    if page=$(curl --silent --show-error \
        --noproxy '*' \
        --connect-timeout 5 \
        --max-time 8 \
        "$STATUS_URL" 2>/dev/null | iconv -f GBK -t UTF-8 2>/dev/null) \
        && [[ $page == *'注销页'* ]]; then
        return
    fi

    printf '[%s] 未检测到“注销页”，开始重新登录。\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    login_command
}

auto_command() {
    local existing filtered cron_line
    local script_quoted config_quoted log_quoted

    [[ -f $CONFIG_FILE ]] || fail "找不到 ${CONFIG_FILE}，请先运行 $(basename "$0") init"
    command -v crontab >/dev/null 2>&1 || fail "找不到 crontab 命令"

    umask 077
    : >>"$AUTO_LOG"
    chmod 600 "$AUTO_LOG"

    printf -v script_quoted '%q' "$SCRIPT_PATH"
    printf -v config_quoted '%q' "$CONFIG_FILE"
    printf -v log_quoted '%q' "$AUTO_LOG"
    cron_line="* * * * * PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin GUET_DRCOM_ENV=$config_quoted $script_quoted check >> $log_quoted 2>&1 # guet_drcom-auto"

    existing=$(crontab -l 2>/dev/null || true)
    filtered=$(awk '!/# guet_drcom-auto$/' <<<"$existing")
    {
        [[ -z $filtered ]] || printf '%s\n' "$filtered"
        printf '%s\n' "$cron_line"
    } | crontab -

    ui_header '自动重连'
    ui_success '定时任务已启用，每分钟检查一次'
    ui_value '配置文件' "$CONFIG_FILE"
    ui_value '日志文件' "$AUTO_LOG"
    ui_value '查看任务' 'crontab -l'
}

disable_command() {
    local existing filtered

    command -v crontab >/dev/null 2>&1 || fail "找不到 crontab 命令"
    existing=$(crontab -l 2>/dev/null || true)

    if ! grep -Fq '# guet_drcom-auto' <<<"$existing"; then
        ui_warning '自动重连任务尚未启用，无需移除'
        return
    fi

    filtered=$(awk '!/# guet_drcom-auto$/' <<<"$existing")
    {
        [[ -z $filtered ]] || printf '%s\n' "$filtered"
    } | crontab -

    ui_header '自动重连'
    ui_success '定时任务已关闭，其他 cron 任务未修改'
}

case ${1:-help} in
    init)
        [[ $# -eq 1 ]] || fail "init 不接受额外参数"
        init_command
        ;;
    login)
        [[ $# -eq 1 ]] || fail "login 不接受额外参数"
        login_command
        ;;
    logout)
        [[ $# -eq 1 ]] || fail "logout 不接受额外参数"
        logout_command
        ;;
    auto)
        [[ $# -eq 1 ]] || fail "auto 不接受额外参数"
        auto_command
        ;;
    disable)
        [[ $# -eq 1 ]] || fail "disable 不接受额外参数"
        disable_command
        ;;
    check)
        [[ $# -eq 1 ]] || fail "check 不接受额外参数"
        check_command
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
