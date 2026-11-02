use std::{env, net::SocketAddr, str::FromStr};

use anyhow::{Context, Result};

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: SocketAddr,
    pub database_url: String,
    pub db_max_connections: u32,
    pub jwt_secret: String,
    pub jwt_ttl_secs: i64,
    /// 允许的前端来源；空 = 允许任意来源（仅开发）
    pub cors_origins: Vec<String>,
    /// 单机操控租约默认时长（Lease.dc.html：5:00）
    pub lease_default_secs: i64,
    /// 机器人多久没有任何消息判定为断联
    pub robot_timeout_ms: u64,
    /// 下发给机器人的遥测频率
    pub telemetry_hz: u32,
    /// 遥测入库抽样间隔
    pub telemetry_persist_ms: u64,
    /// 等待机器人回执的超时
    pub command_timeout_ms: u64,
    /// 首次启动时若没有任何成员则创建管理员
    pub bootstrap_admin: Option<(String, String)>,
}

fn var<T: FromStr>(key: &str, default: T) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    match env::var(key) {
        Ok(v) => v
            .parse()
            .map_err(|e| anyhow::anyhow!("环境变量 {key} 无效：{e}")),
        Err(_) => Ok(default),
    }
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let jwt_secret = env::var("JWT_SECRET").context("必须设置 JWT_SECRET")?;
        anyhow::ensure!(jwt_secret.len() >= 32, "JWT_SECRET 至少 32 个字符");

        let bootstrap_admin = match (env::var("BOOTSTRAP_ADMIN"), env::var("BOOTSTRAP_PASSWORD")) {
            (Ok(h), Ok(p)) if !h.is_empty() && !p.is_empty() => Some((h, p)),
            _ => None,
        };

        Ok(Self {
            bind_addr: var("BIND_ADDR", SocketAddr::from(([0, 0, 0, 0], 8080)))?,
            database_url: env::var("DATABASE_URL").context("必须设置 DATABASE_URL")?,
            db_max_connections: var("DB_MAX_CONNECTIONS", 20)?,
            jwt_secret,
            jwt_ttl_secs: var("JWT_TTL_SECS", 12 * 3600)?,
            cors_origins: env::var("CORS_ORIGINS")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect(),
            lease_default_secs: var("LEASE_DEFAULT_SECS", 300)?,
            robot_timeout_ms: var("ROBOT_TIMEOUT_MS", 1500)?,
            telemetry_hz: var("TELEMETRY_HZ", 10)?,
            telemetry_persist_ms: var("TELEMETRY_PERSIST_MS", 1000)?,
            command_timeout_ms: var("COMMAND_TIMEOUT_MS", 2000)?,
            bootstrap_admin,
        })
    }
}
