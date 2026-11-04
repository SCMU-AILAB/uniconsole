use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::{Deserialize, Serialize};
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::AppResult,
    models::{Lease, LeaseRequest},
    services::{
        access, audit,
        leases::{AcquireOutcome, TransferTarget},
    },
    state::AppState,
};

#[derive(Serialize)]
pub struct LeaseRow {
    pub device_id: String,
    pub name: String,
    pub code: String,
    pub lease: Option<Lease>,
    pub holder_name: Option<String>,
    pub queue_len: i64,
}

/// 租约总表（Lease.dc.html 左侧表格）
pub async fn overview(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<LeaseRow>>> {
    let visible = access::visible_devices(&st.db, &user).await?;
    let rows: Vec<(String, String, String, Option<String>, i64)> = sqlx::query_as(
        "SELECT d.id, d.name, d.code,
                COALESCE(m.name, fs.name, mi.name),
                (SELECT count(*) FROM lease_requests r WHERE r.device_id = d.id AND r.state = 'pending')
         FROM devices d
         LEFT JOIN leases l ON l.device_id = d.id
         LEFT JOIN members m ON m.id = l.holder_id
         LEFT JOIN fleet_sessions fs ON fs.id = l.session_id
         LEFT JOIN missions mi ON mi.id = l.task_id
         WHERE ($1::text[] IS NULL OR d.id = ANY($1))
         ORDER BY d.code",
    )
    .bind(visible)
    .fetch_all(&st.db)
    .await?;
    Ok(Json(
        rows.into_iter()
            .map(|(device_id, name, code, holder_name, queue_len)| {
                let lease = st.leases.current(&device_id);
                LeaseRow {
                    holder_name: lease.as_ref().and(holder_name),
                    lease,
                    device_id,
                    name,
                    code,
                    queue_len,
                }
            })
            .collect(),
    ))
}

#[derive(Deserialize, Default)]
pub struct AcquireReq {
    #[serde(default)]
    pub reason: String,
    pub expected_secs: Option<i32>,
}

pub async fn acquire(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    body: Option<Json<AcquireReq>>,
) -> AppResult<Json<AcquireOutcome>> {
    access::require_device(&st.db, &user, Perm::HoldLease, &id).await?;
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let out = st
        .leases
        .acquire(&user, &id, req.reason, req.expected_secs)
        .await?;
    let action = match &out {
        AcquireOutcome::Granted { .. } => "获取控制权",
        AcquireOutcome::Queued { .. } => "申请控制权",
    };
    audit::record(&st, &user, audit::Kind::Control, action, &id, json!({})).await;
    Ok(Json(out))
}

pub async fn renew(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Lease>> {
    Ok(Json(st.leases.renew(&user, &id).await?))
}

#[derive(Deserialize)]
pub struct ReleaseQuery {
    #[serde(default)]
    pub force: bool,
}

pub async fn release(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<ReleaseQuery>,
) -> AppResult<StatusCode> {
    if q.force {
        // 强制收回：设备管理范围内的管理员 / 管理者
        access::require_device(&st.db, &user, Perm::AssignUsers, &id).await?;
    }
    st.leases.release(&user, &id, q.force).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        if q.force {
            "强制收回控制权"
        } else {
            "释放控制权"
        },
        &id,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

pub async fn transfer(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(target): Json<TransferTarget>,
) -> AppResult<Json<Lease>> {
    let lease = st.leases.transfer(&user, &id, target).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        "转移控制权",
        &id,
        json!({ "to": lease.holder_id.or(lease.task_id) }),
    )
    .await;
    Ok(Json(lease))
}

pub async fn requests(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Vec<LeaseRequest>>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    Ok(Json(st.leases.pending_requests(&id).await?))
}

pub async fn approve(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Lease>> {
    let lease = st.leases.approve(&user, id).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        "批准控制权申请",
        &lease.device_id,
        json!({ "request_id": id }),
    )
    .await;
    Ok(Json(lease))
}

pub async fn deny(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<LeaseRequest>> {
    let req = st.leases.deny(&user, id).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        "拒绝控制权申请",
        &req.device_id,
        json!({ "request_id": id }),
    )
    .await;
    Ok(Json(req))
}
