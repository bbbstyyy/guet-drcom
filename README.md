# GUET Dr.COM 校园网认证工具

桂林电子科技大学（GUET）校园网 Dr.COM 认证辅助脚本，支持自动登录、掉线检测与自动重连，覆盖 macOS/Linux 与 Windows。

- **`guet_drcom.sh`** — macOS / Linux（bash），用 crontab 保活。
- **`guet_drcom.ps1`** — Windows（PowerShell），用「计划任务」保活。
- **`guet_drcom.bat`** — Windows 启动器：双击出菜单，免敲参数。

两个版本认证流程一致，按平台选其一即可。

> **本分支（`router`）适用于校园网口下串接了路由器的场景**：电脑等设备接在路由器 LAN 侧，认证门户看到的是路由器 WAN 口的 IP 和 MAC，本机网卡信息无用。因此本分支不再自动探测网卡，改为在 `init` 时手动填写路由器 WAN 口的 IPv4 和 MAC，之后 `login` / `logout` / `auto` 全部使用这组地址。若设备直接接入校园网（中间没有路由器），请使用 `main` 分支。

---

## 运行示例

以下为脚本运行的终端输出截图（macOS 终端风格）。

> 说明：截图均以 `DRY_RUN=1`（干跑）模式生成，仅展示交互与输出格式，**不真实发送任何认证请求**；网络信息、账号均为模拟值。实际运行去掉 `DRY_RUN` 即可正常登录。

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

## 快速开始

### macOS / Linux

在脚本目录下：

```bash
./guet_drcom.sh init      # 初始化：填学号、密码、选运营商、填路由器 WAN 口 IP/MAC
./guet_drcom.sh login     # 登录
./guet_drcom.sh auto      # 开启每分钟自动检测与重连（推荐）
./guet_drcom.sh disable   # 关闭自动重连
./guet_drcom.sh help      # 查看帮助与状态
```

### Windows

**方式一（推荐）**：双击 `guet_drcom.bat`，按菜单数字选择。

**方式二**：在脚本目录打开 PowerShell：

```powershell
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 init
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 login
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 auto
```

> 若已设为允许本地脚本（`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`），可直接 `.\guet_drcom.ps1 login`。

---

## 命令一览

| 命令 | 作用 |
|------|------|
| `init` | 交互式录入学号、密码、运营商及路由器 WAN 口 IPv4/MAC，生成配置文件 |
| `login` | 注销旧会话后重新登录 |
| `logout` | 单独注销 |
| `auto` | 注册定时任务，每分钟检测掉线并自动重连 |
| `disable` | 移除自动重连任务 |
| `check` | 检测是否在线，掉线则自动登录（供定时任务调用） |
| `help` | 显示帮助与当前状态 |

## 运营商

`init` 时用 ↑/↓ 或数字 1–5 选择，决定账号后缀：

| 选项 | 运营商 | 账号后缀 |
|------|--------|----------|
| 1 | 校园网 | （无） |
| 2 | 中国移动 | `@cmcc` |
| 3 | 中国联通 | `@unicom` |
| 4 | 中国电信 | `@telecom` |
| 5 | 中国广电 | `@glgd` |

## 路由器 WAN 口信息

`init` 最后会要求填写路由器 WAN 口的地址。登录路由器管理页（常见为 `192.168.1.1` 或 `192.168.0.1`），在「WAN 口状态」「上网设置」或「系统状态」中即可看到：

| 项目 | 必填 | 说明 |
|------|------|------|
| IPv4 | 是 | 校园网分配给路由器 WAN 口的地址（不是电脑的 `192.168.x.x`） |
| MAC | 是 | WAN 口 MAC；`AA:BB:CC:DD:EE:FF`、`aa-bb-cc-dd-ee-ff`、`aabbccddeeff` 均可，保存时统一为 12 位小写 |

> **WAN 口 IP 变化后**（路由器重启、DHCP 重新分配等）认证会失败。此时直接改配置文件即可，无需重新 `init`：bash 版改 `.env` 里的 `DRCOM_ROUTER_IP`，Windows 版改 `guet_drcom.config.json` 里的 `RouterIp`。若路由器开启了 WAN 口 MAC 克隆/随机化，请以路由器实际对外使用的 MAC 为准。

---

## 注意事项

> **安全提示**：bash 版密码以明文存在 `.env`，务必 `chmod 600` 限本人访问；Windows 版用 DPAPI 加密，配置文件绑定本机当前用户，换用户或换电脑需重新 `init`。

> 提示：Windows 版计划任务经 `wscript.exe` 隐藏启动，部分杀毒软件可能拦截；若 `auto` 启用后日志长期无新内容，可检查安全软件是否拦截了 `wscript.exe` 或删除了 `guet_drcom_hidden.vbs`。

## 环境变量（可选）

以下变量可覆盖默认值，两平台一致：

`SERVER_IP`、`STATUS_URL`、`LOGIN_URL`、`LOGOUT_URL`、`LOGOUT_DELAY`、`LOGIN_TIMEOUT`、`LOGIN_RETRIES`、`LOGIN_RETRY_DELAY`、`DRY_RUN`、`AUTO_LOG`、`GUET_DRCOM_ENV`（配置文件路径）。路由器 IP/MAC 只从配置文件读取，本分支不再支持 `INTERFACE` / `CLIENT_IP` / `CLIENT_MAC` 等环境变量覆盖。

> 注销后 RADIUS 服务端需要 20~30 秒缓冲，期间登录会返回 `Auth Server Timeout !!!` 或 `Rad:Oppp error: Timeout 40`，且首次请求本身可能耗时十几秒。因此登录请求超时默认 25 秒（`LOGIN_TIMEOUT`），失败后最多重试 5 次（`LOGIN_RETRIES`），每次间隔 3 秒（`LOGIN_RETRY_DELAY`）。实测在第 3 次尝试前后成功，`login` 整体耗时约 35 秒。

```powershell
# 示例：只探测网络、不真正发请求
$env:DRY_RUN = '1'; .\guet_drcom.ps1 login
```

---

## 卸载

macOS / Linux：

```bash
./guet_drcom.sh disable        # 移除 crontab
rm -f .env guet_drcom.log      # 删除配置与日志
```

Windows：双击 `guet_drcom.bat` 选 disable，或运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\guet_drcom.ps1 disable
```

然后删除 `guet_drcom.config.json` 与日志即可。

---

## 支持作者

如果这个工具帮到了你，欢迎给项目点个 ⭐ Star，或请作者喝杯咖啡 ☕

<img src="qrcode.jpg" width="200" alt="二维码" />

本工具免费开源，你的支持是我持续维护的动力。

---

## 许可证

本项目采用 [MIT License](LICENSE) 许可。

## 关于作者

本工具代码风格严格遵循 Andrej Karpathy 编码规范（极简主义），追求清晰、简洁、易维护。

**原作者**：bbbstyyy
