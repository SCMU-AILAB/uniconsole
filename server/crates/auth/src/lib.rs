//! UniConsole 认证（JWT + Argon2 + 一次性令牌 + TOTP 二次验证）与权限（Roles.dc.html 权限矩阵）。
//!
//! 不依赖 Web 框架；HTTP 提取器在 `uniconsole-server` 的 `extract` 模块。
//!
//! 登录态由服务端 `sessions` 表管理：JWT 只携带成员 id 与会话 id（`sid`），
//! 角色、停用、退出登录都以数据库为准，修改后立即生效。

pub mod rbac;
pub mod totp;

pub use rbac::{Access, Perm, access};

use anyhow::anyhow;
use argon2::{
    Argon2,
    password_hash::{PasswordHasher, PasswordVerifier, phc::PasswordHash},
};
use chrono::Utc;
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    /// 成员 id
    pub sub: Uuid,
    /// 会话 id（sessions.id）
    pub sid: Uuid,
    pub iat: i64,
    pub exp: i64,
}

pub fn issue_token(
    secret: &str,
    ttl_secs: i64,
    member_id: Uuid,
    session_id: Uuid,
) -> anyhow::Result<String> {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: member_id,
        sid: session_id,
        iat: now,
        exp: now + ttl_secs,
    };
    Ok(jsonwebtoken::encode(
        &Header::new(Algorithm::HS256),
        &claims,
        &EncodingKey::from_secret(secret.as_bytes()),
    )?)
}

pub fn verify_token(secret: &str, token: &str) -> Option<Claims> {
    jsonwebtoken::decode::<Claims>(
        token,
        &DecodingKey::from_secret(secret.as_bytes()),
        &Validation::new(Algorithm::HS256),
    )
    .ok()
    .map(|d| d.claims)
}

/// 密码强度的最低要求（与前端提示一致）
pub fn check_password_policy(password: &str) -> Result<(), &'static str> {
    if password.chars().count() < 8 {
        return Err("密码至少 8 位");
    }
    if password.len() > 128 {
        return Err("密码不能超过 128 个字符");
    }
    Ok(())
}

/// Argon2 是 CPU 密集操作，调用方应放在 `spawn_blocking` 中。
pub fn hash_password(password: &str) -> anyhow::Result<String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|h| h.to_string())
        .map_err(|e| anyhow!("hash password: {e}"))
}

pub fn verify_password(password: &str, hash: &str) -> bool {
    PasswordHash::new(hash)
        .map(|parsed| {
            Argon2::default()
                .verify_password(password.as_bytes(), &parsed)
                .is_ok()
        })
        .unwrap_or(false)
}

pub async fn hash_password_async(password: String) -> anyhow::Result<String> {
    tokio::task::spawn_blocking(move || hash_password(&password)).await?
}

/// `hash = None`（用户不存在 / 尚未设置密码）时仍对一个真实哈希做校验，使响应时间一致，防止账号探测。
pub async fn verify_password_async(password: String, hash: Option<String>) -> bool {
    static DUMMY: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    tokio::task::spawn_blocking(move || match hash {
        Some(h) => verify_password(&password, &h),
        None => {
            let dummy = DUMMY.get_or_init(|| hash_password("uniconsole-dummy").unwrap_or_default());
            let _ = verify_password(&password, dummy);
            false
        }
    })
    .await
    .unwrap_or(false)
}

/// 高熵随机令牌（机器人接入令牌、邀请令牌）：`<prefix>_<64 位十六进制>`，库里只存 sha256。
pub fn generate_secret(prefix: &str) -> String {
    format!(
        "{prefix}_{}{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    )
}

pub fn generate_device_token() -> String {
    generate_secret("uc")
}

pub fn hash_secret(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
}

pub fn hash_device_token(token: &str) -> String {
    hash_secret(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_roundtrip() {
        let h = hash_password("hunter42").unwrap();
        assert!(verify_password("hunter42", &h));
        assert!(!verify_password("wrong", &h));
    }

    #[test]
    fn jwt_roundtrip() {
        let secret = "x".repeat(32);
        let (id, sid) = (Uuid::new_v4(), Uuid::new_v4());
        let t = issue_token(&secret, 60, id, sid).unwrap();
        let c = verify_token(&secret, &t).unwrap();
        assert_eq!((c.sub, c.sid), (id, sid));
        assert!(verify_token(&"y".repeat(32), &t).is_none());
        let expired = issue_token(&secret, -120, id, sid).unwrap();
        assert!(verify_token(&secret, &expired).is_none());
    }

    #[test]
    fn secrets() {
        let t = generate_secret("inv");
        assert!(t.starts_with("inv_") && t.len() == 4 + 64);
        assert_eq!(hash_secret(&t), hash_secret(&t));
        assert_eq!(hash_secret(&t).len(), 64);
        assert_ne!(generate_secret("inv"), t);
    }

    #[test]
    fn password_policy() {
        assert!(check_password_policy("short").is_err());
        assert!(check_password_policy("long-enough").is_ok());
    }
}
