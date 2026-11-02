"""Go2AgentBackend：用 Go2Agent 的 SimulatedRobotAdapter 验证技能映射（不连接 DDS）。

需要 `uv sync --extra go2`；未安装时跳过。
"""

import asyncio

import pytest

pytest.importorskip("core.runtime", reason="Go2Agent 未安装（uv sync --extra go2）")

from uniagent.adapters import AdapterError
from uniagent.adapters.go2agent import Go2AgentBackend
from uniagent.config import Settings
from uniagent.controller import Controller
from uniagent.protocol import ActionCmd, MoveCmd, SetModeCmd, StopCmd


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


@pytest.fixture
def backend():
    return Go2AgentBackend(simulated=True)


def test_skill_catalog_from_go2agent(backend):
    names = {s["name"] for s in backend.skills()}
    assert {"stop", "hello", "heart", "stand_up", "damp"} <= names


def test_mode_maps_to_skill(backend):
    run(backend.set_mode("stand"))
    assert ("loco_action", ("stand_up", {})) in backend.robot.events


def test_action_and_unknown_skill(backend):
    run(backend.action("heart", {}))
    assert ("loco_action", ("heart", {})) in backend.robot.events
    with pytest.raises(AdapterError):
        run(backend.action("backflip_xxx", {}))


def test_controller_clamps_to_go2agent_limits(backend):
    c = Controller(backend, Settings())
    run(c.handle(SetModeCmd(mode="balance")))
    run(c.handle(MoveCmd(vx=0.8, vy=0.0, wz=-2.0)))  # normal 档 0.8，但 Go2Agent 上限 0.3 / 0.6
    assert backend.robot.events[-1] == ("move_velocity", (0.3, 0.0, -0.6))
    run(c.handle(StopCmd()))
    assert backend.robot.events[-1][0] == "stop"
    run(c.handle(ActionCmd(name="hello")))


def test_telemetry_simulated(backend):
    t = run(backend.telemetry())
    assert t.battery is None and t.extra["hardware"] is False
