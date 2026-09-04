#Requires -Version 5.1

<#
.SYNOPSIS
    桂林电子科技大学（GUET）校园网 Dr.COM 认证辅助工具（Windows / PowerShell 版）。

.DESCRIPTION
    guet_drcom.sh 的 Windows 移植版，通过模拟 Dr.COM Portal 的 HTTP 请求实现
    校园网自动登录、注销、掉线检测与自动重连（借助 Windows 计划任务常驻）。

    本版本（router 分支）面向「校园网口下串接路由器，设备接在 LAN 侧」的场景：
    认证门户看到的是路由器 WAN 口的 IP / MAC，因此不探测本机网卡，
    改为在 init 时由用户填写路由器 WAN 口的 IPv4 / MAC。

.PARAMETER Command
    子命令：init / login / logout / auto / disable / check / help。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 init

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 login

.NOTES
    与 bash 版的差异（Windows 平台适配）：
      * 配置文件使用 JSON 格式（默认 guet_drcom.config.json）。
      * 密码使用 DPAPI 加密存储（仅生成它的 Windows 用户在本机可解密）。
      * 自动重连使用「计划任务」，而非 crontab。
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = 'help',

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    # 供计划任务调用时显式指定配置文件路径
    [string]$ConfigFile,

    # 供隐藏的计划任务将所有输出直接追加到日志，避免借助 cmd.exe 重定向
    [string]$LogFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------
# 路径与可配置项（均可通过环境变量覆盖，保持与 bash 版一致）
# --------------------------------------------------------------------------
$ScriptPath = $PSCommandPath
$ScriptDir  = $PSScriptRoot
$ScriptName = Split-Path -Leaf $PSCommandPath

if ([string]::IsNullOrEmpty($ConfigFile)) {
    if ($env:GUET_DRCOM_ENV) {
        $ConfigFile = $env:GUET_DRCOM_ENV
    } else {
        $ConfigFile = Join-Path $ScriptDir 'guet_drcom.config.json'
    }
}

$ServerIP    = if ($env:SERVER_IP)    { $env:SERVER_IP }    else { '10.0.1.5' }
$StatusUrl   = if ($env:STATUS_URL)   { $env:STATUS_URL }   else { "http://$ServerIP/" }
$LogoutUrl   = if ($env:LOGOUT_URL)   { $env:LOGOUT_URL }   else { "http://${ServerIP}:801/eportal/portal/logout" }
$LoginUrl    = if ($env:LOGIN_URL)    { $env:LOGIN_URL }    else { "http://$ServerIP/drcom/login" }
$LogoutDelay = if ($env:LOGOUT_DELAY) { [int]$env:LOGOUT_DELAY } else { 1 }
# 注销后 RADIUS 服务端需要 20~30s 缓冲，期间登录会返回 Auth Server Timeout /
# Rad:Oppp error，故登录超时放宽并允许多次重试（实测第 3 次前后成功）
$LoginTimeout    = if ($env:LOGIN_TIMEOUT)     { [int]$env:LOGIN_TIMEOUT }     else { 25 }
$LoginRetries    = if ($env:LOGIN_RETRIES)     { [int]$env:LOGIN_RETRIES }     else { 5 }
$LoginRetryDelay = if ($env:LOGIN_RETRY_DELAY) { [int]$env:LOGIN_RETRY_DELAY } else { 3 }
$DryRun      = if ($env:DRY_RUN)      { $env:DRY_RUN }      else { '0' }
$AutoLog     = if ($env:AUTO_LOG)     { $env:AUTO_LOG }     else { Join-Path $ScriptDir 'guet_drcom.log' }

$TaskName = 'GUET_DrCOM_AutoReconnect'
$HiddenLauncher = Join-Path $ScriptDir 'guet_drcom_hidden.vbs'

$CarrierNames    = @('校园网', '中国移动', '中国联通', '中国电信', '中国广电')
$CarrierSuffixes = @('', '@cmcc', '@unicom', '@telecom', '@glgd')

# 网络信息与流程状态（脚本作用域内共享）
$script:ClientIp             = ''
$script:ClientMac            = ''
$script:LogoutSucceeded      = $false
$script:SelectedCarrierId    = 0
$script:SelectedCarrierName  = ''
$script:SelectedCarrierSuffix = ''
$script:DrcomAccount         = ''
$script:DrcomPassword        = ''

# --------------------------------------------------------------------------
# 控制台初始化与颜色
# --------------------------------------------------------------------------
$ESC = [char]27
$script:UseColor = $false
$script:Reset = ''; $script:Bold = ''; $script:Dim = ''
$script:Red = ''; $script:Green = ''; $script:Yellow = ''; $script:Cyan = ''

function Initialize-Console {
    # 尽量以 UTF-8 输出，保证中文与框线字符正确
    try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

    $enable = $true
    if ($env:NO_COLOR -or -not [string]::IsNullOrEmpty($LogFile)) { $enable = $false }
    try { if ([Console]::IsOutputRedirected) { $enable = $false } } catch { }

    if ($enable) {
        # 在 Windows 控制台上启用 VT（ANSI）转义处理
        try {
            if (-not ([System.Management.Automation.PSTypeName]'GuetDrcom.Native').Type) {
                Add-Type -Namespace GuetDrcom -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleMode(System.IntPtr hConsoleHandle, out uint lpMode);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleMode(System.IntPtr hConsoleHandle, uint dwMode);
'@ | Out-Null
            }
            $handle = [GuetDrcom.Native]::GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            $mode = [uint32]0
            if ([GuetDrcom.Native]::GetConsoleMode($handle, [ref]$mode)) {
                [void][GuetDrcom.Native]::SetConsoleMode($handle, $mode -bor 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
            }
        } catch { }
    }

    $script:UseColor = $enable
    if ($enable) {
        $script:Reset  = "$ESC[0m"
        $script:Bold   = "$ESC[1m"
        $script:Dim    = "$ESC[2m"
        $script:Red    = "$ESC[31m"
        $script:Green  = "$ESC[32m"
        $script:Yellow = "$ESC[33m"
        $script:Cyan   = "$ESC[36m"
    }
}

# --------------------------------------------------------------------------
# 界面输出辅助函数
# --------------------------------------------------------------------------
function Write-Header {
    param([string]$Title)
    Write-Host ''
    Write-Host ("{0}{1}{2}" -f "$Bold$Cyan", '╭─ GUET Dr.COM ─────────────────────────╮', $Reset)
    Write-Host ("{0}  {1}{2}" -f $Bold, $Title, $Reset)
    Write-Host ("{0}{1}{2}" -f "$Bold$Cyan", '╰───────────────────────────────────────╯', $Reset)
    Write-Host ''
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ("{0}◆ {1}{2}" -f "$Bold$Cyan", $Title, $Reset)
}

function Write-Value {
    param([string]$Label, [string]$Value)
    Write-Host ("  {0}{1,-10}{2} {3}" -f $Dim, $Label, $Reset, $Value)
}

function Write-Success {
    param([string]$Message)
    Write-Host ("{0}✓{1} {2}" -f $Green, $Reset, $Message)
}

function Write-Warn {
    param([string]$Message)
    $line = "{0}!{1} {2}" -f $Yellow, $Reset, $Message
    if ([string]::IsNullOrEmpty($LogFile)) {
        [Console]::Error.WriteLine($line)
    } else {
        Write-Warning $line
    }
}

function Write-Step {
    param([string]$Label, [string]$Message)
    Write-Host ''
    Write-Host ("{0}{1}{2} {3}" -f $Cyan, $Label, $Reset, $Message)
}

function Fail {
    param([string]$Message)
    $prefix = if ($script:UseColor) { "$Red✗$Reset" } else { '✗' }
    if ([string]::IsNullOrEmpty($LogFile)) {
        [Console]::Error.WriteLine("$prefix $Message")
    } else {
        # Write-Error 会把 ErrorRecord 连同 CategoryInfo 等展开成多行写进日志；
        # 这里紧跟 exit 1，无需错误流语义，单行信息流更易读
        Write-Host "$prefix $Message"
    }
    exit 1
}

# --------------------------------------------------------------------------
# 文件权限：将文件访问限制为当前用户（近似 chmod 600）
# --------------------------------------------------------------------------
function Protect-File {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)  # 断开继承，移除继承的权限
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        Write-Warn "无法收紧 $Path 的访问权限：$($_.Exception.Message)"
    }
}

# --------------------------------------------------------------------------
# 帮助 / 状态
# --------------------------------------------------------------------------
function Show-Usage {
    $initStatus = if (Test-Path -LiteralPath $ConfigFile) { '已完成' } else { '未完成' }

    $autoStatus = '未启用'
    try {
        if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
            $autoStatus = '已启用'
        }
    } catch { }

    Write-Header '校园网认证工具'
    Write-Host ("{0}用法{1}  {2} <子命令>" -f $Bold, $Reset, $ScriptName)

    Write-Section '子命令'
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'init', $Reset, '初始化账号、密码、运营商及路由器 IP/MAC')
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'login', $Reset, '注销旧会话后重新登录')
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'logout', $Reset, '单独测试注销功能')
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'auto', $Reset, '启用每分钟自动检测与重连')
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'disable', $Reset, '关闭自动检测与重连')
    Write-Host ("  {0}{1,-9}{2} {3}" -f $Green, 'help', $Reset, '显示此帮助')

    Write-Section '当前状态'
    if ($initStatus -eq '已完成') {
        Write-Host ("  {0}●{1} init    {2}" -f $Green, $Reset, $initStatus)
    } else {
        Write-Host ("  {0}○{1} init    {2}" -f $Yellow, $Reset, $initStatus)
    }
    if ($autoStatus -eq '已启用') {
        Write-Host ("  {0}●{1} auto    {2}" -f $Green, $Reset, $autoStatus)
    } else {
        Write-Host ("  {0}○{1} auto    {2}" -f $Dim, $Reset, $autoStatus)
    }
    Write-Host ''
    Write-Host ("{0}配置文件：{1}{2}" -f $Dim, $ConfigFile, $Reset)
}

# --------------------------------------------------------------------------
# 运营商选择（方向键 TUI）
# --------------------------------------------------------------------------
function Select-Carrier {
    Write-Section '选择运营商'
    Write-Host ("{0}使用 ↑/↓ 移动，Enter 确认，也可按数字选择{1}" -f $Dim, $Reset)
    Write-Host ''

    $selected = 0
    $count = $CarrierNames.Count
    $firstDraw = $true

    while ($true) {
        if (-not $firstDraw) {
            # 相对上移光标重绘列表（等价于 bash 版的 \033[NA），控制台滚动时依然正确
            try { [Console]::SetCursorPosition(0, [Console]::CursorTop - $count) } catch { }
        }
        $firstDraw = $false
        for ($i = 0; $i -lt $count; $i++) {
            $suffix = $CarrierSuffixes[$i]
            $suffixText = if ($suffix) { " $suffix" } else { '' }
            $num = $i + 1
            if ($i -eq $selected) {
                Write-Host ("  {0}›  {1}  {2,-10}{3}{4}" -f "$Bold$Cyan", $num, $CarrierNames[$i], $suffixText, $Reset)
            } else {
                Write-Host ("     {0}  {1,-10}{2}" -f $num, $CarrierNames[$i], $suffixText)
            }
        }

        $key = [Console]::ReadKey($true)
        switch ($key.Key) {
            'UpArrow'   { $selected = ($selected + $count - 1) % $count }
            'DownArrow' { $selected = ($selected + 1) % $count }
            'Enter' {
                $script:SelectedCarrierId     = $selected + 1
                $script:SelectedCarrierName   = $CarrierNames[$selected]
                $script:SelectedCarrierSuffix = $CarrierSuffixes[$selected]
                Write-Host ''
                return
            }
            default {
                $ch = $key.KeyChar
                if ($ch -match '[1-5]') {
                    $n = [int]"$ch" - 1
                    if ($n -lt $count) { $selected = $n }
                }
            }
        }
    }
}

# --------------------------------------------------------------------------
# 初始化配置
# --------------------------------------------------------------------------
function Invoke-Init {
    try { if ([Console]::IsInputRedirected) { Fail 'init 需要在交互式终端中运行' } } catch { }

    Write-Header '初始化认证配置'

    Write-Host ("{0}学号{1}  " -f $Bold, $Reset) -NoNewline
    $studentId = Read-Host
    if ($studentId -notmatch '^[0-9]+$') { Fail '学号只能包含数字' }

    Write-Host ("{0}密码{1}  " -f $Bold, $Reset) -NoNewline
    $securePassword = Read-Host -AsSecureString
    if ($securePassword.Length -eq 0) { Fail '密码不能为空' }

    Select-Carrier
    $account = "$studentId$($script:SelectedCarrierSuffix)"

    # 认证门户看到的是路由器 WAN 口的地址，本机网卡信息无用，须由用户填写
    Write-Section '路由器 WAN 口信息'
    Write-Host ("{0}可在路由器管理页的「WAN 口状态 / 上网设置」中查看{1}" -f $Dim, $Reset)
    Write-Host ''
    Write-Host ("{0}IPv4{1}  " -f $Bold, $Reset) -NoNewline
    $routerIp = "$(Read-Host)".Trim()
    if ([string]::IsNullOrEmpty($routerIp)) { Fail '路由器 IPv4 地址不能为空' }

    Write-Host ("{0}MAC{1}   " -f $Bold, $Reset) -NoNewline
    $routerMac = "$(Read-Host)".Trim()
    if ([string]::IsNullOrEmpty($routerMac)) { Fail '路由器 MAC 地址不能为空' }

    Resolve-Network -Ip $routerIp -Mac $routerMac

    $config = [ordered]@{
        StudentId         = $studentId
        CarrierId         = $script:SelectedCarrierId
        CarrierName       = $script:SelectedCarrierName
        Account           = $account
        # DPAPI 加密：仅当前 Windows 用户在本机可解密
        PasswordEncrypted = (ConvertFrom-SecureString $securePassword)
        # 路由器 WAN 口地址；IP 变化后可直接修改此处，无需重新 init
        RouterIp          = $script:ClientIp
        RouterMac         = $script:ClientMac
    }
    $json = $config | ConvertTo-Json

    $tempFile = "$ConfigFile.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($tempFile, $json, (New-Object System.Text.UTF8Encoding($false)))
        Protect-File $tempFile
        Move-Item -LiteralPath $tempFile -Destination $ConfigFile -Force
    } finally {
        if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force }
    }

    Write-Success '初始化完成'
    Write-Value '登录账号' $account
    Write-Value '运营商' $script:SelectedCarrierName
    Show-Network
    Write-Value '配置文件' $ConfigFile
}

# --------------------------------------------------------------------------
# 加载配置
# --------------------------------------------------------------------------
function Import-Config {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Fail "找不到 $ConfigFile，请先运行 $ScriptName init"
    }

    try {
        $raw = [System.IO.File]::ReadAllText($ConfigFile)
        $config = $raw | ConvertFrom-Json
    } catch {
        Fail "$ConfigFile 解析失败：$($_.Exception.Message)"
    }

    # StrictMode 下访问不存在的属性会抛错，先判断属性是否存在
    $props = @($config.PSObject.Properties.Name)
    $account    = if ($props -contains 'Account')           { $config.Account }           else { $null }
    $encrypted  = if ($props -contains 'PasswordEncrypted') { $config.PasswordEncrypted } else { $null }
    $routerIp   = if ($props -contains 'RouterIp')          { $config.RouterIp }          else { $null }
    $routerMac  = if ($props -contains 'RouterMac')         { $config.RouterMac }         else { $null }
    if ([string]::IsNullOrEmpty($account))   { Fail "$ConfigFile 缺少 Account" }
    if ([string]::IsNullOrEmpty($encrypted)) { Fail "$ConfigFile 缺少 PasswordEncrypted" }
    if ([string]::IsNullOrEmpty($routerIp))  { Fail "$ConfigFile 缺少 RouterIp，请重新运行 $ScriptName init" }
    if ([string]::IsNullOrEmpty($routerMac)) { Fail "$ConfigFile 缺少 RouterMac，请重新运行 $ScriptName init" }

    try {
        $secure = ConvertTo-SecureString $encrypted -ErrorAction Stop
        $cred = New-Object System.Management.Automation.PSCredential('drcom', $secure)
        $script:DrcomPassword = $cred.GetNetworkCredential().Password
    } catch {
        Fail "密码解密失败（配置可能由其他用户或其他机器生成），请重新运行 $ScriptName init"
    }
    $script:DrcomAccount = $account
    Resolve-Network -Ip $routerIp -Mac $routerMac
}

# --------------------------------------------------------------------------
# 路由器 WAN 口地址：规范化并校验 IPv4 / MAC（来自 init 输入或配置文件）
# --------------------------------------------------------------------------
function Resolve-Network {
    param([string]$Ip, [string]$Mac)

    # 规范化 MAC 为 12 位小写十六进制
    $Mac = ($Mac.Trim() -replace '[:\-]', '').ToLower()
    if ($Mac -notmatch '^[0-9a-f]{12}$') { Fail "MAC 地址格式无效：$Mac" }

    $Ip = $Ip.Trim()
    if ($Ip -notmatch '^(\d{1,3}\.){3}\d{1,3}$') { Fail "IPv4 地址格式无效：$Ip" }
    foreach ($octet in $Ip.Split('.')) {
        if ([int]$octet -gt 255) { Fail "IPv4 地址格式无效：$Ip" }
    }

    $script:ClientIp  = $Ip
    $script:ClientMac = $Mac
}

function Show-Network {
    Write-Section '路由器 WAN 口信息'
    Write-Value 'IPv4' $script:ClientIp
    Write-Value 'MAC' $script:ClientMac
}

# --------------------------------------------------------------------------
# HTTP 请求
# --------------------------------------------------------------------------
function ConvertTo-Query {
    # $Pairs：形如 @(@('key','value'), ...) 的键值对数组（允许键重复、保留顺序）
    param([object[]]$Pairs)
    ($Pairs | ForEach-Object {
        '{0}={1}' -f [uri]::EscapeDataString([string]$_[0]), [uri]::EscapeDataString([string]$_[1])
    }) -join '&'
}

function Invoke-DrcomRequest {
    # -TimeoutSec：请求超时；-Tolerant：失败时返回空串而不终止脚本（供登录重试）
    param([string]$BaseUrl, [object[]]$Pairs, [int]$TimeoutSec = 8, [switch]$Tolerant)
    $url = '{0}?{1}' -f $BaseUrl, (ConvertTo-Query $Pairs)

    # 使用 HttpClient + UseProxy=$false，强制直连门户（避开系统/环境代理）。
    # 不用 Invoke-WebRequest：PS 5.1 无 -NoProxy，且 DefaultWebProxy=$null 在 .NET Framework 上仍可能回落到系统代理。
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', '*/*')
        $client.DefaultRequestHeaders.Referrer = [Uri]("http://$ServerIP/")
        $bytes = $client.GetByteArrayAsync($url).GetAwaiter().GetResult()
        return [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        if ($Tolerant) { return '' }
        Fail "请求失败：$($_.Exception.Message)"
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Send-Logout {
    param([string]$ProgressLabel = '[logout]')
    $script:LogoutSucceeded = $false
    $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

    Write-Step $ProgressLabel '正在注销当前会话…'
    $pairs = @(
        @('callback', 'dr1003'),
        @('login_method', '0'),
        @('user_account', 'drcom'),
        @('user_password', '123'),
        @('ac_logout', '1'),
        @('register_mode', '1'),
        @('wlan_user_ip', $script:ClientIp),
        @('wlan_user_ipv6', ''),
        @('wlan_vlan_id', '1'),
        @('wlan_user_mac', $script:ClientMac),
        @('wlan_ac_ip', ''),
        @('wlan_ac_name', ''),
        @('jsVersion', '4.2'),
        @('v', "$cacheBuster"),
        @('lang', 'zh')
    )
    $response = Invoke-DrcomRequest -BaseUrl $LogoutUrl -Pairs $pairs -Tolerant
    Write-Host ("  {0}服务器{1}  {2}" -f $Dim, $Reset, $(if ($response) { $response } else { '（请求失败或超时）' }))

    $compact = $response -replace '\s', ''
    # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
    if ($compact -match '"result":1([^0-9]|$)') {
        $script:LogoutSucceeded = $true
    } else {
        Write-Warn 'logout 未返回 result=1，将继续尝试登录'
    }
}

function Send-Login {
    for ($attempt = 1; ; $attempt++) {
        $cacheBuster = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $label = if ($attempt -eq 1) { '[2/2]' } else { "[2/2 第 $attempt 次]" }
        Write-Step $label '正在提交登录认证…'
        $pairs = @(
            @('callback', 'dr1004'),
            @('DDDDD', $script:DrcomAccount),
            @('upass', $script:DrcomPassword),
            @('0MKKey', '123456'),
            @('R1', '0'),
            @('R2', ''),
            @('R3', '0'),
            @('R6', '0'),
            @('para', '00'),
            @('v4ip', $script:ClientIp),
            @('v6ip', ''),
            @('terminal_type', '1'),
            @('lang', 'zh-cn'),
            @('jsVersion', '4.2'),
            @('v', "$cacheBuster"),
            @('lang', 'zh')
        )
        # -Tolerant：超时不终止脚本，交由本循环重试
        $response = Invoke-DrcomRequest -BaseUrl $LoginUrl -Pairs $pairs `
            -TimeoutSec $LoginTimeout -Tolerant
        Write-Host ("  {0}服务器{1}  {2}" -f $Dim, $Reset, $(if ($response) { $response } else { '（请求失败或超时）' }))

        $compact = $response -replace '\s', ''
        # 要求 1 后非数字，避免 "result":10 / 12 等误判为成功
        if ($compact -match '"result":1([^0-9]|$)') {
            Write-Success '登录成功'
            return
        }
        if ($attempt -ge $LoginRetries) { break }
        Write-Warn "本次未登录成功，${LoginRetryDelay}s 后重试（注销后首次认证常需等待）"
        Start-Sleep -Seconds $LoginRetryDelay
    }
    Fail "登录失败，$LoginRetries 次尝试均未返回 result=1"
}

# --------------------------------------------------------------------------
# 子命令实现
# --------------------------------------------------------------------------
function Invoke-Logout {
    Write-Header '注销校园网会话'
    Import-Config
    Show-Network

    if ($DryRun -eq '1') {
        Write-Warn 'DRY_RUN=1，未发送 logout 请求'
        return
    }

    Send-Logout '[logout]'
    if (-not $script:LogoutSucceeded) { Fail '注销失败，服务器未返回 result=1' }
    Write-Success '注销成功'
}

function Invoke-Login {
    Write-Header '登录校园网'
    Import-Config
    Show-Network
    Write-Value '登录账号' $script:DrcomAccount

    if ($DryRun -eq '1') {
        Write-Warn 'DRY_RUN=1，未发送 logout/login 请求'
        return
    }

    Send-Logout '[1/2]'
    if ($LogoutDelay -ne 0) { Start-Sleep -Seconds $LogoutDelay }
    Send-Login
}

function Invoke-Check {
    # 注册代码页编码提供程序（PowerShell 7 / .NET Core 需要，才能使用 GBK）
    try {
        [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
    } catch { }
    $gbk = $null
    try { $gbk = [System.Text.Encoding]::GetEncoding(936) } catch { }

    $online = $false
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        # UseProxy=$false：状态检测同样须直连，避免代理返回非门户页面导致误判
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $false
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(8)
        try {
            $bytes = $client.GetByteArrayAsync($StatusUrl).GetAwaiter().GetResult()
        } finally {
            $client.Dispose()
            $handler.Dispose()
        }
        $page = if ($gbk) { $gbk.GetString($bytes) } else { [System.Text.Encoding]::UTF8.GetString($bytes) }
        if ($page -like '*注销页*') { $online = $true }
    } catch {
        $online = $false
    }

    if ($online) { return }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] 未检测到`"注销页`"，开始重新登录。"
    Invoke-Login
}

function Invoke-Auto {
    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Fail "找不到 $ConfigFile，请先运行 $ScriptName init"
    }
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        Fail '找不到计划任务相关命令（ScheduledTasks 模块），无法启用自动重连'
    }

    # 准备日志文件并收紧权限
    if (-not (Test-Path -LiteralPath $AutoLog)) {
        New-Item -ItemType File -Path $AutoLog -Force | Out-Null
    }
    Protect-File $AutoLog

    # 使用当前 PowerShell 解释器（powershell.exe 或 pwsh.exe）
    $psExe = (Get-Process -Id $PID).Path
    if ([string]::IsNullOrEmpty($psExe)) { $psExe = 'powershell.exe' }

    # powershell.exe 属于控制台程序，即使传入 -WindowStyle Hidden，也可能在读取参数前
    # 短暂显示窗口。改由 GUI 子系统的 wscript.exe 启动，并用窗口样式 0 隐藏子进程。
    $launcherContent = @'
Option Explicit

Dim args, shell, command, exitCode
Set args = WScript.Arguments
If args.Count <> 4 Then WScript.Quit 2

command = QuoteArgument(args(0)) & _
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & QuoteArgument(args(1)) & _
    " check -ConfigFile " & QuoteArgument(args(2)) & _
    " -LogFile " & QuoteArgument(args(3))

Set shell = CreateObject("WScript.Shell")
exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function QuoteArgument(ByVal value)
    QuoteArgument = Chr(34) & value & Chr(34)
End Function
'@
    $launcherTemp = "$HiddenLauncher.tmp.$PID"
    try {
        [System.IO.File]::WriteAllText($launcherTemp, $launcherContent, [System.Text.Encoding]::ASCII)
        Protect-File $launcherTemp
        Move-Item -LiteralPath $launcherTemp -Destination $HiddenLauncher -Force
    } catch {
        Fail "无法创建隐藏启动器 $HiddenLauncher：$($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $launcherTemp) { Remove-Item -LiteralPath $launcherTemp -Force }
    }

    $wscriptExe = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $wscriptExe)) {
        $wscriptCommand = Get-Command wscript.exe -ErrorAction SilentlyContinue
        $wscriptExe = if ($wscriptCommand) { $wscriptCommand.Source } else { '' }
    }
    if ([string]::IsNullOrEmpty($wscriptExe)) {
        Fail '找不到 wscript.exe，无法创建无窗口的自动重连任务'
    }

    # Windows 文件名本身不能包含双引号，因此逐项加引号即可安全传给 WScript。
    $taskArgs = '//B //NoLogo "{0}" "{1}" "{2}" "{3}" "{4}"' -f $HiddenLauncher, $psExe, $ScriptPath, $ConfigFile, $AutoLog
    $action  = New-ScheduledTaskAction -Execute $wscriptExe -Argument $taskArgs
    # RepetitionDuration 用 10 年的长跨度；MaxValue 在部分 Windows 上会报参数越界
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 3650)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal `
        -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
        -LogonType Interactive -RunLevel Limited

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
            -Settings $settings -Principal $principal -Force -ErrorAction Stop | Out-Null
    } catch {
        Fail "注册计划任务失败（如为权限问题，请以管理员身份运行 PowerShell 重试）：$($_.Exception.Message)"
    }

    Write-Header '自动重连'
    Write-Success '计划任务已启用，每分钟检查一次'
    Write-Value '任务名称' $TaskName
    Write-Value '配置文件' $ConfigFile
    Write-Value '日志文件' $AutoLog
    Write-Value '运行方式' 'WScript 隐藏后台运行'
    Write-Value '查看任务' "Get-ScheduledTask -TaskName $TaskName"
}

function Invoke-Disable {
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        Fail '找不到计划任务相关命令（ScheduledTasks 模块）'
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Warn '自动重连任务尚未启用，无需移除'
        return
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
    } catch {
        Fail "移除计划任务失败：$($_.Exception.Message)"
    }

    if (Test-Path -LiteralPath $HiddenLauncher) {
        try {
            Remove-Item -LiteralPath $HiddenLauncher -Force -ErrorAction Stop
        } catch {
            Write-Warn "计划任务已关闭，但无法删除隐藏启动器 $HiddenLauncher：$($_.Exception.Message)"
        }
    }

    Write-Header '自动重连'
    Write-Success '计划任务已关闭，其他计划任务未修改'
}

# --------------------------------------------------------------------------
# 主入口
# --------------------------------------------------------------------------
function Assert-NoExtraArgs {
    param([string]$Cmd)
    if ($null -ne $Rest -and $Rest.Count -gt 0) {
        Fail "$Cmd 不接受额外参数"
    }
}

function Invoke-Main {
    switch ($Command) {
        'init'    { Assert-NoExtraArgs 'init';    Invoke-Init }
        'login'   { Assert-NoExtraArgs 'login';   Invoke-Login }
        'logout'  { Assert-NoExtraArgs 'logout';  Invoke-Logout }
        'auto'    { Assert-NoExtraArgs 'auto';    Invoke-Auto }
        'disable' { Assert-NoExtraArgs 'disable'; Invoke-Disable }
        'check'   { Assert-NoExtraArgs 'check';   Invoke-Check }
        'help'    { Show-Usage }
        default   { Show-Usage; exit 2 }
    }
}

Initialize-Console

if ([string]::IsNullOrEmpty($LogFile)) {
    Invoke-Main
} else {
    # PowerShell 5.1 的 *>> 同时捕获成功、错误、警告和 Write-Host 信息流。
    # 重定向底层是 Out-File，PS 5.1 默认写 UTF-16LE；统一为 UTF-8，
    # 避免与 pwsh 7（默认 UTF-8）混用时同一日志文件出现两种编码。
    $PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
    & { Invoke-Main } *>> $LogFile
}
