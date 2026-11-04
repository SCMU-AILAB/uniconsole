//! 通用键值配置（server_settings 表）：通知渠道、值班、维护窗口、固件版本等。

use serde_json::Value;

use crate::{error::AppResult, state::AppState};

pub async fn get(st: &AppState, key: &str, default: Value) -> AppResult<Value> {
    let v: Option<Value> = sqlx::query_scalar("SELECT value FROM server_settings WHERE key = $1")
        .bind(key)
        .fetch_optional(&st.db)
        .await?;
    Ok(v.unwrap_or(default))
}

pub async fn put(st: &AppState, key: &str, value: &Value) -> AppResult<()> {
    sqlx::query(
        "INSERT INTO server_settings (key, value) VALUES ($1, $2)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()",
    )
    .bind(key)
    .bind(value)
    .execute(&st.db)
    .await?;
    Ok(())
}
