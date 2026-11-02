# UniConsole Robot Agent — Agent 指南

运行在机器人（Go2 狗端电脑）上的代理：FastAPI 进程宿主 + WebSocket 外连服务器，
执行层复用 [Go2Agent](https://github.com/SCMU-AILAB/Go2Agent)。Python 3.12，用 **uv** 管理。

> **一定不要将自己加入仓库的 contributor。** 不要在提交信息、作者字段、`pyproject.toml` 的 `authors`、
> README 或任何文件中添加 AI / Agent 的署名或 Co-Authored-By。

## 常用命令

```bash
uv sync                    # 依赖（含 dev 组）；真机加 --extra go2 拉取 Go2Agent
uv run uniagent            # 读取当前目录 .env；默认 ADAPTER=mock
uv run pytest
uv run ruff check src tests && uv run ruff format src tests
uv add <pkg>               # 加依赖只用 uv，不要用 pip，不要手写 requirements.txt
```

## 结构

```
src/uniagent/
  protocol.py        与 server/crates/protocol/src/lib.rs 一一对应的消息模型（改动必须两边同步）
  config.py          环境变量配置
  controller.py      安全核心：急停、限幅、300 ms 看门狗、断线停止 —— 所有指令必经
  link.py            外连服务器、hello / welcome、遥测循环、指令回执、指数退避重连
  api.py             FastAPI：/health /info /skills /telemetry /commands /estop
  adapters/
    base.py          RobotBackend 异步接口（对齐 Go2Agent robot.base.RobotAdapter）
    mock.py          模拟机器人
    go2agent.py      Go2Agent SkillRuntime + UnitreeGo2Adapter
tests/
```

## 约定

- **Go2 动作一律通过 Go2Agent 的 `SkillRuntime.execute`**（它是唯一动作执行边界）。不要在本项目里
  直接调用 SDK / DDS，也不要另写一套 Go2 SDK 适配；缺少的能力先加到 Go2Agent。
- 例外：摇杆 `move` 是逐帧速度采样，先 `runtime.cancel_active()` 再 `move_velocity`。
- 同一台狗只能有一个 DDS 所有者：`go2agent` 后端运行时不能同时启动 Go2Agent 的 app.api / app.main。
- 安全优先：急停、停止永远不能被普通指令阻塞；新增运动类指令必须经过 Controller 的急停判断与限幅；
  不要放宽看门狗与断线停止逻辑。
- Go2Agent 越界速度会直接拒绝，Controller 负责先限幅到 `min(服务器策略, 档位, GO2_MAX_*)`。
- SDK 返回成功 ≠ 动作物理完成；软件急停 ≠ 物理急停。不要在文档或日志中暗示相反含义。
- 无硬件测试用 mock 或 `GO2AGENT_SIMULATED=1`，测试不得连接真实 DDS。
