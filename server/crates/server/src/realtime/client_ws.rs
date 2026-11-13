//! 前端实时通道：`GET /api/v1/ws?token=<jwt>`
//!
//! - 下行：按订阅过滤的遥测、设备状态、租约、告警、急停事件
//! - 上行：订阅管理、摇杆 move（高频、无回执）、stop
//!
//! 断线保护：
//! - 连接断开时，对该连接驱动过的设备立即补发 Stop；
//! - 该成员所有连接都断开后，按策略 `disconnect_stop_secs` 停止其控制的全部设备，
//!   `disconnect_release_secs` 后仍未重连则释放其控制权。
//!
//! 点云：`{"type":"pointcloud","device_id","enable":true}` 开启后，服务端以二进制帧推送
//! `[device_id 长度 u8][device_id UTF-8][机器人原始帧：ts i64 LE + N × (f32 x, f32 y) LE]`。

use std::{collections::HashSet, time::Duration};

use axum::{
    body::Bytes,
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::Response,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::{broadcast::error::RecvError, mpsc};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::AppResult,
    protocol::{ClientToServer, Command, ServerEvent},
    realtime::webrtc::Offer,
    services::{
        access, audit,
        control::{self, Actor},
        events,
    },
    state::AppState,
};

pub async fn client_ws(
    State(st): State<AppState>,
    user: AuthUser,
    ws: WebSocketUpgrade,
) -> AppResult<Response> {
    let visible = access::visible_devices(&st.db, &user).await?;
    Ok(ws.on_upgrade(move |socket| handle(st, user, visible.map(HashSet::from_iter), socket)))
}

enum Subs {
    All,
    Some(HashSet<String>),
}

/// 一条前端连接的状态
struct Conn {
    id: Uuid,
    subs: Subs,
    /// 本连接驱动过的设备（断开时补发停止）
    driving: HashSet<String>,
    /// 开启了点云的设备
    clouds: HashSet<String>,
}

fn json(ev: &ServerEvent) -> Message {
    let text = match ev {
        ServerEvent::Forward { payload, .. } => payload.to_string(),
        ev => serde_json::to_string(ev).expect("serialize"),
    };
    Message::Text(text.into())
}

fn error(e: &crate::error::AppError) -> ServerEvent {
    ServerEvent::Error {
        code: e.code().to_owned(),
        message: e.to_string(),
    }
}

fn cloud_frame(device_id: &str, frame: &Bytes) -> Message {
    let id = device_id.as_bytes();
    let mut out = Vec::with_capacity(1 + id.len() + frame.len());
    out.push(id.len().min(255) as u8);
    out.extend_from_slice(&id[..id.len().min(255)]);
    out.extend_from_slice(frame);
    Message::Binary(out.into())
}

async fn handle(st: AppState, user: AuthUser, visible: Option<HashSet<String>>, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    // 写出和接收分离：慢速公网点云不能阻塞上行 Stop / 急停。
    let (tx, mut replies) = mpsc::channel::<Message>(64);
    let (cloud_tx, mut cloud_out) = mpsc::channel::<Message>(1);
    let mut writer = tokio::spawn(async move {
        loop {
            let frame = tokio::select! {
                biased;
                reply = replies.recv() => reply,
                cloud = cloud_out.recv() => cloud,
            };
            let Some(frame) = frame else { break };
            if !matches!(
                tokio::time::timeout(Duration::from_secs(2), sink.send(frame)).await,
                Ok(Ok(()))
            ) {
                break;
            }
        }
    });
    let mut events = st.hub.subscribe();
    let mut clouds_rx = st.hub.subscribe_pointcloud();
    let mut conn = Conn {
        id: Uuid::new_v4(),
        subs: Subs::Some(HashSet::new()),
        driving: HashSet::new(),
        clouds: HashSet::new(),
    };
    let can_see = |id: &str| visible.as_ref().is_none_or(|v| v.contains(id));

    tracing::debug!(user = %user.name, "前端已连接");
    st.hub.user_connected(user.id);
    st.hub
        .publish(ServerEvent::changed("members", Some(user.id)));

    loop {
        tokio::select! {
            _ = &mut writer => break,
            frame = stream.next() => {
                let text = match frame {
                    Some(Ok(Message::Text(t))) => t,
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(_)) => continue,
                };
                let reply = match serde_json::from_str::<ClientToServer>(text.as_str()) {
                    Err(e) => Some(ServerEvent::Error { code: "bad_request".into(), message: format!("无法解析消息：{e}") }),
                    Ok(msg) => on_message(&st, &user, msg, &mut conn, &can_see).await,
                };
                if let Some(r) = reply
                    && tx.try_send(json(&r)).is_err() { break; }
            }
            ev = events.recv() => {
                let ev = match ev {
                    Ok(ev) => ev,
                    Err(RecvError::Lagged(n)) => {
                        tracing::warn!(user = %user.name, skipped = n, "前端消费过慢，丢弃事件");
                        continue;
                    }
                    Err(RecvError::Closed) => break,
                };
                let deliver = match (&*ev, ev.device_id()) {
                    (ServerEvent::Notice { member_id, .. } | ServerEvent::Forward { member_id, .. }, _) => {
                        *member_id == user.id
                    }
                    (e, _) if e.target_conn().is_some() => e.target_conn() == Some(conn.id),
                    (_, None) => true,
                    (_, Some(id)) => can_see(id) && match &conn.subs {
                        Subs::All => true,
                        Subs::Some(set) => set.contains(id),
                    },
                };
                if deliver && tx.try_send(json(&ev)).is_err() {
                    break;
                }
            }
            frame = clouds_rx.recv(), if !conn.clouds.is_empty() => {
                match frame {
                    Ok(f) if conn.clouds.contains(&f.0) => {
                        // 点云只保留一个待发帧；队列满即丢弃，避免累积过期数据。
                        let _ = cloud_tx.try_send(cloud_frame(&f.0, &f.1));
                    }
                    Ok(_) | Err(RecvError::Lagged(_)) => {}
                    Err(RecvError::Closed) => break,
                }
            }
        }
    }

    writer.abort();

    st.webrtc.client_gone(&st, conn.id);
    for id in conn.driving {
        if let Err(e) = control::execute(
            &st,
            Actor::System("前端断线保护"),
            &id,
            Command::Stop,
            false,
        )
        .await
        {
            tracing::debug!(device = %id, error = %e, "断线保护停止失败");
        }
    }
    if st.hub.user_disconnected(user.id) {
        let _ = sqlx::query("UPDATE members SET last_seen_at = now() WHERE id = $1")
            .bind(user.id)
            .execute(&st.db)
            .await;
        st.hub
            .publish(ServerEvent::changed("members", Some(user.id)));
        if !st.leases.held_by(user.id).is_empty() {
            tokio::spawn(disconnect_guard(st.clone(), user.clone()));
        }
    }
    tracing::debug!(user = %user.name, "前端已断开");
}

/// 操控者所有连接都断开后的保护：先停车，再释放控制权（重连则取消）
async fn disconnect_guard(st: AppState, user: AuthUser) {
    let p = st.safety.policies();
    let stop_after = Duration::from_secs(p.disconnect_stop_secs.max(0) as u64);
    let release_after = Duration::from_secs(p.disconnect_release_secs.max(0) as u64);

    tokio::time::sleep(stop_after).await;
    if st.hub.is_user_online(user.id) {
        return;
    }
    for lease in st.leases.held_by(user.id) {
        let _ = control::execute(
            &st,
            Actor::System("操控者断线"),
            &lease.device_id,
            Command::Stop,
            false,
        )
        .await;
    }

    tokio::time::sleep(release_after.saturating_sub(stop_after)).await;
    if st.hub.is_user_online(user.id) {
        return;
    }
    for lease in st.leases.held_by(user.id) {
        if st
            .leases
            .release(&lease.device_id, Some(user.id))
            .await
            .is_ok()
        {
            let label = audit::device_label(&st, &lease.device_id).await;
            events::record(
                &st,
                &lease.device_id,
                format!(
                    "{} 断线超过 {} 秒，自动释放控制权",
                    user.name,
                    release_after.as_secs()
                ),
                "warning",
            )
            .await;
            audit::record_system(
                &st,
                audit::Kind::Control,
                format!(
                    "{} 断线超过 {} 秒，自动释放 {label} 的控制权",
                    user.name,
                    release_after.as_secs()
                ),
                &label,
                serde_json::json!({ "holder": user.id }),
            )
            .await;
        }
    }
}

async fn on_message(
    st: &AppState,
    user: &AuthUser,
    msg: ClientToServer,
    conn: &mut Conn,
    can_see: &impl Fn(&str) -> bool,
) -> Option<ServerEvent> {
    let Conn {
        id: conn_id,
        subs,
        driving,
        clouds,
    } = conn;
    let conn_id = *conn_id;
    match msg {
        ClientToServer::Subscribe { device_ids } => {
            if device_ids.is_empty() {
                *subs = Subs::All;
            } else {
                let set = match subs {
                    Subs::Some(set) => set,
                    Subs::All => return None,
                };
                set.extend(device_ids.into_iter().filter(|id| can_see(id)));
            }
            None
        }
        ClientToServer::Unsubscribe { device_ids } => {
            if let Subs::Some(set) = subs {
                for id in &device_ids {
                    set.remove(id);
                }
            } else {
                // 从「全部」退订部分设备：转为显式列表
                let all: HashSet<String> = st
                    .hub
                    .online_ids()
                    .into_iter()
                    .filter(|id| !device_ids.contains(id))
                    .collect();
                *subs = Subs::Some(all);
            }
            None
        }
        ClientToServer::Move {
            device_id,
            vx,
            vy,
            wz,
        } => {
            if !can_see(&device_id) {
                return Some(ServerEvent::Error {
                    code: "forbidden".into(),
                    message: format!("无权访问设备 {device_id}"),
                });
            }
            match control::execute(
                st,
                Actor::User(user),
                &device_id,
                Command::Move { vx, vy, wz },
                false,
            )
            .await
            {
                Ok(_) => {
                    driving.insert(device_id);
                    None
                }
                Err(e) => Some(error(&e)),
            }
        }
        ClientToServer::Stop { device_id } => {
            if !can_see(&device_id) {
                return Some(ServerEvent::Error {
                    code: "forbidden".into(),
                    message: format!("无权访问设备 {device_id}"),
                });
            }
            driving.remove(&device_id);
            control::execute(st, Actor::User(user), &device_id, Command::Stop, false)
                .await
                .err()
                .map(|e| error(&e))
        }
        ClientToServer::Pointcloud { device_id, enable } => {
            if !can_see(&device_id) {
                return Some(ServerEvent::Error {
                    code: "forbidden".into(),
                    message: format!("无权访问设备 {device_id}"),
                });
            }
            if enable {
                clouds.insert(device_id);
            } else {
                clouds.remove(&device_id);
            }
            None
        }
        ClientToServer::Ping { nonce } => Some(ServerEvent::Pong { nonce }),
        ClientToServer::WebrtcOffer {
            device_id,
            session_id,
            sdp,
            streams,
        } => {
            if !can_see(&device_id) {
                return Some(ServerEvent::Error {
                    code: "forbidden".into(),
                    message: format!("无权访问设备 {device_id}"),
                });
            }
            st.webrtc
                .offer(
                    st,
                    user,
                    conn_id,
                    Offer {
                        device_id,
                        session_id,
                        sdp,
                        streams,
                    },
                )
                .await
                .err()
                .map(|e| error(&e))
        }
        ClientToServer::WebrtcIce {
            device_id,
            session_id,
            candidate,
        } => st
            .webrtc
            .ice(st, conn_id, &device_id, &session_id, candidate)
            .err()
            .map(|e| error(&e)),
        ClientToServer::WebrtcClose {
            device_id,
            session_id,
        } => st
            .webrtc
            .close(st, conn_id, &device_id, &session_id)
            .err()
            .map(|e| error(&e)),
    }
}
