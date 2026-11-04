//! 录制与回放（Replay.dc.html）。
//! 当前录制内容 = 服务端 1 Hz 遥测 + 指令日志；视频 / 点云 / 导出 MCAP 需要机器人端录制，返回 501。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::RecordingRow,
    protocol::ServerEvent,
    services::{access, audit, recordings, settings},
    state::AppState,
};

#[derive(Deserialize)]
pub struct ListQuery {
    pub tag: Option<String>,
    pub device_id: Option<String>,
    pub limit: Option<i64>,
}

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<Value>>> {
    user.require(Perm::ViewSensors)?;
    let visible = access::visible_devices(&st.db, &user).await?;
    let rows: Vec<RecordingRow> = sqlx::query_as(
        "SELECT * FROM recordings
         WHERE ($1::text IS NULL OR $1 = ANY(tags)) AND ($2::text IS NULL OR $2 = ANY(device_ids))
           AND ($3::text[] IS NULL OR device_ids && $3)
         ORDER BY start_at DESC LIMIT $4",
    )
    .bind(q.tag)
    .bind(q.device_id)
    .bind(visible)
    .bind(q.limit.unwrap_or(50).clamp(1, 200))
    .fetch_all(&st.db)
    .await?;
    let mut out = Vec::with_capacity(rows.len());
    for r in rows {
        out.push(recordings::view(&st, r).await?);
    }
    Ok(Json(out))
}

async fn load(st: &AppState, id: Uuid) -> AppResult<RecordingRow> {
    sqlx::query_as("SELECT * FROM recordings WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("录制不存在"))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ViewSensors)?;
    Ok(Json(recordings::view(&st, load(&st, id).await?).await?))
}

#[derive(Deserialize)]
pub struct NewRecording {
    pub name: String,
    pub device_ids: Vec<String>,
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    #[serde(default)]
    pub tags: Vec<String>,
    pub map_id: Option<String>,
}

/// POST /recordings：手动标记一段录制（时间范围内的遥测与指令）
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<NewRecording>,
) -> AppResult<(StatusCode, Json<Value>)> {
    user.require(Perm::ViewSensors)?;
    if req.end <= req.start || req.device_ids.is_empty() {
        return Err(AppError::bad_request(
            "请选择设备，结束时间必须晚于开始时间",
        ));
    }
    for d in &req.device_ids {
        access::require_device(&st.db, &user, Perm::ViewSensors, d).await?;
    }
    let mut tags = req.tags;
    if tags.is_empty() {
        tags.push("manual".into());
    }
    let r: RecordingRow = sqlx::query_as(
        "INSERT INTO recordings (name, device_ids, start_at, end_at, tags, map_id, created_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING *",
    )
    .bind(&req.name)
    .bind(&req.device_ids)
    .bind(req.start)
    .bind(req.end)
    .bind(&tags)
    .bind(req.map_id)
    .bind(user.id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("新建录制「{}」", r.name),
        &r.name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("recordings", Some(r.id)));
    Ok((StatusCode::CREATED, Json(recordings::view(&st, r).await?)))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::Maintenance)?;
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM recordings WHERE id = $1 RETURNING name")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("录制不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除录制「{name}」"),
        &name,
        json!({}),
    )
    .await;
    st.hub.publish(ServerEvent::changed("recordings", Some(id)));
    Ok(StatusCode::NO_CONTENT)
}

/// (桶序号, 平均最高电机温度, 平均 vx, 平均 x, 平均 y)
type SampleRow = (i32, Option<f64>, Option<f64>, Option<f64>, Option<f64>);

/// GET /recordings/{id}/samples：按时长等分 120 个采样点
pub async fn samples(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ViewSensors)?;
    let r = load(&st, id).await?;
    let rows: Vec<SampleRow> = sqlx::query_as(
        "SELECT width_bucket(extract(epoch FROM ts), extract(epoch FROM $2::timestamptz),
                             extract(epoch FROM $3::timestamptz), 120)::int AS b,
                avg(max_motor_temp)::float8, avg(vx)::float8,
                avg((data->'pose'->>'x')::float8), avg((data->'pose'->>'y')::float8)
         FROM telemetry WHERE device_id = $1 AND ts BETWEEN $2 AND $3
         GROUP BY b ORDER BY b",
    )
    .bind(r.device_ids.first())
    .bind(r.start_at)
    .bind(r.end_at)
    .fetch_all(&st.db)
    .await?;
    let mut temperature = vec![Value::Null; 120];
    let mut velocity = vec![Value::Null; 120];
    let mut trajectory = Vec::new();
    for (b, t, v, x, y) in rows {
        if (1..=120).contains(&b) {
            temperature[(b - 1) as usize] = json!(t);
            velocity[(b - 1) as usize] = json!(v);
            if let (Some(x), Some(y)) = (x, y) {
                trajectory.push(json!([x, y]));
            }
        }
    }
    Ok(Json(json!({
        "chart_title": "电机最高温度（°C）",
        "device_id": r.device_ids.first(),
        "temperature": temperature,
        "velocity": velocity,
        "trajectory": trajectory,
        "cloud": [],
    })))
}

#[derive(Deserialize)]
pub struct Clip {
    pub from_ms: i64,
    pub to_ms: i64,
    pub name: Option<String>,
}

/// POST /recordings/{id}/clip：剪出一段新录制
pub async fn clip(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(c): Json<Clip>,
) -> AppResult<(StatusCode, Json<Value>)> {
    user.require(Perm::ViewSensors)?;
    let r = load(&st, id).await?;
    let total = (r.end_at - r.start_at).num_milliseconds();
    if c.from_ms < 0 || c.to_ms <= c.from_ms || c.to_ms > total {
        return Err(AppError::bad_request(format!(
            "剪辑范围必须在 0–{total} ms 之间且结束晚于开始"
        )));
    }
    let name = c.name.unwrap_or_else(|| format!("{}（片段）", r.name));
    let n: RecordingRow = sqlx::query_as(
        "INSERT INTO recordings (name, device_ids, start_at, end_at, tags, map_id, source_id, clip_of, created_by)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING *",
    )
    .bind(&name)
    .bind(&r.device_ids)
    .bind(r.start_at + Duration::milliseconds(c.from_ms))
    .bind(r.start_at + Duration::milliseconds(c.to_ms))
    .bind(&r.tags)
    .bind(&r.map_id)
    .bind(&r.source_id)
    .bind(r.id)
    .bind(user.id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("从「{}」剪出片段「{name}」", r.name),
        &name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("recordings", Some(n.id)));
    Ok((StatusCode::CREATED, Json(json!({ "id": n.id }))))
}

/// POST /recordings/{id}/export：导出 MCAP / rosbag（需要机器人端原始录制）
pub async fn export(_user: AuthUser, Path(_id): Path<Uuid>) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("导出 MCAP / rosbag"))
}

/// GET /recordings/storage
pub async fn storage(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    user.require(Perm::ViewSensors)?;
    let used: i64 = sqlx::query_scalar(
        "SELECT (pg_total_relation_size('telemetry') + pg_total_relation_size('command_log'))::bigint",
    )
    .fetch_one(&st.db)
    .await?;
    let retention = settings::get(&st, "recording_retention_days", json!(30)).await?;
    Ok(Json(json!({
        "used_bytes": used,
        "total_bytes": null,
        "retention_days": retention,
        "auto_rules": ["告警前后 60 秒", "所有联调会话"],
    })))
}
