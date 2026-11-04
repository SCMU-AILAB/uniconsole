//! 机器人接入：`GET /api/v1/robot/ws`
//!
//! 认证头：`Authorization: Bearer <device_token>`、`X-Device-Id: <device_id>`。
//! 机器人主动外连（适配 NAT / 4G 场景），服务器经同一条连接下发指令。

use std::time::{Duration, Instant};

use axum::{
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, header},
    response::Response,
};
use chrono::Utc;
use futures::{SinkExt, StreamExt};

use super::{Ack, TelemetrySample};
use crate::{
    auth::hash_device_token,
    error::{AppError, AppResult},
    models::DeviceStatus,
    protocol::{PROTOCOL_VERSION, RobotToServer, ServerEvent, ServerToRobot},
    services::{audit, events},
    state::AppState,
};

pub async fn robot_ws(
    State(st): State<AppState>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> AppResult<Response> {
    let device_id = headers
        .get("x-device-id")
        .and_then(|v| v.to_str().ok())
        .ok_or(AppError::Unauthorized)?
        .to_owned();
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .ok_or(AppError::Unauthorized)?;

    let stored: Option<(String,)> = sqlx::query_as("SELECT token_hash FROM devices WHERE id = $1")
        .bind(&device_id)
        .fetch_optional(&st.db)
        .await?;
    match stored {
        Some((hash,)) if hash == hash_device_token(token) => {}
        _ => {
            tracing::warn!(device = %device_id, "机器人认证失败");
            return Err(AppError::Unauthorized);
        }
    }

    Ok(ws.on_upgrade(move |socket| handle(st, device_id, socket)))
}

fn encode(msg: &ServerToRobot) -> Message {
    Message::Text(serde_json::to_string(msg).expect("serialize").into())
}

async fn handle(st: AppState, device_id: String, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();
    let (conn_id, mut rx) = st.hub.register_robot(&device_id);
    let policies = st.safety.policies();
    let global_estop = st.safety.is_global_estop();
    tracing::info!(device = %device_id, %conn_id, "机器人上线");

    let welcome = ServerToRobot::Welcome {
        protocol: PROTOCOL_VERSION,
        server_time: Utc::now(),
        estop: global_estop || st.hub.is_device_estopped(&device_id),
        telemetry_hz: st.cfg.telemetry_hz,
        max_speed_mps: policies.speed_limit,
        max_yaw_rate: policies.max_yaw_rate,
        lost_link_action: policies.lost_link_action.clone(),
        heartbeat_timeout_ms: policies.heartbeat_timeout_ms,
    };
    if sink.send(encode(&welcome)).await.is_err() {
        st.hub.unregister_robot(&device_id, conn_id);
        return;
    }

    set_online(&st, &device_id, true).await;

    // 写任务：下行指令 + 每秒一次应用层 ping（用于测量延迟）
    let mut writer = tokio::spawn(async move {
        let mut ping = tokio::time::interval(Duration::from_secs(1));
        loop {
            let msg = tokio::select! {
                m = rx.recv() => match m { Some(m) => m, None => break }, // 被新连接替换
                _ = ping.tick() => ServerToRobot::Ping { nonce: Utc::now().timestamp_millis() as u64 },
            };
            if sink.send(encode(&msg)).await.is_err() {
                break;
            }
        }
        let _ = sink.close().await;
    });

    let timeout = Duration::from_millis(policies.heartbeat_timeout_ms.max(st.cfg.robot_timeout_ms));
    let persist_every = Duration::from_millis(st.cfg.telemetry_persist_ms);
    let mut last_persist = Instant::now() - persist_every;

    loop {
        let frame = tokio::select! {
            f = tokio::time::timeout(timeout, stream.next()) => f,
            _ = &mut writer => break,
        };
        let text = match frame {
            Err(_) => {
                tracing::warn!(device = %device_id, "机器人心跳超时");
                break;
            }
            Ok(None) | Ok(Some(Err(_))) | Ok(Some(Ok(Message::Close(_)))) => break,
            Ok(Some(Ok(Message::Text(t)))) => t,
            Ok(Some(Ok(Message::Binary(b)))) => {
                // 点云：[ts i64 LE][N × (f32 x, f32 y) LE]，机器人坐标系，+y 朝前、+x 朝右
                if b.len() >= 8 && (b.len() - 8) % 8 == 0 && b.len() <= 512 * 1024 {
                    st.hub.publish_pointcloud(&device_id, b);
                }
                continue;
            }
            Ok(Some(Ok(_))) => continue, // 协议层 ping / pong
        };
        let msg = match serde_json::from_str::<RobotToServer>(text.as_str()) {
            Ok(m) => m,
            Err(e) => {
                tracing::debug!(device = %device_id, error = %e, "无法解析机器人消息");
                continue;
            }
        };
        on_message(&st, &device_id, msg, &mut last_persist, persist_every).await;
    }

    writer.abort();
    if st.hub.unregister_robot(&device_id, conn_id) {
        tracing::info!(device = %device_id, "机器人离线");
        set_online(&st, &device_id, false).await;
    }
}

async fn on_message(
    st: &AppState,
    device_id: &str,
    msg: RobotToServer,
    last_persist: &mut Instant,
    persist_every: Duration,
) {
    match msg {
        RobotToServer::Hello {
            protocol,
            model,
            firmware,
            sn,
            ip,
            capabilities,
            skills,
            sensors,
        } => {
            if protocol != PROTOCOL_VERSION {
                tracing::warn!(device = %device_id, protocol, "机器人协议版本不一致");
            }
            tracing::info!(device = %device_id, ?model, ?firmware, ?capabilities, "hello");
            let res = sqlx::query(
                "UPDATE devices SET firmware = COALESCE($2, firmware), sn = COALESCE($3, sn),
                 ip = COALESCE($4, ip),
                 meta = meta || jsonb_build_object('capabilities', $5::jsonb, 'skills', $6::jsonb)
                        || CASE WHEN $7::jsonb IS NULL THEN '{}'::jsonb
                                ELSE jsonb_build_object('sensors', $7::jsonb) END,
                 updated_at = now() WHERE id = $1",
            )
            .bind(device_id)
            .bind(firmware)
            .bind(sn)
            .bind(ip)
            .bind(serde_json::json!(capabilities))
            .bind(serde_json::json!(skills))
            .bind(sensors)
            .execute(&st.db)
            .await;
            if let Err(e) = res {
                tracing::warn!(error = %e, "更新设备信息失败");
            }
        }
        RobotToServer::Telemetry(t) => {
            let latency = st.hub.live(device_id).latency_ms;
            st.hub.set_telemetry(device_id, t.clone());
            st.alerts.evaluate(st, device_id, &t, latency).await;
            if last_persist.elapsed() >= persist_every {
                *last_persist = Instant::now();
                let _ = st.telemetry_tx.try_send(TelemetrySample {
                    device_id: device_id.to_owned(),
                    latency_ms: latency,
                    data: t.clone(),
                });
            }
            st.hub.publish(ServerEvent::Telemetry {
                device_id: device_id.to_owned(),
                latency_ms: latency,
                data: t,
            });
        }
        RobotToServer::State {
            status,
            location,
            task,
        } => {
            let res = sqlx::query(
                "UPDATE devices SET status = COALESCE($2, status), location = COALESCE($3, location),
                 current_task = COALESCE($4, current_task), last_seen_at = now(), updated_at = now()
                 WHERE id = $1 RETURNING status",
            )
            .bind(device_id)
            .bind(status)
            .bind(&location)
            .bind(&task)
            .fetch_one(&st.db)
            .await;
            match res {
                Ok(row) => {
                    use sqlx::Row;
                    let status: DeviceStatus = row.get(0);
                    st.hub.publish(ServerEvent::DeviceStatus {
                        device_id: device_id.to_owned(),
                        status,
                        online: true,
                        location,
                        task,
                    });
                }
                Err(e) => tracing::warn!(error = %e, "更新设备状态失败"),
            }
        }
        RobotToServer::Ack { cmd_id, ok, error } => {
            st.hub.resolve_ack(
                cmd_id,
                Ack {
                    ok,
                    error: error.clone(),
                },
            );
            st.hub.publish(ServerEvent::CommandAck {
                device_id: device_id.to_owned(),
                cmd_id,
                ok,
                error,
            });
        }
        RobotToServer::Event {
            level,
            code,
            message,
        } => {
            if let Err(e) = st
                .alerts
                .raise_robot_event(st, device_id, &level, &code, &message)
                .await
            {
                tracing::error!(error = %e, "处理机器人事件失败");
            }
            let tone = match level.as_str() {
                "critical" | "error" => "critical",
                "warning" | "warn" => "warning",
                _ => "neutral",
            };
            events::record(st, device_id, message.clone(), tone).await;
            // 机器人本地急停按钮 / 遥控器急停：同步到服务端状态
            if code == "estop" {
                st.hub.set_device_estop(device_id, true);
                st.hub.publish(ServerEvent::Estop {
                    device_id: Some(device_id.to_owned()),
                    active: true,
                    by: "设备".into(),
                });
            }
            st.hub.publish(ServerEvent::RobotEvent {
                device_id: device_id.to_owned(),
                level,
                code,
                message,
            });
        }
        RobotToServer::Pong { nonce } => {
            let rtt = (Utc::now().timestamp_millis() as u64).saturating_sub(nonce);
            st.hub
                .set_latency(device_id, rtt.min(u32::MAX as u64) as u32);
        }
    }
}

async fn set_online(st: &AppState, device_id: &str, online: bool) {
    let sql = if online {
        "UPDATE devices SET status = CASE WHEN status = 'offline' THEN 'online'::device_status ELSE status END,
         last_seen_at = now() WHERE id = $1 RETURNING status, location, current_task"
    } else {
        "UPDATE devices SET status = 'offline', last_seen_at = now() WHERE id = $1
         RETURNING status, location, current_task"
    };
    let row: Result<(DeviceStatus, Option<String>, Option<String>), _> =
        sqlx::query_as(sql).bind(device_id).fetch_one(&st.db).await;
    match row {
        Ok((status, location, task)) => st.hub.publish(ServerEvent::DeviceStatus {
            device_id: device_id.to_owned(),
            status,
            online,
            location,
            task,
        }),
        Err(e) => tracing::warn!(error = %e, "更新在线状态失败"),
    }
    events::record(
        st,
        device_id,
        if online {
            "设备上线"
        } else {
            "设备离线"
        },
        if online { "success" } else { "neutral" },
    )
    .await;
    // 断线后服务端已无法下发；停止由机器人端看门狗负责
    if !online {
        audit::record_system(
            st,
            audit::Kind::System,
            format!("{} 断开连接", audit::device_label(st, device_id).await),
            device_id,
            serde_json::json!({}),
        )
        .await;
    }
}
