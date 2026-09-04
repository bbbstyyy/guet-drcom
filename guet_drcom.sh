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
# 注销后 RADIUS 服务端需要 20~30s 缓冲，期间登录会返回 Auth Server Timeout /
# Rad:Oppp error，故登录超时放宽并允许多次重试（实测第 3 次前后成功）
LOGIN_TIMEOUT=${LOGIN_TIMEOUT:-25}
LOGIN_RETRIES=${LOGIN_RETRIES:-5}
LOGIN_RETRY_DELAY=${LOGIN_RETRY_DELAY:-3}
DRY_RUN=${DRY_RUN:-0}
AUTO_LOG=${AUTO_LOG:-"$SCRIPT_DIR/guet_drcom.log"}
# cron 每分钟追加一次；持续掉线时每次写约 20 行，超过此字节数轮转为 .1
AUTO_LOG_MAX=${AUTO_LOG_MAX:-1048576}

# cron 的 PATH 与登录 shell 不同，auto 时按这份 PATH 校验依赖
CRON_PATH='/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'
CRON_TAG='# guet_drcom-auto'
# check 的自我互斥锁；同一配置文件即同一账号，故由配置文件路径派生
LOCK_DIR="${CONFIG_FILE}.lock"
# 持有者进程已消失、或持锁超过此秒数，即视为崩溃残留，可被抢占
LOCK_STALE=${LOCK_STALE:-600}

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

# 检测与删除必须用同一口径，否则行尾多一个空格或 CR（手动编辑过、
# 或 crontab 来自 Windows）就会一边报「已启用」、一边删不掉：auto 重复
# 追加任务，disable 谎报已关闭。两者都用 grep -F 的子串语义。
cron_has_tag() {
    grep -Fq -- "$CRON_TAG"
}

cron_without_tag() {
    awk -v tag="$CRON_TAG" 'index($0, tag) == 0'
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
        && crontab -l 2>/dev/null | cron_has_tag; then
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
        "$LOGOUT_URL") || response=''
    printf '  %b服务器%b  %s\n' "$DIM" "$RESET" "${response:-（请求失败或超时）}"

    compact=$(tr -d '[:space:]' <<<"$response")
    # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
    if [[ $compact =~ \"result\":1([^0-9]|$) ]]; then
        LOGOUT_SUCCEEDED=1
    else
        ui_warning 'logout 未返回 result=1，将继续尝试登录'
    fi
}

# $1 进度标签，$2 最大尝试次数。成功返回 0，失败返回 1 而不终止脚本，
# 由调用方决定接下来是「注销后重来」还是直接报错退出
send_login() {
    local label_prefix=$1 retries=$2
    local attempt=1 cache_buster response compact label

    while :; do
        cache_buster=$(date +%s)
        label=$label_prefix
        ((attempt == 1)) || label="${label_prefix%]} 第 $attempt 次]"
        ui_step "$label" '正在提交登录认证…'
        # --noproxy '*': 校园认证须直连门户，避免 http_proxy / 系统代理劫持
        # curl 失败（多为超时）不直接中断脚本，交由下面的重试逻辑处理
        response=$(curl --silent --show-error --compressed --get \
            --noproxy '*' \
            --connect-timeout 5 \
            --max-time "$LOGIN_TIMEOUT" \
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
            "$LOGIN_URL") || response=''
        printf '  %b服务器%b  %s\n' "$DIM" "$RESET" "${response:-（请求失败或超时）}"

        compact=$(tr -d '[:space:]' <<<"$response")
        # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
        if [[ $compact =~ \"result\":1([^0-9]|$) ]]; then
            ui_success '登录成功'
            return 0
        fi

        ((attempt < retries)) || return 1
        ui_warning "本次未登录成功，${LOGIN_RETRY_DELAY}s 后重试（注销后首次认证常需等待）"
        sleep "$LOGIN_RETRY_DELAY"
        attempt=$((attempt + 1))
    done
}

# check 与 login 共用的完整重连流程：注销 → 等待缓冲 → 按完整重试次数登录
logout_then_login() {
    send_logout "$1"
    [[ $LOGOUT_DELAY == 0 ]] || sleep "$LOGOUT_DELAY"
    send_login "$2" "$LOGIN_RETRIES" \
        || fail "登录失败，${LOGIN_RETRIES} 次尝试均未返回 result=1"
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
    # 手动 login 总是先注销，确保清掉服务端可能残留的旧会话
    logout_then_login '[1/2]' '[2/2]'
}

# cron 每分钟触发一次，而单次 check 最坏要跑两三分钟（登录重试到底）。
# 不互斥的话，后一个实例的 logout 会拆掉前一个正在建立的会话，双方都失败，
# 而每分钟又叠加一个新实例，形成越等越连不上的死循环。
acquire_lock() {
    local holder='' started=0 now

    now=$(date +%s)
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        # 2>/dev/null 必须写在输入重定向之前：否则 pid 文件不存在时（断电留下
        # 空锁目录），重定向失败的报错会先泄漏到 stderr，污染 auto 日志
        read -r holder started 2>/dev/null <"$LOCK_DIR/pid" || true
        # 锁文件可能因断电等原因只写了一半，非数字时按最早时间处理
        [[ $started =~ ^[0-9]+$ ]] || started=0
        # 持有者仍在运行且未超时就让位，否则按崩溃/断电的残留锁抢占
        if [[ $holder =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null \
            && ((now - started < LOCK_STALE)); then
            return 1
        fi
        rm -rf -- "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || return 1
    fi

    printf '%s %s\n' "$$" "$now" >"$LOCK_DIR/pid"
    trap 'rm -rf -- "$LOCK_DIR"' EXIT
}

# 本次输出已被 cron 重定向到 AUTO_LOG，轮转后本轮仍写进旧 inode（即 .1），
# 下一次 cron 才会打开新文件；放在最前面做即可，不影响正确性
rotate_auto_log() {
    local size

    [[ -f $AUTO_LOG ]] || return 0
    size=$(wc -c <"$AUTO_LOG" 2>/dev/null || echo 0)
    ((size > AUTO_LOG_MAX)) || return 0
    mv -f -- "$AUTO_LOG" "$AUTO_LOG.1" 2>/dev/null || true
}

check_command() {
    local page

    command -v curl >/dev/null 2>&1 || fail "找不到 curl 命令"
    command -v iconv >/dev/null 2>&1 || fail "找不到 iconv 命令"

    rotate_auto_log
    if ! acquire_lock; then
        printf '[%s] 上一轮 check 仍在运行，跳过本次。\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        return
    fi

    # iconv -c 丢弃非法字节继续转换，并且一律忽略退出码：响应被 --max-time
    # 截断时 -c 仍会返回 1，若让它参与判断（叠加 pipefail），页面里明明有
    # 「注销页」也会被判成离线，进而把一个健康的会话注销掉
    page=$(curl --silent --show-error \
        --noproxy '*' \
        --connect-timeout 5 \
        --max-time 8 \
        "$STATUS_URL" 2>/dev/null | iconv -c -f GBK -t UTF-8 2>/dev/null) || true
    if [[ $page == *'注销页'* ]]; then
        return
    fi

    printf '[%s] 未检测到“注销页”，开始重新登录。\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    ui_header '自动重连'
    load_config
    print_network
    ui_value '登录账号' "$DRCOM_ACCOUNT"

    if [[ $DRY_RUN == 1 ]]; then
        ui_warning 'DRY_RUN=1，未发送 logout/login 请求'
        return
    fi

    # 状态探测仍可能误判（门户抖动、响应超时），所以先只试一次直接登录：
    # 会话其实还在的话这次多半直接成功，不会动到它；即便门户拒绝，也只是退回
    # 下面的注销重连，不比原来更差。
    if send_login '[直接登录]' 1; then
        return
    fi
    logout_then_login '[注销]' '[重新登录]'
}

# macOS 的 TCC 会拦住 cron 读取 ~/Desktop、~/Documents、~/Downloads 下的文件，
# 症状是定时任务静默失效、日志一直没有新内容
warn_macos_tcc() {
    local protected=1

    [[ $(uname -s) == Darwin ]] || return 0
    # 该文件系统默认大小写不敏感，PWD 里的大小写未必与真实目录名一致
    shopt -s nocasematch
    case $SCRIPT_DIR/ in
        "$HOME"/Desktop/*|"$HOME"/Documents/*|"$HOME"/Downloads/*) protected=0 ;;
    esac
    shopt -u nocasematch
    ((protected == 0)) || return 0

    ui_warning "本项目位于 macOS 受隐私保护的目录：$SCRIPT_DIR"
    ui_warning '若日志长期没有新内容，请在「系统设置 → 隐私与安全性 → 完全磁盘'
    ui_warning '访问权限」中添加 /usr/sbin/cron，或把项目移到该限制之外的目录。'
}

auto_command() {
    local existing filtered cron_line tool
    local script_quoted config_quoted log_quoted

    [[ -f $CONFIG_FILE ]] || fail "找不到 ${CONFIG_FILE}，请先运行 $(basename "$0") init"
    command -v crontab >/dev/null 2>&1 || fail "找不到 crontab 命令"

    # cron 的 PATH 比登录 shell 窄（Homebrew 常在 /opt/homebrew/bin），故按 cron
    # 实际使用的 PATH 校验；否则终端里跑得通，而定时任务每分钟静默失败一次。
    # 子 shell 内 hash -r 清掉命令缓存，避免拿登录 shell 的缓存路径误判存在。
    for tool in curl iconv; do
        (PATH=$CRON_PATH; hash -r; command -v "$tool" >/dev/null 2>&1) \
            || fail "cron 的 PATH（${CRON_PATH}）中找不到 ${tool}，请将其装入上述目录之一"
    done

    # crontab 会把命令中的 % 转成换行，把 cron 行拆坏；%q 并不转义它
    case $SCRIPT_PATH$CONFIG_FILE$AUTO_LOG in
        *%*) fail "路径含 % 字符，crontab 无法正确处理，请改用不含 % 的路径" ;;
    esac

    umask 077
    : >>"$AUTO_LOG"
    chmod 600 "$AUTO_LOG"

    printf -v script_quoted '%q' "$SCRIPT_PATH"
    printf -v config_quoted '%q' "$CONFIG_FILE"
    printf -v log_quoted '%q' "$AUTO_LOG"
    cron_line="* * * * * PATH=$CRON_PATH GUET_DRCOM_ENV=$config_quoted $script_quoted check >> $log_quoted 2>&1 $CRON_TAG"

    existing=$(crontab -l 2>/dev/null || true)
    filtered=$(cron_without_tag <<<"$existing")
    {
        [[ -z $filtered ]] || printf '%s\n' "$filtered"
        printf '%s\n' "$cron_line"
    } | crontab -

    ui_header '自动重连'
    ui_success '定时任务已启用，每分钟检查一次'
    ui_value '配置文件' "$CONFIG_FILE"
    ui_value '日志文件' "$AUTO_LOG"
    ui_value '查看任务' 'crontab -l'
    warn_macos_tcc
}

disable_command() {
    local existing filtered

    command -v crontab >/dev/null 2>&1 || fail "找不到 crontab 命令"
    existing=$(crontab -l 2>/dev/null || true)

    if ! cron_has_tag <<<"$existing"; then
        ui_warning '自动重连任务尚未启用，无需移除'
        return
    fi

    filtered=$(cron_without_tag <<<"$existing")
    {
        [[ -z $filtered ]] || printf '%s\n' "$filtered"
    } | crontab -

    # 正在运行的 check 会自行清理；这里只清掉崩溃/断电留下的残留锁目录
    if [[ -d $LOCK_DIR ]]; then
        rm -rf -- "$LOCK_DIR"
    fi

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
