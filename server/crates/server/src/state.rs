use std::sync::Arc;

use sqlx::PgPool;
use tokio::sync::mpsc;

use crate::{
    config::Config,
    realtime::{Hub, TelemetrySample},
    services::{alerting::AlertEngine, leases::LeaseService, safety::SafetyService},
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
    pub telemetry_tx: mpsc::Sender<TelemetrySample>,
}
