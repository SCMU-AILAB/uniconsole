//! 安全策略（Safety.dc.html）：全局急停、策略开关、电子围栏。
//! TODO：围栏下发到机器人端做本地判定（目前只存储）。

use axum::{
    Json,
    extract::{Path, Query, State},
    http::StatusCode,
};
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    models::{Zone, ZoneType},
    services::{audit, control, safety::Policies},
    state::AppState,
};

pub async fn get(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    let (estop_by, estop_at): (Option<String>, Option<chrono::DateTime<chrono::Utc>>) = sqlx::query_as(
        "SELECT m.name, s.estop_at FROM safety_state s LEFT JOIN members m ON m.id = s.estop_by WHERE s.id = 1",
    )
    .fetch_one(&st.db)
    .await?;
    let (zones,): (i64,) = sqlx::query_as("SELECT count(*) FROM zones WHERE enabled")
        .fetch_one(&st.db)
        .await?;
    Ok(Json(json!({
        "global_estop": st.safety.is_global_estop(),
        "estop_by": estop_by,
        "estop_at": estop_at,
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
    let p = st.safety.update_policies(&st.db, patch.clone()).await?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "修改安全策略",
        "安全策略",
        patch,
    )
    .await;
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
    /// [[x, y], ...]
    pub polygon: Option<Value>,
    pub rule: Option<String>,
    pub scope: Option<Value>,
    pub schedule: Option<String>,
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
         VALUES ($1, $2, $3, $4, COALESCE($5, ''), COALESCE($6, '{\"all\": true}'::jsonb),
                 COALESCE($7, '始终'), COALESCE($8, ''), COALESCE($9, TRUE))
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
        "新增电子围栏",
        &z.name,
        json!({ "type": z.zone_type }),
    )
    .await;
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
        "修改电子围栏",
        &z.name,
        json!({}),
    )
    .await;
    Ok(Json(z))
}

pub async fn delete_zone(
    State(st): State<AppState>,
    user: AuthUser,
    Path(id): Path<Uuid>,
) -> AppResult<StatusCode> {
    user.require(Perm::EditMaps)?;
    let name: Option<(String,)> = sqlx::query_as("DELETE FROM zones WHERE id = $1 RETURNING name")
        .bind(id)
        .fetch_optional(&st.db)
        .await?;
    let (name,) = name.ok_or_else(|| AppError::not_found("围栏不存在"))?;
    audit::record(
        &st,
        &user,
        audit::Kind::Config,
        "删除电子围栏",
        &name,
        json!({}),
    )
    .await;
    Ok(StatusCode::NO_CONTENT)
}
