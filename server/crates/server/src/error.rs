use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

pub type AppResult<T> = Result<T, AppError>;

/// 统一错误：响应体 `{"error": {"code": "...", "message": "..."}}`
#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{0}")]
    BadRequest(String),
    #[error("未登录或令牌无效")]
    Unauthorized,
    #[error("{0}")]
    Forbidden(String),
    #[error("{0}")]
    NotFound(String),
    #[error("{0}")]
    Conflict(String),
    #[error("设备 {0} 不在线")]
    RobotOffline(String),
    #[error("等待设备回执超时")]
    Timeout,
    #[error("系统处于急停状态")]
    EstopActive,
    #[error(transparent)]
    Internal(#[from] anyhow::Error),
}

impl AppError {
    fn status_and_code(&self) -> (StatusCode, &'static str) {
        match self {
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            AppError::Forbidden(_) => (StatusCode::FORBIDDEN, "forbidden"),
            AppError::NotFound(_) => (StatusCode::NOT_FOUND, "not_found"),
            AppError::Conflict(_) => (StatusCode::CONFLICT, "conflict"),
            AppError::RobotOffline(_) => (StatusCode::SERVICE_UNAVAILABLE, "robot_offline"),
            AppError::Timeout => (StatusCode::GATEWAY_TIMEOUT, "timeout"),
            AppError::EstopActive => (StatusCode::LOCKED, "estop_active"),
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
        (
            status,
            Json(json!({ "error": { "code": code, "message": message } })),
        )
            .into_response()
    }
}
