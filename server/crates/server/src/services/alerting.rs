//! 告警引擎：对每帧遥测按规则做阈值 + 持续时间判定；规则全部缓存在内存，
//! 只有真正触发告警时才访问数据库。

use std::sync::RwLock;

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    error::AppResult,
    models::{AlertRule, AlertSeverity, AlertState, DeviceStatus, Role},
    protocol::{Command, ServerEvent, SpeedLevel, Telemetry},
    services::{
        audit,
        control::{self, Actor},
        events, notify, recordings,
    },
    state::AppState,
};

type Key = (String, Uuid); // (device_id, rule_id)

pub const AUTO_ACTIONS: [&str; 4] = ["slow", "stop", "dock", "notify"];

pub struct AlertEngine {
    rules: RwLock<Vec<AlertRule>>,
    breach_since: DashMap<Key, DateTime<Utc>>,
    open: DashMap<Key, Uuid>,
}

/// 规则没写 metric_label 时的默认曲线标题
pub fn default_metric_label(metric: &str) -> String {
    match metric {
        "max_motor_temp" => "电机最高温度（°C）".into(),
        "battery" => "电量（%）".into(),
        "latency_ms" => "通信延迟（ms）".into(),
        "voltage" => "电压（V）".into(),
        "current" => "电流（A）".into(),
        "pitch" => "机身俯仰角（rad）".into(),
        "roll" => "机身横滚角（rad）".into(),
        "loc_confidence" => "定位置信度".into(),
        other => other.to_owned(),
    }
}

fn metric_value(metric: &str, t: &Telemetry, latency_ms: Option<u32>) -> Option<f64> {
    Some(match metric {
        "max_motor_temp" => t.max_motor_temp()? as f64,
        "battery" => t.battery? as f64,
        "latency_ms" => latency_ms? as f64,
        "voltage" => t.voltage as f64,
        "current" => t.current as f64,
        "pitch" => (t.pitch as f64).abs(),
        "roll" => (t.roll as f64).abs(),
        other => t.extra.get(other)?.as_f64()?,
    })
}

fn breached(op: &str, v: f64, threshold: f64) -> bool {
    match op {
        ">" => v > threshold,
        "<" => v < threshold,
        ">=" => v >= threshold,
        "<=" => v <= threshold,
        _ => false,
    }
}

fn severity_tone(s: AlertSeverity) -> &'static str {
    match s {
        AlertSeverity::Critical => "critical",
        AlertSeverity::Warning => "warning",
        AlertSeverity::Info => "info",
    }
}

impl AlertEngine {
    pub async fn load(db: &PgPool) -> anyhow::Result<Self> {
        let engine = Self {
            rules: RwLock::new(vec![]),
            breach_since: DashMap::new(),
            open: DashMap::new(),
        };
        engine.reload_rules(db).await?;
        let open: Vec<(Uuid, String, Uuid)> = sqlx::query_as(
            "SELECT id, device_id, rule_id FROM alerts
             WHERE state <> 'closed' AND rule_id IS NOT NULL AND device_id IS NOT NULL",
        )
        .fetch_all(db)
        .await?;
        for (id, device, rule) in open {
            engine.open.insert((device, rule), id);
        }
        Ok(engine)
    }

    pub async fn reload_rules(&self, db: &PgPool) -> anyhow::Result<()> {
        let rules: Vec<AlertRule> = sqlx::query_as("SELECT * FROM alert_rules WHERE enabled")
            .fetch_all(db)
            .await?;
        *self.rules.write().expect("rules lock") = rules;
        Ok(())
    }

    /// 告警被人工关闭后，允许同一规则再次触发
    pub fn on_closed(&self, device_id: &str, rule_id: Uuid) {
        let key = (device_id.to_owned(), rule_id);
        self.open.remove(&key);
        self.breach_since.remove(&key);
    }

    pub async fn evaluate(
        &self,
        st: &AppState,
        device_id: &str,
        t: &Telemetry,
        latency_ms: Option<u32>,
    ) {
        let rules = self.rules.read().expect("rules lock").clone();
        let now = Utc::now();
        for rule in rules {
            let key = (device_id.to_owned(), rule.id);
            let Some(v) = metric_value(&rule.metric, t, latency_ms) else {
                continue;
            };
            if !breached(&rule.op, v, rule.threshold) {
                self.breach_since.remove(&key);
                continue;
            }
            let since = *self.breach_since.entry(key.clone()).or_insert(now);
            if (now - since).num_seconds() < rule.duration_secs as i64
                || self.open.contains_key(&key)
            {
                continue;
            }
            match self.raise_rule(st, device_id, &rule, v).await {
                Ok(Some(id)) => {
                    self.open.insert(key, id);
                }
                Ok(None) => {} // 并发去重：已有未关闭告警
                Err(e) => tracing::error!(error = %e, rule = %rule.name, "创建告警失败"),
            }
        }
    }

    async fn raise_rule(
        &self,
        st: &AppState,
        device_id: &str,
        rule: &AlertRule,
        value: f64,
    ) -> AppResult<Option<Uuid>> {
        let label = rule
            .metric_label
            .clone()
            .unwrap_or_else(|| default_metric_label(&rule.metric));
        let id: Option<Uuid> = sqlx::query_scalar(
            "INSERT INTO alerts (severity, title, device_id, rule_id, metric, metric_label, threshold, peak, location)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, (SELECT location FROM devices WHERE id = $3))
             ON CONFLICT (device_id, rule_id) WHERE state <> 'closed' AND rule_id IS NOT NULL DO NOTHING
             RETURNING id",
        )
        .bind(rule.severity)
        .bind(&rule.name)
        .bind(device_id)
        .bind(rule.id)
        .bind(&rule.metric)
        .bind(&label)
        .bind(rule.threshold)
        .bind(value)
        .fetch_optional(&st.db)
        .await?;
        let Some(alert_id) = id else { return Ok(None) };

        let duration = if rule.duration_secs > 0 {
            format!("持续 {} 秒", rule.duration_secs)
        } else {
            String::new()
        };
        add_event(
            &st.db,
            alert_id,
            severity_tone(rule.severity),
            &format!(
                "{label} {} {} {duration}（当前 {value:.1}）",
                rule.op, rule.threshold
            ),
            None,
        )
        .await?;

        if let Some(action) = rule.auto_action.clone() {
            // 告警在机器人连接的读循环里评估；等待回执必须放到独立任务，否则回执读不到会自锁超时
            let (st2, device, title) = (st.clone(), device_id.to_owned(), rule.name.clone());
            tokio::spawn(async move {
                if let Err(e) = st2
                    .alerts
                    .auto_action(&st2, alert_id, &device, &title, &action)
                    .await
                {
                    tracing::warn!(error = %e, "告警自动处理失败");
                }
            });
        }

        if rule.severity != AlertSeverity::Info {
            set_device_alert(st, device_id).await?;
        }
        let device = audit::device_label(st, device_id).await;
        let now = Utc::now();
        match recordings::auto_record(
            st,
            &format!("{device} {}", rule.name),
            &[device_id.to_owned()],
            now - chrono::Duration::seconds(60),
            now + chrono::Duration::seconds(60),
            "alert",
            &alert_id.to_string(),
        )
        .await
        {
            Ok(rec) => {
                let _ = sqlx::query("UPDATE alerts SET recording_id = $2 WHERE id = $1")
                    .bind(alert_id)
                    .bind(rec)
                    .execute(&st.db)
                    .await;
            }
            Err(e) => tracing::warn!(error = %e, "告警自动录制失败"),
        }
        events::record(
            st,
            device_id,
            format!("告警：{}", rule.name),
            severity_tone(rule.severity),
        )
        .await;
        audit::record_system(
            st,
            audit::Kind::Alert,
            format!("触发告警「{device} {}」", rule.name),
            &device,
            serde_json::json!({ "alert_id": alert_id, "value": value }),
        )
        .await;
        st.hub.publish(ServerEvent::Alert {
            alert_id,
            device_id: Some(device_id.to_owned()),
            severity: rule.severity,
            title: rule.name.clone(),
            state: AlertState::Open,
        });
        spawn_notify(st, alert_id);
        st.hub
            .publish(ServerEvent::changed("alerts", Some(alert_id)));
        Ok(Some(alert_id))
    }

    async fn auto_action(
        &self,
        st: &AppState,
        alert_id: Uuid,
        device_id: &str,
        title: &str,
        action: &str,
    ) -> AppResult<()> {
        let cmd = match action {
            "slow" => Some((
                Command::SetSpeed {
                    level: SpeedLevel::Slow,
                },
                "自动执行：切换低速，限速 0.3 m/s",
            )),
            "stop" => Some((Command::Stop, "自动执行：停止运动")),
            "dock" => Some((
                Command::Action {
                    name: "dock".into(),
                    params: serde_json::Value::Null,
                },
                "自动执行：返回充电桩",
            )),
            _ => None,
        };
        if let Some((cmd, msg)) = cmd {
            let r = control::execute(st, Actor::System("告警自动处理"), device_id, cmd, true).await;
            let text = match r {
                Ok(res) if res.ok != Some(false) => msg.to_owned(),
                Ok(res) => format!("{msg}失败：{}", res.message.unwrap_or_default()),
                Err(e) => format!("{msg}失败：{e}"),
            };
            add_event(&st.db, alert_id, "neutral", &text, None).await?;
        }
        if action == "notify" {
            let device = audit::device_label(st, device_id).await;
            let targets: Vec<Uuid> = sqlx::query_scalar(
                "SELECT id FROM members WHERE NOT disabled AND (role = $1
                    OR id = (SELECT owner_id FROM devices WHERE id = $2))",
            )
            .bind(Role::Admin)
            .bind(device_id)
            .fetch_all(&st.db)
            .await?;
            for m in &targets {
                st.hub.publish(ServerEvent::Notice {
                    member_id: *m,
                    level: "warning".into(),
                    text: format!("告警：{device} {title}"),
                });
            }
            add_event(
                &st.db,
                alert_id,
                "neutral",
                &format!("已通知管理者（{} 人）", targets.len()),
                None,
            )
            .await?;
        }
        Ok(())
    }

    /// 机器人上报的事件（跌倒、碰撞…）直接生成告警
    pub async fn raise_robot_event(
        &self,
        st: &AppState,
        device_id: &str,
        level: &str,
        code: &str,
        message: &str,
    ) -> AppResult<()> {
        let severity = match level {
            "critical" | "error" => AlertSeverity::Critical,
            "warning" | "warn" => AlertSeverity::Warning,
            _ => return Ok(()), // info 级事件只推送，不建告警
        };
        let alert_id: Uuid = sqlx::query_scalar(
            "INSERT INTO alerts (severity, title, device_id, metric, metric_label, location)
             VALUES ($1, $2, $3, $4, $4, (SELECT location FROM devices WHERE id = $3)) RETURNING id",
        )
        .bind(severity)
        .bind(message)
        .bind(device_id)
        .bind(code)
        .fetch_one(&st.db)
        .await?;
        add_event(
            &st.db,
            alert_id,
            severity_tone(severity),
            &format!("设备上报：{message}"),
            None,
        )
        .await?;
        set_device_alert(st, device_id).await?;
        st.hub.publish(ServerEvent::Alert {
            alert_id,
            device_id: Some(device_id.to_owned()),
            severity,
            title: message.to_owned(),
            state: AlertState::Open,
        });
        spawn_notify(st, alert_id);
        st.hub
            .publish(ServerEvent::changed("alerts", Some(alert_id)));
        Ok(())
    }
}

/// 外部通知（webhook、值班人）放到独立任务：告警在机器人连接的读循环里产生，不能被网络请求拖住
fn spawn_notify(st: &AppState, alert_id: Uuid) {
    let st = st.clone();
    tokio::spawn(async move { notify::alert_raised(&st, alert_id).await });
}

/// 告警时间线。tone：critical / warning = 触发，neutral = 自动动作与通知，info = 人工处理
pub async fn add_event(
    db: &PgPool,
    alert_id: Uuid,
    tone: &str,
    message: &str,
    actor_id: Option<Uuid>,
) -> AppResult<()> {
    let level = match tone {
        "critical" | "warning" => tone,
        "info" => "note",
        _ => "action",
    };
    sqlx::query(
        "INSERT INTO alert_events (alert_id, level, tone, message, actor_id) VALUES ($1, $2, $3, $4, $5)",
    )
    .bind(alert_id)
    .bind(level)
    .bind(tone)
    .bind(message)
    .bind(actor_id)
    .execute(db)
    .await?;
    Ok(())
}

async fn set_device_alert(st: &AppState, device_id: &str) -> AppResult<()> {
    sqlx::query("UPDATE devices SET status = 'alert', updated_at = now() WHERE id = $1")
        .bind(device_id)
        .execute(&st.db)
        .await?;
    st.hub.publish(ServerEvent::DeviceStatus {
        device_id: device_id.to_owned(),
        status: DeviceStatus::Alert,
        online: st.hub.is_online(device_id),
        location: None,
        task: None,
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn thresholds() {
        assert!(breached(">", 68.0, 60.0));
        assert!(!breached(">", 60.0, 60.0));
        assert!(breached("<", 15.0, 20.0));
        assert!(!breached("??", 1.0, 0.0));
    }

    #[test]
    fn extract_metrics() {
        let t: Telemetry = serde_json::from_value(json!({
            "ts": "2026-11-02T06:00:00Z", "battery": 41.0,
            "joint_temps": [[41,44,46],[40,43,45],[42,47,68],[39,42,44]],
            "extra": {"loc_confidence": 0.54}
        }))
        .unwrap();
        assert_eq!(metric_value("max_motor_temp", &t, None), Some(68.0));
        assert_eq!(metric_value("battery", &t, None), Some(41.0));
        assert_eq!(metric_value("latency_ms", &t, Some(64)), Some(64.0));
        assert_eq!(metric_value("loc_confidence", &t, None), Some(0.54));
        assert_eq!(metric_value("latency_ms", &t, None), None);
    }

    #[test]
    fn labels() {
        assert_eq!(default_metric_label("battery"), "电量（%）");
        assert_eq!(default_metric_label("custom_x"), "custom_x");
    }
}
