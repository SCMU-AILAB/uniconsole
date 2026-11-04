//! 多机联调（Fleet.dc.html）。会话开始时一次性获取所有参与设备的租约，
//! 同步指令向所有设备并发下发并汇总回执。
//! TODO：时间轴（timeline）执行器、编队保持控制、PTP 时钟偏差统计。

use std::time::Instant;

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::Utc;
use futures::future::join_all;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{FleetPreset, FleetSession, Formation, Role},
    protocol::{Command, MotionMode, ServerEvent, SpeedLevel},
    services::{
        access, audit,
        control::{self, Actor},
        events, recordings,
    },
    state::AppState,
};

fn changed(st: &AppState, id: Uuid) {
    st.hub
        .publish(ServerEvent::changed("fleet_sessions", Some(id)));
}

async fn load(st: &AppState, id: Uuid) -> AppResult<FleetSession> {
    sqlx::query_as("SELECT * FROM fleet_sessions WHERE id = $1")
        .bind(id)
        .fetch_optional(&st.db)
        .await?
        .ok_or_else(|| AppError::not_found("联调会话不存在"))
}

fn ensure_owner(user: &AuthUser, s: &FleetSession) -> AppResult<()> {
    if s.owner_id != user.id && user.role != Role::Admin {
        return Err(AppError::forbidden("只有会话发起人可以操作该会话"));
    }
    Ok(())
}

async fn check_devices(st: &AppState, user: &AuthUser, ids: &[String]) -> AppResult<()> {
    for id in ids {
        access::require_device(&st.db, user, Perm::FleetSession, id).await?;
    }
    Ok(())
}

async fn labels(st: &AppState, ids: &[String]) -> String {
    let names: Vec<String> = sqlx::query_scalar(
        "SELECT d.name FROM unnest($1::text[]) WITH ORDINALITY AS t(id, n)
         JOIN devices d ON d.id = t.id ORDER BY t.n",
    )
    .bind(ids)
    .fetch_all(&st.db)
    .await
    .unwrap_or_default();
    names.join("、")
}

fn session_label(s: &FleetSession) -> String {
    format!("联调会话 #{}「{}」", s.number, s.name)
}

#[derive(Deserialize)]
pub struct ListQuery {
    pub active: Option<bool>,
}

pub async fn list(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<ListQuery>,
) -> AppResult<Json<Vec<FleetSession>>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(
        sqlx::query_as(
            "SELECT * FROM fleet_sessions WHERE ($1::bool IS NULL OR active = $1)
             ORDER BY active DESC, updated_at DESC",
        )
        .bind(q.active)
        .fetch_all(&st.db)
        .await?,
    ))
}

pub async fn get(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(load(&st, id).await?))
}

#[derive(Deserialize, Default)]
pub struct UpsertSession {
    #[serde(alias = "name")]
    pub title: Option<String>,
    pub device_ids: Option<Vec<String>>,
    pub formation: Option<Formation>,
    pub spacing: Option<f32>,
    pub timeline: Option<Value>,
    pub preset_id: Option<String>,
    pub control_mode: Option<String>,
    pub clock_sync: Option<String>,
    pub lost_link_action: Option<String>,
    /// 只用于 PATCH：false = 急停解除后恢复会话
    pub paused: Option<bool>,
}

#[derive(Deserialize)]
pub struct CreateQuery {
    #[serde(default)]
    pub start: bool,
}

/// POST /fleet-sessions[?start=true]：可按预设发起（`preset_id`），`start=true` 时直接开始，
/// 任一设备不可用则整体失败（409 + device_ids），会话不会留下
pub async fn create(
    State(st): State<AppState>,
    user: AuthUser,
    Query(q): Query<CreateQuery>,
    Json(mut req): Json<UpsertSession>,
) -> AppResult<(StatusCode, Json<FleetSession>)> {
    user.require(Perm::FleetSession)?;
    if let Some(pid) = &req.preset_id {
        let p: FleetPreset = sqlx::query_as("SELECT * FROM fleet_presets WHERE id = $1")
            .bind(pid)
            .fetch_optional(&st.db)
            .await?
            .ok_or_else(|| AppError::not_found("联调预设不存在"))?;
        req.title.get_or_insert(p.name);
        req.device_ids.get_or_insert(p.device_ids);
        req.formation.get_or_insert(p.formation);
        req.spacing.get_or_insert(p.spacing);
    }
    let ids = req.device_ids.clone().unwrap_or_default();
    check_devices(&st, &user, &ids).await?;
    let s: FleetSession = sqlx::query_as(
        "INSERT INTO fleet_sessions (name, owner_id, device_ids, formation, spacing, timeline, preset_id,
                                     control_mode, clock_sync, lost_link_action)
         VALUES ($1, $2, $3, COALESCE($4, 'line'), COALESCE($5, 1.0), COALESCE($6, '[]'::jsonb), $7,
                 COALESCE($8, '领队-跟随'), COALESCE($9, 'PTP · 局域网'), COALESCE($10, '原地趴下'))
         RETURNING *",
    )
    .bind(req.title.unwrap_or_else(|| "新联调会话".into()))
    .bind(user.id)
    .bind(&ids)
    .bind(req.formation)
    .bind(req.spacing)
    .bind(req.timeline)
    .bind(req.preset_id)
    .bind(req.control_mode)
    .bind(req.clock_sync)
    .bind(req.lost_link_action)
    .fetch_one(&st.db)
    .await?;
    if q.start {
        if let Err(e) = start_session(&st, &user, &s).await {
            sqlx::query("DELETE FROM fleet_sessions WHERE id = $1")
                .bind(s.id)
                .execute(&st.db)
                .await?;
            return Err(e);
        }
        return Ok((StatusCode::CREATED, Json(load(&st, s.id).await?)));
    }
    changed(&st, s.id);
    Ok((StatusCode::CREATED, Json(s)))
}

async fn start_session(st: &AppState, user: &AuthUser, s: &FleetSession) -> AppResult<()> {
    if s.device_ids.is_empty() {
        return Err(AppError::bad_request("请先选择参与设备"));
    }
    if st.safety.is_global_estop() {
        return Err(AppError::EstopActive);
    }
    check_devices(st, user, &s.device_ids).await?;
    st.leases
        .acquire_for_session(s.id, &format!("联调会话 #{}", s.number), &s.device_ids)
        .await?;
    sqlx::query(
        "UPDATE fleet_sessions SET active = TRUE, paused = FALSE, started_at = now(), updated_at = now()
         WHERE id = $1",
    )
    .bind(s.id)
    .execute(&st.db)
    .await?;
    for d in &s.device_ids {
        events::record(st, d, format!("加入{}", session_label(s)), "info").await;
    }
    audit::record(
        st,
        user,
        audit::Kind::Control,
        format!(
            "发起{}（{}）",
            session_label(s),
            labels(st, &s.device_ids).await
        ),
        session_label(s),
        json!({ "devices": s.device_ids }),
    )
    .await;
    changed(st, s.id);
    Ok(())
}

pub async fn start(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if s.active {
        return Err(AppError::conflict("会话已在进行中"));
    }
    start_session(&st, &user, &s).await?;
    Ok(Json(load(&st, id).await?))
}

async fn stop_devices(st: &AppState, ids: &[String]) {
    for d in ids {
        let _ = control::execute(st, Actor::System("联调结束"), d, Command::Stop, false).await;
    }
}

async fn end_session(st: &AppState, s: &FleetSession, by: &str) -> AppResult<()> {
    stop_devices(st, &s.device_ids).await;
    if let Some(start) = s.started_at
        && !s.device_ids.is_empty()
    {
        let _ = recordings::auto_record(
            st,
            &session_label(s),
            &s.device_ids,
            start,
            Utc::now(),
            "fleet",
            &s.id.to_string(),
        )
        .await;
    }
    st.leases.release_session(s.id, None).await?;
    sqlx::query(
        "UPDATE fleet_sessions SET active = FALSE, paused = FALSE, updated_at = now() WHERE id = $1",
    )
    .bind(s.id)
    .execute(&st.db)
    .await?;
    for d in &s.device_ids {
        events::record(
            st,
            d,
            format!("{}结束（{by}）", session_label(s)),
            "neutral",
        )
        .await;
    }
    changed(st, s.id);
    Ok(())
}

pub async fn stop(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    end_session(&st, &s, &user.name).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("结束{}", session_label(&s)),
        session_label(&s),
        json!({}),
    )
    .await;
    Ok(Json(load(&st, id).await?))
}

/// PATCH /fleet-sessions/{id}
/// - 进行中修改 device_ids：新加入的设备由会话接管控制权（被占用 409 + device_ids），移出的设备停止并释放；
///   最后一台退出则会话自动结束
/// - `paused: false`：急停解除后恢复会话
pub async fn update(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertSession>,
) -> AppResult<Json<FleetSession>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;

    if let Some(ids) = &req.device_ids {
        check_devices(&st, &user, ids).await?;
        if s.active {
            let added: Vec<String> = ids
                .iter()
                .filter(|d| !s.device_ids.contains(d))
                .cloned()
                .collect();
            let removed: Vec<String> = s
                .device_ids
                .iter()
                .filter(|d| !ids.contains(d))
                .cloned()
                .collect();
            if !added.is_empty() {
                st.leases
                    .acquire_for_session(s.id, &format!("联调会话 #{}", s.number), &added)
                    .await?;
                for d in &added {
                    events::record(&st, d, format!("加入{}", session_label(&s)), "info").await;
                }
            }
            if !removed.is_empty() {
                stop_devices(&st, &removed).await;
                st.leases.release_session(s.id, Some(&removed)).await?;
                for d in &removed {
                    events::record(&st, d, format!("退出{}", session_label(&s)), "neutral").await;
                }
            }
            if ids.is_empty() {
                end_session(&st, &s, "最后一台设备退出").await?;
            }
            if !added.is_empty() || !removed.is_empty() {
                audit::record(
                    &st,
                    &user,
                    audit::Kind::Control,
                    format!(
                        "调整{}的参与设备（{}）",
                        session_label(&s),
                        labels(&st, ids).await
                    ),
                    session_label(&s),
                    json!({ "added": added, "removed": removed }),
                )
                .await;
            }
        }
    }
    if req.paused == Some(false) && st.safety.is_global_estop() {
        return Err(AppError::EstopActive);
    }
    if req.paused == Some(true) {
        return Err(AppError::bad_request("会话只会因急停暂停，不能手动暂停"));
    }

    sqlx::query(
        "UPDATE fleet_sessions SET name = COALESCE($2, name), device_ids = COALESCE($3, device_ids),
         formation = COALESCE($4, formation), spacing = COALESCE($5, spacing),
         timeline = COALESCE($6, timeline), control_mode = COALESCE($7, control_mode),
         clock_sync = COALESCE($8, clock_sync), lost_link_action = COALESCE($9, lost_link_action),
         paused = COALESCE($10, paused), updated_at = now()
         WHERE id = $1",
    )
    .bind(id)
    .bind(req.title)
    .bind(req.device_ids)
    .bind(req.formation)
    .bind(req.spacing)
    .bind(req.timeline)
    .bind(req.control_mode)
    .bind(req.clock_sync)
    .bind(req.lost_link_action)
    .bind(req.paused)
    .execute(&st.db)
    .await?;
    changed(&st, id);
    Ok(Json(load(&st, id).await?))
}

pub async fn remove(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if s.active {
        end_session(&st, &s, &user.name).await?;
    }
    sqlx::query("DELETE FROM fleet_sessions WHERE id = $1")
        .bind(id)
        .execute(&st.db)
        .await?;
    changed(&st, id);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
pub struct FleetCommand {
    pub command: Command,
    /// 为空表示所有参与设备
    pub device_ids: Option<Vec<String>>,
    /// 回执标题，如「同步站立」；缺省按指令生成
    pub label: Option<String>,
}

#[derive(Serialize)]
pub struct Ack {
    pub device_id: String,
    pub ok: bool,
    pub latency_ms: Option<u64>,
    pub error: Option<String>,
    pub message: Option<String>,
}

fn command_label(c: &Command) -> String {
    match c {
        Command::Move { .. } => "同步移动".into(),
        Command::Stop => "同步停止".into(),
        Command::SetMode { mode } => format!(
            "同步{}",
            match mode {
                MotionMode::Stand => "站立",
                MotionMode::Down => "趴下",
                MotionMode::Balance => "平衡站立",
                MotionMode::Walk => "行走",
                MotionMode::Stairs => "爬楼梯",
                MotionMode::Damp => "阻尼",
                MotionMode::Recovery => "恢复站立",
            }
        ),
        Command::SetSpeed { level } => format!(
            "同步切换为{}速",
            match level {
                SpeedLevel::Slow => "慢",
                SpeedLevel::Normal => "标准",
                SpeedLevel::Fast => "快",
            }
        ),
        Command::Estop { .. } => "同步急停".into(),
        Command::ReleaseEstop => "同步解除急停".into(),
        Command::Action { name, .. } => format!("同步动作 {name}"),
    }
}

/// POST /fleet-sessions/{id}/commands：同步指令，并发下发并汇总每台设备的回执
pub async fn command(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<FleetCommand>,
) -> AppResult<Json<Value>> {
    let s = load(&st, id).await?;
    ensure_owner(&user, &s)?;
    if !s.active {
        return Err(AppError::conflict("会话未开始"));
    }
    if s.paused && req.command.is_motion() {
        return Err(AppError::conflict("会话因急停已暂停，请先恢复会话"));
    }
    let targets: Vec<String> = match req.device_ids {
        Some(ids) => ids
            .into_iter()
            .filter(|i| s.device_ids.contains(i))
            .collect(),
        None => s.device_ids.clone(),
    };
    let sent_at = Utc::now();
    let started = Instant::now();
    let futs = targets.iter().map(|d| {
        let (st, user, cmd, d) = (st.clone(), user.clone(), req.command.clone(), d.clone());
        async move {
            match control::execute(&st, Actor::User(&user), &d, cmd, true).await {
                Ok(r) => Ack {
                    device_id: d,
                    ok: r.ok.unwrap_or(false),
                    latency_ms: r.latency_ms,
                    error: r.error,
                    message: r.message,
                },
                Err(e) => Ack {
                    device_id: d,
                    ok: false,
                    latency_ms: None,
                    error: Some(e.code().to_owned()),
                    message: Some(e.to_string()),
                },
            }
        }
    });
    let acks = join_all(futs).await;
    // 各设备在同一时刻执行时相对发出时刻的偏移：取最慢回执，向上取整到 50 ms
    let slowest = acks
        .iter()
        .filter_map(|a| a.latency_ms)
        .max()
        .unwrap_or(started.elapsed().as_millis() as u64);
    let receipt = json!({
        "label": req.label.unwrap_or_else(|| command_label(&req.command)),
        "sent_at": sent_at,
        "schedule_offset_ms": slowest.div_ceil(50) * 50,
        "acks": acks,
    });
    sqlx::query("UPDATE fleet_sessions SET last_receipt = $2, updated_at = now() WHERE id = $1")
        .bind(id)
        .bind(&receipt)
        .execute(&st.db)
        .await?;
    changed(&st, id);
    Ok(Json(receipt))
}

// ───────── 预设 ─────────

pub async fn list_presets(
    State(st): State<AppState>,
    user: AuthUser,
) -> AppResult<Json<Vec<FleetPreset>>> {
    user.require(Perm::ViewDevice)?;
    Ok(Json(
        sqlx::query_as("SELECT * FROM fleet_presets ORDER BY created_at")
            .fetch_all(&st.db)
            .await?,
    ))
}

#[derive(Deserialize)]
pub struct CreatePreset {
    pub id: Option<String>,
    pub name: String,
    /// 把该会话的设备、队形、间距保存为预设；否则使用下面的字段
    pub session_id: Option<Uuid>,
    pub device_ids: Option<Vec<String>>,
    pub formation: Option<Formation>,
    pub spacing: Option<f32>,
}

pub async fn create_preset(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<CreatePreset>,
) -> AppResult<(StatusCode, Json<FleetPreset>)> {
    user.require(Perm::FleetSession)?;
    let name = req.name.trim();
    if name.is_empty() {
        return Err(AppError::bad_request("请填写预设名称"));
    }
    let (ids, formation, spacing) = match req.session_id {
        Some(sid) => {
            let s = load(&st, sid).await?;
            (s.device_ids, s.formation, s.spacing)
        }
        None => (
            req.device_ids.unwrap_or_default(),
            req.formation.unwrap_or(Formation::Line),
            req.spacing.unwrap_or(1.0),
        ),
    };
    let id = req
        .id
        .unwrap_or_else(|| format!("p-{}", &Uuid::new_v4().simple().to_string()[..8]));
    let p: FleetPreset = sqlx::query_as(
        "INSERT INTO fleet_presets (id, name, device_ids, formation, spacing, created_by)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING *",
    )
    .bind(&id)
    .bind(name)
    .bind(&ids)
    .bind(formation)
    .bind(spacing)
    .bind(user.id)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("保存联调预设「{name}」（{}）", labels(&st, &ids).await),
        name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("fleet_presets", Some(&p.id)));
    Ok((StatusCode::CREATED, Json(p)))
}

pub async fn delete_preset(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<String>,
) -> AppResult<StatusCode> {
    user.require(Perm::FleetSession)?;
    let name: Option<String> =
        sqlx::query_scalar("DELETE FROM fleet_presets WHERE id = $1 RETURNING name")
            .bind(&id)
            .fetch_optional(&st.db)
            .await?;
    let name = name.ok_or_else(|| AppError::not_found("联调预设不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除联调预设「{name}」"),
        &name,
        json!({}),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("fleet_presets", Some(&id)));
    Ok(StatusCode::NO_CONTENT)
}
