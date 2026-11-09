"""机器人 ⇄ 服务器通信协议（JSON over WebSocket）。

与服务端 `server/crates/protocol/src/lib.rs` 一一对应，两边改动必须同步。
"""

from datetime import UTC, datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, Field, TypeAdapter

PROTOCOL_VERSION = 1

MotionMode = Literal["stand", "down", "balance", "walk", "stairs", "damp", "recovery"]
SpeedLevel = Literal["slow", "normal", "fast"]
DeviceStatus = Literal["online", "busy", "alert", "charging", "offline"]


# ───────────────────────── 指令 ─────────────────────────


class MoveCmd(BaseModel):
    kind: Literal["move"] = "move"
    vx: float
    vy: float
    wz: float


class StopCmd(BaseModel):
    kind: Literal["stop"] = "stop"


class SetModeCmd(BaseModel):
    kind: Literal["set_mode"] = "set_mode"
    mode: MotionMode


class SetSpeedCmd(BaseModel):
    kind: Literal["set_speed"] = "set_speed"
    level: SpeedLevel


class EstopCmd(BaseModel):
    kind: Literal["estop"] = "estop"
    # 急停演练：走一遍急停链路并回执，但不驱动硬件
    drill: bool = False


class ReleaseEstopCmd(BaseModel):
    kind: Literal["release_estop"] = "release_estop"


class ActionCmd(BaseModel):
    kind: Literal["action"] = "action"
    name: str
    params: Any = None


Command = Annotated[
    MoveCmd | StopCmd | SetModeCmd | SetSpeedCmd | EstopCmd | ReleaseEstopCmd | ActionCmd,
    Field(discriminator="kind"),
]
CommandAdapter: TypeAdapter = TypeAdapter(Command)


# 不让机器人运动的技能（播报等）：不需要控制权，急停中也可以执行。与服务端 Command::is_motion 保持一致
NON_MOTION_ACTIONS = frozenset({"say"})


def is_motion(cmd: BaseModel) -> bool:
    """停止类指令（stop / estop / release_estop / 阻尼）和播报以外都是运动指令。"""
    if isinstance(cmd, (StopCmd, EstopCmd, ReleaseEstopCmd)):
        return False
    if isinstance(cmd, ActionCmd) and cmd.name in NON_MOTION_ACTIONS:
        return False
    return not (isinstance(cmd, SetModeCmd) and cmd.mode == "damp")


# ───────────────────────── 机器人 → 服务器 ─────────────────────────


def utcnow() -> datetime:
    return datetime.now(UTC)


class Pose(BaseModel):
    x: float = 0.0
    y: float = 0.0
    yaw: float = 0.0


class Telemetry(BaseModel):
    """遥测帧。joint_temps 顺序：[FL, FR, RL, RR] × [hip, thigh, calf]。"""

    ts: datetime = Field(default_factory=utcnow)
    battery: float | None = None  # 后端拿不到电量时为空（Go2Agent 未订阅 lowstate）
    vx: float = 0.0
    vy: float = 0.0
    wz: float = 0.0
    roll: float = 0.0
    pitch: float = 0.0
    yaw: float = 0.0
    joint_temps: list[list[float]] = Field(default_factory=list)
    foot_forces: list[float] = Field(default_factory=list)
    voltage: float = 0.0
    current: float = 0.0
    pose: Pose | None = None
    mode: str | None = None
    map_id: str | None = None  # pose 所在地图（服务器 GET /maps 的 id）
    extra: dict = Field(default_factory=dict)


class Hello(BaseModel):
    type: Literal["hello"] = "hello"
    protocol: int = PROTOCOL_VERSION
    model: str | None = None
    firmware: str | None = None
    sn: str | None = None
    ip: str | None = None
    capabilities: list[str] = Field(default_factory=list)
    skills: list[dict] = Field(default_factory=list)  # [{name, description, tags, motion}]
    sensors: dict | None = None  # {lidar, cameras[], topics[]}


class TelemetryMsg(Telemetry):
    type: Literal["telemetry"] = "telemetry"


class StateMsg(BaseModel):
    type: Literal["state"] = "state"
    status: DeviceStatus | None = None
    location: str | None = None
    task: str | None = None


class Ack(BaseModel):
    type: Literal["ack"] = "ack"
    cmd_id: str
    ok: bool
    error: str | None = None


class Event(BaseModel):
    """level: critical / warning / info；code=estop 表示本地急停被触发。"""

    type: Literal["event"] = "event"
    level: str
    code: str
    message: str


class Pong(BaseModel):
    type: Literal["pong"] = "pong"
    nonce: int


class WebrtcAnswerMsg(BaseModel):
    type: Literal["webrtc_answer"] = "webrtc_answer"
    session_id: str
    sdp: str


class WebrtcIceUp(BaseModel):
    type: Literal["webrtc_ice"] = "webrtc_ice"
    session_id: str
    candidate: dict


class WebrtcCloseUp(BaseModel):
    """结束或拒绝一路视频；reason 给人看。"""

    type: Literal["webrtc_close"] = "webrtc_close"
    session_id: str
    reason: str | None = None


# ───────────────────────── 服务器 → 机器人 ─────────────────────────


class Welcome(BaseModel):
    type: Literal["welcome"]
    protocol: int
    server_time: datetime
    estop: bool
    telemetry_hz: int
    max_speed_mps: float
    max_yaw_rate: float
    lost_link_action: str = "stop"  # stop | down | dock
    heartbeat_timeout_ms: int = 1500


class CommandMsg(BaseModel):
    type: Literal["command"]
    cmd_id: str
    command: Command


class Ping(BaseModel):
    type: Literal["ping"]
    nonce: int


class WebrtcOffer(BaseModel):
    """前端发起的一路视频（服务器只转发信令，媒体直连 / 走 TURN）。"""

    type: Literal["webrtc_offer"]
    session_id: str
    sdp: str
    streams: list[str] = Field(default_factory=lambda: ["front"])
    ice_servers: list[dict] = Field(default_factory=list)


class WebrtcIce(BaseModel):
    type: Literal["webrtc_ice"]
    session_id: str
    candidate: dict


class WebrtcClose(BaseModel):
    type: Literal["webrtc_close"]
    session_id: str


ServerMessage = Annotated[
    Welcome | CommandMsg | Ping | WebrtcOffer | WebrtcIce | WebrtcClose, Field(discriminator="type")
]
ServerMessageAdapter: TypeAdapter = TypeAdapter(ServerMessage)
