//! 邮箱验证码（注册）。
//!
//! - 6 位数字，10 分钟有效，同一邮箱 60 秒内只能获取一次，新验证码会让旧的失效；
//! - 库里只存 HMAC（密钥 = JWT_SECRET），错误 5 次后作废；
//! - 同一 IP 每小时最多获取 10 次（防止拿服务器当发信器）。

use std::time::{Duration, Instant};

use dashmap::DashMap;
use data_encoding::HEXLOWER;
use hmac::{Hmac, KeyInit, Mac};
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    state::AppState,
};

pub const CODE_TTL_SECS: i64 = 10 * 60;
pub const RESEND_AFTER_SECS: i64 = 60;
const MAX_ATTEMPTS: i32 = 5;
const IP_LIMIT: u32 = 10;
const IP_WINDOW: Duration = Duration::from_secs(3600);

/// 用途：目前只有注册
pub const PURPOSE_REGISTER: &str = "register";

/// 规整邮箱：去空格、转小写；格式明显不对返回 None
pub fn normalize_email(raw: &str) -> Option<String> {
    let e = raw.trim().to_lowercase();
    let (local, domain) = e.split_once('@')?;
    let ok = e.len() <= 254
        && !local.is_empty()
        && local.len() <= 64
        && !domain.contains('@')
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && !domain.contains("..")
        && e.chars()
            .all(|c| c.is_ascii_graphic() && c != '<' && c != '>' && c != '"');
    ok.then_some(e)
}

fn new_code() -> String {
    format!("{:06}", Uuid::new_v4().as_u128() % 1_000_000)
}

fn hash_code(secret: &str, purpose: &str, email: &str, code: &str) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("hmac key");
    mac.update(format!("email-code:{purpose}:{email}:{code}").as_bytes());
    HEXLOWER.encode(&mac.finalize().into_bytes())
}

/// 每个 IP 一小时内获取验证码的次数
#[derive(Default)]
pub struct CodeLimiter {
    by_ip: DashMap<String, (u32, Instant)>,
}

impl CodeLimiter {
    pub fn hit(&self, ip: &str) -> AppResult<()> {
        if self.by_ip.len() > 10_000 {
            self.by_ip.retain(|_, (_, t)| t.elapsed() < IP_WINDOW);
        }
        let mut e = self
            .by_ip
            .entry(ip.to_owned())
            .or_insert((0, Instant::now()));
        if e.1.elapsed() >= IP_WINDOW {
            *e = (0, Instant::now());
        }
        if e.0 >= IP_LIMIT {
            return Err(AppError::TooManyRequests(
                "获取验证码过于频繁，请稍后再试".into(),
            ));
        }
        e.0 += 1;
        Ok(())
    }
}

/// 生成并保存验证码，返回明文（由调用方发邮件）。60 秒内重复获取返回 429
pub async fn issue(st: &AppState, purpose: &str, email: &str) -> AppResult<String> {
    let wait: Option<f64> = sqlx::query_scalar(
        "SELECT EXTRACT(EPOCH FROM sent_at + make_interval(secs => $3) - now())::float8
         FROM email_codes WHERE email = $1 AND purpose = $2
           AND sent_at > now() - make_interval(secs => $3)",
    )
    .bind(email)
    .bind(purpose)
    .bind(RESEND_AFTER_SECS as f64)
    .fetch_optional(&st.db)
    .await?;
    if let Some(w) = wait {
        return Err(AppError::TooManyRequests(format!(
            "请 {} 秒后再获取验证码",
            w.ceil().max(1.0) as i64
        )));
    }
    let code = new_code();
    sqlx::query(
        "INSERT INTO email_codes (email, purpose, code_hash, attempts, sent_at, expires_at)
         VALUES ($1, $2, $3, 0, now(), now() + make_interval(secs => $4))
         ON CONFLICT (email, purpose) DO UPDATE
           SET code_hash = EXCLUDED.code_hash, attempts = 0,
               sent_at = EXCLUDED.sent_at, expires_at = EXCLUDED.expires_at",
    )
    .bind(email)
    .bind(purpose)
    .bind(hash_code(&st.cfg.jwt_secret, purpose, email, &code))
    .bind(CODE_TTL_SECS as f64)
    .execute(&st.db)
    .await?;
    Ok(code)
}

/// 发信失败时撤回，允许立即重新获取
pub async fn revoke(st: &AppState, purpose: &str, email: &str) {
    let _ = sqlx::query("DELETE FROM email_codes WHERE email = $1 AND purpose = $2")
        .bind(email)
        .bind(purpose)
        .execute(&st.db)
        .await;
}

/// 校验验证码；成功后作废（一次性）
pub async fn consume(st: &AppState, purpose: &str, email: &str, code: &str) -> AppResult<()> {
    let row: Option<(String, i32)> = sqlx::query_as(
        "SELECT code_hash, attempts FROM email_codes
         WHERE email = $1 AND purpose = $2 AND expires_at > now()",
    )
    .bind(email)
    .bind(purpose)
    .fetch_optional(&st.db)
    .await?;
    let Some((hash, attempts)) = row else {
        return Err(AppError::bad_request("验证码无效或已过期，请重新获取"));
    };
    if attempts >= MAX_ATTEMPTS {
        revoke(st, purpose, email).await;
        return Err(AppError::bad_request("验证码错误次数过多，请重新获取"));
    }
    let given = hash_code(&st.cfg.jwt_secret, purpose, email, code.trim());
    if !crate::util::constant_time_eq(given.as_bytes(), hash.as_bytes()) {
        sqlx::query(
            "UPDATE email_codes SET attempts = attempts + 1 WHERE email = $1 AND purpose = $2",
        )
        .bind(email)
        .bind(purpose)
        .execute(&st.db)
        .await?;
        return Err(AppError::bad_request("验证码错误"));
    }
    // 并发提交同一个验证码时只有一个能删掉这一行
    let deleted =
        sqlx::query("DELETE FROM email_codes WHERE email = $1 AND purpose = $2 AND code_hash = $3")
            .bind(email)
            .bind(purpose)
            .bind(&hash)
            .execute(&st.db)
            .await?
            .rows_affected();
    if deleted == 0 {
        return Err(AppError::bad_request("验证码已被使用，请重新获取"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn emails() {
        assert_eq!(
            normalize_email(" Lin.Yue@Example.COM ").as_deref(),
            Some("lin.yue@example.com")
        );
        assert_eq!(normalize_email("a@b"), None);
        assert_eq!(normalize_email("@b.com"), None);
        assert_eq!(normalize_email("a@@b.com"), None);
        assert_eq!(normalize_email("a b@c.com"), None);
        assert_eq!(normalize_email("a@b..com"), None);
        assert_eq!(normalize_email("林@b.com"), None);
    }

    #[test]
    fn codes() {
        for _ in 0..100 {
            let c = new_code();
            assert_eq!(c.len(), 6);
            assert!(c.chars().all(|x| x.is_ascii_digit()));
        }
        let h = hash_code("s", "register", "a@b.com", "123456");
        assert_eq!(h, hash_code("s", "register", "a@b.com", "123456"));
        assert_ne!(h, hash_code("s", "register", "c@b.com", "123456"));
        assert_ne!(h, hash_code("t", "register", "a@b.com", "123456"));
    }

    #[test]
    fn ip_limit() {
        let l = CodeLimiter::default();
        for _ in 0..IP_LIMIT {
            assert!(l.hit("1.2.3.4").is_ok());
        }
        assert!(l.hit("1.2.3.4").is_err());
        assert!(l.hit("5.6.7.8").is_ok());
    }
}
