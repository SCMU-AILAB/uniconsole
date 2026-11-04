//! REST API：所有路由挂在 `/api/v1` 下，JSON 字段为 snake_case。
//! 完整清单见 `server/docs/API.md`。

mod alerts;
mod auth;
mod devices;
mod fleet;
mod leases;
mod me;
mod members;
mod missions;
mod safety;

use axum::{
    Json, Router,
    extract::State,
    routing::{delete, get, patch, post},
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
        // 认证
        .route("/auth/login", post(auth::login))
        .route("/auth/logout", post(auth::logout))
        .route("/auth/me", get(auth::me))
        .route("/auth/password", post(auth::change_password))
        .route("/auth/invites/{token}", get(auth::invite_info))
        .route("/auth/invites/{token}/accept", post(auth::accept_invite))
        // 当前账户（设置页）
        .route("/me/sessions", get(me::list_sessions))
        .route("/me/sessions/{id}", delete(me::revoke_session))
        .route("/me/tokens", get(me::list_tokens).post(me::create_token))
        .route("/me/tokens/{id}", delete(me::revoke_token))
        .route("/me/2fa/enable", post(me::enable_2fa))
        .route("/me/2fa/verify", post(me::verify_2fa))
        .route("/me/2fa/disable", post(me::disable_2fa))
        .route(
            "/me/preferences",
            get(me::get_preferences).put(me::put_preferences),
        )
        .route("/me/push-tokens", post(me::add_push_token))
        // 成员与权限（Roles.dc.html）
        .route("/members", get(members::list).post(members::create))
        .route(
            "/members/{id}",
            get(members::get)
                .patch(members::update)
                .delete(members::remove),
        )
        .route("/members/{id}/invite", post(members::reinvite))
        .route(
            "/members/{id}/devices",
            get(members::grants).put(members::put_grants),
        )
        .route("/audit", get(members::audit))
        .route("/audit.csv", get(members::audit_csv))
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
        .route("/devices/{id}/events", get(devices::events))
        .route("/devices/{id}/sensors", get(devices::sensors))
        .route(
            "/device-groups",
            get(devices::list_groups).post(devices::create_group),
        )
        .route(
            "/device-groups/{id}",
            patch(devices::update_group).delete(devices::delete_group),
        )
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
        .route(
            "/fleet-presets",
            get(fleet::list_presets).post(fleet::create_preset),
        )
        .route("/fleet-presets/{id}", delete(fleet::delete_preset))
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
        .route("/safety/drill", post(safety::drill))
        .route("/zones", get(safety::list_zones).post(safety::create_zone))
        .route(
            "/zones/{id}",
            patch(safety::update_zone).delete(safety::delete_zone),
        )
        // 告警（Alerts.dc.html）
        .route("/alerts", get(alerts::list))
        .route("/alerts/{id}", get(alerts::get).patch(alerts::update))
        .route("/alerts/{id}/events", post(alerts::add_note))
        .route("/alerts/{id}/remote-down", post(alerts::remote_down))
        .route("/alerts/{id}/history", get(alerts::history))
        .route(
            "/alert-channels",
            get(alerts::get_channels).put(alerts::put_channels),
        )
        .route(
            "/on-call",
            get(alerts::get_on_call).put(alerts::put_on_call),
        )
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
