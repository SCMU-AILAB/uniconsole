-- 多机联调（Fleet.dc.html）、告警中心（Alerts.dc.html）按前端模型补字段

-- ───────── 联调会话 ─────────
CREATE SEQUENCE fleet_session_number_seq;
ALTER TABLE fleet_sessions
    ADD COLUMN number           INTEGER NOT NULL DEFAULT nextval('fleet_session_number_seq'),
    ADD COLUMN started_at       TIMESTAMPTZ,
    ADD COLUMN preset_id        TEXT,
    ADD COLUMN control_mode     TEXT NOT NULL DEFAULT '领队-跟随',
    ADD COLUMN clock_sync       TEXT NOT NULL DEFAULT 'PTP · 局域网',
    ADD COLUMN lost_link_action TEXT NOT NULL DEFAULT '原地趴下',
    ADD COLUMN last_receipt     JSONB;
ALTER SEQUENCE fleet_session_number_seq OWNED BY fleet_sessions.number;
UPDATE fleet_sessions SET started_at = created_at WHERE active;

CREATE TABLE fleet_presets (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    device_ids TEXT[] NOT NULL DEFAULT '{}',
    formation  formation NOT NULL DEFAULT 'line',
    spacing    REAL NOT NULL DEFAULT 1.0,
    created_by UUID REFERENCES members(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ───────── 告警 ─────────
ALTER TABLE alert_rules ADD COLUMN metric_label TEXT;
UPDATE alert_rules SET metric_label = CASE metric
    WHEN 'max_motor_temp' THEN '电机最高温度（°C）'
    WHEN 'battery'        THEN '电量（%）'
    WHEN 'latency_ms'     THEN '通信延迟（ms）'
    ELSE NULL END;

ALTER TABLE alerts
    ADD COLUMN metric_label   TEXT,
    ADD COLUMN threshold      DOUBLE PRECISION,
    ADD COLUMN location       TEXT,
    ADD COLUMN assignee_id    UUID REFERENCES members(id) ON DELETE SET NULL,
    ADD COLUMN silenced_until TIMESTAMPTZ,
    ADD COLUMN recording_id   UUID;

-- 时间线圆点颜色：critical / warning = 触发，neutral = 自动动作与通知，info = 人工处理
ALTER TABLE alert_events ADD COLUMN tone TEXT NOT NULL DEFAULT 'neutral'
    CHECK (tone IN ('critical', 'warning', 'info', 'neutral', 'success'));
UPDATE alert_events SET tone = CASE level
    WHEN 'critical' THEN 'critical'
    WHEN 'warning'  THEN 'warning'
    WHEN 'note'     THEN 'info'
    ELSE 'neutral' END;
