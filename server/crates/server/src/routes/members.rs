use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use serde::Deserialize;
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth::{self, Access, AuthUser, Perm},
    error::{AppError, AppResult},
    models::{AuditEntry, Member, MemberRow, Role},
    services::audit,
    state::AppState,
};

pub async fn list(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Vec<Member>>> {
    let rows: Vec<MemberRow> = sqlx::query_as("SELECT * FROM members ORDER BY created_at")
        .fetch_all(&st.db)
        .await?;
    Ok(Json(rows.into_iter().map(Member::from).collect()))
}

#[derive(Deserialize)]
pub struct CreateMember {
    pub handle: String,
    pub name: String,
    pub password: String,
    pub role: Role,
    pub color: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
}

pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CreateMember>,
) -> AppResult<(StatusCode, Json<Member>)> {
    user.require(Perm::ManageMembers)?;
    if req.password.len() < 8 {
        return Err(AppError::bad_request("密码至少 8 位"));
    }
    let hash = auth::hash_password_async(req.password).await?;
    let row: MemberRow = sqlx::query_as(
        "INSERT INTO members (handle, name, password_hash, role, color, expires_at)
         VALUES ($1, $2, $3, $4, COALESCE($5, '#8E8E93'), $6) RETURNING *",
    )
    .bind(req.handle.trim().trim_start_matches('@'))
    .bind(&req.name)
    .bind(hash)
    .bind(req.role)
    .bind(req.color)
    .bind(req.expires_at)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st.db,
        &user,
        "添加成员",
        &row.name,
        json!({ "role": row.role }),
    )
    .await;
    Ok((StatusCode::CREATED, Json(row.into())))
}

#[derive(Deserialize)]
pub struct UpdateMember {
    pub name: Option<String>,
    pub role: Option<Role>,
    pub color: Option<String>,
    pub expires_at: Option<DateTime<Utc>>,
    pub disabled: Option<bool>,
    pub password: Option<String>,
}

pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateMember>,
) -> AppResult<Json<Member>> {
    // 本人可以改自己的名字、颜色、密码；其它字段需要管理员
    let is_self = id == user.id;
    let privileged = req.role.is_some() || req.expires_at.is_some() || req.disabled.is_some();
    if !is_self || privileged {
        user.require(Perm::ManageMembers)?;
    }
    let hash = match req.password {
        Some(p) if p.len() < 8 => return Err(AppError::bad_request("密码至少 8 位")),
        Some(p) => Some(auth::hash_password_async(p).await?),
        None => None,
    };
    let row: MemberRow = sqlx::query_as(
        "UPDATE members SET name = COALESCE($2, name), role = COALESCE($3, role), color = COALESCE($4, color),
         expires_at = COALESCE($5, expires_at), disabled = COALESCE($6, disabled),
         password_hash = COALESCE($7, password_hash)
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.name)
    .bind(req.role)
    .bind(req.color)
    .bind(req.expires_at)
    .bind(req.disabled)
    .bind(hash)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("成员不存在"))?;
    if privileged {
        audit::record(
            &st.db,
            &user,
            "修改成员权限",
            &row.name,
            json!({ "role": row.role, "disabled": row.disabled }),
        )
        .await;
    }
    Ok(Json(row.into()))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::ManageMembers)?;
    if id == user.id {
        return Err(AppError::bad_request("不能删除自己"));
    }
    let name: Option<(String,)> =
        sqlx::query_as("DELETE FROM members WHERE id = $1 RETURNING name")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (name,) = name.ok_or_else(|| AppError::not_found("成员不存在"))?;
    audit::record(&st.db, &user, "移除成员", &name, json!({})).await;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn grants(
    State(st): State<AppState>,
    _user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Vec<String>>> {
    let rows: Vec<(String,)> = sqlx::query_as(
        "SELECT device_id FROM device_grants WHERE member_id = $1 ORDER BY device_id",
    )
    .bind(id)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows.into_iter().map(|(d,)| d).collect()))
}

#[derive(Deserialize)]
pub struct SetGrants {
    pub device_ids: Vec<String>,
}

/// 分配使用者：管理员可分配任意设备；设备管理者只能分配自己管理的设备
pub async fn set_grants(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<SetGrants>,
) -> AppResult<Json<Vec<String>>> {
    let access = user.access(Perm::AssignUsers);
    if access == Access::None {
        return Err(AppError::forbidden("没有权限分配设备"));
    }

    let mut tx = st.db.begin().await?;
    if access == Access::All {
        sqlx::query("DELETE FROM device_grants WHERE member_id = $1")
            .bind(id)
            .execute(&mut *tx)
            .await?;
    } else {
        // 只改动自己管理的设备
        sqlx::query(
            "DELETE FROM device_grants WHERE member_id = $1
             AND device_id IN (SELECT id FROM devices WHERE owner_id = $2)",
        )
        .bind(id)
        .bind(user.id)
        .execute(&mut *tx)
        .await?;
        let owned: Vec<(String,)> =
            sqlx::query_as("SELECT id FROM devices WHERE owner_id = $1 AND id = ANY($2)")
                .bind(user.id)
                .bind(&req.device_ids)
                .fetch_all(&mut *tx)
                .await?;
        if owned.len() != req.device_ids.len() {
            return Err(AppError::forbidden("只能分配你管理的设备"));
        }
    }
    sqlx::query(
        "INSERT INTO device_grants (member_id, device_id) SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING",
    )
    .bind(id)
    .bind(&req.device_ids)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    audit::record(
        &st.db,
        &user,
        "分配设备",
        &id.to_string(),
        json!({ "device_ids": req.device_ids }),
    )
    .await;
    grants(State(st), user, Path(id)).await
}

#[derive(Deserialize)]
pub struct AuditQuery {
    pub limit: Option<i64>,
    pub before: Option<i64>,
}

pub async fn audit(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<AuditQuery>,
) -> AppResult<Json<Vec<AuditEntry>>> {
    user.require(Perm::ManageMembers)?;
    let rows = sqlx::query_as(
        "SELECT * FROM audit_log WHERE ($1::bigint IS NULL OR id < $1) ORDER BY id DESC LIMIT $2",
    )
    .bind(q.before)
    .bind(q.limit.unwrap_or(100).clamp(1, 500))
    .fetch_all(&st.db)
    .await?;
    Ok(Json(rows))
}
