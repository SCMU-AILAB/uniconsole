//! 前端实时通道：`GET /api/v1/ws?token=<jwt>`
//!
//! - 下行：按订阅过滤的遥测、设备状态、租约、告警、急停事件
//! - 上行：订阅管理、摇杆 move（高频、无回执）、stop
//!
//! 断线保护：连接断开时，对该连接驱动过的设备补发 Stop。

use std::collections::HashSet;

use axum::{
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::Response,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::broadcast::error::RecvError;

use crate::{
    auth::AuthUser,
    error::AppResult,
    protocol::{ClientToServer, Command, ServerEvent},
    services::{
        access,
        control::{self, Actor},
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

fn json(ev: &ServerEvent) -> Message {
    Message::Text(serde_json::to_string(ev).expect("serialize").into())
}

async fn handle(st: AppState, user: AuthUser, visible: Option<HashSet<String>>, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let mut events = st.hub.subscribe();
    let mut subs = Subs::Some(HashSet::new());
    let mut driving: HashSet<String> = HashSet::new();
    let can_see = |id: &str| visible.as_ref().is_none_or(|v| v.contains(id));

    tracing::debug!(user = %user.name, "前端已连接");

    loop {
        tokio::select! {
            frame = stream.next() => {
                let text = match frame {
                    Some(Ok(Message::Text(t))) => t,
                    Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                    Some(Ok(_)) => continue,
                };
                let reply = match serde_json::from_str::<ClientToServer>(text.as_str()) {
                    Err(e) => Some(ServerEvent::Error { message: format!("无法解析消息：{e}") }),
                    Ok(msg) => on_message(&st, &user, msg, &mut subs, &mut driving, &can_see).await,
                };
                if let Some(r) = reply
                    && sink.send(json(&r)).await.is_err() { break; }
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
                let deliver = match ev.device_id() {
                    None => true,
                    Some(id) => can_see(id) && match &subs {
                        Subs::All => true,
                        Subs::Some(set) => set.contains(id),
                    },
                };
                if deliver && sink.send(json(&ev)).await.is_err() {
                    break;
                }
            }
        }
    }

    for id in driving {
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
    tracing::debug!(user = %user.name, "前端已断开");
}

async fn on_message(
    st: &AppState,
    user: &AuthUser,
    msg: ClientToServer,
    subs: &mut Subs,
    driving: &mut HashSet<String>,
    can_see: &impl Fn(&str) -> bool,
) -> Option<ServerEvent> {
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
                Err(e) => Some(ServerEvent::Error {
                    message: e.to_string(),
                }),
            }
        }
        ClientToServer::Stop { device_id } => {
            if !can_see(&device_id) {
                return Some(ServerEvent::Error {
                    message: format!("无权访问设备 {device_id}"),
                });
            }
            driving.remove(&device_id);
            control::execute(st, Actor::User(user), &device_id, Command::Stop, false)
                .await
                .err()
                .map(|e| ServerEvent::Error {
                    message: e.to_string(),
                })
        }
        ClientToServer::Ping { nonce } => Some(ServerEvent::Pong { nonce }),
    }
}
