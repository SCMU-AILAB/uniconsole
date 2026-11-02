//! UniConsole 实时通信协议（JSON over WebSocket）。
//!
//! - 机器人 ⇄ 服务器：`/api/v1/robot/ws`，见 [`RobotToServer`] / [`ServerToRobot`]
//! - 前端   ⇄ 服务器：`/api/v1/ws`，见 [`ClientToServer`] / [`ServerEvent`]
//!
//! 所有消息都是带 `type` 字段的 JSON 对象。机器人端 Python 模型位于
//! `robot/src/uniagent/protocol.py`，两边改动必须同步。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

use uniconsole_domain::{AlertSeverity, AlertState, DeviceStatus, Lease};

pub const PROTOCOL_VERSION: u32 = 1;

// ───────────────────────── 指令 ─────────────────────────

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SpeedLevel {
    Slow,
    Normal,
    Fast,
}

/// 运动模式（Control.dc.html 的姿态按钮）
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum MotionMode {
    Stand,
    Down,
    Balance,
    Walk,
    Stairs,
    Damp,
    Recovery,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Command {
    /// 速度指令，机体坐标系。机器人端 300 ms 未收到新的 move 自动停止。
    Move {
        vx: f32,
        vy: f32,
        wz: f32,
    },
    Stop,
    SetMode {
        mode: MotionMode,
    },
    SetSpeed {
        level: SpeedLevel,
    },
    Estop,
    ReleaseEstop,
    /// 预置动作 / 技能调用，例如 hello、stretch、take_photo
    Action {
        name: String,
        #[serde(default)]
        params: Value,
    },
}

impl Command {
    /// 会让机器人运动的指令：需要控制权且急停时被拒绝
    /// 停止类指令（Stop / Estop / 阻尼）永远允许，任何人可触发。
    pub fn is_motion(&self) -> bool {
        !matches!(
            self,
            Command::Stop
                | Command::Estop
                | Command::ReleaseEstop
                | Command::SetMode {
                    mode: MotionMode::Damp
                }
        )
    }

    /// 按安全策略限幅
    pub fn clamp(&mut self, max_speed: f32, max_yaw_rate: f32) {
        if let Command::Move { vx, vy, wz } = self {
            let clamp = |v: f32, m: f32| if v.is_finite() { v.clamp(-m, m) } else { 0.0 };
            *vx = clamp(*vx, max_speed);
            *vy = clamp(*vy, max_speed);
            *wz = clamp(*wz, max_yaw_rate);
        }
    }
}

// ───────────────────────── 机器人 → 服务器 ─────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct Pose {
    pub x: f32,
    pub y: f32,
    pub yaw: f32,
}

/// 遥测帧，字段对齐 HANDOFF §6 Telemetry。
/// `joint_temps` 顺序：[FL, FR, RL, RR] × [hip, thigh, calf]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Telemetry {
    pub ts: DateTime<Utc>,
    /// 后端拿不到电量时为空（例如 Go2Agent 目前只订阅 sportmodestate）
    #[serde(default)]
    pub battery: Option<f32>,
    #[serde(default)]
    pub vx: f32,
    #[serde(default)]
    pub vy: f32,
    #[serde(default)]
    pub wz: f32,
    #[serde(default)]
    pub roll: f32,
    #[serde(default)]
    pub pitch: f32,
    #[serde(default)]
    pub yaw: f32,
    #[serde(default)]
    pub joint_temps: Vec<[f32; 3]>,
    #[serde(default)]
    pub foot_forces: Vec<f32>,
    #[serde(default)]
    pub voltage: f32,
    #[serde(default)]
    pub current: f32,
    #[serde(default)]
    pub pose: Option<Pose>,
    #[serde(default)]
    pub mode: Option<String>,
    /// 其他扩展字段（定位置信度、雷达状态等）
    #[serde(default)]
    pub extra: Value,
}

impl Telemetry {
    pub fn max_motor_temp(&self) -> Option<f32> {
        self.joint_temps
            .iter()
            .flat_map(|leg| leg.iter().copied())
            .reduce(f32::max)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RobotToServer {
    /// 连接后第一条消息
    Hello {
        protocol: u32,
        model: Option<String>,
        firmware: Option<String>,
        sn: Option<String>,
        ip: Option<String>,
        #[serde(default)]
        capabilities: Vec<String>,
        /// 技能目录 [{name, description, tags}]，存入 devices.meta.skills 供前端展示
        #[serde(default)]
        skills: Vec<Value>,
    },
    Telemetry(Telemetry),
    /// 机器人自身状态变化（任务中 / 充电 / 位置描述）
    State {
        status: Option<DeviceStatus>,
        location: Option<String>,
        task: Option<String>,
    },
    Ack {
        cmd_id: Uuid,
        ok: bool,
        #[serde(default)]
        error: Option<String>,
    },
    /// 机器人侧检测到的事件（跌倒、碰撞、急停按钮…）
    Event {
        level: String,
        code: String,
        message: String,
    },
    Pong {
        nonce: u64,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerToRobot {
    Welcome {
        protocol: u32,
        server_time: DateTime<Utc>,
        /// 全局急停中：机器人必须保持停止
        estop: bool,
        telemetry_hz: u32,
        max_speed_mps: f32,
        max_yaw_rate: f32,
    },
    Command {
        cmd_id: Uuid,
        command: Command,
    },
    Ping {
        nonce: u64,
    },
}

// ───────────────────────── 前端 ⇄ 服务器 ─────────────────────────

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientToServer {
    /// 订阅设备实时数据；`device_ids` 为空表示订阅全部有权限的设备
    Subscribe {
        #[serde(default)]
        device_ids: Vec<String>,
    },
    Unsubscribe {
        device_ids: Vec<String>,
    },
    /// 高频摇杆输入（需持有控制权），不等待回执
    Move {
        device_id: String,
        vx: f32,
        vy: f32,
        wz: f32,
    },
    Stop {
        device_id: String,
    },
    Ping {
        nonce: u64,
    },
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerEvent {
    Telemetry {
        device_id: String,
        latency_ms: Option<u32>,
        #[serde(flatten)]
        data: Telemetry,
    },
    DeviceStatus {
        device_id: String,
        status: DeviceStatus,
        online: bool,
        location: Option<String>,
        task: Option<String>,
    },
    LeaseChanged {
        device_id: String,
        lease: Option<Lease>,
        queue_len: i64,
    },
    LeaseRequested {
        device_id: String,
        request_id: Uuid,
        requester: String,
    },
    CommandAck {
        device_id: String,
        cmd_id: Uuid,
        ok: bool,
        error: Option<String>,
    },
    Estop {
        /// None = 全局急停
        device_id: Option<String>,
        active: bool,
        by: String,
    },
    Alert {
        alert_id: Uuid,
        device_id: Option<String>,
        severity: AlertSeverity,
        title: String,
        state: AlertState,
    },
    RobotEvent {
        device_id: String,
        level: String,
        code: String,
        message: String,
    },
    Pong {
        nonce: u64,
    },
    Error {
        message: String,
    },
}

impl ServerEvent {
    /// 用于按订阅过滤；None 表示所有已认证客户端都应收到
    pub fn device_id(&self) -> Option<&str> {
        match self {
            ServerEvent::Telemetry { device_id, .. }
            | ServerEvent::DeviceStatus { device_id, .. }
            | ServerEvent::LeaseChanged { device_id, .. }
            | ServerEvent::LeaseRequested { device_id, .. }
            | ServerEvent::CommandAck { device_id, .. }
            | ServerEvent::RobotEvent { device_id, .. } => Some(device_id),
            ServerEvent::Estop { device_id, .. } | ServerEvent::Alert { device_id, .. } => {
                device_id.as_deref()
            }
            ServerEvent::Pong { .. } | ServerEvent::Error { .. } => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_wire_format() {
        let msg = ServerToRobot::Command {
            cmd_id: Uuid::nil(),
            command: Command::Move {
                vx: 0.5,
                vy: 0.0,
                wz: -0.1,
            },
        };
        let v = serde_json::to_value(&msg).unwrap();
        assert_eq!(v["type"], "command");
        assert_eq!(v["command"]["kind"], "move");
        assert_eq!(v["command"]["vx"], 0.5);
    }

    #[test]
    fn parse_robot_telemetry() {
        let raw = r#"{"type":"telemetry","ts":"2026-11-02T06:00:00Z","battery":86,
            "joint_temps":[[41,44,46],[40,43,45],[42,47,68],[39,42,44]]}"#;
        match serde_json::from_str::<RobotToServer>(raw).unwrap() {
            RobotToServer::Telemetry(t) => assert_eq!(t.max_motor_temp(), Some(68.0)),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn motion_classification() {
        assert!(
            Command::Move {
                vx: 0.0,
                vy: 0.0,
                wz: 0.0
            }
            .is_motion()
        );
        assert!(!Command::Stop.is_motion());
        assert!(!Command::Estop.is_motion());
        assert!(
            !Command::SetMode {
                mode: MotionMode::Damp
            }
            .is_motion()
        );
        assert!(
            Command::SetMode {
                mode: MotionMode::Stand
            }
            .is_motion()
        );
    }
}
