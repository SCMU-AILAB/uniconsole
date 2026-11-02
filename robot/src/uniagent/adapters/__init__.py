from ..config import Settings
from .base import AdapterError, RobotBackend, VelocityLimits


def create_backend(settings: Settings) -> RobotBackend:
    if settings.adapter == "mock":
        from .mock import MockBackend

        return MockBackend()
    if settings.adapter == "go2agent":
        from .go2agent import Go2AgentBackend

        return Go2AgentBackend(
            network_interface=settings.network_interface,
            domain_id=settings.domain_id,
            model=settings.model,
            limits=VelocityLimits(settings.go2_max_forward, settings.go2_max_lateral, settings.go2_max_yaw),
            simulated=settings.go2agent_simulated,
        )
    raise ValueError(f"未知后端 {settings.adapter}（可选：mock、go2agent）")


__all__ = ["AdapterError", "RobotBackend", "VelocityLimits", "create_backend"]
