"""机器人端安全控制核心。

无论指令来自服务器还是本地 API，都经过这里：
- 急停状态下拒绝一切运动指令；
- 按 min(服务器策略, 速度档位, 后端上限) 限幅；
- 看门狗：持续 move 中断超过 WATCHDOG_MS（默认 300 ms）自动停止；
- 与服务器断线时立即停止。
"""

import asyncio
import logging
import math
import time
from collections.abc import Awaitable, Callable

from .adapters import AdapterError, RobotBackend
from .config import Settings
from .protocol import (
    ActionCmd,
    EstopCmd,
    Event,
    MoveCmd,
    ReleaseEstopCmd,
    SetModeCmd,
    SetSpeedCmd,
    StopCmd,
    is_motion,
)

log = logging.getLogger(__name__)

SPEED_LIMITS = {"slow": 0.3, "normal": 0.8, "fast": 1.5}  # Control.dc.html 速度档位


class CommandRejected(Exception):
    pass


def _clamp(v: float, limit: float) -> float:
    if math.isnan(v):
        return 0.0
    return max(-limit, min(limit, v))


class Controller:
    def __init__(
        self,
        backend: RobotBackend,
        settings: Settings,
        on_event: Callable[[Event], Awaitable[None]] | None = None,
    ) -> None:
        self.backend = backend
        self.settings = settings
        self.on_event = on_event
        self.estop = False
        self.speed_level = "normal"
        self.max_speed = settings.max_speed_mps
        self.max_yaw = settings.max_yaw_rate
        self._moving = False
        self._last_move = 0.0
        self.lost_link_action = "stop"
        # 服务器下发的电子围栏（服务端按遥测执行；这里保存供本地执行）
        self.zones: list[dict] = []

    def apply_server_limits(self, max_speed: float, max_yaw: float) -> None:
        self.max_speed = min(self.settings.max_speed_mps, max_speed)
        self.max_yaw = min(self.settings.max_yaw_rate, max_yaw)

    @property
    def speed_limit(self) -> float:
        return min(self.max_speed, SPEED_LIMITS[self.speed_level])

    @property
    def moving(self) -> bool:
        return self._moving

    async def handle(self, cmd) -> None:
        """执行一条指令；失败抛 CommandRejected / AdapterError。"""
        if isinstance(cmd, EstopCmd):
            if cmd.drill:
                log.info("急停演练：链路正常（未驱动硬件）")
                return
            await self.trigger_estop(source="server")
            return
        if isinstance(cmd, ReleaseEstopCmd):
            self.estop = False
            log.warning("急停已解除")
            return
        if isinstance(cmd, StopCmd):
            await self.stop()
            return
        if is_motion(cmd) and self.estop:
            raise CommandRejected("急停中，拒绝运动指令")

        if isinstance(cmd, MoveCmd):
            lim = self.backend.limits
            vx = _clamp(cmd.vx, min(self.speed_limit, lim.forward_m_s))
            vy = _clamp(cmd.vy, min(self.speed_limit, lim.lateral_m_s))
            wz = _clamp(cmd.wz, min(self.max_yaw, lim.yaw_rad_s))
            self._last_move = time.monotonic()
            self._moving = any(abs(v) > 1e-3 for v in (vx, vy, wz))
            await self.backend.move(vx, vy, wz)
        elif isinstance(cmd, SetModeCmd):
            await self.backend.set_mode(cmd.mode)
            if cmd.mode in ("down", "damp"):
                self._moving = False
        elif isinstance(cmd, SetSpeedCmd):
            self.speed_level = cmd.level
            await self.backend.set_speed_level(cmd.level)
        elif isinstance(cmd, ActionCmd):
            if is_motion(cmd):
                self._moving = False  # 技能接管运动，看门狗不应再发 stop 打断它
            await self.backend.action(cmd.name, cmd.params or {})
        else:  # pragma: no cover
            raise CommandRejected(f"未知指令 {cmd!r}")

    async def stop(self) -> None:
        self._moving = False
        await self.backend.stop()

    async def trigger_estop(self, source: str) -> None:
        """急停：先置标志（之后的运动指令全部拒绝），再驱动硬件。"""
        self.estop = True
        self._moving = False
        log.warning("急停触发（来源：%s）", source)
        try:
            if self.settings.estop_mode == "damp":
                await self.backend.damp()
            else:
                await self.backend.stop()
        except AdapterError:
            log.exception("急停执行失败")
            raise
        finally:
            if source != "server" and self.on_event:
                await self.on_event(
                    Event(level="critical", code="estop", message=f"本地急停触发（{source}）")
                )

    async def on_link_lost(self) -> None:
        """与服务器断线：按服务器下发的策略处理（stop 原地停止 / down 趴下；dock 暂按 stop）。"""
        if self._moving:
            log.warning("与服务器断线，停止运动（策略 %s）", self.lost_link_action)
        try:
            await self.stop()
            if self.lost_link_action == "down" and not self.estop:
                await self.backend.set_mode("down")
        except AdapterError:
            log.exception("断线处理失败")

    async def watchdog(self) -> None:
        period = self.settings.watchdog_ms / 1000.0
        while True:
            await asyncio.sleep(0.05)
            if self._moving and time.monotonic() - self._last_move > period:
                log.info("看门狗：%d ms 未收到 move，自动停止", self.settings.watchdog_ms)
                try:
                    await self.stop()
                except AdapterError:
                    log.exception("看门狗停止失败")
