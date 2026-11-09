//! 已规划、尚未实现的模块：智能体（独立服务）；以及 ICE 服务器列表。
//! 统一返回 501 `not_implemented`，前端据此显示「尚未接入」。

use axum::{Json, extract::State, http::StatusCode};
use serde_json::Value;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    state::AppState,
};

pub async fn agent(_user: AuthUser) -> AppResult<StatusCode> {
    Err(AppError::not_implemented("智能体服务"))
}

/// GET /webrtc/ice-servers：ICE_SERVERS（JSON 数组）+ 配置了 TURN_SECRET 时的限时 TURN 凭据；缺省为空（仅局域网直连）
pub async fn ice_servers(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(crate::realtime::webrtc::ice_servers(&st, user.id)))
}
