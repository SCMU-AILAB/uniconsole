//! 智能体（前端交接文档 §12）。决定做成**独立服务**（复用 Go2Agent 的规划能力），服务端只负责：
//!
//! 1. **鉴权与转发**：`/api/v1/agent/{路径}` 原样（方法、查询串、请求体）转发到 `AGENT_URL/{路径}`，
//!    附加请求头：
//!    - `X-UniConsole-Member-Id` / `X-UniConsole-Member-Name` / `X-UniConsole-Role`：当前成员；
//!    - `X-UniConsole-Token: <AGENT_TOKEN>`：证明请求来自服务端；
//!    - `Authorization`：成员自己的令牌原样带过去，智能体执行计划时用它回调本服务的 REST
//!      （`POST /devices/{id}/commands` 等），控制权、急停、权限检查都和成员亲自操作一样。
//!
//!    响应的状态码、`Content-Type` 和 body 原样返回。没配置 `AGENT_URL` 时 501。
//! 2. **流式回复**：智能体把 `agent_message` / `agent_delta` / `agent_plan` 推给
//!    `POST /api/v1/internal/agent/events`（`Authorization: Bearer <AGENT_TOKEN>`），
//!    服务端经 `/api/v1/ws` 只发给对应成员。

use std::time::Duration;

use axum::{
    Json,
    body::{Body, Bytes},
    extract::{Path, State},
    http::{HeaderMap, Method, StatusCode, Uri, header},
    response::Response,
};
use serde::Deserialize;
use serde_json::Value;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    protocol::ServerEvent,
    state::AppState,
    util::constant_time_eq,
};

/// 智能体服务的单次请求超时（规划可能较慢；流式回复走 WS，不受此限制）
const AGENT_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_BODY: usize = 1024 * 1024;

fn role_name(user: &AuthUser) -> String {
    serde_json::to_value(user.role)
        .ok()
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default()
}

/// ANY /agent/{*rest}
pub async fn proxy(
    State(st): State<AppState>,
    user: AuthUser,
    Path(rest): Path<String>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> AppResult<Response> {
    let Some(base) = &st.cfg.agent_url else {
        return Err(AppError::not_implemented("智能体服务"));
    };
    if body.len() > MAX_BODY {
        return Err(AppError::bad_request("请求体过大"));
    }
    if rest.split('/').any(|seg| seg == ".." || seg == ".") {
        return Err(AppError::bad_request("路径不合法"));
    }
    let mut url = format!("{base}/{rest}");
    if let Some(q) = uri.query() {
        url.push('?');
        url.push_str(q);
    }
    let method = reqwest::Method::from_bytes(method.as_str().as_bytes())
        .map_err(|_| AppError::bad_request("不支持的请求方法"))?;

    let mut req = st
        .http
        .request(method, &url)
        .timeout(AGENT_TIMEOUT)
        .header("X-UniConsole-Member-Id", user.id.to_string())
        // 名字可能含中文：HTTP 头只放 ASCII，按百分号编码
        .header("X-UniConsole-Member-Name", percent_encode(&user.name))
        .header("X-UniConsole-Role", role_name(&user))
        .body(body);
    if let Some(t) = &st.cfg.agent_token {
        req = req.header("X-UniConsole-Token", t);
    }
    for h in [header::AUTHORIZATION, header::CONTENT_TYPE, header::ACCEPT] {
        if let Some(v) = headers.get(&h) {
            req = req.header(h.as_str(), v.as_bytes());
        }
    }

    let resp = req.send().await.map_err(|e| {
        tracing::warn!(error = %e, url, "智能体服务请求失败");
        if e.is_timeout() {
            AppError::Timeout
        } else {
            AppError::Upstream("智能体服务暂时不可用".into())
        }
    })?;
    let status = StatusCode::from_u16(resp.status().as_u16()).unwrap_or(StatusCode::BAD_GATEWAY);
    let content_type = resp.headers().get(reqwest::header::CONTENT_TYPE).cloned();
    let bytes = resp
        .bytes()
        .await
        .map_err(|_| AppError::Upstream("智能体服务响应中断".into()))?;
    let mut out = Response::builder().status(status);
    if let Some(ct) = content_type {
        out = out.header(header::CONTENT_TYPE, ct.as_bytes());
    }
    out.body(Body::from(bytes))
        .map_err(|e| AppError::Internal(e.into()))
}

fn percent_encode(s: &str) -> String {
    s.bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect()
}

#[derive(Deserialize)]
pub struct AgentEvent {
    pub member_id: Uuid,
    /// `{type: agent_message | agent_delta | agent_plan, conversation_id, …}`
    pub event: Value,
}

/// POST /internal/agent/events：智能体服务推给成员的流式消息（共享密钥鉴权）
pub async fn push_event(
    State(st): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<AgentEvent>,
) -> AppResult<StatusCode> {
    let Some(expected) = &st.cfg.agent_token else {
        return Err(AppError::not_implemented("智能体服务"));
    };
    let given = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    if !given.is_some_and(|g| constant_time_eq(g.as_bytes(), expected.as_bytes())) {
        return Err(AppError::Unauthorized);
    }
    let ok_type = req.event["type"]
        .as_str()
        .is_some_and(|t| matches!(t, "agent_message" | "agent_delta" | "agent_plan"));
    if !ok_type {
        return Err(AppError::bad_request(
            "event.type 只能是 agent_message、agent_delta、agent_plan",
        ));
    }
    st.hub.publish(ServerEvent::Forward {
        member_id: req.member_id,
        payload: req.event,
    });
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helpers() {
        assert_eq!(percent_encode("Kanade 林"), "Kanade%20%E6%9E%97");
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
    }
}
