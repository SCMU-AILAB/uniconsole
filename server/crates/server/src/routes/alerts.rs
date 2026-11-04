//! 告警中心（Alerts.dc.html）。
//! TODO：通知渠道（企业微信 / 飞书 / 短信 / 推送）。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{Alert, AlertEvent, AlertRule, AlertSeverity, AlertState},
    protocol::ServerEvent,
    services::{access, alerting::add_event, audit},
    state::AppState,
};

#[derive(Deserialize)]
pub struct AlertQuery {
    pub state: Option<AlertState>,
    pub severity: Option<AlertSeverity>,
    pub device_id: Option<String>,
    pub limit: Option<i64>,
}

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<AlertQuery>,
) -> AppResult<Json<Vec<Alert>>> {
    let visible = access::visible_devices(&st.db, &user).await?;
    let rows = sqlx::query_as(
        "SELECT * FROM alerts
         WHERE ($1::alert_state IS NULL OR state = $1)
           AND ($2::alert_severity IS NULL OR severity = $2)
           AND ($3::text IS NULL OR device_id = $3)
           AND ($4::text[] IS NULL OR device_id IS NULL OR device_id = ANY($4))
         ORDER BY created_at DESC LIMIT $5",
    )
    .bind(q.state)
    .bind(q.severity)
    .bind(q.device_id)
    .bind(visible)
    .bind(q.limit.unwrap_or(100).clamp(1, 500))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}

async fn load(st: &AppState, user: &AuthUser, id: Uuid) -> AppResult<Alert> {
    let a: Alert = sqlx::query_as("SELECT * FROM alerts WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("告警不存在"))?;
    if let Some(d) = &a.device_id {
        access::require_device(&st.db, user, Perm::ViewDevice, d).await?;
    }
    Ok(a)
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let alert = load(&st, &user, id).await?;
    let events: Vec<AlertEvent> =
        sqlx::query_as("SELECT * FROM alert_events WHERE alert_id = $1 ORDER BY ts")
            .bind(id)
            .fetch_all(&st.db)
            .await?;
    Ok(Json(json!({ "alert": alert, "events": events })))
}

#[derive(Deserialize)]
pub struct UpdateAlert {
    pub state: AlertState,
    pub note: Option<String>,
}

/// 确认（doing）/ 关闭（closed）/ 重新打开（open）
pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateAlert>,
) -> AppResult<Json<Alert>> {
    load(&st, &user, id).await?;
    if user.role == crate::models::Role::Viewer {
        return Err(AppError::forbidden("观察者不能处理告警"));
    }
    let a: Alert = sqlx::query_as(
        "UPDATE alerts SET state = $2, updated_at = now(),
         closed_at = CASE WHEN $2 = 'closed'::alert_state THEN now() ELSE NULL END
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.state)
    .fetch_one(&st.db)
    .await?;

    let verb = match req.state {
        AlertState::Open => "重新打开",
        AlertState::Doing => "已确认",
        AlertState::Closed => "关闭",
    };
    let msg = match &req.note {
        Some(n) if !n.is_empty() => format!("{} {verb}：{n}", user.name),
        _ => format!("{} {verb}", user.name),
    };
    sqlx::query(
        "INSERT INTO alert_events (alert_id, level, message, actor_id) VALUES ($1, 'note', $2, $3)",
    )
    .bind(id)
    .bind(&msg)
    .bind(user.id)
    .execute(&st.db)
    .await?;

    if a.state == AlertState::Closed
        && let (Some(d), Some(r)) = (&a.device_id, a.rule_id)
    {
        st.alerts.on_closed(d, r);
    }
    st.hub.publish(ServerEvent::Alert {
        alert_id: a.id,
        device_id: a.device_id.clone(),
        severity: a.severity,
        title: a.title.clone(),
        state: a.state,
    });
    Ok(Json(a))
}

#[derive(Deserialize)]
pub struct NoteReq {
    pub message: String,
}

pub async fn add_note(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<NoteReq>,
) -> AppResult<StatusCode> {
    load(&st, &user, id).await?;
    add_event(
        &st.db,
        id,
        "note",
        &format!("{}：{}", user.name, req.message),
    )
    .await?;
    Ok(StatusCode::CREATED)
}

// ───────── 规则 ─────────

pub async fn list_rules(
    State(st): State<AppState>,
    _user: AuthUser,
) -> AppResult<Json<Vec<AlertRule>>> {
    Ok(Json(
        sqlx::query_as("SELECT * FROM alert_rules ORDER BY created_at")
            .fetch_all(&st.db)
            .await?,
    ))
}

#[derive(Deserialize)]
pub struct UpsertRule {
    pub name: Option<String>,
    pub metric: Option<String>,
    pub op: Option<String>,
    pub threshold: Option<f64>,
    pub duration_secs: Option<i32>,
    pub severity: Option<AlertSeverity>,
    pub auto_action: Option<String>,
    pub enabled: Option<bool>,
}

fn validate_op(op: &Option<String>) -> AppResult<()> {
    match op.as_deref() {
        None | Some(">" | "<" | ">=" | "<=") => Ok(()),
        Some(o) => Err(AppError::bad_request(format!("不支持的比较符 {o}"))),
    }
}

async fn reload(st: &AppState) -> AppResult<()> {
    st.alerts.reload_rules(&st.db).await?;
    Ok(())
}

pub async fn create_rule(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertRule>,
) -> AppResult<(StatusCode, Json<AlertRule>)> {
    user.require(Perm::EditMaps)?;
    validate_op(&req.op)?;
    let (Some(name), Some(metric), Some(op), Some(threshold), Some(severity)) =
        (req.name, req.metric, req.op, req.threshold, req.severity)
    else {
        return Err(AppError::bad_request(
            "name、metric、op、threshold、severity 必填",
        ));
    };
    let r: AlertRule = sqlx::query_as(
        "INSERT INTO alert_rules (name, metric, op, threshold, duration_secs, severity, auto_action, enabled)
         VALUES ($1, $2, $3, $4, COALESCE($5, 0), $6, $7, COALESCE($8, TRUE)) RETURNING *",
    )
    .bind(name)
    .bind(metric)
    .bind(op)
    .bind(threshold)
    .bind(req.duration_secs)
    .bind(severity)
    .bind(req.auto_action)
    .bind(req.enabled)
    .fetch_one(&st.db)
    .await?;
    reload(&st).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Alert,
        "新增告警规则",
        &r.name,
        json!({}),
    )
    .await;
    Ok((StatusCode::CREATED, Json(r)))
}

pub async fn update_rule(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertRule>,
) -> AppResult<Json<AlertRule>> {
    user.require(Perm::EditMaps)?;
    validate_op(&req.op)?;
    let r: AlertRule = sqlx::query_as(
        "UPDATE alert_rules SET name = COALESCE($2, name), metric = COALESCE($3, metric), op = COALESCE($4, op),
         threshold = COALESCE($5, threshold), duration_secs = COALESCE($6, duration_secs),
         severity = COALESCE($7, severity), auto_action = COALESCE($8, auto_action), enabled = COALESCE($9, enabled)
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.metric)
    .bind(req.op)
    .bind(req.threshold)
    .bind(req.duration_secs)
    .bind(req.severity)
    .bind(req.auto_action)
    .bind(req.enabled)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("规则不存在"))?;
    reload(&st).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Alert,
        "修改告警规则",
        &r.name,
        json!({}),
    )
    .await;
    Ok(Json(r))
}

pub async fn delete_rule(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let res = sqlx::query("DELETE FROM alert_rules WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("规则不存在"));
    }
    reload(&st).await?;
    Ok(StatusCode::NO_CONTENT)
}
