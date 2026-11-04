//! 安全策略（Safety.dc.html）：全局急停、急停演练、策略开关、电子围栏。
//! TODO：围栏下发到机器人端做本地判定（目前只存储）。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use chrono::{DateTime, Utc};
use futures::future::join_all;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{Zone, ZoneType},
    protocol::{Command, ServerEvent},
    services::{
        audit,
        control::{self, Actor},
        safety::Policies,
    },
    state::AppState,
};

pub async fn get(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    let (estop_by, estop_at, last_drill_at): (
        Option<String>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
    ) = sqlx::query_as(
        "SELECT m.name, s.estop_at, s.last_drill_at
         FROM safety_state s LEFT JOIN members m ON m.id = s.estop_by WHERE s.id = 1",
    )
    .fetch_one(&st.db)
    .await?;
    let zones: i64 = sqlx::query_scalar("SELECT count(*) FROM zones WHERE enabled")
        .fetch_one(&st.db)
        .await?;
    let global = st.safety.is_global_estop();
    Ok(Json(json!({
        "global_estop": global,
        "estop_by": if global { estop_by } else { None },
        "estop_at": if global { estop_at } else { None },
        "last_drill_at": last_drill_at,
        "active_zones": zones,
        "policies": st.safety.policies(),
    })))
}

pub async fn update_policies(
    State(st): State<AppState>,
    user: AuthUser,
    Json(patch): Json<Value>,
) -> AppResult<Json<Policies>> {
    user.require(Perm::EditMaps)?;
    let before = st.safety.policies();
    let p = st.safety.update_policies(&st.db, patch.clone()).await?;
    let keys: Vec<&str> = patch
        .as_object()
        .map(|m| m.keys().map(String::as_str).collect())
        .unwrap_or_default();
    if p != before {
        audit::record(
            &st,
            &user,
            audit::Kind::Config,
            format!("修改安全策略（{}）", keys.join("、")),
            "安全策略",
            patch,
        )
        .await;
        st.hub
            .publish(ServerEvent::changed("safety", None::<String>));
    }
    Ok(Json(p))
}

#[derive(Deserialize)]
pub struct EstopReq {
    pub active: bool,
}

pub async fn global_estop(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<EstopReq>,
) -> AppResult<Json<Value>> {
    control::set_global_estop(&st, &user, req.active).await?;
    Ok(Json(json!({ "global_estop": req.active })))
}

/// POST /safety/drill：急停演练。给每台在线设备下发「演练急停」并测量回执耗时，设备不会真的停机。
pub async fn drill(State(st): State<AppState>, user: AuthUser) -> AppResult<Json<Value>> {
    user.require(Perm::EditMaps)?;
    let ids = st.hub.online_ids();
    let futs = ids.iter().map(|d| {
        let (st, user, d) = (st.clone(), user.clone(), d.clone());
        async move {
            let r = control::execute(
                &st,
                Actor::User(&user),
                &d,
                Command::Estop { drill: true },
                true,
            )
            .await;
            match r {
                Ok(res) => {
                    json!({ "device_id": d, "ok": res.ok == Some(true), "ms": res.latency_ms,
                                   "error": res.error, "message": res.message })
                }
                Err(e) => json!({ "device_id": d, "ok": false, "ms": null,
                                  "error": e.code(), "message": e.to_string() }),
            }
        }
    });
    let responses = join_all(futs).await;
    let at: DateTime<Utc> = sqlx::query_scalar(
        "UPDATE safety_state SET last_drill_at = now() WHERE id = 1 RETURNING last_drill_at",
    )
    .fetch_one(&st.db)
    .await?;
    let ok = responses.iter().filter(|r| r["ok"] == true).count();
    let slowest = responses.iter().filter_map(|r| r["ms"].as_u64()).max();
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        match slowest {
            Some(ms) => format!(
                "急停演练：{ok}/{} 台设备响应，最慢 {ms} ms",
                responses.len()
            ),
            None => format!("急停演练：{} 台在线设备，无响应", responses.len()),
        },
        "全部设备",
        json!({ "responses": responses }),
    )
    .await;
    st.hub
        .publish(ServerEvent::changed("safety", None::<String>));
    Ok(Json(json!({ "at": at, "responses": responses })))
}

// ───────── 围栏 ─────────

fn zones_changed(st: &AppState, id: Uuid) {
    st.hub.publish(ServerEvent::changed("zones", Some(id)));
}

#[derive(Deserialize)]
pub struct ZoneQuery {
    pub map_id: Option<String>,
}

pub async fn list_zones(
    State(st): State<AppState>,
    _user: AuthUser,
    Query(q): Query<ZoneQuery>,
) -> AppResult<Json<Vec<Zone>>> {
    Ok(Json(
        sqlx::query_as(
            "SELECT * FROM zones WHERE ($1::text IS NULL OR map_id = $1) ORDER BY created_at",
        )
        .bind(q.map_id)
        .fetch_all(&st.db)
        .await?,
    ))
}

#[derive(Deserialize)]
pub struct UpsertZone {
    pub map_id: Option<String>,
    pub name: Option<String>,
    pub zone_type: Option<ZoneType>,
    /// [[x, y], ...]，米，地图坐标系
    pub polygon: Option<Value>,
    /// 显示文本，如「限速 0.3 m/s」
    pub rule: Option<String>,
    /// 显示文本，如「全部设备」
    pub scope: Option<String>,
    /// 显示文本，如「全天」「每天 09:00–18:00」
    pub schedule: Option<String>,
    /// 显示文本，如「停止并告警」
    pub action: Option<String>,
    pub enabled: Option<bool>,
}

fn validate_polygon(p: &Option<Value>) -> AppResult<()> {
    if let Some(p) = p {
        let ok = p.as_array().is_some_and(|pts| {
            pts.len() >= 3
                && pts.iter().all(|pt| {
                    pt.as_array()
                        .is_some_and(|xy| xy.len() == 2 && xy.iter().all(Value::is_number))
                })
        });
        if !ok {
            return Err(AppError::bad_request("polygon 必须是至少 3 个 [x, y] 点"));
        }
    }
    Ok(())
}

fn zone_type_label(t: ZoneType) -> &'static str {
    match t {
        ZoneType::Ban => "禁行区",
        ZoneType::Slow => "限速区",
        ZoneType::Whitelist => "白名单区",
        ZoneType::Wall => "虚拟墙",
    }
}

pub async fn create_zone(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<UpsertZone>,
) -> AppResult<(StatusCode, Json<Zone>)> {
    user.require(Perm::EditMaps)?;
    validate_polygon(&req.polygon)?;
    let (Some(map_id), Some(name), Some(zone_type), Some(polygon)) =
        (req.map_id, req.name, req.zone_type, req.polygon)
    else {
        return Err(AppError::bad_request(
            "map_id、name、zone_type、polygon 必填",
        ));
    };
    let z: Zone = sqlx::query_as(
        "INSERT INTO zones (map_id, name, zone_type, polygon, rule, scope, schedule, action, enabled)
         VALUES ($1, $2, $3, $4, COALESCE($5, ''), COALESCE($6, '全部设备'),
                 COALESCE($7, '全天'), COALESCE($8, ''), COALESCE($9, TRUE))
         RETURNING *",
    )
    .bind(map_id)
    .bind(name)
    .bind(zone_type)
    .bind(polygon)
    .bind(req.rule)
    .bind(req.scope)
    .bind(req.schedule)
    .bind(req.action)
    .bind(req.enabled)
    .fetch_one(&st.db)
    .await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("新增{}「{}」", zone_type_label(z.zone_type), z.name),
        &z.name,
        json!({ "map_id": z.map_id }),
    )
    .await;
    zones_changed(&st, z.id);
    Ok((StatusCode::CREATED, Json(z)))
}

pub async fn update_zone(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
    Json(req): Json<UpsertZone>,
) -> AppResult<Json<Zone>> {
    user.require(Perm::EditMaps)?;
    validate_polygon(&req.polygon)?;
    let z: Zone = sqlx::query_as(
        "UPDATE zones SET map_id = COALESCE($2, map_id), name = COALESCE($3, name),
         zone_type = COALESCE($4, zone_type), polygon = COALESCE($5, polygon), rule = COALESCE($6, rule),
         scope = COALESCE($7, scope), schedule = COALESCE($8, schedule), action = COALESCE($9, action),
         enabled = COALESCE($10, enabled), updated_at = now()
         WHERE id = $1 RETURNING *",
    )
    .bind(id)
    .bind(req.map_id)
    .bind(req.name)
    .bind(req.zone_type)
    .bind(req.polygon)
    .bind(req.rule)
    .bind(req.scope)
    .bind(req.schedule)
    .bind(req.action)
    .bind(req.enabled)
    .fetch_optional(&st.db)
    .await?
    .ok_or_else(|| AppError::not_found("围栏不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("修改{}「{}」", zone_type_label(z.zone_type), z.name),
        &z.name,
        json!({}),
    )
    .await;
    zones_changed(&st, id);
    Ok(Json(z))
}

pub async fn delete_zone(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let row: Option<(String, ZoneType)> =
        sqlx::query_as("DELETE FROM zones WHERE id = $1 RETURNING name, zone_type")
            .bind(id)
            .fetch_optional(&st.db)
            .await?;
    let (name, t) = row.ok_or_else(|| AppError::not_found("围栏不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        format!("删除{}「{name}」", zone_type_label(t)),
        &name,
        json!({}),
    )
    .await;
    zones_changed(&st, id);
    Ok(StatusCode::NO_CONTENT)
}
