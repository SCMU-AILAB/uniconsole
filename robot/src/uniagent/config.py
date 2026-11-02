"""配置：全部来自环境变量（或 robot/.env）。"""

import os
from dataclasses import dataclass
from pathlib import Path


def _load_dotenv(path: Path) -> None:
    """极简 .env 读取，不覆盖已有环境变量。"""
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def _env(key: str, default: object = "") -> str:
    return os.environ.get(key, str(default))


def _flag(key: str) -> bool:
    return _env(key).lower() in ("1", "true", "yes", "on")


@dataclass
class Settings:
    # 服务器接入
    server_url: str = "ws://127.0.0.1:8080/api/v1/robot/ws"
    device_id: str = ""
    device_token: str = ""

    # 执行后端
    adapter: str = "mock"  # mock | go2agent
    network_interface: str = ""  # DDS 网卡，例如 eth0
    domain_id: int = 0
    model: str = "Unitree Go2 EDU"
    go2agent_simulated: bool = False  # 使用 Go2Agent 的 SimulatedRobotAdapter（不连 DDS）
    # Go2Agent UnitreeGo2Config 的应用限速（越界会被拒绝，Controller 会先限幅）
    go2_max_forward: float = 0.3
    go2_max_lateral: float = 0.3
    go2_max_yaw: float = 0.6
    estop_mode: str = "damp"  # damp（阻尼卸力）| stop（StopMove 保持站立）

    # 安全
    watchdog_ms: int = 300  # HANDOFF §8.4：输入松开 300 ms 自动停止
    max_speed_mps: float = 1.5
    max_yaw_rate: float = 2.0

    # 本地 FastAPI
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    local_api_token: str = ""  # 为空则本地控制接口禁用

    telemetry_hz: int = 10

    @classmethod
    def from_env(cls) -> "Settings":
        _load_dotenv(Path.cwd() / ".env")
        d = cls()
        return cls(
            server_url=_env("SERVER_URL", d.server_url),
            device_id=_env("DEVICE_ID"),
            device_token=_env("DEVICE_TOKEN"),
            adapter=_env("ADAPTER", d.adapter),
            network_interface=_env("NETWORK_INTERFACE"),
            domain_id=int(_env("DOMAIN_ID", d.domain_id)),
            model=_env("ROBOT_MODEL", d.model),
            go2agent_simulated=_flag("GO2AGENT_SIMULATED"),
            go2_max_forward=float(_env("GO2_MAX_FORWARD", d.go2_max_forward)),
            go2_max_lateral=float(_env("GO2_MAX_LATERAL", d.go2_max_lateral)),
            go2_max_yaw=float(_env("GO2_MAX_YAW", d.go2_max_yaw)),
            estop_mode=_env("ESTOP_MODE", d.estop_mode),
            watchdog_ms=int(_env("WATCHDOG_MS", d.watchdog_ms)),
            max_speed_mps=float(_env("MAX_SPEED_MPS", d.max_speed_mps)),
            max_yaw_rate=float(_env("MAX_YAW_RATE", d.max_yaw_rate)),
            api_host=_env("API_HOST", d.api_host),
            api_port=int(_env("API_PORT", d.api_port)),
            local_api_token=_env("LOCAL_API_TOKEN"),
            telemetry_hz=int(_env("TELEMETRY_HZ", d.telemetry_hz)),
        )
