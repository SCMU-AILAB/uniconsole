//! 地图与任务（Missions.dc.html）：目前只做 CRUD。
//! TODO：任务调度器（按 schedule 触发、到点前 10 分钟自动获取租约、逐点下发）。

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{Mission, MissionState},
    services::audit,
    state::AppState,
};

pub async fn list(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Vec<Mission>>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(
        sqlx::query_as("SELECT * FROM missions ORDER BY updated_at DESC")
            .fetch_all(&st.db)
            .await?,
    ))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Mission>> {
    user.require(Perm::ViewDevice)?;
    sqlx::query_as("SELECT * FROM missions WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .map(Json)
        .ok_or_else(|| AppError::not_found("任务不存在"))
}

#[derive(Deserialize)]
pub struct UpsertMission {
    pub name: Option<String>,
    pub map_id: Option<String>,
    /// Waypoint[]：{index, name, x, y, yaw, stay, actions[]}
    pub waypoints: Option<Value>,
    pub schedule: Option<String>,
    /// {kind: "device" | "preset", id}
    pub assignee: Option<Value>,
    pub state: Option<MissionState>,
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertMission>,
) -> AppResult<(StatusCode, Json<Mission>)> {
    user.require(Perm::EditMaps)?;
    let (Some(name), Some(map_id)) = (req.name, req.map_id) else {
        return Err(AppError::bad_request("name 和 map_id 必填"));
    };
    let m: Mission = sqlx::query_as(
        "INSERT INTO missions (name, map_id, waypoints, schedule, assignee, state, created_by)
         VALUES ($1, $2, COALESCE($3, '[]'::jsonb), $4, COALESCE($5, '{}'::jsonb), COALESCE($6, 'scheduled'), $7)
         RETURNING *",
    )
    .bind(name)
    .bind(map_id)
    .bind(req.waypoints)
    .bind(req.schedule)
    .bind(req.assignee)
    .bind(req.state)
    .bind(user.id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "创建任务",
        &m.name,
        json!({}),
    )
    .await;
    Ok((StatusCode::CREATED, Json(m)))
}

pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertMission>,
) -> AppResult<Json<Mission>> {
    user.require(Perm::EditMaps)?;
    let m: Mission = sqlx::query_as(
        "UPDATE missions SET name = COALESCE($2, name), map_id = COALESCE($3, map_id),
         waypoints = COALESCE($4, waypoints), schedule = COALESCE($5, schedule),
         assignee = COALESCE($6, assignee), state = COALESCE($7, state), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.map_id)
    .bind(req.waypoints)
    .bind(req.schedule)
    .bind(req.assignee)
    .bind(req.state)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("任务不存在"))?;
    Ok(Json(m))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let res = sqlx::query("DELETE FROM missions WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("任务不存在"));
    }
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "删除任务",
        &id.to_string(),
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}
