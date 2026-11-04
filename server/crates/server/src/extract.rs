use std::net::SocketAddr;

use axum::{
    extract::{ConnectInfo, FromRef, FromRequestParts},
    http::{header, request::Parts},
};
use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::{error::AppError, models::Role, state::AppState};
use uniconsole_auth::{Access, Perm, rbac, verify_token};

/// 已认证的前端用户。令牌来源：`Authorization: Bearer <jwt>`，
/// 或 WebSocket 场景下的 `?token=<jwt>` 查询参数。
///
/// 每次请求都会按 JWT 中的会话 id 查库：会话被吊销（退出登录）、成员被停用 / 过期、
/// 角色被修改，都会立即生效。
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: Uuid,
    pub session_id: Uuid,
    pub name: String,
    pub role: Role,
    /// X-Client（审计日志「客户端」列，如「macOS · 1.0.0」）
    pub client: String,
    pub ip: String,
}

impl AuthUser {
    pub fn access(&self, perm: Perm) -> Access {
        rbac::access(self.role, perm)
    }

    /// 非设备相关的权限检查：Scoped 也算有权限
    pub fn require(&self, perm: Perm) -> Result<(), AppError> {
        if self.access(perm) == Access::None {
            return Err(AppError::forbidden("没有权限执行该操作"));
        }
        Ok(())
    }

    pub fn is_admin(&self) -> bool {
        self.role == Role::Admin
    }
}

fn bearer(parts: &Parts) -> Option<String> {
    if let Some(v) = parts
        .headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    {
        return v.strip_prefix("Bearer ").map(str::to_owned);
    }
    parts.uri.query().and_then(|q| {
        q.split('&')
            .filter_map(|kv| kv.split_once('='))
            .find(|(k, _)| *k == "token")
            .map(|(_, v)| v.to_owned())
    })
}

/// 头部值按 UTF-8 解码，失败时按 Latin-1（Dart 的 HttpClient 以 Latin-1 发送 `·` 等字符）
fn decode_header(bytes: &[u8]) -> String {
    match std::str::from_utf8(bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => bytes.iter().map(|&b| b as char).collect(),
    }
}

/// 请求方的客户端信息（X-Client、IP），登录等未认证接口也会用到
#[derive(Debug, Clone, Default)]
pub struct ClientInfo {
    pub client: String,
    pub ip: String,
}

impl ClientInfo {
    pub fn from_parts(parts: &Parts) -> Self {
        let client = parts
            .headers
            .get("x-client")
            .or_else(|| parts.headers.get(header::USER_AGENT))
            .map(|v| decode_header(v.as_bytes()))
            .unwrap_or_default()
            .chars()
            .filter(|c| !c.is_control())
            .take(64)
            .collect();
        let ip = parts
            .extensions
            .get::<ConnectInfo<SocketAddr>>()
            .map(|c| c.0.ip().to_string())
            .unwrap_or_default();
        Self { client, ip }
    }
}

impl<S: Send + Sync> FromRequestParts<S> for ClientInfo {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(parts: &mut Parts, _: &S) -> Result<Self, Self::Rejection> {
        Ok(Self::from_parts(parts))
    }
}

type SessionLookup = (
    Uuid,
    String,
    Role,
    bool,
    Option<DateTime<Utc>>,
    Option<DateTime<Utc>>,
    DateTime<Utc>,
);

impl<S> FromRequestParts<S> for AuthUser
where
    AppState: FromRef<S>,
    S: Send + Sync,
{
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let app = AppState::from_ref(state);
        let token = bearer(parts).ok_or(AppError::Unauthorized)?;
        let claims = verify_token(&app.cfg.jwt_secret, &token).ok_or(AppError::Unauthorized)?;

        // 顺带刷新会话最近活动时间（每分钟最多写一次）
        let row: Option<SessionLookup> = sqlx::query_as(
            "WITH touch AS (
                 UPDATE sessions SET last_seen_at = now()
                 WHERE id = $1 AND last_seen_at < now() - interval '60 seconds'
             )
             SELECT m.id, m.name, m.role, m.disabled, m.expires_at, s.revoked_at, s.expires_at
             FROM sessions s JOIN members m ON m.id = s.member_id
             WHERE s.id = $1",
        )
        .bind(claims.sid)
        .fetch_optional(&app.db)
        .await?;

        let Some((member_id, name, role, disabled, member_expires, revoked, session_expires)) = row
        else {
            return Err(AppError::Unauthorized);
        };
        let now = Utc::now();
        if member_id != claims.sub || revoked.is_some() || session_expires <= now {
            return Err(AppError::Unauthorized);
        }
        if disabled {
            return Err(AppError::forbidden("账号已停用"));
        }
        if member_expires.is_some_and(|e| e <= now) {
            return Err(AppError::forbidden("账号已过期"));
        }

        let info = ClientInfo::from_parts(parts);
        Ok(AuthUser {
            id: member_id,
            session_id: claims.sid,
            name,
            role,
            client: info.client,
            ip: info.ip,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::decode_header;

    #[test]
    fn x_client_encodings() {
        assert_eq!(decode_header("macOS · 1.0.0".as_bytes()), "macOS · 1.0.0");
        assert_eq!(decode_header(b"macOS \xb7 1.0.0"), "macOS · 1.0.0");
        assert_eq!(decode_header(b"iOS 1.0"), "iOS 1.0");
    }
}
