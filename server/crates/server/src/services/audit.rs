//! 审计日志。`action` 写成完整的人话（如「批准 林悦 的控制权申请（Alpha）」），前端直接显示。
//! 写入失败只记日志，不影响主流程；成功后推送 `changed: audit`。

use serde_json::Value;
use uuid::Uuid;

use crate::{auth::AuthUser, models::AuditKind, protocol::ServerEvent, state::AppState};

pub use crate::models::AuditKind as Kind;

#[allow(clippy::too_many_arguments)]
async fn insert(
    st: &AppState,
    actor_id: Option<Uuid>,
    actor_name: &str,
    client: &str,
    kind: AuditKind,
    action: &str,
    target: &str,
    detail: Value,
) {
    let res = sqlx::query(
        "INSERT INTO audit_log (actor_id, actor_name, action, target, client, kind, detail)
         VALUES ($1, $2, $3, $4, $5, $6, $7)",
    )
    .bind(actor_id)
    .bind(actor_name)
    .bind(action)
    .bind(target)
    .bind(client)
    .bind(kind.as_str())
    .bind(detail)
    .execute(&st.db)
    .await;
    match res {
        Ok(_) => st
            .hub
            .publish(ServerEvent::changed("audit", None::<String>)),
        Err(e) => tracing::error!(error = %e, action, "写审计日志失败"),
    }
}

/// 成员操作
pub async fn record(
    st: &AppState,
    actor: &AuthUser,
    kind: AuditKind,
    action: impl AsRef<str>,
    target: impl AsRef<str>,
    detail: Value,
) {
    insert(
        st,
        Some(actor.id),
        &actor.name,
        &actor.client,
        kind,
        action.as_ref(),
        target.as_ref(),
        detail,
    )
    .await;
}

/// 系统自动动作：actor 为「系统」，client 为「服务端」
pub async fn record_system(
    st: &AppState,
    kind: AuditKind,
    action: impl AsRef<str>,
    target: impl AsRef<str>,
    detail: Value,
) {
    insert(
        st,
        None,
        "系统",
        "服务端",
        kind,
        action.as_ref(),
        target.as_ref(),
        detail,
    )
    .await;
}

/// 设备显示名（审计和事件文案用），查不到时退回 id
pub async fn device_label(st: &AppState, device_id: &str) -> String {
    sqlx::query_scalar::<_, String>("SELECT name FROM devices WHERE id = $1")
        .bind(device_id)
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| device_id.to_owned())
}

/// 成员显示名
pub async fn member_label(st: &AppState, member_id: Uuid) -> String {
    sqlx::query_scalar::<_, String>("SELECT name FROM members WHERE id = $1")
        .bind(member_id)
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| "未知成员".to_owned())
}
