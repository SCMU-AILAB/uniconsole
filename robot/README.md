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

## 已有 Go2Agent 环境的部署

狗端已有可用的 Go2Agent 与原生 bindings 时，优先复用该环境（不会更新 Go2Agent 或覆盖其本地修改）：

1. 将 `robot/` 同步到狗端 `~/uniconsole/robot`，排除 `.env`、`.venv` 和缓存。
2. 创建权限为 `600` 的 `.env`，填写服务器注册设备返回的 `DEVICE_ID` / `DEVICE_TOKEN`。
   使用 `ADAPTER=go2agent`、`NETWORK_INTERFACE=eth0`、`API_HOST=127.0.0.1`、`API_PORT=18000`。
   `ESTOP_MODE=stop` 使用 StopMove；若现场选择阻尼卸力，则配置 `damp`。
3. 确认没有其他 Go2Agent / DDS 控制进程，然后运行：

   ```bash
   cd ~/uniconsole/robot
   bash deploy/install-local-go2.sh ~/Go2Agent
   loginctl enable-linger "$USER"  # 使用户服务在退出 SSH 后及开机时继续运行
   systemctl --user status uniagent
   journalctl --user -u uniagent -n 50
   curl http://127.0.0.1:18000/health
   ```

安装脚本使用 Go2Agent 同版本 Python，在独立 uv 环境中引用原有 site-packages 和源码。
日常更新后使用 `systemctl --user restart uniagent`，停止使用 `systemctl --user stop uniagent`。
不要同时手动启动第二个 uniagent。

长连接在服务端指定的心跳超时后立即清理指令任务并停止；重连不会重放旧指令。
服务退出会等待网络任务结束、执行停止，再关闭 DDS。遥测缺失时不发送模拟帧。

2026-11-13 真机联调：ARM64 狗端、eth0 DDS、设备 `go2-cf-01`，验证真实姿态/位置上传、
StopMove 回执和急停演练回执。回执表示 SDK 接受命令，走动/起身未在本次联调中执行。
相机、点云、低层电池/关节数据仍需通过 Go2Agent 提供。
