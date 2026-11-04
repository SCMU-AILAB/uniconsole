-- 地图、任务字段、今日排期、录制、设备日志
-- 坐标约定：米，原点在地图左下角，x 向右、y 向上；角度弧度，逆时针为正，0 指向 +x（ROS REP-103）

CREATE TABLE maps (
    id            TEXT PRIMARY KEY,                  -- 例：b2
    name          TEXT NOT NULL,                     -- 例：B 区 · 巡检层
    short_name    TEXT NOT NULL DEFAULT '',          -- 例：B 区巡检层
    width_m       REAL NOT NULL,
    height_m      REAL NOT NULL,
    origin        JSONB NOT NULL DEFAULT '[0, 0]'::jsonb,   -- 地图左下角在世界坐标中的位置
    resolution_cm REAL NOT NULL DEFAULT 5,
    areas         JSONB NOT NULL DEFAULT '[]'::jsonb,       -- [{polygon: [[x,y],…], label, outline}]
    chargers      JSONB NOT NULL DEFAULT '[]'::jsonb,       -- [[x, y], …]
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE missions
    ADD COLUMN completed    INTEGER NOT NULL DEFAULT 0,      -- 本轮已完成的点位数
    ADD COLUMN loop_enabled BOOLEAN NOT NULL DEFAULT FALSE;

-- 今日排期（Missions.dc.html 底部时间轴）
CREATE TABLE schedule_entries (
    id         BIGSERIAL PRIMARY KEY,
    device_id  TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    starts_at  TIMESTAMPTZ NOT NULL,
    ends_at    TIMESTAMPTZ NOT NULL CHECK (ends_at > starts_at),
    label      TEXT NOT NULL,
    kind       TEXT NOT NULL DEFAULT 'other' CHECK (kind IN ('run', 'charge', 'other')),
    mission_id UUID REFERENCES missions(id) ON DELETE SET NULL
);
CREATE INDEX schedule_entries_range ON schedule_entries (starts_at, ends_at);

-- 录制：目前只回放服务端持久化的遥测与指令（视频 / 点云需要机器人端录制，见 API.md）
CREATE TABLE recordings (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    device_ids TEXT[] NOT NULL,
    start_at   TIMESTAMPTZ NOT NULL,
    end_at     TIMESTAMPTZ NOT NULL CHECK (end_at > start_at),
    tags       TEXT[] NOT NULL DEFAULT '{}',             -- alert | patrol | fleet | manual
    map_id     TEXT,
    source_id  TEXT,                                     -- 告警 id / 联调会话 id / 任务 id
    clip_of    UUID REFERENCES recordings(id) ON DELETE SET NULL,
    created_by UUID REFERENCES members(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX recordings_start ON recordings (start_at DESC);

-- 设备日志（设备运维页）：机器人上报的 event 全部落库
CREATE TABLE device_logs (
    id        BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    level     TEXT NOT NULL CHECK (level IN ('info', 'warn', 'error')),
    message   TEXT NOT NULL
);
CREATE INDEX device_logs_at ON device_logs (at DESC);
CREATE INDEX device_logs_device_at ON device_logs (device_id, at DESC);
