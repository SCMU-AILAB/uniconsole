"""Go2 后端：复用 Go2Agent 的 Skill Runtime 与 UnitreeGo2Adapter。

Go2Agent 约定「Robot Skill Runtime 是唯一动作执行边界」，因此：
- 服务器 `action` / `set_mode` 指令 → `SkillRuntime.execute(技能名)`，与 Go2Agent 的文本 / 视觉 Agent
  共用同一技能目录（register_go2_skills，44 个技能），参数校验、资源锁、感知前提都由 Go2Agent 负责；
- `stop` → 执行 `stop` 技能（取消正在运行的技能并 StopMove）；
- 摇杆 `move` 是逐帧速度采样，没有对应的有限时长技能：先取消正在运行的技能，再调用
  `UnitreeGo2Adapter.move_velocity`（Go2 移动技能内部也是这样刷新速度的）。

UnitreeGo2Adapter 是进程内唯一的 DDS 所有者；不要同时运行 Go2Agent 自己的 app.api / app.main。
"""

import asyncio
import logging
import math
import time
from typing import Any

from ..protocol import Pose, Telemetry
from .base import AdapterError, CameraFrame, RobotBackend, VelocityLimits

log = logging.getLogger(__name__)

# 与 Go2Agent UnitreeGo2Config 默认值一致
GO2AGENT_DEFAULT_LIMITS = VelocityLimits(0.3, 0.3, 0.6)

# 不会让机身运动的技能（停止 / 卸力 / 模式开关）；其余技能都视为运动技能
NON_MOTION_SKILLS = frozenset(
    {"stop", "stop_move", "damp", "switch_avoid_mode", "switch_joystick", "auto_recover_set", "free_avoid"}
)

# 服务器 MotionMode → Go2Agent 技能
MODE_SKILLS = {
    "stand": "stand_up",
    "down": "stand_down",
    "balance": "balance_stand",
    "walk": "balance_stand",  # Go2 在平衡站立下接收 move 即行走
    "damp": "damp",
    "recovery": "recovery_stand",
    # stairs：Go2Agent 目录里没有对应步态技能，可用 action 显式选择 classic_walk 等
}


class Go2AgentBackend(RobotBackend):
    capabilities = ("move", "mode", "action", "skills", "telemetry")

    def __init__(
        self,
        *,
        network_interface: str = "",
        domain_id: int = 0,
        model: str = "Unitree Go2 EDU",
        limits: VelocityLimits = GO2AGENT_DEFAULT_LIMITS,
        simulated: bool = False,
        video_enabled: bool = False,
        video_fps: int = 10,
        lidar_enabled: bool = False,
    ) -> None:
        try:
            from core.runtime import SkillRuntime
            from robot import SimulatedRobotAdapter, UnitreeGo2Adapter, UnitreeGo2Config
            from skills import register_go2_skills
        except ImportError as e:  # pragma: no cover - 取决于安装方式
            raise AdapterError("未安装 Go2Agent：uv sync --extra go2") from e

        self._model = model
        self._simulated = simulated
        self._video_enabled = video_enabled and not simulated
        self._video_fps = video_fps
        self._camera = None
        self._lidar_enabled = lidar_enabled and not simulated
        self._lidar = None
        self._lidar_frame = None
        self._lidar_sent = -1
        self.limits = limits
        if simulated:
            self.robot = SimulatedRobotAdapter()
        else:
            self.robot = UnitreeGo2Adapter(
                UnitreeGo2Config(
                    network_interface=network_interface,
                    domain_id=domain_id,
                    max_forward_m_s=limits.forward_m_s,
                    max_lateral_m_s=limits.lateral_m_s,
                    max_yaw_rad_s=limits.yaw_rad_s,
                )
            )
        self.runtime = SkillRuntime(self.robot)
        register_go2_skills(self.runtime)
        self._mode = "stand"

    # ───────── 生命周期 ─────────

    async def connect(self) -> None:
        if not self._simulated:
            await self._native(self.robot.connect())
        if self._video_enabled:
            try:
                from perception.go2_front import Go2FrontCamera

                # 采集实现归 Go2Agent，复用上面已初始化的 DDS，永不另起 DDS 所有者。
                camera = Go2FrontCamera(fps=self._video_fps)
                await asyncio.to_thread(camera.start)
                self._camera = camera
                self.capabilities = (*type(self).capabilities, "webrtc")
            except Exception:
                log.exception("Go2Agent 前置相机初始化失败，控制与遥测仍可使用")
        if self._lidar_enabled:
            try:
                from perception.go2_lidar import Go2Lidar

                self._lidar = Go2Lidar()
                await asyncio.to_thread(self._lidar.start)
                self.capabilities = (*self.capabilities, "pointcloud")
            except Exception:
                self._lidar = None
                log.exception("Go2Agent 雷达初始化失败")

    async def close(self) -> None:
        if self._lidar is not None:
            await asyncio.to_thread(self._lidar.close)
            self._lidar = None
        if self._camera is not None:
            await asyncio.to_thread(self._camera.close)
            if self._camera.status.state == "close_timeout":
                raise AdapterError("相机线程尚未停止，保留 DDS 至进程退出")
            self._camera = None
        if not self._simulated:
            await self._native(self.robot.close())

    def camera_frame(self, stream: str = "front") -> CameraFrame | None:
        if stream != "front" or self._camera is None:
            return None
        frame = self._camera.latest()
        return None if frame is None else CameraFrame(frame.seq, frame.stamp, frame.jpeg)

    def sensors(self) -> dict[str, Any] | None:
        if self._camera is None and self._lidar is None:
            return None
        frame = self.camera_frame()
        healthy = frame is not None and time.monotonic() - frame.stamp < 2
        return {
            "cameras": [
                {
                    "name": "front",
                    "detail": "Go2 前置相机",
                    "health": "ok" if healthy else "idle",
                    "hz": self._video_fps,
                }
            ]
            if self._camera is not None
            else [],
            "lidar": "Go2 LiDAR（点云 / 高程图）" if self._lidar is not None else "尚未接入",
            "topics": [
                {"name": "/utlidar/cloud_deskewed", "detail": "雷达原始点云（去畸变）", "health": "idle"},
                {"name": "/utlidar/height_map_array", "detail": "雷达高程图（备用）", "health": "idle"},
            ]
            if self._lidar
            else [],
        }

    async def pointcloud(self) -> list[tuple[float, float]] | None:
        if self._lidar is None:
            return None
        self._lidar_frame = frame = await asyncio.to_thread(self._lidar.latest)
        if frame is None or frame.seq == self._lidar_sent:
            return None
        self._lidar_sent = frame.seq
        return list(frame.points)

    def lidar_info(self) -> dict[str, Any] | None:
        if self._lidar is None:
            return None
        frame = self._lidar_frame
        return {
            "source": frame.source if frame else None,
            "age_ms": round((time.monotonic() - frame.stamp) * 1000) if frame else None,
            "points": len(frame.points) if frame else 0,
            **self._lidar.diagnostics(),
        }

    def info(self) -> dict[str, Any]:
        # TODO：从固件接口读取真实 SN / 固件版本
        return {"model": self._model, "firmware": None, "sn": None, "ip": None}

    def skills(self) -> list[dict[str, Any]]:
        return [
            {
                "name": s.metadata.name,
                "description": s.metadata.description,
                "tags": list(s.metadata.tags),
                "motion": s.metadata.name not in NON_MOTION_SKILLS,
            }
            for s in self.runtime.registry.list()
        ]

    # ───────── 执行 ─────────

    @staticmethod
    async def _native(awaitable) -> Any:
        from robot import RobotCommandError

        try:
            return await awaitable
        except RobotCommandError as e:
            raise AdapterError(str(e)) from e

    async def _skill(self, name: str, **arguments: Any) -> None:
        if not self.runtime.registry.exists(name):
            raise AdapterError(f"Go2Agent 未注册技能 {name}")
        result = await self.runtime.execute(name, **arguments)
        if not result.success:
            code = getattr(result.failure_code, "value", None)
            raise AdapterError(
                f"{name}: {result.message or result.status.value}" + (f" ({code})" if code else "")
            )

    async def move(self, vx: float, vy: float, wz: float) -> None:
        if not all(math.isfinite(v) for v in (vx, vy, wz)):
            raise AdapterError("速度必须是有限数")
        # 遥操作接管：中断正在执行的技能（舞蹈、跟随等），避免争用 mobile_base
        await self.runtime.cancel_active()
        await self._native(self.robot.move_velocity(vx, vy, wz))

    async def stop(self) -> None:
        await self._skill("stop")

    async def damp(self) -> None:
        await self.runtime.cancel_active()
        await self._native(self.robot.execute_loco_action("damp"))
        self._mode = "damp"

    async def set_mode(self, mode: str) -> None:
        skill = MODE_SKILLS.get(mode)
        if skill is None:
            raise AdapterError(f"Go2 暂不支持模式 {mode}")
        await self._skill(skill)
        self._mode = mode

    async def action(self, name: str, params: dict[str, Any]) -> None:
        await self._skill(name, **(params or {}))

    async def telemetry(self) -> Telemetry:
        state = await self.robot.get_state()
        d = state.details
        if not self._simulated and not d.get("telemetry_available"):
            raise AdapterError("尚未收到 rt/sportmodestate")

        def triple(key: str) -> tuple[float, float, float]:
            v = tuple(d.get(key) or ())
            return (float(v[0]), float(v[1]), float(v[2])) if len(v) >= 3 else (0.0, 0.0, 0.0)

        vel, rpy, pos = triple("velocity_m_s"), triple("rpy_rad"), triple("position_m")
        return Telemetry(
            battery=None,  # TODO：Go2Agent 未订阅 rt/lowstate
            vx=vel[0],
            vy=vel[1],
            roll=rpy[0],
            pitch=rpy[1],
            yaw=rpy[2],
            pose=Pose(x=pos[0], y=pos[1], yaw=rpy[2]),
            # 指令成功不等于实际姿态已经改变；原始 sport_mode 保留在 extra。
            mode=self._mode if self._simulated else None,
            extra={
                "sport_mode": d.get("mode"),
                "gait_type": d.get("gait_type"),
                "error_code": d.get("error_code"),
                "hardware": state.hardware,
                "unavailable": ["battery", "voltage", "current", "wz", "acc"],
                "lidar": self.lidar_info(),
            },
        )
