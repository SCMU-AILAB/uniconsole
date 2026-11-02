# UniConsole

宇树（Unitree）机器人管理与群控平台：单机操控、多机联调、控制权租约、安全策略与急停、告警、任务与审计。

```
┌──────────────────────┐   WebSocket 外连    ┌──────────────────────────┐   REST + WebSocket   ┌──────────────────┐
│ robot/  机器人代理    │ ─────────────────▶ │ server/  后端服务          │ ◀─────────────────── │ frontend/  客户端 │
│ Python · FastAPI · uv │   遥测 / 指令 / 回执 │ Rust · axum · PostgreSQL  │   设备 / 租约 / 告警   │ Flutter          │
│ 执行层：Go2Agent      │                    │                          │   实时遥测 / 摇杆      │ 桌面 + 移动       │
└──────────────────────┘                    └──────────────────────────┘                      └──────────────────┘
```

| 目录 | 说明 | 技术栈 |
|---|---|---|
| [`server/`](server/) | 中枢服务：鉴权与权限、设备与实时状态、控制权租约、急停与安全策略、告警引擎、多机联调、审计 | Rust（Cargo workspace）· axum · tokio · sqlx · PostgreSQL |
| [`robot/`](robot/) | 运行在机器人上的代理：外连服务器、安全看门狗、本地调试 API；Go2 执行层复用 [Go2Agent](https://github.com/SCMU-AILAB/Go2Agent) 的 Skill Runtime | Python 3.12 · FastAPI · uv |
| [`frontend/`](frontend/) | 跨平台控制台（macOS / Windows / Linux / iOS / Android），设计稿见 `frontend/design/` | Flutter · Riverpod |

接口与实时协议：[`server/docs/API.md`](server/docs/API.md)。

## 快速开始

### 1. 数据库

```bash
cd server
docker compose up -d db          # 或本机 PostgreSQL 17：创建 uniconsole 用户与数据库
```

### 2. 后端

```bash
cd server
cp .env.example .env             # 修改 JWT_SECRET（openssl rand -hex 32）与初始管理员密码
cargo run                        # 自动执行数据库迁移，监听 :8080
```

### 3. 机器人代理（无需硬件）

先用管理员账号注册一台设备，拿到只显示一次的接入令牌：

```bash
TOKEN=$(curl -s localhost:8080/api/v1/auth/login -H 'content-type: application/json' \
  -d '{"handle":"kanade","password":"<BOOTSTRAP_PASSWORD>"}' | jq -r .token)
curl -s localhost:8080/api/v1/devices -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -d '{"id":"go2-01","name":"Alpha","code":"GO2-01","model":"Unitree Go2 EDU","kind":"dog"}' | jq -r .token
```

```bash
cd robot
uv sync
cp .env.example .env             # 填 DEVICE_ID=go2-01 与上一步的 DEVICE_TOKEN
uv run uniagent                  # ADAPTER=mock：模拟机器人，持续上报遥测
```

真机（Go2）：`uv sync --extra go2`，并设置 `ADAPTER=go2agent`、`NETWORK_INTERFACE=eth0`，详见 [`robot/README.md`](robot/README.md)。

### 4. 前端

```bash
cd frontend
flutter pub get
flutter run -d macos
```

## 安全设计

- **急停永远可达**：任何角色都可以触发单机 / 全局急停，急停期间所有运动指令被拒绝；解除默认需要管理者。
- **控制权**：同一时刻一台设备只有一个控制者（租约），没有控制权时只读；租约过期自动停止并释放。
- **多层停止保护**：机器人端 300 ms 看门狗、与服务器断线即停、前端断线服务器补发停止。
- **限速**：服务器安全策略、速度档位、机器人后端上限三者取最小值。
- 软件急停不能替代物理急停，真机操作时请随身携带遥控器。

## 开发

| | 测试 | 规范 |
|---|---|---|
| server | `cargo test --workspace` | `cargo fmt --all && cargo clippy --workspace --all-targets` |
| robot | `uv run pytest` | `uv run ruff check src tests && uv run ruff format src tests` |
| frontend | `flutter test` | `flutter analyze` |

各子项目的协作约定见对应目录下的 `AGENTS.md`。
