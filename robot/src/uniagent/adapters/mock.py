"""模拟机器人：无需硬件即可联调服务器与前端。"""

import math
import random
import time
from typing import Any

from ..protocol import Pose, Telemetry
from .base import AdapterError, RobotBackend

MODES = {"stand", "down", "balance", "walk", "stairs", "damp", "recovery"}
SKILLS = {
    "hello": "打招呼",
    "stretch": "伸展",
    "heart": "比心",
    "sit": "坐下",
    "dance1": "跳舞 1",
}


class MockBackend(RobotBackend):
    capabilities = ("move", "mode", "speed", "action", "telemetry")

    def __init__(self, model: str = "Unitree Go2 EDU (mock)") -> None:
        self._model = model
        self._v = (0.0, 0.0, 0.0)
        self._pose = Pose()
        self._mode = "stand"
        self._battery = 86.0
        self._temps = [[41.0, 44.0, 46.0], [40.0, 43.0, 45.0], [42.0, 47.0, 52.0], [39.0, 42.0, 44.0]]
        self._last = time.monotonic()
        self.calls: list[tuple] = []  # 测试用：记录调用序列

    async def connect(self) -> None:
        pass

    def info(self) -> dict[str, Any]:
        return {"model": self._model, "firmware": "mock-1.0", "sn": "MOCK-0001", "ip": "127.0.0.1"}

    def skills(self) -> list[dict[str, Any]]:
        return [{"name": k, "description": v, "tags": [], "motion": True} for k, v in SKILLS.items()]

    def sensors(self) -> dict[str, Any]:
        return {
            "lidar": "4D LiDAR · 360°×90° · 21,600 点/秒 · 10 Hz（模拟）",
            "cameras": [
                {"name": "前置 RGB", "detail": "1280×720 · 30 fps", "health": "ok", "hz": 30},
                {"name": "深度", "detail": "640×480 · 15 fps", "health": "ok", "hz": 15},
            ],
            "topics": [
                {"name": "/utlidar/cloud", "detail": "PointCloud2", "health": "ok", "hz": 10},
                {"name": "/sportmodestate", "detail": "SportModeState", "health": "ok", "hz": 50},
            ],
        }

    async def pointcloud(self) -> list[tuple[float, float]]:
        # 模拟一个 8 m × 6 m 的房间轮廓 + 噪声
        pts = []
        for i in range(720):
            a = i / 720 * 2 * math.pi
            c, s = math.cos(a), math.sin(a)
            r = min(4.0 / abs(c) if abs(c) > 1e-6 else 99, 3.0 / abs(s) if abs(s) > 1e-6 else 99)
            r += random.uniform(-0.03, 0.03)
            pts.append((round(r * c, 3), round(r * s, 3)))
        return pts

    async def move(self, vx: float, vy: float, wz: float) -> None:
        if self._mode in ("down", "damp"):
            raise AdapterError(f"当前模式 {self._mode} 不能行走，请先站立")
        self._v = (vx, vy, wz)
        self.calls.append(("move", vx, vy, wz))

    async def stop(self) -> None:
        self._v = (0.0, 0.0, 0.0)
        self.calls.append(("stop",))

    async def damp(self) -> None:
        self._v = (0.0, 0.0, 0.0)
        self._mode = "damp"
        self.calls.append(("damp",))

    async def set_mode(self, mode: str) -> None:
        if mode not in MODES:
            raise AdapterError(f"未知模式 {mode}")
        if mode in ("down", "damp"):
            self._v = (0.0, 0.0, 0.0)
        self._mode = "stand" if mode == "recovery" else mode
        self.calls.append(("mode", mode))

    async def action(self, name: str, params: dict[str, Any]) -> None:
        if name not in SKILLS:
            raise AdapterError(f"不支持的动作 {name}")
        self.calls.append(("action", name))

    async def telemetry(self) -> Telemetry:
        now = time.monotonic()
        dt, self._last = now - self._last, now
        vx, vy, wz = self._v
        p = self._pose
        p.yaw = (p.yaw + wz * dt + math.pi) % (2 * math.pi) - math.pi
        p.x += (vx * math.cos(p.yaw) - vy * math.sin(p.yaw)) * dt
        p.y += (vx * math.sin(p.yaw) + vy * math.cos(p.yaw)) * dt
        speed = abs(vx) + abs(vy) + abs(wz) * 0.3
        self._battery = max(0.0, self._battery - dt * (0.002 + speed * 0.01))
        for leg in self._temps:
            for i in range(3):
                target = 38.0 + speed * 12.0 + i * 3
                leg[i] += (target - leg[i]) * min(1.0, dt * 0.05) + random.uniform(-0.05, 0.05)
        moving = speed > 0.01
        return Telemetry(
            battery=round(self._battery, 1),
            vx=vx,
            vy=vy,
            wz=wz,
            roll=random.uniform(-0.02, 0.02),
            pitch=random.uniform(-0.03, 0.03) if moving else 0.0,
            yaw=p.yaw,
            joint_temps=[[round(t, 1) for t in leg] for leg in self._temps],
            foot_forces=[round(random.uniform(60, 120) if moving else 85.0, 1) for _ in range(4)],
            voltage=round(25.2 * (0.85 + self._battery / 100 * 0.15), 2),
            current=round(1.5 + speed * 6 + random.uniform(-0.2, 0.2), 2),
            pose=Pose(x=round(p.x, 3), y=round(p.y, 3), yaw=round(p.yaw, 3)),
            mode=self._mode,
            map_id="b2",
            extra={
                "loc_confidence": 0.92,
                "acc": [round(random.uniform(-0.1, 0.1), 3), round(random.uniform(-0.1, 0.1), 3), 9.81],
                "battery_temp": round(31.0 + speed * 4, 1),
            },
        )
