//! UniConsole 后端服务。
//!
//! workspace 中的其它 crate：
//! - `uniconsole-domain`：领域模型（这里以 `crate::models` 引用）
//! - `uniconsole-protocol`：WebSocket 协议（`crate::protocol`）
//! - `uniconsole-auth`：JWT / 密码 / 权限矩阵（`crate::auth`，并补上 HTTP 提取器 `AuthUser`）

pub mod app;
pub mod config;
pub mod error;
mod extract;
pub mod realtime;
pub mod routes;
pub mod services;
pub mod state;
pub mod util;

pub use uniconsole_domain as models;
pub use uniconsole_protocol as protocol;

pub mod auth {
    pub use crate::extract::AuthUser;
    pub use uniconsole_auth::*;
}
