# 前端 → 后端交接：接口需求

本文写给做服务端（`../server`）的人，说明 Flutter 前端需要哪些接口、每个字段怎么用。
以 `../server/docs/API.md` 为基础，逐条对照前端的 Repository 接口
（`lib/data/repositories/repositories.dart`）列出：

- **已有**：API.md 里已经有，前端直接接。
- **补字段**：接口有了，但前端界面还要用到几个字段。
- **缺接口**：API.md 里没有。这里给的是**建议形状**，后端可以改，改了告诉前端即可。

前端目前全部用 mock（`lib/data/mock/`）。接后端时只替换 Repository 实现，界面不动。
mock 里的行为（权限规则、状态变化、审计日志写法）就是前端对后端的预期，有疑问可以直接看对应 mock。

**说明：**
- 字段名都按 API.md 的约定写成 snake_case。
- 「→」左边是请求，右边是响应。
- 「前端」指 `frontend/`。

---

## 0. 速览

| 模块 | 前端接口 | 状态 | 本文 |
|---|---|---|---|
| 认证 | 登录、当前用户 | 已有；前端还没做登录页 | §2 |
| 设备 | `DeviceRepository` | 补字段；缺分组、事件 | §3 |
| 遥测 | `TelemetryRepository` | 已有；单位要确认 | §3.3 |
| 感知 | `SensorRepository` | 缺接口（点云、传感器状态） | §3.4 |
| 操控 | `ControlRepository` | 已有；补指令日志格式 | §3.5 |
| 控制权 | `LeaseRepository` | 补字段 | §4 |
| 多机联调 | `FleetRepository` | 补字段；缺预设 | §5 |
| 安全 | `SafetyRepository` | 补字段；缺演练、地图 | §6 |
| 告警 | `AlertRepository` | 补字段；缺指派、静默、远程趴下、通知渠道、值班 | §7 |
| 地图与任务 | `MissionRepository` | 缺地图、排期；任务字段要补 | §8 |
| 录制与回放 | `RecordingRepository` | 全部缺 | §9 |
| 设备运维 | `MaintenanceRepository` | 全部缺 | §10 |
| 成员与权限 | `MemberRepository` | 补字段；邀请流程要定 | §11 |
| 智能体 | `AgentRepository` | 全部缺 | §12 |
| 对讲 | `IntercomRepository` | 全部缺（依赖音频通道） | §13 |
| 设置 | `PreferencesRepository` | 全部缺 | §14 |
| 视频 | — | API.md §4 未实现 | §15 |

**建议的实现顺序：**
1. 认证、设备、遥测、操控、控制权、急停。这几项打通后，单机操控就能跑真实设备。
2. 告警、安全、联调。
3. 成员、审计、设置。
4. 地图与任务、运维、录制。
5. 智能体、对讲、视频。

---

## 1. 全局约定

### 1.1 前端会怎么调用
- **令牌：**登录拿到 JWT，存在系统钥匙串里。
  - REST 用 `Authorization: Bearer`，WS 用 `?token=`。
  - 收到 401 时清掉令牌，回到登录页。
- **请求头：**每个请求带 `X-Client: <平台> · <版本>`，如 `macOS · 1.0.0`、`iOS · 1.0.0`。审计日志的「客户端」列直接显示它。
- **WS：**全局只连一条 `/api/v1/ws`。
  - 断线后按 1 s → 30 s 指数退避重连。
  - 重连后重新 `subscribe`，并重新拉一次各列表。
- **列表：**统一做法是「REST 拉全量 + WS 增量」。WS 没有专门事件的资源，前端靠下面的 `changed` 消息重新拉。

### 1.2 新增 WS 下行消息：`changed`（建议）

很多资源（任务、联调会话、成员、围栏、规则、固件状态……）不值得每种都设计增量消息。
建议加一个通用的失效通知，前端收到后重新 GET 对应列表：

```json
{"type": "changed", "resource": "missions", "id": "m-12"}
```

`resource` 的取值见各节标注的「changed:xxx」。`id` 可为空，表示整个列表都变了。

### 1.3 错误
- 格式按 API.md：`{"error": {"code", "message"}}`。前端会把 `message` **原样显示**给用户，所以请写成给人看的中文，比如「Echo 正在联调会话 #12 中」。
- 前端按 `code` 分支的地方：

| code | 前端行为 |
|---|---|
| `forbidden` | 提示无权限；操控页切到只读 |
| `conflict` | 提示 message。联调发起失败时还会标红冲突设备，见 §5 |
| `estop_active` | 急停提示条；运动按钮保持禁用 |
| `robot_offline` / `timeout` | 指令日志里标红 |
| `bad_request` | 表单旁显示 message |

- **建议**：409 冲突带上相关设备，前端用它标红：
  ```json
  {"error": {"code": "conflict", "message": "…", "device_ids": ["go2-05"]}}
  ```

### 1.4 时间、单位、坐标
- 时间用 RFC 3339 UTC，由前端转成本地时间。时长一律用 `*_secs` 或 `*_ms` 整数。
- 百分比用 0–100，电量也是。
- **角度**
  - 遥测里的 `roll` / `pitch` / `yaw` 请在 API.md 写明单位。前端界面显示「度」，如果后端给的是弧度，前端来换算。示例里的 `1.2` 看起来是弧度。
- **地图坐标（需要后端确认）**
  - 前端界面内部用「地图宽高的 0–100 百分比，y 向下」。
  - 建议 API 用机器人导航的地图坐标系：单位米，原点在地图左下角，x 向右、y 向上，角度用弧度、逆时针为正、0 指向 +x（ROS REP-103）。
  - 再在 `GET /maps` 里给出 `width_m` / `height_m`（以及非零原点时的 `origin`），前端据此换算。
  - 下文的 `position` / `polygon` / `pose` 都按这个约定。

### 1.5 权限
- 服务端按 `RolePermission.matrix`（`lib/data/models/member.dart`，Roles 页的权限矩阵）校验。
- ◐ 表示「自己管理的设备（`owner_id` 是自己）+ 被授权的设备（`/members/{id}/devices`）」。
- 平台管理员能访问全部设备。观察者只能查看。
- 急停任何人都能触发。

### 1.6 审计
- 前端 mock 里**每个改变状态的操作都写一条审计**，见 `MockWorld.log` 的调用处。
- 服务端请在同样的地方落审计，`action` 写成完整的人话。前端直接显示 `action`，不自己拼。
- 例子：
  - 「批准 林悦 的控制权申请（Alpha）」
  - 「确认告警「Charlie 左后腿电机过热」」
  - 「远程终端 Alpha：`systemctl restart lidar`」

---

## 2. 认证

| 状态 | 接口 | 说明 |
|---|---|---|
| 已有 | `POST /auth/login`、`GET /auth/me` | |
| 缺 | `POST /auth/logout` | 让当前令牌失效（设置 › 退出登录） |
| 缺 | 二次验证 | 见 §14。远程终端要求二次验证后才能打开（§10） |

**说明：**
- `member` 的字段见 §11。
- 前端还没有登录页，这部分要前端补，接口按现有的来。
- 登录页要能显示「账号已停用」「账号已过期」，请分别给出 message，code 用 `forbidden`。

---

## 3. 设备

### 3.1 `GET /devices`：补字段

前端的 `Device`（`lib/data/models/device.dart`）在 `DeviceView` 之外还要：

| 字段 | 用途 | 说明 |
|---|---|---|
| `group_id` | 侧边栏「设备分组」筛选 | 现在只有 `group`（名字）。建议改成引用分组 id，见 §3.2 |
| `user_id` | 「使用者」列、卡片上的头像 | 当前持有控制权的成员，前端可以从 `lease.holder_kind == "user"` 推出来，**不加也行** |

对现有字段的使用：
- `battery`：可以是浮点，前端取整。
- `max_motor_temp`：离线时请给 `null`。
- `latency_ms`：离线时请给 `null`。
- `uptime_secs`：可为 `null`。
- `estop`：单机急停状态，前端靠它判断「急停中」。
- 列表字段 `current_task`、`location`：前端展示 `device_status` 推下来的最新值。

`DeviceView.lease` 请和 §4 的 Lease 用同一个形状。

### 3.2 设备分组（缺）

```
GET /device-groups → [{"id": "patrol", "name": "巡检队", "tone": "busy"}]
```

- `tone` 是界面颜色名，取值 `online | busy | warning | action | critical | neutral`。
- 分组的增删改可以以后再做（前端暂时没有编辑界面）。changed:`device_groups`。

### 3.3 遥测：已有

前端 `Telemetry`（`lib/data/models/telemetry.dart`）对应 WS `telemetry`，另外从 `extra` 读这几个字段：

| `extra` 键 | 用途 |
|---|---|
| `acc` | `[ax, ay, az]` m/s²，感知页 IMU |
| `loc_confidence` | 0–1，定位置信度 |
| `battery_temp` | °C，操控页电池温度 |

**单位：**
- `roll` / `pitch` / `yaw` 的单位请写明，见 §1.4。
- `joint_temps` 和 `foot_forces` 的顺序按 API.md：FL FR RL RR × hip thigh calf。

**`GET /devices/{id}/telemetry?from=&to=`：**告警详情的曲线要用（§7），一次取触发前 30 分钟。请给出返回格式，建议如下：

```json
{"samples": [{"ts": "…", "battery": 86, "max_motor_temp": 46, "latency_ms": 18, "voltage": 25.1, "pitch": 0.1, "roll": 0, "extra": {}}]}
```

### 3.4 感知（缺）

```
GET /devices/{id}/sensors →
{
  "lidar": "4D LiDAR · 360°×90° · 21,600 点/秒 · 10 Hz",
  "cameras": [{"name": "前置 RGB", "detail": "1280×720 · 30 fps", "health": "ok|degraded|idle", "hz": 30}],
  "topics":  [{"name": "/utlidar/cloud", "detail": "PointCloud2", "health": "ok", "hz": 10}]
}
```

- 摄像头和话题的状态可以由机器人 `hello.capabilities` 加上遥测统计得出。
- 状态变化时发 changed:`sensors`（带 device id）。

**点云：**
- 前端要的是机器人坐标系下的二维投影点，单位米，+y 朝前、+x 朝右，约 10 Hz。
- 数据量大，不适合走 JSON WS。建议和视频一起走 WebRTC 数据通道（§15）。
- 过渡方案：WS 下行二进制帧 `[device_id 长度 u8][device_id][ts i64 ms][N × (f32 x, f32 y)]`，前端按订阅接收。

### 3.5 操控：已有

| 前端调用 | 接口 |
|---|---|
| `move` / `stop` | WS `move` / `stop` |
| `send` | `POST /devices/{id}/commands` |
| `setEstop` | `POST /devices/{id}/estop` |
| `watchEstop` | WS `estop` |
| `watchLog` | `GET /devices/{id}/commands` |

**指令日志：**`GET /devices/{id}/commands` 的返回格式请定下来。建议：

```json
[{"cmd_id": "…", "at": "…", "command": {"kind": "set_mode", "mode": "stand"}, "ok": true, "error": null, "by": "Kanade"}]
```

- `error` 用 API 错误码（`estop_active`、`robot_offline`、`timeout`、`forbidden`），前端翻译成中文。
- 新指令执行完后，通过 WS `command_ack` 推送。

**设备事件（缺）：**
- 用在 Main 页「最近事件」和设备详情。
- 需要一个历史接口，增量继续走 WS `robot_event`、`device_status`、`lease_changed`：

```
GET /devices/{id}/events?limit=20 → [{"at": "…", "text": "Kanade 获得控制权", "tone": "info|success|warning|critical|neutral"}]
```

**设备技能：**
- 前端从 `devices.meta.skills` 渲染动作按钮。
- 请在每个技能上加 `motion: bool`，表示会不会让设备运动。急停中前端会禁用运动技能，智能体也要用这个字段（§12）。

---

## 4. 控制权

前端 `Lease`（`lib/data/models/lease.dart`）：

```json
{
  "device_id": "go2-01",
  "holder_kind": "user|task|session",
  "holder_id": "kanade",
  "source": "单机操控",
  "acquired_at": "…",
  "expires_at": "… | null",
  "queue": [{"id": "req-1", "user_id": "linyue", "reason": "调试步态", "expected_secs": 900, "created_at": "…"}]
}
```

**要补的：**
- **`acquired_at`：**页面显示「已控制 41 分钟」。
- **`holder_kind: "session"`：**联调会话持有控制权时用，`holder_id` 是会话 id。会话结束前 `expires_at` 为 `null`。
- **`GET /leases`：**请把 `queue` 整个带上，不只是 `queue_len`。控制权页要列出每台设备的申请人和理由，逐台再请求 `/lease/requests` 太慢。
- **强制收回要有原因：**`DELETE /devices/{id}/lease?force=true` 请接受 body `{"reason": "…"}`，或者 query `&reason=`。原因写进审计，并通知被收回的人。
- **转交备注：**`POST /devices/{id}/lease/transfer` 接受可选的 `note`。
- **`lease_changed`（WS）：**希望直接带完整 lease（包括 queue），前端就不用再拉一次。

**规则（前端 mock 的行为，见 `mock_leases`）：**
- 设备空闲时，申请直接获得；否则进入队列。
- 申请是幂等的：
  - 持有者再申请，直接返回 `granted`。
  - 已在队列里的人再申请，返回 `queued`，不会重复排队。
- 批准、拒绝、转交：只有持有者、设备管理者、平台管理员能做（403）。申请已处理过时返回 409。
- 强制收回：只有设备管理者、平台管理员能做（403）。
- 联调会话持有的设备不能转交，要先结束会话或移出设备（409）。
- 租约规则（期限、空闲释放、断线停止、断线释放）来自 `/safety` 的 policies，见 §6。

---

## 5. 多机联调

前端 `FleetSession`（`lib/data/models/fleet.dart`）要的字段：

```json
{
  "id": "fs-12", "number": 12, "title": "展厅迎宾",
  "initiator_id": "kanade", "started_at": "…",
  "device_ids": ["go2-05", "go2-06"],
  "formation": "v", "spacing": 1.2, "preset_id": "showroom",
  "control_mode": "领队-跟随", "clock_sync": "PTP · 局域网", "lost_link_action": "原地趴下",
  "clock_skew_ms": 3,
  "timeline": [{"device_id": "go2-05", "start_ms": 0, "end_ms": 2000, "action": "stand", "kind": "pose|move|act"}],
  "timeline_length_ms": 16000,
  "last_receipt": {
    "label": "同步站立", "sent_at": "…", "schedule_offset_ms": 200,
    "acks": [{"device_id": "go2-05", "ok": true, "latency_ms": 22, "error": null}]
  },
  "paused": false
}
```

**字段说明：**
- `device_ids` 的第一台是领队。
- **`number`：**会话编号，界面显示「联调会话 #12」。请服务端自增。
- **`paused`：**全局急停时，所有会话变成暂停。
- **`commands` 回执：**`POST /fleet-sessions/{id}/commands` 的回执请带 `latency_ms`，前端显示每台的延迟。也请带 `schedule_offset_ms`，表示各设备在同一时刻执行时，相对发出时刻的偏移。

**行为：**
- **加入 / 移出设备：**`PATCH /fleet-sessions/{id} {device_ids}`。加入时会话接管该设备的控制权。设备被别人占用时返回 409，并带 `device_ids`（§1.3）。
- **最后一台退出（建议）：**会话自动结束。目前 mock 只在智能体回桩计划里这样处理，服务端最好统一。
- **改队形：**`PATCH {formation}`。
- **发起：**前端调用 `POST /fleet-sessions` 再调 `/start`。任一设备不可用就整体失败，前端标红冲突设备。如果后端愿意，可以合并成一个 `POST /fleet-sessions?start=true`。
- changed:`fleet_sessions`。

**联调预设（缺）：**

```
GET  /fleet-presets → [{"id", "name", "device_ids", "formation", "spacing"}]
POST /fleet-presets {name, session_id}      // 把当前会话保存为预设
POST /fleet-sessions {preset_id}            // 按预设发起
```

---

## 6. 安全

`GET /safety` 的形状，前端是 `SafetyState` / `SafetyPolicies`（`lib/data/models/safety.dart`）：

```json
{
  "global_estop": false, "estop_by": "Kanade", "estop_at": "…", "last_drill_at": "…",
  "policies": {
    "auto_dock": true, "dock_threshold": 20,
    "heartbeat_timeout_ms": 1500, "lost_link_action": "stop|down|dock",
    "lease_expiry_action": "stop_release|stop_only",
    "speed_limit": 1.5, "stop_near_people": true, "min_distance": 0.8,
    "fall_detection": true, "collision_detection": true, "cliff_detection": true,
    "release_needs_manager": true, "hardware_remotes": 2,
    "lease_term_secs": 300, "idle_release_secs": 600,
    "disconnect_stop_secs": 3, "disconnect_release_secs": 60
  }
}
```

**说明：**
- `estop_by` 是显示名，不是 id。
- policies 的字段名请以这份为准，或者告诉前端你们用的名字。`PATCH /safety/policies` 会对未知字段返回 400，所以两边必须一致。
- 解除全局急停：`release_needs_manager` 为 true 时，非管理者调用 `{active:false}` 返回 403，message 写「需要管理者解除」。

**急停演练（缺）：**

```
POST /safety/drill → {"at": "…", "responses": [{"device_id": "go2-01", "ms": 180}]}
```

- 演练会给每台在线设备下发「演练急停」，测量从下发到确认停止的耗时。设备不会真的停机，需要机器人协议支持一个 `drill` 标志。
- 演练完成后要更新 `last_drill_at`。

**围栏：**
- `zone` 的 `rule` / `scope` / `schedule` / `action` 前端都按**字符串**显示，比如「限速 0.3 m/s」「全部设备」「全天」「停止并告警」。
- 如果后端要结构化，请另给一个 `*_label` 字段，前端直接显示。
- `polygon` 按 §1.4 的坐标系。前端目前只编辑矩形，也就是 4 个点。
- changed:`zones`。

---

## 7. 告警

前端 `Alert`（`lib/data/models/alert.dart`）在现有字段之外还要：

| 字段 | 用途 |
|---|---|
| `metric_label` | 曲线标题，如「RL_calf 电机温度（°C）」 |
| `metric` / `threshold` | 画曲线和阈值线，从触发的规则来 |
| `location` | 触发位置，如「C 区仓库」「联调会话 #11」 |
| `assignee_id` | 处理人 |
| `silenced_until` | 静默到期时间 |
| `recording_id` | 自动录制（告警前后 60 秒），见 §9 |
| `events[].tone` | 时间线圆点颜色：`critical/warning`=触发，`neutral`=自动动作和通知，`info`=人工处理 |

**要补的操作：**

| 前端调用 | 建议接口 | 说明 |
|---|---|---|
| `acknowledge` | `PATCH /alerts/{id} {state:"doing"}` | 当前用户成为处理人（`assignee_id`） |
| `assign` | `PATCH /alerts/{id} {assignee_id}` | **缺。**状态同时变成 doing |
| `close` | `PATCH {state:"closed", note}` | 已有。`note` 必填，前端会校验，后端也请校验 |
| `reopen` | `PATCH {state:"open"}` | 已有 |
| `silence` | `PATCH {silenced_until: "…" \| null}` | **缺。**静默期间不重复推送 |
| `remoteDown` | `POST /alerts/{id}/remote-down` | **缺。**走急停通道让设备趴下：不需要控制权，并写进告警时间线和审计 |
| `history` | `GET /alerts/{id}/history` | **缺。**或者前端用 `/devices/{id}/telemetry` 自己取，但阈值需要从规则查。建议服务端直接给 `{values[], threshold, min_y, max_y}` |

- WS `alert`：前端收到后会 `GET /alerts/{id}` 拿完整数据，然后弹横幅。状态变化（被别人确认、关闭）请也推一条 `alert`，带新的 `state`。

**规则：**
- `GET /alert-rules` 请带 `enabled`。`PATCH /alert-rules/{id} {enabled}` 用于开关。
- 前端显示的条件是「> 60 °C 持续 10 秒」，由 `op` / `threshold` / `duration_secs` 拼出来，后端不用给字符串。
- `auto_action`：前端的规则表单有四个选项，现有的 `slow|stop` 不够，请扩展为：

  | 取值 | 显示 |
  |---|---|
  | `slow` | 自动降速 |
  | `stop` | 自动停止 |
  | `dock` | 自动回桩 |
  | `notify` | 通知管理者 |

**通知渠道和值班（缺，告警页右栏）：**

```
GET /alert-channels → [{"name": "邮件", "min_severity": "warning"}]
GET /on-call → {"weeks": ["kanade", "linyue", "zhouming"], "escalate_after_secs": 600, "escalate_to_id": "zhouming"}
```

`weeks[0]` 是本周的值班人。前端目前只显示，没有编辑界面。

---

## 8. 地图与任务

### 8.1 地图（缺）

```
GET /maps → [{
  "id": "b2", "name": "B 区 · 巡检层", "short_name": "B 区巡检层",
  "width_m": 48, "height_m": 30, "origin": [0, 0], "resolution_cm": 5, "updated_at": "…",
  "areas": [{"polygon": [[x,y],…], "label": "仓库", "outline": false}],
  "chargers": [[x, y]],
  "devices": [{"device_id": "go2-01", "x": 12.3, "y": 4.5, "yaw": 1.57}]
}]
POST /maps/{id}/chargers {x, y}    // 手动标注充电桩
POST /maps/{id}/remap              // 重新建图，由「地图更新」任务的设备执行
```

**说明：**
- `areas` 是建图得到的墙体和房间。`outline: true` 是外墙，只画边线。
- 设备位置更新很频繁，建议**不要**放在 `GET /maps` 里轮询。前端改用遥测里的 `pose`，前提是 pose 和地图使用同一坐标系、并且说明 pose 属于哪张地图。所以请在遥测里加 `map_id`。
- 安全策略页用的地图也从这里取。
- changed:`maps`。

### 8.2 任务：补字段

前端 `Mission`（`lib/data/models/mission.dart`）：

```json
{
  "id": "m-1", "name": "B 区巡检", "map_id": "b2",
  "assignee": {"device_id": "go2-03", "backup_device_id": "go2-04"},   // 或 {"preset_id": "showroom"}
  "schedule": "每天 09:00、14:00",
  "state": "running|scheduled|paused",
  "completed": 3, "loop": true,
  "waypoints": [{
    "name": "P1 · 配电柜", "x": 10.5, "y": 6.2, "yaw": 1.57,
    "stay_secs": 30, "retries": 2,
    "actions": [{"name": "拍照", "detail": "前置相机 · 存档"}]
  }]
}
```

**说明：**
- `completed` 是本轮已完成的点位数，界面显示「当前 3/8」。
- `retries`：失败重试次数，仍失败就跳过并告警。
- `schedule` 目前是给人看的字符串。如果后端用 cron，请再给一个 `schedule_label`。
- 前端的修改都走 `PATCH /missions/{id}`：
  - 运行、暂停：`{state}`
  - 替换全部点位：`{waypoints}`
- 新建：`POST /missions {name, map_id}`，其余字段用默认值。
- 任务运行到第几个点要实时更新，请推 changed:`missions`，或者专门推 `{"type":"mission_progress","mission_id","completed"}`。

### 8.3 今日排期（缺）

```
GET /schedule?date=2026-11-04 → [{"device_id", "start", "end", "label", "kind": "run|charge|other", "mission_id"}]
```

---

## 9. 录制与回放（全部缺）

前端模型见 `lib/data/models/recording.dart`。

```
GET  /recordings → [{
  "id", "name", "device_ids", "start", "end", "size_bytes",
  "tags": ["alert|patrol|fleet|manual"],
  "tracks": [{"kind": "video|point_cloud|joints|commands", "segments": [[0.0, 0.4], [0.5, 1.0]]}],
  "events": [{"offset_ms": 12000, "label": "电机过热告警", "tone": "critical"}],
  "streams": "视频 3 路 / 点云 / 关节 / IMU / 指令 / 日志",
  "map_id", "source_id"
}]
GET  /recordings/storage → {"used_bytes", "total_bytes", "retention_days", "auto_rules": ["告警前后 60 秒", "所有联调会话"]}
GET  /recordings/{id}/samples → {"chart_title", "temperature": [], "velocity": [], "trajectory": [[x,y]], "cloud": [[x,y]]}
POST /recordings/{id}/clip {from_ms, to_ms} → {"id"}
POST /recordings/{id}/export {format: "mcap|rosbag"} → {"url", "filename"}
```

**说明：**
- `tracks[].segments` 是有数据的时间段，用 0–1 的比例表示。
- `samples` 按录制时长等分采样，前端需要约 120 个点。
- 分享链接由前端生成：`uniconsole://replay/{id}?t=<秒>`。如果要网页可以打开，需要后端提供落地页。
- 回放视频依赖 §15。
- changed:`recordings`。

---

## 10. 设备运维（全部缺）

前端模型见 `lib/data/models/maintenance.dart`。

```
GET  /firmware → [{"device_id", "current", "target", "state", "progress": 0.4, "error"}]
     state: available | waiting_task | waiting_online | scheduled | queued | upgrading | failed | latest
GET  /firmware/release → {"latest": {"Unitree Go2 EDU": "v1.1.8"}, "agent_version": "0.4.2", "notes": ["…"]}
POST /firmware/upgrade {device_ids}     // 灰度：先升第一台，自检通过后其余并行；
                                         // 任务中的等任务结束，离线的上线后自动升
POST /firmware/schedule {device_ids}    // 排进维护窗口
POST /devices/{id}/rollback
POST /devices/{id}/reboot
GET  /battery-health → [{"device_id", "cycles", "monthly": [98, 97.5, …]}]   // 近 6 个月满充容量 %，最后一项是当前
GET  /logs?device_id=&level=&limit= → [{"at", "level": "info|warn|error", "device_id", "message"}]
GET / PUT /maintenance-window {"start_min": 1380, "end_min": 180}     // 距零点的分钟数，可跨零点
POST /diagnostics {device_ids} → {"url", "filename"}
```

**升级进度：**推 changed:`firmware`，或者推 `{"type":"firmware_progress","device_id","state","progress"}`，后者体验更好。

**远程终端：**
- 第一版前端是「发一条命令、收一段输出」：

  ```
  POST /devices/{id}/terminal {command} → {"lines": [{"text", "tone": "normal|success|warning|error"}]}
  ```

- 打开终端前要先通过二次验证（§14）。每条命令都写进审计，kind 是 `terminal`。
- 以后要做交互式终端，可以改成 WS 通道。

---

## 11. 成员与权限

前端 `Member`（`lib/data/models/member.dart`）：

```json
{
  "id": "linyue", "name": "林悦", "handle": "@linyue", "role": "owner",
  "color": 4294198070, "expires_at": null, "disabled": false,
  "granted_device_ids": ["go2-01"],
  "video_only": false, "guest_link": false,
  "online": true, "last_seen": "…"
}
```

**要补的字段：**
- `color`：ARGB 整数。如果后端存 `#RRGGBB` 也行，告诉前端就好。
- `granted_device_ids`：请直接放在成员里，省得逐个请求 `/members/{id}/devices`。
- `video_only`、`guest_link`：观察者的临时访客链接，只能看视频，没有账号。
- `online`、`last_seen`：成员表的「最近活动」。

**邀请流程（需要后端定）：**
- 前端的邀请表单**没有密码**，设计上是「对方首次登录时设置」。而现在 `POST /members` 要求带 password。
- 方案一（建议）：`POST /members` 不传 password，返回一个一次性邀请链接 `{member, invite_url}`，对方打开后自己设密码。前端把链接显示出来，让管理员复制。
- 方案二：前端生成初始密码，显示给管理员。

**更新：**前端的 `update` 会同时调用 `PATCH /members/{id}` 和 `PUT /members/{id}/devices`。

**规则（mock 已实现，服务端请保持一致）：**
- 只有管理员能邀请、改角色、停用、移除。
- 不能修改自己的角色，不能停用或移除自己。
- 至少要保留一名管理员。
- handle 唯一（409）。

**审计：**`GET /audit` 每一项：

```json
{"id", "at", "actor": "Kanade", "actor_id": "kanade", "action": "…", "target": "Alpha", "kind": "control|alert|terminal|config|system", "client": "macOS · 1.0.0"}
```

- 系统自动执行的操作：`actor` 为「系统」，`client` 为「服务端」。
- **缺：**`GET /audit.csv`，导出 CSV。或者前端分页拉全量后自己生成。
- 新审计条目推 changed:`audit`。

---

## 12. 智能体（全部缺）

界面见 Agent / MobileAgent 设计稿，前端模型见 `lib/data/models/agent.dart`。
现在的 mock 是关键词匹配，只用来演示界面。

**硬性规则（HANDOFF §8.3）：**
- 涉及运动的计划，必须先生成计划，列出步骤和安全检查，用户点「执行计划」后才能执行。
- 执行中可以「中止并停止所有设备」。
- `motion: true` 的技能不能设为自动执行。

```
GET  /agent/conversations → [{"id", "title", "updated_at"}]
POST /agent/conversations → {"id"}
GET  /agent/conversations/{id} → {"id", "title", "updated_at", "device_ids", "map_id", "messages": [Message]}
PATCH /agent/conversations/{id} {device_ids?, map_id?}      // 输入框上方的 @设备 / 地图标签
POST /agent/conversations/{id}/messages {text}              // 回复走 WS 流式推送
POST /agent/plans/{id}/run · /abort · /cancel
GET  /agent/skills → [{"name", "description", "mode": "auto|ask|deny", "motion": true}]
PATCH /agent/skills/{name} {mode}                            // motion 技能设 auto 返回 400
```

```json
Message = {"id", "role": "user|agent", "text", "at",
  "plan": {"id", "title", "state": "pending|running|done|aborted|cancelled", "progress": "Alpha 已到达，Bravo 距离 6.2 m",
           "checks": [{"text": "路线不经过禁入区", "ok": true}],
           "steps": [{"who": "Alpha", "device_id": "go2-01", "text": "返回 1 号充电桩",
                      "call": "navigate_to(target=\"dock-1\")", "eta": "约 10 分钟",
                      "summary": "距离 42 m", "state": "waiting|running|done|skipped"}]},
  "photo": {"device_id", "caption"}}
```

**WS 下行：**
```json
{"type": "agent_message", "conversation_id", "message": Message}          // 新消息，或者同一 id 的更新
{"type": "agent_delta", "conversation_id", "message_id", "text": "…"}      // 流式追加文字（可选）
{"type": "agent_plan", "conversation_id", "plan": Plan}                    // 计划状态、步骤、进度变化
```

**其他：**
- 「拍照」需要拿到设备当前画面，依赖视频（§15）。
- 语音输入需要语音识别服务：可以由后端提供 `POST /asr`，也可以前端用系统自带的识别，待定。

---

## 13. 对讲与播报（全部缺）

```
GET  /intercom/targets → [{"id", "label": "展厅全部", "device_ids": []}]
POST /intercom/broadcast {target_id, text} → {"played": 2}      // TTS 播报，返回实际播放的设备数
GET  /intercom/presets → ["请注意，设备正在通过", …]
```

**按住说话**需要双向实时音频：
- 建议和视频共用 WebRTC（§15），上行麦克风，下行设备收音。
- 界面上的「监听」开关控制是否订阅下行音频。
- 降噪和延迟状态由连接上报。

---

## 14. 设置与账户（全部缺）

```
GET / PUT /me/preferences       // 整个对象，按账户同步
GET    /me/sessions → [{"id", "name": "MacBook Pro", "detail": "macOS · 192.168.1.20", "current": true}]
DELETE /me/sessions/{id}        // 让该客户端退出登录
GET    /me/tokens → [{"id", "name", "detail": "读写设备 · 创建于 10 月 12 日"}]
DELETE /me/tokens/{id}
POST   /me/2fa/enable · /disable · /verify {code}
POST   /me/push-tokens {platform: "apns|fcm", token}      // 系统推送，见下
```

`preferences` 对应前端 `Preferences`（`lib/data/models/preferences.dart`）。后端可以当作不透明 JSON 存，不用理解里面的字段：

```json
{"sidebar_icon_size": "medium", "hud_opacity": 0.72, "dark_while_controlling": true,
 "deadzone": 0.1, "curve": "exponential",
 "bindings": [{"control": "A", "action": "站立 / 趴下"}],
 "video_quality": "p720", "weak_network": "control", "relay": "auto",
 "notify_critical": "urgent", "notify_warning": "banner", "notify_lease": "banner_sound",
 "daily_report_hour": 18, "two_factor": true}
```

**说明：**
- `two_factor` 以服务端为准，前端只显示。开关二次验证要写审计。
- **系统推送：**App 不在前台时，需要服务端推 APNs / FCM，按用户的 `notify_*` 偏好过滤。前台横幅前端已经做了，靠 WS `alert` 触发。

---

## 15. 视频（API.md §4 未实现）

前端要的：
- **画面：**每台设备 1–3 路，分别是前置、深度、后置。
- **画质：**偏好里的 `video_quality` 决定，弱网时按 `weak_network` 降级。
- **中继：**偏好里的 `relay`，可选 自动 / 东京 / 上海 / 仅局域网直连。
- **额外通道：**同一条 WebRTC 连接上带点云数据通道（§3.4）和对讲音频（§13）。

**信令：**按 API.md 的计划走 `/api/v1/ws`。前端会实现下面这些消息：

```json
{"type": "webrtc_offer",  "device_id", "session_id", "sdp", "streams": ["front", "depth"]}
{"type": "webrtc_answer", "device_id", "session_id", "sdp"}
{"type": "webrtc_ice",    "device_id", "session_id", "candidate"}
{"type": "webrtc_close",  "device_id", "session_id"}
```

另外请提供 ICE 服务器：`GET /webrtc/ice-servers → [{"urls": [...], "username", "credential"}]`，TURN 凭据要有时效。

---

## 16. 需要后端决定的事

1. 地图坐标系和角度单位（§1.4）：用米加弧度，还是用百分比？
2. 遥测 `roll` / `pitch` / `yaw` 的单位（§1.4）。
3. 邀请成员时怎么设密码（§11）。
4. 是否加通用的 `changed` 失效消息（§1.2），或者每种资源各自设计增量消息。
5. 点云的传输方式：过渡期用 WS 二进制，还是直接上 WebRTC 数据通道（§3.4）。
6. 智能体放在服务端，还是独立服务（§12）。前端只关心上面列出的接口形状。
7. 急停演练需要机器人协议支持 `drill` 标志（§6）。

定下来的部分请直接更新 `../server/docs/API.md`。前端以 API.md 为准接入，这份文档里对应的「建议」就作废。
