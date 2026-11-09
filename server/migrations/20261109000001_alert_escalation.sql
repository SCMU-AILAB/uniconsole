-- 告警升级：超过值班设置的 escalate_after_secs 仍未确认时升级一次
ALTER TABLE alerts ADD COLUMN escalated_at TIMESTAMPTZ;
CREATE INDEX alerts_open_unescalated ON alerts (created_at) WHERE state = 'open' AND escalated_at IS NULL;
