import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from uniagent.adapters.mock import MockBackend
from uniagent.api import create_app
from uniagent.config import Settings
from uniagent.controller import CommandRejected, Controller
from uniagent.protocol import (
    CommandAdapter,
    CommandMsg,
    MoveCmd,
    ServerMessageAdapter,
    SetModeCmd,
    SetSpeedCmd,
    StopCmd,
    TelemetryMsg,
    Welcome,
    is_motion,
)


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


# ───────── 协议：与服务端 uniconsole-protocol 的线格式保持一致 ─────────


def test_parse_server_command():
    raw = json.dumps(
        {
            "type": "command",
            "cmd_id": "00000000-0000-0000-0000-000000000000",
            "command": {"kind": "move", "vx": 0.5, "vy": 0, "wz": -0.1},
        }
    )
    msg = ServerMessageAdapter.validate_json(raw)
    assert isinstance(msg, CommandMsg)
    assert isinstance(msg.command, MoveCmd) and msg.command.vx == 0.5


def test_parse_welcome():
    raw = json.dumps(
        {
            "type": "welcome",
            "protocol": 1,
            "server_time": "2026-11-02T06:00:00Z",
            "estop": True,
            "telemetry_hz": 10,
            "max_speed_mps": 1.5,
            "max_yaw_rate": 2.0,
        }
    )
    msg = ServerMessageAdapter.validate_json(raw)
    assert isinstance(msg, Welcome) and msg.estop


def test_telemetry_wire_format():
    t = run(MockBackend().telemetry())
    d = json.loads(TelemetryMsg(**t.model_dump()).model_dump_json())
    assert d["type"] == "telemetry"
    assert len(d["joint_temps"]) == 4 and len(d["joint_temps"][0]) == 3
    assert d["ts"].endswith("Z") or "+00:00" in d["ts"]


def test_motion_classification():
    assert is_motion(MoveCmd(vx=0, vy=0, wz=0))
    assert not is_motion(StopCmd())
    assert not is_motion(SetModeCmd(mode="damp"))
    assert is_motion(CommandAdapter.validate_python({"kind": "action", "name": "hello"}))


def test_battery_optional():
    d = json.loads(TelemetryMsg().model_dump_json())
    assert d["battery"] is None


# ───────── 控制器：急停、限幅、看门狗 ─────────


def make_controller(**kw):
    s = Settings(**kw)
    return Controller(MockBackend(), s), s


def test_clamp_by_speed_level():
    c, _ = make_controller()
    run(c.handle(SetSpeedCmd(level="slow")))
    run(c.handle(MoveCmd(vx=5.0, vy=-5.0, wz=9.0)))
    assert c.backend.calls[-1] == ("move", 0.3, -0.3, 2.0)


def test_estop_blocks_motion_but_allows_stop():
    c, _ = make_controller(estop_mode="damp")
    run(c.trigger_estop("test"))
    assert c.backend.calls[-1] == ("damp",)
    with pytest.raises(CommandRejected):
        run(c.handle(MoveCmd(vx=0.1, vy=0, wz=0)))
    run(c.handle(StopCmd()))  # 停止永远允许


def test_watchdog_stops_after_timeout():
    c, _ = make_controller(watchdog_ms=100)

    async def scenario():
        wd = asyncio.ensure_future(c.watchdog())
        await c.handle(MoveCmd(vx=0.5, vy=0, wz=0))
        assert c.moving
        await asyncio.sleep(0.3)
        wd.cancel()

    run(scenario())
    assert not c.moving
    assert ("stop",) in c.backend.calls


# ───────── 本地 FastAPI ─────────


def test_local_api():
    app = create_app(Settings(local_api_token="secret"), connect_server=False)
    with TestClient(app) as client:
        assert client.get("/health").json()["server_connected"] is False
        assert "battery" in client.get("/telemetry").json()
        assert any(sk["name"] == "hello" for sk in client.get("/skills").json())

        assert client.post("/commands", json={"kind": "stop"}).status_code == 401
        r = client.post(
            "/commands", json={"kind": "set_mode", "mode": "stand"}, headers={"X-Local-Token": "secret"}
        )
        assert r.status_code == 200

        assert client.post("/estop").json() == {"estop": True}
        r = client.post(
            "/commands",
            json={"kind": "move", "vx": 0.2, "vy": 0, "wz": 0},
            headers={"X-Local-Token": "secret"},
        )
        assert r.status_code == 423


def test_local_control_disabled_without_token():
    app = create_app(Settings(local_api_token=""), connect_server=False)
    with TestClient(app) as client:
        assert (
            client.post("/commands", json={"kind": "stop"}, headers={"X-Local-Token": ""}).status_code == 403
        )
