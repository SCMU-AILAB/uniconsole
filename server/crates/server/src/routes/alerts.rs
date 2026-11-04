//! 告警中心（Alerts.dc.html）：告警列表 / 详情 / 处理、规则、通知渠道与值班。
//! TODO：通知渠道的实际发送（邮件 / 企业微信 / 飞书 / 短信 / APNs）。

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
    models::{Alert, AlertEvent, AlertRule, AlertSeverity, AlertState, Role},
    protocol::{Command, MotionMode, ServerEvent},
    services::{
        access,
        alerting::{AUTO_ACTIONS, add_event, default_metric_label},
        audit,
        control::{self, Actor, CommandResult},
        events, settings,
    },
    state::AppState,
    util::double_option,
};

#[derive(Deserialize)]
pub struct AlertQuery {
    pub state: Option<AlertState>,
    pub severity: Option<AlertSeverity>,
    pub device_id: Option<String>,
    pub assignee_id: Option<Uuid>,
    pub limit: Option<i64>,
}

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<AlertQuery>,
) -> AppResult<Json<Vec<Alert>>> {
    let visible = access::visible_devices(&st.db, &user).await?;
    Ok(Json(
        sqlx::query_as(
            "SELECT * FROM alerts
             WHERE ($1::alert_state IS NULL OR state = $1)
               AND ($2::alert_severity IS NULL OR severity = $2)
               AND ($3::text IS NULL OR device_id = $3)
               AND ($4::text[] IS NULL OR device_id IS NULL OR device_id = ANY($4))
               AND ($5::uuid IS NULL OR assignee_id = $5)
             ORDER BY created_at DESC LIMIT $6",
        )
        .bind(q.state)
        .bind(q.severity)
        .bind(q.device_id)
        .bind(visible)
        .bind(q.assignee_id)
        .bind(q.limit.unwrap_or(100).clamp(1, 500))
        .fetch_all(&st.db)
        .await?,
    ))
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

/// 审计里的告警名：「Charlie 左后腿电机过热」
async fn alert_label(st: &AppState, a: &Alert) -> String {
    match &a.device_id {
        Some(d) => format!("{} {}", audit::device_label(st, d).await, a.title),
        None => a.title.clone(),
    }
}

/// GET /alerts/{id}：`{alert, events[]}`
pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let alert = load(&st, &user, id).await?;
    let events: Vec<AlertEvent> =
        sqlx::query_as("SELECT * FROM alert_events WHERE alert_id = $1 ORDER BY ts, id")
            .bind(id)
            .fetch_all(&st.db)
            .await?;
    Ok(Json(json!({ "alert": alert, "events": events })))
}

#[derive(Deserialize)]
pub struct UpdateAlert {
    pub state: Option<AlertState>,
    /// 关闭时必填
    pub note: Option<String>,
    /// 指派处理人（状态同时变为 doing）
    pub assignee_id: Option<Uuid>,
    /// 静默到期时间；null = 取消静默
    #[serde(default, deserialize_with = "double_option")]
    pub silenced_until: Option<Option<DateTime<Utc>>>,
}

/// PATCH /alerts/{id}：确认（state=doing，当前用户成为处理人）/ 指派 / 关闭（note 必填）/ 重新打开 / 静默
pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateAlert>,
) -> AppResult<Json<Alert>> {
    let before = load(&st, &user, id).await?;
    if user.role == Role::Viewer {
        return Err(AppError::forbidden("观察者不能处理告警"));
    }
    let note = req.note.as_deref().map(str::trim).filter(|n| !n.is_empty());
    if req.state == Some(AlertState::Closed) && note.is_none() {
        return Err(AppError::bad_request("关闭告警需要填写处理说明"));
    }

    let mut state = req.state;
    let mut assignee = None;
    if let Some(a) = req.assignee_id {
        let ok: bool = sqlx::query_scalar(
            "SELECT EXISTS (SELECT 1 FROM members WHERE id = $1 AND NOT disabled)",
        )
        .bind(a)
        .fetch_one(&st.db)
        .await?;
        if !ok {
            return Err(AppError::bad_request("处理人不存在或已停用"));
        }
        assignee = Some(a);
        state.get_or_insert(AlertState::Doing);
    } else if state == Some(AlertState::Doing) && before.assignee_id.is_none() {
        assignee = Some(user.id);
    }

    let a: Alert = sqlx::query_as(
        "UPDATE alerts SET
            state = COALESCE($2, state),
            assignee_id = COALESCE($3, assignee_id),
            silenced_until = CASE WHEN $4 THEN $5 ELSE silenced_until END,
            closed_at = CASE WHEN COALESCE($2, state) = 'closed'::alert_state
                             THEN COALESCE(closed_at, now()) ELSE NULL END,
            updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(state)
    .bind(assignee)
    .bind(req.silenced_until.is_some())
    .bind(req.silenced_until.flatten())
    .fetch_one(&st.db)
    .await?;

    let label = alert_label(&st, &a).await;
    let mut lines: Vec<(String, String)> = Vec::new(); // (时间线, 审计)
    if let Some(m) = assignee.filter(|m| Some(*m) != before.assignee_id && *m != user.id) {
        let who = audit::member_label(&st, m).await;
        lines.push((
            format!("{} 指派给 {who}", user.name),
            format!("把告警「{label}」指派给 {who}"),
        ));
        st.hub.publish(ServerEvent::Notice {
            member_id: m,
            level: "warning".into(),
            text: format!("{} 把告警「{label}」指派给你", user.name),
        });
    }
    if a.state != before.state {
        let suffix = note.map(|n| format!("：{n}")).unwrap_or_default();
        lines.push(match a.state {
            AlertState::Doing => (
                format!("{} 已确认，正在处理{suffix}", user.name),
                format!("确认告警「{label}」"),
            ),
            AlertState::Closed => (
                format!("{} 关闭{suffix}", user.name),
                format!("关闭告警「{label}」{suffix}"),
            ),
            AlertState::Open => (
                format!("{} 重新打开{suffix}", user.name),
                format!("重新打开告警「{label}」"),
            ),
        });
    } else if let Some(n) = note {
        lines.push((
            format!("{}：{n}", user.name),
            format!("备注告警「{label}」：{n}"),
        ));
    }
    if let Some(s) = req.silenced_until {
        lines.push(match s {
            Some(t) => (
                format!("{} 静默至 {}", user.name, t.format("%m-%d %H:%M UTC")),
                format!("静默告警「{label}」至 {}", t.format("%Y-%m-%d %H:%M UTC")),
            ),
            None => (
                format!("{} 取消静默", user.name),
                format!("取消告警「{label}」的静默"),
            ),
        });
    }
    for (event, action) in &lines {
        add_event(&st.db, id, "info", event, Some(user.id)).await?;
        audit::record(
            &st,
            &user,
            audit::Kind::Alert,
            action,
            &label,
            json!({ "alert_id": id }),
        )
        .await;
    }

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
    st.hub.publish(ServerEvent::changed("alerts", Some(id)));
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
    if req.message.trim().is_empty() {
        return Err(AppError::bad_request("备注不能为空"));
    }
    add_event(
        &st.db,
        id,
        "info",
        &format!("{}：{}", user.name, req.message.trim()),
        Some(user.id),
    )
    .await?;
    st.hub.publish(ServerEvent::changed("alerts", Some(id)));
    Ok(StatusCode::CREATED)
}

/// POST /alerts/{id}/remote-down：走急停通道让设备趴下（不需要控制权，急停中也可以）
pub async fn remote_down(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<CommandResult>> {
    let a = load(&st, &user, id).await?;
    if user.role == Role::Viewer {
        return Err(AppError::forbidden("观察者不能处理告警"));
    }
    let device = a
        .device_id
        .clone()
        .ok_or_else(|| AppError::bad_request("该告警没有关联设备"))?;
    let r = control::execute(
        &st,
        Actor::Override(&user),
        &device,
        Command::SetMode {
            mode: MotionMode::Down,
        },
        true,
    )
    .await?;
    let label = alert_label(&st, &a).await;
    let text = if r.ok == Some(false) {
        format!(
            "{} 远程趴下失败：{}",
            user.name,
            r.message.clone().unwrap_or_default()
        )
    } else {
        format!("{} 远程趴下", user.name)
    };
    add_event(&st.db, id, "info", &text, Some(user.id)).await?;
    events::record(&st, &device, &text, "warning").await;
    audit::record(
        &st,
        &user,
        audit::Kind::Alert,
        format!("远程趴下（告警「{label}」）"),
        &label,
        json!({ "alert_id": id }),
    )
    .await;
    st.hub.publish(ServerEvent::changed("alerts", Some(id)));
    Ok(Json(r))
}

/// GET /alerts/{id}/history：触发前 30 分钟到关闭（或现在）的指标曲线 + 阈值
pub async fn history(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    let a = load(&st, &user, id).await?;
    let (Some(device), Some(metric)) = (&a.device_id, &a.metric) else {
        return Ok(Json(json!({ "values": [], "threshold": a.threshold })));
    };
    let from = a.created_at - Duration::minutes(30);
    let to = a
        .closed_at
        .unwrap_or_else(Utc::now)
        .min(a.created_at + Duration::hours(2));
    let column = match metric.as_str() {
        "max_motor_temp" | "battery" | "voltage" | "current" | "latency_ms" => {
            format!("{metric}::float8")
        }
        "pitch" | "roll" => format!("abs({metric})::float8"),
        _ => "(data->'extra'->>$4)::float8".into(),
    };
    let sql = format!(
        "SELECT ts, {column} AS v FROM telemetry
         WHERE device_id = $1 AND ts BETWEEN $2 AND $3 AND {column} IS NOT NULL ORDER BY ts LIMIT 2000"
    );
    let rows: Vec<(DateTime<Utc>, f64)> = sqlx::query_as(sqlx::AssertSqlSafe(sql))
        .bind(device)
        .bind(from)
        .bind(to)
        .bind(metric)
        .fetch_all(&st.db)
        .await?;
    let mut lo = rows.iter().map(|r| r.1).fold(f64::INFINITY, f64::min);
    let mut hi = rows.iter().map(|r| r.1).fold(f64::NEG_INFINITY, f64::max);
    if let Some(t) = a.threshold {
        lo = lo.min(t);
        hi = hi.max(t);
    }
    let pad = ((hi - lo) * 0.1).max(1.0);
    let values: Vec<Value> = rows
        .iter()
        .map(|(ts, v)| json!({ "ts": ts, "v": v }))
        .collect();
    Ok(Json(json!({
        "metric": metric,
        "metric_label": a.metric_label,
        "threshold": a.threshold,
        "from": from, "to": to,
        "min_y": if values.is_empty() { Value::Null } else { json!((lo - pad).floor()) },
        "max_y": if values.is_empty() { Value::Null } else { json!((hi + pad).ceil()) },
        "values": values,
    })))
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
    pub metric_label: Option<String>,
    pub op: Option<String>,
    pub threshold: Option<f64>,
    pub duration_secs: Option<i32>,
    pub severity: Option<AlertSeverity>,
    /// slow | stop | dock | notify；null = 无
    #[serde(default, deserialize_with = "double_option")]
    pub auto_action: Option<Option<String>>,
    pub enabled: Option<bool>,
}

fn validate_rule(r: &UpsertRule) -> AppResult<()> {
    if let Some(op) = r.op.as_deref()
        && !matches!(op, ">" | "<" | ">=" | "<=")
    {
        return Err(AppError::bad_request(format!("不支持的比较符 {op}")));
    }
    if let Some(Some(a)) = &r.auto_action
        && !AUTO_ACTIONS.contains(&a.as_str())
    {
        return Err(AppError::bad_request(
            "auto_action 只能是 slow、stop、dock、notify",
        ));
    }
    if r.duration_secs.is_some_and(|d| !(0..=86_400).contains(&d)) {
        return Err(AppError::bad_request("持续时间必须在 0–86400 秒之间"));
    }
    Ok(())
}

async fn rules_changed(st: &AppState) -> AppResult<()> {
    st.alerts.reload_rules(&st.db).await?;
    st.hub
        .publish(ServerEvent::changed("alert_rules", None::<String>));
    Ok(())
}

pub async fn create_rule(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertRule>,
) -> AppResult<(StatusCode, Json<AlertRule>)> {
    user.require(Perm::EditMaps)?;
    validate_rule(&req)?;
    let (Some(name), Some(metric), Some(op), Some(threshold), Some(severity)) =
        (req.name, req.metric, req.op, req.threshold, req.severity)
    else {
        return Err(AppError::bad_request(
            "name、metric、op、threshold、severity 必填",
        ));
    };
    let label = req
        .metric_label
        .unwrap_or_else(|| default_metric_label(&metric));
    let r: AlertRule = sqlx::query_as(
        "INSERT INTO alert_rules (name, metric, metric_label, op, threshold, duration_secs, severity, auto_action, enabled)
         VALUES ($1, $2, $3, $4, $5, COALESCE($6, 0), $7, $8, COALESCE($9, TRUE)) RETURNING *",
    )
    .bind(name)
    .bind(metric)
    .bind(label)
    .bind(op)
    .bind(threshold)
    .bind(req.duration_secs)
    .bind(severity)
    .bind(req.auto_action.flatten())
    .bind(req.enabled)
    .fetch_one(&st.db)
    .await?;
    rules_changed(&st).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Alert,
        format!("新增告警规则「{}」", r.name),
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
    validate_rule(&req)?;
    let r: AlertRule = sqlx::query_as(
        "UPDATE alert_rules SET name = COALESCE($2, name), metric = COALESCE($3, metric),
         metric_label = COALESCE($4, metric_label), op = COALESCE($5, op),
         threshold = COALESCE($6, threshold), duration_secs = COALESCE($7, duration_secs),
         severity = COALESCE($8, severity),
         auto_action = CASE WHEN $9 THEN $10 ELSE auto_action END,
         enabled = COALESCE($11, enabled)
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.metric)
    .bind(req.metric_label)
    .bind(req.op)
    .bind(req.threshold)
    .bind(req.duration_secs)
    .bind(req.severity)
    .bind(req.auto_action.is_some())
    .bind(req.auto_action.flatten())
    .bind(req.enabled)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("规则不存在"))?;
    rules_changed(&st).await?;
    let action = match req.enabled {
        Some(true) => format!("启用告警规则「{}」", r.name),
        Some(false) => format!("停用告警规则「{}」", r.name),
        None => format!("修改告警规则「{}」", r.name),
    };
    audit::record(&st, &user, audit::Kind::Alert, action, &r.name, json!({})).await;
    Ok(Json(r))
}

pub async fn delete_rule(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM alert_rules WHERE id = $1 RETURNING name")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("规则不存在"))?;
    rules_changed(&st).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Alert,
        format!("删除告警规则「{name}」"),
        &name,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

// ───────── 通知渠道与值班（告警页右栏） ─────────

pub async fn get_channels(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(
        settings::get(
            &st,
            "alert_channels",
            json!([{ "name": "应用内推送", "min_severity": "info" }]),
        )
        .await?,
    ))
}

pub async fn put_channels(
    State(st): State<AppState>,
    user: AuthUser,
    Json(v): Json<Value>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ManageMembers)?;
    let ok = v.as_array().is_some_and(|a| {
        a.iter().all(|c| {
            c["name"].is_string()
                && matches!(
                    c["min_severity"].as_str(),
                    Some("critical" | "warning" | "info")
                )
        })
    });
    if !ok {
        return Err(AppError::bad_request(
            "格式应为 [{name, min_severity: critical|warning|info}]",
        ));
    }
    settings::put(&st, "alert_channels", &v).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "修改告警通知渠道",
        "通知渠道",
        v.clone(),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("alert_channels", None::<String>));
    Ok(Json(v))
}

pub async fn get_on_call(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(
        settings::get(
            &st,
            "on_call",
            json!({ "weeks": [], "escalate_after_secs": 600, "escalate_to_id": null }),
        )
        .await?,
    ))
}

pub async fn put_on_call(
    State(st): State<AppState>,
    user: AuthUser,
    Json(v): Json<Value>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ManageMembers)?;
    if !v["weeks"].is_array() || !v["escalate_after_secs"].is_u64() {
        return Err(AppError::bad_request(
            "格式应为 {weeks: [成员 id], escalate_after_secs, escalate_to_id}",
        ));
    }
    settings::put(&st, "on_call", &v).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "修改值班安排",
        "值班",
        v.clone(),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("on_call", None::<String>));
    Ok(Json(v))
}
