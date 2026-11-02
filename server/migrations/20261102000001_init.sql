-- UniConsole 初始 schema
-- 枚举值与前端 HANDOFF §6 数据模型保持一致

CREATE TYPE member_role       AS ENUM ('admin', 'owner', 'user', 'viewer');
CREATE TYPE device_kind       AS ENUM ('dog', 'humanoid');
CREATE TYPE device_status     AS ENUM ('online', 'busy', 'alert', 'charging', 'offline');
CREATE TYPE lease_holder_kind AS ENUM ('user', 'task', 'session');
CREATE TYPE request_state     AS ENUM ('pending', 'approved', 'denied', 'cancelled');
CREATE TYPE alert_severity    AS ENUM ('critical', 'warning', 'info');
CREATE TYPE alert_state       AS ENUM ('open', 'doing', 'closed');
CREATE TYPE formation         AS ENUM ('line', 'column', 'v', 'grid');
CREATE TYPE mission_state     AS ENUM ('running', 'scheduled', 'paused');
CREATE TYPE zone_type         AS ENUM ('ban', 'slow', 'whitelist', 'wall');

-- ───────────── 成员与权限 ─────────────
CREATE TABLE members (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handle        TEXT NOT NULL UNIQUE,
    name          TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    role          member_role NOT NULL DEFAULT 'viewer',
    color         TEXT NOT NULL DEFAULT '#8E8E93',
    expires_at    TIMESTAMPTZ,
    disabled      BOOLEAN NOT NULL DEFAULT FALSE,
    last_seen_at  TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ───────────── 设备 ─────────────
CREATE TABLE devices (
    id            TEXT PRIMARY KEY,                 -- 例：go2-01
    name          TEXT NOT NULL,                    -- 例：Alpha
    code          TEXT NOT NULL UNIQUE,             -- 例：GO2-01
    model         TEXT NOT NULL,                    -- 例：Unitree Go2 EDU
    kind          device_kind NOT NULL,
    sn            TEXT,
    firmware      TEXT,
    ip            TEXT,
    grp           TEXT,                             -- 分组：巡检队 / 研发测试
    owner_id      UUID REFERENCES members(id) ON DELETE SET NULL,
    token_hash    TEXT NOT NULL,                    -- 机器人接入令牌 sha256
    status        device_status NOT NULL DEFAULT 'offline',
    location      TEXT,
    current_task  TEXT,
    last_seen_at  TIMESTAMPTZ,
    meta          JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 设备授权给使用者（owner 之外）
CREATE TABLE device_grants (
    member_id  UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (member_id, device_id)
);

-- ───────────── 遥测（抽样持久化，建议生产环境改用 TimescaleDB hypertable） ─────────────
CREATE TABLE telemetry (
    device_id      TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    ts             TIMESTAMPTZ NOT NULL,
    battery        REAL,
    vx             REAL, vy REAL, wz REAL,
    roll           REAL, pitch REAL, yaw REAL,
    voltage        REAL,
    current        REAL,
    max_motor_temp REAL,
    data           JSONB NOT NULL,                  -- 完整报文（关节温度、足端力等）
    PRIMARY KEY (device_id, ts)
);

-- ───────────── 联调会话（先建，租约要引用） ─────────────
CREATE TABLE fleet_sessions (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    owner_id   UUID NOT NULL REFERENCES members(id),
    device_ids TEXT[] NOT NULL DEFAULT '{}',
    leader_id  TEXT,
    formation  formation NOT NULL DEFAULT 'line',
    spacing    REAL NOT NULL DEFAULT 1.0,
    timeline   JSONB NOT NULL DEFAULT '[]'::jsonb,  -- TrackAction[]
    active     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ───────────── 地图与任务 ─────────────
CREATE TABLE missions (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    map_id     TEXT NOT NULL,
    waypoints  JSONB NOT NULL DEFAULT '[]'::jsonb,  -- Waypoint[]
    schedule   TEXT,                                -- cron 表达式或描述
    assignee   JSONB NOT NULL DEFAULT '{}'::jsonb,  -- {kind: device|preset, id}
    state      mission_state NOT NULL DEFAULT 'scheduled',
    created_by UUID REFERENCES members(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ───────────── 控制权租约 ─────────────
-- 每台设备同一时刻最多一个持有者（主键保证）
CREATE TABLE leases (
    device_id     TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
    holder_kind   lease_holder_kind NOT NULL,
    holder_id     UUID REFERENCES members(id) ON DELETE CASCADE,
    task_id       UUID REFERENCES missions(id) ON DELETE CASCADE,
    session_id    UUID REFERENCES fleet_sessions(id) ON DELETE CASCADE,
    source        TEXT NOT NULL,                    -- 单机操控 / 联调会话 #12 / 仓库夜巡
    acquired_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ,                      -- NULL = 随会话/任务
    CHECK (
        (holder_kind = 'user'    AND holder_id  IS NOT NULL) OR
        (holder_kind = 'task'    AND task_id    IS NOT NULL) OR
        (holder_kind = 'session' AND session_id IS NOT NULL)
    )
);

CREATE TABLE lease_requests (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id     TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    requester_id  UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    reason        TEXT NOT NULL DEFAULT '',
    expected_secs INTEGER NOT NULL DEFAULT 300,
    state         request_state NOT NULL DEFAULT 'pending',
    decided_by    UUID REFERENCES members(id) ON DELETE SET NULL,
    decided_at    TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX lease_requests_pending ON lease_requests (device_id, created_at) WHERE state = 'pending';

-- ───────────── 指令日志 ─────────────
CREATE TABLE command_log (
    id         UUID PRIMARY KEY,
    device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    actor_id   UUID REFERENCES members(id) ON DELETE SET NULL,
    command    JSONB NOT NULL,
    ok         BOOLEAN,
    error      TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    acked_at   TIMESTAMPTZ
);
CREATE INDEX command_log_device_ts ON command_log (device_id, created_at DESC);

-- ───────────── 告警 ─────────────
CREATE TABLE alert_rules (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name          TEXT NOT NULL,
    metric        TEXT NOT NULL,                    -- max_motor_temp / battery / latency_ms ...
    op            TEXT NOT NULL CHECK (op IN ('>', '<', '>=', '<=')),
    threshold     DOUBLE PRECISION NOT NULL,
    duration_secs INTEGER NOT NULL DEFAULT 0,
    severity      alert_severity NOT NULL,
    auto_action   TEXT,                             -- slow / stop / dock / NULL
    enabled       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE alerts (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    severity   alert_severity NOT NULL,
    state      alert_state NOT NULL DEFAULT 'open',
    title      TEXT NOT NULL,
    device_id  TEXT REFERENCES devices(id) ON DELETE CASCADE,
    rule_id    UUID REFERENCES alert_rules(id) ON DELETE SET NULL,
    metric     TEXT,
    peak       DOUBLE PRECISION,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    closed_at  TIMESTAMPTZ
);
CREATE INDEX alerts_state_ts ON alerts (state, created_at DESC);
-- 同一设备同一规则只允许一条未关闭告警（去重）
CREATE UNIQUE INDEX alerts_open_dedupe ON alerts (device_id, rule_id) WHERE state <> 'closed' AND rule_id IS NOT NULL;

CREATE TABLE alert_events (
    id       BIGSERIAL PRIMARY KEY,
    alert_id UUID NOT NULL REFERENCES alerts(id) ON DELETE CASCADE,
    ts       TIMESTAMPTZ NOT NULL DEFAULT now(),
    level    TEXT NOT NULL DEFAULT 'info',          -- critical / warning / info / action / note
    message  TEXT NOT NULL,
    actor_id UUID REFERENCES members(id) ON DELETE SET NULL
);

-- ───────────── 安全策略 ─────────────
CREATE TABLE zones (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    map_id     TEXT NOT NULL,
    name       TEXT NOT NULL,
    zone_type  zone_type NOT NULL,
    polygon    JSONB NOT NULL,                      -- [[x, y], ...] 地图坐标（米）
    rule       TEXT NOT NULL DEFAULT '',
    scope      JSONB NOT NULL DEFAULT '{"all": true}'::jsonb,
    schedule   TEXT NOT NULL DEFAULT '始终',
    action     TEXT NOT NULL DEFAULT '',
    enabled    BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 单行表：全局急停状态 + 安全策略开关
CREATE TABLE safety_state (
    id          SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    global_estop BOOLEAN NOT NULL DEFAULT FALSE,
    estop_by    UUID REFERENCES members(id) ON DELETE SET NULL,
    estop_at    TIMESTAMPTZ,
    policies    JSONB NOT NULL
);
INSERT INTO safety_state (policies) VALUES ('{
  "auto_dock": true,
  "dock_threshold_pct": 20,
  "heartbeat_timeout_ms": 1500,
  "disconnect_action": "stop",
  "lease_expire_action": "stop_and_release",
  "max_speed_mps": 1.5,
  "max_yaw_rate": 2.0,
  "human_stop": true,
  "min_device_distance_m": 0.8,
  "fall_detection": true,
  "collision_detection": true,
  "edge_detection": true,
  "estop_release_requires_manager": true
}'::jsonb);

-- ───────────── 审计 ─────────────
CREATE TABLE audit_log (
    id         BIGSERIAL PRIMARY KEY,
    ts         TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id   UUID REFERENCES members(id) ON DELETE SET NULL,
    actor_name TEXT NOT NULL,
    action     TEXT NOT NULL,
    target     TEXT NOT NULL DEFAULT '',
    client     TEXT NOT NULL DEFAULT '',
    detail     JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX audit_log_ts ON audit_log (ts DESC);

-- 默认告警规则（Alerts.dc.html）
INSERT INTO alert_rules (name, metric, op, threshold, duration_secs, severity, auto_action) VALUES
  ('电机过热',   'max_motor_temp', '>', 60,  10, 'critical', 'slow'),
  ('低电量',     'battery',        '<', 20,  0,  'warning',  NULL),
  ('通信延迟高', 'latency_ms',     '>', 300, 15, 'info',     NULL);
