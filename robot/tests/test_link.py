"""半开连接与长指令在断线时的收尾；只连接本地测试 WebSocket。"""

import asyncio
import json

from websockets.asyncio.client import connect
from websockets.asyncio.server import serve

from uniagent.adapters.mock import MockBackend
from uniagent.config import Settings
from uniagent.controller import Controller
from uniagent.link import ServerLink


def test_silent_server_cancels_command_and_stops_before_close():
    async def scenario():
        started, cancelled = asyncio.Event(), asyncio.Event()

        class SlowBackend(MockBackend):
            async def action(self, name, params):
                started.set()
                try:
                    await asyncio.Future()
                finally:
                    cancelled.set()

        backend = SlowBackend()
        link = ServerLink(Controller(backend, Settings()))
        release = asyncio.Event()

        async def handler(ws):
            assert json.loads(await ws.recv())["type"] == "hello"
            await ws.send(
                json.dumps(
                    {
                        "type": "welcome",
                        "protocol": 1,
                        "server_time": "2026-11-13T00:00:00Z",
                        "estop": False,
                        "telemetry_hz": 10,
                        "max_speed_mps": 0.3,
                        "max_yaw_rate": 0.6,
                        "heartbeat_timeout_ms": 100,
                    }
                )
            )
            await ws.send(
                json.dumps(
                    {
                        "type": "command",
                        "cmd_id": "00000000-0000-0000-0000-000000000001",
                        "command": {"kind": "action", "name": "hello"},
                    }
                )
            )
            await release.wait()

        async with serve(handler, "127.0.0.1", 0) as server:
            port = server.sockets[0].getsockname()[1]
            async with connect(f"ws://127.0.0.1:{port}") as ws:
                link._ws = ws
                try:
                    await asyncio.wait_for(link._session(ws), 2)
                except TimeoutError:
                    pass
                else:
                    raise AssertionError("silent server must time out")
                assert started.is_set() and cancelled.is_set()
                assert not link.connected and not link._commands
                assert backend.calls[-1] == ("stop",)
                release.set()

    asyncio.run(scenario())
