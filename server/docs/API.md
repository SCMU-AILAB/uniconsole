# UniConsole 接口文档

```
机器人（Python FastAPI 代理） ──WS 外连──▶  服务器（Rust / axum） ◀──REST + WS──  前端（Flutter）
                                              │
                                          PostgreSQL
```

- REST 前缀 `/api/v1`，JSON 字段 **snake_case**，时间为 RFC 3339（UTC），时长用 `*_secs` / `*_ms` 整数，百分比 0–100。
- 认证：`Authorization: Bearer <jwt>`；WebSocket 用 `?token=<jwt>`。收到 401 时清掉令牌回到登录页。
- 请求头 `X-Client: macOS · 1.0.0`：写入审计日志「客户端」列和「已登录设备」。值按 UTF-8 解码，失败时按
  Latin-1（Dart `HttpClient` 发送 `·` 时就是 Latin-1），两种都可以。
- 错误统一为 `{"error": {"code": "...", "message": "..."}}`。`message` 是给人看的中文，前端可以原样显示：

| HTTP | code | 场景 |
|---|---|---|
| 400 | bad_request | 参数错误（表单旁显示 message） |
| 401 | unauthorized | 未登录 / 会话失效 / 已退出（「登录已失效，请重新登录」）；登录时账号或密码错误（「账号或密码错误」） |
| 401 | two_factor_required | 登录：该账号开启了二次验证，请带上 `code` 重试 |
| 401 | two_factor_invalid | 二次验证码错误 |
| 403 | forbidden | 权限不足、没有控制权；账号已停用 / 已过期（message 分别为「账号已停用」「账号已过期」） |
| 404 | not_found | |
| 409 | conflict | 已存在、申请已处理、设备被占用。涉及设备时带 `device_ids: [...]`，前端据此标红 |
| 423 | estop_active | 急停中拒绝运动指令 |
| 429 | too_many_requests | 登录失败过多（同一账号 + IP 15 分钟内 5 次，锁定 60 秒） |
| 501 | not_implemented | 已规划、尚未实现的接口 |
| 502 | upstream_unavailable | 依赖的外部服务（智能体）不可用 |
| 503 | robot_offline | 设备不在线 |
| 504 | timeout | 等待机器人回执超时 |

**单位与坐标（定稿）**：
- 角度一律**弧度**：遥测 `roll` / `pitch` / `yaw`、`pose.yaw`、点位 `yaw`、角速度 `wz`。前端显示「度」时自行换算。
- 地图坐标系（ROS REP-103）：单位**米**，原点在地图左下角，x 向右、y 向上；角度逆时针为正，0 指向 +x。
  `GET /maps` 给出 `width_m` / `height_m` / `origin`，前端据此换算成界面百分比。`pose`、`polygon`、点位、充电桩都用这个坐标系。
- 点云二维投影用**机器人坐标系**：+y 朝前、+x 朝右，单位米。

枚举值与前端 HANDOFF §6 一致：

| 枚举 | 取值 |
|---|---|
| role | admin · owner · user · viewer |
| device status | online · busy · alert · charging · offline |
| device kind | dog · humanoid |
| alert severity / state | critical · warning · info / open · doing · closed |
| formation | line · column · v · grid |
| mission state | running · scheduled · paused |
| zone type | ban · slow · whitelist · wall |
| audit kind | control · alert · terminal · config · system |

---

## 1. REST

### 认证

登录态由服务端会话管理：JWT 里只有成员 id 和会话 id。退出登录、在其他设备上踢下线、停用账号、
修改角色都**立即生效**（下一次请求就会 401 / 403）。令牌有效期 12 小时（`expires_in`，秒）。

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| POST | /auth/login | `{handle, password, code?, device_name?}` → `LoginResponse` | 公开 |
| POST | /auth/logout | 吊销当前会话 → 204 | 登录 |
| GET | /auth/me | 当前成员（`Member`） | 登录 |
| POST | /auth/password | `{old_password, new_password}` → 204；其他已登录设备全部退出 | 登录 |
| GET | /auth/invites/{token} | 邀请页信息 `{handle, name, expires_at}`；无效或过期 404 | 公开 |
| POST | /auth/invites/{token}/accept | `{password, device_name?}` → `LoginResponse`（设置密码并直接登录） | 公开 |
| POST | /auth/register/code | `{email}` → `{expires_in: 600, resend_after: 60}`，向邮箱发 6 位验证码 | 公开 |
| POST | /auth/register | `{email, code, handle, name, password, device_name?}` → 201 `LoginResponse`（观察者，直接登录） | 公开 |

```json
// POST /auth/login
{"handle": "@Kanade", "password": "…", "code": "123456", "device_name": "MacBook Pro"}
// 200 LoginResponse
{"token": "eyJ…", "expires_in": 43200, "session_id": "…", "member": Member}
```

- `handle` 可带 `@`，不区分大小写；也可以填注册邮箱（含 `@` 且不在开头即按邮箱查找）。`device_name` 显示在「已登录设备」里，缺省取 `X-Client` 的平台名。
- **登录页要处理的错误**：
  - 401 `unauthorized`「账号或密码错误」（账号不存在、尚未激活也返回这个，防止探测账号）
  - 401 `two_factor_required`：显示验证码输入框，带 `code` 再提交一次
  - 401 `two_factor_invalid`「二次验证码错误」
  - 403 `forbidden`「账号已停用」/「账号已过期」
  - 429 `too_many_requests`「登录失败次数过多，请 N 秒后再试」
- 密码规则：8–128 个字符（400「密码至少 8 位」）。
- **邀请**：管理员邀请成员时不设密码，拿到 `invite_url`（`uniconsole://invite/<token>`，7 天有效、只能用一次）。
  前端打开深链后先 `GET /auth/invites/{token}` 显示「为 林悦（@linyue）设置密码」，再 `accept`，成功即已登录。
- **邮箱注册**（`REGISTRATION_ENABLED=false` 时两个接口都返回 403「暂未开放注册，请联系管理员邀请」）：
  1. `POST /auth/register/code {email}`：发信件「UniConsole 注册验证码 123456」，10 分钟有效。
     错误：400「邮箱格式不正确」、409「该邮箱已注册，请直接登录」、429「请 N 秒后再获取验证码」
     （同一邮箱 60 秒一次）/「获取验证码过于频繁，请稍后再试」（同一 IP 每小时 10 次）、
     502 `upstream_unavailable`「邮件发送失败，请稍后再试」（可立即重试）。
  2. `POST /auth/register`：错误 400「验证码错误」/「验证码无效或已过期，请重新获取」/
     「验证码错误次数过多，请重新获取」（错 5 次作废）、409「账号 @x 已被使用」/「该邮箱已注册，请直接登录」，
     以及账号、名字、密码的格式错误（同邀请）。账号重名时验证码不会被消耗，改个账号再提交即可。
  3. 成功即登录（同 `/auth/login` 的 `LoginResponse`），角色固定为 `viewer`（只能看，不能控制）。
     在线管理员收到 `notice`「林悦（x@y.com）注册成为观察者，可在成员与权限里调整角色」，成员列表收到 `changed`；
     管理员用 `PATCH /members/{id} {role}` 调整角色。

### 当前账户（设置页）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /me/sessions | 已登录设备 `[{id, name, detail, current, created_at, last_seen_at, expires_at}]`，`detail` 如「macOS · 1.0.0 · 192.168.1.20」 |
| DELETE | /me/sessions/{id} | 让该设备退出登录（可以是当前会话） |
| GET | /me/tokens | 个人 API 令牌 `[{id, name, detail, created_at, last_seen_at, expires_at}]`，`detail` 如「创建于 10 月 12 日 · 最近使用 11 月 3 日」 |
| POST | /me/tokens | `{name, ttl_days?}` → `{id, name, token, ttl_days}`，**token 只返回这一次**；用法同登录令牌 |
| DELETE | /me/tokens/{id} | 吊销 |
| POST | /me/2fa/enable | → `{secret, otpauth_url}`（扫码绑定验证器 App）；已开启 409 |
| POST | /me/2fa/verify | `{code}` → 204，验证通过后正式开启 |
| POST | /me/2fa/disable | `{code}` → 204 |
| GET / PUT | /me/preferences | 前端 `Preferences` 整个对象，服务端不解析，按账户同步；`two_factor` 以服务端为准（读时覆盖、写时忽略） |
| POST | /me/push-tokens | `{platform: "apns" \| "fcm", token}` → 204（登记；服务端发送尚未接入） |

开关二次验证、创建 / 吊销令牌、修改密码都会写审计。

### 成员与权限（Roles.dc.html）

```json
Member = {
  "id": "uuid", "handle": "linyue", "name": "林悦", "role": "owner",
  "color": "#FF2D55",            // 头像颜色 #RRGGBB
  "expires_at": null,            // null = 长期
  "disabled": false,
  "granted_device_ids": ["go2-01"],   // 被授权的设备（不含自己管理的，那些看 devices.owner_id）
  "video_only": false, "guest_link": false,
  "online": true,                // 当前有前端连接着 /api/v1/ws
  "last_seen": "…",              // 最近一次登录 / 断开实时连接的时间
  "two_factor": false,
  "pending_invite": false,       // 已邀请、尚未设置密码
  "email": "linyue@example.com", // 邮箱注册的账号才有；只有管理员和本人看得到，其他人为 null
  "created_at": "…"
}
```

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| GET | /members | `Member[]` | 登录 |
| GET | /members/{id} | `Member` | 登录 |
| POST | /members | `{handle, name, role, password?, color?, expires_at?, video_only?, guest_link?, device_ids?}` → 201 `{member, invite_url, invite_expires_at}`。不传 `password` 时生成邀请链接（推荐），传了则直接激活、`invite_url` 为 null | 管理员 |
| POST | /members/{id}/invite | 重新生成邀请链接（旧链接作废）→ `{invite_url, invite_expires_at}`；已激活 409 | 管理员 |
| PATCH | /members/{id} | `{name?, role?, color?, expires_at?, disabled?, video_only?, guest_link?}`；`expires_at: null` 表示改为长期 | 管理员；本人可改 `name` / `color` |
| DELETE | /members/{id} | → 204 | 管理员 |
| GET / PUT | /members/{id}/devices | 授权设备 `{device_ids: []}` | 管理员；设备管理者只能增减自己管理的设备 |
| GET | /audit?limit=&before=&kind= | 审计日志，按 id 倒序，`before` 分页 | 管理员 |
| GET | /audit.csv?kind= | 导出 CSV（UTF-8 BOM，Excel 可直接打开） | 管理员 |

规则（与前端 mock 一致）：
- 只有管理员能邀请、改角色、停用、移除；不能改自己的角色（403「不能修改自己的角色」），不能停用 / 移除自己。
- 至少保留一名可用的平台管理员（409「至少要保留一名平台管理员」）。
- 账号唯一，不区分大小写，2–32 位小写字母 / 数字 / `_.-`（409「账号 @linyue 已存在」）。
- 停用会立即踢下线该成员的所有会话。

`AuditEntry`：

```json
{"id": 123, "at": "…", "actor": "Kanade", "actor_id": "uuid | null", "action": "批准 林悦 的控制权申请（Alpha）",
 "target": "Alpha", "kind": "control", "client": "macOS · 1.0.0", "detail": {}}
```

`action` 是完整的人话，前端直接显示；系统动作 `actor` 为「系统」、`client` 为「服务端」。新条目推送 `changed: audit`。

### 设备（Main / Control / Sensors / Maintenance）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /devices?status=&group_id=&q= | 设备列表（按可见范围过滤），`DeviceView[]` |
| POST | /devices | 注册设备（管理员）`{id, name, code, model, kind, sn?, group_id?, owner_id?, location?}` → `{device, token}`，**token 只返回这一次** |
| GET / PATCH / DELETE | /devices/{id} | PATCH: `{name?, group_id?, location?, owner_id?, meta?}` |
| POST | /devices/{id}/token | 轮换机器人接入令牌（管理员） |
| GET | /devices/{id}/telemetry/latest | 最新一帧遥测（形状同 WS `telemetry`） |
| GET | /devices/{id}/telemetry?from=&to=&limit= | 1 Hz 抽样历史（默认最近 1 小时）→ `{"samples": [...]}`，见下 |
| GET | /devices/{id}/sensors | 传感器描述（机器人 hello 上报），见下 |
| GET | /devices/{id}/events?limit=20 | 最近事件 `[{at, text, tone}]`，增量走 WS `device_event` |
| POST | /devices/{id}/commands | `{command, wait?=true}` → `CommandResult` |
| GET | /devices/{id}/commands?limit= | 指令日志（含被拒绝的指令），见下 |
| POST | /devices/{id}/estop | `{active: bool}` 单机急停 / 解除 → `{estop, delivered}`（离线也会记录，设备上线时生效） |
| GET | /device-groups | `[{id, name, tone, sort}]`，`tone` 取 `online · busy · warning · action · critical · neutral` |
| POST / PATCH / DELETE | /device-groups(/{id}) | `{id?, name, tone?, sort?}`（管理员 / 设备管理者）；变化推送 `changed: device_groups` |

`DeviceView`（数据库字段 + 实时状态）：

```json
{
  "id": "go2-01", "name": "Alpha", "code": "GO2-01", "model": "Unitree Go2 EDU", "kind": "dog",
  "sn": "GO2E-24A0137", "firmware": "v1.1.7", "ip": "192.168.123.161", "group_id": "patrol",
  "owner_id": "…", "status": "busy", "location": "B 区 · 2 号走廊", "current_task": "巡检路线 B-2",
  "last_seen_at": "…", "created_at": "…", "updated_at": "…",
  "meta": {
    "capabilities": ["move", "mode", "action", "skills", "telemetry"],
    "skills": [{"name": "heart", "description": "…", "tags": [], "motion": true}],   // 动作按钮；motion=true 急停中禁用
    "sensors": {…}
  },
  "online": true,
  "battery": 86.0,          // 可为浮点；机器人拿不到时为 null；离线时保留最后已知值
  "latency_ms": 18,         // 离线 null
  "max_motor_temp": 46.0,   // 离线 null
  "uptime_secs": 11520,     // 离线 null
  "estop": false,           // 单机急停中（全局急停时也为 true）
  "user_id": "…",           // 当前持有控制权的成员（lease.holder_kind == user 时），否则 null
  "lease": Lease | null     // 形状见「控制权」，含 queue
}
```

遥测历史 `samples[]`：`{ts, battery, max_motor_temp, latency_ms, voltage, current, pitch, roll, vx, extra}`，按时间升序。

传感器：

```json
{"lidar": "4D LiDAR · 360°×90° · 21,600 点/秒 · 10 Hz",
 "cameras": [{"name": "前置 RGB", "detail": "1280×720 · 30 fps", "health": "ok|degraded|idle", "hz": 30}],
 "topics":  [{"name": "/utlidar/cloud", "detail": "PointCloud2", "health": "ok", "hz": 10}],
 "online": true}
```

`command`（`kind` 区分）：

```json
{"kind": "move", "vx": 0.6, "vy": 0, "wz": -0.15}     // 高频请走 WebSocket
{"kind": "stop"}
{"kind": "set_mode", "mode": "stand|down|balance|walk|stairs|damp|recovery"}
{"kind": "set_speed", "level": "slow|normal|fast"}  // 0.3 / 0.8 / 1.5 m/s
{"kind": "estop"} / {"kind": "release_estop"}
{"kind": "action", "name": "heart", "params": {}}  // name 取自 meta.skills；参数校验由机器人端技能完成
```

`CommandResult`：`{cmd_id, ok, error, message, latency_ms}`。`ok: false` 时 `error` 为 `robot_error`（机器人执行失败，
`message` 是机器人给的原因）。被服务端拒绝的指令直接返回 HTTP 错误（403 / 423 / 503 / 504）。

指令日志（新的在前）：

```json
[{"cmd_id": "…", "at": "…", "command": {"kind": "set_mode", "mode": "stand"},
  "ok": false, "error": "estop_active", "message": "系统处于急停状态", "by": "Kanade", "acked_at": "…"}]
```

`error` 取值：`estop_active` · `forbidden` · `robot_offline` · `timeout` · `robot_error`，前端翻译成中文；`ok: null` 表示未等待回执。
高频 `move` 不记录。

### 控制权（Lease.dc.html）

```json
Lease = {
  "device_id": "go2-01",
  "holder_kind": "user|task|session",
  "holder_id": "…",            // 按 holder_kind：成员 id / 任务 id / 联调会话 id
  "source": "单机操控",          // 或「联调会话 · 展厅迎宾」「单机 · 由 Kanade 转交」
  "acquired_at": "…",          // 「已控制 41 分钟」
  "expires_at": "… | null",    // 联调会话 / 任务持有时为 null
  "queue": [{"id": "…", "user_id": "…", "reason": "调试步态", "expected_secs": 900,
             "state": "pending", "created_at": "…", "device_id": "go2-01", "decided_by": null, "decided_at": null}]
}
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /leases | 每台可见设备 `{device_id, name, code, lease, holder_name, queue}`（`queue` 在无人控制时也可能非空） |
| POST | /devices/{id}/lease | `{reason?, expected_secs?}` → `{"result":"granted","lease"}` 或 `{"result":"queued","request"}` |
| POST | /devices/{id}/lease/renew | 续约 `lease_term_secs`（策略，默认 300 s；建议剩余 1/3 时自动续约）→ `Lease` |
| DELETE | /devices/{id}/lease | 释放自己的控制权 → 204 |
| DELETE | /devices/{id}/lease?force=true&reason=… | 强制收回（设备管理者、平台管理员），`reason` 也可放 body `{"reason"}`；写审计并通知被收回的人 |
| POST | /devices/{id}/lease/transfer | `{"kind":"user","id":"…","note"?}` 或 `{"kind":"task","id":"<mission id>"}` → `Lease`；通知接收人 |
| GET | /devices/{id}/lease/requests | 待处理申请 |
| POST | /lease-requests/{id}/approve · /deny | 批准（控制权转给申请人，时长 = 申请里的 `expected_secs`）/ 拒绝；通知申请人 |

规则（与前端 mock 一致）：
- 空闲（或已过期）直接获得，否则排队。幂等：持有者再申请返回 `granted` 并续期；已在队列中的人再申请返回原申请。
- 批准、拒绝、转交：持有者、设备管理者、平台管理员（否则 403）；申请已处理过 409「该申请已处理」。
- 强制收回：只有设备管理者、平台管理员（403）。
- 联调会话持有的设备不能转交 / 批准给别人：409 并带 `device_ids`，message 如「Echo 正在联调会话中，请先结束会话或把它移出会话」。
- 租约到期、空闲释放、断线停止 / 释放的时间来自 `/safety` 的 policies（见「安全策略」），这些自动动作都写设备事件、审计，并给原持有者推 `notice`。

### 多机联调（Fleet.dc.html）

```json
FleetSession = {
  "id": "uuid", "number": 12, "title": "展厅迎宾",          // 界面显示「联调会话 #12」
  "initiator_id": "…", "started_at": "… | null",
  "device_ids": ["go2-05", "go2-06"], "leader_id": "go2-05",  // 第一台是领队
  "formation": "line|column|v|grid", "spacing": 1.2, "preset_id": "… | null",
  "control_mode": "领队-跟随", "clock_sync": "PTP · 局域网", "lost_link_action": "原地趴下",
  "clock_skew_ms": null,                                      // 未接入 PTP 统计前为 null
  "timeline": [{"device_id": "go2-05", "start_ms": 0, "end_ms": 2000, "action": "站立", "kind": "pose|move|act",
                "command": null}],                            // command 可选：协议 Command 对象，填了就不再按 action 翻译
  "timeline_length_ms": 16000,                                // 服务端按 timeline 的最大 end_ms 计算
  "playback_started_at": "… | null",                          // 时间轴播放中：播放头 = now - playback_started_at
  "last_receipt": Receipt | null,
  "active": true, "paused": false, "created_at": "…", "updated_at": "…"
}
Receipt = {"label": "同步站立", "sent_at": "…", "schedule_offset_ms": 200,
           "acks": [{"device_id": "go2-05", "ok": true, "latency_ms": 22, "error": null, "message": null}]}
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /fleet-sessions?active= | 列表（进行中的在前） |
| POST | /fleet-sessions?start=true | `{title, device_ids, formation?, spacing?, timeline?, preset_id?, control_mode?, clock_sync?, lost_link_action?}`；带 `preset_id` 时缺省字段取自预设。`start=true` 直接开始：任一设备被占用则整体失败（409 + `device_ids`），会话不会留下 |
| GET / PATCH / DELETE | /fleet-sessions/{id} | PATCH 字段同上，另有 `paused: false`（急停解除后恢复） |
| POST | /fleet-sessions/{id}/start | 开始：一次性接管所有设备的控制权 |
| POST | /fleet-sessions/{id}/stop | 结束：全部停止并释放控制权 |
| POST | /fleet-sessions/{id}/commands | `{command, device_ids?, label?}` → `Receipt`（同时存为 `last_receipt`） |
| POST | /fleet-sessions/{id}/play | `{from_ms?}`（可不带 body）→ `FleetSession`：按时间轴下发动作，仅发起人；已在播放 409、急停中 423、有无法识别的动作 400 |
| POST | /fleet-sessions/{id}/play/stop | 中止播放，所有设备停止 → `FleetSession` |
| GET | /fleet-presets | `[{id, name, device_ids, formation, spacing, created_by, created_at}]` |
| POST | /fleet-presets | `{name, session_id}`（把会话保存为预设）或 `{name, device_ids, formation?, spacing?}` |
| DELETE | /fleet-presets/{id} | |

行为：
- 进行中 `PATCH {device_ids}`：新加入的设备由会话接管控制权（被别人占用 → 409 + `device_ids`），移出的设备停止并释放；
  **最后一台退出时会话自动结束**。只有发起人和平台管理员能操作会话（403）。
- 全局急停时所有进行中的会话 `paused = true`，此时运动类同步指令 409；急停解除后需要 `PATCH {paused: false}` 恢复（急停中恢复 423）。
- `schedule_offset_ms`：各设备在同一时刻执行时相对发出时刻的偏移，取最慢回执向上取整到 50 ms。
- 变化推送 `changed: fleet_sessions` / `changed: fleet_presets`。
- **时间轴播放**：`action` 按 `kind` 翻译——
  `pose`：站立 / 趴下 / 平衡站立 / 行走 / 爬楼梯 / 阻尼 / 恢复站立（或 stand、down 等模式名）→ `set_mode`；
  `move`：「前进 3 m」「后退 1.5 m」「左移 / 右移 1 m」「左转 / 右转 90°」→ 块内以 10 Hz 下发 `move`，速度 = 距离 / 块时长
  （仍受安全策略限幅，超限时走不满距离），块结束 `stop`；
  `act`：设备技能目录（`meta.skills`）里 `name` 或 `description` 等于 `action` 的技能（「打招呼」→ hello），英文标识符直接当技能名。
  播放开始时推 `changed: fleet_sessions`（`playback_started_at` 有值），结束 / 中止后清空，并把每台设备的结果写入
  `last_receipt`（`label: "时间轴执行"`，失败的 `message` 写明是哪个动作）。全局急停、会话结束都会中止播放。
- TODO：编队保持、PTP 时钟偏差统计（`clock_skew_ms`）。

### 安全（Safety.dc.html）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /safety | `{global_estop, estop_by, estop_at, last_drill_at, active_zones, policies}`；`estop_by` 是显示名，未急停时为 null |
| PATCH | /safety/policies | 局部更新策略字段（未知字段、非法取值 400）；管理员 / 设备管理者 |
| POST | /safety/estop | `{active}` 全局急停（任何人可触发；`release_needs_manager` 时非管理者解除 403「需要管理者解除」） |
| POST | /safety/drill | 急停演练（管理员 / 设备管理者）→ `{at, responses: [{device_id, ok, ms, error, message}]}`；设备不会真的停机，完成后更新 `last_drill_at` |
| GET / POST | /zones?map_id= | `{map_id, name, zone_type, polygon: [[x,y],…], rule?, scope?, schedule?, action?, enabled?}` |
| PATCH / DELETE | /zones/{id} | 变化推送 `changed: zones` |

围栏的 `rule` / `scope` / `schedule` / `action` 都是**显示文本**（如「限速 0.3 m/s」「全部设备」「全天」「停止并告警」），
`scope` 默认「全部设备」、`schedule` 默认「全天」。`polygon` 用地图坐标系（米，见「约定」）。

**服务端执行**（按遥测 `pose` + `map_id`）：
- `ban` 禁入区 / `wall` 虚拟墙：**进入时**停止设备，写设备事件，生成 warning 告警（`metric: geofence`，标题如「进入禁入区「配电室」」）。
  之后仍可操控把设备开出来，离开时记一条事件。
- `whitelist` 允许区：该地图上有适用的允许区、设备却不在任何一个里面时，同样停止并告警（「离开允许区…」）。
- `slow` 限速区：在区内时运动指令的速度上限取 `rule` 里的第一个数字（m/s，缺省 0.3），与策略 `speed_limit` 取小。
- 适用范围：`scope` 为空或含「全部」时所有设备，否则文本中出现设备的 id / 名称 / 编号才适用；
  `schedule` 为「22:00–06:00」这类时段时只在该时段（排期时区，可跨零点）生效，其他文本视为一直生效。
- 启用的围栏在机器人连接时和每次变化后以 `zones` 消息下发给机器人（见 §3）。

安全策略 `policies`（字段名与前端 `SafetyPolicies` 一致）：

```json
{"auto_dock": true, "dock_threshold": 20,
 "heartbeat_timeout_ms": 1500, "lost_link_action": "stop|down|dock",
 "lease_expiry_action": "stop_release|stop_only",
 "speed_limit": 1.5, "max_yaw_rate": 2.0, "stop_near_people": true, "min_distance": 0.8,
 "fall_detection": true, "collision_detection": true, "cliff_detection": true,
 "release_needs_manager": true, "hardware_remotes": 0,
 "lease_term_secs": 300, "idle_release_secs": 600,
 "disconnect_stop_secs": 3, "disconnect_release_secs": 60}
```

- `lost_link_action`：机器人与服务器断联后的动作（下发给机器人执行；`dock` 暂按 `stop` 处理）。
- `lease_expiry_action`：`stop_release` 到期停止并释放；`stop_only` 到期只停车，持有者可续回，其他人也可直接申请。
- `idle_release_secs`：持有者多久没有任何操作（指令 / 续约）自动释放，0 表示不释放。
- `release_needs_manager` 为 true 时，非管理者解除急停 403「需要管理者解除」。

### 告警（Alerts.dc.html）

```json
Alert = {
  "id": "uuid", "severity": "critical|warning|info", "state": "open|doing|closed",
  "title": "电机过热", "device_id": "go2-03", "rule_id": "… | null",
  "metric": "max_motor_temp", "metric_label": "电机最高温度（°C）", "threshold": 60, "peak": 68,
  "location": "C 区 · 仓库",            // 触发时设备的位置
  "assignee_id": "… | null",           // 处理人
  "silenced_until": "… | null",
  "recording_id": null,                // 自动录制，尚未实现
  "created_at": "…", "updated_at": "…", "closed_at": "… | null"
}
AlertEvent = {"id": 1, "alert_id": "…", "at": "…", "tone": "critical|warning|neutral|info", "level": "…",
              "message": "电机最高温度（°C） > 60 持续 10 秒（当前 68.0）", "actor_id": "… | null"}
```

`tone`：`critical` / `warning` = 触发，`neutral` = 自动动作和通知，`info` = 人工处理。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /alerts?state=&severity=&device_id=&assignee_id=&limit= | `Alert[]`（按可见设备过滤） |
| GET | /alerts/{id} | `{alert, events[]}`（时间线按时间升序） |
| PATCH | /alerts/{id} | 见下 |
| POST | /alerts/{id}/events | `{message}` 备注 |
| POST | /alerts/{id}/remote-down | 走急停通道让设备趴下：不需要控制权、急停中也可以 → `CommandResult`；写时间线和审计 |
| GET | /alerts/{id}/history | 指标曲线 `{metric, metric_label, threshold, from, to, min_y, max_y, values: [{ts, v}]}`：触发前 30 分钟到关闭（或现在，最多触发后 2 小时） |
| GET / POST | /alert-rules | `{name, metric, metric_label?, op: > < >= <=, threshold, duration_secs, severity, auto_action?, enabled?}` |
| PATCH / DELETE | /alert-rules/{id} | `PATCH {enabled}` 用于开关；`auto_action: null` 清除；变化推送 `changed: alert_rules` |
| GET / PUT | /alert-channels | `[{name, min_severity, kind?, url?, format?}]`（PUT 仅管理员），见下 |
| GET / PUT | /on-call | `{weeks: [成员 id], escalate_after_secs, escalate_to_id}`，`weeks[0]` 是本周值班人（PUT 仅管理员） |

**通知与升级**：
- 渠道 `kind`：`in_app`（缺省，应用内推送，靠 WS `alert`）或 `webhook`：告警达到 `min_severity` 时 POST 到 `url`，
  `format` 为 `json`（缺省，`{text, alert}`）/ `feishu` / `dingtalk` / `wecom` / `slack`（纯文本消息）。
  非管理员 GET 时 `url` 只显示协议和主机（地址里通常带密钥）。
- 告警触发（warning 及以上）时给本周值班人发 `notice`。
- 超过 `escalate_after_secs` 仍是 `open`（未确认、未静默）的告警升级一次：给 `escalate_to_id` 发 `notice`，再走一遍 webhook。
- 每次通知、失败原因、升级都写进告警时间线（`tone: neutral`），并推 `changed: alerts`。

`PATCH /alerts/{id}` 的操作（观察者 403）：

| 前端操作 | 请求 | 说明 |
|---|---|---|
| 确认 | `{state: "doing"}` | 尚无处理人时当前用户成为处理人 |
| 指派 | `{assignee_id}` | 状态同时变为 doing；通知被指派人 |
| 关闭 | `{state: "closed", note}` | `note` 必填（400「关闭告警需要填写处理说明」） |
| 重新打开 | `{state: "open"}` | |
| 静默 | `{silenced_until: "…"}` / `{silenced_until: null}` | 只记录，不影响去重 |

每个操作都写时间线（tone `info`）和审计（如「确认告警「Charlie 电机过热」」）。告警新建和状态变化都推 WS `alert`
（前端收到后 `GET /alerts/{id}` 拿完整数据）以及 `changed: alerts`。

`auto_action`：`slow` 自动降速 · `stop` 自动停止 · `dock` 自动回桩（发送 `dock` 技能，机器人端需支持）·
`notify` 通知设备管理者和平台管理员（WS `notice`）。规则表单显示的「> 60 °C 持续 10 秒」由前端用 `op` / `threshold` / `duration_secs` 拼出。

告警规则可用的 `metric`：`max_motor_temp`、`battery`、`latency_ms`、`voltage`、`current`、`pitch`、`roll`，
以及遥测 `extra` 中的任意数值字段（如 `loc_confidence`）。

### 地图与任务（Missions.dc.html）

```json
Map = {"id": "b2", "name": "B 区 · 巡检层", "short_name": "B 区巡检层",
       "width_m": 48, "height_m": 30, "origin": [0, 0], "resolution_cm": 5, "updated_at": "…",
       "areas": [{"polygon": [[x, y], …], "label": "仓库", "outline": false}],   // outline=true 为外墙，只画边线
       "chargers": [[x, y]]}
Mission = {"id": "uuid", "name": "B 区巡检", "map_id": "b2",
           "assignee": {"device_id": "go2-03", "backup_device_id": "go2-04"},   // 或 {"preset_id": "showroom"}
           "schedule": "每天 09:00、14:00",       // 给人看的字符串
           "state": "running|scheduled|paused", "completed": 3, "loop": true,
           "waypoints": [{"name": "P1 · 配电柜", "x": 10.5, "y": 6.2, "yaw": 1.57, "stay_secs": 30, "retries": 2,
                          "actions": [{"name": "拍照", "detail": "前置相机 · 存档"},
                                      {"name": "挥手", "detail": "", "skill": "hello", "params": {}}]}],   // 带 skill 的动作到达后执行
           "created_by": "…", "created_at": "…", "updated_at": "…"}
ScheduleEntry = {"id": 1, "device_id": "go2-01", "start": "…", "end": "…", "label": "B 区巡检",
                 "kind": "run|charge|other", "mission_id": "… | null"}
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /maps | `Map[]` |
| GET / PATCH / DELETE | /maps/{id} | 编辑：管理员 / 设备管理者 |
| POST | /maps | 登记地图 `{id, name, short_name?, width_m, height_m, origin?, resolution_cm?, areas?, chargers?}` |
| POST | /maps/{id}/chargers | `{x, y}` 手动标注充电桩 → `Map` |
| POST | /maps/{id}/remap | 重新建图 → **501**（需要机器人端 SLAM） |
| GET / POST | /missions | 新建只需 `{name, map_id}`，其余默认 |
| GET / PATCH / DELETE | /missions/{id} | 运行 / 暂停 `{state}`；替换全部点位 `{waypoints}`；`{assignee, schedule, loop, completed}` |
| GET | /schedule?date=YYYY-MM-DD | 当天的排期 `ScheduleEntry[]`；日期按排期时区（`SCHEDULE_TZ_OFFSET_MINUTES`，默认北京时间），缺省今天 |
| POST / DELETE | /schedule(/{id}) | 手动加 / 删排期（自动生成的排期也可以删，任务修改后会重新生成） |

- 设备位置不放在地图里：用遥测的 `pose` + `map_id`（同一坐标系）。
- 变化推送 `changed: maps` / `missions` / `schedule`。

**任务执行（服务端调度器）**：
- **排期**：`schedule` 仍是给人看的字符串，服务端能识别「每天 / 工作日 / 周末 / 每周一、三、五 / 星期日」加若干 `HH:MM`
  （如「每天 09:00、14:00」「工作日 08:30」），时刻按排期时区解释。到点时 `scheduled` 的任务自动变成 `running`；
  `paused` 的任务不会被触发。识别不出时刻的任务只能手动运行（`PATCH {state: "running"}`）。
  当天还没开始的运行会自动出现在 `GET /schedule` 里（`kind: run`），任务改动后重新生成。
- **执行**：选设备（`assignee.device_id` 在线且未急停，否则 `backup_device_id`；`preset_id` 暂不支持）→ 以任务身份获取
  控制权（`lease.holder_kind = task`）→ 从第 `completed` 个点位开始，逐点下发
  `{"kind":"action","name":"navigate_to","params":{"map_id","x","y","yaw"}}`，机器人**到达后**回执（单点超时
  `MISSION_STEP_TIMEOUT_SECS`，默认 600 s）→ 执行该点带 `skill` 的动作 → 停留 `stay_secs` → `completed + 1`，推 `changed: missions`。
- 到达失败按 `retries` 重试，仍失败就跳过该点，并生成 warning 告警（`metric: mission_waypoint_failed`）。
- 一轮结束：`loop = true` 从头再来；否则回到 `scheduled`、`completed = 0`。
- **停止**：`PATCH {state: "paused" | "scheduled"}` 或删除任务时立即停止设备并释放控制权，`completed` 保留（暂停后再运行会从断点继续）。
  急停、设备掉线、控制权被收回 / 被占用、没有可用设备时，任务自动变为 `paused`，设备事件和审计里写明原因，并给任务创建者发 `notice`。
- 服务重启后，`running` 的任务从 `completed` 处继续。
- 机器人端需要提供 `navigate_to` 技能（模拟机器人已提供；Go2Agent 尚未提供，真机上会回执失败 → 重试 → 跳过并告警）。

### 录制与回放（Replay.dc.html）

当前录制内容 = 服务端持久化的 **1 Hz 遥测 + 指令日志**；视频、点云需要机器人端录制，暂不包含。

```json
Recording = {"id": "uuid", "name": "Charlie 电机过热", "device_ids": ["go2-03"], "start": "…", "end": "…",
             "size_bytes": 81920, "tags": ["alert|patrol|fleet|manual"],
             "tracks": [{"kind": "joints|commands", "segments": [[0.0, 0.4], [0.5, 1.0]]}],   // 有数据的时间段，0–1
             "events": [{"offset_ms": 12000, "label": "电机过热", "tone": "critical"}],
             "streams": "关节 / IMU / 电量 / 指令（视频与点云需机器人端录制）",
             "map_id": null, "source_id": "<告警 / 会话 id>", "clip_of": null, "created_by": null, "created_at": "…"}
```

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /recordings?tag=&device_id=&limit= | `Recording[]`，新的在前 |
| POST | /recordings | 手动标记一段 `{name, device_ids, start, end, tags?, map_id?}` |
| GET / DELETE | /recordings/{id} | |
| GET | /recordings/{id}/samples | 等分 120 点：`{chart_title, device_id, temperature[], velocity[], trajectory: [[x,y]], cloud: []}`（无数据的点为 null） |
| POST | /recordings/{id}/clip | `{from_ms, to_ms, name?}` → `{id}` |
| POST | /recordings/{id}/export | `{format?: "mcap" \| "rosbag"}`（可不带 body，缺省 mcap）→ `{url, filename, expires_at}`；rosbag → 501 |
| GET | /recordings/{id}/download?token= | 下载 MCAP（`export` 返回的 `url`，相对服务器地址；15 分钟有效，**不需要** Authorization 头）；链接无效或过期 403 |
| GET | /recordings/storage | `{used_bytes, total_bytes: null, retention_days, auto_rules}` |

- 自动录制：告警触发时录前后 60 秒（`alert.recording_id`），联调会话结束时录整段。
- 遥测、指令日志、设备日志、设备事件保留 `retention_days`（默认 30 天），每小时清理一次。
- 分享链接由前端生成 `uniconsole://replay/{id}?t=<秒>`。变化推送 `changed: recordings`。
- **MCAP 导出**（Foxglove Studio 可直接打开）：每个 topic 一个 JSON 通道，时间戳为纳秒——
  `/{device_id}/telemetry`（遥测完整报文，1 Hz）、`/{device_id}/commands`（`{actor, command, ok, error}`）、
  `/{device_id}/events`（`{text, tone}`）。需要 rosbag 时可用 `mcap convert` 转换。

### 设备运维（Maintenance.dc.html）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /firmware | `[{device_id, current, target, state, progress, error}]`；`state` 目前只会是 `latest · available · waiting_online` |
| GET / PUT | /firmware/release | `{latest: {"Unitree Go2 EDU": "v1.1.8"}, agent_version, notes: []}`（PUT 仅管理员） |
| POST | /firmware/upgrade · /firmware/schedule | → **501**（需要机器人端 OTA） |
| POST | /devices/{id}/rollback · /reboot · /terminal | → **501** |
| POST | /diagnostics | `{device_ids}`（1–50 台，需要「固件升级与远程终端」权限）→ `{url, filename, expires_at}`：服务端诊断包的签名下载链接 |
| GET | /diagnostics/download?devices=&token= | 下载诊断包 JSON（15 分钟有效，不需要 Authorization 头）：每台设备的设备信息、控制权、实时状态与最新遥测、最近 500 条日志、200 条事件、24 小时指令、7 天告警、1 小时遥测摘要，以及安全策略 |
| GET | /battery-health | `[{device_id, cycles: null, monthly: []}]`（机器人端尚未上报电池数据） |
| GET | /logs?device_id=&level=info\|warn\|error&limit= | `[{at, level, device_id, message}]`，来自机器人上报的事件 |
| GET / PUT | /maintenance-window | `{start_min, end_min}` 距零点的分钟数，可跨零点（默认 23:00–03:00） |

### 对讲与播报

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /intercom/targets | `[{id, label, device_ids}]`，`id` 为 `all` / `group:<分组 id>` / `device:<设备 id>` |
| GET | /intercom/presets | 常用播报语 `string[]`（设置键 `intercom_presets`） |
| POST | /intercom/broadcast | `{target_id, text}` → `{played, total, failed: [{device_id, message}]}`；`played` 为实际播放成功的设备数 |

- 播报 = 向每台设备下发 `{"kind":"action","name":"say","params":{"text"}}`，机器人端 TTS 播放后回执。
- `say` 不是运动指令（服务端 `Command::is_motion`、机器人端 `is_motion` 一致）：不需要控制权，急停中也可以播报。
- 权限：对设备有「申请 / 持有控制权」权限（观察者不能播报，使用者只能播报给被授权的设备）；无权限、离线、机器人失败的设备列在 `failed`。
  全部无权限时 403；`text` 为 1–200 字，否则 400。写审计。
- 按住说话（双向实时音频）走 WebRTC 音频轨，见 §4。模拟机器人提供 `say`；Go2Agent 端尚未注册该技能（会进 `failed`）。

### 智能体（独立服务，服务端鉴权与转发）

接口形状按前端交接文档 §12（`/agent/conversations`、`/agent/plans/{id}/run`、`/agent/skills` …），由智能体服务实现。

- `ANY /api/v1/agent/{路径}` 原样转发到 `AGENT_URL/{路径}`（方法、查询串、请求体、`Content-Type`），响应原样返回。
  没配置 `AGENT_URL` → 501；智能体服务连不上 → 502 `upstream_unavailable`；超过 60 秒 → 504。
- 转发时附加：`X-UniConsole-Member-Id`、`X-UniConsole-Member-Name`（百分号编码）、`X-UniConsole-Role`、
  `X-UniConsole-Token: <AGENT_TOKEN>`，以及成员自己的 `Authorization`。智能体执行计划时用这个令牌回调
  `POST /devices/{id}/commands` 等接口，控制权、急停、权限检查和成员亲自操作完全一样。
  HANDOFF §8.3 的规则（运动计划先确认再执行、`motion` 技能不能设为自动）由智能体服务保证。
- 流式回复：智能体 `POST /api/v1/internal/agent/events`（`Authorization: Bearer <AGENT_TOKEN>`）
  `{member_id, event: {type: agent_message | agent_delta | agent_plan, conversation_id, …}}` → 204，
  服务端经 `/api/v1/ws` 把 `event` 原样发给该成员的所有连接。

### 尚未实现（501）

| 接口 | 说明 |
|---|---|
| `POST /maps/{id}/remap` | 需要机器人端 SLAM 建图 |
| `POST /firmware/upgrade` · `/firmware/schedule`、`/devices/{id}/rollback` · `/reboot` · `/terminal` | 需要机器人端 OTA / 受控 shell |

### 交接文档 §16 的七项决定

| # | 问题 | 决定 |
|---|---|---|
| 1 | 地图坐标系 | 米 + 弧度，REP-103，见「单位与坐标」；前端负责换算成百分比 |
| 2 | 遥测角度单位 | 弧度 |
| 3 | 邀请成员的密码 | 方案一：`POST /members` 不传密码，返回一次性邀请链接 `invite_url`（7 天有效），对方打开后自己设密码 |
| 4 | 通用 `changed` 推送 | 加，见 §2 的 `changed.resource` 表 |
| 5 | 点云传输 | 过渡期走 WS 二进制帧（已实现，按设备开关），以后迁到 WebRTC 数据通道 |
| 6 | 智能体放哪 | 独立服务；服务端只做鉴权与转发（见「智能体」），未配置 `AGENT_URL` 时 501 |
| 7 | 急停演练 | 机器人协议的急停指令加 `drill` 标志（已实现），`POST /safety/drill` |

### 系统

`GET /healthz`（无前缀），`GET /api/v1/system/info`。

---

## 2. 前端 WebSocket：`GET /api/v1/ws?token=<jwt>`

连接后默认**不推送任何设备数据**，需要先订阅。

**上行**

```json
{"type": "subscribe", "device_ids": ["go2-01"]}   // 空数组 = 全部可见设备
{"type": "unsubscribe", "device_ids": ["go2-01"]}
{"type": "move", "device_id": "go2-01", "vx": 0.6, "vy": 0, "wz": -0.15}
{"type": "stop", "device_id": "go2-01"}
{"type": "pointcloud", "device_id": "go2-01", "enable": true}   // 开关点云二进制流（默认关）
{"type": "ping", "nonce": 1}
{"type": "webrtc_offer", "device_id": "go2-01", "session_id": "<前端生成的 UUID>", "sdp": "…", "streams": ["front", "depth"]}
{"type": "webrtc_ice", "device_id": "go2-01", "session_id": "…", "candidate": {…}}
{"type": "webrtc_close", "device_id": "go2-01", "session_id": "…"}
```

摇杆按 10–20 Hz 发送 `move`；松开后停止发送即可——机器人端看门狗 300 ms 内自动停止，
前端也应在松开时显式发一次 `stop`。

**断线保护**：WebSocket 断开时，服务器立即对该连接驱动过的设备补发停止；该成员**所有**连接都断开后，
`disconnect_stop_secs`（默认 3 s）后停止其控制的全部设备，`disconnect_release_secs`（默认 60 s）后仍未重连则释放其控制权。
重连后要重新 `subscribe`，并重新拉一次各列表。

**下行**（`type` 区分；带 `device_id` 的事件按订阅过滤，急停 / 全局事件全部推送）

```json
{"type": "telemetry", "device_id": "go2-01", "latency_ms": 18, "ts": "…", "battery": 86,   // 可能为 null
 "vx": 0.6, "vy": 0, "wz": -0.15, "roll": 0, "pitch": 0, "yaw": 1.2,
 "joint_temps": [[41,44,46],[40,43,45],[42,47,52],[39,42,44]],   // FL FR RL RR × hip thigh calf
 "foot_forces": [80,82,79,85], "voltage": 25.1, "current": 3.2,
 "pose": {"x": 1.2, "y": 3.4, "yaw": 1.2}, "map_id": "b2", "mode": "walk",
 "extra": {"acc": [0.01, -0.02, 9.81], "loc_confidence": 0.92, "battery_temp": 31.0}}
{"type": "device_status", "device_id": "…", "status": "online", "online": true, "location": null, "task": null}
{"type": "lease_changed", "device_id": "…", "lease": Lease | null, "queue_len": 1}   // lease 含完整 queue
{"type": "lease_requested", "device_id": "…", "request_id": "…", "requester": "林悦"}
{"type": "command_ack", "device_id": "…", "cmd_id": "…", "ok": true, "error": null}
{"type": "estop", "device_id": null | "go2-01", "active": true, "by": "Kanade"}
{"type": "alert", "alert_id": "…", "device_id": "…", "severity": "critical", "title": "电机过热", "state": "open"}
{"type": "robot_event", "device_id": "…", "level": "warning", "code": "fall", "message": "…"}
{"type": "device_event", "device_id": "…", "event": {"at": "…", "text": "Kanade 获得控制权", "tone": "info"}}
{"type": "changed", "resource": "members", "id": "… | null"}   // 通用失效通知：重新 GET 对应资源，见下表
{"type": "notice", "member_id": "…", "level": "info|warning", "text": "Kanade 收回了你对 Alpha 的控制权：…"}  // 只发给本人
{"type": "pong", "nonce": 1}
{"type": "webrtc_answer", "device_id": "…", "session_id": "…", "sdp": "…"}       // 视频信令只发给发起该 session 的那条连接
{"type": "webrtc_ice", "device_id": "…", "session_id": "…", "candidate": {…}}
{"type": "webrtc_close", "device_id": "…", "session_id": "…", "reason": "设备离线 | 机器人端尚未接入视频 | null"}
{"type": "error", "code": "forbidden", "message": "你没有该设备的控制权（只读）"}   // 上行消息失败，code 同 REST
```

**点云二进制帧**（`pointcloud` 开启后，约 5–10 Hz）：
`[device_id 长度 u8][device_id UTF-8][ts i64 LE，毫秒][N × (f32 x, f32 y) LE]`，单位米，机器人坐标系 +y 朝前、+x 朝右。
Go2 实机目前每秒最多 5 帧、每帧最多 6000 点。遥测 `extra.lidar.source` 区分 `pointcloud` 与
`height_map`；后者为高程图障碍投影。前端对同设备共享订阅，最后一个观看者离开时关闭，断线或 2 秒无帧清空。
WebSocket 写出与消息接收独立：可靠事件优先，点云只保留一个待发帧，满时丢帧；
单次写出超过 2 秒或可靠队列溢出会断开连接并执行原有断线停止，避免慢客户端无限积压。

`changed.resource` 取值（`id` 为空表示整个列表都变了）：

| resource | 重新拉取 |
|---|---|
| `members` | `GET /members`（也用于成员上线 / 下线） |
| `audit` | `GET /audit` |
| `devices` | `GET /devices`（注册、删除、改名、改分组） |
| `device_groups` | `GET /device-groups` |
| `leases` | `GET /leases`（同时也会推 `lease_changed`） |
| `safety` | `GET /safety`（急停、策略、演练） |
| `fleet_sessions` | `GET /fleet-sessions` |
| `fleet_presets` | `GET /fleet-presets` |
| `zones` | `GET /zones` |
| `alerts` | `GET /alerts`（单条用 `id`） |
| `alert_rules` | `GET /alert-rules` |
| `alert_channels` / `on_call` | `GET /alert-channels` / `GET /on-call` |
| `maps` / `missions` / `schedule` | `GET /maps` / `GET /missions` / `GET /schedule` |
| `recordings` | `GET /recordings` |
| `firmware` / `maintenance_window` | `GET /firmware` / `GET /maintenance-window` |

---

## 3. 机器人 WebSocket：`GET /api/v1/robot/ws`

请求头：`Authorization: Bearer <device_token>`、`X-Device-Id: <device_id>`。
机器人**主动外连**服务器（适配 NAT / 4G），指令经同一连接下发。

```
robot → hello {protocol, model, firmware, sn, ip, capabilities[], skills[{name, description, tags, motion}], sensors?}
server → welcome {protocol, server_time, estop, telemetry_hz, max_speed_mps, max_yaw_rate,
                  lost_link_action, heartbeat_timeout_ms}
robot → state {status, location, task}
robot → telemetry {...}           // telemetry_hz，默认 10 Hz
server → ping {nonce}  ◀▶  robot → pong {nonce}     // 每秒，用于测延迟
server → command {cmd_id, command}
robot → ack {cmd_id, ok, error}   // move 成功不回执
robot → event {level, code, message}   // level=critical/warning 自动生成告警；code=estop 同步急停
robot → <binary> [ts i64 LE][N × (f32 x, f32 y) LE]   // 点云二维投影，服务器加上设备 id 转发给订阅的前端
server → webrtc_offer {session_id, sdp, streams[], ice_servers[]}  ◀▶  robot → webrtc_answer {session_id, sdp}
server → webrtc_ice {session_id, candidate}                        ◀▶  robot → webrtc_ice {session_id, candidate}
server → webrtc_close {session_id}                                 ◀▶  robot → webrtc_close {session_id, reason?}
server → zones {zones: [{id, map_id, name, zone_type, polygon, speed_limit_mps}]}   // 连接时和围栏变化时；机器人端目前只保存
```

急停指令 `{"kind":"estop","drill":true}` 是**演练**：机器人走一遍急停链路并回执，但不驱动硬件、不进入急停状态。

`hello.skills` 是机器人端可执行的技能目录（Go2 后端为 Go2Agent 注册的 44 个技能），服务器存入
`devices.meta.skills`；前端用它渲染动作按钮，并用 `{"kind":"action","name":"<技能名>","params":{…}}` 下发。
参数校验由 Go2Agent 完成，失败原因经 `ack.error` 返回。

服务器超过 `heartbeat_timeout_ms`（默认 1500 ms）收不到任何消息即判定离线。
机器人端断线即停止运动，并以 1 s → 30 s 指数退避重连。

---

## 4. 视频：WebRTC 信令

服务器**只转发信令**，媒体由机器人直接推给前端（局域网直连，或经 TURN 中继）。消息形状见 §2 / §3。

- 一路视频 = 一个前端生成的 `session_id`（1–128 字符，建议 UUID），归属发起它的那条 WS 连接：
  answer / ice / close 只回给这条连接；其他连接用这个 id 发 ice / close 返回 `forbidden`，再发 offer 返回 `conflict`。
- 权限：「查看视频与传感器」（观察者 / 使用者只能看被授权的设备）。设备离线 → `robot_offline`；
  设备 hello 的 `capabilities` 里没有 `webrtc` → `not_implemented`（前端显示「尚未接入」）。
- 同一连接对同一 `session_id` 再发 offer = 重新协商，直接转发。
- 前端连接断开：服务器替它向机器人发 `webrtc_close`。机器人掉线：前端收到 `webrtc_close`（`reason: "设备离线"`）。
- 机器人拒绝（例如还没接入相机推流）时回 `webrtc_close` 带 `reason`，原样转给前端。

**ICE 服务器**：`GET /api/v1/webrtc/ice-servers` → `[{urls, username?, credential?, expires_at?}]`，
offer 转发给机器人时附带同一份。
- `ICE_SERVERS`：静态 JSON 数组（如公共 STUN），缺省 `[]` = 仅局域网直连。
- `TURN_URLS`（逗号分隔）+ `TURN_SECRET`：追加一条**限时** TURN 凭据（coturn `use-auth-secret`）：
  `username = "<过期 Unix 时间>:<成员 id>"`，`credential = base64(HMAC-SHA1(TURN_SECRET, username))`，
  有效期 `TURN_TTL_SECS`（默认 12 小时）。前端在 `expires_at` 之前重新获取即可。

Go2 机器人端使用 Go2Agent `perception.go2_front` 采集前置相机，通过 aiortc 推流。
安装 `video` 可选依赖并设置 `VIDEO_ENABLED=1` 后声明 `webrtc`，目前支持 `streams: ["front"]`，
默认 640×360、10 帧/秒、最多两个观看会话。answer 的 SDP 包含已收集的 ICE candidate；
客户端可发送 trickle ICE。客户端重试应使用新的 `session_id`，狗端会关闭重复使用的会话。
缺失相机、失帧或协商失败通过 `webrtc_close.reason` 返回；视频不包含音频，也不需要控制权租约。
公网 TURN 已部署到 `1.13.195.109:3478`，后端优先提供 TCP 中继以适配受限 UDP 网络。
安装脚本、端口与验证范围见 [TURN 部署](../deploy/turn.md)。
