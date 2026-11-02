use serde_json::Value;
use sqlx::PgPool;

use crate::auth::AuthUser;

/// 写审计日志。失败只记录错误，不影响主流程。
pub async fn record(db: &PgPool, actor: &AuthUser, action: &str, target: &str, detail: Value) {
    let res = sqlx::query(
        "INSERT INTO audit_log (actor_id, actor_name, action, target, client, detail)
         VALUES ($1, $2, $3, $4, $5, $6)",
    )
    .bind(actor.id)
    .bind(&actor.name)
    .bind(action)
    .bind(target)
    .bind(&actor.client)
    .bind(detail)
    .execute(db)
    .await;
    if let Err(e) = res {
        tracing::error!(error = %e, action, "写审计日志失败");
    }
}

/// 系统动作（租约过期、自动告警处理）的审计
pub async fn record_system(db: &PgPool, action: &str, target: &str, detail: Value) {
    let res = sqlx::query(
        "INSERT INTO audit_log (actor_name, action, target, client, detail)
         VALUES ('系统', $1, $2, 'server', $3)",
    )
    .bind(action)
    .bind(target)
    .bind(detail)
    .execute(db)
    .await;
    if let Err(e) = res {
        tracing::error!(error = %e, action, "写审计日志失败");
    }
}
