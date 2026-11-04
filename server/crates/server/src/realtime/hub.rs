//! 进程内实时中枢：机器人连接表、最新遥测、指令回执、事件广播。
//!
//! 注意：这是单实例实现。多实例水平扩展时需要把「设备 → 所在实例」路由
//! 与事件广播迁移到 Redis / NATS / Postgres LISTEN-NOTIFY。

use std::{sync::Arc, time::Duration};

use axum::body::Bytes;
use chrono::{DateTime, Utc};
use dashmap::DashMap;
use tokio::sync::{broadcast, mpsc, oneshot};
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    protocol::{Command, ServerEvent, ServerToRobot, Telemetry},
};

/// 每个机器人连接的出站队列长度；满了说明链路堵塞，新指令直接报错而不是无限堆积
const ROBOT_QUEUE: usize = 256;
const EVENT_BUS: usize = 8192;

#[derive(Clone)]
pub struct RobotConn {
    pub conn_id: Uuid,
    pub tx: mpsc::Sender<ServerToRobot>,
}

#[derive(Debug, Clone, Default)]
pub struct LiveInfo {
    pub telemetry: Option<Telemetry>,
    pub latency_ms: Option<u32>,
    pub connected_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone)]
pub struct Ack {
    pub ok: bool,
    pub error: Option<String>,
}

pub struct Hub {
    robots: DashMap<String, RobotConn>,
    live: DashMap<String, LiveInfo>,
    pending: DashMap<Uuid, oneshot::Sender<Ack>>,
    estopped: DashMap<String, ()>,
    /// 成员 id → 在线前端连接数
    users: DashMap<Uuid, usize>,
    events: broadcast::Sender<Arc<ServerEvent>>,
    /// 点云二进制帧：(设备 id, 机器人原始帧)
    pointcloud: broadcast::Sender<Arc<(String, Bytes)>>,
}

impl Default for Hub {
    fn default() -> Self {
        Self::new()
    }
}

impl Hub {
    pub fn new() -> Self {
        let (events, _) = broadcast::channel(EVENT_BUS);
        let (pointcloud, _) = broadcast::channel(256);
        Self {
            robots: DashMap::new(),
            live: DashMap::new(),
            pending: DashMap::new(),
            estopped: DashMap::new(),
            users: DashMap::new(),
            events,
            pointcloud,
        }
    }

    // ───────── 事件总线 ─────────

    pub fn subscribe(&self) -> broadcast::Receiver<Arc<ServerEvent>> {
        self.events.subscribe()
    }

    pub fn publish(&self, ev: ServerEvent) {
        // 没有订阅者时 send 返回 Err，可忽略
        let _ = self.events.send(Arc::new(ev));
    }

    pub fn subscribe_pointcloud(&self) -> broadcast::Receiver<Arc<(String, Bytes)>> {
        self.pointcloud.subscribe()
    }

    pub fn publish_pointcloud(&self, device_id: &str, frame: Bytes) {
        let _ = self
            .pointcloud
            .send(Arc::new((device_id.to_owned(), frame)));
    }

    // ───────── 机器人连接 ─────────

    /// 注册连接；同一设备重复连接时旧连接被替换（旧的写任务会因 tx 被丢弃而退出）
    pub fn register_robot(&self, device_id: &str) -> (Uuid, mpsc::Receiver<ServerToRobot>) {
        let (tx, rx) = mpsc::channel(ROBOT_QUEUE);
        let conn_id = Uuid::new_v4();
        let now = Utc::now();
        self.robots
            .insert(device_id.to_owned(), RobotConn { conn_id, tx });
        self.live
            .entry(device_id.to_owned())
            .or_default()
            .connected_at = Some(now);
        (conn_id, rx)
    }

    /// 只有当前连接仍是 `conn_id` 时才移除，避免误删重连后的新连接
    pub fn unregister_robot(&self, device_id: &str, conn_id: Uuid) -> bool {
        let removed = self
            .robots
            .remove_if(device_id, |_, c| c.conn_id == conn_id)
            .is_some();
        if removed && let Some(mut l) = self.live.get_mut(device_id) {
            l.latency_ms = None;
            l.connected_at = None;
        }
        removed
    }

    pub fn is_online(&self, device_id: &str) -> bool {
        self.robots.contains_key(device_id)
    }

    pub fn online_ids(&self) -> Vec<String> {
        self.robots.iter().map(|e| e.key().clone()).collect()
    }

    pub fn live(&self, device_id: &str) -> LiveInfo {
        self.live
            .get(device_id)
            .map(|l| l.clone())
            .unwrap_or_default()
    }

    pub fn set_telemetry(&self, device_id: &str, t: Telemetry) {
        self.live.entry(device_id.to_owned()).or_default().telemetry = Some(t);
    }

    pub fn set_latency(&self, device_id: &str, ms: u32) {
        self.live
            .entry(device_id.to_owned())
            .or_default()
            .latency_ms = Some(ms);
    }

    // ───────── 前端在线状态 ─────────

    pub fn user_connected(&self, member_id: Uuid) {
        *self.users.entry(member_id).or_default() += 1;
    }

    /// 返回 true 表示该成员的最后一个连接已断开
    pub fn user_disconnected(&self, member_id: Uuid) -> bool {
        let mut gone = false;
        if let Some(mut n) = self.users.get_mut(&member_id) {
            *n = n.saturating_sub(1);
            gone = *n == 0;
        }
        if gone {
            self.users.remove_if(&member_id, |_, n| *n == 0);
        }
        gone
    }

    pub fn is_user_online(&self, member_id: Uuid) -> bool {
        self.users.get(&member_id).is_some_and(|n| *n > 0)
    }

    // ───────── 急停标记（单机） ─────────

    pub fn set_device_estop(&self, device_id: &str, on: bool) {
        if on {
            self.estopped.insert(device_id.to_owned(), ());
        } else {
            self.estopped.remove(device_id);
        }
    }

    pub fn is_device_estopped(&self, device_id: &str) -> bool {
        self.estopped.contains_key(device_id)
    }

    // ───────── 指令下发 ─────────

    pub fn send_raw(&self, device_id: &str, msg: ServerToRobot) -> AppResult<()> {
        let conn = self
            .robots
            .get(device_id)
            .map(|c| c.clone())
            .ok_or_else(|| AppError::RobotOffline(device_id.to_owned()))?;
        conn.tx.try_send(msg).map_err(|e| match e {
            mpsc::error::TrySendError::Full(_) => {
                AppError::Internal(anyhow::anyhow!("设备 {device_id} 下行队列已满"))
            }
            mpsc::error::TrySendError::Closed(_) => AppError::RobotOffline(device_id.to_owned()),
        })
    }

    /// 下发指令。`wait = Some(t)` 时等待机器人回执，否则立即返回。
    pub async fn dispatch(
        &self,
        device_id: &str,
        command: Command,
        wait: Option<Duration>,
    ) -> AppResult<(Uuid, Option<Ack>)> {
        let cmd_id = Uuid::new_v4();
        let rx = wait.map(|_| {
            let (tx, rx) = oneshot::channel();
            self.pending.insert(cmd_id, tx);
            rx
        });

        if let Err(e) = self.send_raw(device_id, ServerToRobot::Command { cmd_id, command }) {
            self.pending.remove(&cmd_id);
            return Err(e);
        }

        let (Some(rx), Some(timeout)) = (rx, wait) else {
            return Ok((cmd_id, None));
        };
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(ack)) => Ok((cmd_id, Some(ack))),
            Ok(Err(_)) => Err(AppError::RobotOffline(device_id.to_owned())),
            Err(_) => {
                self.pending.remove(&cmd_id);
                Err(AppError::Timeout)
            }
        }
    }

    /// 机器人回执到达
    pub fn resolve_ack(&self, cmd_id: Uuid, ack: Ack) {
        if let Some((_, tx)) = self.pending.remove(&cmd_id) {
            let _ = tx.send(ack);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn dispatch_and_ack() {
        let hub = Arc::new(Hub::new());
        let (_conn, mut rx) = hub.register_robot("go2-01");

        let h = hub.clone();
        let robot = tokio::spawn(async move {
            if let Some(ServerToRobot::Command { cmd_id, .. }) = rx.recv().await {
                h.resolve_ack(
                    cmd_id,
                    Ack {
                        ok: true,
                        error: None,
                    },
                );
            }
        });

        let (_, ack) = hub
            .dispatch("go2-01", Command::Stop, Some(Duration::from_millis(500)))
            .await
            .unwrap();
        assert!(ack.unwrap().ok);
        robot.await.unwrap();
    }

    #[tokio::test]
    async fn offline_and_timeout() {
        let hub = Hub::new();
        assert!(matches!(
            hub.dispatch("nope", Command::Stop, None).await,
            Err(AppError::RobotOffline(_))
        ));

        let (_conn, _rx) = hub.register_robot("go2-02");
        assert!(matches!(
            hub.dispatch("go2-02", Command::Stop, Some(Duration::from_millis(20)))
                .await,
            Err(AppError::Timeout)
        ));
    }

    #[test]
    fn reconnect_keeps_new_connection() {
        let hub = Hub::new();
        let (old, _rx1) = hub.register_robot("go2-01");
        let (_new, _rx2) = hub.register_robot("go2-01");
        assert!(!hub.unregister_robot("go2-01", old));
        assert!(hub.is_online("go2-01"));
    }
}
