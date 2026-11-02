//! REST API：所有路由挂在 `/api/v1` 下，JSON 字段为 snake_case。
//! 完整清单见 `server/docs/API.md`。

mod alerts;
mod auth;
mod devices;
mod fleet;
mod leases;
mod members;
mod missions;
mod safety;

use axum::{
    Json, Router,
    extract::State,
    routing::{get, patch, post},
};
use serde_json::{Value, json};

use crate::{
    protocol::PROTOCOL_VERSION,
    realtime::{client_ws, robot_ws},
    state::AppState,
};

pub fn router(state: AppState) -> Router {
    let api = Router::new()
        // 系统
        .route("/system/info", get(system_info))
        // 认证与成员（Roles.dc.html）
        .route("/auth/login", post(auth::login))
        .route("/auth/me", get(auth::me))
        .route("/members", get(members::list).post(members::create))
        .route(
            "/members/{id}",
            patch(members::update).delete(members::remove),
        )
        .route(
            "/members/{id}/devices",
            get(members::grants).put(members::set_grants),
        )
        .route("/audit", get(members::audit))
        // 设备（Main / Control / Sensors / Maintenance）
        .route("/devices", get(devices::list).post(devices::create))
        .route(
            "/devices/{id}",
            get(devices::get)
                .patch(devices::update)
                .delete(devices::remove),
        )
        .route("/devices/{id}/token", post(devices::rotate_token))
        .route("/devices/{id}/telemetry", get(devices::telemetry_history))
        .route(
            "/devices/{id}/telemetry/latest",
            get(devices::telemetry_latest),
        )
        .route(
            "/devices/{id}/commands",
            get(devices::command_log).post(devices::send_command),
        )
        .route("/devices/{id}/estop", post(devices::estop))
        // 控制权（Lease.dc.html）
        .route("/leases", get(leases::overview))
        .route(
            "/devices/{id}/lease",
            post(leases::acquire).delete(leases::release),
        )
        .route("/devices/{id}/lease/renew", post(leases::renew))
        .route("/devices/{id}/lease/transfer", post(leases::transfer))
        .route("/devices/{id}/lease/requests", get(leases::requests))
        .route("/lease-requests/{id}/approve", post(leases::approve))
        .route("/lease-requests/{id}/deny", post(leases::deny))
        // 多机联调（Fleet.dc.html）
        .route("/fleet-sessions", get(fleet::list).post(fleet::create))
        .route(
            "/fleet-sessions/{id}",
            get(fleet::get).patch(fleet::update).delete(fleet::remove),
        )
        .route("/fleet-sessions/{id}/start", post(fleet::start))
        .route("/fleet-sessions/{id}/stop", post(fleet::stop))
        .route("/fleet-sessions/{id}/commands", post(fleet::command))
        // 地图与任务（Missions.dc.html）
        .route("/missions", get(missions::list).post(missions::create))
        .route(
            "/missions/{id}",
            get(missions::get)
                .patch(missions::update)
                .delete(missions::remove),
        )
        // 安全策略（Safety.dc.html）
        .route("/safety", get(safety::get))
        .route("/safety/policies", patch(safety::update_policies))
        .route("/safety/estop", post(safety::global_estop))
        .route("/zones", get(safety::list_zones).post(safety::create_zone))
        .route(
            "/zones/{id}",
            patch(safety::update_zone).delete(safety::delete_zone),
        )
        // 告警（Alerts.dc.html）
        .route("/alerts", get(alerts::list))
        .route("/alerts/{id}", get(alerts::get).patch(alerts::update))
        .route("/alerts/{id}/events", post(alerts::add_note))
        .route(
            "/alert-rules",
            get(alerts::list_rules).post(alerts::create_rule),
        )
        .route(
            "/alert-rules/{id}",
            patch(alerts::update_rule).delete(alerts::delete_rule),
        )
        // 实时通道
        .route("/ws", get(client_ws))
        .route("/robot/ws", get(robot_ws));

    Router::new()
        .route("/healthz", get(healthz))
        .nest("/api/v1", api)
        .with_state(state)
}

async fn healthz(State(st): State<AppState>) -> Json<Value> {
    let db_ok = sqlx::query("SELECT 1").execute(&st.db).await.is_ok();
    Json(json!({ "ok": db_ok, "db": db_ok }))
}

async fn system_info(State(st): State<AppState>) -> Json<Value> {
    Json(json!({
        "name": "uniconsole-server",
        "version": env!("CARGO_PKG_VERSION"),
        "protocol": PROTOCOL_VERSION,
        "online_devices": st.hub.online_ids().len(),
        "global_estop": st.safety.is_global_estop(),
    }))
}
