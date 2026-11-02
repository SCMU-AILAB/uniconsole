"""机器人端 FastAPI 服务。

职责：
1. 进程宿主：初始化执行后端（mock / Go2Agent）、安全看门狗、与服务器的长连接；
2. 本地 API：现场调试、健康检查（供 systemd / 运维探活）。

本地控制接口需要 `X-Local-Token`（LOCAL_API_TOKEN），为空时只开放只读接口和急停。
注意：本地控制绕过了服务器的控制权租约，只用于现场调试；API 仅限可信网络。
"""

import asyncio
import hmac
import logging
from contextlib import asynccontextmanager
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException

from . import __version__
from .adapters import AdapterError, create_backend
from .config import Settings
from .controller import CommandRejected, Controller
from .link import ServerLink
from .protocol import PROTOCOL_VERSION, Command, ReleaseEstopCmd, Telemetry

log = logging.getLogger(__name__)


def create_app(settings: Settings | None = None, connect_server: bool = True) -> FastAPI:
    settings = settings or Settings.from_env()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        backend = create_backend(settings)
        await backend.connect()
        controller = Controller(backend, settings)
        link = ServerLink(controller)
        controller.on_event = link.emit_event
        app.state.controller = controller
        app.state.link = link

        tasks = [asyncio.ensure_future(controller.watchdog())]
        if connect_server:
            tasks.append(asyncio.ensure_future(link.run_forever()))
        log.info("机器人代理已启动：设备 %s，后端 %s", settings.device_id or "-", settings.adapter)
        try:
            yield
        finally:
            for t in tasks:
                t.cancel()
            try:
                await controller.stop()
            except AdapterError:
                log.exception("退出时停止失败")
            await backend.close()

    app = FastAPI(title="UniConsole Robot Agent", version=__version__, lifespan=lifespan)

    def controller() -> Controller:
        return app.state.controller

    Ctl = Annotated[Controller, Depends(controller)]

    def require_local_token(x_local_token: Annotated[str, Header()] = "") -> None:
        expected = settings.local_api_token
        if not expected:
            raise HTTPException(403, "未配置 LOCAL_API_TOKEN，本地控制已禁用")
        if not hmac.compare_digest(x_local_token, expected):
            raise HTTPException(401, "X-Local-Token 无效")

    @app.get("/health")
    def health(c: Ctl):
        link: ServerLink = app.state.link
        return {
            "ok": True,
            "device_id": settings.device_id,
            "adapter": settings.adapter,
            "server_connected": link.connected,
            "server_error": link.last_error,
            "estop": c.estop,
            "moving": c.moving,
        }

    @app.get("/info")
    def info(c: Ctl):
        return {
            **c.backend.info(),
            "device_id": settings.device_id,
            "protocol": PROTOCOL_VERSION,
            "agent_version": __version__,
            "capabilities": c.backend.capabilities,
            "speed_level": c.speed_level,
            "speed_limit": c.speed_limit,
        }

    @app.get("/skills")
    def skills(c: Ctl):
        return c.backend.skills()

    @app.get("/telemetry", response_model=Telemetry)
    async def telemetry(c: Ctl):
        try:
            return await c.backend.telemetry()
        except AdapterError as e:
            raise HTTPException(503, str(e))

    @app.post("/commands", dependencies=[Depends(require_local_token)])
    async def command(cmd: Command, c: Ctl):
        try:
            await c.handle(cmd)
        except CommandRejected as e:
            raise HTTPException(423, str(e))
        except AdapterError as e:
            raise HTTPException(500, str(e))
        return {"ok": True}

    # 急停不需要令牌：任何能访问到机器人的人都可以触发（HANDOFF §8.1）
    @app.post("/estop")
    async def estop(c: Ctl):
        await c.trigger_estop(source="local_api")
        return {"estop": True}

    @app.post("/estop/release", dependencies=[Depends(require_local_token)])
    async def release(c: Ctl):
        await c.handle(ReleaseEstopCmd())
        return {"estop": False}

    return app
