//! 成员与权限（Roles.dc.html）：成员、邀请、授权设备、审计日志。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::IntoResponse,
};
use chrono::{DateTime, Duration, Utc};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{self, Access, AuthUser, Perm},
    error::{AppError, AppResult},
    models::{AuditEntry, Member, MemberRow, Role},
    protocol::ServerEvent,
    services::{audit, members},
    state::AppState,
    util::{double_option, normalize_handle},
};

fn role_label(r: Role) -> &'static str {
    match r {
        Role::Admin => "平台管理员",
        Role::Owner => "设备管理者",
        Role::User => "使用者",
        Role::Viewer => "观察者",
    }
}

fn valid_color(c: &str) -> bool {
    c.len() == 7 && c.starts_with('#') && c[1..].chars().all(|x| x.is_ascii_hexdigit())
}

fn changed(st: &AppState, id: Uuid) {
    st.hub.publish(ServerEvent::changed("members", Some(id)));
}

/// 邮箱只给管理员和本人看
fn mask_email(user: &AuthUser, mut m: Member) -> Member {
    if !user.is_admin() && m.id != user.id {
        m.email = None;
    }
    m
}

pub async fn list(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Vec<Member>>> {
    let list = members::list(&st).await?;
    Ok(Json(
        list.into_iter().map(|m| mask_email(&user, m)).collect(),
    ))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Member>> {
    Ok(Json(mask_email(&user, members::load(&st, id).await?)))
}

#[derive(Deserialize)]
pub struct CreateMember {
    pub handle: String,
    pub name: String,
    pub role: Role,
    /// 不传则生成一次性邀请链接，由对方首次打开时自己设置密码（推荐）
    pub password: Option<String>,
    pub color: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub video_only: bool,
    #[serde(default)]
    pub guest_link: bool,
    #[serde(default)]
    pub device_ids: Vec<String>,
}

/// 生成新的邀请令牌，返回 (邀请链接, 过期时间)
async fn new_invite(st: &AppState, member_id: Uuid) -> AppResult<(String, DateTime<Utc>)> {
    let token = auth::generate_secret("inv");
    let expires = Utc::now() + Duration::seconds(st.cfg.invite_ttl_secs);
    sqlx::query("UPDATE members SET invite_token_hash = $2, invite_expires_at = $3 WHERE id = $1")
        .bind(member_id)
        .bind(auth::hash_secret(&token))
        .bind(expires)
        .execute(&st.db)
        .await?;
    Ok((format!("{}{token}", st.cfg.invite_url_base), expires))
}

async fn set_grants(st: &AppState, member_id: Uuid, device_ids: &[String]) -> AppResult<()> {
    let mut tx = st.db.begin().await?;
    sqlx::query("DELETE FROM device_grants WHERE member_id = $1")
        .bind(member_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "INSERT INTO device_grants (member_id, device_id)
         SELECT $1, d FROM unnest($2::text[]) d ON CONFLICT DO NOTHING",
    )
    .bind(member_id)
    .bind(device_ids)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(())
}

/// POST /members：邀请成员（仅管理员）
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CreateMember>,
) -> AppResult<(StatusCode, Json<Value>)> {
    user.require(Perm::ManageMembers)?;
    let handle = normalize_handle(&req.handle)
        .ok_or_else(|| AppError::bad_request("账号只能包含 2–32 位小写字母、数字、_ . -"))?;
    let name = req.name.trim();
    if name.is_empty() || name.chars().count() > 32 {
        return Err(AppError::bad_request("请填写 1–32 个字的名字"));
    }
    if let Some(c) = &req.color
        && !valid_color(c)
    {
        return Err(AppError::bad_request("颜色格式应为 #RRGGBB"));
    }
    let hash = match req.password {
        Some(p) => {
            auth::check_password_policy(&p).map_err(AppError::bad_request)?;
            Some(auth::hash_password_async(p).await?)
        }
        None => None,
    };

    let row: MemberRow = sqlx::query_as(
        "INSERT INTO members (handle, name, password_hash, role, color, expires_at, video_only, guest_link)
         VALUES ($1, $2, $3, $4, COALESCE($5, '#8E8E93'), $6, $7, $8) RETURNING *",
    )
    .bind(&handle)
    .bind(name)
    .bind(&hash)
    .bind(req.role)
    .bind(req.color)
    .bind(req.expires_at)
    .bind(req.video_only)
    .bind(req.guest_link)
    .fetch_one(&st.db)
    .await
    .map_err(|e| match AppError::from(e) {
        AppError::Conflict(_) => AppError::conflict(format!("账号 @{handle} 已存在")),
        other => other,
    })?;

    if !req.device_ids.is_empty() {
        set_grants(&st, row.id, &req.device_ids).await?;
    }
    let invite = if hash.is_none() {
        Some(new_invite(&st, row.id).await?)
    } else {
        None
    };

    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("邀请 {} 加入，角色为{}", row.name, role_label(row.role)),
        &row.name,
        json!({ "role": row.role, "invite": invite.is_some() }),
    )
    .await;
    changed(&st, row.id);
    let member = members::load(&st, row.id).await?;
    Ok((
        StatusCode::CREATED,
        Json(json!({
            "member": member,
            "invite_url": invite.as_ref().map(|i| &i.0),
            "invite_expires_at": invite.as_ref().map(|i| i.1),
        })),
    ))
}

/// POST /members/{id}/invite：为尚未激活的成员重新生成邀请链接（旧链接失效）
pub async fn reinvite(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Value>> {
    user.require(Perm::ManageMembers)?;
    let row: MemberRow = sqlx::query_as("SELECT * FROM members WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("成员不存在"))?;
    if !row.pending_invite() {
        return Err(AppError::conflict(format!(
            "{} 已经激活，无需重新邀请",
            row.name
        )));
    }
    let (url, expires) = new_invite(&st, id).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("重新生成 {} 的邀请链接", row.name),
        &row.name,
        json!({}),
    )
    .await;
    Ok(Json(
        json!({ "invite_url": url, "invite_expires_at": expires }),
    ))
}

#[derive(Deserialize)]
pub struct UpdateMember {
    pub name: Option<String>,
    pub role: Option<Role>,
    pub color: Option<String>,
    /// null = 长期有效
    #[serde(default, deserialize_with = "double_option")]
    pub expires_at: Option<Option<DateTime<Utc>>>,
    pub disabled: Option<bool>,
    pub video_only: Option<bool>,
    pub guest_link: Option<bool>,
}

/// PATCH /members/{id}
///
/// - 本人只能改名字、颜色；其余字段只有管理员能改
/// - 不能修改自己的角色，不能停用自己
/// - 至少保留一名可用的平台管理员
pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMember>,
) -> AppResult<Json<Member>> {
    let is_self = id == user.id;
    let privileged = req.role.is_some()
        || req.expires_at.is_some()
        || req.disabled.is_some()
        || req.video_only.is_some()
        || req.guest_link.is_some();
    if !is_self || privileged {
        user.require(Perm::ManageMembers)?;
    }
    if is_self && req.role.is_some_and(|r| r != user.role) {
        return Err(AppError::forbidden("不能修改自己的角色"));
    }
    if is_self && req.disabled == Some(true) {
        return Err(AppError::forbidden("不能停用自己"));
    }
    if let Some(c) = &req.color
        && !valid_color(c)
    {
        return Err(AppError::bad_request("颜色格式应为 #RRGGBB"));
    }
    if let Some(n) = &req.name
        && (n.trim().is_empty() || n.chars().count() > 32)
    {
        return Err(AppError::bad_request("请填写 1–32 个字的名字"));
    }

    let before: MemberRow = sqlx::query_as("SELECT * FROM members WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("成员不存在"))?;

    let loses_admin = before.role == Role::Admin
        && (req.role.is_some_and(|r| r != Role::Admin) || req.disabled == Some(true));
    if loses_admin && members::other_active_admins(&st, id).await? == 0 {
        return Err(AppError::conflict("至少要保留一名平台管理员"));
    }

    let row: MemberRow = sqlx::query_as(
        "UPDATE members SET
            name = COALESCE($2, name), role = COALESCE($3, role), color = COALESCE($4, color),
            expires_at = CASE WHEN $5 THEN $6 ELSE expires_at END,
            disabled = COALESCE($7, disabled), video_only = COALESCE($8, video_only),
            guest_link = COALESCE($9, guest_link)
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name.as_deref().map(str::trim))
    .bind(req.role)
    .bind(&req.color)
    .bind(req.expires_at.is_some())
    .bind(req.expires_at.flatten())
    .bind(req.disabled)
    .bind(req.video_only)
    .bind(req.guest_link)
    .fetch_one(&st.db)
    .await?;

    if req.disabled == Some(true) {
        members::revoke_sessions(&st, id, None).await?;
    }

    let mut changes = Vec::new();
    if row.role != before.role {
        changes.push(format!(
            "将 {} 的角色从{}改为{}",
            row.name,
            role_label(before.role),
            role_label(row.role)
        ));
    }
    if row.disabled != before.disabled {
        changes.push(format!(
            "{}了 {}",
            if row.disabled { "停用" } else { "启用" },
            row.name
        ));
    }
    if row.expires_at != before.expires_at {
        changes.push(match row.expires_at {
            Some(t) => format!(
                "将 {} 的有效期设为 {}",
                row.name,
                t.format("%Y-%m-%d %H:%M")
            ),
            None => format!("将 {} 设为长期有效", row.name),
        });
    }
    if row.name != before.name {
        changes.push(format!("将 {} 改名为 {}", before.name, row.name));
    }
    if !changes.is_empty() {
        audit::record(
            &st,
            &user,
            audit::Kind::Config,
            changes.join("；"),
            &row.name,
            json!({ "role": row.role, "disabled": row.disabled }),
        )
        .await;
    }
    changed(&st, id);
    Ok(Json(members::view(&st, row).await?))
}

/// DELETE /members/{id}
pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::ManageMembers)?;
    if id == user.id {
        return Err(AppError::forbidden("不能移除自己"));
    }
    let role: Option<Role> = sqlx::query_scalar("SELECT role FROM members WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
    let role = role.ok_or_else(|| AppError::not_found("成员不存在"))?;
    if role == Role::Admin && members::other_active_admins(&st, id).await? == 0 {
        return Err(AppError::conflict("至少要保留一名平台管理员"));
    }
    let name: String = sqlx::query_scalar("DELETE FROM members WHERE id = $1 RETURNING name")
        .bind(id)
        .fetch_one(&st.db)
        .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("移除成员 {name}"),
        &name,
        json!({}),
    )
    .await;
    changed(&st, id);
    Ok(StatusCode::NO_CONTENT)
}

pub async fn grants(
    State(st): State<AppState>,
    _user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<String>>> {
    Ok(Json(
        sqlx::query_scalar(
            "SELECT device_id FROM device_grants WHERE member_id = $1 ORDER BY device_id",
        )
        .bind(id)
        .fetch_all(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
pub struct SetGrants {
    pub device_ids: Vec<String>,
}

/// PUT /members/{id}/devices：管理员可分配任意设备；设备管理者只能增减自己管理的设备
pub async fn put_grants(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<SetGrants>,
) -> AppResult<Json<Vec<String>>> {
    match user.access(Perm::AssignUsers) {
        Access::None => return Err(AppError::forbidden("没有权限分配设备")),
        Access::All => set_grants(&st, id, &req.device_ids).await?,
        Access::Scoped => {
            let mut tx = st.db.begin().await?;
            let owned: Vec<String> =
                sqlx::query_scalar("SELECT id FROM devices WHERE owner_id = $1 AND id = ANY($2)")
                    .bind(user.id)
                    .bind(&req.device_ids)
                    .fetch_all(&mut *tx)
                    .await?;
            if owned.len() != req.device_ids.len() {
                return Err(AppError::forbidden("只能分配你管理的设备"));
            }
            sqlx::query(
                "DELETE FROM device_grants WHERE member_id = $1
                 AND device_id IN (SELECT id FROM devices WHERE owner_id = $2)",
            )
            .bind(id)
            .bind(user.id)
            .execute(&mut *tx)
            .await?;
            sqlx::query(
                "INSERT INTO device_grants (member_id, device_id)
                 SELECT $1, d FROM unnest($2::text[]) d ON CONFLICT DO NOTHING",
            )
            .bind(id)
            .bind(&req.device_ids)
            .execute(&mut *tx)
            .await?;
            tx.commit().await?;
        }
    }
    let name = audit::member_label(&st, id).await;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("调整 {name} 的授权设备（共 {} 台）", req.device_ids.len()),
        &name,
        json!({ "device_ids": req.device_ids }),
    )
    .await;
    changed(&st, id);
    grants(State(st), user, Path(id)).await
}

// ───────── 审计 ─────────

#[derive(Deserialize)]
pub struct AuditQuery {
    pub limit: Option<i64>,
    /// 分页：只返回 id 小于它的记录
    pub before: Option<i64>,
    /// control | alert | terminal | config | system
    pub kind: Option<String>,
}

async fn query_audit(st: &AppState, q: &AuditQuery, max: i64) -> AppResult<Vec<AuditEntry>> {
    Ok(sqlx::query_as(
        "SELECT id, ts AS at, actor_name AS actor, actor_id, action, target, kind, client, detail
         FROM audit_log
         WHERE ($1::bigint IS NULL OR id < $1) AND ($2::text IS NULL OR kind = $2)
         ORDER BY id DESC LIMIT $3",
    )
    .bind(q.before)
    .bind(&q.kind)
    .bind(q.limit.unwrap_or(100).clamp(1, max))
    .fetch_all(&st.db)
    .await?)
}

pub async fn audit(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<AuditQuery>,
) -> AppResult<Json<Vec<AuditEntry>>> {
    user.require(Perm::ManageMembers)?;
    Ok(Json(query_audit(&st, &q, 500).await?))
}

/// GET /audit.csv：导出（UTF-8 BOM，Excel 可直接打开）
pub async fn audit_csv(
    State(st): State<AppState>,
    user: AuthUser,
    Query(mut q): Query<AuditQuery>,
) -> AppResult<impl IntoResponse> {
    user.require(Perm::ManageMembers)?;
    q.limit = Some(q.limit.unwrap_or(10_000));
    let rows = query_audit(&st, &q, 50_000).await?;
    let esc = |s: &str| format!("\"{}\"", s.replace('"', "\"\""));
    let mut out = String::from("\u{feff}时间,操作人,操作,对象,分类,客户端\n");
    for r in rows {
        out.push_str(&format!(
            "{},{},{},{},{},{}\n",
            r.at.to_rfc3339(),
            esc(&r.actor),
            esc(&r.action),
            esc(&r.target),
            r.kind,
            esc(&r.client)
        ));
    }
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("{} 导出了审计日志", user.name),
        "审计日志",
        json!({}),
    )
    .await;
    Ok((
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8"),
            (
                header::CONTENT_DISPOSITION,
                "attachment; filename=\"uniconsole-audit.csv\"",
            ),
        ],
        out,
    ))
}
