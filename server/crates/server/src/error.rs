use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

pub type AppResult<T> = Result<T, AppError>;

/// 统一错误：响应体 `{"error": {"code": "...", "message": "..."}}`。
/// `message` 会被前端原样显示，必须是给人看的中文。
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("登录已失效，请重新登录")]
    Unauthorized,
    #[error("账号或密码错误")]
    BadCredentials,
    #[error("请输入二次验证码")]
    TwoFactorRequired,
    #[error("二次验证码错误")]
    TwoFactorInvalid,
    #[error("{0}")]
    Forbidden(String),
    /// 403：邮箱注册的账号还没通过管理员审核
    #[error("账号正在等待管理员审核，通过后会邮件通知你")]
    PendingApproval,
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    /// 409，并带上冲突的设备，前端据此标红
    #[error("{message}")]
    ConflictDevices {
        message: String,
        device_ids: Vec<String>,
    },
    #[error("{0}")]
    TooManyRequests(String),
    #[error("设备 {0} 不在线")]
    RobotOffline(String),
    #[error("等待设备回执超时")]
    Timeout,
    #[error("系统处于急停状态")]
    EstopActive,
    #[error("{0}")]
    NotImplemented(String),
    /// 502：依赖的外部服务（智能体）不可用
    #[error("{0}")]
    Upstream(String),
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl AppError {
    pub fn code(&self) -> &'static str {
        self.status_and_code().1
    }

    fn status_and_code(&self) -> (StatusCode, &'static str) {
        match self {
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            AppError::Unauthorized | AppError::BadCredentials => {
                (StatusCode::UNAUTHORIZED, "unauthorized")
            }
            AppError::TwoFactorRequired => (StatusCode::UNAUTHORIZED, "two_factor_required"),
            AppError::TwoFactorInvalid => (StatusCode::UNAUTHORIZED, "two_factor_invalid"),
            AppError::Forbidden(_) => (StatusCode::FORBIDDEN, "forbidden"),
            AppError::PendingApproval => (StatusCode::FORBIDDEN, "pending_approval"),
            AppError::NotFound(_) => (StatusCode::NOT_FOUND, "not_found"),
            AppError::Conflict(_) | AppError::ConflictDevices { .. } => {
                (StatusCode::CONFLICT, "conflict")
            }
            AppError::TooManyRequests(_) => (StatusCode::TOO_MANY_REQUESTS, "too_many_requests"),
            AppError::RobotOffline(_) => (StatusCode::SERVICE_UNAVAILABLE, "robot_offline"),
            AppError::Timeout => (StatusCode::GATEWAY_TIMEOUT, "timeout"),
            AppError::EstopActive => (StatusCode::LOCKED, "estop_active"),
            AppError::NotImplemented(_) => (StatusCode::NOT_IMPLEMENTED, "not_implemented"),
            AppError::Upstream(_) => (StatusCode::BAD_GATEWAY, "upstream_unavailable"),
            AppError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
        }
    }

    pub fn forbidden(msg: impl Into<String>) -> Self {
        AppError::Forbidden(msg.into())
    }
    pub fn not_found(msg: impl Into<String>) -> Self {
        AppError::NotFound(msg.into())
    }
    pub fn bad_request(msg: impl Into<String>) -> Self {
        AppError::BadRequest(msg.into())
    }
    pub fn conflict(msg: impl Into<String>) -> Self {
        AppError::Conflict(msg.into())
    }
    pub fn not_implemented(what: &str) -> Self {
        AppError::NotImplemented(format!("{what}尚未实现"))
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        match &e {
            sqlx::Error::RowNotFound => AppError::NotFound("记录不存在".into()),
            sqlx::Error::Database(db) if db.is_unique_violation() => {
                AppError::Conflict("记录已存在".into())
            }
            sqlx::Error::Database(db) if db.is_foreign_key_violation() => {
                AppError::BadRequest("引用的记录不存在".into())
            }
            _ => AppError::Internal(e.into()),
        }
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code) = self.status_and_code();
        let message = match &self {
            AppError::Internal(e) => {
                tracing::error!(error = ?e, "internal error");
                "服务器内部错误".to_string()
            }
            other => other.to_string(),
        };
        let mut body = json!({ "error": { "code": code, "message": message } });
        if let AppError::ConflictDevices { device_ids, .. } = &self {
            body["error"]["device_ids"] = json!(device_ids);
        }
        (status, Json(body)).into_response()
    }
}
