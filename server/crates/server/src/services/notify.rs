//! 告警通知（Alerts.dc.html 右栏「通知渠道」「值班」）。
//!
//! 通知渠道 `alert_channels`：`[{name, min_severity, kind?, url?, format?}]`
//! - `kind: "in_app"`（缺省）：应用内推送，前端靠 WS `alert` 弹横幅，服务端无需额外发送；
//! - `kind: "webhook"`：告警触发 / 升级时 POST 到 `url`。`format` 决定请求体：
//!   `json`（缺省，完整告警对象）、`feishu`、`dingtalk`、`wecom`（企业微信）、`slack`（都是纯文本消息）。
//!
//! 值班 `on_call`：`{weeks: [成员 id], escalate_after_secs, escalate_to_id}`
//! - 告警触发（warning 及以上）时给本周值班人（`weeks[0]`）发应用内提示；
//! - 超过 `escalate_after_secs` 仍未确认（state 仍为 open、未静默）则升级：提示 `escalate_to_id`，
//!   并再走一遍 webhook 渠道。每条告警只升级一次（`alerts.escalated_at`）。
//!
//! 每次通知 / 升级都写进告警时间线（tone = neutral）。

use std::time::Duration;

use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    error::AppResult,
    models::{Alert, AlertSeverity},
    protocol::ServerEvent,
    services::{alerting::add_event, audit, settings},
    state::AppState,
};

fn rank(s: AlertSeverity) -> u8 {
    match s {
        AlertSeverity::Info => 0,
        AlertSeverity::Warning => 1,
        AlertSeverity::Critical => 2,
    }
}

fn severity_from(s: &str) -> Option<AlertSeverity> {
    Some(match s {
        "info" => AlertSeverity::Info,
        "warning" => AlertSeverity::Warning,
        "critical" => AlertSeverity::Critical,
        _ => return None,
    })
}

fn severity_label(s: AlertSeverity) -> &'static str {
    match s {
        AlertSeverity::Critical => "严重",
        AlertSeverity::Warning => "警告",
        AlertSeverity::Info => "提示",
    }
}

pub const WEBHOOK_FORMATS: &[&str] = &["json", "feishu", "dingtalk", "wecom", "slack"];

/// 校验 PUT /alert-channels 的内容，返回给人看的错误
pub fn validate_channels(v: &Value) -> Result<(), String> {
    let Some(list) = v.as_array() else {
        return Err("格式应为 [{name, min_severity, kind?, url?, format?}]".into());
    };
    for c in list {
        let name = c["name"].as_str().unwrap_or_default();
        if name.is_empty() {
            return Err("每个渠道都需要 name".into());
        }
        if c["min_severity"].as_str().and_then(severity_from).is_none() {
            return Err(format!(
                "渠道「{name}」的 min_severity 只能是 critical、warning、info"
            ));
        }
        match c["kind"].as_str().unwrap_or("in_app") {
            "in_app" => {}
            "webhook" => {
                let url = c["url"].as_str().unwrap_or_default();
                if !(url.starts_with("https://") || url.starts_with("http://")) {
                    return Err(format!("渠道「{name}」需要 http(s) 开头的 url"));
                }
                let format = c["format"].as_str().unwrap_or("json");
                if !WEBHOOK_FORMATS.contains(&format) {
                    return Err(format!(
                        "渠道「{name}」的 format 只能是 {}",
                        WEBHOOK_FORMATS.join("、")
                    ));
                }
            }
            other => {
                return Err(format!(
                    "渠道「{name}」的 kind「{other}」不支持（in_app、webhook）"
                ));
            }
        }
    }
    Ok(())
}

/// webhook 地址里通常带密钥：非管理员只看到协议和主机
pub fn mask_channels(v: &Value) -> Value {
    let mut v = v.clone();
    if let Some(list) = v.as_array_mut() {
        for c in list {
            if let Some(url) = c.get("url").and_then(Value::as_str) {
                let host = url
                    .split_once("://")
                    .map(|(scheme, rest)| {
                        format!(
                            "{scheme}://{}/…",
                            rest.split('/').next().unwrap_or_default()
                        )
                    })
                    .unwrap_or_else(|| "…".into());
                c["url"] = json!(host);
            }
        }
    }
    v
}

/// 按渠道格式生成请求体
pub fn webhook_body(format: &str, text: &str, alert: &Value) -> Value {
    match format {
        "feishu" => json!({ "msg_type": "text", "content": { "text": text } }),
        "dingtalk" | "wecom" => json!({ "msgtype": "text", "text": { "content": text } }),
        "slack" => json!({ "text": text }),
        _ => json!({ "text": text, "alert": alert }),
    }
}

async fn load(st: &AppState, alert_id: Uuid) -> AppResult<Option<Alert>> {
    Ok(sqlx::query_as("SELECT * FROM alerts WHERE id = $1")
        .bind(alert_id)
        .fetch_optional(&st.db)
        .await?)
}

async fn device_name(st: &AppState, device_id: Option<&str>) -> String {
    match device_id {
        Some(id) => audit::device_label(st, id).await,
        None => "系统".into(),
    }
}

async fn member_name(st: &AppState, id: Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT name FROM members WHERE id = $1 AND NOT disabled")
        .bind(id)
        .fetch_optional(&st.db)
        .await
        .ok()
        .flatten()
}

/// 依次发送 webhook 渠道，结果写进告警时间线
async fn send_webhooks(st: &AppState, alert: &Alert, text: &str) {
    let channels = settings::get(st, "alert_channels", json!([]))
        .await
        .unwrap_or_default();
    let payload = serde_json::to_value(alert).unwrap_or_default();
    for c in channels.as_array().map(Vec::as_slice).unwrap_or_default() {
        if c["kind"].as_str() != Some("webhook") {
            continue;
        }
        let min = c["min_severity"]
            .as_str()
            .and_then(severity_from)
            .unwrap_or(AlertSeverity::Info);
        if rank(alert.severity) < rank(min) {
            continue;
        }
        let name = c["name"].as_str().unwrap_or("webhook");
        let Some(url) = c["url"].as_str() else {
            continue;
        };
        let body = webhook_body(c["format"].as_str().unwrap_or("json"), text, &payload);
        let res = st
            .http
            .post(url)
            .timeout(Duration::from_secs(10))
            .json(&body)
            .send()
            .await;
        let msg = match res {
            Ok(r) if r.status().is_success() => format!("已通过「{name}」通知"),
            Ok(r) => format!("通过「{name}」通知失败：HTTP {}", r.status().as_u16()),
            Err(e) => {
                tracing::warn!(error = %e, channel = name, "告警 webhook 发送失败");
                format!("通过「{name}」通知失败：无法连接")
            }
        };
        let _ = add_event(&st.db, alert.id, "neutral", &msg, None).await;
    }
}

/// 告警刚触发：webhook 渠道 + 本周值班人。在独立任务里调用（不阻塞机器人读循环）
pub async fn alert_raised(st: &AppState, alert_id: Uuid) {
    let Ok(Some(alert)) = load(st, alert_id).await else {
        return;
    };
    let device = device_name(st, alert.device_id.as_deref()).await;
    let location = alert
        .location
        .as_deref()
        .map(|l| format!(" · {l}"))
        .unwrap_or_default();
    let text = format!(
        "【{}】{device} {}{location}",
        severity_label(alert.severity),
        alert.title
    );
    send_webhooks(st, &alert, &text).await;

    if rank(alert.severity) >= rank(AlertSeverity::Warning) {
        let on_call = settings::get(st, "on_call", json!({}))
            .await
            .unwrap_or_default();
        if let Some(id) = on_call["weeks"][0]
            .as_str()
            .and_then(|s| s.parse::<Uuid>().ok())
            && let Some(name) = member_name(st, id).await
        {
            st.hub.publish(ServerEvent::Notice {
                member_id: id,
                level: "warning".into(),
                text: format!("值班告警：{device} {}", alert.title),
            });
            let _ = add_event(
                &st.db,
                alert.id,
                "neutral",
                &format!("已通知值班人 {name}"),
                None,
            )
            .await;
        }
    }
    st.hub
        .publish(ServerEvent::changed("alerts", Some(alert.id)));
}

/// 后台：每 30 秒检查一次需要升级的告警
pub async fn escalator(st: AppState) {
    let mut tick = tokio::time::interval(Duration::from_secs(30));
    loop {
        tick.tick().await;
        if let Err(e) = escalate_due(&st).await {
            tracing::warn!(error = %e, "检查告警升级失败");
        }
    }
}

async fn escalate_due(st: &AppState) -> AppResult<()> {
    let on_call = settings::get(st, "on_call", json!({})).await?;
    let Some(secs) = on_call["escalate_after_secs"].as_i64().filter(|s| *s > 0) else {
        return Ok(());
    };
    let target = on_call["escalate_to_id"]
        .as_str()
        .and_then(|s| s.parse::<Uuid>().ok());
    let due: Vec<Alert> = sqlx::query_as(
        "UPDATE alerts SET escalated_at = now()
         WHERE state = 'open' AND escalated_at IS NULL AND severity <> 'info'
           AND created_at < now() - make_interval(secs => $1)
           AND (silenced_until IS NULL OR silenced_until < now())
         RETURNING *",
    )
    .bind(secs as f64)
    .fetch_all(&st.db)
    .await?;
    for alert in due {
        let device = device_name(st, alert.device_id.as_deref()).await;
        let waited = if secs < 60 {
            format!("{secs} 秒")
        } else {
            format!("{} 分钟", (secs + 59) / 60)
        };
        let who = match target {
            Some(id) => member_name(st, id).await.map(|n| (id, n)),
            None => None,
        };
        if let Some((id, _)) = &who {
            st.hub.publish(ServerEvent::Notice {
                member_id: *id,
                level: "warning".into(),
                text: format!("告警升级：{device} {} 已 {waited}无人确认", alert.title),
            });
        }
        let msg = match &who {
            Some((_, name)) => format!("{waited}无人确认，已升级给 {name}"),
            None => format!("{waited}无人确认，已升级"),
        };
        add_event(&st.db, alert.id, "neutral", &msg, None).await?;
        let text = format!(
            "【升级 · {}】{device} {} 已 {waited}无人确认",
            severity_label(alert.severity),
            alert.title
        );
        send_webhooks(st, &alert, &text).await;
        st.hub
            .publish(ServerEvent::changed("alerts", Some(alert.id)));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_channels() {
        assert!(
            validate_channels(&json!([{"name": "应用内推送", "min_severity": "info"}])).is_ok()
        );
        assert!(
            validate_channels(&json!([{"name": "飞书", "min_severity": "critical", "kind": "webhook",
                                      "url": "https://open.feishu.cn/open-apis/bot/v2/hook/x", "format": "feishu"}]))
            .is_ok()
        );
        assert!(validate_channels(&json!([{"name": "x", "min_severity": "high"}])).is_err());
        assert!(
            validate_channels(&json!([{"name": "x", "min_severity": "info", "kind": "webhook"}]))
                .is_err()
        );
        assert!(
            validate_channels(
                &json!([{"name": "x", "min_severity": "info", "kind": "webhook",
                                      "url": "https://a", "format": "telegram"}])
            )
            .is_err()
        );
        assert!(
            validate_channels(&json!([{"name": "x", "min_severity": "info", "kind": "sms"}]))
                .is_err()
        );
    }

    #[test]
    fn masks_urls() {
        let v = mask_channels(
            &json!([{"name": "飞书", "url": "https://open.feishu.cn/open-apis/bot/v2/hook/secret"},
                                      {"name": "应用内"}]),
        );
        assert_eq!(v[0]["url"], "https://open.feishu.cn/…");
        assert!(v[1].get("url").is_none());
    }

    #[test]
    fn bodies() {
        assert_eq!(
            webhook_body("feishu", "t", &json!({}))["content"]["text"],
            "t"
        );
        assert_eq!(
            webhook_body("dingtalk", "t", &json!({}))["text"]["content"],
            "t"
        );
        assert_eq!(
            webhook_body("json", "t", &json!({"id": 1}))["alert"]["id"],
            1
        );
    }
}
