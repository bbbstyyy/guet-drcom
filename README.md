# GUET Dr.COM 路由器版

适用于 **MiWiFi / XiaoQiang / BusyBox ash** 环境的桂电 Dr.COM 校园网认证脚本。

本分支只保留路由器所需内容：

```text
.
├── README.md
├── guet_drcom.sh
└── docs
    └── help.jpg
```

## 已验证环境

- 小米路由器 / XiaoQiang 固件
- Linux 4.4.60
- ARMv7
- BusyBox ash 1.25.1
- curl 7.79.1
- crontab / crond
- 无需 Bash
- 无需 iconv

> 脚本使用 `#!/bin/sh`，针对 BusyBox ash 做了兼容处理。

## 功能

| 命令 | 说明 |
| --- | --- |
| `init` | 初始化学号、密码、运营商 |
| `login` | 注销旧会话并重新登录 |
| `logout` | 注销当前会话 |
| `check` | 检测在线状态，掉线则重连 |
| `auto` | 每分钟自动检测与重连 |
| `disable` | 移除自动重连 cron |
| `diag` | 查看认证服务器的路由和接口信息 |
| `help` | 显示帮助 |

![guet_drcom.sh help](docs/help.jpg)

## 安装

建议放在路由器的持久化目录，例如 `/data/guet-drcom`：

```sh
mkdir -p /data/guet-drcom
cd /data/guet-drcom

wget -O guet_drcom.sh \
  https://raw.githubusercontent.com/bbbstyyy/guet-drcom/miwifi/guet_drcom.sh

chmod 700 guet_drcom.sh
```

确认脚本可以运行：

```sh
./guet_drcom.sh help
```

## 使用

### 1. 初始化

```sh
./guet_drcom.sh init
```

按提示输入：

- 学号
- 密码
- 运营商

运营商对应关系：

| 选项 | 运营商 | 账号后缀 |
| ---: | --- | --- |
| 1 | 校园网 | 无 |
| 2 | 中国移动 | `@cmcc` |
| 3 | 中国联通 | `@unicom` |
| 4 | 中国电信 | `@telecom` |
| 5 | 中国广电 | `@glgd` |

初始化后会在脚本目录生成：

```text
.env
```

默认情况下即：

```text
/data/guet-drcom/.env
```

### 2. 检查校园网路由

首次使用建议执行：

```sh
./guet_drcom.sh diag
```

应能看到到认证服务器 `10.0.1.5` 的路由，例如：

```text
10.0.1.5 via 10.x.x.x dev eth0 src 10.x.x.x
```

如果出现：

```text
RTNETLINK answers: Network unreachable
```

说明路由器当前没有到认证服务器的路由，请先检查 WAN 是否已正确接入校园网。

### 3. 登录

```sh
./guet_drcom.sh login
```

认证成功时，Dr.COM 返回内容中会包含：

```text
"result":1
```

并显示：

```text
登录成功
```

登录前脚本会先尝试注销旧会话。如果注销返回 `result=0`，但随后登录返回 `result=1`，不影响正常使用。

### 4. 检查在线状态

```sh
./guet_drcom.sh check
```

- 在线：直接退出，返回成功状态。
- 掉线：自动重新执行登录。
- 无法路由到认证服务器：跳过本次认证并返回非零状态。

脚本不依赖 `iconv`，可直接在精简 BusyBox 固件上检测 Dr.COM 在线状态。

### 5. 开启自动重连

```sh
./guet_drcom.sh auto
```

脚本会向当前用户的 crontab 添加一条带有：

```text
# guet_drcom-auto
```

标记的任务，每分钟执行一次在线检测。

查看任务：

```sh
crontab -l
```

查看日志：

```sh
tail -f /data/guet-drcom/guet_drcom.log
```

默认日志文件为：

```text
/data/guet-drcom/guet_drcom.log
```

### 6. 关闭自动重连

```sh
./guet_drcom.sh disable
```

只会移除带 `# guet_drcom-auto` 标记的 cron 项，不会删除路由器原有的其他定时任务。

## 手动注销

```sh
./guet_drcom.sh logout
```

如果当前没有可注销的 Radius 会话，服务器可能返回：

```text
Radius注销失败！
```

这不代表后续登录一定会失败。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `guet_drcom.sh` | 路由器认证脚本 |
| `.env` | 本地认证配置，运行 `init` 后生成 |
| `guet_drcom.log` | 自动检测 / 重连日志 |
| `docs/help.jpg` | 路由器实际运行截图 |

## 安全提示

`.env` 中包含认证账号和密码，并以明文形式保存在路由器本地。

请确保：

- 不要将 `.env` 上传或提交到公开仓库；
- 不要把配置文件发送给他人；
- 建议限制脚本目录和配置文件的访问权限。

脚本通过 `init` 创建配置文件时会将权限设置为仅当前用户可读写。
