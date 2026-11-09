//! 电子围栏（Safety.dc.html「安全区域」）在服务端的执行。
//!
//! 依据机器人遥测里的 `pose` + `map_id`（与 `/zones` 同一地图坐标系，米）判断设备在哪些区域里：
//! - `ban` 禁入区 / `wall` 虚拟墙：进入时立即停止，写设备事件并生成 warning 告警（`metric: geofence`）；
//! - `whitelist` 允许区：该地图上有适用的允许区、而设备不在任何一个里面时，同样停止并告警；
//! - `slow` 限速区：在区内时运动指令的速度上限取 `rule` 里的数字（如「限速 0.3 m/s」，缺省 0.3）。
//!
//! 只在「进入违规」这一刻停车和告警一次；操作者可以继续操控把设备开出来（离开时记一条事件）。
//! `scope`：含「全部」或为空时适用所有设备，否则文本里出现设备的 id / 名称 / 编号才适用。
//! `schedule`：「全天 / 始终」或空为一直生效；「22:00–06:00」这类时段（可跨零点）按排期时区解释；无法识别时一直生效。
//!
//! 围栏同时下发给机器人（`zones` 消息），供机器人端以后在本地执行。

use std::sync::RwLock;

use chrono::{FixedOffset, NaiveTime, Utc};
use dashmap::DashMap;
use serde_json::{Value, json};
use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    models::{Zone, ZoneType},
    protocol::{Command, ServerToRobot, Telemetry},
    services::{
        control::{self, Actor},
        events,
    },
    state::AppState,
};

#[derive(Debug, Clone)]
pub struct ZoneRule {
    pub id: Uuid,
    pub map_id: String,
    pub name: String,
    pub kind: ZoneType,
    pub polygon: Vec<(f64, f64)>,
    /// 限速区的速度上限
    pub speed: Option<f32>,
    pub scope: String,
    /// 生效时段（本地时间）；None = 一直生效
    pub window: Option<(NaiveTime, NaiveTime)>,
}

/// 射线法判断点是否在多边形内
pub fn contains(poly: &[(f64, f64)], x: f64, y: f64) -> bool {
    if poly.len() < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (xi, yi) = poly[i];
        let (xj, yj) = poly[j];
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn first_number(s: &str) -> Option<f32> {
    let mut buf = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() || (c == '.' && !buf.is_empty() && !buf.contains('.')) {
            buf.push(c);
        } else if !buf.is_empty() {
            break;
        }
    }
    buf.trim_end_matches('.').parse().ok()
}

fn hhmm(s: &str) -> Option<NaiveTime> {
    let s = s.trim().replace('：', ":");
    let (h, m) = s.split_once(':')?;
    NaiveTime::from_hms_opt(h.trim().parse().ok()?, m.trim().parse().ok()?, 0)
}

/// 「22:00–06:00」「08:00-18:00」「9:00 至 17:30」→ 时段；其他 → None（一直生效）
pub fn parse_window(s: &str) -> Option<(NaiveTime, NaiveTime)> {
    for sep in ['–', '—', '-', '~', '～', '至', '到'] {
        if let Some((a, b)) = s.split_once(sep)
            && let (Some(a), Some(b)) = (hhmm(a), hhmm(b))
        {
            return Some((a, b));
        }
    }
    None
}

fn in_window(w: Option<(NaiveTime, NaiveTime)>, now: NaiveTime) -> bool {
    match w {
        None => true,
        Some((a, b)) if a <= b => now >= a && now < b,
        Some((a, b)) => now >= a || now < b, // 跨零点
    }
}

fn scope_applies(scope: &str, ids: &[&str]) -> bool {
    let scope = scope.trim().to_lowercase();
    scope.is_empty()
        || scope.contains("全部")
        || scope == "all"
        || ids
            .iter()
            .any(|i| !i.is_empty() && scope.contains(&i.to_lowercase()))
}

impl ZoneRule {
    pub fn from_zone(z: &Zone) -> Option<Self> {
        let polygon: Vec<(f64, f64)> = z
            .polygon
            .as_array()?
            .iter()
            .filter_map(|p| Some((p[0].as_f64()?, p[1].as_f64()?)))
            .collect();
        (polygon.len() >= 3).then(|| ZoneRule {
            id: z.id,
            map_id: z.map_id.clone(),
            name: z.name.clone(),
            kind: z.zone_type,
            polygon,
            speed: (z.zone_type == ZoneType::Slow).then(|| first_number(&z.rule).unwrap_or(0.3)),
            scope: z.scope.clone(),
            window: parse_window(&z.schedule),
        })
    }

    /// 下发给机器人的形状
    fn to_robot(&self) -> Value {
        json!({
            "id": self.id, "map_id": self.map_id, "name": self.name, "zone_type": self.kind,
            "polygon": self.polygon.iter().map(|(x, y)| [x, y]).collect::<Vec<_>>(),
            "speed_limit_mps": self.speed,
        })
    }
}

/// 一台设备在某一时刻的围栏判定
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Verdict {
    /// 违规：(区域 id, 说明)
    pub violation: Option<(Uuid, String)>,
    pub speed_cap: Option<f32>,
}

pub fn judge(
    zones: &[ZoneRule],
    ids: &[&str],
    map_id: &str,
    x: f64,
    y: f64,
    now: NaiveTime,
) -> Verdict {
    let applicable: Vec<&ZoneRule> = zones
        .iter()
        .filter(|z| z.map_id == map_id && in_window(z.window, now) && scope_applies(&z.scope, ids))
        .collect();
    let mut v = Verdict::default();
    for z in &applicable {
        let inside = contains(&z.polygon, x, y);
        match z.kind {
            ZoneType::Ban | ZoneType::Wall if inside && v.violation.is_none() => {
                let what = if z.kind == ZoneType::Ban {
                    "禁入区"
                } else {
                    "虚拟墙"
                };
                v.violation = Some((z.id, format!("进入{what}「{}」", z.name)));
            }
            ZoneType::Slow if inside => {
                let s = z.speed.unwrap_or(0.3);
                v.speed_cap = Some(v.speed_cap.map_or(s, |c: f32| c.min(s)));
            }
            _ => {}
        }
    }
    let whitelists: Vec<&&ZoneRule> = applicable
        .iter()
        .filter(|z| z.kind == ZoneType::Whitelist)
        .collect();
    if v.violation.is_none()
        && !whitelists.is_empty()
        && !whitelists.iter().any(|z| contains(&z.polygon, x, y))
    {
        let first = whitelists[0];
        v.violation = Some((first.id, format!("离开允许区「{}」", first.name)));
    }
    v
}

#[derive(Default)]
pub struct Geofence {
    zones: RwLock<Vec<ZoneRule>>,
    /// 设备 → 上一次的判定
    state: DashMap<String, Verdict>,
    /// 设备 → (名称, 编号)，用于匹配 scope
    labels: DashMap<String, (String, String)>,
}

impl Geofence {
    pub async fn load(db: &PgPool) -> anyhow::Result<Self> {
        let g = Self::default();
        g.reload(db).await?;
        Ok(g)
    }

    pub async fn reload(&self, db: &PgPool) -> anyhow::Result<()> {
        let zones: Vec<Zone> = sqlx::query_as("SELECT * FROM zones WHERE enabled")
            .fetch_all(db)
            .await?;
        *self.zones.write().expect("zones lock") =
            zones.iter().filter_map(ZoneRule::from_zone).collect();
        self.labels.clear();
        Ok(())
    }

    /// 围栏变化后：重新加载并下发给所有在线机器人
    pub async fn changed(&self, st: &AppState) {
        if let Err(e) = self.reload(&st.db).await {
            tracing::error!(error = %e, "重新加载围栏失败");
            return;
        }
        for id in st.hub.online_ids() {
            self.push_to_robot(st, &id);
        }
    }

    pub fn push_to_robot(&self, st: &AppState, device_id: &str) {
        let zones: Vec<Value> = self
            .zones
            .read()
            .expect("zones lock")
            .iter()
            .map(ZoneRule::to_robot)
            .collect();
        let _ = st.hub.send_raw(device_id, ServerToRobot::Zones { zones });
    }

    /// 当前限速区的速度上限（指令限幅用）
    pub fn speed_cap(&self, device_id: &str) -> Option<f32> {
        self.state.get(device_id).and_then(|v| v.speed_cap)
    }

    pub fn forget(&self, device_id: &str) {
        self.state.remove(device_id);
    }

    /// 每帧遥测调用；只在判定变化时做事
    pub async fn on_telemetry(&self, st: &AppState, device_id: &str, t: &Telemetry) {
        let (Some(pose), Some(map_id)) = (&t.pose, &t.map_id) else {
            return;
        };
        if self.zones.read().expect("zones lock").is_empty() && !self.state.contains_key(device_id)
        {
            return;
        }
        if !self.labels.contains_key(device_id) {
            let row: Option<(String, String)> =
                sqlx::query_as("SELECT name, code FROM devices WHERE id = $1")
                    .bind(device_id)
                    .fetch_optional(&st.db)
                    .await
                    .ok()
                    .flatten();
            self.labels
                .insert(device_id.to_owned(), row.unwrap_or_default());
        }
        let (name, code) = self
            .labels
            .get(device_id)
            .map(|l| l.clone())
            .unwrap_or_default();
        let now = Utc::now()
            .with_timezone(
                &FixedOffset::east_opt(st.cfg.schedule_tz_offset_minutes * 60)
                    .unwrap_or_else(|| FixedOffset::east_opt(0).expect("utc")),
            )
            .time();
        let verdict = {
            let zones = self.zones.read().expect("zones lock");
            judge(
                &zones,
                &[device_id, &name, &code],
                map_id,
                f64::from(pose.x),
                f64::from(pose.y),
                now,
            )
        };
        let before = self.state.insert(device_id.to_owned(), verdict.clone());
        let was = before.as_ref().and_then(|v| v.violation.clone());
        if was.as_ref().map(|v| v.0) == verdict.violation.as_ref().map(|v| v.0) {
            return;
        }
        // 违规处理要发指令、写库：放到独立任务，不阻塞机器人读循环
        let (st, device) = (st.clone(), device_id.to_owned());
        tokio::spawn(async move {
            if let Some((_, text)) = &verdict.violation {
                let _ = control::execute(
                    &st,
                    Actor::System("电子围栏"),
                    &device,
                    Command::Stop,
                    false,
                )
                .await;
                events::record(&st, &device, format!("{text}，已停止"), "warning").await;
                if let Err(e) = st
                    .alerts
                    .raise_robot_event(&st, &device, "warning", "geofence", text)
                    .await
                {
                    tracing::warn!(error = %e, "生成围栏告警失败");
                }
            } else if let Some((_, text)) = was {
                events::record(&st, &device, format!("已解除：{text}"), "info").await;
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(
        kind: ZoneType,
        poly: &[(f64, f64)],
        scope: &str,
        schedule: &str,
        rule: &str,
    ) -> ZoneRule {
        ZoneRule::from_zone(&Zone {
            id: Uuid::new_v4(),
            map_id: "b2".into(),
            name: "z".into(),
            zone_type: kind,
            polygon: json!(poly.iter().map(|(x, y)| [x, y]).collect::<Vec<_>>()),
            rule: rule.into(),
            scope: scope.into(),
            schedule: schedule.into(),
            action: String::new(),
            enabled: true,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        })
        .unwrap()
    }

    const SQUARE: &[(f64, f64)] = &[(0.0, 0.0), (2.0, 0.0), (2.0, 2.0), (0.0, 2.0)];
    const BIG: &[(f64, f64)] = &[(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)];

    fn noon() -> NaiveTime {
        NaiveTime::from_hms_opt(12, 0, 0).unwrap()
    }

    #[test]
    fn point_in_polygon() {
        assert!(contains(SQUARE, 1.0, 1.0));
        assert!(!contains(SQUARE, 3.0, 1.0));
        assert!(!contains(&[(0.0, 0.0), (1.0, 0.0)], 0.5, 0.0));
    }

    #[test]
    fn ban_and_slow() {
        let zones = vec![
            rule(ZoneType::Ban, SQUARE, "全部设备", "全天", ""),
            rule(ZoneType::Slow, BIG, "全部设备", "全天", "限速 0.5 m/s"),
        ];
        let v = judge(&zones, &["go2-01"], "b2", 1.0, 1.0, noon());
        assert!(v.violation.unwrap().1.contains("禁入区"));
        let v = judge(&zones, &["go2-01"], "b2", 5.0, 5.0, noon());
        assert_eq!(
            v,
            Verdict {
                violation: None,
                speed_cap: Some(0.5)
            }
        );
        assert_eq!(
            judge(&zones, &["go2-01"], "other", 1.0, 1.0, noon()),
            Verdict::default()
        );
    }

    #[test]
    fn whitelist_scope_and_window() {
        let zones = vec![rule(
            ZoneType::Whitelist,
            BIG,
            "Alpha、Bravo",
            "22:00–06:00",
            "",
        )];
        let night = NaiveTime::from_hms_opt(23, 0, 0).unwrap();
        // 范围外的设备不受限
        assert_eq!(
            judge(
                &zones,
                &["go2-03", "Charlie", "GO2-03"],
                "b2",
                20.0,
                0.0,
                night
            ),
            Verdict::default()
        );
        // 白天不生效
        assert_eq!(
            judge(
                &zones,
                &["go2-01", "Alpha", "GO2-01"],
                "b2",
                20.0,
                0.0,
                noon()
            ),
            Verdict::default()
        );
        let v = judge(
            &zones,
            &["go2-01", "Alpha", "GO2-01"],
            "b2",
            20.0,
            0.0,
            night,
        );
        assert!(v.violation.unwrap().1.contains("允许区"));
        assert!(
            judge(
                &zones,
                &["go2-01", "Alpha", "GO2-01"],
                "b2",
                5.0,
                5.0,
                night
            )
            .violation
            .is_none()
        );
    }

    #[test]
    fn windows() {
        let w = parse_window("08:00-18:00").unwrap();
        assert!(in_window(Some(w), noon()));
        assert!(parse_window("全天").is_none());
        assert!(parse_window("9:00 至 17:30").is_some());
    }
}
