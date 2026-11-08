//! 联调时间轴播放（Fleet.dc.html「动作编排」）。
//!
//! 时间轴是 `TrackAction[]`：`{device_id, start_ms, end_ms, action, kind: pose|move|act, command?}`。
//! `action` 是给人看的文字，服务端按 `kind` 翻译成指令：
//! - `pose`：站立 / 趴下 / 平衡站立 / 行走 / 爬楼梯 / 阻尼 / 恢复站立（或英文模式名）→ `set_mode`
//! - `move`：「前进 3 m」「后退 1.5 m」「左移 1 m」「右转 90°」→ 在 [start, end] 内以 10 Hz 下发 `move`，
//!   速度 = 距离 / 时长（仍受安全策略限幅），结束时 `stop`
//! - `act`：设备技能目录里名字或描述等于 `action` 的技能（如「打招呼」→ hello）→ `action`
//! - 带 `command`（协议 Command 对象）时直接用它，不再翻译。
//!
//! 播放用会话发起人的身份下发（会话持有控制权）；急停、会话结束、手动停止都会中止播放并让设备停下。
//! 播放结束后把每台设备的执行结果写入 `last_receipt`（标题「时间轴执行」）。

use std::{collections::HashMap, time::Duration};

use chrono::Utc;
use dashmap::DashMap;
use futures::future::join_all;
use serde_json::{Value, json};
use tokio::{sync::watch, time::Instant};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::FleetSession,
    protocol::{Command, MotionMode, ServerEvent},
    services::control::{self, Actor},
    state::AppState,
};

/// 翻译后的一步
#[derive(Debug, Clone, PartialEq)]
pub enum StepKind {
    /// 到点下发一次
    Once(Command),
    /// 在 [start, end] 内持续下发速度
    Stream { vx: f32, vy: f32, wz: f32 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    pub device_id: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub label: String,
    pub kind: StepKind,
}

fn pose(action: &str) -> Option<MotionMode> {
    let a = action.trim().to_lowercase();
    // 「恢复站立」「平衡站立」都含「站立」，先判断更具体的
    Some(if a.contains("恢复") || a == "recovery" {
        MotionMode::Recovery
    } else if a.contains("平衡") || a == "balance" {
        MotionMode::Balance
    } else if a.contains("站立") || a.contains("起立") || a == "stand" {
        MotionMode::Stand
    } else if a.contains("趴下") || a.contains("卧倒") || a == "down" {
        MotionMode::Down
    } else if a.contains("楼梯") || a == "stairs" {
        MotionMode::Stairs
    } else if a.contains("阻尼") || a == "damp" {
        MotionMode::Damp
    } else if a.contains("行走") || a == "walk" {
        MotionMode::Walk
    } else {
        return None;
    })
}

/// 文字里的第一个数字
fn number(s: &str) -> Option<f32> {
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

/// 「前进 3 m」→ 机体坐标系速度（vx 向前、vy 向左、wz 逆时针），`secs` 为动作时长
pub fn movement(action: &str, secs: f32) -> Option<(f32, f32, f32)> {
    let a = action.to_lowercase();
    let secs = secs.max(0.1);
    let n = number(&a);
    let dist = n.unwrap_or(1.0);
    let has = |ws: &[&str]| ws.iter().any(|w| a.contains(w));
    if has(&["左转", "turn left"]) || has(&["右转", "turn right"]) {
        let deg = n.unwrap_or(90.0);
        let w = deg.to_radians() / secs;
        return Some((0.0, 0.0, if has(&["左转", "turn left"]) { w } else { -w }));
    }
    let v = dist / secs;
    if has(&["前进", "向前", "forward"]) {
        Some((v, 0.0, 0.0))
    } else if has(&["后退", "向后", "backward", "back"]) {
        Some((-v, 0.0, 0.0))
    } else if has(&["左移", "向左", "left"]) {
        Some((0.0, v, 0.0))
    } else if has(&["右移", "向右", "right"]) {
        Some((0.0, -v, 0.0))
    } else {
        None
    }
}

/// 在技能目录 `[{name, description}]` 里找动作
pub fn skill_for(action: &str, skills: &[Value]) -> Option<String> {
    let a = action.trim();
    skills
        .iter()
        .find(|s| s["name"].as_str() == Some(a) || s["description"].as_str() == Some(a))
        .and_then(|s| s["name"].as_str())
        .map(str::to_owned)
        .or_else(|| {
            // 技能目录里没有时，纯英文标识符按技能名直接下发，由机器人端校验
            (!a.is_empty() && a.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'))
                .then(|| a.to_owned())
        })
}

/// 把时间轴翻译成可执行的步骤；无法识别的动作全部列出返回 400
pub fn compile(
    timeline: &Value,
    devices: &[String],
    skills: &HashMap<String, Vec<Value>>,
) -> AppResult<Vec<Step>> {
    let items = timeline.as_array().map(Vec::as_slice).unwrap_or_default();
    let mut steps = Vec::with_capacity(items.len());
    let mut bad = Vec::new();
    for it in items {
        let device = it["device_id"].as_str().unwrap_or_default();
        let action = it["action"].as_str().unwrap_or_default();
        let start = it["start_ms"].as_u64().unwrap_or(0);
        let end = it["end_ms"].as_u64().unwrap_or(start).max(start);
        if !devices.iter().any(|d| d == device) {
            continue; // 已退出会话的设备
        }
        let kind = if let Some(c) = it.get("command").filter(|c| !c.is_null()) {
            serde_json::from_value::<Command>(c.clone())
                .ok()
                .map(StepKind::Once)
        } else {
            match it["kind"].as_str().unwrap_or("pose") {
                "pose" => pose(action).map(|mode| StepKind::Once(Command::SetMode { mode })),
                "move" => movement(action, (end - start) as f32 / 1000.0)
                    .map(|(vx, vy, wz)| StepKind::Stream { vx, vy, wz }),
                "act" => skill_for(action, skills.get(device).map(Vec::as_slice).unwrap_or(&[]))
                    .map(|name| {
                        StepKind::Once(Command::Action {
                            name,
                            params: json!({}),
                        })
                    }),
                _ => None,
            }
        };
        match kind {
            Some(kind) => steps.push(Step {
                device_id: device.to_owned(),
                start_ms: start,
                end_ms: end,
                label: action.to_owned(),
                kind,
            }),
            None => bad.push(format!("{device}「{action}」")),
        }
    }
    if !bad.is_empty() {
        return Err(AppError::bad_request(format!(
            "时间轴里有无法识别的动作：{}",
            bad.join("、")
        )));
    }
    if steps.is_empty() {
        return Err(AppError::bad_request("时间轴为空"));
    }
    steps.sort_by_key(|s| s.start_ms);
    Ok(steps)
}

#[derive(Default)]
pub struct TimelinePlayer {
    running: DashMap<Uuid, watch::Sender<bool>>,
}

impl TimelinePlayer {
    pub fn is_playing(&self, session: Uuid) -> bool {
        self.running.contains_key(&session)
    }

    /// 中止播放（设备停车与收尾由播放任务完成）
    pub fn stop(&self, session: Uuid) {
        if let Some((_, tx)) = self.running.remove(&session) {
            let _ = tx.send(true);
        }
    }

    pub fn stop_all(&self) {
        let ids: Vec<Uuid> = self.running.iter().map(|e| *e.key()).collect();
        for id in ids {
            self.stop(id);
        }
    }

    /// 从 `from_ms` 开始播放
    pub async fn play(
        &self,
        st: &AppState,
        user: &AuthUser,
        s: &FleetSession,
        from_ms: u64,
    ) -> AppResult<()> {
        if !s.active {
            return Err(AppError::conflict("会话未开始"));
        }
        if s.paused || st.safety.is_global_estop() {
            return Err(AppError::EstopActive);
        }
        let rows: Vec<(String, Value)> = sqlx::query_as(
            "SELECT id, COALESCE(meta->'skills', '[]'::jsonb) FROM devices WHERE id = ANY($1)",
        )
        .bind(&s.device_ids)
        .fetch_all(&st.db)
        .await?;
        let skills: HashMap<String, Vec<Value>> = rows
            .into_iter()
            .map(|(id, v)| (id, v.as_array().cloned().unwrap_or_default()))
            .collect();
        let steps: Vec<Step> = compile(&s.timeline, &s.device_ids, &skills)?
            .into_iter()
            .filter(|st| {
                st.end_ms > from_ms || (st.end_ms == st.start_ms && st.start_ms >= from_ms)
            })
            .collect();

        let (tx, rx) = watch::channel(false);
        match self.running.entry(s.id) {
            dashmap::Entry::Occupied(_) => return Err(AppError::conflict("时间轴已在播放")),
            dashmap::Entry::Vacant(v) => {
                v.insert(tx);
            }
        }
        let started = Utc::now() - chrono::Duration::milliseconds(from_ms as i64);
        sqlx::query(
            "UPDATE fleet_sessions SET playback_started_at = $2, updated_at = now() WHERE id = $1",
        )
        .bind(s.id)
        .bind(started)
        .execute(&st.db)
        .await?;
        st.hub
            .publish(ServerEvent::changed("fleet_sessions", Some(s.id)));

        let (st, user, session, devices) = (st.clone(), user.clone(), s.id, s.device_ids.clone());
        tokio::spawn(async move {
            let results = run(&st, &user, &steps, from_ms, rx).await;
            st.fleet_player.running.remove(&session);
            finish(&st, session, &devices, results).await;
        });
        Ok(())
    }
}

/// 每步的结果：(设备, 失败原因)
type StepResult = (String, Option<(String, String)>);

async fn run(
    st: &AppState,
    user: &AuthUser,
    steps: &[Step],
    from_ms: u64,
    mut cancel: watch::Receiver<bool>,
) -> Vec<StepResult> {
    let t0 = Instant::now() - Duration::from_millis(from_ms);
    let all = join_all(steps.iter().map(|s| run_step(st, user, s, t0)));
    tokio::select! {
        r = all => r,
        _ = cancel.wait_for(|c| *c) => {
            let mut devices: Vec<&str> = steps.iter().map(|s| s.device_id.as_str()).collect();
            devices.sort();
            devices.dedup();
            devices
                .into_iter()
                .map(|d| (d.to_owned(), Some(("cancelled".into(), "播放已中止".into()))))
                .collect()
        }
    }
}

async fn run_step(st: &AppState, user: &AuthUser, s: &Step, t0: Instant) -> StepResult {
    let fail = |e: AppError| (e.code().to_owned(), e.to_string());
    let start = t0 + Duration::from_millis(s.start_ms);
    let end = t0 + Duration::from_millis(s.end_ms);
    tokio::time::sleep_until(start).await;
    let res = match &s.kind {
        StepKind::Once(cmd) => {
            let block = Duration::from_millis(s.end_ms - s.start_ms);
            let wait = Duration::from_millis(st.cfg.command_timeout_ms)
                .max(block + Duration::from_secs(2));
            match control::execute_with_timeout(
                st,
                Actor::User(user),
                &s.device_id,
                cmd.clone(),
                Some(wait),
            )
            .await
            {
                Ok(r) if r.ok == Some(true) => None,
                Ok(r) => Some((
                    r.error.unwrap_or_else(|| "robot_error".into()),
                    r.message.unwrap_or_else(|| "机器人执行失败".into()),
                )),
                Err(e) => Some(fail(e)),
            }
        }
        StepKind::Stream { vx, vy, wz } => {
            let mut tick = tokio::time::interval(Duration::from_millis(100));
            let mut err = None;
            while Instant::now() < end {
                tick.tick().await;
                let cmd = Command::Move {
                    vx: *vx,
                    vy: *vy,
                    wz: *wz,
                };
                if let Err(e) =
                    control::execute(st, Actor::User(user), &s.device_id, cmd, false).await
                {
                    err = Some(fail(e));
                    break;
                }
            }
            let _ =
                control::execute(st, Actor::User(user), &s.device_id, Command::Stop, false).await;
            err
        }
    };
    (
        s.device_id.clone(),
        res.map(|(code, msg)| (code, format!("「{}」：{msg}", s.label))),
    )
}

async fn finish(st: &AppState, session: Uuid, devices: &[String], results: Vec<StepResult>) {
    if results.iter().any(|(_, r)| r.is_some()) {
        for d in devices {
            let _ =
                control::execute(st, Actor::System("时间轴中止"), d, Command::Stop, false).await;
        }
    }
    let mut first_err: HashMap<&str, &(String, String)> = HashMap::new();
    for (d, r) in &results {
        if let Some(e) = r {
            first_err.entry(d.as_str()).or_insert(e);
        }
    }
    let acks: Vec<Value> = devices
        .iter()
        .map(|d| {
            let e = first_err.get(d.as_str());
            json!({
                "device_id": d,
                "ok": e.is_none(),
                "latency_ms": null,
                "error": e.map(|e| &e.0),
                "message": e.map(|e| &e.1),
            })
        })
        .collect();
    let receipt = json!({
        "label": "时间轴执行",
        "sent_at": Utc::now(),
        "schedule_offset_ms": 0,
        "acks": acks,
    });
    let _ = sqlx::query(
        "UPDATE fleet_sessions SET playback_started_at = NULL, last_receipt = $2, updated_at = now()
         WHERE id = $1",
    )
    .bind(session)
    .bind(receipt)
    .execute(&st.db)
    .await;
    st.hub
        .publish(ServerEvent::changed("fleet_sessions", Some(session)));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn poses() {
        assert_eq!(pose("站立"), Some(MotionMode::Stand));
        assert_eq!(pose("恢复站立"), Some(MotionMode::Recovery));
        assert_eq!(pose("平衡站立"), Some(MotionMode::Balance));
        assert_eq!(pose("趴下"), Some(MotionMode::Down));
        assert_eq!(pose("down"), Some(MotionMode::Down));
        assert_eq!(pose("跳舞"), None);
    }

    #[test]
    fn movements() {
        let (vx, vy, wz) = movement("队形前进 3 m", 6.0).unwrap();
        assert!((vx - 0.5).abs() < 1e-6 && vy == 0.0 && wz == 0.0);
        assert_eq!(movement("后退 1.5m", 3.0), Some((-0.5, 0.0, 0.0)));
        assert_eq!(movement("左移 1 m", 2.0), Some((0.0, 0.5, 0.0)));
        let (_, _, wz) = movement("右转 90°", 2.0).unwrap();
        assert!((wz + std::f32::consts::FRAC_PI_4).abs() < 1e-6);
        assert!(movement("原地等待", 1.0).is_none());
    }

    #[test]
    fn compiles_design_timeline() {
        let devices = vec!["go2-05".to_owned(), "go2-06".to_owned()];
        let skills = HashMap::from([(
            "go2-05".to_owned(),
            vec![json!({"name": "hello", "description": "打招呼"})],
        )]);
        let tl = json!([
            {"device_id": "go2-05", "start_ms": 0, "end_ms": 2000, "action": "站立", "kind": "pose"},
            {"device_id": "go2-05", "start_ms": 2500, "end_ms": 8000, "action": "队形前进 3 m", "kind": "move"},
            {"device_id": "go2-05", "start_ms": 8600, "end_ms": 12000, "action": "打招呼", "kind": "act"},
            {"device_id": "go2-06", "start_ms": 100, "end_ms": 200, "action": "x",
             "command": {"kind": "set_speed", "level": "slow"}},
            {"device_id": "go2-99", "start_ms": 0, "end_ms": 1, "action": "站立", "kind": "pose"}
        ]);
        let steps = compile(&tl, &devices, &skills).unwrap();
        assert_eq!(steps.len(), 4);
        assert_eq!(steps[1].device_id, "go2-06");
        assert!(
            matches!(&steps[3].kind, StepKind::Once(Command::Action { name, .. }) if name == "hello")
        );

        let bad = json!([{"device_id": "go2-06", "start_ms": 0, "end_ms": 1, "action": "打招呼", "kind": "act"},
                         {"device_id": "go2-06", "start_ms": 0, "end_ms": 1, "action": "转圈圈", "kind": "move"}]);
        let err = compile(&bad, &devices, &skills).unwrap_err().to_string();
        assert!(err.contains("打招呼") && err.contains("转圈圈"), "{err}");
    }
}
