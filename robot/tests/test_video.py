"""真实本地 WebRTC 协商/收帧，图像来自生成的 JPEG；不连接 DDS。"""

import asyncio
import io
import time

import pytest

pytest.importorskip("aiortc", reason="需要 uv sync --extra video")
import av
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription

from uniagent.adapters.base import CameraFrame
from uniagent.adapters.mock import MockBackend
from uniagent.config import Settings
from uniagent.controller import Controller
from uniagent.link import ServerLink
from uniagent.protocol import WebrtcIce, WebrtcOffer
from uniagent.video import CameraTrack, VideoSessions


def jpeg():
    buffer = io.BytesIO()
    with av.open(buffer, "w", format="mjpeg") as output:
        stream = output.add_stream("mjpeg", rate=10)
        stream.width, stream.height, stream.pix_fmt = 320, 180, "yuvj420p"
        frame = av.VideoFrame(320, 180, "yuvj420p")
        for plane in frame.planes:
            plane.update(bytes([128]) * plane.buffer_size)
        for packet in stream.encode(frame):
            output.mux(packet)
        for packet in stream.encode():
            output.mux(packet)
    return buffer.getvalue()


class CameraBackend(MockBackend):
    capabilities = (*MockBackend.capabilities, "webrtc")

    def __init__(self):
        super().__init__()
        self.image = jpeg()
        self.seq = 0
        self.stale = False

    def camera_frame(self, stream="front"):
        self.seq += 1
        return CameraFrame(self.seq, time.monotonic() - (30 if self.stale else 0), self.image)


def test_webrtc_front_frames_and_close():
    async def scenario():
        messages = asyncio.Queue()
        manager = VideoSessions(CameraBackend(), Settings(video_width=160), messages.put)
        viewer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        viewer.addTransceiver("video", direction="recvonly")
        track_ready = asyncio.Future()

        @viewer.on("track")
        def track_received(track):
            track_ready.set_result(track)

        try:
            await viewer.setLocalDescription(await viewer.createOffer())
            await manager.offer(
                WebrtcOffer(type="webrtc_offer", session_id="test", sdp=viewer.localDescription.sdp)
            )
            answer = await asyncio.wait_for(messages.get(), 5)
            assert answer.type == "webrtc_answer"
            await viewer.setRemoteDescription(RTCSessionDescription(answer.sdp, "answer"))
            track = await asyncio.wait_for(track_ready, 5)
            frames = [await asyncio.wait_for(track.recv(), 5) for _ in range(3)]
            assert all((f.width, f.height) == (160, 90) for f in frames)
            assert frames[0].pts < frames[1].pts < frames[2].pts
            assert len(manager.sessions) == 1
            source = manager._source
            await manager.close_all()
            assert not manager.sessions and manager._source is None
            assert source.readyState == "ended"
        finally:
            await manager.close_all()
            await viewer.close()

    asyncio.run(scenario())


def test_camera_stale_frame_is_never_returned():
    async def scenario():
        backend = CameraBackend()
        backend.stale = True
        track = CameraTrack(backend, Settings(), lambda: None)
        with pytest.raises(TimeoutError):
            await asyncio.wait_for(track.recv(), 0.08)
        track.stop()

    asyncio.run(scenario())


def test_corrupt_frames_end_stream_instead_of_freezing_forever(monkeypatch):
    from aiortc.mediastreams import MediaStreamError

    async def scenario():
        backend = CameraBackend()
        backend.image = b"not jpeg"
        failed = asyncio.Event()
        track = CameraTrack(backend, Settings(), failed.set)
        monkeypatch.setattr(track, "FRAME_TIMEOUT_SECONDS", 0.05)
        with pytest.raises(MediaStreamError):
            await asyncio.wait_for(track.recv(), 1)
        assert failed.is_set() and track.readyState == "ended"

    asyncio.run(scenario())


def test_unsupported_stream_rejected_and_bad_sdp_cleans_up():
    async def scenario():
        messages = asyncio.Queue()
        manager = VideoSessions(CameraBackend(), Settings(), messages.put)
        await manager.offer(
            WebrtcOffer(type="webrtc_offer", session_id="bad", sdp="invalid", streams=["rear"])
        )
        assert (await messages.get()).reason == "设备仅支持前置相机 front"
        assert not manager.sessions
        await manager.offer(WebrtcOffer(type="webrtc_offer", session_id="bad", sdp="invalid"))
        assert (await asyncio.wait_for(messages.get(), 2)).type == "webrtc_close"
        await manager.close_all()
        assert not manager.sessions

    asyncio.run(scenario())


def test_slow_video_negotiation_does_not_block_stop_and_shutdown(monkeypatch):
    async def scenario():
        started, cancelled = asyncio.Event(), asyncio.Event()

        async def stalled(self, description):
            started.set()
            try:
                await asyncio.Future()
            finally:
                cancelled.set()

        monkeypatch.setattr(RTCPeerConnection, "setRemoteDescription", stalled)
        backend = CameraBackend()
        link = ServerLink(Controller(backend, Settings(video_enabled=True)))
        viewer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        viewer.addTransceiver("video", direction="recvonly")
        try:
            offer = await viewer.createOffer()
            await link._on_message(
                WebrtcOffer(type="webrtc_offer", session_id="slow", sdp=offer.sdp).model_dump_json()
            )
            await asyncio.wait_for(started.wait(), 1)
            await link._on_message('{"type":"command","cmd_id":"stop","command":{"kind":"stop"}}')
            for _ in range(20):
                if backend.calls and backend.calls[-1] == ("stop",):
                    break
                await asyncio.sleep(0.01)
            assert backend.calls[-1] == ("stop",)
            await link.video.close_all()
            assert cancelled.is_set() and not link.video.sessions
        finally:
            await link.video.close_all()
            await viewer.close()

    asyncio.run(scenario())


def test_viewer_limit_and_candidate_queue_bound():
    async def scenario():
        messages = asyncio.Queue()
        manager = VideoSessions(CameraBackend(), Settings(video_max_sessions=1), messages.put)
        viewer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        viewer.addTransceiver("video", direction="recvonly")
        try:
            offer = await viewer.createOffer()
            await manager.offer(WebrtcOffer(type="webrtc_offer", session_id="one", sdp=offer.sdp))
            await manager.offer(WebrtcOffer(type="webrtc_offer", session_id="two", sdp=offer.sdp))
            assert (await messages.get()).reason == "相机观看人数已达上限"
            for _ in range(65):
                manager.ice(WebrtcIce(type="webrtc_ice", session_id="one", candidate={}))
            await asyncio.sleep(0)
            await manager.close_all()
            assert not manager.sessions
        finally:
            await manager.close_all()
            await viewer.close()

    asyncio.run(scenario())


def test_rejection_backpressure_does_not_block_receive_or_cleanup(monkeypatch):
    async def scenario():
        started, cancelled = asyncio.Event(), asyncio.Event()

        async def blocked_send(_):
            started.set()
            try:
                await asyncio.Future()
            finally:
                cancelled.set()

        backend = CameraBackend()
        link = ServerLink(Controller(backend, Settings(video_enabled=True)))
        link.video.send = blocked_send
        monkeypatch.setattr(link.video, "SIGNAL_TIMEOUT_SECONDS", 0.05)
        await asyncio.wait_for(
            link._on_message(
                WebrtcOffer(
                    type="webrtc_offer", session_id="rear", sdp="", streams=["rear"]
                ).model_dump_json()
            ),
            0.1,
        )
        await asyncio.wait_for(started.wait(), 1)
        await link._on_message('{"type":"command","cmd_id":"stop","command":{"kind":"stop"}}')
        await asyncio.sleep(0)
        assert backend.calls[-1] == ("stop",)
        await asyncio.wait_for(link.video.close_all(), 1)
        assert cancelled.is_set()

    asyncio.run(scenario())
