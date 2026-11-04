//! 认证：登录、退出、当前用户、邀请激活、修改密码。

use axum::{
    Json,
    extract::{Path, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::{
    auth::{self, AuthUser, totp},
    error::{AppError, AppResult},
    extract::ClientInfo,
    models::{Member, MemberRow},
    services::{
        audit, members,
        sessions::{self, LoginLimiter, LoginResponse},
    },
    state::AppState,
    util::normalize_handle,
};

#[derive(Deserialize)]
pub struct LoginReq {
    /// 账号，可带 @，不区分大小写
    pub handle: String,
    pub password: String,
    /// 开启二次验证的账号需要；首次不带时返回 401 two_factor_required
    pub code: Option<String>,
    /// 会话名（「设置 › 已登录设备」显示），缺省取 X-Client 的平台名
    pub device_name: Option<String>,
}

/// POST /auth/login
pub async fn login(
    State(st): State<AppState>,
    info: ClientInfo,
    Json(req): Json<LoginReq>,
) -> AppResult<Json<LoginResponse>> {
    let handle = normalize_handle(&req.handle).unwrap_or_default();
    let key = LoginLimiter::key(&handle, &info.ip);
    st.login_limiter.check(&key)?;

    let row: Option<MemberRow> = sqlx::query_as("SELECT * FROM members WHERE handle = $1")
        .bind(&handle)
        .fetch_optional(&st.db)
        .await?;

    // 账号不存在、尚未激活、密码错误都返回同一个错误，且耗时一致
    let hash = row.as_ref().and_then(|r| r.password_hash.clone());
    let ok = auth::verify_password_async(req.password, hash).await;
    let row = match row {
        Some(r) if ok => r,
        _ => {
            st.login_limiter.fail(&key);
            return Err(AppError::BadCredentials);
        }
    };
    sessions::ensure_active(&row)?;

    if row.two_factor {
        let secret = row.totp_secret.as_deref().unwrap_or_default();
        match req.code.as_deref() {
            None | Some("") => return Err(AppError::TwoFactorRequired),
            Some(code) if !totp::verify(secret, code, Utc::now().timestamp()) => {
                st.login_limiter.fail(&key);
                return Err(AppError::TwoFactorInvalid);
            }
            Some(_) => {}
        }
    }
    st.login_limiter.reset(&key);

    let resp = sessions::login_response(&st, row, &info, req.device_name).await?;
    Ok(Json(resp))
}

/// POST /auth/logout：吊销当前会话
pub async fn logout(State(st): State<AppState>, user: AuthUser) -> AppResult<StatusCode> {
    sqlx::query("UPDATE sessions SET revoked_at = now() WHERE id = $1 AND revoked_at IS NULL")
        .bind(user.session_id)
        .execute(&st.db)
        .await?;
    Ok(StatusCode::NO_CONTENT)
}

/// GET /auth/me
pub async fn me(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Member>> {
    Ok(Json(members::load(&st, user.id).await?))
}

#[derive(Serialize)]
pub struct InviteInfo {
    pub handle: String,
    pub name: String,
    pub expires_at: Option<DateTime<Utc>>,
}

async fn invite_row(st: &AppState, token: &str) -> AppResult<MemberRow> {
    sqlx::query_as(
        "SELECT * FROM members
         WHERE invite_token_hash = $1 AND invite_expires_at > now() AND NOT disabled",
    )
    .bind(auth::hash_secret(token))
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("邀请链接无效或已过期，请联系管理员重新邀请"))
}

/// GET /auth/invites/{token}：邀请页显示「为 林悦（@linyue）设置密码」
pub async fn invite_info(
    State(st): State<AppState>,
    Path(token): Path<String>,
) -> AppResult<Json<InviteInfo>> {
    let r = invite_row(&st, &token).await?;
    Ok(Json(InviteInfo {
        handle: r.handle,
        name: r.name,
        expires_at: r.invite_expires_at,
    }))
}

#[derive(Deserialize)]
pub struct AcceptInvite {
    pub password: String,
    pub device_name: Option<String>,
}

/// POST /auth/invites/{token}/accept：设置密码并直接登录
pub async fn accept_invite(
    State(st): State<AppState>,
    info: ClientInfo,
    Path(token): Path<String>,
    Json(req): Json<AcceptInvite>,
) -> AppResult<Json<LoginResponse>> {
    auth::check_password_policy(&req.password).map_err(AppError::bad_request)?;
    let row = invite_row(&st, &token).await?;
    let hash = auth::hash_password_async(req.password).await?;
    let row: MemberRow = sqlx::query_as(
        "UPDATE members SET password_hash = $2, invite_token_hash = NULL, invite_expires_at = NULL
         WHERE id = $1 AND invite_token_hash = $3 RETURNING *",
    )
    .bind(row.id)
    .bind(hash)
    .bind(auth::hash_secret(&token))
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::conflict("邀请链接已被使用"))?;
    sessions::ensure_active(&row)?;

    let actor = AuthUser {
        id: row.id,
        session_id: uuid::Uuid::nil(),
        name: row.name.clone(),
        role: row.role,
        client: info.client.clone(),
        ip: info.ip.clone(),
    };
    audit::record(
        &st,
        &actor,
        audit::Kind::Config,
        format!("{} 接受邀请并设置了密码", row.name),
        &row.name,
        json!({}),
    )
    .await;
    st.hub.publish(crate::protocol::ServerEvent::changed(
        "members",
        Some(row.id),
    ));
    Ok(Json(
        sessions::login_response(&st, row, &info, req.device_name).await?,
    ))
}

#[derive(Deserialize)]
pub struct ChangePassword {
    pub old_password: String,
    pub new_password: String,
}

/// POST /auth/password：修改自己的密码，其他已登录设备全部退出
pub async fn change_password(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<ChangePassword>,
) -> AppResult<StatusCode> {
    auth::check_password_policy(&req.new_password).map_err(AppError::bad_request)?;
    let hash: Option<String> =
        sqlx::query_scalar("SELECT password_hash FROM members WHERE id = $1")
            .bind(user.id)
            .fetch_one(&st.db)
            .await?;
    if !auth::verify_password_async(req.old_password, hash).await {
        return Err(AppError::bad_request("原密码错误"));
    }
    let new_hash = auth::hash_password_async(req.new_password).await?;
    sqlx::query("UPDATE members SET password_hash = $2 WHERE id = $1")
        .bind(user.id)
        .bind(new_hash)
        .execute(&st.db)
        .await?;
    members::revoke_sessions(&st, user.id, Some(user.session_id)).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 修改了密码", user.name),
        &user.name,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}
