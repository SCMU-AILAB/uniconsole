//! 已规划、尚未实现的模块：智能体（独立服务）、对讲播报；以及 ICE 服务器列表。
//! 统一返回 501 `not_implemented`，前端据此显示「尚未接入」。

use axum::{Json, extract::State, http::StatusCode};
use serde_json::{Value, json};

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    state::AppState,
};

pub async fn agent(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("智能体服务"))
}

pub async fn intercom_broadcast(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("对讲播报（TTS）"))
}

/// GET /intercom/targets：播报对象 = 全部设备 + 各设备分组
pub async fn intercom_targets(
    State(st): State<AppState>,
    _user: AuthUser,
) -> AppResult<Json<Value>> {
    let all: Vec<String> = sqlx::query_scalar("SELECT id FROM devices ORDER BY code")
        .fetch_all(&st.db)
        .await?;
    let groups: Vec<(String, String, Vec<String>)> = sqlx::query_as(
        "SELECT g.id, g.name, COALESCE(array_agg(d.id ORDER BY d.code) FILTER (WHERE d.id IS NOT NULL), '{}')
         FROM device_groups g LEFT JOIN devices d ON d.group_id = g.id GROUP BY g.id, g.name, g.sort ORDER BY g.sort, g.name",
    )
    .fetch_all(&st.db)
    .await?;
    let mut out = vec![json!({ "id": "all", "label": "全部设备", "device_ids": all })];
    out.extend(groups.into_iter().map(
        |(id, name, ids)| json!({ "id": format!("group:{id}"), "label": name, "device_ids": ids }),
    ));
    Ok(Json(json!(out)))
}

pub async fn intercom_presets(
    State(st): State<AppState>,
    _user: AuthUser,
) -> AppResult<Json<Value>> {
    Ok(Json(
        crate::services::settings::get(
            &st,
            "intercom_presets",
            json!(["请注意，设备正在通过", "请勿靠近设备", "巡检进行中，请让行"]),
        )
        .await?,
    ))
}

/// GET /webrtc/ice-servers：ICE_SERVERS（JSON 数组）+ 配置了 TURN_SECRET 时的限时 TURN 凭据；缺省为空（仅局域网直连）
pub async fn ice_servers(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(crate::realtime::webrtc::ice_servers(&st, user.id)))
}
