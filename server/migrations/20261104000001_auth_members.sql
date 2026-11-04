-- 认证与成员：服务端会话、邀请、二次验证、偏好；审计分类；通用配置表

-- 邀请制：受邀成员在首次打开邀请链接时设置密码，此前 password_hash 为空
ALTER TABLE members ALTER COLUMN password_hash DROP NOT NULL;
ALTER TABLE members
    ADD COLUMN invite_token_hash TEXT UNIQUE,
    ADD COLUMN invite_expires_at TIMESTAMPTZ,
    ADD COLUMN totp_secret       TEXT,                       -- 已开启的二次验证密钥
    ADD COLUMN totp_pending      TEXT,                       -- 正在绑定、尚未验证的密钥
    ADD COLUMN two_factor        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN preferences       JSONB   NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN video_only        BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN guest_link        BOOLEAN NOT NULL DEFAULT FALSE;

-- 登录会话与 API 令牌（JWT 的 sid 指向这里；吊销即失效）
CREATE TYPE session_kind AS ENUM ('login', 'token');
CREATE TABLE sessions (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    member_id    UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    kind         session_kind NOT NULL DEFAULT 'login',
    name         TEXT NOT NULL DEFAULT '',          -- 「MacBook Pro」或令牌名
    client       TEXT NOT NULL DEFAULT '',          -- X-Client：「macOS · 1.0.0」
    ip           TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL,
    revoked_at   TIMESTAMPTZ
);
CREATE INDEX sessions_member_active ON sessions (member_id) WHERE revoked_at IS NULL;

-- 系统推送（APNs / FCM）设备令牌
CREATE TABLE push_tokens (
    platform   TEXT NOT NULL CHECK (platform IN ('apns', 'fcm')),
    token      TEXT NOT NULL,
    member_id  UUID NOT NULL REFERENCES members(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (platform, token)
);

-- 审计分类（前端筛选用）
ALTER TABLE audit_log
    ADD COLUMN kind TEXT NOT NULL DEFAULT 'system'
        CHECK (kind IN ('control', 'alert', 'terminal', 'config', 'system'));
UPDATE audit_log SET client = '服务端' WHERE client = 'server';

-- 通用键值配置（通知渠道、值班、维护窗口、固件版本等不值得单独建表的配置）
CREATE TABLE server_settings (
    key        TEXT PRIMARY KEY,
    value      JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
