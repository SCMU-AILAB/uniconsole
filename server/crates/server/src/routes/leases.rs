//! 控制权（Lease.dc.html）。

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
    models::{Lease, LeaseHolderKind, LeaseRequest},
    protocol::ServerEvent,
    services::{
        access, audit, events,
        leases::{AcquireOutcome, TransferTarget},
    },
    state::AppState,
};

#[derive(Serialize)]
pub struct LeaseRow {
    pub device_id: String,
    pub name: String,
    pub code: String,
    /// 含 queue；无人控制时为 null
    pub lease: Option<Lease>,
    /// 持有者显示名（成员名 / 联调会话名 / 任务名）
    pub holder_name: Option<String>,
    /// 申请队列（无人控制时也可能有未处理的申请）
    pub queue: Vec<LeaseRequest>,
}

/// GET /leases：每台可见设备的租约与完整申请队列
pub async fn overview(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<LeaseRow>>> {
    let visible = access::visible_devices(&st.db, &user).await?;
    let rows: Vec<(String, String, String, Option<String>)> = sqlx::query_as(
        "SELECT d.id, d.name, d.code, COALESCE(m.name, fs.name, mi.name)
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
    let ids: Vec<String> = rows.iter().map(|r| r.0.clone()).collect();
    let mut queues = st.leases.queues(&ids).await?;
    Ok(Json(
        rows.into_iter()
            .map(|(device_id, name, code, holder_name)| {
                let queue = queues.remove(&device_id).unwrap_or_default();
                let lease = st.leases.current(&device_id).map(|mut l| {
                    l.queue = queue.clone();
                    l
                });
                LeaseRow {
                    holder_name: lease.as_ref().and(holder_name),
                    lease,
                    device_id,
                    name,
                    code,
                    queue,
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

/// POST /devices/{id}/lease
pub async fn acquire(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    body: Option<Json<AcquireReq>>,
) -> AppResult<Json<AcquireOutcome>> {
    access::require_device(&st.db, &user, Perm::HoldLease, &id).await?;
    let req = body.map(|Json(b)| b).unwrap_or_default();
    let term = st.safety.policies().lease_term_secs;
    let reason = req.reason.clone();
    let out = st
        .leases
        .acquire(&user, &id, req.reason, req.expected_secs, term)
        .await?;
    let label = audit::device_label(&st, &id).await;
    match &out {
        AcquireOutcome::Granted { .. } => {
            events::record(&st, &id, format!("{} 获得控制权", user.name), "info").await;
            audit::record(
                &st,
                &user,
                audit::Kind::Control,
                format!("获取 {label} 的控制权"),
                &label,
                json!({}),
            )
            .await;
        }
        AcquireOutcome::Queued { .. } => {
            events::record(&st, &id, format!("{} 申请控制权", user.name), "neutral").await;
            if let Some(holder) = st.leases.current(&id).and_then(|l| {
                (l.holder_kind == LeaseHolderKind::User)
                    .then_some(l.holder_id)
                    .flatten()
            }) {
                st.hub.publish(ServerEvent::Notice {
                    member_id: holder,
                    level: "info".into(),
                    text: format!(
                        "{} 申请 {label} 的控制权：{}",
                        user.name,
                        if reason.is_empty() {
                            "未填写原因"
                        } else {
                            &reason
                        }
                    ),
                });
            }
            audit::record(
                &st,
                &user,
                audit::Kind::Control,
                format!("申请 {label} 的控制权"),
                &label,
                json!({ "reason": reason }),
            )
            .await;
        }
    }
    Ok(Json(out))
}

/// POST /devices/{id}/lease/renew
pub async fn renew(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Lease>> {
    let p = st.safety.policies();
    let lease = st
        .leases
        .renew(
            &user,
            &id,
            p.lease_term_secs,
            p.lease_expiry_action == "stop_only",
        )
        .await?;
    Ok(Json(st.leases.full(&id).await?.unwrap_or(lease)))
}

#[derive(Deserialize, Default)]
pub struct ReleaseQuery {
    #[serde(default)]
    pub force: bool,
    pub reason: Option<String>,
}

#[derive(Deserialize, Default)]
pub struct ReleaseBody {
    pub reason: Option<String>,
}

/// DELETE /devices/{id}/lease?force=true&reason=…（reason 也可以放在 body）
pub async fn release(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Query(q): Query<ReleaseQuery>,
    body: Option<Json<ReleaseBody>>,
) -> AppResult<StatusCode> {
    let label = audit::device_label(&st, &id).await;
    if !q.force {
        st.leases.release(&id, Some(user.id)).await?;
        events::record(&st, &id, format!("{} 释放控制权", user.name), "neutral").await;
        audit::record(
            &st,
            &user,
            audit::Kind::Control,
            format!("释放 {label} 的控制权"),
            &label,
            json!({}),
        )
        .await;
        return Ok(StatusCode::NO_CONTENT);
    }

    // 强制收回：设备管理者、平台管理员
    access::require_device(&st.db, &user, Perm::AssignUsers, &id).await?;
    if !user.is_admin() && !st.leases.is_device_owner(user.id, &id).await? {
        return Err(crate::error::AppError::forbidden(
            "只有设备管理者或平台管理员可以强制收回",
        ));
    }
    let reason = q
        .reason
        .or(body.and_then(|Json(b)| b.reason))
        .filter(|r| !r.trim().is_empty())
        .unwrap_or_else(|| "未填写原因".into());
    let lease = st.leases.release(&id, None).await?;
    let holder_name = match lease.holder_kind {
        LeaseHolderKind::User => {
            audit::member_label(&st, lease.holder_id.unwrap_or_default()).await
        }
        _ => lease.source.clone(),
    };
    if let (LeaseHolderKind::User, Some(h)) = (lease.holder_kind, lease.holder_id) {
        st.hub.publish(ServerEvent::Notice {
            member_id: h,
            level: "warning".into(),
            text: format!("{} 收回了你对 {label} 的控制权：{reason}", user.name),
        });
    }
    events::record(&st, &id, format!("{} 强制收回控制权", user.name), "warning").await;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("强制收回 {holder_name} 对 {label} 的控制权：{reason}"),
        &label,
        json!({ "reason": reason, "holder": lease.holder() }),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct TransferReq {
    #[serde(flatten)]
    pub target: TransferTarget,
    pub note: Option<String>,
}

/// POST /devices/{id}/lease/transfer {kind: user|task, id, note?}
pub async fn transfer(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
    Json(req): Json<TransferReq>,
) -> AppResult<Json<Lease>> {
    let label = audit::device_label(&st, &id).await;
    let term = st.safety.policies().lease_term_secs;
    let lease = st
        .leases
        .transfer(&user, &id, &label, &req.target, term)
        .await?;
    let note = req.note.filter(|n| !n.trim().is_empty());
    let target_name = match req.target {
        TransferTarget::User { id: m } => {
            st.hub.publish(ServerEvent::Notice {
                member_id: m,
                level: "info".into(),
                text: format!(
                    "{} 把 {label} 的控制权转交给你{}",
                    user.name,
                    note.as_deref()
                        .map(|n| format!("：{n}"))
                        .unwrap_or_default()
                ),
            });
            audit::member_label(&st, m).await
        }
        TransferTarget::Task { .. } => lease.source.clone(),
    };
    events::record(
        &st,
        &id,
        format!("{} 把控制权转交给 {target_name}", user.name),
        "info",
    )
    .await;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("把 {label} 的控制权转交给 {target_name}"),
        &label,
        json!({ "to": lease.holder(), "note": note }),
    )
    .await;
    Ok(Json(st.leases.full(&id).await?.unwrap_or(lease)))
}

pub async fn requests(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<Json<Vec<LeaseRequest>>> {
    access::require_device(&st.db, &user, Perm::ViewDevice, &id).await?;
    Ok(Json(st.leases.pending_requests(&id).await?))
}

/// POST /lease-requests/{id}/approve
pub async fn approve(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<Lease>> {
    let device: Option<String> =
        sqlx::query_scalar("SELECT device_id FROM lease_requests WHERE id = $1")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let label = audit::device_label(&st, device.as_deref().unwrap_or_default()).await;
    let (lease, req) = st.leases.approve(&user, id, &label).await?;
    let who = audit::member_label(&st, req.requester_id).await;
    st.hub.publish(ServerEvent::Notice {
        member_id: req.requester_id,
        level: "info".into(),
        text: format!("{} 批准了你对 {label} 的控制权申请", user.name),
    });
    events::record(
        &st,
        &req.device_id,
        format!("{} 批准 {who} 的控制权申请", user.name),
        "info",
    )
    .await;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("批准 {who} 的控制权申请（{label}）"),
        &label,
        json!({ "request_id": id }),
    )
    .await;
    Ok(Json(st.leases.full(&req.device_id).await?.unwrap_or(lease)))
}

/// POST /lease-requests/{id}/deny
pub async fn deny(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<LeaseRequest>> {
    let req = st.leases.deny(&user, id).await?;
    let (label, who) = (
        audit::device_label(&st, &req.device_id).await,
        audit::member_label(&st, req.requester_id).await,
    );
    st.hub.publish(ServerEvent::Notice {
        member_id: req.requester_id,
        level: "warning".into(),
        text: format!("{} 拒绝了你对 {label} 的控制权申请", user.name),
    });
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("拒绝 {who} 的控制权申请（{label}）"),
        &label,
        json!({ "request_id": id }),
    )
    .await;
    Ok(Json(req))
}
