# 公网 TURN 中继

TURN 转发 WebRTC 视频；点云通过既有鉴权 WebSocket 转发，不走 TURN。
当前主机为 `1.13.195.109`（SSH `ubuntu`、端口 `2222`）；端口 `22` 转发到内网后端。

```bash
sudo bash install-turn.sh 1.13.195.109
sudo systemctl status uniconsole-turn
sudo journalctl -u uniconsole-turn -n 50
```

脚本适用于 Ubuntu/Debian，安装 coturn 和 `uniconsole-turn.service`，自动检测本机出口 IPv4，
配置公网 NAT 映射。共享密钥保存在 `/etc/coturn/uniconsole.secret`（0600），不输出到终端。
将同一密钥通过安全通道写入后端 `.env` 的 `TURN_SECRET`，不要提交或写入聊天记录。

后端配置示例（密钥需单独填入）：

```dotenv
TURN_URLS=turn:1.13.195.109:3478?transport=tcp,turn:1.13.195.109:3478?transport=udp
TURN_TTL_SECS=43200
ICE_SERVERS=[{"urls":"stun:1.13.195.109:3478"}]
```

修改后重启 `uniconsole-server`。已登录客户端通过 `/api/v1/webrtc/ice-servers` 获取限时凭据；
相同配置由后端附加到机器人 offer。aiortc 当前只采用第一条 TURN URL，因此将经过验证的 TCP 放在首位。
Flutter 可收集多种候选地址，优先直连，无法直连时中继；验证时可强制 relay。

云安全组和主机防火墙所需入站规则：

| 协议 | 端口 | 用途 |
|---|---|---|
| TCP | 3478 | TURN over TCP，适用于客户端 UDP 受限网络 |
| UDP | 3478 | STUN / TURN over UDP |
| UDP | 49160–49200 | TURN 分配的媒体端口 |

使用 IP 无需 DNS 记录。媒体仍由 WebRTC DTLS-SRTP 加密；此安装没有配置 TURN TLS 监听。
`no-tcp-relay` 禁止 RFC6062 TCP 对等端分配，不影响客户端通过 TCP 3478 使用 UDP 媒体中继。
服务拒绝私网、回环及组播 peer，限制每用户 4 个分配、总计 32 个、每个 2 MB/s。
日志中拒绝 `192.168.*` host candidate 是正常保护，不能为此删除私网限制。

2026-11-13 验证：使用后端发放的限时凭据，两个强制 relay 的 ICE 端点经 TCP 3478 成功传输数据。
UDP 3478 探测未到达云主机，主机 INPUT 默认 ACCEPT；尚未确认云安全组或上游 UDP 限制。
TCP 中继已可用。开放 UDP 规则后应从外网复测，不能只凭服务 active 或 TCP 端口连通声称 UDP 可用。

同日 macOS 原生视频测试设置 `iceTransportPolicy=relay`，收到并显示真实 640×360 图像，
检查选中 ICE candidate pair 的本地候选为 relay；退出页面后狗端 `video_sessions` 恢复为 0。

原生视频与雷达验证命令见 [Go2 实机链路](../../frontend/docs/GO2_LIVE.md)。
