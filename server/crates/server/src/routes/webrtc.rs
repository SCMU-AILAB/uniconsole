//! ICE 服务器列表（WebRTC 信令本身在 `realtime::webrtc`）。

use axum::{Json, extract::State};
use serde_json::Value;

use crate::{auth::AuthUser, error::AppResult, state::AppState};

/// GET /webrtc/ice-servers：ICE_SERVERS（JSON 数组）+ 配置了 TURN_SECRET 时的限时 TURN 凭据；缺省为空（仅局域网直连）
pub async fn ice_servers(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(crate::realtime::webrtc::ice_servers(&st, user.id)))
}
