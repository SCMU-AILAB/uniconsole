use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    auth::{self, AuthUser, Perm},
    error::{AppError, AppResult},
    models::{DeviceKind, DeviceRow, DeviceView, Role},
    protocol::{Command, Telemetry},
    services::{
        access, audit,
        control::{self, Actor, CommandResult},
    },
    state::AppState,
};

fn view(st: &AppState, d: DeviceRow) -> DeviceView {
    let live = st.hub.live(&d.id);
    let online = st.hub.is_online(&d.id);
    let t = live.telemetry.as_ref();
    DeviceView {
        online,
        battery: t.and_then(|t| t.battery),
        latency_ms: live.latency_ms,
        max_motor_temp: t.and_then(Telemetry::max_motor_temp),
        uptime_secs: live
            .connected_at
            .filter(|_| online)
            .map(|c| (Utc::now() - c).num_seconds()),
        estop: st.safety.is_global_estop() || st.hub.is_device_estopped(&d.id),
        lease: st.leases.current(&d.id),
        device: d,
    }
}

#[derive(Deserialize)]
pub struct ListQuery {
    pub status: Option<String>,
    pub group: Option<String>,
    pub q: Option<String>,
}

/// 设备总览（Main.dc.html）。统计数字由前端基于同一列表计算（HANDOFF §8.5）。
pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<DeviceView>>> {
    let visible = access::visible_devices(&st.db, &user).await?;
    let rows: Vec<DeviceRow> = sqlx::query_as(
        "SELECT * FROM devices
         WHERE ($1::text[] IS NULL OR id = ANY($1))
           AND ($2::text IS NULL OR status::text = $2)
           AND ($3::text IS NULL OR grp = $3)
           AND ($4::text IS NULL OR name ILIKE '%' || $4 || '%' OR code ILIKE '%' || $4 || '%'
                OR location ILIKE '%' || $4 || '%')
         ORDER BY code",
    )
    .bind(visible)
    .bind(q.status)
    .bind(q.group)
    .bind(q.q)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows.into_iter().map(|d| view(&st, d)).collect()))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<DeviceView>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    let row: DeviceRow = sqlx::query_as("SELECT * FROM devices WHERE id = $1")
        .bind(&id)
        .fetch_one(&st.db)
        .await?;
    Ok(Json(view(&st, row)))
}

#[derive(Deserialize)]
pub struct CreateDevice {
    pub id: String,
    pub name: String,
    pub code: String,
    pub model: String,
    pub kind: DeviceKind,
    pub sn: Option<String>,
    pub group: Option<String>,
    pub owner_id: Option<uuid::Uuid>,
    pub location: Option<String>,
}

/// 注册设备，返回一次性明文接入令牌（写入机器人端 `.env`）
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CreateDevice>,
) -> AppResult<(StatusCode, Json<Value>)> {
    if user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以注册设备"));
    }
    if req.id.is_empty()
        || !req
            .id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(AppError::bad_request("设备 id 只能包含字母、数字、- 和 _"));
    }
    let token = auth::generate_device_token();
    let row: DeviceRow = sqlx::query_as(
        "INSERT INTO devices (id, name, code, model, kind, sn, grp, owner_id, location, token_hash)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *",
    )
    .bind(&req.id)
    .bind(&req.name)
    .bind(&req.code)
    .bind(&req.model)
    .bind(req.kind)
    .bind(&req.sn)
    .bind(&req.group)
    .bind(req.owner_id)
    .bind(&req.location)
    .bind(auth::hash_device_token(&token))
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st.db,
        &user,
        "注册设备",
        &row.id,
        json!({ "model": row.model }),
    )
    .await;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "device": view(&st, row), "token": token })),
    ))
}

#[derive(Deserialize)]
pub struct UpdateDevice {
    pub name: Option<String>,
    pub group: Option<String>,
    pub location: Option<String>,
    pub owner_id: Option<uuid::Uuid>,
    pub meta: Option<Value>,
}

pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<UpdateDevice>,
) -> AppResult<Json<DeviceView>> {
    access::require_device(&st.db, &user, Perm::Maintenance, &id).await?;
    if req.owner_id.is_some() && user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以更换设备管理者"));
    }
    let row: DeviceRow = sqlx::query_as(
        "UPDATE devices SET name = COALESCE($2, name), grp = COALESCE($3, grp), location = COALESCE($4, location),
         owner_id = COALESCE($5, owner_id), meta = COALESCE($6, meta), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(&id)
    .bind(req.name)
    .bind(req.group)
    .bind(req.location)
    .bind(req.owner_id)
    .bind(req.meta)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(view(&st, row)))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    if user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以删除设备"));
    }
    let res = sqlx::query("DELETE FROM devices WHERE id = $1")
        .bind(&id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("设备不存在"));
    }
    audit::record(&st.db, &user, "删除设备", &id, json!({})).await;
    Ok(StatusCode::NO_CONTENT)
}

/// 轮换接入令牌（旧令牌立即失效，下次重连时生效）
pub async fn rotate_token(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    if user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以轮换令牌"));
    }
    let token = auth::generate_device_token();
    let res = sqlx::query("UPDATE devices SET token_hash = $2, updated_at = now() WHERE id = $1")
        .bind(&id)
        .bind(auth::hash_device_token(&token))
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("设备不存在"));
    }
    audit::record(&st.db, &user, "轮换设备令牌", &id, json!({})).await;
    Ok(Json(json!({ "token": token })))
}

pub async fn telemetry_latest(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Option<Telemetry>>> {
    access::require_device(&st.db, &user, Perm::ViewSensors, &id).await?;
    Ok(Json(st.hub.live(&id).telemetry))
}

#[derive(Deserialize)]
pub struct HistoryQuery {
    pub from: Option<DateTime<Utc>>,
    pub to: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
}

/// 抽样遥测历史（告警详情曲线、回放）
pub async fn telemetry_history(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<HistoryQuery>,
) -> AppResult<Json<Vec<Value>>> {
    access::require_device(&st.db, &user, Perm::ViewSensors, &id).await?;
    let rows: Vec<(Value,)> = sqlx::query_as(
        "SELECT data FROM telemetry WHERE device_id = $1
           AND ts >= COALESCE($2, now() - interval '1 hour') AND ts <= COALESCE($3, now())
         ORDER BY ts DESC LIMIT $4",
    )
    .bind(&id)
    .bind(q.from)
    .bind(q.to)
    .bind(q.limit.unwrap_or(3600).clamp(1, 20_000))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows.into_iter().rev().map(|(v,)| v).collect()))
}

#[derive(Deserialize)]
pub struct SendCommand {
    pub command: Command,
    /// 默认等待机器人回执
    #[serde(default = "yes")]
    pub wait: bool,
}
fn yes() -> bool {
    true
}

/// 单条指令（姿态切换、预置动作…）。高频摇杆走 WebSocket。
pub async fn send_command(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<SendCommand>,
) -> AppResult<Json<CommandResult>> {
    let perm = if req.command.is_motion() {
        Perm::HoldLease
    } else {
        Perm::Estop
    };
    access::require_device(&st.db, &user, perm, &id).await?;
    Ok(Json(
        control::execute(&st, Actor::User(&user), &id, req.command, req.wait).await?,
    ))
}

#[derive(Deserialize)]
pub struct LogQuery {
    pub limit: Option<i64>,
}

/// 指令日志（Control.dc.html 右下）
pub async fn command_log(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<LogQuery>,
) -> AppResult<Json<Vec<Value>>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    let rows: Vec<(Value,)> = sqlx::query_as(
        "SELECT json_build_object('id', id, 'command', command, 'ok', ok, 'error', error,
                                  'created_at', created_at, 'acked_at', acked_at)::jsonb
         FROM command_log WHERE device_id = $1 ORDER BY created_at DESC LIMIT $2",
    )
    .bind(&id)
    .bind(q.limit.unwrap_or(50).clamp(1, 500))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows.into_iter().map(|(v,)| v).collect()))
}

#[derive(Deserialize)]
pub struct EstopReq {
    pub active: bool,
}

/// 单机急停 / 解除。急停任何人可触发；解除规则见 control::execute。
pub async fn estop(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<EstopReq>,
) -> AppResult<Json<Value>> {
    access::require_device(&st.db, &user, Perm::Estop, &id).await?;
    let cmd = if req.active {
        Command::Estop
    } else {
        Command::ReleaseEstop
    };
    // 急停：即使设备离线也要记录状态，等它上线时 Welcome 会带上急停标志
    let sent = match control::execute(&st, Actor::User(&user), &id, cmd, false).await {
        Ok(_) => true,
        Err(AppError::RobotOffline(_)) => false,
        Err(e) => return Err(e),
    };
    audit::record(
        &st.db,
        &user,
        if req.active {
            "单机急停"
        } else {
            "解除单机急停"
        },
        &id,
        json!({ "delivered": sent }),
    )
    .await;
    Ok(Json(json!({ "estop": req.active, "delivered": sent })))
}
