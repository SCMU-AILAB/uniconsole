-- 设备分组、设备事件、指令日志补充字段、安全策略改用前端字段名、围栏 scope 改为显示文本

-- ───────── 设备分组（侧边栏「设备分组」筛选） ─────────
CREATE TABLE device_groups (
    id         TEXT PRIMARY KEY,                    -- 例：patrol
    name       TEXT NOT NULL,                       -- 例：巡检队
    tone       TEXT NOT NULL DEFAULT 'neutral'
               CHECK (tone IN ('online', 'busy', 'warning', 'action', 'critical', 'neutral')),
    sort       INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE devices ADD COLUMN group_id TEXT REFERENCES device_groups(id) ON DELETE SET NULL;
INSERT INTO device_groups (id, name)
SELECT 'g' || row_number() OVER (ORDER BY grp), grp
FROM (SELECT DISTINCT grp FROM devices WHERE grp IS NOT NULL AND grp <> '') g;
UPDATE devices d SET group_id = g.id FROM device_groups g WHERE g.name = d.grp;
ALTER TABLE devices DROP COLUMN grp;

-- ───────── 设备事件（Main 页「最近事件」、设备详情） ─────────
CREATE TABLE device_events (
    id        BIGSERIAL PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
    at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    text      TEXT NOT NULL,
    tone      TEXT NOT NULL DEFAULT 'neutral'
              CHECK (tone IN ('info', 'success', 'warning', 'critical', 'neutral'))
);
CREATE INDEX device_events_device_at ON device_events (device_id, at DESC);

-- ───────── 遥测 / 指令日志 ─────────
ALTER TABLE telemetry ADD COLUMN latency_ms INTEGER;
ALTER TABLE command_log
    ADD COLUMN actor_name TEXT NOT NULL DEFAULT '系统',
    ADD COLUMN error_code TEXT;            -- estop_active / forbidden / robot_offline / timeout / robot_error
UPDATE command_log SET actor_name = COALESCE(command->>'by', '系统'),
                       command = COALESCE(command->'command', command)
WHERE command ? 'by';

-- ───────── 安全策略：改用前端 SafetyPolicies 的字段名 ─────────
ALTER TABLE safety_state ADD COLUMN last_drill_at TIMESTAMPTZ;
UPDATE safety_state SET policies = jsonb_build_object(
    'auto_dock',               COALESCE(policies->'auto_dock', 'true'),
    'dock_threshold',          COALESCE(policies->'dock_threshold_pct', '20'),
    'heartbeat_timeout_ms',    COALESCE(policies->'heartbeat_timeout_ms', '1500'),
    'lost_link_action',        COALESCE(policies->'disconnect_action', '"stop"'),
    'lease_expiry_action',     CASE WHEN policies->>'lease_expire_action' = 'release'
                                    THEN '"stop_only"'::jsonb ELSE '"stop_release"'::jsonb END,
    'speed_limit',             COALESCE(policies->'max_speed_mps', '1.5'),
    'max_yaw_rate',            COALESCE(policies->'max_yaw_rate', '2.0'),
    'stop_near_people',        COALESCE(policies->'human_stop', 'true'),
    'min_distance',            COALESCE(policies->'min_device_distance_m', '0.8'),
    'fall_detection',          COALESCE(policies->'fall_detection', 'true'),
    'collision_detection',     COALESCE(policies->'collision_detection', 'true'),
    'cliff_detection',         COALESCE(policies->'edge_detection', 'true'),
    'release_needs_manager',   COALESCE(policies->'estop_release_requires_manager', 'true'),
    'hardware_remotes',        '0',
    'lease_term_secs',         '300',
    'idle_release_secs',       '600',
    'disconnect_stop_secs',    '3',
    'disconnect_release_secs', '60'
) WHERE id = 1;

-- ───────── 联调：全局急停时会话暂停 ─────────
ALTER TABLE fleet_sessions ADD COLUMN paused BOOLEAN NOT NULL DEFAULT FALSE;

-- ───────── 围栏：scope 前端按字符串显示 ─────────
ALTER TABLE zones ALTER COLUMN scope DROP DEFAULT;
ALTER TABLE zones ALTER COLUMN scope TYPE TEXT USING
    CASE WHEN scope = '{"all": true}'::jsonb THEN '全部设备' ELSE scope::text END;
ALTER TABLE zones ALTER COLUMN scope SET DEFAULT '全部设备';
ALTER TABLE zones ALTER COLUMN schedule SET DEFAULT '全天';
