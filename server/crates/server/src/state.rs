use std::sync::Arc;

use sqlx::PgPool;
use tokio::sync::mpsc;

use crate::{
    config::Config,
    realtime::{Hub, TelemetrySample},
    services::{
        alerting::AlertEngine, fleet_timeline::TimelinePlayer, leases::LeaseService,
        missions::MissionRunner, safety::SafetyService, sessions::LoginLimiter,
    },
};

/// 全局共享状态；所有字段都是廉价克隆的句柄。
#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub cfg: Arc<Config>,
    pub hub: Arc<Hub>,
    pub leases: Arc<LeaseService>,
    pub safety: Arc<SafetyService>,
    pub alerts: Arc<AlertEngine>,
    pub missions: Arc<MissionRunner>,
    pub fleet_player: Arc<TimelinePlayer>,
    pub telemetry_tx: mpsc::Sender<TelemetrySample>,
    pub login_limiter: Arc<LoginLimiter>,
}
