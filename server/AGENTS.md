# UniConsole Server — Agent 指南

Rust 后端：机器人 ⇄ 服务器 ⇄ 前端 的中枢。axum 0.8 + tokio + sqlx 0.9（PostgreSQL），用 Cargo 管理。

> **一定不要将自己加入仓库的 contributor。** 不要在提交信息、作者字段、`Cargo.toml` 的 `authors`、
> README 或任何文件中添加 AI / Agent 的署名或 Co-Authored-By。

## 常用命令

```bash
cp .env.example .env              # 首次：填 DATABASE_URL / JWT_SECRET / BOOTSTRAP_*
docker compose up -d db           # 或本机 Postgres 17
cargo run                         # 启动时自动执行 migrations/
cargo test --workspace            # 单元测试（不需要数据库）
cargo fmt --all && cargo clippy --workspace --all-targets   # 提交前必须零警告
```

## 部署

开发服务器 `yaoyifeng@192.168.0.239`，服务地址 `http://192.168.0.239:8800`（systemd 服务 `uniconsole-server`，
Postgres 17 跑在 Docker 容器 `uniconsole-db`，只监听本机）。

```bash
deploy/deploy.sh                 # 同步代码 → 服务器上 release 编译 → 重启服务
deploy/deploy.sh <host> --setup  # 新机器首次部署（生成 .env、建数据库容器、装 systemd 服务）
ssh yaoyifeng@192.168.0.239 journalctl -u uniconsole-server -f   # 看日志
```

服务器上的 `.env`（数据库密码、JWT 密钥、初始管理员密码）只在服务器上，不进仓库、不会被 deploy 覆盖。

公网：frp 把 `1.13.195.109:8800` 映射到服务器的 8800（`frpc-uniconsole.service`，配置见
`deploy/frpc-uniconsole.toml.example`）。**用 IP 访问**：`silencecf.me` 未备案，腾讯云会把域名的 HTTP 请求
302 到拦截页。目前是明文 HTTP，上线前需要 HTTPS（备案域名 + 证书，或改用境外中转）。

## 结构（Cargo workspace）

依赖方向：`domain` ← `protocol` / `auth` ← `server`。底层 crate 不得反向依赖上层。

```
Cargo.toml               [workspace]：成员、workspace.package、统一的 workspace.dependencies
crates/
  domain/    uniconsole-domain    领域模型：枚举、数据库行、DTO（无 IO）。
                                  sqlx 派生在 feature "sqlx" 后面，只有 server 开启
  protocol/  uniconsole-protocol  WebSocket 协议（与 robot/src/uniagent/protocol.py 一一对应）
  auth/      uniconsole-auth      JWT、Argon2、机器人接入令牌、rbac 权限矩阵（Roles.dc.html），不依赖 Web 框架
  server/    uniconsole-server    lib + bin：
    src/main.rs          只做日志初始化并调用 app::run
    src/lib.rs           re-export：crate::models / crate::protocol / crate::auth（含 AuthUser 提取器）
    src/app.rs           建连接池、迁移、初始管理员、后台任务、路由与中间件、优雅退出
    src/config.rs  error.rs  state.rs  extract.rs
    src/realtime/        hub（连接表 / 回执 / 事件总线）、robot_ws、client_ws、webrtc（信令中继）、遥测批量入库
    src/services/        control（指令唯一入口）、leases、safety、alerting、access、audit、events、missions（任务调度与执行）、notify（告警通知与升级）、geofence（电子围栏）、fleet_timeline（联调时间轴播放）、
                         sessions（登录会话 / 限流）、members、recordings、settings（键值配置）
    src/routes/          REST，全部挂在 /api/v1
migrations/              sqlx 迁移（只增不改：新改动写新文件），由 app::MIGRATOR 嵌入
docs/API.md              接口与协议文档 —— 改接口必须同步更新
```

依赖管理：新增第三方依赖先加到根 `Cargo.toml` 的 `[workspace.dependencies]`，
成员 crate 中写 `xxx.workspace = true`；不要在成员里单独写版本号。

## 约定

- **所有指令都走 `services::control::execute`**：急停检查 → 控制权检查 → 限幅 → 下发 → 指令日志。
  不要在路由里直接调用 `hub.dispatch`。
- 安全规则（HANDOFF §8）：Stop / Estop 任何角色可触发、不需要控制权；急停中运动指令返回 423；
  运动指令必须由租约持有者发出；解除急停按策略需要管理者。
- 租约的获取 / 转移用带条件的 UPSERT 原子完成，内存缓存只做高频读取，写操作必须先写库再更新缓存。
- SQL 使用运行时 `sqlx::query_as`（不依赖编译期数据库）；动态 SQL 字符串需 `AssertSqlSafe`。
- JSON 字段 snake_case；枚举值与 `frontend/design/HANDOFF.md` §6 保持一致。
- 改 `crates/protocol` 时同步修改 `robot/src/uniagent/protocol.py` 与 `docs/API.md`，并补测试。
- 当前为单实例实现（hub 在进程内）；多实例扩展需引入 Redis / NATS / PG NOTIFY，不要假设已支持。

## 未完成（TODO）

接口形状都已在 `docs/API.md` 定下，以下能力目前返回 501 或只存数据：
机器人端本地执行围栏（服务端已按遥测执行并下发）、邮件 / 短信告警渠道、APNs / FCM 推送、
机器人端相机推流（WebRTC 信令已完成）、机器人端录制（视频 / 点云）与导出、固件 OTA / 回滚 / 重启 / 远程终端 / 诊断包、
智能体服务本身（服务端已做转发）、Go2Agent 端的 navigate_to / say 技能、电池健康数据。
