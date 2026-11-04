//! 设备运维（Maintenance.dc.html）。
//! 固件升级 / 回滚 / 重启 / 远程终端 / 诊断包需要机器人端 OTA 与受控 shell 能力，暂返回 501。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{DeviceLog, DeviceRow},
    protocol::ServerEvent,
    services::{access, audit, settings},
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
pub async fn diagnostics(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("诊断包导出"))
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
