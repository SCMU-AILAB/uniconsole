"""硬件后端接口（异步），与 Go2Agent 的 `robot.base.RobotAdapter` 协议对齐。

新增机型 / 执行层只需实现 RobotBackend。所有方法都可能抛 AdapterError，
错误信息会通过 ack.error 回传服务器并显示在前端指令日志里。
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any, ClassVar

from ..protocol import Telemetry


class AdapterError(Exception):
    """硬件 / 技能执行失败。"""


@dataclass(frozen=True)
class VelocityLimits:
    """后端自身的速度上限（应用限制，不是硬件极限）。"""

    forward_m_s: float = 1.5
    lateral_m_s: float = 1.5
    yaw_rad_s: float = 2.0


class RobotBackend(ABC):
    capabilities: ClassVar[tuple[str, ...]] = ()
    limits: VelocityLimits = VelocityLimits()

    @abstractmethod
    async def connect(self) -> None:
        """初始化通信；不得发出任何运动指令。"""

    async def close(self) -> None:
        """释放通信资源；不负责停止（停止由 Controller 在关闭前完成）。"""

    @abstractmethod
    def info(self) -> dict[str, Any]:
        """{model, firmware, sn, ip}"""

    @abstractmethod
    async def move(self, vx: float, vy: float, wz: float) -> None:
        """发送一次速度指令（调用方负责持续刷新与停止）。"""

    @abstractmethod
    async def stop(self) -> None:
        """停止运动并取消正在执行的技能，保持姿态。"""

    @abstractmethod
    async def damp(self) -> None:
        """阻尼模式：电机卸力（软件急停）。"""

    @abstractmethod
    async def set_mode(self, mode: str) -> None: ...

    async def set_speed_level(self, level: str) -> None:
        """可选：机器人自带速度档位。默认只由 Controller 限幅。"""

    @abstractmethod
    async def action(self, name: str, params: dict[str, Any]) -> None:
        """执行一个技能 / 预置动作。"""

    def skills(self) -> list[dict[str, Any]]:
        """可用技能目录：[{name, description, tags}]，上报给服务器供前端展示。"""
        return []

    @abstractmethod
    async def telemetry(self) -> Telemetry: ...
