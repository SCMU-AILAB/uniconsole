//! 指令下发的唯一入口：急停检查 → 控制权检查 → 安全限幅 → 下发 → 记录。
//!
//! HANDOFF §8 交互规则在服务端的落实：
//! 1. 急停永远可达：Stop / Estop 不需要控制权，任何角色都能触发；
//!    急停期间所有运动指令被拒绝（423 estop_active）。
//! 2. 控制权：运动指令必须由租约持有者发出。
//! 4. 松开 300 ms 自动停止：由机器人端看门狗保证；前端断线时服务端补发 Stop。

use std::time::Duration;

use serde::Serialize;
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::Role,
    protocol::{Command, ServerEvent},
    services::audit,
    state::AppState,
};

#[derive(Clone, Copy)]
pub enum Actor<'a> {
    User(&'a AuthUser),
    /// 系统自动动作（告警自动处理、租约过期、断线保护）
    System(&'a str),
}

impl Actor<'_> {
    fn id(&self) -> Option<Uuid> {
        match self {
            Actor::User(u) => Some(u.id),
            Actor::System(_) => None,
        }
    }
    fn name(&self) -> &str {
        match self {
            Actor::User(u) => &u.name,
            Actor::System(s) => s,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct CommandResult {
    pub cmd_id: Uuid,
    /// None = 未等待回执（高频 move）
    pub ok: Option<bool>,
    pub error: Option<String>,
}

pub async fn execute(
    st: &AppState,
    actor: Actor<'_>,
    device_id: &str,
    mut cmd: Command,
    wait_ack: bool,
) -> AppResult<CommandResult> {
    match &cmd {
        Command::Estop => {
            st.hub.set_device_estop(device_id, true);
            st.hub.publish(ServerEvent::Estop {
                device_id: Some(device_id.to_owned()),
                active: true,
                by: actor.name().to_owned(),
            });
        }
        Command::ReleaseEstop => {
            if st.safety.is_global_estop() {
                return Err(AppError::EstopActive);
            }
            if let Actor::User(u) = actor {
                let manager = matches!(u.role, Role::Admin | Role::Owner);
                let needs_manager = st.safety.policies().estop_release_requires_manager;
                if needs_manager && !manager {
                    return Err(AppError::forbidden("解除急停需要管理者确认"));
                }
                if !manager && !st.leases.can_drive(device_id, u.id).await? {
                    return Err(AppError::forbidden("只有控制者或管理者可以解除急停"));
                }
            }
            st.hub.set_device_estop(device_id, false);
            st.hub.publish(ServerEvent::Estop {
                device_id: Some(device_id.to_owned()),
                active: false,
                by: actor.name().to_owned(),
            });
        }
        c if c.is_motion() => {
            if st.safety.is_global_estop() || st.hub.is_device_estopped(device_id) {
                return Err(AppError::EstopActive);
            }
            if let Actor::User(u) = actor
                && !st.leases.can_drive(device_id, u.id).await?
            {
                return Err(AppError::forbidden("你没有该设备的控制权（只读）"));
            }
            let p = st.safety.policies();
            cmd.clamp(p.max_speed_mps, p.max_yaw_rate);
        }
        _ => {}
    }

    let log_it = !matches!(cmd, Command::Move { .. });
    let wait = wait_ack.then(|| Duration::from_millis(st.cfg.command_timeout_ms));
    let logged_cmd = log_it.then(|| cmd.clone());

    let result = st.hub.dispatch(device_id, cmd, wait).await;

    if let Some(c) = logged_cmd {
        let (cmd_id, ok, err) = match &result {
            Ok((id, ack)) => (
                *id,
                ack.as_ref().map(|a| a.ok),
                ack.as_ref().and_then(|a| a.error.clone()),
            ),
            Err(e) => (Uuid::new_v4(), Some(false), Some(e.to_string())),
        };
        let res = sqlx::query(
            "INSERT INTO command_log (id, device_id, actor_id, command, ok, error, acked_at)
             VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $5 IS NULL THEN NULL ELSE now() END)",
        )
        .bind(cmd_id)
        .bind(device_id)
        .bind(actor.id())
        .bind(json!({ "by": actor.name(), "command": c }))
        .bind(ok)
        .bind(err)
        .execute(&st.db)
        .await;
        if let Err(e) = res {
            tracing::warn!(error = %e, "写指令日志失败");
        }
    }

    let (cmd_id, ack) = result?;
    Ok(CommandResult {
        cmd_id,
        ok: ack.as_ref().map(|a| a.ok),
        error: ack.and_then(|a| a.error),
    })
}

/// 全局急停 / 解除（Safety.dc.html、⌘⇧E）
pub async fn set_global_estop(st: &AppState, user: &AuthUser, active: bool) -> AppResult<()> {
    if !active
        && st.safety.policies().estop_release_requires_manager
        && !matches!(user.role, Role::Admin | Role::Owner)
    {
        return Err(AppError::forbidden("解除全局急停需要管理者确认"));
    }

    st.safety
        .set_global_estop(&st.db, active, Some(user.id))
        .await?;

    let cmd = if active {
        Command::Estop
    } else {
        Command::ReleaseEstop
    };
    for id in st.hub.online_ids() {
        st.hub.set_device_estop(&id, active);
        if let Err(e) = st.hub.dispatch(&id, cmd.clone(), None).await {
            tracing::error!(device = %id, error = %e, "全局急停下发失败");
        }
    }

    st.hub.publish(ServerEvent::Estop {
        device_id: None,
        active,
        by: user.name.clone(),
    });
    audit::record(
        st,
        user,
        audit::Kind::Control,
        if active {
            "触发全局急停"
        } else {
            "解除全局急停"
        },
        "全部设备",
        json!({}),
    )
    .await;
    Ok(())
}
