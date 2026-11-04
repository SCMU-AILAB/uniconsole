//! 设备事件（Main 页「最近事件」、设备详情）：写库并推送 WS `device_event`。

use crate::{models::DeviceEvent, protocol::ServerEvent, state::AppState};

/// tone：info | success | warning | critical | neutral
pub async fn record(st: &AppState, device_id: &str, text: impl Into<String>, tone: &str) {
    let text = text.into();
    let res: Result<DeviceEvent, _> = sqlx::query_as(
        "INSERT INTO device_events (device_id, text, tone) VALUES ($1, $2, $3)
         RETURNING at, text, tone",
    )
    .bind(device_id)
    .bind(&text)
    .bind(tone)
    .fetch_one(&st.db)
    .await;
    match res {
        Ok(event) => st.hub.publish(ServerEvent::DeviceEvent {
            device_id: device_id.to_owned(),
            event,
        }),
        Err(e) => tracing::warn!(error = %e, device = device_id, "写设备事件失败"),
    }
}
