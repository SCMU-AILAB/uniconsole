//! 应用装配：数据库、迁移、共享状态、后台任务、路由与中间件、HTTP 服务。

use std::{sync::Arc, time::Duration};

use anyhow::Context;
use axum::{
    Router,
    http::{HeaderValue, Method, header},
};
use serde_json::json;
use sqlx::{PgPool, postgres::PgPoolOptions};
use tower_http::{
    cors::{AllowOrigin, Any, CorsLayer},
    trace::TraceLayer,
};

use crate::{
    auth,
    config::Config,
    models::Role,
    protocol::Command,
    realtime::{Hub, spawn_telemetry_writer},
    routes,
    services::{
        alerting::AlertEngine,
        audit,
        control::{self, Actor},
        leases::LeaseService,
        safety::SafetyService,
        sessions::LoginLimiter,
    },
    state::AppState,
};

/// 迁移文件位于 workspace 根目录 `migrations/`
pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("../../migrations");

/// 连接数据库、执行迁移、创建初始管理员，并加载各服务的内存状态
pub async fn build_state(cfg: Arc<Config>) -> anyhow::Result<AppState> {
    let db = PgPoolOptions::new()
        .max_connections(cfg.db_max_connections)
        .acquire_timeout(Duration::from_secs(5))
        .connect(&cfg.database_url)
        .await
        .context("连接数据库失败")?;
    MIGRATOR.run(&db).await.context("数据库迁移失败")?;
    bootstrap_admin(&db, &cfg).await?;

    // 启动时所有设备都视为离线，等待机器人重新连接
    sqlx::query("UPDATE devices SET status = 'offline' WHERE status <> 'offline'")
        .execute(&db)
        .await?;

    let hub = Arc::new(Hub::new());
    Ok(AppState {
        leases: Arc::new(
            LeaseService::load(db.clone(), hub.clone(), cfg.lease_default_secs).await?,
        ),
        safety: Arc::new(SafetyService::load(&db).await?),
        alerts: Arc::new(AlertEngine::load(&db).await?),
        telemetry_tx: spawn_telemetry_writer(db.clone()),
        login_limiter: Arc::new(LoginLimiter::default()),
        hub,
        cfg,
        db,
    })
}

/// 完整的 HTTP 应用（路由 + CORS + 请求日志）
pub fn app(state: AppState) -> Router {
    let cors = cors(&state.cfg);
    routes::router(state)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
}

/// 启动服务直到收到 Ctrl-C / SIGTERM
pub async fn run(cfg: Config) -> anyhow::Result<()> {
    let cfg = Arc::new(cfg);
    let state = build_state(cfg.clone()).await?;
    tokio::spawn(lease_sweeper(state.clone()));

    let listener = tokio::net::TcpListener::bind(cfg.bind_addr).await?;
    tracing::info!("UniConsole 服务已启动：http://{}", cfg.bind_addr);
    axum::serve(
        listener,
        app(state).into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await?;
    Ok(())
}

fn cors(cfg: &Config) -> CorsLayer {
    let layer = CorsLayer::new()
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
        ])
        .allow_headers([
            header::AUTHORIZATION,
            header::CONTENT_TYPE,
            "x-client".parse().unwrap(),
        ]);
    if cfg.cors_origins.is_empty() {
        tracing::warn!("CORS_ORIGINS 未设置，允许任意来源（仅限开发环境）");
        layer.allow_origin(Any)
    } else {
        let origins: Vec<HeaderValue> = cfg
            .cors_origins
            .iter()
            .filter_map(|o| o.parse().ok())
            .collect();
        layer.allow_origin(AllowOrigin::list(origins))
    }
}

/// 首次启动且没有任何成员时，按环境变量创建平台管理员
async fn bootstrap_admin(db: &PgPool, cfg: &Config) -> anyhow::Result<()> {
    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM members")
        .fetch_one(db)
        .await?;
    if count > 0 {
        return Ok(());
    }
    let Some((handle, password)) = &cfg.bootstrap_admin else {
        tracing::warn!("数据库中没有任何成员，请设置 BOOTSTRAP_ADMIN / BOOTSTRAP_PASSWORD 后重启");
        return Ok(());
    };
    let hash = auth::hash_password_async(password.clone()).await?;
    sqlx::query("INSERT INTO members (handle, name, password_hash, role, color) VALUES ($1, $1, $2, $3, '#5856D6')")
        .bind(handle)
        .bind(hash)
        .bind(Role::Admin)
        .execute(db)
        .await?;
    tracing::info!(handle, "已创建初始管理员");
    Ok(())
}

/// 每秒清理过期租约；按策略对设备下发停止（Safety.dc.html「控制租约过期：停止并释放」）
async fn lease_sweeper(st: AppState) {
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tick.tick().await;
        let expired = match st.leases.sweep_expired().await {
            Ok(e) => e,
            Err(e) => {
                tracing::error!(error = %e, "清理过期租约失败");
                continue;
            }
        };
        let stop = st.safety.policies().lease_expire_action.starts_with("stop");
        for lease in expired {
            if stop {
                let _ = control::execute(
                    &st,
                    Actor::System("租约过期"),
                    &lease.device_id,
                    Command::Stop,
                    false,
                )
                .await;
            }
            audit::record_system(
                &st,
                audit::Kind::System,
                "控制权过期释放",
                &lease.device_id,
                json!({ "holder": lease.holder_id }),
            )
            .await;
        }
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        let _ = tokio::signal::ctrl_c().await;
    };
    #[cfg(unix)]
    let term = async {
        if let Ok(mut s) = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        {
            s.recv().await;
        }
    };
    #[cfg(not(unix))]
    let term = std::future::pending::<()>();
    tokio::select! { _ = ctrl_c => {}, _ = term => {} }
    tracing::info!("正在关闭服务…");
}
