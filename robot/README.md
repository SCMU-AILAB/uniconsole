# UniConsole Robot Agent（uniagent）

运行在机器人（Go2 狗端电脑）上的代理进程：

```
                 ┌──────────────── uniagent（本项目）────────────────┐
UniConsole 服务器 ◀─WS 外连─ ServerLink ─▶ Controller（急停 / 限幅 / 300 ms 看门狗）
                 │                              │                    │
                 │   FastAPI 本地 API ──────────┤                    │
                 │                              ▼                    │
                 │                    Backend（mock | go2agent）      │
                 └──────────────────────────────┼────────────────────┘
                                                ▼
                         Go2Agent：SkillRuntime + UnitreeGo2Adapter（唯一 DDS 所有者）
```

- **机器人主动外连**服务器 `/api/v1/robot/ws`（适配 NAT / 4G），指令经同一条连接下发；断线即停止，指数退避重连。
- **FastAPI** 是进程宿主，同时提供本地调试 API：`/health`、`/info`、`/telemetry`、`/skills`、`/commands`、`/estop`。
- **执行层复用 [Go2Agent](https://github.com/SCMU-AILAB/Go2Agent)**：服务器的 `action` 指令 = `SkillRuntime.execute(技能名)`，
  与 Go2Agent 文本 / 视觉 Agent 共享同一套 44 个 Go2 技能；摇杆 `move` 先取消正在运行的技能，再调用 `move_velocity`。
- 协议定义：`src/uniagent/protocol.py`，与 `server/crates/protocol/src/lib.rs` 一一对应，详见 `server/docs/API.md`。

## 开发

```bash
uv sync                          # 安装依赖（含 dev 组）
cp .env.example .env             # 填 DEVICE_ID / DEVICE_TOKEN（服务器注册设备时返回）
uv run uniagent                  # 默认 ADAPTER=mock，无需硬件
uv run pytest
uv run ruff check src tests
```

## 真机（Go2）

```bash
uv sync --extra go2              # 拉取 Go2Agent（git 依赖）
# 另需在狗端安装 Go2Agent 依赖的原生 unitree_sdk2_cpp bindings（同级项目 unitree_sdk2_bindings）
ADAPTER=go2agent NETWORK_INTERFACE=eth0 uv run uniagent
```

开发机上可用 `ADAPTER=go2agent GO2AGENT_SIMULATED=1` 走 Go2Agent 的 `SimulatedRobotAdapter`，
验证技能目录与指令映射而不连接 DDS。

注意：

- 同一台狗上 **只能有一个 DDS 所有者**。uniagent 以 `go2agent` 模式运行时，不要同时启动 Go2Agent 的
  `app.api` / `app.main` / `app.perception`。
- Go2Agent 默认应用限速前后 / 横移 0.3 m/s、转向 0.6 rad/s，且越界直接拒绝；Controller 会把速度限幅到
  `min(服务器策略, 速度档位, GO2_MAX_*)`，可通过 `.env` 中的 `GO2_MAX_FORWARD` 等放宽。
- Go2Agent 目前只订阅 `rt/sportmodestate`，遥测中没有电量 / 关节温度（`battery` 为空）。
  TODO：订阅 `rt/lowstate` 补齐电量、关节温度、足端力。
- SDK 返回 0 只表示命令被接受，不代表动作物理完成。软件急停（`damp` / `stop_move`）不是物理急停，现场必须备好遥控器。
