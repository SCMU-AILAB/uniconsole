//! 设备运维（Maintenance.dc.html）。
//! 固件升级 / 回滚 / 重启 / 远程终端需要机器人端 OTA 与受控 shell 能力，暂返回 501；
//! 诊断包由服务端汇总已有数据（JSON）。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::Utc;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{DeviceLog, DeviceRow},
    protocol::ServerEvent,
    services::{access, audit, export, settings},
    state::AppState,
};

fn default_release() -> Value {
    json!({ "latest": {}, "agent_version": null, "notes": [] })
}

/// GET /firmware：每台可见设备的固件状态
pub async fn firmware(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Vec<Value>>> {
    user.require(Perm::ViewDevice)?;
    let visible = access::visible_devices(&st.db, &user).await?;
    let release = settings::get(&st, "firmware_release", default_release()).await?;
    let rows: Vec<DeviceRow> = sqlx::query_as(
        "SELECT * FROM devices WHERE ($1::text[] IS NULL OR id = ANY($1)) ORDER BY code",
    )
    .bind(visible)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(
        rows.into_iter()
            .map(|d| {
                let target = release["latest"]
                    .get(&d.model)
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let online = st.hub.is_online(&d.id);
                let state = match (&target, &d.firmware) {
                    (None, _) => "latest",
                    (Some(t), Some(c)) if t == c => "latest",
                    _ if !online => "waiting_online",
                    _ => "available",
                };
                json!({ "device_id": d.id, "current": d.firmware, "target": target,
                        "state": state, "progress": null, "error": null })
            })
            .collect(),
    ))
}

pub async fn get_release(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(
        settings::get(&st, "firmware_release", default_release()).await?,
    ))
}

/// PUT /firmware/release：`{latest: {"Unitree Go2 EDU": "v1.1.8"}, agent_version, notes: []}`（管理员）
pub async fn put_release(
    State(st): State<AppState>,
    user: AuthUser,
    Json(v): Json<Value>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ManageMembers)?;
    if !v["latest"].is_object() || !v["notes"].is_array() {
        return Err(AppError::bad_request(
            "格式应为 {latest: {型号: 版本}, agent_version, notes: []}",
        ));
    }
    settings::put(&st, "firmware_release", &v).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "更新固件发布信息",
        "固件",
        v.clone(),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("firmware", None::<String>));
    Ok(Json(v))
}

pub async fn upgrade(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("固件升级（机器人端 OTA）"))
}
pub async fn schedule_upgrade(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("排期升级（机器人端 OTA）"))
}
pub async fn rollback(_user: AuthUser, Path(_id): Path<String>) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("固件回滚（机器人端 OTA）"))
}
pub async fn reboot(_user: AuthUser, Path(_id): Path<String>) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("远程重启"))
}
pub async fn terminal(_user: AuthUser, Path(_id): Path<String>) -> AppResult<StatusCode> {
    Err(AppError::not_implemented(
        "远程终端（需要机器人端受控 shell 与二次验证）",
    ))
}
#[derive(Deserialize)]
pub struct DiagnosticsReq {
    pub device_ids: Vec<String>,
}

fn diag_purpose(ids: &[String]) -> String {
    format!("diagnostics:{}", ids.join(","))
}

fn diag_filename(ids: &[String]) -> String {
    let who = match ids {
        [one] => one.clone(),
        _ => format!("{}-devices", ids.len()),
    };
    format!("diag_{who}_{}.json", Utc::now().format("%Y%m%d_%H%M"))
}

/// POST /diagnostics `{device_ids}` → `{url, filename, expires_at}`：服务端诊断包（JSON）的签名下载链接
pub async fn diagnostics(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<DiagnosticsReq>,
) -> AppResult<Json<Value>> {
    let mut ids = req.device_ids;
    ids.sort();
    ids.dedup();
    if ids.is_empty() || ids.len() > 50 {
        return Err(AppError::bad_request("device_ids 需要 1–50 台设备"));
    }
    for id in &ids {
        access::require_device(&st.db, &user, Perm::Maintenance, id).await?;
    }
    let now = Utc::now();
    let token = export::link_token(&st.cfg.jwt_secret, &diag_purpose(&ids), now);
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("导出诊断包（{} 台设备）", ids.len()),
        ids.join("、"),
        json!({ "device_ids": ids }),
    )
    .await;
    Ok(Json(json!({
        "url": format!("/api/v1/diagnostics/download?devices={}&token={token}", ids.join(",")),
        "filename": diag_filename(&ids),
        "expires_at": now + chrono::Duration::seconds(export::LINK_TTL_SECS),
    })))
}

#[derive(Deserialize)]
pub struct DiagnosticsDownload {
    pub devices: String,
    pub token: String,
}

/// GET /diagnostics/download?devices=&token=：按签名链接下载诊断包（不需要登录态）
pub async fn diagnostics_download(
    State(st): State<AppState>,
    Query(q): Query<DiagnosticsDownload>,
) -> AppResult<axum::response::Response> {
    let ids: Vec<String> = q.devices.split(',').map(str::to_owned).collect();
    if !export::verify_token(
        &st.cfg.jwt_secret,
        &diag_purpose(&ids),
        &q.token,
        Utc::now(),
    ) {
        return Err(AppError::forbidden("下载链接无效或已过期，请重新导出"));
    }
    let mut devices = Vec::with_capacity(ids.len());
    for id in &ids {
        let report: Value = sqlx::query_scalar(
            "SELECT jsonb_build_object(
               'device', (SELECT to_jsonb(d) - 'token_hash' FROM devices d WHERE d.id = $1),
               'lease', (SELECT to_jsonb(l) FROM leases l WHERE l.device_id = $1),
               'logs', COALESCE((SELECT jsonb_agg(x) FROM (SELECT at, level, message FROM device_logs
                        WHERE device_id = $1 ORDER BY at DESC LIMIT 500) x), '[]'),
               'events', COALESCE((SELECT jsonb_agg(x) FROM (SELECT at, text, tone FROM device_events
                        WHERE device_id = $1 ORDER BY at DESC LIMIT 200) x), '[]'),
               'commands', COALESCE((SELECT jsonb_agg(x) FROM (SELECT created_at, actor_name, command, ok, error, error_code
                        FROM command_log WHERE device_id = $1 AND created_at > now() - interval '24 hours'
                        ORDER BY created_at DESC LIMIT 500) x), '[]'),
               'alerts', COALESCE((SELECT jsonb_agg(x) FROM (SELECT id, severity, state, title, metric, peak, created_at, closed_at
                        FROM alerts WHERE device_id = $1 AND created_at > now() - interval '7 days'
                        ORDER BY created_at DESC LIMIT 100) x), '[]'),
               'telemetry_last_hour', COALESCE((SELECT jsonb_agg(x) FROM (SELECT ts, battery, voltage, current, max_motor_temp
                        FROM telemetry WHERE device_id = $1 AND ts > now() - interval '1 hour' ORDER BY ts) x), '[]'))",
        )
        .bind(id)
        .fetch_one(&st.db)
        .await?;
        let live = st.hub.live(id);
        let mut report = report;
        report["live"] = json!({
            "online": st.hub.is_online(id),
            "estop": st.hub.is_device_estopped(id),
            "latency_ms": live.latency_ms,
            "telemetry": live.telemetry,
        });
        devices.push(report);
    }
    let body = json!({
        "generated_at": Utc::now(),
        "server_version": env!("CARGO_PKG_VERSION"),
        "global_estop": st.safety.is_global_estop(),
        "policies": st.safety.policies(),
        "devices": devices,
    });
    export::attachment(
        &diag_filename(&ids),
        "application/json",
        serde_json::to_vec_pretty(&body).map_err(|e| AppError::Internal(e.into()))?,
    )
}

/// GET /battery-health：机器人端尚未上报电池循环次数 / 满充容量，返回空数据
pub async fn battery_health(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<Value>>> {
    user.require(Perm::ViewDevice)?;
    let visible = access::visible_devices(&st.db, &user).await?;
    let ids: Vec<String> = sqlx::query_scalar(
        "SELECT id FROM devices WHERE ($1::text[] IS NULL OR id = ANY($1)) ORDER BY code",
    )
    .bind(visible)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(
        ids.into_iter()
            .map(|d| json!({ "device_id": d, "cycles": null, "monthly": [] }))
            .collect(),
    ))
}

#[derive(Deserialize)]
pub struct LogQuery {
    pub device_id: Option<String>,
    /// info | warn | error
    pub level: Option<String>,
    pub limit: Option<i64>,
}

/// GET /logs：设备日志（机器人上报的事件）
pub async fn logs(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<LogQuery>,
) -> AppResult<Json<Vec<DeviceLog>>> {
    user.require(Perm::ViewDevice)?;
    if let Some(d) = &q.device_id {
        access::require_device(&st.db, &user, Perm::ViewDevice, d).await?;
    }
    let visible = access::visible_devices(&st.db, &user).await?;
    Ok(Json(
        sqlx::query_as(
            "SELECT at, level, device_id, message FROM device_logs
             WHERE ($1::text IS NULL OR device_id = $1) AND ($2::text IS NULL OR level = $2)
               AND ($3::text[] IS NULL OR device_id = ANY($3))
             ORDER BY at DESC, id DESC LIMIT $4",
        )
        .bind(q.device_id)
        .bind(q.level)
        .bind(visible)
        .bind(q.limit.unwrap_or(200).clamp(1, 2000))
        .fetch_all(&st.db)
        .await?,
    ))
}

pub async fn get_window(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(
        settings::get(
            &st,
            "maintenance_window",
            json!({ "start_min": 1380, "end_min": 180 }),
        )
        .await?,
    ))
}

/// PUT /maintenance-window：`{start_min, end_min}` 距零点的分钟数，可跨零点
pub async fn put_window(
    State(st): State<AppState>,
    user: AuthUser,
    Json(v): Json<Value>,
) -> AppResult<Json<Value>> {
    user.require(Perm::Maintenance)?;
    let ok = ["start_min", "end_min"]
        .iter()
        .all(|k| v[k].as_u64().is_some_and(|m| m < 1440));
    if !ok {
        return Err(AppError::bad_request(
            "start_min / end_min 必须是 0–1439 的整数（距零点的分钟数）",
        ));
    }
    settings::put(&st, "maintenance_window", &v).await?;
    let fmt = |m: u64| format!("{:02}:{:02}", m / 60, m % 60);
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!(
            "把维护窗口改为 {}–{}",
            fmt(v["start_min"].as_u64().unwrap_or(0)),
            fmt(v["end_min"].as_u64().unwrap_or(0))
        ),
        "维护窗口",
        v.clone(),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("maintenance_window", None::<String>));
    Ok(Json(v))
}
