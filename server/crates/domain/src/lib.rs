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
    pub password_hash: String,
    pub role: Role,
    pub color: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub disabled: bool,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Member {
    pub id: Uuid,
    pub handle: String,
    pub name: String,
    pub role: Role,
    pub color: String,
    pub expires_at: Option<DateTime<Utc>>,
    pub disabled: bool,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

impl From<MemberRow> for Member {
    fn from(r: MemberRow) -> Self {
        Self {
            id: r.id,
            handle: r.handle,
            name: r.name,
            role: r.role,
            color: r.color,
            expires_at: r.expires_at,
            disabled: r.disabled,
            last_seen_at: r.last_seen_at,
            created_at: r.created_at,
        }
    }
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
    #[serde(rename = "group")]
    pub grp: Option<String>,
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
    pub battery: Option<f32>,
    pub latency_ms: Option<u32>,
    pub max_motor_temp: Option<f32>,
    pub uptime_secs: Option<i64>,
    pub estop: bool,
    pub lease: Option<Lease>,
}

// ───────────── 租约 ─────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
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
}

impl Lease {
    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        self.expires_at.is_some_and(|e| e <= now)
    }
    pub fn held_by_user(&self, user: Uuid) -> bool {
        self.holder_kind == LeaseHolderKind::User && self.holder_id == Some(user)
    }
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct LeaseRequest {
    pub id: Uuid,
    pub device_id: String,
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
    pub scope: Value,
    pub schedule: String,
    pub action: String,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
#[cfg_attr(feature = "sqlx", derive(sqlx::FromRow))]
pub struct AuditEntry {
    pub id: i64,
    pub ts: DateTime<Utc>,
    pub actor_id: Option<Uuid>,
    pub actor_name: String,
    pub action: String,
    pub target: String,
    pub client: String,
    pub detail: Value,
}
