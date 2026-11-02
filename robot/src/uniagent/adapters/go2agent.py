"""Go2 后端：复用 Go2Agent 的 Skill Runtime 与 UnitreeGo2Adapter。

Go2Agent 约定「Robot Skill Runtime 是唯一动作执行边界」，因此：
- 服务器 `action` / `set_mode` 指令 → `SkillRuntime.execute(技能名)`，与 Go2Agent 的文本 / 视觉 Agent
  共用同一技能目录（register_go2_skills，44 个技能），参数校验、资源锁、感知前提都由 Go2Agent 负责；
- `stop` → 执行 `stop` 技能（取消正在运行的技能并 StopMove）；
- 摇杆 `move` 是逐帧速度采样，没有对应的有限时长技能：先取消正在运行的技能，再调用
  `UnitreeGo2Adapter.move_velocity`（Go2 移动技能内部也是这样刷新速度的）。

UnitreeGo2Adapter 是进程内唯一的 DDS 所有者；不要同时运行 Go2Agent 自己的 app.api / app.main。
"""

import logging
import math
from typing import Any

from ..protocol import Pose, Telemetry
from .base import AdapterError, RobotBackend, VelocityLimits

log = logging.getLogger(__name__)

# 与 Go2Agent UnitreeGo2Config 默认值一致
GO2AGENT_DEFAULT_LIMITS = VelocityLimits(0.3, 0.3, 0.6)

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
    ) -> None:
        try:
            from core.runtime import SkillRuntime
            from robot import SimulatedRobotAdapter, UnitreeGo2Adapter, UnitreeGo2Config
            from skills import register_go2_skills
        except ImportError as e:  # pragma: no cover - 取决于安装方式
            raise AdapterError("未安装 Go2Agent：uv sync --extra go2") from e

        self._model = model
        self._simulated = simulated
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

    async def close(self) -> None:
        if not self._simulated:
            await self._native(self.robot.close())

    def info(self) -> dict[str, Any]:
        # TODO：从固件接口读取真实 SN / 固件版本
        return {"model": self._model, "firmware": None, "sn": None, "ip": None}

    def skills(self) -> list[dict[str, Any]]:
        return [
            {"name": s.metadata.name, "description": s.metadata.description, "tags": list(s.metadata.tags)}
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
            mode=self._mode,
            extra={
                "sport_mode": d.get("mode"),
                "gait_type": d.get("gait_type"),
                "error_code": d.get("error_code"),
                "hardware": state.hardware,
            },
        )
