//! UniConsole 认证（JWT + Argon2 + 机器人接入令牌）与权限（Roles.dc.html 权限矩阵）。
//!
//! 不依赖 Web 框架；HTTP 提取器在 `uniconsole-server` 的 `extract` 模块。

pub mod rbac;

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

use uniconsole_domain::Role;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
    pub sub: Uuid,
    pub name: String,
    pub role: Role,
    pub iat: i64,
    pub exp: i64,
}

pub fn issue_token(
    secret: &str,
    ttl_secs: i64,
    id: Uuid,
    name: &str,
    role: Role,
) -> anyhow::Result<String> {
    let now = Utc::now().timestamp();
    let claims = Claims {
        sub: id,
        name: name.to_owned(),
        role,
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

/// `hash = None`（用户不存在）时仍对一个真实哈希做校验，使响应时间一致，防止账号探测。
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

/// 机器人接入令牌：高熵随机串，库里只存 sha256。
pub fn generate_device_token() -> String {
    format!("uc_{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
}

pub fn hash_device_token(token: &str) -> String {
    hex::encode(Sha256::digest(token.as_bytes()))
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
        let id = Uuid::new_v4();
        let t = issue_token(&secret, 60, id, "Kanade", Role::Admin).unwrap();
        let c = verify_token(&secret, &t).unwrap();
        assert_eq!(c.sub, id);
        assert_eq!(c.role, Role::Admin);
        assert!(verify_token(&"y".repeat(32), &t).is_none());
    }

    #[test]
    fn device_token_hash_is_stable() {
        let t = generate_device_token();
        assert_eq!(hash_device_token(&t), hash_device_token(&t));
        assert_eq!(hash_device_token(&t).len(), 64);
    }
}
