# UniConsole 接口文档

```
机器人（Python FastAPI 代理） ──WS 外连──▶  服务器（Rust / axum） ◀──REST + WS──  前端（Flutter）
                                              │
                                          PostgreSQL
```

- REST 前缀 `/api/v1`，JSON 字段 **snake_case**，时间为 RFC 3339（UTC）。
- 认证：`Authorization: Bearer <jwt>`；WebSocket 可用 `?token=<jwt>`。
- 可选请求头 `X-Client: macOS · 1.0.0`，写入审计日志的「客户端」列。
- 错误统一为 `{"error": {"code": "...", "message": "..."}}`：

| HTTP | code | 场景 |
|---|---|---|
| 400 | bad_request | 参数错误 |
| 401 | unauthorized | 未登录 / 令牌无效 |
| 403 | forbidden | 角色权限不足、没有控制权 |
| 404 | not_found | |
| 409 | conflict | 已存在、申请已处理、设备被他人控制 |
| 423 | estop_active | 急停中拒绝运动指令 |
| 503 | robot_offline | 设备不在线 |
| 504 | timeout | 等待机器人回执超时 |

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

---

## 1. REST

### 认证与成员（Roles.dc.html）

| 方法 | 路径 | 说明 | 权限 |
|---|---|---|---|
| POST | /auth/login | `{handle, password}` → `{token, expires_in, member}` | 公开 |
| GET | /auth/me | 当前成员 | 登录 |
| GET | /members | 成员列表 | 登录 |
| POST | /members | `{handle, name, password, role, color?, expires_at?}` | 管理员 |
| PATCH | /members/{id} | `{name?, role?, color?, expires_at?, disabled?, password?}` | 管理员；本人可改名字/颜色/密码 |
| DELETE | /members/{id} | | 管理员 |
| GET / PUT | /members/{id}/devices | 授权设备 `{device_ids: []}` | 管理员 / 管理者（仅自己管理的设备） |
| GET | /audit?limit=&before= | 审计日志（按 id 倒序分页） | 管理员 |

### 设备（Main / Control / Sensors / Maintenance）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /devices?status=&group=&q= | 设备列表（按可见范围过滤），见下方 DeviceView |
| POST | /devices | 注册设备（管理员）→ `{device, token}`，**token 只返回这一次** |
| GET / PATCH / DELETE | /devices/{id} | PATCH: `{name?, group?, location?, owner_id?, meta?}` |
| POST | /devices/{id}/token | 轮换机器人接入令牌（管理员） |
| GET | /devices/{id}/telemetry/latest | 最新一帧遥测 |
| GET | /devices/{id}/telemetry?from=&to=&limit= | 抽样历史（默认最近 1 小时，1 Hz） |
| POST | /devices/{id}/commands | `{command, wait?=true}` → `{cmd_id, ok, error}` |
| GET | /devices/{id}/commands?limit= | 指令日志 |
| POST | /devices/{id}/estop | `{active: bool}` 单机急停 / 解除 |

`DeviceView`（数据库字段 + 实时状态）：

```json
{
  "id": "go2-01", "name": "Alpha", "code": "GO2-01", "model": "Unitree Go2 EDU", "kind": "dog",
  "sn": "GO2E-24A0137", "firmware": "v1.1.7", "ip": "192.168.123.161", "group": "巡检队",
  "owner_id": "…", "status": "busy", "location": "B 区 · 2 号走廊", "current_task": "巡检路线 B-2",
  "last_seen_at": "…", "meta": {}, "created_at": "…", "updated_at": "…",
  "online": true, "battery": 86.0, "latency_ms": 18, "max_motor_temp": 46.0, "uptime_secs": 11520,
  "estop": false,
  "lease": { "holder_kind": "user", "holder_id": "…", "source": "单机操控", "expires_at": "…", … }
}
```

`command`（`kind` 区分）：

```json
{"kind": "move", "vx": 0.6, "vy": 0, "wz": -0.15}     // 高频请走 WebSocket
{"kind": "stop"}
{"kind": "set_mode", "mode": "stand|down|balance|walk|stairs|damp|recovery"}
{"kind": "set_speed", "level": "slow|normal|fast"}  // 0.3 / 0.8 / 1.5 m/s
{"kind": "estop"} / {"kind": "release_estop"}
{"kind": "action", "name": "hello", "params": {}}
```

### 控制权（Lease.dc.html）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /leases | 每台可见设备的 `{device_id, name, code, lease, holder_name, queue_len}` |
| POST | /devices/{id}/lease | `{reason?, expected_secs?}` → `{"result":"granted","lease"}` 或 `{"result":"queued","request"}` |
| POST | /devices/{id}/lease/renew | 续约（默认 300 s；建议剩余 1/3 时自动续约） |
| DELETE | /devices/{id}/lease?force= | 释放；`force=true` 为管理者强制收回 |
| POST | /devices/{id}/lease/transfer | `{"kind":"user","id":"…"}` 或 `{"kind":"task","id":"<mission id>"}` |
| GET | /devices/{id}/lease/requests | 待处理申请队列 |
| POST | /lease-requests/{id}/approve · /deny | 当前持有者 / 管理员 / 设备管理者 |

### 多机联调（Fleet.dc.html）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET / POST | /fleet-sessions | `{name?, device_ids?, leader_id?, formation?, spacing?, timeline?}` |
| GET / PATCH / DELETE | /fleet-sessions/{id} | |
| POST | /fleet-sessions/{id}/start | 一次性获取所有设备租约（任一被占用则整体失败 409） |
| POST | /fleet-sessions/{id}/stop | 全部停止并释放租约 |
| POST | /fleet-sessions/{id}/commands | `{command, device_ids?}` → 每台设备的 `{device_id, ok, error}` |

### 任务 / 安全 / 告警

| 方法 | 路径 | 说明 |
|---|---|---|
| GET / POST | /missions | `{name, map_id, waypoints[], schedule?, assignee{}, state?}` |
| GET / PATCH / DELETE | /missions/{id} | |
| GET | /safety | `{global_estop, estop_by, estop_at, active_zones, policies}` |
| PATCH | /safety/policies | 局部更新策略字段（未知字段 400） |
| POST | /safety/estop | `{active}` 全局急停（任何人可触发；默认解除需管理者） |
| GET / POST | /zones?map_id= | `{map_id, name, zone_type, polygon: [[x,y],…], rule?, scope?, schedule?, action?}` |
| PATCH / DELETE | /zones/{id} | |
| GET | /alerts?state=&severity=&device_id=&limit= | |
| GET | /alerts/{id} | `{alert, events[]}`（事件时间线） |
| PATCH | /alerts/{id} | `{state: open|doing|closed, note?}` |
| POST | /alerts/{id}/events | `{message}` 备注 |
| GET / POST | /alert-rules | `{name, metric, op: > < >= <=, threshold, duration_secs, severity, auto_action?: slow|stop}` |
| PATCH / DELETE | /alert-rules/{id} | |

告警规则可用的 `metric`：`max_motor_temp`、`battery`、`latency_ms`、`voltage`、`pitch`、`roll`，
以及遥测 `extra` 中的任意数值字段（如 `loc_confidence`）。

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
{"type": "ping", "nonce": 1}
```

摇杆按 10–20 Hz 发送 `move`；松开后停止发送即可——机器人端看门狗 300 ms 内自动停止，
前端也应在松开时显式发一次 `stop`。WebSocket 断开时服务器会对该连接驱动过的设备补发停止。

**下行**（`type` 区分；带 `device_id` 的事件按订阅过滤，急停 / 全局事件全部推送）

```json
{"type": "telemetry", "device_id": "go2-01", "latency_ms": 18, "ts": "…", "battery": 86,   // 可能为 null
 "vx": 0.6, "vy": 0, "wz": -0.15, "roll": 0, "pitch": 0, "yaw": 1.2,
 "joint_temps": [[41,44,46],[40,43,45],[42,47,52],[39,42,44]],   // FL FR RL RR × hip thigh calf
 "foot_forces": [80,82,79,85], "voltage": 25.1, "current": 3.2,
 "pose": {"x": 1.2, "y": 3.4, "yaw": 1.2}, "mode": "walk", "extra": {}}
{"type": "device_status", "device_id": "…", "status": "online", "online": true, "location": null, "task": null}
{"type": "lease_changed", "device_id": "…", "lease": {…} | null, "queue_len": 1}
{"type": "lease_requested", "device_id": "…", "request_id": "…", "requester": "林悦"}
{"type": "command_ack", "device_id": "…", "cmd_id": "…", "ok": true, "error": null}
{"type": "estop", "device_id": null | "go2-01", "active": true, "by": "Kanade"}
{"type": "alert", "alert_id": "…", "device_id": "…", "severity": "critical", "title": "电机过热", "state": "open"}
{"type": "robot_event", "device_id": "…", "level": "warning", "code": "fall", "message": "…"}
{"type": "pong", "nonce": 1}
{"type": "error", "message": "你没有该设备的控制权（只读）"}
```

---

## 3. 机器人 WebSocket：`GET /api/v1/robot/ws`

请求头：`Authorization: Bearer <device_token>`、`X-Device-Id: <device_id>`。
机器人**主动外连**服务器（适配 NAT / 4G），指令经同一连接下发。

```
robot → hello {protocol, model, firmware, sn, ip, capabilities[], skills[{name, description, tags}]}
server → welcome {protocol, server_time, estop, telemetry_hz, max_speed_mps, max_yaw_rate}
robot → state {status, location, task}
robot → telemetry {...}           // telemetry_hz，默认 10 Hz
server → ping {nonce}  ◀▶  robot → pong {nonce}     // 每秒，用于测延迟
server → command {cmd_id, command}
robot → ack {cmd_id, ok, error}   // move 成功不回执
robot → event {level, code, message}   // level=critical/warning 自动生成告警；code=estop 同步急停
```

`hello.skills` 是机器人端可执行的技能目录（Go2 后端为 Go2Agent 注册的 44 个技能），服务器存入
`devices.meta.skills`；前端用它渲染动作按钮，并用 `{"kind":"action","name":"<技能名>","params":{…}}` 下发。
参数校验由 Go2Agent 完成，失败原因经 `ack.error` 返回。

服务器超过 `heartbeat_timeout_ms`（默认 1500 ms）收不到任何消息即判定离线。
机器人端断线即停止运动，并以 1 s → 30 s 指数退避重连。

---

## 4. 视频（未实现）

按 HANDOFF 预期走 WebRTC：服务器只做信令（预留在 `/api/v1/ws` 上增加 `webrtc_offer / answer / ice` 消息），
媒体流由机器人端直接推到 SFU / 浏览器。
