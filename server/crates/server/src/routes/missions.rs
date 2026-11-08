//! 地图与任务（Missions.dc.html）：地图、任务、今日排期。
//! 任务的调度与执行见 `services::missions`；这里改完数据库后调用 `st.missions.sync` 让执行跟上。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, NaiveDate, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{Map, Mission, MissionState, ScheduleEntry},
    protocol::ServerEvent,
    services::{audit, missions},
    state::AppState,
};

// ───────── 地图 ─────────

fn maps_changed(st: &AppState, id: &str) {
    st.hub.publish(ServerEvent::changed("maps", Some(id)));
}

pub async fn list_maps(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Vec<Map>>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(
        sqlx::query_as("SELECT * FROM maps ORDER BY name")
            .fetch_all(&st.db)
            .await?,
    ))
}

pub async fn get_map(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Map>> {
    user.require(Perm::ViewDevice)?;
    sqlx::query_as("SELECT * FROM maps WHERE id = $1")
        .bind(&id)
        .fetch_optional(&st.db)
        .await?
        .map(Json)
        .ok_or_else(|| AppError::not_found("地图不存在"))
}

#[derive(Deserialize)]
pub struct UpsertMap {
    pub id: Option<String>,
    pub name: Option<String>,
    pub short_name: Option<String>,
    pub width_m: Option<f32>,
    pub height_m: Option<f32>,
    pub origin: Option<Value>,
    pub resolution_cm: Option<f32>,
    pub areas: Option<Value>,
    pub chargers: Option<Value>,
}

fn validate_map(m: &UpsertMap) -> AppResult<()> {
    for (n, v) in [("width_m", m.width_m), ("height_m", m.height_m)] {
        if v.is_some_and(|v| !(v.is_finite() && v > 0.0 && v < 10_000.0)) {
            return Err(AppError::bad_request(format!("{n} 必须是正数（米）")));
        }
    }
    if m.areas.as_ref().is_some_and(|a| !a.is_array())
        || m.chargers.as_ref().is_some_and(|a| !a.is_array())
    {
        return Err(AppError::bad_request("areas / chargers 必须是数组"));
    }
    Ok(())
}

/// POST /maps：登记地图（通常由建图流程写入；管理员也可手动录入）
pub async fn create_map(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertMap>,
) -> AppResult<(StatusCode, Json<Map>)> {
    user.require(Perm::EditMaps)?;
    validate_map(&req)?;
    let (Some(id), Some(name), Some(w), Some(h)) = (req.id, req.name, req.width_m, req.height_m)
    else {
        return Err(AppError::bad_request("id、name、width_m、height_m 必填"));
    };
    let m: Map = sqlx::query_as(
        "INSERT INTO maps (id, name, short_name, width_m, height_m, origin, resolution_cm, areas, chargers)
         VALUES ($1, $2, COALESCE($3, $2), $4, $5, COALESCE($6, '[0, 0]'::jsonb), COALESCE($7, 5),
                 COALESCE($8, '[]'::jsonb), COALESCE($9, '[]'::jsonb)) RETURNING *",
    )
    .bind(&id)
    .bind(&name)
    .bind(req.short_name)
    .bind(w)
    .bind(h)
    .bind(req.origin)
    .bind(req.resolution_cm)
    .bind(req.areas)
    .bind(req.chargers)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("新增地图「{name}」"),
        &name,
        json!({}),
    )
    .await;
    maps_changed(&st, &id);
    Ok((StatusCode::CREATED, Json(m)))
}

pub async fn update_map(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<UpsertMap>,
) -> AppResult<Json<Map>> {
    user.require(Perm::EditMaps)?;
    validate_map(&req)?;
    let m: Map = sqlx::query_as(
        "UPDATE maps SET name = COALESCE($2, name), short_name = COALESCE($3, short_name),
         width_m = COALESCE($4, width_m), height_m = COALESCE($5, height_m), origin = COALESCE($6, origin),
         resolution_cm = COALESCE($7, resolution_cm), areas = COALESCE($8, areas),
         chargers = COALESCE($9, chargers), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(&id)
    .bind(req.name)
    .bind(req.short_name)
    .bind(req.width_m)
    .bind(req.height_m)
    .bind(req.origin)
    .bind(req.resolution_cm)
    .bind(req.areas)
    .bind(req.chargers)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("地图不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("修改地图「{}」", m.name),
        &m.name,
        json!({}),
    )
    .await;
    maps_changed(&st, &id);
    Ok(Json(m))
}

pub async fn delete_map(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let name: Option<String> = sqlx::query_scalar("DELETE FROM maps WHERE id = $1 RETURNING name")
        .bind(&id)
        .fetch_optional(&st.db)
        .await?;
    let name = name.ok_or_else(|| AppError::not_found("地图不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除地图「{name}」"),
        &name,
        json!({}),
    )
    .await;
    maps_changed(&st, &id);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct Charger {
    pub x: f64,
    pub y: f64,
}

/// POST /maps/{id}/chargers：手动标注充电桩
pub async fn add_charger(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(c): Json<Charger>,
) -> AppResult<Json<Map>> {
    user.require(Perm::EditMaps)?;
    if !(c.x.is_finite() && c.y.is_finite()) {
        return Err(AppError::bad_request("坐标必须是数字"));
    }
    let m: Map = sqlx::query_as(
        "UPDATE maps SET chargers = chargers || jsonb_build_array(jsonb_build_array($2::float8, $3::float8)),
         updated_at = now() WHERE id = $1 RETURNING *",
    )
    .bind(&id)
    .bind(c.x)
    .bind(c.y)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("地图不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("在地图「{}」上标注充电桩", m.name),
        &m.name,
        json!({ "x": c.x, "y": c.y }),
    )
    .await;
    maps_changed(&st, &id);
    Ok(Json(m))
}

/// POST /maps/{id}/remap：重新建图（需要机器人端 SLAM 建图能力）
pub async fn remap(_user: AuthUser, Path(_id): Path<String>) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("重新建图（机器人端 SLAM 建图）"))
}

// ───────── 任务 ─────────

fn missions_changed(st: &AppState, id: Uuid) {
    st.hub.publish(ServerEvent::changed("missions", Some(id)));
}

/// 任务改动后重新生成它今天的自动排期
async fn replan(st: &AppState, id: Uuid) {
    if let Err(e) = missions::plan_today(st, Some(id)).await {
        tracing::warn!(error = %e, mission = %id, "生成今日排期失败");
    }
}

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
    pub waypoints: Option<Value>,
    pub schedule: Option<String>,
    pub assignee: Option<Value>,
    pub state: Option<MissionState>,
    pub completed: Option<i32>,
    #[serde(rename = "loop")]
    pub loop_enabled: Option<bool>,
}

fn validate_mission(m: &UpsertMission) -> AppResult<()> {
    if m.waypoints.as_ref().is_some_and(|w| !w.is_array()) {
        return Err(AppError::bad_request("waypoints 必须是数组"));
    }
    if m.assignee.as_ref().is_some_and(|a| !a.is_object()) {
        return Err(AppError::bad_request(
            "assignee 必须是对象：{device_id, backup_device_id} 或 {preset_id}",
        ));
    }
    if m.completed.is_some_and(|c| c < 0) {
        return Err(AppError::bad_request("completed 不能为负"));
    }
    Ok(())
}

/// POST /missions：`{name, map_id}` 即可，其余字段用默认值
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertMission>,
) -> AppResult<(StatusCode, Json<Mission>)> {
    user.require(Perm::EditMaps)?;
    validate_mission(&req)?;
    let (Some(name), Some(map_id)) = (req.name, req.map_id) else {
        return Err(AppError::bad_request("name 和 map_id 必填"));
    };
    let m: Mission = sqlx::query_as(
        "INSERT INTO missions (name, map_id, waypoints, schedule, assignee, state, loop_enabled, created_by)
         VALUES ($1, $2, COALESCE($3, '[]'::jsonb), $4, COALESCE($5, '{}'::jsonb), COALESCE($6, 'scheduled'),
                 COALESCE($7, FALSE), $8)
         RETURNING *",
    )
    .bind(name)
    .bind(map_id)
    .bind(req.waypoints)
    .bind(req.schedule)
    .bind(req.assignee)
    .bind(req.state)
    .bind(req.loop_enabled)
    .bind(user.id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("新建任务「{}」", m.name),
        &m.name,
        json!({}),
    )
    .await;
    missions_changed(&st, m.id);
    replan(&st, m.id).await;
    st.missions.sync(&st, &m);
    Ok((StatusCode::CREATED, Json(m)))
}

/// PATCH /missions/{id}：运行 / 暂停 `{state}`、替换全部点位 `{waypoints}`、其他字段
pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertMission>,
) -> AppResult<Json<Mission>> {
    user.require(Perm::EditMaps)?;
    validate_mission(&req)?;
    let before: Mission = sqlx::query_as("SELECT * FROM missions WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("任务不存在"))?;
    let m: Mission = sqlx::query_as(
        "UPDATE missions SET name = COALESCE($2, name), map_id = COALESCE($3, map_id),
         waypoints = COALESCE($4, waypoints), schedule = COALESCE($5, schedule),
         assignee = COALESCE($6, assignee), state = COALESCE($7, state),
         completed = COALESCE($8, completed), loop_enabled = COALESCE($9, loop_enabled), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.map_id)
    .bind(&req.waypoints)
    .bind(req.schedule)
    .bind(req.assignee)
    .bind(req.state)
    .bind(req.completed)
    .bind(req.loop_enabled)
    .fetch_one(&st.db)
    .await?;
    let action = if m.state != before.state {
        match m.state {
            MissionState::Running => format!("运行任务「{}」", m.name),
            MissionState::Paused => format!("暂停任务「{}」", m.name),
            MissionState::Scheduled => format!("把任务「{}」改回排期", m.name),
        }
    } else if req.waypoints.is_some() {
        format!(
            "修改任务「{}」的点位（共 {} 个）",
            m.name,
            m.waypoints.as_array().map_or(0, Vec::len)
        )
    } else {
        format!("修改任务「{}」", m.name)
    };
    audit::record(&st, &user, audit::Kind::Config, action, &m.name, json!({})).await;
    missions_changed(&st, id);
    replan(&st, id).await;
    st.missions.sync(&st, &m);
    Ok(Json(m))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    st.missions.stop(id, true);
    st.leases.release_task(id).await?;
    sqlx::query(
        "DELETE FROM schedule_entries WHERE auto AND mission_id = $1 AND starts_at > now()",
    )
    .bind(id)
    .execute(&st.db)
    .await?;
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM missions WHERE id = $1 RETURNING name")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("任务不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除任务「{name}」"),
        &name,
        json!({}),
    )
    .await;
    missions_changed(&st, id);
    Ok(StatusCode::NO_CONTENT)
}

// ───────── 今日排期 ─────────

#[derive(Deserialize)]
pub struct ScheduleQuery {
    /// YYYY-MM-DD（按 SCHEDULE_TZ_OFFSET_MINUTES 的本地日期），缺省今天
    pub date: Option<NaiveDate>,
}

pub async fn schedule(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<ScheduleQuery>,
) -> AppResult<Json<Vec<ScheduleEntry>>> {
    user.require(Perm::ViewDevice)?;
    let day = q.date.unwrap_or_else(|| missions::local_today(&st));
    let (from, to) = missions::local_day_range(&st, day);
    Ok(Json(
        sqlx::query_as(
            "SELECT * FROM schedule_entries WHERE starts_at < $2 AND ends_at > $1 ORDER BY starts_at",
        )
        .bind(from)
        .bind(to)
        .fetch_all(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
pub struct NewEntry {
    pub device_id: String,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub label: String,
    pub kind: Option<String>,
    pub mission_id: Option<Uuid>,
}

/// POST /schedule：手动排期（调度器上线前由人工维护）
pub async fn add_schedule(
    State(st): State<AppState>,
    user: AuthUser,
    Json(e): Json<NewEntry>,
) -> AppResult<(StatusCode, Json<ScheduleEntry>)> {
    user.require(Perm::EditMaps)?;
    if e.end <= e.start {
        return Err(AppError::bad_request("结束时间必须晚于开始时间"));
    }
    let kind = e.kind.unwrap_or_else(|| "other".into());
    if !matches!(kind.as_str(), "run" | "charge" | "other") {
        return Err(AppError::bad_request("kind 只能是 run、charge、other"));
    }
    let row: ScheduleEntry = sqlx::query_as(
        "INSERT INTO schedule_entries (device_id, starts_at, ends_at, label, kind, mission_id)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
    )
    .bind(&e.device_id)
    .bind(e.start)
    .bind(e.end)
    .bind(&e.label)
    .bind(&kind)
    .bind(e.mission_id)
    .fetch_one(&st.db)
    .await?;
    st.hub
        .publish(ServerEvent::changed("schedule", None::<String>));
    Ok((StatusCode::CREATED, Json(row)))
}

pub async fn delete_schedule(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<i64>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let res = sqlx::query("DELETE FROM schedule_entries WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("排期不存在"));
    }
    st.hub
        .publish(ServerEvent::changed("schedule", None::<String>));
    Ok(StatusCode::NO_CONTENT)
}
