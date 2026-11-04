//! 当前账户：已登录设备、API 令牌、二次验证、偏好、推送令牌（设置页）。

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, totp},
    error::{AppError, AppResult},
    extract::ClientInfo,
    models::{SessionKind, SessionRow},
    services::{audit, sessions},
    state::AppState,
};

#[derive(Serialize)]
pub struct SessionView {
    pub id: Uuid,
    pub name: String,
    /// 「macOS · 1.0.0 · 192.168.1.20」
    pub detail: String,
    pub current: bool,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

fn session_view(s: SessionRow, current: Uuid) -> SessionView {
    let detail = [s.client.as_str(), s.ip.as_str()]
        .into_iter()
        .filter(|x| !x.is_empty())
        .collect::<Vec<_>>()
        .join(" · ");
    SessionView {
        current: s.id == current,
        id: s.id,
        name: s.name,
        detail,
        created_at: s.created_at,
        last_seen_at: s.last_seen_at,
        expires_at: s.expires_at,
    }
}

async fn active(st: &AppState, member: Uuid, kind: SessionKind) -> AppResult<Vec<SessionRow>> {
    Ok(sqlx::query_as(
        "SELECT id, kind, name, client, ip, created_at, last_seen_at, expires_at FROM sessions
         WHERE member_id = $1 AND kind = $2 AND revoked_at IS NULL AND expires_at > now()
         ORDER BY last_seen_at DESC",
    )
    .bind(member)
    .bind(kind)
    .fetch_all(&st.db)
    .await?)
}

async fn revoke(st: &AppState, member: Uuid, id: Uuid, kind: SessionKind) -> AppResult<()> {
    let res = sqlx::query(
        "UPDATE sessions SET revoked_at = now()
         WHERE id = $1 AND member_id = $2 AND kind = $3 AND revoked_at IS NULL",
    )
    .bind(id)
    .bind(member)
    .bind(kind)
    .execute(&st.db)
    .await?;
    if res.rows_affected() == 0 {
        return Err(AppError::not_found("记录不存在或已失效"));
    }
    Ok(())
}

// ───────── 已登录设备 ─────────

pub async fn list_sessions(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<SessionView>>> {
    let rows = active(&st, user.id, SessionKind::Login).await?;
    Ok(Json(
        rows.into_iter()
            .map(|s| session_view(s, user.session_id))
            .collect(),
    ))
}

/// DELETE /me/sessions/{id}：让该客户端退出登录（可以是当前会话）
pub async fn revoke_session(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    revoke(&st, user.id, id, SessionKind::Login).await?;
    Ok(StatusCode::NO_CONTENT)
}

// ───────── API 令牌 ─────────

#[derive(Serialize)]
pub struct TokenView {
    pub id: Uuid,
    pub name: String,
    /// 「创建于 10 月 12 日 · 最近使用 11 月 3 日」
    pub detail: String,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
}

fn token_view(s: SessionRow) -> TokenView {
    let d = |t: DateTime<Utc>| t.format("%-m 月 %-d 日").to_string();
    TokenView {
        detail: format!(
            "创建于 {} · 最近使用 {}",
            d(s.created_at),
            d(s.last_seen_at)
        ),
        id: s.id,
        name: s.name,
        created_at: s.created_at,
        last_seen_at: s.last_seen_at,
        expires_at: s.expires_at,
    }
}

pub async fn list_tokens(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<TokenView>>> {
    let rows = active(&st, user.id, SessionKind::Token).await?;
    Ok(Json(rows.into_iter().map(token_view).collect()))
}

#[derive(Deserialize)]
pub struct CreateToken {
    pub name: String,
    pub ttl_days: Option<i64>,
}

/// POST /me/tokens：创建个人 API 令牌（脚本 / 集成用）。明文只返回这一次。
pub async fn create_token(
    State(st): State<AppState>,
    user: AuthUser,
    info: ClientInfo,
    Json(req): Json<CreateToken>,
) -> AppResult<(StatusCode, Json<Value>)> {
    let name = req.name.trim();
    if name.is_empty() || name.chars().count() > 64 {
        return Err(AppError::bad_request("请填写 1–64 个字的令牌名称"));
    }
    let days = req
        .ttl_days
        .unwrap_or(st.cfg.api_token_ttl_days)
        .clamp(1, 3650);
    let (id, token) =
        sessions::issue(&st, user.id, SessionKind::Token, name, &info, days * 86_400).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 创建了 API 令牌「{name}」", user.name),
        name,
        json!({ "token_id": id, "ttl_days": days }),
    )
    .await;
    Ok((
        StatusCode::CREATED,
        Json(json!({ "id": id, "name": name, "token": token, "ttl_days": days })),
    ))
}

pub async fn revoke_token(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    revoke(&st, user.id, id, SessionKind::Token).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 吊销了一个 API 令牌", user.name),
        id.to_string(),
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

// ───────── 二次验证 ─────────

/// POST /me/2fa/enable：生成密钥，返回给验证器 App 扫码；需随后调用 /verify 才真正开启
pub async fn enable_2fa(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    let (enabled, handle): (bool, String) =
        sqlx::query_as("SELECT two_factor, handle FROM members WHERE id = $1")
            .bind(user.id)
            .fetch_one(&st.db)
            .await?;
    if enabled {
        return Err(AppError::conflict("二次验证已开启"));
    }
    let secret = totp::generate_secret();
    sqlx::query("UPDATE members SET totp_pending = $2 WHERE id = $1")
        .bind(user.id)
        .bind(&secret)
        .execute(&st.db)
        .await?;
    Ok(Json(json!({
        "secret": secret,
        "otpauth_url": totp::otpauth_url(&secret, &handle, "UniConsole"),
    })))
}

#[derive(Deserialize)]
pub struct CodeReq {
    pub code: String,
}

/// POST /me/2fa/verify：输入验证器上的 6 位数字完成绑定
pub async fn verify_2fa(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CodeReq>,
) -> AppResult<StatusCode> {
    let pending: Option<String> =
        sqlx::query_scalar("SELECT totp_pending FROM members WHERE id = $1")
            .bind(user.id)
            .fetch_one(&st.db)
            .await?;
    let pending = pending.ok_or_else(|| AppError::conflict("请先调用 /me/2fa/enable"))?;
    if !totp::verify(&pending, &req.code, Utc::now().timestamp()) {
        return Err(AppError::TwoFactorInvalid);
    }
    sqlx::query(
        "UPDATE members SET totp_secret = totp_pending, totp_pending = NULL, two_factor = TRUE
         WHERE id = $1",
    )
    .bind(user.id)
    .execute(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 开启了二次验证", user.name),
        &user.name,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

/// POST /me/2fa/disable：需要当前验证码
pub async fn disable_2fa(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CodeReq>,
) -> AppResult<StatusCode> {
    let secret: Option<String> =
        sqlx::query_scalar("SELECT totp_secret FROM members WHERE id = $1 AND two_factor")
            .bind(user.id)
            .fetch_optional(&st.db)
            .await?
            .flatten();
    let secret = secret.ok_or_else(|| AppError::conflict("二次验证未开启"))?;
    if !totp::verify(&secret, &req.code, Utc::now().timestamp()) {
        return Err(AppError::TwoFactorInvalid);
    }
    sqlx::query(
        "UPDATE members SET totp_secret = NULL, totp_pending = NULL, two_factor = FALSE WHERE id = $1",
    )
    .bind(user.id)
    .execute(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 关闭了二次验证", user.name),
        &user.name,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

// ───────── 偏好 ─────────

/// GET /me/preferences：前端 Preferences 对象，服务端当作不透明 JSON 保存。
/// `two_factor` 以服务端为准，读取时覆盖进去。
pub async fn get_preferences(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    let (mut prefs, two_factor): (Value, bool) =
        sqlx::query_as("SELECT preferences, two_factor FROM members WHERE id = $1")
            .bind(user.id)
            .fetch_one(&st.db)
            .await?;
    if let Value::Object(m) = &mut prefs {
        m.insert("two_factor".into(), json!(two_factor));
    }
    Ok(Json(prefs))
}

pub async fn put_preferences(
    State(st): State<AppState>,
    user: AuthUser,
    Json(mut prefs): Json<Value>,
) -> AppResult<Json<Value>> {
    let Value::Object(m) = &mut prefs else {
        return Err(AppError::bad_request("偏好必须是 JSON 对象"));
    };
    m.remove("two_factor");
    if prefs.to_string().len() > 64 * 1024 {
        return Err(AppError::bad_request("偏好数据过大"));
    }
    sqlx::query("UPDATE members SET preferences = $2 WHERE id = $1")
        .bind(user.id)
        .bind(&prefs)
        .execute(&st.db)
        .await?;
    get_preferences(State(st), user).await
}

// ───────── 系统推送令牌 ─────────

#[derive(Deserialize)]
pub struct PushToken {
    /// apns | fcm
    pub platform: String,
    pub token: String,
}

/// POST /me/push-tokens：登记 APNs / FCM 令牌（服务端发送尚未接入，先登记）
pub async fn add_push_token(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<PushToken>,
) -> AppResult<StatusCode> {
    if !matches!(req.platform.as_str(), "apns" | "fcm") || req.token.is_empty() {
        return Err(AppError::bad_request(
            "platform 只能是 apns 或 fcm，token 不能为空",
        ));
    }
    sqlx::query(
        "INSERT INTO push_tokens (platform, token, member_id) VALUES ($1, $2, $3)
         ON CONFLICT (platform, token) DO UPDATE SET member_id = EXCLUDED.member_id, created_at = now()",
    )
    .bind(&req.platform)
    .bind(&req.token)
    .bind(user.id)
    .execute(&st.db)
    .await?;
    Ok(StatusCode::NO_CONTENT)
}
