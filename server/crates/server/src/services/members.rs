//! 成员视图组装：数据库行 + 授权设备 + 在线状态。

use std::collections::HashMap;

use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    models::{Member, MemberRow},
    state::AppState,
};

pub async fn view(st: &AppState, row: MemberRow) -> AppResult<Member> {
    let grants: Vec<String> = sqlx::query_scalar(
        "SELECT device_id FROM device_grants WHERE member_id = $1 ORDER BY device_id",
    )
    .bind(row.id)
    .fetch_all(&st.db)
    .await?;
    let online = st.hub.is_user_online(row.id);
    Ok(Member::from_row(row, grants, online))
}

pub async fn load(st: &AppState, id: Uuid) -> AppResult<Member> {
    let row: MemberRow = sqlx::query_as("SELECT * FROM members WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("成员不存在"))?;
    view(st, row).await
}

pub async fn list(st: &AppState) -> AppResult<Vec<Member>> {
    let rows: Vec<MemberRow> = sqlx::query_as("SELECT * FROM members ORDER BY created_at")
        .fetch_all(&st.db)
        .await?;
    let grants: Vec<(Uuid, String)> =
        sqlx::query_as("SELECT member_id, device_id FROM device_grants ORDER BY device_id")
            .fetch_all(&st.db)
            .await?;
    let mut by_member: HashMap<Uuid, Vec<String>> = HashMap::new();
    for (m, d) in grants {
        by_member.entry(m).or_default().push(d);
    }
    Ok(rows
        .into_iter()
        .map(|r| {
            let g = by_member.remove(&r.id).unwrap_or_default();
            let online = st.hub.is_user_online(r.id);
            Member::from_row(r, g, online)
        })
        .collect())
}

/// 除 `except` 之外仍可用的平台管理员数量（「至少保留一名管理员」规则）
pub async fn other_active_admins(st: &AppState, except: Uuid) -> AppResult<i64> {
    Ok(sqlx::query_scalar(
        "SELECT count(*) FROM members
         WHERE role = 'admin' AND NOT disabled AND id <> $1
           AND (expires_at IS NULL OR expires_at > now())",
    )
    .bind(except)
    .fetch_one(&st.db)
    .await?)
}

/// 吊销某成员的全部会话（停用、改密码时）
pub async fn revoke_sessions(st: &AppState, member_id: Uuid, keep: Option<Uuid>) -> AppResult<()> {
    sqlx::query(
        "UPDATE sessions SET revoked_at = now()
         WHERE member_id = $1 AND revoked_at IS NULL AND ($2::uuid IS NULL OR id <> $2)",
    )
    .bind(member_id)
    .bind(keep)
    .execute(&st.db)
    .await?;
    Ok(())
}
