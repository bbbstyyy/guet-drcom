# GUET Dr.COM 校园网认证工具

桂林电子科技大学（GUET）校园网 Dr.COM 认证辅助脚本，提供自动登录、注销、掉线检测与自动重连。

- **`guet_drcom.sh`** — macOS / Linux（bash）版本，使用 crontab 保活。
- **`guet_drcom.ps1`** — Windows（PowerShell）版本，使用「计划任务」保活。
- **`guet_drcom.bat`** — Windows 启动器：双击出菜单，免敲 PowerShell 参数。

两者协议、字段、交互流程完全一致，可按平台任选其一。

---

## macOS / Linux 版（guet_drcom.sh）

### 环境要求

- macOS 或 Linux（bash 脚本）
- 需安装 `curl`、`iconv`（可选 `iproute2` / `net-tools`）
- 无需额外依赖

### 快速开始

**推荐方式**：直接在脚本目录下使用

```bash
./guet_drcom.sh init          # 交互式初始化学号/密码/运营商
./guet_drcom.sh login         # 注销旧会话后登录
./guet_drcom.sh auto           # 启用每分钟自动检测与重连（强烈推荐）
./guet_drcom.sh disable        # 关闭自动重连
./guet_drcom.sh check          # 手动检测掉线并重连
./guet_drcom.sh logout         # 单独注销
./guet_drcom.sh help           # 显示帮助
```

### 子命令

| 命令     | 作用                     |
|----------|--------------------------|
| `init`   | 交互式录入学号、密码、运营商，生成 `.env` 配置文件 |
| `login`  | 注销旧会话后重新登录     |
| `logout` | 单独测试注销功能         |
| `auto`   | 注册 crontab 每分钟自动检测与重连 |
| `disable`| 移除自动重连 crontab     |
| `check`  | 检测是否在线，掉线则自动登录 |
| `help`   | 显示帮助与当前状态       |

### 运营商

初始化时用 ↑/↓ 或数字 1-5 选择，对应账号后缀：

| 选项 | 运营商     | 账号后缀 |
|------|------------|----------|
| 1    | 校园网     | （无）   |
| 2    | 中国移动   | `@cmcc` |
| 3    | 中国联通   | `@unicom` |
| 4    | 中国电信   | `@telecom` |
| 5    | 中国广电   | `@glgd` |

### 与 Windows 版的主要差异

| 方面         | macOS/Linux (bash)          | Windows (PowerShell)              |
|--------------|-----------------------------|----------------------------------|
| 配置文件     | `.env`（`chmod 600`）       | `guet_drcom.config.json`         |
| 密码存储     | 明文转义后存储              | **DPAPI 加密**（仅本机当前用户可用） |
| 自动保活     | crontab（`* * * * *`）      | 计划任务 + 隐藏 VBS 启动         |
| 网络探测     | `route` / `ip` / `ifconfig` | `Find-NetRoute` / `Get-NetAdapter` |
| GBK 解码     | `iconv`                     | `.NET` `Encoding.GetEncoding(936)` |

> **重要**：bash 版密码明文存储在 `.env` 文件中，请确保 `chmod 600`，仅限自己使用。Windows 版密码绑定当前用户 + 本机。

### 环境变量（可选覆盖）

支持以下环境变量覆盖默认值（与 Windows 版完全一致）：

- `SERVER_IP`
- `STATUS_URL`
- `LOGIN_URL`
- `LOGOUT_URL`
- `LOGOUT_DELAY`
- `DRY_RUN`
- `AUTO_LOG`
- `GUET_DRCOM_ENV`（配置文件路径）
- `INTERFACE`、`CLIENT_IP`、`CLIENT_IPV6`、`CLIENT_MAC`（手动指定网络信息）

### 后台运行机制

`auto` 命令会将每分钟检测任务注册到 crontab，使用 `GUET_DRCOM_ENV` 环境变量指定配置文件。

### 卸载

```bash
./guet_drcom.sh disable          # 移除 crontab 任务
rm -f .guet_drcom.env            # 删除配置文件
rm -f guet_drcom.log             # 删除日志
```

---

## Windows 版（guet_drcom.ps1）

### 环境要求

- Windows 10 / 11 或 Windows Server（自带 Windows PowerShell 5.1 即可，PowerShell 7 亦可）。
- 无需额外安装，`Invoke-WebRequest`、`Find-NetRoute`、计划任务等均为系统自带。

### 快速开始

**方式一（推荐）：双击 `guet_drcom.bat`**，按菜单数字选择 init / login / auto 等操作；也可以带参数在命令行调用，参数原样转发给 PowerShell 脚本：

```bat
guet_drcom.bat login
guet_drcom.bat auto
```

**方式二：直接调用 PowerShell 脚本**，在脚本所在目录打开 PowerShell：

```powershell
# 1. 初始化：录入学号、密码、运营商（交互式）
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 init

# 2. 登录（先注销旧会话再登录）
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 login

# 3. 启用每分钟自动检测与重连
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 auto

# 查看帮助与当前状态
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 help
```

> 若已将执行策略设为允许本地脚本（`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`），可直接 `\.guet_drcom.ps1 login`。

### 子命令

| 命令 | 作用 |
|------|------|
| `init` | 交互式录入学号、密码、运营商，生成配置文件 |
| `login` | 注销旧会话后重新登录 |
| `logout` | 单独测试注销功能 |
| `auto` | 注册计划任务，每分钟检测一次并自动重连 |
| `disable` | 移除自动重连计划任务 |
| `check` | 检测是否在线，掉线则重新登录（供计划任务调用） |
| `help` | 显示帮助与状态 |

### 运营商

初始化时用 ↑/↓ 或数字 1-5 选择，对应账号后缀：

| 选项 | 运营商 | 账号后缀 |
|------|--------|----------|
| 1 | 校园网 | （无） |
| 2 | 中国移动 | `@cmcc` |
| 3 | 中国联通 | `@unicom` |
| 4 | 中国电信 | `@telecom` |
| 5 | 中国广电 | `@glgd` |

### 与 bash 版的差异

| 方面 | bash 版 | PowerShell 版 |
|------|---------|---------------|
| 配置文件 | `.env`（shell 变量，`chmod 600`） | `guet_drcom.config.json`（JSON，ACL 限当前用户） |
| 密码存储 | `printf %q` 转义后明文 | **DPAPI 加密**（仅生成它的 Windows 用户在本机可解密） |
| 自动保活 | crontab（`* * * * *`） | 计划任务 `GUET_DrCOM_AutoReconnect`（每分钟经 `wscript.exe` 隐藏启动，无窗口闪烁） |
| 网络探测 | `route`/`ip`/`ifconfig` | `Find-NetRoute`/`Get-NetAdapter`/`Get-NetIPAddress` |
| GBK 解码 | `iconv` | .NET `Encoding.GetEncoding(936)` |

> **注意**：由于密码用 DPAPI 按「当前用户 + 本机」加密，配置文件不能跨用户或跨电脑复制使用；换用户或换机需重新 `init`。计划任务也以当前用户身份运行，请确保 `auto` 时登录的就是日常使用的账户。

### 环境变量（可选覆盖）

`SERVER_IP`、`STATUS_URL`、`LOGIN_URL`、`LOGOUT_URL`、`LOGOUT_DELAY`、`DRY_RUN`、`AUTO_LOG`、`GUET_DRCOM_ENV`（配置文件路径），以及 `INTERFACE`/`CLIENT_IP`/`CLIENT_IPV6`/`CLIENT_MAC`（手动指定网络信息）。用法与 bash 版一致。

```powershell
# 示例：只探测网络、不真正发请求
$env:DRY_RUN = '1'; .\guet_drcom.ps1 login
```

### 后台运行机制与 `-LogFile`

`auto` 会在脚本目录生成隐藏启动器 `guet_drcom_hidden.vbs`，计划任务经 `wscript.exe` 调用它、以完全隐藏的窗口执行 `check -ConfigFile <配置> -LogFile <日志>`。`-LogFile` 让脚本把所有输出（含警告与错误）以 UTF-8 追加到日志文件。这两个参数供计划任务内部使用，日常无需手动指定。

> 提示：部分杀毒软件对「wscript 隐藏启动脚本」的模式较敏感。若 `auto` 启用后日志长期无新内容，可检查安全软件是否拦截了 `wscript.exe` 或删除了 `guet_drcom_hidden.vbs`。

---

## 运行示例

以下为脚本运行的终端输出截图（macOS 终端风格）。

> 说明：截图均以 `DRY_RUN=1`（干跑）模式生成，仅展示交互与输出格式，**不真实发送任何认证请求**；网络信息、账号均为模拟值。实际运行时去掉 `DRY_RUN` 即可正常登录。

<table>
<tr>
<td><b><code>./guet_drcom.sh help</code></b><br>查看帮助与当前状态<br><img src="docs/screenshot-help.png" width="100%" alt="help 运行截图" /></td>
<td><b><code>DRY_RUN=1 ./guet_drcom.sh login</code></b><br>登录流程（干跑，不发请求）<br><img src="docs/screenshot-login.png" width="100%" alt="login 运行截图" /></td>
</tr>
<tr>
<td><b><code>DRY_RUN=1 ./guet_drcom.sh logout</code></b><br>单独注销（干跑，不发请求）<br><img src="docs/screenshot-logout.png" width="100%" alt="logout 运行截图" /></td>
<td><b><code>./guet_drcom.sh auto</code></b><br>启用每分钟自动检测与重连<br><img src="docs/screenshot-auto.png" width="100%" alt="auto 运行截图" /></td>
</tr>
</table>

---

## 支持

如果你觉得这个工具对你有帮助，欢迎打赏支持！

<img src="收款码.jpg" width="200" alt="收款码" />

**感谢支持！**  
本工具免费开源，免费使用，如有帮助请支持作者！

---

## 许可证

本项目采用 [MIT License](LICENSE) 许可。

## 关于作者

本工具代码风格严格遵循 Andrej Karpathy 编码规范（极简主义），追求清晰、简洁、易维护。

**原作者**：bbbstyyy