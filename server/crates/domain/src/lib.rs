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

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct FleetSession {
    pub id: Uuid,
    pub name: String,
    pub owner_id: Uuid,
    pub device_ids: Vec<String>,
    pub leader_id: Option<String>,
    pub formation: Formation,
    pub spacing: f32,
    pub timeline: Value,
    pub active: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

// ───────────── 任务 ─────────────

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct Mission {
    pub id: Uuid,
    pub name: String,
    pub map_id: String,
    pub waypoints: Value,
    pub schedule: Option<String>,
    pub assignee: Value,
    pub state: MissionState,
    pub created_by: Option<Uuid>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
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
    pub metric: Option<String>,
    pub peak: Option<f64>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub closed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AlertEvent {
    pub id: i64,
    pub alert_id: Uuid,
    pub ts: DateTime<Utc>,
    pub level: String,
    pub message: String,
    pub actor_id: Option<Uuid>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AlertRule {
    pub id: Uuid,
    pub name: String,
    pub metric: String,
    pub op: String,
    pub threshold: f64,
    pub duration_secs: i32,
    pub severity: AlertSeverity,
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
