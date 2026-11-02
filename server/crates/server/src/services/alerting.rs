//! 告警引擎：对每帧遥测按规则做阈值 + 持续时间判定；规则全部缓存在内存，
//! 只有真正触发告警时才访问数据库。

use std::sync::RwLock;

use chrono::{DateTime, Utc};
use dashmap::DashMap;
use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    error::AppResult,
    models::{AlertRule, AlertSeverity, AlertState, DeviceStatus},
    protocol::{Command, ServerEvent, SpeedLevel, Telemetry},
    services::control::{self, Actor},
    state::AppState,
};

type Key = (String, Uuid); // (device_id, rule_id)

pub struct AlertEngine {
    rules: RwLock<Vec<AlertRule>>,
    breach_since: DashMap<Key, DateTime<Utc>>,
    open: DashMap<Key, Uuid>,
}

fn metric_value(metric: &str, t: &Telemetry, latency_ms: Option<u32>) -> Option<f64> {
    Some(match metric {
        "max_motor_temp" => t.max_motor_temp()? as f64,
        "battery" => t.battery? as f64,
        "latency_ms" => latency_ms? as f64,
        "voltage" => t.voltage as f64,
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
        let id: Option<(Uuid,)> = sqlx::query_as(
            "INSERT INTO alerts (severity, title, device_id, rule_id, metric, peak)
             VALUES ($1, $2, $3, $4, $5, $6)
             ON CONFLICT (device_id, rule_id) WHERE state <> 'closed' AND rule_id IS NOT NULL DO NOTHING
             RETURNING id",
        )
        .bind(rule.severity)
        .bind(&rule.name)
        .bind(device_id)
        .bind(rule.id)
        .bind(&rule.metric)
        .bind(value)
        .fetch_optional(&st.db)
        .await?;
        let Some((alert_id,)) = id else {
            return Ok(None);
        };

        let level = match rule.severity {
            AlertSeverity::Critical => "critical",
            AlertSeverity::Warning => "warning",
            AlertSeverity::Info => "info",
        };
        add_event(
            &st.db,
            alert_id,
            level,
            &format!(
                "{} {} {}（当前 {:.1}）持续 {} 秒",
                rule.metric, rule.op, rule.threshold, value, rule.duration_secs
            ),
        )
        .await?;

        if let Some(action) = rule.auto_action.as_deref() {
            let cmd = match action {
                "slow" => Some((
                    Command::SetSpeed {
                        level: SpeedLevel::Slow,
                    },
                    "自动执行：切换低速步态",
                )),
                "stop" => Some((Command::Stop, "自动执行：停止运动")),
                _ => None,
            };
            if let Some((cmd, msg)) = cmd {
                let ok = control::execute(st, Actor::System("告警自动处理"), device_id, cmd, false)
                    .await
                    .is_ok();
                add_event(
                    &st.db,
                    alert_id,
                    "action",
                    if ok {
                        msg
                    } else {
                        "自动处理失败：设备不在线"
                    },
                )
                .await?;
            }
        }

        if rule.severity != AlertSeverity::Info {
            set_device_alert(st, device_id).await?;
        }
        st.hub.publish(ServerEvent::Alert {
            alert_id,
            device_id: Some(device_id.to_owned()),
            severity: rule.severity,
            title: rule.name.clone(),
            state: AlertState::Open,
        });
        Ok(Some(alert_id))
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
        let (alert_id,): (Uuid,) = sqlx::query_as(
            "INSERT INTO alerts (severity, title, device_id, metric) VALUES ($1, $2, $3, $4) RETURNING id",
        )
        .bind(severity)
        .bind(message)
        .bind(device_id)
        .bind(code)
        .fetch_one(&st.db)
        .await?;
        add_event(&st.db, alert_id, level, &format!("[{code}] {message}")).await?;
        set_device_alert(st, device_id).await?;
        st.hub.publish(ServerEvent::Alert {
            alert_id,
            device_id: Some(device_id.to_owned()),
            severity,
            title: message.to_owned(),
            state: AlertState::Open,
        });
        Ok(())
    }
}

pub async fn add_event(db: &PgPool, alert_id: Uuid, level: &str, message: &str) -> AppResult<()> {
    sqlx::query("INSERT INTO alert_events (alert_id, level, message) VALUES ($1, $2, $3)")
        .bind(alert_id)
        .bind(level)
        .bind(message)
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
}
