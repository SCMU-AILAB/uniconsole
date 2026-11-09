//! 登录会话：签发（登录 / 接受邀请 / API 令牌）、登录失败限流。

use std::time::{Duration, Instant};

use chrono::{Duration as ChronoDuration, Utc};
use dashmap::DashMap;
use serde::Serialize;
use uuid::Uuid;

use crate::{
    auth,
    error::{AppError, AppResult},
    extract::ClientInfo,
    models::{Member, MemberRow, SessionKind},
    services::members,
    state::AppState,
};

#[derive(Debug, Serialize)]
pub struct LoginResponse {
    pub token: String,
    pub expires_in: i64,
    pub session_id: Uuid,
    pub member: Member,
}

/// 为成员新建一个会话并签发 JWT
pub async fn issue(
    st: &AppState,
    member_id: Uuid,
    kind: SessionKind,
    name: &str,
    info: &ClientInfo,
    ttl_secs: i64,
) -> AppResult<(Uuid, String)> {
    let session_id: Uuid = sqlx::query_scalar(
        "INSERT INTO sessions (member_id, kind, name, client, ip, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
    )
    .bind(member_id)
    .bind(kind)
    .bind(name)
    .bind(&info.client)
    .bind(&info.ip)
    .bind(Utc::now() + ChronoDuration::seconds(ttl_secs))
    .fetch_one(&st.db)
    .await?;
    let token = auth::issue_token(&st.cfg.jwt_secret, ttl_secs, member_id, session_id)?;
    Ok((session_id, token))
}

/// 登录成功后的统一响应（登录、接受邀请都用它）
pub async fn login_response(
    st: &AppState,
    row: MemberRow,
    info: &ClientInfo,
    device_name: Option<String>,
) -> AppResult<LoginResponse> {
    let name = device_name
        .filter(|n| !n.trim().is_empty())
        .unwrap_or_else(|| default_session_name(&info.client));
    let ttl = st.cfg.jwt_ttl_secs;
    let (session_id, token) = issue(st, row.id, SessionKind::Login, &name, info, ttl).await?;
    sqlx::query("UPDATE members SET last_seen_at = now() WHERE id = $1")
        .bind(row.id)
        .execute(&st.db)
        .await?;
    Ok(LoginResponse {
        token,
        expires_in: ttl,
        session_id,
        member: members::view(st, row).await?,
    })
}

fn default_session_name(client: &str) -> String {
    // 「macOS · 1.0.0」→「macOS」
    client
        .split('·')
        .next()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("未知设备")
        .to_owned()
}

/// 账号状态检查（密码已验证之后）
pub fn ensure_active(row: &MemberRow) -> AppResult<()> {
    if row.pending_approval {
        return Err(AppError::PendingApproval);
    }
    if row.disabled {
        return Err(AppError::forbidden("账号已停用"));
    }
    if row.expires_at.is_some_and(|e| e <= Utc::now()) {
        return Err(AppError::forbidden("账号已过期"));
    }
    Ok(())
}

// ───────── 登录失败限流 ─────────

const MAX_FAILURES: u32 = 5;
const LOCKOUT: Duration = Duration::from_secs(60);
const WINDOW: Duration = Duration::from_secs(15 * 60);

/// 按「账号 + IP」计数：15 分钟内连续失败 5 次后锁定 60 秒
#[derive(Default)]
pub struct LoginLimiter {
    failures: DashMap<String, (u32, Instant)>,
}

impl LoginLimiter {
    pub fn key(handle: &str, ip: &str) -> String {
        format!("{}|{ip}", handle.to_lowercase())
    }

    pub fn check(&self, key: &str) -> AppResult<()> {
        if let Some(e) = self.failures.get(key) {
            let (count, last) = *e;
            if count >= MAX_FAILURES && last.elapsed() < LOCKOUT {
                let wait = (LOCKOUT - last.elapsed()).as_secs().max(1);
                return Err(AppError::TooManyRequests(format!(
                    "登录失败次数过多，请 {wait} 秒后再试"
                )));
            }
        }
        Ok(())
    }

    pub fn fail(&self, key: &str) {
        if self.failures.len() > 10_000 {
            self.failures.retain(|_, (_, t)| t.elapsed() < WINDOW);
        }
        let mut e = self
            .failures
            .entry(key.to_owned())
            .or_insert((0, Instant::now()));
        if e.1.elapsed() > WINDOW || (e.0 >= MAX_FAILURES && e.1.elapsed() >= LOCKOUT) {
            e.0 = 0;
        }
        e.0 += 1;
        e.1 = Instant::now();
    }

    pub fn reset(&self, key: &str) {
        self.failures.remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locks_after_five_failures() {
        let l = LoginLimiter::default();
        let k = LoginLimiter::key("Kanade", "1.2.3.4");
        for _ in 0..4 {
            l.fail(&k);
            assert!(l.check(&k).is_ok());
        }
        l.fail(&k);
        assert!(matches!(l.check(&k), Err(AppError::TooManyRequests(_))));
        l.reset(&k);
        assert!(l.check(&k).is_ok());
        assert_eq!(k, "kanade|1.2.3.4");
    }

    #[test]
    fn session_names() {
        assert_eq!(default_session_name("macOS · 1.0.0"), "macOS");
        assert_eq!(default_session_name(""), "未知设备");
    }
}
