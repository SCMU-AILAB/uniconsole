//! 多机联调（Fleet.dc.html）。会话启动时一次性获取所有参与设备的租约，
//! 同步指令向所有设备并发下发并汇总回执。
//! TODO：时间轴（timeline）执行器、编队保持控制。

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use futures::future::join_all;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{FleetSession, Formation, Role},
    protocol::Command,
    services::{
        access, audit,
        control::{self, Actor},
    },
    state::AppState,
};

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<FleetSession>>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(
        sqlx::query_as("SELECT * FROM fleet_sessions ORDER BY updated_at DESC")
            .fetch_all(&st.db)
            .await?,
    ))
}

async fn load(st: &AppState, id: Uuid) -> AppResult<FleetSession> {
    sqlx::query_as("SELECT * FROM fleet_sessions WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("联调会话不存在"))
}

fn ensure_owner(user: &AuthUser, s: &FleetSession) -> AppResult<()> {
    if s.owner_id != user.id && user.role != Role::Admin {
        return Err(AppError::forbidden("只有会话发起人可以操作该会话"));
    }
    Ok(())
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(load(&st, id).await?))
}

#[derive(Deserialize)]
pub struct UpsertSession {
    pub name: Option<String>,
    pub device_ids: Option<Vec<String>>,
    pub leader_id: Option<String>,
    pub formation: Option<Formation>,
    pub spacing: Option<f32>,
    pub timeline: Option<Value>,
}

async fn check_devices(st: &AppState, user: &AuthUser, ids: &[String]) -> AppResult<()> {
    for id in ids {
        access::require_device(&st.db, user, Perm::FleetSession, id).await?;
    }
    Ok(())
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertSession>,
) -> AppResult<(StatusCode, Json<FleetSession>)> {
    user.require(Perm::FleetSession)?;
    let ids = req.device_ids.unwrap_or_default();
    check_devices(&st, &user, &ids).await?;
    let s: FleetSession = sqlx::query_as(
        "INSERT INTO fleet_sessions (name, owner_id, device_ids, leader_id, formation, spacing, timeline)
         VALUES ($1, $2, $3, COALESCE($4, $3[1]), COALESCE($5, 'line'), COALESCE($6, 1.0), COALESCE($7, '[]'::jsonb))
         RETURNING *",
    )
    .bind(req.name.unwrap_or_else(|| "新联调会话".into()))
    .bind(user.id)
    .bind(&ids)
    .bind(req.leader_id)
    .bind(req.formation)
    .bind(req.spacing)
    .bind(req.timeline)
    .fetch_one(&st.db)
    .await?;
    Ok((StatusCode::CREATED, Json(s)))
}

pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertSession>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if let Some(ids) = &req.device_ids {
        if s.active {
            return Err(AppError::conflict("会话进行中，不能修改参与设备"));
        }
        check_devices(&st, &user, ids).await?;
    }
    let s: FleetSession = sqlx::query_as(
        "UPDATE fleet_sessions SET name = COALESCE($2, name), device_ids = COALESCE($3, device_ids),
         leader_id = COALESCE($4, leader_id), formation = COALESCE($5, formation),
         spacing = COALESCE($6, spacing), timeline = COALESCE($7, timeline), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.device_ids)
    .bind(req.leader_id)
    .bind(req.formation)
    .bind(req.spacing)
    .bind(req.timeline)
    .fetch_one(&st.db)
    .await?;
    Ok(Json(s))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if s.active {
        stop_all(&st, &s).await;
        st.leases.release_session(id).await?;
    }
    sqlx::query("DELETE FROM fleet_sessions WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn start(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if s.device_ids.is_empty() {
        return Err(AppError::bad_request("请先选择参与设备"));
    }
    if st.safety.is_global_estop() {
        return Err(AppError::EstopActive);
    }
    check_devices(&st, &user, &s.device_ids).await?;
    st.leases
        .acquire_for_session(id, &s.name, &s.device_ids)
        .await?;
    let s: FleetSession = sqlx::query_as(
        "UPDATE fleet_sessions SET active = TRUE, updated_at = now() WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st.db,
        &user,
        "开始联调会话",
        &s.name,
        json!({ "devices": s.device_ids }),
    )
    .await;
    Ok(Json(s))
}

async fn stop_all(st: &AppState, s: &FleetSession) {
    for d in &s.device_ids {
        let _ = control::execute(st, Actor::System("联调结束"), d, Command::Stop, false).await;
    }
}

pub async fn stop(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    stop_all(&st, &s).await;
    st.leases.release_session(id).await?;
    let s: FleetSession = sqlx::query_as(
        "UPDATE fleet_sessions SET active = FALSE, updated_at = now() WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .fetch_one(&st.db)
    .await?;
    audit::record(&st.db, &user, "结束联调会话", &s.name, json!({})).await;
    Ok(Json(s))
}

#[derive(Deserialize)]
pub struct FleetCommand {
    pub command: Command,
    /// 为空表示所有参与设备
    pub device_ids: Option<Vec<String>>,
}

#[derive(Serialize)]
pub struct DeviceResult {
    pub device_id: String,
    pub ok: bool,
    pub error: Option<String>,
}

/// 同步指令：并发下发并汇总每台设备的回执（Fleet.dc.html「同步指令」）
pub async fn command(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<FleetCommand>,
) -> AppResult<Json<Vec<DeviceResult>>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if !s.active {
        return Err(AppError::conflict("会话未开始"));
    }
    let targets: Vec<String> = match req.device_ids {
        Some(ids) => ids
            .into_iter()
            .filter(|i| s.device_ids.contains(i))
            .collect(),
        None => s.device_ids.clone(),
    };
    let futs = targets.iter().map(|d| {
        let st = st.clone();
        let user = user.clone();
        let cmd = req.command.clone();
        let d = d.clone();
        async move {
            let r = control::execute(&st, Actor::User(&user), &d, cmd, true).await;
            match r {
                Ok(res) => DeviceResult {
                    device_id: d,
                    ok: res.ok.unwrap_or(false),
                    error: res.error,
                },
                Err(e) => DeviceResult {
                    device_id: d,
                    ok: false,
                    error: Some(e.to_string()),
                },
            }
        }
    });
    Ok(Json(join_all(futs).await))
}
