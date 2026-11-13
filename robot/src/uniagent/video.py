"""WebRTC 视频会话；仅传相机，采集和编解码均不阻塞控制/心跳。

可选依赖：uv sync --extra video。一个采集/解码轨道供至多若干观看者共享，
MediaRelay 不积压旧帧；信令断开、客户端关闭、ICE 失败或相机失帧均清理会话。
"""

import asyncio
import io
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from fractions import Fraction

import av
from aiortc import RTCConfiguration, RTCIceServer, RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
from aiortc.contrib.media import MediaRelay
from aiortc.sdp import SessionDescription, candidate_from_sdp
from pydantic import BaseModel
from websockets.exceptions import ConnectionClosed

from .adapters.base import RobotBackend
from .config import Settings
from .protocol import WebrtcAnswerMsg, WebrtcCloseUp, WebrtcIce, WebrtcOffer

log = logging.getLogger(__name__)
Send = Callable[[BaseModel], Awaitable[None]]


class CameraTrack(VideoStreamTrack):
    FRAME_TIMEOUT_SECONDS = 5.0

    def __init__(self, backend: RobotBackend, settings: Settings, failed: Callable[[], None]):
        super().__init__()
        self.backend = backend
        self.settings = settings
        self.failed = failed
        self._seq = -1
        self._last_sent = 0.0
        self._origin = time.monotonic()

    def _decode(self, jpeg: bytes) -> av.VideoFrame:
        with av.open(io.BytesIO(jpeg), format="mjpeg") as container:
            frame = next(container.decode(video=0), None)
            if frame is None:
                raise ValueError("相机 JPEG 未包含画面")
            width = min(frame.width, self.settings.video_width) // 2 * 2
            height = max(2, round(frame.height * width / frame.width) // 2 * 2)
            return frame.reformat(width=width, height=height, format="yuv420p")

    async def recv(self) -> av.VideoFrame:
        deadline = time.monotonic() + self.FRAME_TIMEOUT_SECONDS
        while self.readyState == "live":
            now = time.monotonic()
            if now >= deadline:
                self.failed()
                self.stop()
                break
            frame = self.backend.camera_frame("front")
            if frame is not None and frame.seq != self._seq and now - frame.stamp < 2:
                await asyncio.sleep(max(0, self._last_sent + 1 / self.settings.video_fps - now))
                try:
                    image = await asyncio.to_thread(self._decode, frame.jpeg)
                except (av.FFmpegError, ValueError, StopIteration):
                    # 单帧破损可恢复，不重复解码同一个坏帧。
                    self._seq = frame.seq
                    await asyncio.sleep(0.01)
                    continue
                self._seq = frame.seq
                self._last_sent = time.monotonic()
                image.pts = round((self._last_sent - self._origin) * 90000)
                image.time_base = Fraction(1, 90000)
                return image
            await asyncio.sleep(0.01)
        from aiortc.mediastreams import MediaStreamError

        raise MediaStreamError


@dataclass
class Session:
    pc: RTCPeerConnection
    task: asyncio.Task | None = None
    ice_task: asyncio.Task | None = None
    timeout_task: asyncio.Task | None = None
    candidates: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(maxsize=64))
    track: object | None = None


class VideoSessions:
    SIGNAL_TIMEOUT_SECONDS = 1.0

    def __init__(self, backend: RobotBackend, settings: Settings, send: Send):
        self.backend, self.settings, self.send = backend, settings, send
        self.sessions: dict[str, Session] = {}
        self._source: CameraTrack | None = None
        self._relay: MediaRelay | None = None
        self._cleanup: set[asyncio.Task] = set()

    def _spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._cleanup.add(task)

        def done(t):
            self._cleanup.discard(t)
            if not t.cancelled() and t.exception() is not None:
                log.warning("视频会话清理失败：%s", type(t.exception()).__name__)

        task.add_done_callback(done)

    def request_close(self, session_id: str) -> None:
        self._spawn(self.close(session_id))

    async def _notify(self, msg: BaseModel) -> None:
        try:
            await asyncio.wait_for(self.send(msg), self.SIGNAL_TIMEOUT_SECONDS)
        except (ConnectionClosed, OSError, RuntimeError, TimeoutError):
            log.debug("视频会话信令连接已关闭")

    async def offer(self, msg: WebrtcOffer) -> None:
        if msg.session_id in self.sessions:
            self._spawn(self.close(msg.session_id, "视频会话已存在，请重新连接"))
            return
        if "webrtc" not in self.backend.capabilities:
            reason = "机器人端相机未启用"
        elif msg.streams != ["front"]:
            reason = "设备仅支持前置相机 front"
        elif len(self.sessions) >= self.settings.video_max_sessions:
            reason = "相机观看人数已达上限"
        else:
            reason = None
        if reason:
            self._spawn(self._notify(WebrtcCloseUp(session_id=msg.session_id, reason=reason)))
            return
        servers = [
            RTCIceServer(urls=s["urls"], username=s.get("username"), credential=s.get("credential"))
            for s in msg.ice_servers
            if s.get("urls")
        ]
        pc = RTCPeerConnection(RTCConfiguration(iceServers=servers))
        session = Session(pc)
        self.sessions[msg.session_id] = session

        @pc.on("connectionstatechange")
        async def state_changed():
            if pc.connectionState in ("failed", "closed") and self.sessions.get(msg.session_id) is session:
                self._spawn(self.close(msg.session_id, "视频连接已断开"))

        session.task = asyncio.create_task(self._negotiate(msg, session))

    async def _negotiate(self, msg: WebrtcOffer, session: Session) -> None:
        try:
            async with asyncio.timeout(20):
                pc = session.pc
                videos = [m for m in SessionDescription.parse(msg.sdp).media if m.kind == "video"]
                if len(videos) != 1 or videos[0].direction not in ("recvonly", "sendrecv"):
                    raise ValueError("请请求一路接收视频")
                await pc.setRemoteDescription(RTCSessionDescription(sdp=msg.sdp, type="offer"))
                for transceiver in pc.getTransceivers():
                    transceiver.direction = "sendonly" if transceiver.kind == "video" else "inactive"
                if self._source is None or self._source.readyState != "live":
                    self._source = CameraTrack(self.backend, self.settings, self._camera_failed)
                    self._relay = MediaRelay()
                session.track = self._relay.subscribe(self._source, buffered=False)
                pc.addTrack(session.track)
                session.ice_task = asyncio.create_task(self._consume_ice(session))
                await pc.setLocalDescription(await pc.createAnswer())
                await self._notify(WebrtcAnswerMsg(session_id=msg.session_id, sdp=pc.localDescription.sdp))
                session.timeout_task = asyncio.create_task(self._check_connected(msg.session_id, session))
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("视频协商失败")
            self._spawn(self.close(msg.session_id, "视频协商失败，请重新连接"))

    async def _check_connected(self, session_id: str, session: Session) -> None:
        await asyncio.sleep(20)
        if session.pc.connectionState != "connected":
            self._spawn(self.close(session_id, "视频连接超时，请检查网络或 TURN 配置"))

    def ice(self, msg: WebrtcIce) -> None:
        session = self.sessions.get(msg.session_id)
        if session is not None:
            try:
                session.candidates.put_nowait(msg.candidate)
            except asyncio.QueueFull:
                self._spawn(self.close(msg.session_id, "视频候选地址过多"))

    async def _consume_ice(self, session: Session) -> None:
        while True:
            value = await session.candidates.get()
            try:
                raw = value.get("candidate", "")
                if raw is None:
                    raw = ""
                if not isinstance(raw, str):
                    raise TypeError("candidate 必须是字符串")
                candidate = candidate_from_sdp(raw.removeprefix("candidate:")) if raw else None
                if candidate is not None:
                    candidate.sdpMid = value.get("sdpMid")
                    candidate.sdpMLineIndex = value.get("sdpMLineIndex")
                await session.pc.addIceCandidate(candidate)
            except (ValueError, AssertionError, TypeError, KeyError, IndexError):
                log.debug("忽略无效的视频 ICE candidate")

    def _camera_failed(self) -> None:
        for session_id in list(self.sessions):
            self._spawn(self.close(session_id, "相机暂时没有新画面，请重试"))

    async def close(self, session_id: str, reason: str | None = None) -> None:
        session = self.sessions.pop(session_id, None)
        if session is None:
            return
        tasks = [t for t in (session.task, session.ice_task, session.timeout_task) if t is not None]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if session.track is not None:
            session.track.stop()
        await session.pc.close()
        if not self.sessions and self._source is not None:
            self._source.stop()
            self._source, self._relay = None, None
        if reason is not None:
            await self._notify(WebrtcCloseUp(session_id=session_id, reason=reason))

    async def close_all(self) -> None:
        for session_id in list(self.sessions):
            await self.close(session_id)
        if self._cleanup:
            await asyncio.gather(*list(self._cleanup), return_exceptions=True)
