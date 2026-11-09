//! WebRTC 信令中继（前端交接文档 §15）。媒体不经过服务器：服务器只在 `/api/v1/ws` 与机器人连接之间
//! 转发 offer / answer / ice / close，并负责鉴权、会话归属和断线清理。
//!
//! - 一路视频 = 一个前端生成的 `session_id`，归属发起它的那条前端连接；信令只回给这条连接。
//! - 设备必须在 hello 的 `capabilities` 里声明 `webrtc`，否则返回 501（机器人端尚未接入视频）。
//! - 前端连接断开 → 通知机器人关闭它的所有会话；机器人掉线 → 通知前端 `webrtc_close`（reason「设备离线」）。
//!
//! ICE 服务器：`ICE_SERVERS`（静态 JSON 数组）+ 可选的限时 TURN 凭据（coturn `use-auth-secret`）：
//! `username = "<过期时间戳>:<成员 id>"`，`credential = base64(HMAC-SHA1(TURN_SECRET, username))`。

use chrono::Utc;
use dashmap::DashMap;
use data_encoding::BASE64;
use hmac::{Hmac, KeyInit, Mac};
use serde_json::{Value, json};
use sha1::Sha1;
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    protocol::{RobotToServer, ServerEvent, ServerToRobot},
    services::access,
    state::AppState,
};

/// 前端发来的 offer
pub struct Offer {
    pub device_id: String,
    pub session_id: String,
    pub sdp: String,
    pub streams: Vec<String>,
}

#[derive(Debug, Clone)]
struct Session {
    conn_id: Uuid,
    device_id: String,
}

/// session_id → 归属
#[derive(Default)]
pub struct WebrtcSessions {
    sessions: DashMap<String, Session>,
}

/// 给某成员的 ICE 服务器列表（GET /webrtc/ice-servers 和转发给机器人的 offer 用同一份）
pub fn ice_servers(st: &AppState, member_id: Uuid) -> Value {
    let mut list = st.cfg.ice_servers.as_array().cloned().unwrap_or_default();
    if let Some(secret) = &st.cfg.turn_secret
        && !st.cfg.turn_urls.is_empty()
    {
        let expires = Utc::now().timestamp() + st.cfg.turn_ttl_secs;
        let username = format!("{expires}:{member_id}");
        let mut mac = Hmac::<Sha1>::new_from_slice(secret.as_bytes()).expect("hmac key");
        mac.update(username.as_bytes());
        list.push(json!({
            "urls": st.cfg.turn_urls,
            "username": username,
            "credential": BASE64.encode(&mac.finalize().into_bytes()),
            "expires_at": chrono::DateTime::from_timestamp(expires, 0),
        }));
    }
    Value::Array(list)
}

fn robot_supports_webrtc(meta: &Value) -> bool {
    meta["capabilities"]
        .as_array()
        .is_some_and(|c| c.iter().any(|v| v == "webrtc"))
}

impl WebrtcSessions {
    fn owned(&self, conn_id: Uuid, device_id: &str, session_id: &str) -> AppResult<()> {
        match self.sessions.get(session_id) {
            Some(s) if s.conn_id == conn_id && s.device_id == device_id => Ok(()),
            Some(_) => Err(AppError::forbidden("该视频会话不属于当前连接")),
            None => Err(AppError::not_found("视频会话不存在或已结束")),
        }
    }

    /// 前端 offer：鉴权后转发给机器人
    pub async fn offer(
        &self,
        st: &AppState,
        user: &AuthUser,
        conn_id: Uuid,
        offer: Offer,
    ) -> AppResult<()> {
        let Offer {
            device_id,
            session_id,
            sdp,
            mut streams,
        } = offer;
        let (device_id, session_id) = (device_id.as_str(), session_id.as_str());
        if session_id.is_empty() || session_id.len() > 128 {
            return Err(AppError::bad_request("session_id 长度应为 1–128"));
        }
        access::require_device(&st.db, user, Perm::ViewSensors, device_id).await?;
        if !st.hub.is_online(device_id) {
            return Err(AppError::RobotOffline(device_id.to_owned()));
        }
        let meta: Value = sqlx::query_scalar("SELECT meta FROM devices WHERE id = $1")
            .bind(device_id)
            .fetch_optional(&st.db)
            .await?
            .unwrap_or_default();
        if !robot_supports_webrtc(&meta) {
            return Err(AppError::not_implemented("该设备的视频（机器人端 WebRTC）"));
        }
        match self.sessions.entry(session_id.to_owned()) {
            dashmap::Entry::Occupied(e) if e.get().conn_id != conn_id => {
                return Err(AppError::conflict("session_id 已被占用"));
            }
            // 同一连接重发 offer（重新协商）：直接转发
            dashmap::Entry::Occupied(_) => {}
            dashmap::Entry::Vacant(v) => {
                v.insert(Session {
                    conn_id,
                    device_id: device_id.to_owned(),
                });
            }
        }
        if streams.is_empty() {
            streams.push("front".into());
        }
        let sent = st.hub.send_raw(
            device_id,
            ServerToRobot::WebrtcOffer {
                session_id: session_id.to_owned(),
                sdp,
                streams,
                ice_servers: ice_servers(st, user.id),
            },
        );
        if sent.is_err() {
            self.sessions.remove(session_id);
        }
        sent
    }

    pub fn ice(
        &self,
        st: &AppState,
        conn_id: Uuid,
        device_id: &str,
        session_id: &str,
        candidate: Value,
    ) -> AppResult<()> {
        self.owned(conn_id, device_id, session_id)?;
        st.hub.send_raw(
            device_id,
            ServerToRobot::WebrtcIce {
                session_id: session_id.to_owned(),
                candidate,
            },
        )
    }

    pub fn close(
        &self,
        st: &AppState,
        conn_id: Uuid,
        device_id: &str,
        session_id: &str,
    ) -> AppResult<()> {
        self.owned(conn_id, device_id, session_id)?;
        self.sessions.remove(session_id);
        // 机器人已离线时无需再通知
        let _ = st.hub.send_raw(
            device_id,
            ServerToRobot::WebrtcClose {
                session_id: session_id.to_owned(),
            },
        );
        Ok(())
    }

    /// 机器人发来的信令：转给会话归属的前端连接；不属于该设备的会话直接丢弃
    pub fn from_robot(&self, st: &AppState, device_id: &str, msg: RobotToServer) {
        let (session_id, close) = match &msg {
            RobotToServer::WebrtcAnswer { session_id, .. }
            | RobotToServer::WebrtcIce { session_id, .. } => (session_id.clone(), false),
            RobotToServer::WebrtcClose { session_id, .. } => (session_id.clone(), true),
            _ => return,
        };
        let Some(s) = self
            .sessions
            .get(&session_id)
            .map(|s| s.clone())
            .filter(|s| s.device_id == device_id)
        else {
            tracing::debug!(device = device_id, session = %session_id, "忽略未知视频会话的信令");
            return;
        };
        if close {
            self.sessions.remove(&session_id);
        }
        let device_id = device_id.to_owned();
        let conn_id = s.conn_id;
        st.hub.publish(match msg {
            RobotToServer::WebrtcAnswer { sdp, .. } => ServerEvent::WebrtcAnswer {
                conn_id,
                device_id,
                session_id,
                sdp,
            },
            RobotToServer::WebrtcIce { candidate, .. } => ServerEvent::WebrtcIce {
                conn_id,
                device_id,
                session_id,
                candidate,
            },
            RobotToServer::WebrtcClose { reason, .. } => ServerEvent::WebrtcClose {
                conn_id,
                device_id,
                session_id,
                reason,
            },
            _ => return,
        });
    }

    /// 前端连接断开：关闭它的所有会话
    pub fn client_gone(&self, st: &AppState, conn_id: Uuid) {
        let mine: Vec<(String, String)> = self
            .sessions
            .iter()
            .filter(|e| e.conn_id == conn_id)
            .map(|e| (e.key().clone(), e.device_id.clone()))
            .collect();
        for (session_id, device_id) in mine {
            self.sessions.remove(&session_id);
            let _ = st
                .hub
                .send_raw(&device_id, ServerToRobot::WebrtcClose { session_id });
        }
    }

    /// 机器人掉线：通知前端它的会话都结束了
    pub fn robot_gone(&self, st: &AppState, device_id: &str) {
        let gone: Vec<(String, Uuid)> = self
            .sessions
            .iter()
            .filter(|e| e.device_id == device_id)
            .map(|e| (e.key().clone(), e.conn_id))
            .collect();
        for (session_id, conn_id) in gone {
            self.sessions.remove(&session_id);
            st.hub.publish(ServerEvent::WebrtcClose {
                conn_id,
                device_id: device_id.to_owned(),
                session_id,
                reason: Some("设备离线".into()),
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_check() {
        assert!(robot_supports_webrtc(
            &json!({"capabilities": ["move", "webrtc"]})
        ));
        assert!(!robot_supports_webrtc(&json!({"capabilities": ["move"]})));
        assert!(!robot_supports_webrtc(&json!({})));
    }
}
