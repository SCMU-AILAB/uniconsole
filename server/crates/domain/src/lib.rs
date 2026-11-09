//! UniConsole 领域模型：数据库行模型与对外 DTO（JSON 字段统一 snake_case）。
//!
//! 枚举值与 `frontend/design/HANDOFF.md` §6 一致。开启 `sqlx` feature 后
//! 枚举映射到 PostgreSQL ENUM，结构体可直接 `query_as`。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

macro_rules! pg_enum {
    ($name:ident, $pg:literal, [$($variant:ident),+ $(,)?]) => {
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
        #[cfg_attr(feature = "sqlx", derive(sqlx::Type))]
        #[cfg_attr(feature = "sqlx", sqlx(type_name = $pg, rename_all = "lowercase"))]
        #[serde(rename_all = "lowercase")]
        pub enum $name { $($variant),+ }
    };
}

pg_enum!(Role, "member_role", [Admin, Owner, User, Viewer]);
pg_enum!(DeviceKind, "device_kind", [Dog, Humanoid]);
pg_enum!(
    DeviceStatus,
    "device_status",
    [Online, Busy, Alert, Charging, Offline]
);
pg_enum!(LeaseHolderKind, "lease_holder_kind", [User, Task, Session]);
pg_enum!(
    RequestState,
    "request_state",
    [Pending, Approved, Denied, Cancelled]
);
pg_enum!(AlertSeverity, "alert_severity", [Critical, Warning, Info]);
pg_enum!(AlertState, "alert_state", [Open, Doing, Closed]);
pg_enum!(Formation, "formation", [Line, Column, V, Grid]);
pg_enum!(MissionState, "mission_state", [Running, Scheduled, Paused]);
pg_enum!(ZoneType, "zone_type", [Ban, Slow, Whitelist, Wall]);

// ───────────── 成员 ─────────────

#[derive(Debug, Clone)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct MemberRow {
    pub id: Uuid,
    pub handle: String,
    pub name: String,
    /// 受邀尚未激活时为空
    pub password_hash: Option<String>,
    pub role: Role,
    pub color: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub disabled: bool,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub invite_expires_at: Option<DateTime<Utc>>,
    pub totp_secret: Option<String>,
    pub two_factor: bool,
    pub video_only: bool,
    pub guest_link: bool,
    /// 自助注册时验证过的邮箱（小写）；也可以用它登录
    pub email: Option<String>,
    /// 邮箱注册、等待管理员审核（审核前不能登录）
    pub pending_approval: bool,
}

impl MemberRow {
    pub fn pending_invite(&self) -> bool {
        self.password_hash.is_none()
    }
}

/// 对外的成员视图（GET /members、/auth/me）
#[derive(Debug, Clone, Serialize)]
pub struct Member {
    pub id: Uuid,
    /// 账号，不带 @（前端显示时自行加上）
    pub handle: String,
    pub name: String,
    pub role: Role,
    /// 头像颜色 `#RRGGBB`
    pub color: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub disabled: bool,
    /// 已授权使用的设备（不含自己管理的设备）
    pub granted_device_ids: Vec<String>,
    pub video_only: bool,
    pub guest_link: bool,
    /// 当前是否有客户端在线（实时连接）
    pub online: bool,
    pub last_seen: Option<DateTime<Utc>>,
    pub two_factor: bool,
    /// 受邀尚未设置密码
    pub pending_invite: bool,
    /// 邮箱（只有管理员和本人看得到，其他人看到 null）
    pub email: Option<String>,
    /// 邮箱注册、等待管理员审核
    pub pending_approval: bool,
    pub created_at: DateTime<Utc>,
}

impl Member {
    pub fn from_row(r: MemberRow, granted_device_ids: Vec<String>, online: bool) -> Self {
        Self {
            pending_invite: r.pending_invite(),
            id: r.id,
            handle: r.handle,
            name: r.name,
            role: r.role,
            color: r.color,
            expires_at: r.expires_at,
            disabled: r.disabled,
            granted_device_ids,
            video_only: r.video_only,
            guest_link: r.guest_link,
            online,
            last_seen: r.last_seen_at,
            two_factor: r.two_factor,
            email: r.email,
            pending_approval: r.pending_approval,
            created_at: r.created_at,
        }
    }
}

pg_enum!(SessionKind, "session_kind", [Login, Token]);

/// 登录会话 / API 令牌（GET /me/sessions、/me/tokens）
#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct SessionRow {
    pub id: Uuid,
    pub kind: SessionKind,
    pub name: String,
    pub client: String,
    pub ip: String,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

// ───────────── 设备 ─────────────

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct DeviceRow {
    pub id: String,
    pub name: String,
    pub code: String,
    pub model: String,
    pub kind: DeviceKind,
    pub sn: Option<String>,
    pub firmware: Option<String>,
    pub ip: Option<String>,
    /// 设备分组（GET /device-groups）
    pub group_id: Option<String>,
    pub owner_id: Option<Uuid>,
    pub status: DeviceStatus,
    pub location: Option<String>,
    pub current_task: Option<String>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub meta: Value,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// 设备总览返回：数据库字段 + 实时状态
#[derive(Debug, Clone, Serialize)]
pub struct DeviceView {
    #[serde(flatten)]
    pub device: DeviceRow,
    pub online: bool,
    /// 最近一帧遥测的电量（离线时保留最后已知值），机器人拿不到时为 null
    pub battery: Option<f32>,
    /// 离线时为 null
    pub latency_ms: Option<u32>,
    /// 离线时为 null
    pub max_motor_temp: Option<f32>,
    pub uptime_secs: Option<i64>,
    /// 单机急停中（全局急停时也为 true）
    pub estop: bool,
    pub lease: Option<Lease>,
    /// 当前持有控制权的成员（lease.holder_kind == user 时）
    pub user_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct DeviceGroup {
    pub id: String,
    pub name: String,
    /// online | busy | warning | action | critical | neutral
    pub tone: String,
    pub sort: i32,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct DeviceEvent {
    pub at: DateTime<Utc>,
    pub text: String,
    /// info | success | warning | critical | neutral
    pub tone: String,
}

// ───────────── 租约 ─────────────

#[derive(Debug, Clone)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Lease {
    pub device_id: String,
    pub holder_kind: LeaseHolderKind,
    pub holder_id: Option<Uuid>,
    pub task_id: Option<Uuid>,
    pub session_id: Option<Uuid>,
    pub source: String,
    pub acquired_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
    /// 申请队列（按申请时间）；数据库里不存，由服务端补上
    #[cfg_attr(feature = "sqlx", sqlx(skip))]
    pub queue: Vec<LeaseRequest>,
}

impl Lease {
    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.is_some_and(|e| e <= now)
    }
    pub fn held_by_user(&self, user: Uuid) -> bool {
        self.holder_kind == LeaseHolderKind::User && self.holder_id == Some(user)
    }
    /// 对外的持有者 id：成员 / 联调会话 / 任务
    pub fn holder(&self) -> Option<Uuid> {
        match self.holder_kind {
            LeaseHolderKind::User => self.holder_id,
            LeaseHolderKind::Session => self.session_id,
            LeaseHolderKind::Task => self.task_id,
        }
    }
}

/// 对外形状（前端 Lease）：`holder_id` 按 `holder_kind` 指向成员 / 会话 / 任务
impl Serialize for Lease {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Out<'a> {
            device_id: &'a str,
            holder_kind: LeaseHolderKind,
            holder_id: Option<Uuid>,
            source: &'a str,
            acquired_at: DateTime<Utc>,
            expires_at: Option<DateTime<Utc>>,
            queue: &'a [LeaseRequest],
        }
        Out {
            device_id: &self.device_id,
            holder_kind: self.holder_kind,
            holder_id: self.holder(),
            source: &self.source,
            acquired_at: self.acquired_at,
            expires_at: self.expires_at,
            queue: &self.queue,
        }
        .serialize(s)
    }
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct LeaseRequest {
    pub id: Uuid,
    pub device_id: String,
    /// 申请人
    #[serde(rename = "user_id")]
    pub requester_id: Uuid,
    pub reason: String,
    pub expected_secs: i32,
    pub state: RequestState,
    pub decided_by: Option<Uuid>,
    pub decided_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

// ───────────── 联调 ─────────────

#[derive(Debug, Clone)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct FleetSession {
    pub id: Uuid,
    pub number: i32,
    pub name: String,
    pub owner_id: Uuid,
    /// 第一台是领队
    pub device_ids: Vec<String>,
    pub formation: Formation,
    pub spacing: f32,
    pub preset_id: Option<String>,
    pub control_mode: String,
    pub clock_sync: String,
    pub lost_link_action: String,
    /// TrackAction[]：{device_id, start_ms, end_ms, action, kind: pose|move|act}
    pub timeline: Value,
    pub last_receipt: Option<Value>,
    pub active: bool,
    pub paused: bool,
    pub started_at: Option<DateTime<Utc>>,
    /// 时间轴播放起点（已减去起播偏移）；None = 未在播放
    pub playback_started_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// 对外形状（前端 FleetSession）
impl Serialize for FleetSession {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        #[derive(Serialize)]
        struct Out<'a> {
            id: Uuid,
            number: i32,
            title: &'a str,
            initiator_id: Uuid,
            started_at: Option<DateTime<Utc>>,
            device_ids: &'a [String],
            leader_id: Option<&'a String>,
            formation: Formation,
            spacing: f32,
            preset_id: Option<&'a str>,
            control_mode: &'a str,
            clock_sync: &'a str,
            lost_link_action: &'a str,
            /// 时钟偏差：未接入 PTP 统计前为 null
            clock_skew_ms: Option<i64>,
            timeline: &'a Value,
            timeline_length_ms: i64,
            last_receipt: Option<&'a Value>,
            active: bool,
            paused: bool,
            playback_started_at: Option<DateTime<Utc>>,
            created_at: DateTime<Utc>,
            updated_at: DateTime<Utc>,
        }
        let length = self
            .timeline
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|t| t.get("end_ms").and_then(Value::as_i64))
                    .max()
                    .unwrap_or(0)
            })
            .unwrap_or(0);
        Out {
            id: self.id,
            number: self.number,
            title: &self.name,
            initiator_id: self.owner_id,
            started_at: self.started_at,
            device_ids: &self.device_ids,
            leader_id: self.device_ids.first(),
            formation: self.formation,
            spacing: self.spacing,
            preset_id: self.preset_id.as_deref(),
            control_mode: &self.control_mode,
            clock_sync: &self.clock_sync,
            lost_link_action: &self.lost_link_action,
            clock_skew_ms: None,
            timeline: &self.timeline,
            timeline_length_ms: length,
            last_receipt: self.last_receipt.as_ref(),
            active: self.active,
            paused: self.paused,
            playback_started_at: self.playback_started_at,
            created_at: self.created_at,
            updated_at: self.updated_at,
        }
        .serialize(s)
    }
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct FleetPreset {
    pub id: String,
    pub name: String,
    pub device_ids: Vec<String>,
    pub formation: Formation,
    pub spacing: f32,
    pub created_by: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

// ───────────── 地图与任务 ─────────────

/// 地图。坐标：米，原点在左下角，x 向右、y 向上（ROS REP-103）
#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Map {
    pub id: String,
    pub name: String,
    pub short_name: String,
    pub width_m: f32,
    pub height_m: f32,
    pub origin: Value,
    pub resolution_cm: f32,
    /// [{polygon: [[x,y],…], label, outline}]
    pub areas: Value,
    /// [[x, y], …]
    pub chargers: Value,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Mission {
    pub id: Uuid,
    pub name: String,
    pub map_id: String,
    /// Waypoint[]：{name, x, y, yaw, stay_secs, retries, actions: [{name, detail}]}
    pub waypoints: Value,
    /// 给人看的排期，如「每天 09:00、14:00」
    pub schedule: Option<String>,
    /// {device_id, backup_device_id} 或 {preset_id}
    pub assignee: Value,
    pub state: MissionState,
    /// 本轮已完成的点位数（「当前 3/8」）
    pub completed: i32,
    #[serde(rename = "loop")]
    pub loop_enabled: bool,
    pub created_by: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct ScheduleEntry {
    pub id: i64,
    pub device_id: String,
    #[serde(rename = "start")]
    pub starts_at: DateTime<Utc>,
    #[serde(rename = "end")]
    pub ends_at: DateTime<Utc>,
    pub label: String,
    /// run | charge | other
    pub kind: String,
    pub mission_id: Option<Uuid>,
}

// ───────────── 录制 ─────────────

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct RecordingRow {
    pub id: Uuid,
    pub name: String,
    pub device_ids: Vec<String>,
    #[serde(rename = "start")]
    pub start_at: DateTime<Utc>,
    #[serde(rename = "end")]
    pub end_at: DateTime<Utc>,
    pub tags: Vec<String>,
    pub map_id: Option<String>,
    pub source_id: Option<String>,
    pub clip_of: Option<Uuid>,
    pub created_by: Option<Uuid>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct DeviceLog {
    pub at: DateTime<Utc>,
    /// info | warn | error
    pub level: String,
    pub device_id: String,
    pub message: String,
}

// ───────────── 告警 ─────────────

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Alert {
    pub id: Uuid,
    pub severity: AlertSeverity,
    pub state: AlertState,
    pub title: String,
    pub device_id: Option<String>,
    pub rule_id: Option<Uuid>,
    /// 触发的指标，如 max_motor_temp；机器人事件时为事件 code
    pub metric: Option<String>,
    /// 曲线标题，如「电机最高温度（°C）」
    pub metric_label: Option<String>,
    pub threshold: Option<f64>,
    pub peak: Option<f64>,
    /// 触发位置，如「C 区仓库」
    pub location: Option<String>,
    /// 处理人
    pub assignee_id: Option<Uuid>,
    pub silenced_until: Option<DateTime<Utc>>,
    /// 自动录制（告警前后 60 秒）
    pub recording_id: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AlertEvent {
    pub id: i64,
    pub alert_id: Uuid,
    #[serde(rename = "at")]
    pub ts: DateTime<Utc>,
    pub level: String,
    /// critical / warning = 触发，neutral = 自动动作与通知，info = 人工处理
    pub tone: String,
    pub message: String,
    pub actor_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AlertRule {
    pub id: Uuid,
    pub name: String,
    pub metric: String,
    pub metric_label: Option<String>,
    pub op: String,
    pub threshold: f64,
    pub duration_secs: i32,
    pub severity: AlertSeverity,
    /// slow | stop | dock | notify
    pub auto_action: Option<String>,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
}

// ───────────── 安全 ─────────────

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Zone {
    pub id: Uuid,
    pub map_id: String,
    pub name: String,
    pub zone_type: ZoneType,
    pub polygon: Value,
    pub rule: String,
    /// 显示文本，如「全部设备」「Go2 系列」
    pub scope: String,
    pub schedule: String,
    pub action: String,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

/// 审计分类（前端筛选）
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AuditKind {
    Control,
    Alert,
    Terminal,
    Config,
    System,
}

impl AuditKind {
    pub fn as_str(self) -> &'static str {
        match self {
            AuditKind::Control => "control",
            AuditKind::Alert => "alert",
            AuditKind::Terminal => "terminal",
            AuditKind::Config => "config",
            AuditKind::System => "system",
        }
    }
}

/// GET /audit 的一项。`action` 是完整的人话，前端直接显示。
#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AuditEntry {
    pub id: i64,
    pub at: DateTime<Utc>,
    /// 显示名；系统动作为「系统」
    pub actor: String,
    pub actor_id: Option<Uuid>,
    pub action: String,
    pub target: String,
    pub kind: String,
    /// X-Client；系统动作为「服务端」
    pub client: String,
    pub detail: Value,
}
