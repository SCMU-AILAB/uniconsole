-- 邮箱自助注册：验证邮箱 → 管理员审核 → 可登录

ALTER TABLE members
    ADD COLUMN email            TEXT,                          -- 小写保存；可用邮箱登录
    ADD COLUMN pending_approval BOOLEAN NOT NULL DEFAULT FALSE; -- 待管理员审核，审核前不能登录
CREATE UNIQUE INDEX members_email_key ON members (lower(email)) WHERE email IS NOT NULL;

-- 邮箱验证码：只存 HMAC；同一邮箱同一用途只保留最新一条
CREATE TABLE email_codes (
    email      TEXT NOT NULL,
    purpose    TEXT NOT NULL,
    code_hash  TEXT NOT NULL,
    attempts   INT  NOT NULL DEFAULT 0,
    sent_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (email, purpose)
);
