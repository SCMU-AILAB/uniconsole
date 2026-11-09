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

use uniconsole_domain::{AlertSeverity, AlertState, DeviceEvent, DeviceStatus, Lease};

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

/// 不让机器人运动的技能（播报等）：不需要控制权，急停中也可以执行
pub const NON_MOTION_ACTIONS: &[&str] = &["say"];

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
    /// `drill = true`：急停演练，机器人走一遍急停链路并回执，但不真的停机
    Estop {
        #[serde(default)]
        drill: bool,
    },
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
    /// 停止类指令（Stop / Estop / 阻尼）永远允许，任何人可触发；播报（`say`）不是运动。
    /// 与 robot/src/uniagent/protocol.py 的 `is_motion` 保持一致。
    pub fn is_motion(&self) -> bool {
        match self {
            Command::Action { name, .. } => !NON_MOTION_ACTIONS.contains(&name.as_str()),
            _ => !matches!(
                self,
                Command::Stop
                    | Command::Estop { .. }
                    | Command::ReleaseEstop
                    | Command::SetMode {
                        mode: MotionMode::Damp
                    }
            ),
        }
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
    /// pose 所在的地图（GET /maps 的 id）
    #[serde(default)]
    pub map_id: Option<String>,
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
        /// 传感器描述 {lidar, cameras[], topics[]}，存入 devices.meta.sensors
        #[serde(default)]
        sensors: Option<Value>,
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
    /// WebRTC 信令：机器人对前端 offer 的应答
    WebrtcAnswer {
        session_id: String,
        sdp: String,
    },
    WebrtcIce {
        session_id: String,
        candidate: Value,
    },
    /// 机器人结束（或拒绝）一路视频，`reason` 给人看
    WebrtcClose {
        session_id: String,
        #[serde(default)]
        reason: Option<String>,
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
        /// 与服务器断联后的动作：stop | down | dock
        lost_link_action: String,
        heartbeat_timeout_ms: u64,
    },
    Command {
        cmd_id: Uuid,
        command: Command,
    },
    Ping {
        nonce: u64,
    },
    /// WebRTC 信令（前端 → 机器人转发）。`ice_servers` 与前端拿到的相同（含限时 TURN 凭据）
    WebrtcOffer {
        session_id: String,
        sdp: String,
        streams: Vec<String>,
        ice_servers: Value,
    },
    WebrtcIce {
        session_id: String,
        candidate: Value,
    },
    WebrtcClose {
        session_id: String,
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
    /// 开关某台设备的点云二进制流（默认关闭，数据量较大）
    Pointcloud {
        device_id: String,
        enable: bool,
    },
    Ping {
        nonce: u64,
    },
    /// WebRTC 信令：`session_id` 由前端生成（UUID），一路视频一个
    WebrtcOffer {
        device_id: String,
        session_id: String,
        sdp: String,
        /// front | depth | rear …，缺省 ["front"]
        #[serde(default)]
        streams: Vec<String>,
    },
    WebrtcIce {
        device_id: String,
        session_id: String,
        candidate: Value,
    },
    WebrtcClose {
        device_id: String,
        session_id: String,
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
    /// 设备事件（GET /devices/{id}/events 的增量）
    DeviceEvent {
        device_id: String,
        event: DeviceEvent,
    },
    /// 通用失效通知：前端收到后重新 GET 对应资源。`id` 为空表示整个列表都变了。
    Changed {
        resource: String,
        id: Option<String>,
    },
    /// 只发给某个成员的提示（控制权被收回、被分配告警等）
    Notice {
        member_id: Uuid,
        level: String,
        text: String,
    },
    Pong {
        nonce: u64,
    },
    /// 上行消息处理失败（code 同 REST 错误码，如 estop_active、forbidden）
    Error {
        code: String,
        message: String,
    },
    /// WebRTC 信令（机器人 → 前端），只发给发起该 session 的那条连接（`conn_id` 不序列化）
    WebrtcAnswer {
        #[serde(skip)]
        conn_id: Uuid,
        device_id: String,
        session_id: String,
        sdp: String,
    },
    WebrtcIce {
        #[serde(skip)]
        conn_id: Uuid,
        device_id: String,
        session_id: String,
        candidate: Value,
    },
    WebrtcClose {
        #[serde(skip)]
        conn_id: Uuid,
        device_id: String,
        session_id: String,
        reason: Option<String>,
    },
}

impl ServerEvent {
    pub fn changed(resource: &str, id: Option<impl ToString>) -> Self {
        ServerEvent::Changed {
            resource: resource.to_owned(),
            id: id.map(|i| i.to_string()),
        }
    }

    /// 用于按订阅过滤；None 表示所有已认证客户端都应收到
    /// 只发给某一条前端连接的事件（WebRTC 信令）
    pub fn target_conn(&self) -> Option<Uuid> {
        match self {
            ServerEvent::WebrtcAnswer { conn_id, .. }
            | ServerEvent::WebrtcIce { conn_id, .. }
            | ServerEvent::WebrtcClose { conn_id, .. } => Some(*conn_id),
            _ => None,
        }
    }

    pub fn device_id(&self) -> Option<&str> {
        match self {
            ServerEvent::Telemetry { device_id, .. }
            | ServerEvent::DeviceStatus { device_id, .. }
            | ServerEvent::LeaseChanged { device_id, .. }
            | ServerEvent::LeaseRequested { device_id, .. }
            | ServerEvent::CommandAck { device_id, .. }
            | ServerEvent::RobotEvent { device_id, .. }
            | ServerEvent::DeviceEvent { device_id, .. } => Some(device_id),
            ServerEvent::Estop { device_id, .. } | ServerEvent::Alert { device_id, .. } => {
                device_id.as_deref()
            }
            ServerEvent::WebrtcAnswer { device_id, .. }
            | ServerEvent::WebrtcIce { device_id, .. }
            | ServerEvent::WebrtcClose { device_id, .. } => Some(device_id),
            ServerEvent::Pong { .. }
            | ServerEvent::Error { .. }
            | ServerEvent::Changed { .. }
            | ServerEvent::Notice { .. } => None,
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
        assert!(
            !Command::Action {
                name: "say".into(),
                params: Value::Null
            }
            .is_motion()
        );
        assert!(
            Command::Action {
                name: "hello".into(),
                params: Value::Null
            }
            .is_motion()
        );
        assert!(!Command::Estop { drill: false }.is_motion());
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

    #[test]
    fn webrtc_wire_format() {
        let raw = r#"{"type":"webrtc_offer","device_id":"go2-01","session_id":"s1","sdp":"v=0"}"#;
        match serde_json::from_str::<ClientToServer>(raw).unwrap() {
            ClientToServer::WebrtcOffer { streams, .. } => assert!(streams.is_empty()),
            other => panic!("unexpected {other:?}"),
        }
        let raw = r#"{"type":"webrtc_close","session_id":"s1"}"#;
        assert!(matches!(
            serde_json::from_str::<RobotToServer>(raw).unwrap(),
            RobotToServer::WebrtcClose { reason: None, .. }
        ));
        let ev = ServerEvent::WebrtcAnswer {
            conn_id: Uuid::nil(),
            device_id: "go2-01".into(),
            session_id: "s1".into(),
            sdp: "v=0".into(),
        };
        let v = serde_json::to_value(&ev).unwrap();
        assert_eq!(v["type"], "webrtc_answer");
        assert!(v.get("conn_id").is_none());
        assert_eq!(ev.target_conn(), Some(Uuid::nil()));
    }
}
