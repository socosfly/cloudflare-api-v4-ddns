# Cloudflare API v4 DDNS
# forked from yulewang/cloudflare-api-v4-ddns

使用 Bash 自动检测公网 IP，并更新 Cloudflare DNS 记录。仅在 IP 发生变化时请求更新，支持 IPv4（A）和 IPv6（AAAA），更新成功后可选发送 Telegram Bot 通知。

## 功能

- 支持 Cloudflare API Token（推荐）
- 兼容旧式 Global API Key
- 支持 A 和 AAAA 记录
- 自动查询并缓存 Zone ID、Record ID 和公网 IP
- 缓存的 Record ID 失效时自动重新查询并重试一次
- 使用 Cloudflare PATCH API 更新 DNS
- 可选发送带本地时间戳的 Telegram 通知
- Cloudflare 或 Telegram API 失败时输出明确错误信息

## 依赖

- Bash
- curl
- jq

Debian、Ubuntu：

```bash
sudo apt update
sudo apt install -y curl jq
```

OpenWrt：

```bash
opkg update
opkg install bash curl jq
```

macOS：

```bash
brew install jq
```

## 下载与安装

```bash
sudo wget https://raw.githubusercontent.com/socosfly/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh \
  -O /usr/local/bin/cf-ddns.sh
sudo chmod +x /usr/local/bin/cf-ddns.sh
sudo nano /usr/local/bin/cf-ddns.sh
```

请使用 `bash /usr/local/bin/cf-ddns.sh` 或直接执行脚本，不要使用 `sh cf-ddns.sh`。

## Cloudflare API Token

建议在 Cloudflare 创建仅授权目标域名的 API Token，至少包含：

- Zone → Zone → Read
- Zone → DNS → Edit
- Zone Resources → 选择需要更新的域名

## 配置

脚本开头的 `configuration` 区域包含以下变量：

```bash
CF_API_TOKEN='你的 Cloudflare API Token'
CF_API_KEY=''
CF_API_EMAIL=''

CFZONE_NAME='example.com'
CFRECORD_NAME='home.example.com'
CFRECORD_TYPE='A'
CFTTL='120'
FORCE='false'

TGCHATID='你的 Telegram Chat ID'
TGTOKEN='你的 Telegram Bot Token'
TGURL="https://api.telegram.org/bot${TGTOKEN}/sendMessage"
```

变量说明：

| 变量 | 说明 |
| --- | --- |
| `CF_API_TOKEN` | Cloudflare API Token，推荐使用 |
| `CF_API_KEY` | 旧式 Global API Key，使用 Token 时留空 |
| `CF_API_EMAIL` | 使用 Global API Key 时填写 Cloudflare 登录邮箱 |
| `CFZONE_NAME` | Cloudflare 根域名，例如 `example.com` |
| `CFRECORD_NAME` | 完整记录名，例如 `home.example.com`；也可填写 `home` |
| `CFRECORD_TYPE` | IPv4 填 `A`，IPv6 填 `AAAA` |
| `CFTTL` | `1` 表示自动 TTL，也可填写 `60`～`86400` |
| `FORCE` | `true` 表示忽略本地 IP 缓存并强制更新 |
| `TGCHATID` | Telegram Chat ID；留空则不发送通知 |
| `TGTOKEN` | Telegram Bot Token；留空则不发送通知 |
| `TGURL` | Telegram Bot `sendMessage` API 地址 |

使用 API Token 时不需要填写 `CF_API_EMAIL`。Telegram 通知是可选功能，`TGCHATID` 或 `TGTOKEN` 为空时会自动跳过。

> 仓库是公开的，请勿把真实 Cloudflare Token 或 Telegram Bot Token 提交到 GitHub。

## 直接运行

如果已经在脚本内填写配置：

```bash
/usr/local/bin/cf-ddns.sh
```

也可以通过参数传入 Cloudflare 配置：

```bash
/usr/local/bin/cf-ddns.sh \
  -T '你的 Cloudflare API Token' \
  -z example.com \
  -h home.example.com \
  -t A
```

强制更新：

```bash
/usr/local/bin/cf-ddns.sh \
  -T '你的 Cloudflare API Token' \
  -z example.com \
  -h home.example.com \
  -t A \
  -f true
```

## Telegram 通知

脚本支持给TG Bot发送通知。

## 设置定时任务

编辑当前运行用户的 crontab：

```bash
crontab -e
```

每两分钟运行一次，不保存日志：

```cron
*/2 * * * * /usr/local/bin/cf-ddns.sh >/dev/null 2>&1
```

保存日志：

```cron
*/2 * * * * /usr/local/bin/cf-ddns.sh >> /var/log/cf-ddns.log 2>&1
```

手动运行与 cron 应使用同一个用户，否则 `$HOME` 和缓存目录可能不同。默认缓存目录为：

```text
$HOME/.local/state/cf-ddns
```

也可以通过 `CF_CACHE_DIR` 指定固定目录。

## 常见提示

- `WAN IP unchanged`：公网 IP 没有变化，不需要更新。
- `Resolving Cloudflare Zone ID and Record ID`：首次运行、配置变化或缓存失效时重新查询 ID。
- `Telegram notification sent successfully`：Telegram 通知发送成功。
- `Cloudflare ... failed`：检查 Token 权限、根域名、记录名称和记录类型。
