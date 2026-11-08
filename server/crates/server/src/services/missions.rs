//! 任务调度与执行（Missions.dc.html）。
//!
//! - **调度器**：每 15 秒检查一次，`state = scheduled` 且 `schedule` 里的某个时刻刚到的任务改为 `running`。
//!   `schedule` 仍是给人看的字符串，能识别「每天 / 工作日 / 周末 / 每周一、三」+ 若干 `HH:MM`，
//!   时间按 `SCHEDULE_TZ_OFFSET_MINUTES`（默认 +480，北京时间）解释。识别不出时刻的任务只能手动运行。
//! - **今日排期**：按 schedule 自动生成当天的 `run` 排期（`auto = true`），任务修改后重新生成。
//! - **执行**：选设备（主设备不可用时用备用设备）→ 以任务身份获取控制权 → 逐点下发
//!   `{"kind":"action","name":"navigate_to","params":{map_id,x,y,yaw}}`，机器人到达后回执 →
//!   执行点位动作（带 `skill` 的动作）→ 停留 `stay_secs` → 回写 `completed` 并推 `changed: missions`。
//!   失败按 `retries` 重试，仍失败则跳过该点并生成告警。`loop = true` 时跑完一轮从头开始。
//! - 暂停 / 删除 / 急停 / 控制权被收回 / 设备掉线：停止执行，任务回到 `paused`（删除除外），释放控制权。
//! - 服务重启后，`running` 状态的任务从 `completed` 处继续。

use std::time::{Duration, Instant};

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, NaiveTime, TimeZone, Utc};
use dashmap::DashMap;
use serde_json::{Value, json};
use tokio::sync::watch;
use uuid::Uuid;

use crate::{
    error::{AppError, AppResult},
    models::{Mission, MissionState},
    protocol::{Command, ServerEvent},
    services::{
        audit,
        control::{self, Actor},
        events,
    },
    state::AppState,
};

// ───────────────────────── 排期字符串 ─────────────────────────

/// 解析后的排期：哪几天（周一 = 0）、几点
#[derive(Debug, Clone, PartialEq)]
pub struct Schedule {
    pub days: [bool; 7],
    pub times: Vec<NaiveTime>,
}

impl Schedule {
    /// 本地日期 `day` 的所有运行时刻
    pub fn times_on(&self, day: NaiveDate) -> &[NaiveTime] {
        if self.days[day.weekday().num_days_from_monday() as usize] {
            &self.times
        } else {
            &[]
        }
    }
}

fn weekday_index(c: char) -> Option<usize> {
    Some(match c {
        '一' => 0,
        '二' => 1,
        '三' => 2,
        '四' => 3,
        '五' => 4,
        '六' => 5,
        '日' | '天' => 6,
        _ => return None,
    })
}

/// 识别「每天 09:00、14:00」「工作日 08:30」「周末 10:00」「每周一、三、五 21:00」。
/// 没有任何 `HH:MM` 时返回 None（只能手动运行）。
pub fn parse_schedule(s: &str) -> Option<Schedule> {
    let chars: Vec<char> = s.chars().collect();

    let mut times = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].is_ascii_digit() {
            let start = i;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
            if i + 2 < chars.len()
                && matches!(chars[i], ':' | '：')
                && chars[i + 1].is_ascii_digit()
                && chars[i + 2].is_ascii_digit()
                && i - start <= 2
            {
                let h: u32 = chars[start..i].iter().collect::<String>().parse().ok()?;
                let m: u32 = chars[i + 1..i + 3]
                    .iter()
                    .collect::<String>()
                    .parse()
                    .ok()?;
                if let Some(t) = NaiveTime::from_hms_opt(h, m, 0) {
                    times.push(t);
                }
                i += 3;
            }
        } else {
            i += 1;
        }
    }
    if times.is_empty() {
        return None;
    }
    times.sort();
    times.dedup();

    let mut days = [false; 7];
    let mut explicit = false;
    if s.contains("工作日") {
        days[..5].fill(true);
        explicit = true;
    }
    if s.contains("周末") {
        days[5] = true;
        days[6] = true;
        explicit = true;
    }
    // 「周一、三」「星期二」「每周六日」
    let mut j = 0;
    while j < chars.len() {
        let after = if chars[j] == '周' {
            Some(j + 1)
        } else if chars[j] == '星' && chars.get(j + 1) == Some(&'期') {
            Some(j + 2)
        } else {
            None
        };
        if let Some(mut k) = after {
            while k < chars.len() {
                if let Some(d) = weekday_index(chars[k]) {
                    days[d] = true;
                    explicit = true;
                } else if !matches!(chars[k], '、' | ',' | '，' | '/' | ' ' | '和' | '及') {
                    break;
                }
                k += 1;
            }
            j = k;
        } else {
            j += 1;
        }
    }
    if !explicit {
        days = [true; 7];
    }
    Some(Schedule { days, times })
}

/// 本地时间 (from, to] 内是否有运行时刻
pub fn due_between(
    sched: &Schedule,
    from: DateTime<FixedOffset>,
    to: DateTime<FixedOffset>,
) -> bool {
    let mut day = from.date_naive();
    while day <= to.date_naive() {
        for t in sched.times_on(day) {
            let Some(at) = from
                .timezone()
                .from_local_datetime(&day.and_time(*t))
                .single()
            else {
                continue;
            };
            if at > from && at <= to {
                return true;
            }
        }
        day = day.succ_opt().expect("date overflow");
    }
    false
}

// ───────────────────────── 点位 ─────────────────────────

#[derive(Debug, Clone)]
struct Waypoint {
    name: String,
    x: f64,
    y: f64,
    yaw: f64,
    stay_secs: u64,
    retries: u32,
    /// 带 `skill` 的点位动作：到达后按技能下发 `{"kind":"action","name":skill,"params":…}`
    actions: Vec<(String, String, Value)>,
}

fn waypoints(m: &Mission) -> Vec<Waypoint> {
    m.waypoints
        .as_array()
        .map(|a| {
            a.iter()
                .enumerate()
                .map(|(i, w)| Waypoint {
                    name: w["name"]
                        .as_str()
                        .map_or_else(|| format!("P{}", i + 1), str::to_owned),
                    x: w["x"].as_f64().unwrap_or(0.0),
                    y: w["y"].as_f64().unwrap_or(0.0),
                    yaw: w["yaw"].as_f64().unwrap_or(0.0),
                    stay_secs: w["stay_secs"].as_u64().unwrap_or(0),
                    retries: w["retries"].as_u64().unwrap_or(0).min(10) as u32,
                    actions: w["actions"]
                        .as_array()
                        .map(|acts| {
                            acts.iter()
                                .filter_map(|a| {
                                    Some((
                                        a["name"].as_str().unwrap_or_default().to_owned(),
                                        a["skill"].as_str()?.to_owned(),
                                        a.get("params").cloned().unwrap_or_else(|| json!({})),
                                    ))
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .collect()
        })
        .unwrap_or_default()
}

/// 估算一轮耗时（排期条的长度）：每个点位 60 秒路程 + 停留
fn estimate(m: &Mission) -> chrono::Duration {
    let secs: u64 = waypoints(m).iter().map(|w| 60 + w.stay_secs).sum();
    chrono::Duration::seconds(secs.max(300) as i64)
}

// ───────────────────────── 执行器 ─────────────────────────

/// 停止原因：决定任务最后的状态
#[derive(Debug, Clone, Copy, PartialEq)]
enum StopReason {
    /// 成员暂停 / 改回排期：状态已由路由写好
    External,
    /// 任务被删除
    Deleted,
}

struct Running {
    cancel: watch::Sender<Option<StopReason>>,
}

#[derive(Default)]
pub struct MissionRunner {
    running: DashMap<Uuid, Running>,
}

impl MissionRunner {
    pub fn is_running(&self, id: Uuid) -> bool {
        self.running.contains_key(&id)
    }

    /// 让任务的执行与数据库状态一致：running → 启动；其他 → 停止
    pub fn sync(&self, st: &AppState, m: &Mission) {
        if m.state == MissionState::Running {
            self.start(st, m.id);
        } else {
            self.stop(m.id, false);
        }
    }

    /// 停止执行；`deleted` 表示任务已删除
    pub fn stop(&self, id: Uuid, deleted: bool) {
        if let Some((_, r)) = self.running.remove(&id) {
            let _ = r.cancel.send(Some(if deleted {
                StopReason::Deleted
            } else {
                StopReason::External
            }));
        }
    }

    fn start(&self, st: &AppState, id: Uuid) {
        let (tx, rx) = watch::channel(None);
        match self.running.entry(id) {
            dashmap::Entry::Occupied(_) => return,
            dashmap::Entry::Vacant(v) => {
                v.insert(Running { cancel: tx });
            }
        }
        let st = st.clone();
        tokio::spawn(async move {
            run(&st, id, rx).await;
            st.missions.running.remove(&id);
        });
    }
}

/// 结束一次执行时任务要落到的状态
enum Outcome {
    /// 一轮跑完（非循环）：回到 scheduled，completed 清零
    Finished,
    /// 出错：paused，保留 completed，提示原因
    Failed(String),
    Stopped(StopReason),
}

async fn load(st: &AppState, id: Uuid) -> AppResult<Option<Mission>> {
    Ok(sqlx::query_as("SELECT * FROM missions WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?)
}

fn changed(st: &AppState, id: Uuid) {
    st.hub.publish(ServerEvent::changed("missions", Some(id)));
}

/// 选设备：主设备在线且未急停优先，否则备用设备
fn pick_device(st: &AppState, m: &Mission) -> Result<String, String> {
    if m.assignee.get("preset_id").is_some_and(|v| !v.is_null()) {
        return Err("暂不支持由联调预设执行任务，请指定设备".into());
    }
    let usable = |id: &str| st.hub.is_online(id) && !st.hub.is_device_estopped(id);
    let main = m.assignee["device_id"].as_str();
    let backup = m.assignee["backup_device_id"].as_str();
    if main.is_none() && backup.is_none() {
        return Err("任务没有指定执行设备".into());
    }
    if st.safety.is_global_estop() {
        return Err("全局急停中".into());
    }
    main.into_iter()
        .chain(backup)
        .find(|id| usable(id))
        .map(str::to_owned)
        .ok_or_else(|| "执行设备与备用设备都不在线或处于急停".into())
}

async fn run(st: &AppState, id: Uuid, mut cancel: watch::Receiver<Option<StopReason>>) {
    let Ok(Some(m)) = load(st, id).await else {
        return;
    };
    let device = match pick_device(st, &m) {
        Ok(d) => d,
        Err(e) => {
            finish(st, &m, None, Outcome::Failed(e), None).await;
            return;
        }
    };
    if let Err(e) = st.leases.acquire_for_task(id, &m.name, &device).await {
        finish(st, &m, Some(&device), Outcome::Failed(e.to_string()), None).await;
        return;
    }
    let entry = open_schedule_entry(st, &m, &device).await;
    events::record(st, &device, format!("开始执行任务「{}」", m.name), "info").await;

    let outcome = tokio::select! {
        o = execute(st, id, &device) => o,
        r = async {
            loop {
                if let Some(r) = *cancel.borrow_and_update() {
                    return r;
                }
                if cancel.changed().await.is_err() {
                    return StopReason::External;
                }
            }
        } => Outcome::Stopped(r),
    };
    let m = load(st, id).await.ok().flatten().unwrap_or(m);
    finish(st, &m, Some(&device), outcome, entry).await;
}

/// 逐点执行，直到一轮结束（非循环）或出错
async fn execute(st: &AppState, id: Uuid, device: &str) -> Outcome {
    let step_timeout = Duration::from_secs(st.cfg.mission_step_timeout_secs);
    loop {
        let Ok(Some(m)) = load(st, id).await else {
            return Outcome::Stopped(StopReason::Deleted);
        };
        let points = waypoints(&m);
        if points.is_empty() {
            return Outcome::Failed("任务没有点位".into());
        }
        let idx = m.completed.max(0) as usize;
        if idx >= points.len() {
            if !m.loop_enabled {
                return Outcome::Finished;
            }
            set_completed(st, id, 0).await;
            continue;
        }
        let wp = &points[idx];
        let label = format!("任务「{}」", m.name);

        if !st.leases.is_task_holder(device, id) {
            return Outcome::Failed("控制权已被收回".into());
        }

        let mut last_err = String::new();
        let mut arrived = false;
        let started = Instant::now();
        for attempt in 0..=wp.retries {
            let cmd = Command::Action {
                name: "navigate_to".into(),
                params: json!({ "map_id": m.map_id, "x": wp.x, "y": wp.y, "yaw": wp.yaw }),
            };
            match control::execute_with_timeout(
                st,
                Actor::System(&label),
                device,
                cmd,
                Some(step_timeout),
            )
            .await
            {
                Ok(r) if r.ok == Some(true) => {
                    arrived = true;
                    break;
                }
                Ok(r) => last_err = r.message.unwrap_or_else(|| "机器人执行失败".into()),
                Err(AppError::EstopActive) => return Outcome::Failed("急停中".into()),
                Err(AppError::RobotOffline(_)) => return Outcome::Failed("设备掉线".into()),
                Err(e) => last_err = e.to_string(),
            }
            tracing::warn!(mission = %id, point = %wp.name, attempt, error = %last_err, "点位导航失败");
            if !st.leases.is_task_holder(device, id) {
                return Outcome::Failed("控制权已被收回".into());
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }

        if arrived {
            for (name, skill, params) in &wp.actions {
                let cmd = Command::Action {
                    name: skill.clone(),
                    params: params.clone(),
                };
                if let Ok(r) = control::execute(st, Actor::System(&label), device, cmd, true).await
                    && r.ok != Some(true)
                {
                    let why = r.message.unwrap_or_default();
                    events::record(
                        st,
                        device,
                        format!("{label} 在 {} 的动作「{name}」失败：{why}", wp.name),
                        "warning",
                    )
                    .await;
                }
            }
            if wp.stay_secs > 0 {
                tokio::time::sleep(Duration::from_secs(wp.stay_secs)).await;
            }
            tracing::debug!(mission = %id, point = %wp.name, secs = started.elapsed().as_secs(), "到达点位");
        } else {
            let msg = format!(
                "{label} 未能到达 {}（重试 {} 次）：{last_err}",
                wp.name, wp.retries
            );
            events::record(st, device, &msg, "warning").await;
            if let Err(e) = st
                .alerts
                .raise_robot_event(st, device, "warning", "mission_waypoint_failed", &msg)
                .await
            {
                tracing::warn!(error = %e, "生成任务告警失败");
            }
        }
        set_completed(st, id, idx as i32 + 1).await;
    }
}

async fn set_completed(st: &AppState, id: Uuid, n: i32) {
    let _ = sqlx::query("UPDATE missions SET completed = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(n)
        .execute(&st.db)
        .await;
    changed(st, id);
}

/// 执行开始时找到 / 新建这次运行的排期条
async fn open_schedule_entry(st: &AppState, m: &Mission, device: &str) -> Option<i64> {
    let now = Utc::now();
    let existing: Option<i64> = sqlx::query_scalar(
        "UPDATE schedule_entries SET device_id = $2, starts_at = LEAST(starts_at, $3)
         WHERE id = (SELECT id FROM schedule_entries WHERE mission_id = $1 AND kind = 'run'
                     AND starts_at <= $3 + interval '5 minutes' AND ends_at >= $3
                     ORDER BY starts_at LIMIT 1)
         RETURNING id",
    )
    .bind(m.id)
    .bind(device)
    .bind(now)
    .fetch_optional(&st.db)
    .await
    .ok()
    .flatten();
    let id = match existing {
        Some(id) => Some(id),
        None => sqlx::query_scalar(
            "INSERT INTO schedule_entries (device_id, starts_at, ends_at, label, kind, mission_id)
             VALUES ($1, $2, $3, $4, 'run', $5) RETURNING id",
        )
        .bind(device)
        .bind(now)
        .bind(now + estimate(m))
        .bind(&m.name)
        .bind(m.id)
        .fetch_one(&st.db)
        .await
        .ok(),
    };
    st.hub
        .publish(ServerEvent::changed("schedule", None::<String>));
    id
}

async fn finish(
    st: &AppState,
    m: &Mission,
    device: Option<&str>,
    outcome: Outcome,
    entry: Option<i64>,
) {
    if let Some(device) = device {
        if !matches!(outcome, Outcome::Finished) {
            let _ =
                control::execute(st, Actor::System("任务停止"), device, Command::Stop, false).await;
        }
        if let Err(e) = st.leases.release_task(m.id).await {
            tracing::warn!(error = %e, "释放任务控制权失败");
        }
    }
    if let Some(entry) = entry {
        let _ = sqlx::query(
            "UPDATE schedule_entries SET ends_at = GREATEST(now(), starts_at + interval '1 second')
             WHERE id = $1",
        )
        .bind(entry)
        .execute(&st.db)
        .await;
        st.hub
            .publish(ServerEvent::changed("schedule", None::<String>));
    }

    let (state_sql, text, tone) = match &outcome {
        Outcome::Finished => (
            Some(
                "UPDATE missions SET state = 'scheduled', completed = 0, updated_at = now() WHERE id = $1 AND state = 'running'",
            ),
            format!("任务「{}」已完成", m.name),
            "success",
        ),
        Outcome::Failed(why) => (
            Some(
                "UPDATE missions SET state = 'paused', updated_at = now() WHERE id = $1 AND state = 'running'",
            ),
            format!("任务「{}」已暂停：{why}", m.name),
            "warning",
        ),
        Outcome::Stopped(StopReason::External) => {
            (None, format!("任务「{}」已停止", m.name), "info")
        }
        Outcome::Stopped(StopReason::Deleted) => {
            (None, format!("任务「{}」已删除，停止执行", m.name), "info")
        }
    };
    if let Some(sql) = state_sql {
        let _ = sqlx::query(sql).bind(m.id).execute(&st.db).await;
    }
    if let Some(device) = device {
        events::record(st, device, &text, tone).await;
    }
    if let Outcome::Failed(_) = outcome {
        if let Some(owner) = m.created_by {
            st.hub.publish(ServerEvent::Notice {
                member_id: owner,
                level: "warning".into(),
                text: text.clone(),
            });
        }
        audit::record_system(
            st,
            audit::Kind::System,
            &text,
            &m.name,
            json!({ "mission_id": m.id }),
        )
        .await;
    }
    changed(st, m.id);
}

// ───────────────────────── 调度器 ─────────────────────────

fn tz(st: &AppState) -> FixedOffset {
    FixedOffset::east_opt(st.cfg.schedule_tz_offset_minutes * 60)
        .unwrap_or_else(|| FixedOffset::east_opt(0).expect("utc"))
}

/// 排期使用的本地日期（GET /schedule 缺省日期）
pub fn local_today(st: &AppState) -> NaiveDate {
    Utc::now().with_timezone(&tz(st)).date_naive()
}

/// 本地日期 `day` 的 [00:00, 次日 00:00)，换算成 UTC
pub fn local_day_range(st: &AppState, day: NaiveDate) -> (DateTime<Utc>, DateTime<Utc>) {
    let tz = tz(st);
    let from = tz
        .from_local_datetime(&day.and_hms_opt(0, 0, 0).expect("midnight"))
        .single()
        .expect("fixed offset")
        .with_timezone(&Utc);
    (from, from + chrono::Duration::days(1))
}

/// 按 schedule 重新生成某任务今天还没开始的自动排期（任务新建 / 修改 / 删除、每天零点）
pub async fn plan_today(st: &AppState, mission_id: Option<Uuid>) -> AppResult<()> {
    let day = local_today(st);
    let (from, to) = local_day_range(st, day);
    let now = Utc::now();
    sqlx::query(
        "DELETE FROM schedule_entries WHERE auto AND starts_at > $1 AND starts_at < $2
         AND ($3::uuid IS NULL OR mission_id = $3)",
    )
    .bind(now)
    .bind(to)
    .bind(mission_id)
    .execute(&st.db)
    .await?;
    let missions: Vec<Mission> = sqlx::query_as(
        "SELECT * FROM missions WHERE schedule IS NOT NULL AND state <> 'paused'
         AND ($1::uuid IS NULL OR id = $1)",
    )
    .bind(mission_id)
    .fetch_all(&st.db)
    .await?;
    let tz = tz(st);
    for m in missions {
        let Some(sched) = m.schedule.as_deref().and_then(parse_schedule) else {
            continue;
        };
        let Some(device) = m.assignee["device_id"].as_str() else {
            continue;
        };
        for t in sched.times_on(day) {
            let Some(at) = tz.from_local_datetime(&day.and_time(*t)).single() else {
                continue;
            };
            let at = at.with_timezone(&Utc);
            if at <= now || at < from {
                continue;
            }
            sqlx::query(
                "INSERT INTO schedule_entries (device_id, starts_at, ends_at, label, kind, mission_id, auto)
                 VALUES ($1, $2, $3, $4, 'run', $5, TRUE)
                 ON CONFLICT (mission_id, starts_at) WHERE auto DO NOTHING",
            )
            .bind(device)
            .bind(at)
            .bind(at + estimate(&m))
            .bind(&m.name)
            .bind(m.id)
            .execute(&st.db)
            .await?;
        }
    }
    st.hub
        .publish(ServerEvent::changed("schedule", None::<String>));
    Ok(())
}

/// 后台：恢复重启前在跑的任务；每 15 秒触发到点的任务；跨天时生成新一天的排期
pub async fn scheduler(st: AppState) {
    match sqlx::query_as::<_, Mission>("SELECT * FROM missions WHERE state = 'running'")
        .fetch_all(&st.db)
        .await
    {
        Ok(ms) => {
            for m in ms {
                tracing::info!(mission = %m.id, "恢复执行任务");
                st.missions.sync(&st, &m);
            }
        }
        Err(e) => tracing::error!(error = %e, "加载运行中的任务失败"),
    }
    if let Err(e) = plan_today(&st, None).await {
        tracing::warn!(error = %e, "生成今日排期失败");
    }

    let tz = tz(&st);
    let mut last = Utc::now().with_timezone(&tz);
    let mut planned_day = last.date_naive();
    let mut tick = tokio::time::interval(Duration::from_secs(15));
    loop {
        tick.tick().await;
        let now = Utc::now().with_timezone(&tz);
        if now.date_naive() != planned_day {
            planned_day = now.date_naive();
            if let Err(e) = plan_today(&st, None).await {
                tracing::warn!(error = %e, "生成今日排期失败");
            }
        }
        if let Err(e) = trigger_due(&st, last, now).await {
            tracing::error!(error = %e, "检查到点任务失败");
        }
        last = now;
    }
}

async fn trigger_due(
    st: &AppState,
    from: DateTime<FixedOffset>,
    to: DateTime<FixedOffset>,
) -> AppResult<()> {
    let missions: Vec<Mission> =
        sqlx::query_as("SELECT * FROM missions WHERE state = 'scheduled' AND schedule IS NOT NULL")
            .fetch_all(&st.db)
            .await?;
    for m in missions {
        let Some(sched) = m.schedule.as_deref().and_then(parse_schedule) else {
            continue;
        };
        if !due_between(&sched, from, to) {
            continue;
        }
        let started: Option<Mission> = sqlx::query_as(
            "UPDATE missions SET state = 'running', completed = 0, updated_at = now()
             WHERE id = $1 AND state = 'scheduled' RETURNING *",
        )
        .bind(m.id)
        .fetch_optional(&st.db)
        .await?;
        if let Some(m) = started {
            tracing::info!(mission = %m.id, "按排期启动任务");
            audit::record_system(
                st,
                audit::Kind::Control,
                format!("按排期启动任务「{}」", m.name),
                &m.name,
                json!({ "mission_id": m.id }),
            )
            .await;
            changed(st, m.id);
            st.missions.sync(st, &m);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn t(h: u32, m: u32) -> NaiveTime {
        NaiveTime::from_hms_opt(h, m, 0).unwrap()
    }

    #[test]
    fn parses_daily() {
        let s = parse_schedule("每天 09:00、14:00").unwrap();
        assert_eq!(s.days, [true; 7]);
        assert_eq!(s.times, vec![t(9, 0), t(14, 0)]);
        assert_eq!(parse_schedule("8:30").unwrap().times, vec![t(8, 30)]);
        assert_eq!(parse_schedule("每天 21：05").unwrap().times, vec![t(21, 5)]);
    }

    #[test]
    fn parses_weekdays() {
        let s = parse_schedule("工作日 08:30").unwrap();
        assert_eq!(s.days, [true, true, true, true, true, false, false]);
        let s = parse_schedule("周末 10:00").unwrap();
        assert_eq!(s.days, [false, false, false, false, false, true, true]);
        let s = parse_schedule("每周一、三、五 21:00").unwrap();
        assert_eq!(s.days, [true, false, true, false, true, false, false]);
        let s = parse_schedule("星期日 07:00").unwrap();
        assert_eq!(s.days, [false, false, false, false, false, false, true]);
    }

    #[test]
    fn manual_only() {
        assert!(parse_schedule("手动").is_none());
        assert!(parse_schedule("").is_none());
        assert!(parse_schedule("25:00").is_none());
    }

    #[test]
    fn due_window() {
        let tz = FixedOffset::east_opt(8 * 3600).unwrap();
        let s = parse_schedule("每天 09:00").unwrap();
        let at = |h, m, sec| tz.with_ymd_and_hms(2026, 11, 9, h, m, sec).unwrap();
        assert!(due_between(&s, at(8, 59, 50), at(9, 0, 5)));
        assert!(due_between(&s, at(8, 59, 50), at(9, 0, 0)));
        assert!(!due_between(&s, at(9, 0, 0), at(9, 0, 15)));
        assert!(!due_between(&s, at(8, 0, 0), at(8, 59, 59)));
        // 跨零点
        let s = parse_schedule("每天 00:00").unwrap();
        let late = tz.with_ymd_and_hms(2026, 11, 8, 23, 59, 50).unwrap();
        assert!(due_between(&s, late, at(0, 0, 5)));
        // 2026-11-09 是周一，「周末」不触发
        let s = parse_schedule("周末 09:00").unwrap();
        assert!(!due_between(&s, at(8, 59, 50), at(9, 0, 5)));
    }

    #[test]
    fn reads_waypoints() {
        let m = Mission {
            id: Uuid::nil(),
            name: "x".into(),
            map_id: "b2".into(),
            waypoints: json!([
                {"name": "P1", "x": 1.0, "y": 2.0, "yaw": 0.5, "stay_secs": 30, "retries": 2,
                 "actions": [{"name": "拍照", "detail": "前置相机"}, {"name": "挥手", "skill": "hello"}]},
                {"x": 3}
            ]),
            schedule: None,
            assignee: json!({}),
            state: MissionState::Scheduled,
            completed: 0,
            loop_enabled: false,
            created_by: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let w = waypoints(&m);
        assert_eq!(w.len(), 2);
        assert_eq!(w[0].actions.len(), 1);
        assert_eq!(w[0].actions[0].1, "hello");
        assert_eq!(w[1].name, "P2");
        assert_eq!(estimate(&m).num_seconds(), 300);
    }
}
