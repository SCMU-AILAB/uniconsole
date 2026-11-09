# 发信（注册验证码）

```
uniconsole-server ──smtp://127.0.0.1:25──▶ Postfix（服务器本机，只监听 127.0.0.1）
                                              │ STARTTLS + 账号密码，587 端口
                                              ▼
                                        Resend 中继 ──▶ 收件人邮箱
```

服务器在家宽 / 校园网后面：**出站 25 端口被运营商封了**，也没有反向解析（PTR），直接投递会被拒或进垃圾箱。
所以 Postfix 只做本机排队，统一交给 Resend（免费 3000 封 / 月、100 封 / 天）发出，
发件人仍然是 `noreply@silencecf.me`，由 Resend 用 silencecf.me 的 DKIM 签名。

## 服务器上已经做好的

- `apt install postfix libsasl2-modules`，`/etc/postfix/main.cf`：`inet_interfaces = loopback-only`、
  `relayhost = [smtp.resend.com]:587`、`smtp_tls_security_level = encrypt`、不收信（`mydestination` 为空）、
  队列最长 1 小时（验证码 10 分钟就过期，没必要久留）。
- `/etc/postfix/sasl_passwd`（600 权限）：`[smtp.resend.com]:587 resend:<API Key>`。
- `~/uniconsole/server/.env`：`SMTP_URL=smtp://127.0.0.1:25`、`MAIL_FROM=UniConsole <noreply@silencecf.me>`。

## 换 / 填 Resend API Key

```bash
ssh yaoyifeng@silencecf.me
echo '[smtp.resend.com]:587 resend:re_xxxxxxxx' | sudo tee /etc/postfix/sasl_passwd >/dev/null
sudo postmap /etc/postfix/sasl_passwd && sudo postfix reload
sudo postqueue -f          # 立即重试队列里的邮件
```

## DNS 记录（silencecf.me，Namecheap → Advanced DNS）

在 Resend 控制台 Domains → Add Domain 填 `silencecf.me`，它会给出下面这几条（DKIM 的值每个账号不同，
以控制台为准）：

| 类型 | 主机 | 值 | 作用 |
|---|---|---|---|
| TXT | `resend._domainkey` | `p=MIGfMA0GCSq…`（控制台复制） | DKIM 签名 |
| MX | `send` | `feedback-smtp.<区域>.amazonses.com`，优先级 10 | 退信回收（Return-Path） |
| TXT | `send` | `v=spf1 include:amazonses.com ~all` | 退信域 SPF |
| TXT | `_dmarc` | `v=DMARC1; p=none;` | DMARC（建议，可后加） |

根域名现有的 MX（`eforward*.registrar-servers.com`，Namecheap 邮件转发）和
`v=spf1 include:spf.efwd.registrar-servers.com ~all` **不用动**：Resend 的退信走 `send.silencecf.me`，
不影响根域名收信。

## 排查

```bash
sudo journalctl -u postfix@- -f      # 投递日志：status=sent / deferred 及原因
sudo postqueue -p                    # 积压的邮件
sudo postsuper -d ALL                # 清空队列
```

- `535 Authentication credentials invalid`：API Key 不对或没 `postmap`。
- `450 … domain is not verified`：Resend 里域名还没验证通过（DNS 未生效）。
- 服务端日志「邮件发送失败」：Postfix 没在跑（`systemctl status postfix`）。
- 本地开发不设 `SMTP_URL`，验证码直接打印在服务端日志里。
