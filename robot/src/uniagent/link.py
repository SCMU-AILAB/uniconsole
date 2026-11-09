"""与服务器的长连接：机器人主动外连（适配 NAT / 4G），断线指数退避重连。

上行：hello → telemetry（按服务器要求的频率）/ ack / event / pong
下行：welcome → command / ping
"""

import asyncio
import logging
import struct
import time

from pydantic import BaseModel, ValidationError
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed, InvalidStatus

from .adapters import AdapterError
from .controller import CommandRejected, Controller
from .protocol import (
    Ack,
    CommandMsg,
    Event,
    Hello,
    MoveCmd,
    Ping,
    Pong,
    ServerMessageAdapter,
    StateMsg,
    TelemetryMsg,
    WebrtcCloseUp,
    WebrtcOffer,
    Welcome,
)

log = logging.getLogger(__name__)


class ServerLink:
    def __init__(self, controller: Controller) -> None:
        self.controller = controller
        self.settings = controller.settings
        self.connected = False
        self.last_error: str | None = None
        self._ws: ClientConnection | None = None
        self._send_lock = asyncio.Lock()
        self._telemetry_hz = self.settings.telemetry_hz

    async def send(self, msg: BaseModel) -> None:
        ws = self._ws
        if ws is None:
            return
        async with self._send_lock:
            await ws.send(msg.model_dump_json())

    async def emit_event(self, event: Event) -> None:
        """供 Controller 回调：本地事件上报（断线时丢弃）。"""
        try:
            await self.send(event)
        except ConnectionClosed:
            pass

    async def run_forever(self) -> None:
        if not (self.settings.device_id and self.settings.device_token):
            log.error("未配置 DEVICE_ID / DEVICE_TOKEN，不连接服务器（仅本地 API 可用）")
            return
        backoff = 1.0
        headers = {
            "Authorization": f"Bearer {self.settings.device_token}",
            "X-Device-Id": self.settings.device_id,
        }
        while True:
            try:
                async with connect(
                    self.settings.server_url,
                    additional_headers=headers,
                    ping_interval=None,  # 使用应用层 ping
                    open_timeout=5,
                    max_queue=64,
                ) as ws:
                    self._ws = ws
                    backoff = 1.0
                    await self._session(ws)
            except InvalidStatus as e:
                self.last_error = f"服务器拒绝连接：HTTP {e.response.status_code}"
                log.error(self.last_error)
            except (TimeoutError, OSError, ConnectionClosed) as e:
                self.last_error = f"连接中断：{e!r}"
                log.warning(self.last_error)
            except Exception as e:
                self.last_error = f"未知错误：{e!r}"
                log.exception("服务器连接异常")
            finally:
                was_connected = self.connected
                self._ws = None
                self.connected = False
                if was_connected:
                    await self.controller.on_link_lost()
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30.0)

    async def _session(self, ws: ClientConnection) -> None:
        backend = self.controller.backend
        await self.send(
            Hello(
                capabilities=list(backend.capabilities),
                skills=backend.skills(),
                sensors=backend.sensors(),
                **backend.info(),
            )
        )

        welcome = ServerMessageAdapter.validate_json(await asyncio.wait_for(ws.recv(), timeout=5))
        if not isinstance(welcome, Welcome):
            raise TypeError(f"期望 welcome，收到 {welcome!r}")
        self.controller.apply_server_limits(welcome.max_speed_mps, welcome.max_yaw_rate)
        self.controller.lost_link_action = welcome.lost_link_action
        if welcome.estop and not self.controller.estop:
            await self.controller.trigger_estop(source="server")
        self._telemetry_hz = max(1, min(welcome.telemetry_hz, 50))
        self.connected = True
        self.last_error = None
        log.info("已连接服务器 %s（遥测 %d Hz）", self.settings.server_url, self._telemetry_hz)

        await self.send(StateMsg(status="online"))

        telemetry = asyncio.ensure_future(self._telemetry_loop())
        cloud = asyncio.ensure_future(self._pointcloud_loop())
        try:
            async for raw in ws:
                await self._on_message(raw)
        finally:
            telemetry.cancel()
            cloud.cancel()

    async def _pointcloud_loop(self, hz: float = 5.0) -> None:
        """点云二进制帧：[ts i64 LE][N × (f32 x, f32 y) LE]，后端不支持时直接退出。"""
        while True:
            pts = await self.controller.backend.pointcloud()
            if pts is None:
                return
            ws = self._ws
            if ws is not None:
                frame = struct.pack("<q", int(time.time() * 1000)) + b"".join(
                    struct.pack("<ff", x, y) for x, y in pts
                )
                async with self._send_lock:
                    await ws.send(frame)
            await asyncio.sleep(1.0 / hz)

    async def _telemetry_loop(self) -> None:
        period = 1.0 / self._telemetry_hz
        while True:
            try:
                t = await self.controller.backend.telemetry()
                await self.send(TelemetryMsg(**t.model_dump()))
            except AdapterError as e:
                log.debug("读取遥测失败：%s", e)
            await asyncio.sleep(period)

    async def _on_message(self, raw) -> None:
        try:
            msg = ServerMessageAdapter.validate_json(raw)
        except ValidationError as e:
            log.warning("无法解析服务器消息：%s", e)
            return

        if isinstance(msg, Ping):
            await self.send(Pong(nonce=msg.nonce))
        elif isinstance(msg, CommandMsg):
            # 不阻塞接收循环：SDK 调用可能耗时，急停必须能及时进来
            asyncio.ensure_future(self._execute(msg))
        elif isinstance(msg, WebrtcOffer):
            # 视频推流尚未接入（需要 aiortc / GStreamer 推相机流）：明确拒绝，前端据此显示原因
            await self.send(WebrtcCloseUp(session_id=msg.session_id, reason="机器人端尚未接入视频"))
        # webrtc_ice / webrtc_close：没有进行中的视频会话，忽略

    async def _execute(self, msg: CommandMsg) -> None:
        cmd = msg.command
        try:
            await self.controller.handle(cmd)
            ok, error = True, None
        except (CommandRejected, AdapterError) as e:
            ok, error = False, str(e)
        except Exception as e:
            log.exception("执行指令失败")
            ok, error = False, f"内部错误：{e}"
        # 高频 move 不回执（服务器也不等待），失败时才上报
        if isinstance(cmd, MoveCmd) and ok:
            return
        try:
            await self.send(Ack(cmd_id=msg.cmd_id, ok=ok, error=error))
        except ConnectionClosed:
            pass
