#!/bin/sh
# GUET Dr.COM ZTE ONU edition
# Target: old BusyBox ash environments used by ZTE ONU firmware.
# Avoids Bash-only syntax, dirname, command -v, and iconv dependencies.

SERVER_IP=${SERVER_IP:-10.0.1.5}
STATUS_URL=${STATUS_URL:-http://${SERVER_IP}/}
LOGOUT_URL=${LOGOUT_URL:-http://${SERVER_IP}:801/eportal/portal/logout}
LOGIN_URL=${LOGIN_URL:-http://${SERVER_IP}/drcom/login}
LOGOUT_DELAY=${LOGOUT_DELAY:-6}
DRY_RUN=${DRY_RUN:-0}

SCRIPT_PATH=$0
case "$SCRIPT_PATH" in
    */*)
        SCRIPT_DIR=${SCRIPT_PATH%/*}
        SCRIPT_NAME=${SCRIPT_PATH##*/}
        ;;
    *)
        SCRIPT_DIR=.
        SCRIPT_NAME=$SCRIPT_PATH
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd "$SCRIPT_DIR" 2>/dev/null && pwd)
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR=.
SCRIPT_PATH="$SCRIPT_DIR/$SCRIPT_NAME"
CONFIG_FILE=${GUET_DRCOM_ENV:-"$SCRIPT_DIR/.env"}
AUTO_LOG=${AUTO_LOG:-"/tmp/guet_drcom.log"}
AUTO_PID=${AUTO_PID:-"/tmp/guet_drcom.pid"}
AUTO_INTERVAL=${AUTO_INTERVAL:-60}

# GBK bytes for the text: 注销页
STATUS_MARKER_GBK=$(printf '\327\242\317\372\322\263')
STATUS_MARKER_UTF8='注销页'

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'WARN: %s\n' "$*" >&2
}

info() {
    printf '%s\n' "$*"
}

require_cmd() {
    type "$1" >/dev/null 2>&1 || fail "找不到命令: $1"
}

usage() {
    init_status='未完成'
    auto_status='未启用'

    [ -f "$CONFIG_FILE" ] && init_status='已完成'
    if auto_is_running; then
        auto_status='已启用'
    fi

    cat <<EOF_USAGE
GUET Dr.COM 路由器版 (BusyBox ash)

用法:
  $SCRIPT_NAME init       初始化学号、密码、运营商
  $SCRIPT_NAME login      注销旧会话并重新登录
  $SCRIPT_NAME logout     注销当前会话
  $SCRIPT_NAME check      检测在线状态，掉线则重连
  $SCRIPT_NAME auto       后台循环自动检测与重连
  $SCRIPT_NAME status     查看自动重连状态
  $SCRIPT_NAME disable    停止自动重连
  $SCRIPT_NAME diag       查看到认证服务器的路由/接口信息
  $SCRIPT_NAME help       显示帮助

状态:
  init: $init_status
  auto: $auto_status

配置文件: $CONFIG_FILE
日志文件: $AUTO_LOG
PID 文件: $AUTO_PID
检测间隔: ${AUTO_INTERVAL} 秒
EOF_USAGE
}

carrier_from_id() {
    case "$1" in
        1)
            SELECTED_CARRIER_NAME='校园网'
            SELECTED_CARRIER_SUFFIX=''
            ;;
        2)
            SELECTED_CARRIER_NAME='中国移动'
            SELECTED_CARRIER_SUFFIX='@cmcc'
            ;;
        3)
            SELECTED_CARRIER_NAME='中国联通'
            SELECTED_CARRIER_SUFFIX='@unicom'
            ;;
        4)
            SELECTED_CARRIER_NAME='中国电信'
            SELECTED_CARRIER_SUFFIX='@telecom'
            ;;
        5)
            SELECTED_CARRIER_NAME='中国广电'
            SELECTED_CARRIER_SUFFIX='@glgd'
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

select_carrier() {
    while :; do
        cat <<'EOF_CARRIER'

请选择运营商:
  1) 校园网
  2) 中国移动  @cmcc
  3) 中国联通  @unicom
  4) 中国电信  @telecom
  5) 中国广电  @glgd
EOF_CARRIER
        printf '请输入 [1-5]: '
        IFS= read -r SELECTED_CARRIER_ID || fail '读取运营商选择失败'
        if carrier_from_id "$SELECTED_CARRIER_ID"; then
            return 0
        fi
        warn '请输入 1 到 5'
    done
}

restore_tty() {
    if [ -n "${SAVED_STTY:-}" ]; then
        stty "$SAVED_STTY" 2>/dev/null || true
        SAVED_STTY=''
    fi
}

read_password() {
    password=''
    SAVED_STTY=''

    if [ -t 0 ] && type stty >/dev/null 2>&1; then
        SAVED_STTY=$(stty -g 2>/dev/null || true)
    fi

    printf '密码: '
    if [ -n "$SAVED_STTY" ]; then
        trap 'restore_tty; printf "\n" >&2; exit 130' HUP INT TERM
        stty -echo 2>/dev/null || SAVED_STTY=''
    fi

    IFS= read -r password
    read_status=$?

    if [ -n "$SAVED_STTY" ]; then
        restore_tty
        trap - HUP INT TERM
        printf '\n'
    fi

    [ "$read_status" -eq 0 ] || fail '读取密码失败'
    [ -n "$password" ] || fail '密码不能为空'
}

init_command() {
    printf '学号: '
    IFS= read -r student_id || fail '读取学号失败'

    [ -n "$student_id" ] || fail '学号不能为空'
    if ! printf '%s\n' "$student_id" | grep -Eq '^[0-9]+$'; then
        fail '学号只能包含数字'
    fi

    read_password
    select_carrier

    account="${student_id}${SELECTED_CARRIER_SUFFIX}"
    temp_file="${CONFIG_FILE}.tmp.$$"
    umask 077

    if ! {
        printf '# guet_drcom_router configuration; keep this file private.\n'
        printf 'DRCOM_STUDENT_ID=%s\n' "$student_id"
        printf 'DRCOM_CARRIER_ID=%s\n' "$SELECTED_CARRIER_ID"
        printf 'DRCOM_CARRIER_NAME=%s\n' "$SELECTED_CARRIER_NAME"
        printf 'DRCOM_ACCOUNT=%s\n' "$account"
        printf 'DRCOM_PASSWORD=%s\n' "$password"
    } >"$temp_file"; then
        rm -f "$temp_file"
        fail "无法写入临时配置文件: $temp_file"
    fi

    chmod 600 "$temp_file" || {
        rm -f "$temp_file"
        fail '无法设置配置文件权限'
    }

    mv -f "$temp_file" "$CONFIG_FILE" || {
        rm -f "$temp_file"
        fail "无法保存配置文件: $CONFIG_FILE"
    }

    printf '\n初始化完成\n'
    printf '账号: %s\n' "$account"
    printf '运营商: %s\n' "$SELECTED_CARRIER_NAME"
    printf '配置: %s\n' "$CONFIG_FILE"
}

config_get() {
    key=$1
    sed -n "s/^${key}=//p" "$CONFIG_FILE" | sed -n '1p'
}

load_config() {
    [ -f "$CONFIG_FILE" ] || fail "找不到 $CONFIG_FILE，请先运行 $SCRIPT_NAME init"

    DRCOM_ACCOUNT=$(config_get DRCOM_ACCOUNT)
    DRCOM_PASSWORD=$(config_get DRCOM_PASSWORD)

    [ -n "$DRCOM_ACCOUNT" ] || fail "$CONFIG_FILE 缺少 DRCOM_ACCOUNT"
    [ -n "$DRCOM_PASSWORD" ] || fail "$CONFIG_FILE 缺少 DRCOM_PASSWORD"
}

valid_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { bad=1 }
        {
            for (i=1; i<=NF; i++) {
                if ($i !~ /^[0-9][0-9]*$/ || $i < 0 || $i > 255) bad=1
            }
        }
        END { exit bad ? 1 : 0 }
    '
}

detect_network() {
    require_cmd ip
    require_cmd awk
    require_cmd tr

    interface=${INTERFACE:-}
    client_ip=${CLIENT_IP:-}
    client_ipv6=${CLIENT_IPV6:-}
    client_mac=${CLIENT_MAC:-}
    route_info=''

    if [ -z "$interface" ] || [ -z "$client_ip" ]; then
        route_info=$(ip -4 route get "$SERVER_IP" 2>/dev/null || true)
        if [ -z "$route_info" ]; then
            fail "当前没有到认证服务器 $SERVER_IP 的 IPv4 路由。请确认 WAN 已接入校园网；可运行 $SCRIPT_NAME diag 查看。"
        fi

        if [ -z "$interface" ]; then
            interface=$(printf '%s\n' "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
        fi
        if [ -z "$client_ip" ]; then
            client_ip=$(printf '%s\n' "$route_info" | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}')
        fi
    fi

    [ -n "$interface" ] || fail "无法确定通往 $SERVER_IP 的网络接口"
    [ -n "$client_ip" ] || fail "无法读取接口 $interface 的 IPv4 地址"

    if [ -z "$client_mac" ]; then
        client_mac=$(ip link show dev "$interface" 2>/dev/null | awk '/link\/ether/{print $2; exit}')
    fi
    [ -n "$client_mac" ] || fail "无法读取接口 $interface 的 MAC 地址"

    if [ -z "$client_ipv6" ]; then
        client_ipv6=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | awk '/inet6 /{sub(/\/.*/, "", $2); print $2; exit}')
    fi

    client_mac=$(printf '%s' "$client_mac" | tr -d ':-' | tr 'A-F' 'a-f')
    client_ipv6=$(printf '%s' "$client_ipv6" | sed 's/%.*$//')

    [ "${#client_mac}" -eq 12 ] || fail "MAC 地址格式无效: $client_mac"
    case "$client_mac" in
        *[!0-9a-f]*) fail "MAC 地址格式无效: $client_mac" ;;
    esac

    valid_ipv4 "$client_ip" || fail "IPv4 地址格式无效: $client_ip"
}

print_network() {
    printf '接口: %s\n' "$interface"
    printf 'IPv4: %s\n' "$client_ip"
    printf 'IPv6: %s\n' "${client_ipv6:-未获取}"
    printf 'MAC: %s\n' "$client_mac"
}

has_result_one() {
    # BusyBox ash-safe: avoid grep -E regex differences across old firmware.
    # Dr.COM returns JSON/JSONP where result is followed by a comma or } when it is exactly 1.
    compact=$(printf '%s' "$1" | tr -d ' \t\r\n')
    case "$compact" in
        *'"result":1,'*|*'"result":1}'*) return 0 ;;
        *) return 1 ;;
    esac
}

send_logout() {
    progress_label=${1:-'[logout]'}
    LOGOUT_SUCCEEDED=0
    cache_buster=$(date +%s)

    printf '%s 正在注销当前会话...\n' "$progress_label"

    response=$(curl --silent --show-error --get \
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
        --data-urlencode "wlan_user_ipv6=$client_ipv6" \
        --data-urlencode 'wlan_vlan_id=1' \
        --data-urlencode "wlan_user_mac=$client_mac" \
        --data-urlencode 'wlan_ac_ip=' \
        --data-urlencode 'wlan_ac_name=' \
        --data-urlencode 'jsVersion=4.2' \
        --data-urlencode "v=$cache_buster" \
        --data-urlencode 'lang=zh' \
        "$LOGOUT_URL" 2>&1)
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
        warn "logout 请求失败: $response"
        return 0
    fi

    printf '服务器: %s\n' "$response"
    if has_result_one "$response"; then
        LOGOUT_SUCCEEDED=1
    else
        warn 'logout 未返回 result=1，将继续尝试登录'
    fi
}

send_login() {
    cache_buster=$(date +%s)
    printf '[2/2] 正在提交登录认证...\n'

    response=$(curl --silent --show-error --get \
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
        --data-urlencode "v6ip=$client_ipv6" \
        --data-urlencode 'terminal_type=1' \
        --data-urlencode 'lang=zh-cn' \
        --data-urlencode 'jsVersion=4.2' \
        --data-urlencode "v=$cache_buster" \
        --data-urlencode 'lang=zh' \
        "$LOGIN_URL" 2>&1)
    curl_status=$?

    [ "$curl_status" -eq 0 ] || fail "登录请求失败: $response"

    printf '服务器: %s\n' "$response"
    has_result_one "$response" || fail '登录失败，服务器未返回 result=1'
    info '登录成功'
}

logout_command() {
    require_cmd curl
    detect_network
    print_network

    if [ "$DRY_RUN" = '1' ]; then
        warn 'DRY_RUN=1，未发送 logout 请求'
        return 0
    fi

    send_logout '[logout]'
    [ "$LOGOUT_SUCCEEDED" = '1' ] || fail '注销失败，服务器未返回 result=1'
    info '注销成功'
}

login_command() {
    require_cmd curl
    load_config
    detect_network
    print_network
    printf '账号: %s\n' "$DRCOM_ACCOUNT"

    if [ "$DRY_RUN" = '1' ]; then
        warn 'DRY_RUN=1，未发送 logout/login 请求'
        return 0
    fi

    send_logout '[1/2]'
    [ "$LOGOUT_DELAY" = '0' ] || sleep "$LOGOUT_DELAY"
    send_login
}

page_is_online() {
    page=$1
    if printf '%s' "$page" | grep -Fq "$STATUS_MARKER_UTF8"; then
        return 0
    fi
    if printf '%s' "$page" | grep -Fq "$STATUS_MARKER_GBK"; then
        return 0
    fi
    return 1
}

check_command() {
    require_cmd curl
    require_cmd ip
    require_cmd grep

    # If there is no route to the campus portal, a login attempt cannot work either.
    if ! ip -4 route get "$SERVER_IP" >/dev/null 2>&1; then
        printf '[%s] 无法路由到 %s，跳过本次认证。\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SERVER_IP"
        return 1
    fi

    page=$(curl --silent --show-error \
        --noproxy '*' \
        --connect-timeout 5 \
        --max-time 8 \
        "$STATUS_URL" 2>/dev/null || true)

    if [ -n "$page" ] && page_is_online "$page"; then
        return 0
    fi

    printf '[%s] 未检测到在线状态，开始重新登录。\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    login_command
}

safe_auto_path() {
    case "$1" in
        ''|*[!A-Za-z0-9_./:-]*) return 1 ;;
        *) return 0 ;;
    esac
}

auto_read_pid() {
    [ -f "$AUTO_PID" ] || return 1
    auto_pid=$(sed -n '1p' "$AUTO_PID" 2>/dev/null)
    case "$auto_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    return 0
}

auto_is_running() {
    auto_read_pid || return 1
    kill -0 "$auto_pid" 2>/dev/null
}

auto_command() {
    [ -f "$CONFIG_FILE" ] || fail "找不到 $CONFIG_FILE，请先运行 $SCRIPT_NAME init"

    safe_auto_path "$SCRIPT_PATH" || fail "脚本路径含空格或特殊字符，请移动到简单路径后再启用 auto: $SCRIPT_PATH"
    safe_auto_path "$CONFIG_FILE" || fail "配置路径含空格或特殊字符: $CONFIG_FILE"
    safe_auto_path "$AUTO_LOG" || fail "日志路径含空格或特殊字符: $AUTO_LOG"
    safe_auto_path "$AUTO_PID" || fail "PID 路径含空格或特殊字符: $AUTO_PID"

    case "$AUTO_INTERVAL" in
        ''|*[!0-9]*) fail "AUTO_INTERVAL 必须是正整数秒数" ;;
        0) fail "AUTO_INTERVAL 必须大于 0" ;;
    esac

    if auto_is_running; then
        info "自动重连已经运行，PID: $auto_pid"
        printf '日志: %s\n' "$AUTO_LOG"
        return 0
    fi

    rm -f "$AUTO_PID"
    umask 077
    : >>"$AUTO_LOG" || fail "无法创建日志文件: $AUTO_LOG"
    chmod 600 "$AUTO_LOG" 2>/dev/null || true

    (
        trap '' HUP
        printf '[%s] auto loop started, interval=%ss\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$AUTO_INTERVAL" >>"$AUTO_LOG"
        while :; do
            GUET_DRCOM_ENV="$CONFIG_FILE" AUTO_LOG="$AUTO_LOG" /bin/sh "$SCRIPT_PATH" check >>"$AUTO_LOG" 2>&1
            sleep "$AUTO_INTERVAL"
        done
    ) </dev/null >/dev/null 2>&1 &

    auto_pid=$!
    printf '%s\n' "$auto_pid" >"$AUTO_PID" || {
        kill "$auto_pid" 2>/dev/null || true
        fail "无法写入 PID 文件: $AUTO_PID"
    }

    sleep 1
    if ! kill -0 "$auto_pid" 2>/dev/null; then
        rm -f "$AUTO_PID"
        fail "自动重连后台进程启动失败，请查看日志: $AUTO_LOG"
    fi

    info "自动重连已启用：每 $AUTO_INTERVAL 秒检查一次"
    printf 'PID: %s\n' "$auto_pid"
    printf '日志: %s\n' "$AUTO_LOG"
}

status_command() {
    if auto_is_running; then
        printf '自动重连: 运行中\n'
        printf 'PID: %s\n' "$auto_pid"
        printf '检测间隔: %s 秒\n' "$AUTO_INTERVAL"
        printf '日志: %s\n' "$AUTO_LOG"
        return 0
    fi

    printf '自动重连: 未运行\n'
    [ ! -f "$AUTO_PID" ] || printf '检测到无效 PID 文件: %s\n' "$AUTO_PID"
    return 1
}

disable_command() {
    if ! auto_is_running; then
        rm -f "$AUTO_PID"
        warn '自动重连尚未运行'
        return 0
    fi

    pid=$auto_pid
    kill "$pid" 2>/dev/null || fail "无法停止自动重连进程 PID $pid"
    rm -f "$AUTO_PID"
    printf '[%s] auto loop stopped, pid=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$pid" >>"$AUTO_LOG"
    info "自动重连已关闭，PID: $pid"
}

diag_command() {
    require_cmd ip

    printf '系统: '
    uname -a
    printf 'Shell: %s\n' "${SHELL:-/bin/sh}"
    printf '认证服务器: %s\n' "$SERVER_IP"

    printf '\n=== route to %s ===\n' "$SERVER_IP"
    ip -4 route get "$SERVER_IP" 2>&1 || true

    printf '\n=== default route ===\n'
    ip -4 route show default 2>&1 || true

    printf '\n=== IPv4 addresses ===\n'
    ip -4 addr show 2>&1 || true
}

assert_no_extra_args() {
    [ "$#" -eq 1 ] || fail "$1 不接受额外参数"
}

case ${1:-help} in
    init)
        assert_no_extra_args "$@"
        init_command
        ;;
    login)
        assert_no_extra_args "$@"
        login_command
        ;;
    logout)
        assert_no_extra_args "$@"
        logout_command
        ;;
    check)
        assert_no_extra_args "$@"
        check_command
        ;;
    auto)
        assert_no_extra_args "$@"
        auto_command
        ;;
    status)
        assert_no_extra_args "$@"
        status_command
        ;;
    disable)
        assert_no_extra_args "$@"
        disable_command
        ;;
    diag)
        assert_no_extra_args "$@"
        diag_command
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac