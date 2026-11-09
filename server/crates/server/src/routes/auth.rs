//! 认证：登录、退出、当前用户、邀请激活、邮箱注册、修改密码。

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
        audit,
        email_codes::{self, PURPOSE_REGISTER, normalize_email},
        members,
        sessions::{self, LoginLimiter, LoginResponse},
    },
    state::AppState,
    util::normalize_handle,
};

#[derive(Deserialize)]
pub struct LoginReq {
    /// 账号（可带 @）或注册邮箱，不区分大小写
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
    // 「@linyue」是账号，「linyue@example.com」是邮箱
    let email = req
        .handle
        .trim()
        .get(1..)
        .filter(|rest| rest.contains('@'))
        .and_then(|_| normalize_email(&req.handle));
    let ident = match &email {
        Some(e) => e.clone(),
        None => normalize_handle(&req.handle).unwrap_or_default(),
    };
    let key = LoginLimiter::key(&ident, &info.ip);
    st.login_limiter.check(&key)?;

    let row: Option<MemberRow> = match &email {
        Some(_) => sqlx::query_as("SELECT * FROM members WHERE lower(email) = $1"),
        None => sqlx::query_as("SELECT * FROM members WHERE handle = $1"),
    }
    .bind(&ident)
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

// ───────── 邮箱注册（验证邮箱 → 管理员审核 → 可登录）─────────

fn ensure_registration(st: &AppState) -> AppResult<()> {
    if st.cfg.registration_enabled {
        Ok(())
    } else {
        Err(AppError::forbidden("暂未开放注册，请联系管理员邀请"))
    }
}

async fn email_taken(st: &AppState, email: &str) -> AppResult<bool> {
    Ok(
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM members WHERE lower(email) = $1)")
            .bind(email)
            .fetch_one(&st.db)
            .await?,
    )
}

#[derive(Deserialize)]
pub struct RegisterCodeReq {
    pub email: String,
}

/// POST /auth/register/code：向邮箱发送 6 位验证码
pub async fn register_code(
    State(st): State<AppState>,
    info: ClientInfo,
    Json(req): Json<RegisterCodeReq>,
) -> AppResult<Json<serde_json::Value>> {
    ensure_registration(&st)?;
    let email =
        normalize_email(&req.email).ok_or_else(|| AppError::bad_request("邮箱格式不正确"))?;
    if email_taken(&st, &email).await? {
        return Err(AppError::conflict("该邮箱已注册，请直接登录"));
    }
    st.code_limiter.hit(&info.ip)?;
    let code = email_codes::issue(&st, PURPOSE_REGISTER, &email).await?;
    let minutes = email_codes::CODE_TTL_SECS / 60;
    let body = format!(
        "你正在注册 UniConsole，验证码：\n\n    {code}\n\n{minutes} 分钟内有效。如果不是你本人操作，请忽略这封邮件。\n\n— UniConsole"
    );
    if let Err(e) = st
        .mailer
        .send(&email, &format!("UniConsole 注册验证码 {code}"), body)
        .await
    {
        email_codes::revoke(&st, PURPOSE_REGISTER, &email).await;
        return Err(e);
    }
    Ok(Json(json!({
        "expires_in": email_codes::CODE_TTL_SECS,
        "resend_after": email_codes::RESEND_AFTER_SECS,
    })))
}

#[derive(Deserialize)]
pub struct RegisterReq {
    pub email: String,
    pub code: String,
    pub handle: String,
    pub name: String,
    pub password: String,
}

/// POST /auth/register：校验验证码并创建账号（待管理员审核，审核前不能登录）
pub async fn register(
    State(st): State<AppState>,
    Json(req): Json<RegisterReq>,
) -> AppResult<(StatusCode, Json<serde_json::Value>)> {
    ensure_registration(&st)?;
    let email =
        normalize_email(&req.email).ok_or_else(|| AppError::bad_request("邮箱格式不正确"))?;
    let handle = normalize_handle(&req.handle)
        .ok_or_else(|| AppError::bad_request("账号只能包含 2–32 位小写字母、数字、_ . -"))?;
    let name = req.name.trim();
    if name.is_empty() || name.chars().count() > 32 {
        return Err(AppError::bad_request("请填写 1–32 个字的名字"));
    }
    auth::check_password_policy(&req.password).map_err(AppError::bad_request)?;
    if email_taken(&st, &email).await? {
        return Err(AppError::conflict("该邮箱已注册，请直接登录"));
    }
    let handle_taken: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM members WHERE handle = $1)")
            .bind(&handle)
            .fetch_one(&st.db)
            .await?;
    if handle_taken {
        return Err(AppError::conflict(format!("账号 @{handle} 已被使用")));
    }
    // 先查重再消耗验证码：账号重名时验证码还能继续用
    email_codes::consume(&st, PURPOSE_REGISTER, &email, &req.code).await?;
    let hash = auth::hash_password_async(req.password).await?;
    let row: MemberRow = sqlx::query_as(
        "INSERT INTO members (handle, name, password_hash, role, email, pending_approval)
         VALUES ($1, $2, $3, 'viewer', $4, TRUE) RETURNING *",
    )
    .bind(&handle)
    .bind(name)
    .bind(hash)
    .bind(&email)
    .fetch_one(&st.db)
    .await
    .map_err(|e| match AppError::from(e) {
        AppError::Conflict(_) => AppError::conflict("账号或邮箱已被使用"),
        other => other,
    })?;

    audit::record_system(
        &st,
        audit::Kind::Config,
        format!("{name}（{email}）通过邮箱注册，等待审核"),
        name,
        json!({ "handle": handle, "email": email }),
    )
    .await;
    notify_admins(&st, &row).await;
    st.hub.publish(crate::protocol::ServerEvent::changed(
        "members",
        Some(row.id),
    ));
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "member": members::view(&st, row).await?,
            "pending_approval": true,
        })),
    ))
}

/// 新注册申请：在线管理员弹提示，有邮箱的管理员再发一封邮件
async fn notify_admins(st: &AppState, row: &MemberRow) {
    let admins: Vec<(uuid::Uuid, Option<String>)> = sqlx::query_as(
        "SELECT id, email FROM members
         WHERE role = 'admin' AND NOT disabled AND NOT pending_approval",
    )
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();
    let email = row.email.clone().unwrap_or_default();
    let text = format!("{}（{email}）申请注册，等待审核", row.name);
    for (id, admin_email) in admins {
        st.hub.publish(crate::protocol::ServerEvent::Notice {
            member_id: id,
            level: "info".into(),
            text: text.clone(),
        });
        if let Some(to) = admin_email {
            let st = st.clone();
            let body = format!(
                "{text}。\n\n账号：@{}\n请在「成员与权限」里通过或拒绝。\n\n— UniConsole",
                row.handle
            );
            tokio::spawn(async move {
                let _ = st.mailer.send(&to, "UniConsole 新的注册申请", body).await;
            });
        }
    }
}
