use axum::{
    extract::{FromRef, FromRequestParts},
    http::{header, request::Parts},
};
use uuid::Uuid;

use crate::{error::AppError, models::Role, state::AppState};
use uniconsole_auth::{Access, Perm, rbac, verify_token};

/// 已认证的前端用户。令牌来源：`Authorization: Bearer <jwt>`，
/// 或 WebSocket 场景下的 `?token=<jwt>` 查询参数。
#[derive(Debug, Clone)]
pub struct AuthUser {
    pub id: Uuid,
    pub name: String,
    pub role: Role,
    /// 客户端标识（审计日志里的「macOS · 192.168.x.x」）
    pub client: String,
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

        let ua = parts
            .headers
            .get("x-client")
            .or_else(|| parts.headers.get(header::USER_AGENT))
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .chars()
            .take(64)
            .collect();

        Ok(AuthUser {
            id: claims.sub,
            name: claims.name,
            role: claims.role,
            client: ua,
        })
    }
}
