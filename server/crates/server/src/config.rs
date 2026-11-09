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
    /// 机器人多久没有任何消息判定为断联
    pub robot_timeout_ms: u64,
    /// 下发给机器人的遥测频率
    pub telemetry_hz: u32,
    /// 遥测入库抽样间隔
    pub telemetry_persist_ms: u64,
    /// 等待机器人回执的超时
    pub command_timeout_ms: u64,
    /// 邀请链接前缀，后面拼一次性令牌（前端注册了 uniconsole:// 深链）
    pub invite_url_base: String,
    /// 邀请链接有效期
    pub invite_ttl_secs: i64,
    /// 个人 API 令牌默认有效期
    pub api_token_ttl_days: i64,
    /// WebRTC ICE 服务器（GET /webrtc/ice-servers），JSON 数组
    pub ice_servers: serde_json::Value,
    /// 限时 TURN 凭据（coturn use-auth-secret）：TURN_URLS 逗号分隔，TURN_SECRET 为共享密钥
    pub turn_urls: Vec<String>,
    pub turn_secret: Option<String>,
    pub turn_ttl_secs: i64,
    /// 任务单个点位的导航超时（机器人到达后才回执）
    pub mission_step_timeout_secs: u64,
    /// 任务排期字符串里的时刻按哪个时区解释（相对 UTC 的分钟数，默认 +480 北京时间）
    pub schedule_tz_offset_minutes: i32,
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
            robot_timeout_ms: var("ROBOT_TIMEOUT_MS", 1500)?,
            telemetry_hz: var("TELEMETRY_HZ", 10)?,
            telemetry_persist_ms: var("TELEMETRY_PERSIST_MS", 1000)?,
            command_timeout_ms: var("COMMAND_TIMEOUT_MS", 2000)?,
            invite_url_base: env::var("INVITE_URL_BASE")
                .unwrap_or_else(|_| "uniconsole://invite/".into()),
            invite_ttl_secs: var("INVITE_TTL_SECS", 7 * 24 * 3600)?,
            api_token_ttl_days: var("API_TOKEN_TTL_DAYS", 365)?,
            ice_servers: match env::var("ICE_SERVERS") {
                Ok(v) if !v.trim().is_empty() => {
                    serde_json::from_str(&v).context("ICE_SERVERS 必须是 JSON 数组")?
                }
                _ => serde_json::json!([]),
            },
            turn_urls: env::var("TURN_URLS")
                .unwrap_or_default()
                .split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect(),
            turn_secret: env::var("TURN_SECRET").ok().filter(|s| !s.is_empty()),
            turn_ttl_secs: var("TURN_TTL_SECS", 12 * 3600)?,
            mission_step_timeout_secs: var("MISSION_STEP_TIMEOUT_SECS", 600)?,
            schedule_tz_offset_minutes: var("SCHEDULE_TZ_OFFSET_MINUTES", 480)?,
            bootstrap_admin,
        })
    }
}
