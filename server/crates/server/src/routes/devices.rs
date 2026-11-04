//! 设备（Main / Control / Sensors / Maintenance）。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::{
    auth::{self, AuthUser, Perm},
    error::{AppError, AppResult},
    models::{DeviceEvent, DeviceGroup, DeviceKind, DeviceRow, DeviceView, LeaseHolderKind, Role},
    protocol::{Command, ServerEvent, Telemetry},
    services::{
        access, audit,
        control::{self, Actor, CommandResult},
    },
    state::AppState,
};

fn view(st: &AppState, d: DeviceRow, lease: Option<crate::models::Lease>) -> DeviceView {
    let live = st.hub.live(&d.id);
    let online = st.hub.is_online(&d.id);
    let t = live.telemetry.as_ref();
    DeviceView {
        online,
        battery: t.and_then(|t| t.battery),
        latency_ms: live.latency_ms.filter(|_| online),
        max_motor_temp: t.and_then(Telemetry::max_motor_temp).filter(|_| online),
        uptime_secs: live
            .connected_at
            .filter(|_| online)
            .map(|c| (Utc::now() - c).num_seconds()),
        estop: st.safety.is_global_estop() || st.hub.is_device_estopped(&d.id),
        user_id: lease
            .as_ref()
            .filter(|l| l.holder_kind == LeaseHolderKind::User)
            .and_then(|l| l.holder_id),
        lease,
        device: d,
    }
}

#[derive(Deserialize)]
pub struct ListQuery {
    pub status: Option<String>,
    pub group_id: Option<String>,
    pub q: Option<String>,
}

/// GET /devices：设备总览（Main.dc.html）。统计数字由前端基于同一列表计算（HANDOFF §8.5）。
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
           AND ($3::text IS NULL OR group_id = $3)
           AND ($4::text IS NULL OR name ILIKE '%' || $4 || '%' OR code ILIKE '%' || $4 || '%'
                OR location ILIKE '%' || $4 || '%')
         ORDER BY code",
    )
    .bind(visible)
    .bind(q.status)
    .bind(q.group_id)
    .bind(q.q)
    .fetch_all(&st.db)
    .await?;
    let ids: Vec<String> = rows.iter().map(|d| d.id.clone()).collect();
    let mut queues = st.leases.queues(&ids).await?;
    Ok(Json(
        rows.into_iter()
            .map(|d| {
                let lease = st.leases.current(&d.id).map(|mut l| {
                    l.queue = queues.remove(&d.id).unwrap_or_default();
                    l
                });
                view(&st, d, lease)
            })
            .collect(),
    ))
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
    let lease = st.leases.full(&id).await?;
    Ok(Json(view(&st, row, lease)))
}

#[derive(Deserialize)]
pub struct CreateDevice {
    pub id: String,
    pub name: String,
    pub code: String,
    pub model: String,
    pub kind: DeviceKind,
    pub sn: Option<String>,
    pub group_id: Option<String>,
    pub owner_id: Option<uuid::Uuid>,
    pub location: Option<String>,
}

fn devices_changed(st: &AppState, id: Option<&str>) {
    st.hub.publish(ServerEvent::changed("devices", id));
}

/// POST /devices：注册设备，返回一次性明文接入令牌（写入机器人端 `.env`）
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CreateDevice>,
) -> AppResult<(StatusCode, Json<Value>)> {
    if user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以注册设备"));
    }
    if req.id.is_empty()
        || req.id.len() > 32
        || !req
            .id
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(AppError::bad_request(
            "设备 id 只能包含字母、数字、- 和 _（最长 32 位）",
        ));
    }
    let token = auth::generate_device_token();
    let row: DeviceRow = sqlx::query_as(
        "INSERT INTO devices (id, name, code, model, kind, sn, group_id, owner_id, location, token_hash)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *",
    )
    .bind(&req.id)
    .bind(&req.name)
    .bind(&req.code)
    .bind(&req.model)
    .bind(req.kind)
    .bind(&req.sn)
    .bind(&req.group_id)
    .bind(req.owner_id)
    .bind(&req.location)
    .bind(auth::hash_device_token(&token))
    .fetch_one(&st.db)
    .await
    .map_err(|e| match AppError::from(e) {
        AppError::Conflict(_) => AppError::conflict(format!("设备 id {} 或编号 {} 已存在", req.id, req.code)),
        other => other,
    })?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("注册设备 {}（{}）", row.name, row.model),
        &row.name,
        json!({ "id": row.id }),
    )
    .await;
    devices_changed(&st, Some(&row.id));
    Ok((
        StatusCode::CREATED,
        Json(json!({ "device": view(&st, row, None), "token": token })),
    ))
}

#[derive(Deserialize)]
pub struct UpdateDevice {
    pub name: Option<String>,
    pub group_id: Option<String>,
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
        "UPDATE devices SET name = COALESCE($2, name), group_id = COALESCE($3, group_id),
         location = COALESCE($4, location), owner_id = COALESCE($5, owner_id),
         meta = COALESCE($6, meta), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(&id)
    .bind(req.name)
    .bind(req.group_id)
    .bind(req.location)
    .bind(req.owner_id)
    .bind(req.meta)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("修改设备 {} 的信息", row.name),
        &row.name,
        json!({}),
    )
    .await;
    devices_changed(&st, Some(&id));
    let lease = st.leases.full(&id).await?;
    Ok(Json(view(&st, row, lease)))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    if user.role != Role::Admin {
        return Err(AppError::forbidden("只有平台管理员可以删除设备"));
    }
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM devices WHERE id = $1 RETURNING name")
            .bind(&id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("设备不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除设备 {name}"),
        &name,
        json!({ "id": id }),
    )
    .await;
    devices_changed(&st, Some(&id));
    Ok(StatusCode::NO_CONTENT)
}

/// POST /devices/{id}/token：轮换接入令牌（旧令牌立即失效，下次重连时生效）
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
    let label = audit::device_label(&st, &id).await;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("轮换 {label} 的接入令牌"),
        &label,
        json!({}),
    )
    .await;
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

#[derive(Serialize, sqlx::FromRow)]
pub struct Sample {
    pub ts: DateTime<Utc>,
    pub battery: Option<f32>,
    pub max_motor_temp: Option<f32>,
    pub latency_ms: Option<i32>,
    pub voltage: Option<f32>,
    pub current: Option<f32>,
    pub pitch: Option<f32>,
    pub roll: Option<f32>,
    pub vx: Option<f32>,
    pub extra: Option<Value>,
}

/// GET /devices/{id}/telemetry?from=&to=&limit=：1 Hz 抽样历史（默认最近 1 小时）
pub async fn telemetry_history(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<HistoryQuery>,
) -> AppResult<Json<Value>> {
    access::require_device(&st.db, &user, Perm::ViewSensors, &id).await?;
    let mut samples: Vec<Sample> = sqlx::query_as(
        "SELECT ts, battery, max_motor_temp, latency_ms, voltage, current, pitch, roll, vx,
                data->'extra' AS extra
         FROM telemetry WHERE device_id = $1
           AND ts >= COALESCE($2, now() - interval '1 hour') AND ts <= COALESCE($3, now())
         ORDER BY ts DESC LIMIT $4",
    )
    .bind(&id)
    .bind(q.from)
    .bind(q.to)
    .bind(q.limit.unwrap_or(3600).clamp(1, 20_000))
    .fetch_all(&st.db)
    .await?;
    samples.reverse();
    Ok(Json(json!({ "samples": samples })))
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

/// POST /devices/{id}/commands：单条指令（姿态、技能…）。高频摇杆走 WebSocket。
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
pub struct LimitQuery {
    pub limit: Option<i64>,
}

/// GET /devices/{id}/commands：指令日志（Control.dc.html 右下）
pub async fn command_log(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<LimitQuery>,
) -> AppResult<Json<Vec<Value>>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    let rows: Vec<Value> = sqlx::query_scalar(
        "SELECT jsonb_build_object('cmd_id', id, 'at', created_at, 'command', command, 'ok', ok,
                                   'error', error_code, 'message', error, 'by', actor_name,
                                   'acked_at', acked_at)
         FROM command_log WHERE device_id = $1 ORDER BY created_at DESC LIMIT $2",
    )
    .bind(&id)
    .bind(q.limit.unwrap_or(50).clamp(1, 500))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

/// GET /devices/{id}/events?limit=20：最近事件
pub async fn events(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<LimitQuery>,
) -> AppResult<Json<Vec<DeviceEvent>>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    Ok(Json(
        sqlx::query_as(
            "SELECT at, text, tone FROM device_events WHERE device_id = $1 ORDER BY at DESC, id DESC LIMIT $2",
        )
        .bind(&id)
        .bind(q.limit.unwrap_or(20).clamp(1, 200))
        .fetch_all(&st.db)
        .await?,
    ))
}

/// GET /devices/{id}/sensors：机器人 hello 上报的传感器描述
pub async fn sensors(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Value>> {
    access::require_device(&st.db, &user, Perm::ViewSensors, &id).await?;
    let meta: Value = sqlx::query_scalar("SELECT meta FROM devices WHERE id = $1")
        .bind(&id)
        .fetch_one(&st.db)
        .await?;
    let s = meta.get("sensors").cloned().unwrap_or(Value::Null);
    Ok(Json(json!({
        "lidar": s.get("lidar").cloned().unwrap_or(Value::Null),
        "cameras": s.get("cameras").cloned().unwrap_or(json!([])),
        "topics": s.get("topics").cloned().unwrap_or(json!([])),
        "online": st.hub.is_online(&id),
    })))
}

#[derive(Deserialize)]
pub struct EstopReq {
    pub active: bool,
}

/// POST /devices/{id}/estop：单机急停 / 解除。急停任何人可触发；解除规则见 control::execute。
pub async fn estop(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<EstopReq>,
) -> AppResult<Json<Value>> {
    access::require_device(&st.db, &user, Perm::Estop, &id).await?;
    let cmd = if req.active {
        Command::Estop { drill: false }
    } else {
        Command::ReleaseEstop
    };
    // 急停：即使设备离线也要记录状态，等它上线时 Welcome 会带上急停标志
    let sent = match control::execute(&st, Actor::User(&user), &id, cmd, false).await {
        Ok(_) => true,
        Err(AppError::RobotOffline(_)) => false,
        Err(e) => return Err(e),
    };
    let label = audit::device_label(&st, &id).await;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        if req.active {
            format!("急停 {label}")
        } else {
            format!("解除 {label} 的急停")
        },
        &label,
        json!({ "delivered": sent }),
    )
    .await;
    Ok(Json(json!({ "estop": req.active, "delivered": sent })))
}

// ───────── 设备分组 ─────────

pub async fn list_groups(
    State(st): State<AppState>,
    _user: AuthUser,
) -> AppResult<Json<Vec<DeviceGroup>>> {
    Ok(Json(
        sqlx::query_as("SELECT id, name, tone, sort FROM device_groups ORDER BY sort, name")
            .fetch_all(&st.db)
            .await?,
    ))
}

const TONES: [&str; 6] = ["online", "busy", "warning", "action", "critical", "neutral"];

#[derive(Deserialize)]
pub struct UpsertGroup {
    pub id: Option<String>,
    pub name: Option<String>,
    pub tone: Option<String>,
    pub sort: Option<i32>,
}

fn check_tone(t: &Option<String>) -> AppResult<()> {
    match t {
        Some(t) if !TONES.contains(&t.as_str()) => Err(AppError::bad_request(format!(
            "tone 只能是 {}",
            TONES.join("、")
        ))),
        _ => Ok(()),
    }
}

pub async fn create_group(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertGroup>,
) -> AppResult<(StatusCode, Json<DeviceGroup>)> {
    user.require(Perm::Maintenance)?;
    check_tone(&req.tone)?;
    let name = req
        .name
        .filter(|n| !n.trim().is_empty())
        .ok_or_else(|| AppError::bad_request("请填写分组名称"))?;
    let id = req
        .id
        .unwrap_or_else(|| format!("g-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]));
    let g: DeviceGroup = sqlx::query_as(
        "INSERT INTO device_groups (id, name, tone, sort) VALUES ($1, $2, COALESCE($3, 'neutral'), COALESCE($4, 0))
         RETURNING id, name, tone, sort",
    )
    .bind(&id)
    .bind(name.trim())
    .bind(req.tone)
    .bind(req.sort)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("新建设备分组「{}」", g.name),
        &g.name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("device_groups", Some(&g.id)));
    Ok((StatusCode::CREATED, Json(g)))
}

pub async fn update_group(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<UpsertGroup>,
) -> AppResult<Json<DeviceGroup>> {
    user.require(Perm::Maintenance)?;
    check_tone(&req.tone)?;
    let g: DeviceGroup = sqlx::query_as(
        "UPDATE device_groups SET name = COALESCE($2, name), tone = COALESCE($3, tone), sort = COALESCE($4, sort)
         WHERE id = $1 RETURNING id, name, tone, sort",
    )
    .bind(&id)
    .bind(req.name)
    .bind(req.tone)
    .bind(req.sort)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("分组不存在"))?;
    st.hub
        .publish(ServerEvent::changed("device_groups", Some(&id)));
    Ok(Json(g))
}

pub async fn delete_group(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    user.require(Perm::Maintenance)?;
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM device_groups WHERE id = $1 RETURNING name")
            .bind(&id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("分组不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除设备分组「{name}」"),
        &name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("device_groups", Some(&id)));
    st.hub
        .publish(ServerEvent::changed("devices", None::<String>));
    Ok(StatusCode::NO_CONTENT)
}
