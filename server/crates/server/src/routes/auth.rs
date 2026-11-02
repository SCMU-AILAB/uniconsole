use axum::{Json, extract::State};
use chrono::Utc;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    auth::{self, AuthUser},
    error::{AppError, AppResult},
    models::{Member, MemberRow},
    state::AppState,
};

#[derive(Deserialize)]
pub struct LoginReq {
    pub handle: String,
    pub password: String,
}

pub async fn login(
    State(st): State<AppState>,
    Json(req): Json<LoginReq>,
) -> AppResult<Json<Value>> {
    let handle = req.handle.trim().trim_start_matches('@').to_owned();
    let row: Option<MemberRow> = sqlx::query_as("SELECT * FROM members WHERE handle = $1")
        .bind(&handle)
        .fetch_optional(&st.db)
        .await?;

    let hash = row.as_ref().map(|r| r.password_hash.clone());
    let ok = auth::verify_password_async(req.password, hash).await;

    let row = match row {
        Some(r) if ok => r,
        _ => return Err(AppError::Unauthorized),
    };
    if row.disabled || row.expires_at.is_some_and(|e| e <= Utc::now()) {
        return Err(AppError::forbidden("账号已停用或已过期"));
    }

    let token = auth::issue_token(
        &st.cfg.jwt_secret,
        st.cfg.jwt_ttl_secs,
        row.id,
        &row.name,
        row.role,
    )?;
    sqlx::query("UPDATE members SET last_seen_at = now() WHERE id = $1")
        .bind(row.id)
        .execute(&st.db)
        .await?;

    Ok(Json(json!({
        "token": token,
        "expires_in": st.cfg.jwt_ttl_secs,
        "member": Member::from(row),
    })))
}

pub async fn me(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Member>> {
    let row: MemberRow = sqlx::query_as("SELECT * FROM members WHERE id = $1")
        .bind(user.id)
        .fetch_optional(&st.db)
        .await?
        .ok_or(AppError::Unauthorized)?;
    Ok(Json(row.into()))
}
