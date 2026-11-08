//! 指令下发的唯一入口：急停检查 → 控制权检查 → 安全限幅 → 下发 → 记录。
//!
//! HANDOFF §8 交互规则在服务端的落实：
//! 1. 急停永远可达：Stop / Estop 不需要控制权，任何角色都能触发；
//!    急停期间所有运动指令被拒绝（423 estop_active）。
//! 2. 控制权：运动指令必须由租约持有者发出。
//! 4. 松开 300 ms 自动停止：由机器人端看门狗保证；前端断线时服务端补发 Stop。
//!
//! 除高频 `move` 外，每条指令（包括被拒绝的）都写进指令日志，`error` 为错误码。

use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::json;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::Role,
    protocol::{Command, ServerEvent},
    services::{audit, events},
    state::AppState,
};

#[derive(Clone, Copy)]
pub enum Actor<'a> {
    User(&'a AuthUser),
    /// 走急停通道的成员操作（告警「远程趴下」）：不需要控制权，急停中也允许
    Override(&'a AuthUser),
    /// 系统自动动作（告警自动处理、租约过期、断线保护）
    System(&'a str),
}

impl Actor<'_> {
    fn id(&self) -> Option<Uuid> {
        match self {
            Actor::User(u) | Actor::Override(u) => Some(u.id),
            Actor::System(_) => None,
        }
    }
    fn name(&self) -> &str {
        match self {
            Actor::User(u) | Actor::Override(u) => &u.name,
            Actor::System(s) => s,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct CommandResult {
    pub cmd_id: Uuid,
    /// None = 未等待回执（高频 move）
    pub ok: Option<bool>,
    /// 错误码：robot_error（机器人执行失败）等
    pub error: Option<String>,
    /// 给人看的错误说明
    pub message: Option<String>,
    /// 下发到收到回执的耗时
    pub latency_ms: Option<u64>,
}

fn is_manager(u: &AuthUser) -> bool {
    matches!(u.role, Role::Admin | Role::Owner)
}

/// 下发前的检查与副作用（急停标记、限幅）
async fn precheck(
    st: &AppState,
    actor: Actor<'_>,
    device_id: &str,
    cmd: &mut Command,
) -> AppResult<()> {
    match cmd {
        Command::Estop { drill: true } => {}
        Command::Estop { drill: false } => {
            st.hub.set_device_estop(device_id, true);
            st.hub.publish(ServerEvent::Estop {
                device_id: Some(device_id.to_owned()),
                active: true,
                by: actor.name().to_owned(),
            });
            events::record(
                st,
                device_id,
                format!("{} 触发急停", actor.name()),
                "critical",
            )
            .await;
        }
        Command::ReleaseEstop => {
            if st.safety.is_global_estop() {
                return Err(AppError::EstopActive);
            }
            if let Actor::User(u) | Actor::Override(u) = actor {
                if st.safety.policies().release_needs_manager && !is_manager(u) {
                    return Err(AppError::forbidden("需要管理者解除"));
                }
                if !is_manager(u) && !st.leases.can_drive(device_id, u.id).await? {
                    return Err(AppError::forbidden("只有控制者或管理者可以解除急停"));
                }
            }
            st.hub.set_device_estop(device_id, false);
            st.hub.publish(ServerEvent::Estop {
                device_id: Some(device_id.to_owned()),
                active: false,
                by: actor.name().to_owned(),
            });
            events::record(
                st,
                device_id,
                format!("{} 解除急停", actor.name()),
                "success",
            )
            .await;
        }
        c if c.is_motion() => {
            if let Actor::User(u) = actor {
                if st.safety.is_global_estop() || st.hub.is_device_estopped(device_id) {
                    return Err(AppError::EstopActive);
                }
                if !st.leases.can_drive(device_id, u.id).await? {
                    return Err(AppError::forbidden("你没有该设备的控制权（只读）"));
                }
            } else if let Actor::System(_) = actor
                && (st.safety.is_global_estop() || st.hub.is_device_estopped(device_id))
            {
                return Err(AppError::EstopActive);
            }
            let p = st.safety.policies();
            c.clamp(p.speed_limit, p.max_yaw_rate);
        }
        _ => {}
    }
    Ok(())
}

pub async fn execute(
    st: &AppState,
    actor: Actor<'_>,
    device_id: &str,
    cmd: Command,
    wait_ack: bool,
) -> AppResult<CommandResult> {
    let wait = wait_ack.then(|| Duration::from_millis(st.cfg.command_timeout_ms));
    execute_with_timeout(st, actor, device_id, cmd, wait).await
}

/// 同 [`execute`]，回执超时由调用方决定（导航这类长指令，机器人到达后才回执）
pub async fn execute_with_timeout(
    st: &AppState,
    actor: Actor<'_>,
    device_id: &str,
    mut cmd: Command,
    wait: Option<Duration>,
) -> AppResult<CommandResult> {
    let log_it = !matches!(cmd, Command::Move { .. });
    let started = Instant::now();

    let result = match precheck(st, actor, device_id, &mut cmd).await {
        Ok(()) => st.hub.dispatch(device_id, cmd.clone(), wait).await,
        Err(e) => Err(e),
    };
    let latency_ms = wait.map(|_| started.elapsed().as_millis() as u64);

    if let (Actor::User(u), Ok(_)) = (actor, &result)
        && cmd.is_motion()
    {
        st.leases.touch(device_id, u.id);
    }

    if log_it {
        let (cmd_id, ok, code, message) = match &result {
            Ok((id, Some(ack))) => (
                *id,
                Some(ack.ok),
                (!ack.ok).then(|| "robot_error".to_owned()),
                ack.error.clone(),
            ),
            Ok((id, None)) => (*id, None, None, None),
            Err(e) => (
                Uuid::new_v4(),
                Some(false),
                Some(e.code().to_owned()),
                Some(e.to_string()),
            ),
        };
        let res = sqlx::query(
            "INSERT INTO command_log (id, device_id, actor_id, actor_name, command, ok, error, error_code, acked_at)
             VALUES ($1, $2, $3, $4, $5, $6, $7, $8, CASE WHEN $6 IS NULL THEN NULL ELSE now() END)",
        )
        .bind(cmd_id)
        .bind(device_id)
        .bind(actor.id())
        .bind(actor.name())
        .bind(json!(cmd))
        .bind(ok)
        .bind(message)
        .bind(code)
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
        error: ack
            .as_ref()
            .and_then(|a| (!a.ok).then(|| "robot_error".to_owned())),
        message: ack.and_then(|a| a.error),
        latency_ms,
    })
}

/// 全局急停 / 解除（Safety.dc.html、⌘⇧E）。急停时所有进行中的联调会话暂停。
pub async fn set_global_estop(st: &AppState, user: &AuthUser, active: bool) -> AppResult<()> {
    if !active && st.safety.policies().release_needs_manager && !is_manager(user) {
        return Err(AppError::forbidden("需要管理者解除"));
    }

    st.safety
        .set_global_estop(&st.db, active, Some(user.id))
        .await?;

    let cmd = if active {
        Command::Estop { drill: false }
    } else {
        Command::ReleaseEstop
    };
    for id in st.hub.online_ids() {
        st.hub.set_device_estop(&id, active);
        if let Err(e) = st.hub.dispatch(&id, cmd.clone(), None).await {
            tracing::error!(device = %id, error = %e, "全局急停下发失败");
        }
        let text = if active {
            format!("{} 触发全局急停", user.name)
        } else {
            format!("{} 解除全局急停", user.name)
        };
        events::record(st, &id, text, if active { "critical" } else { "success" }).await;
    }
    if active {
        let paused = sqlx::query(
            "UPDATE fleet_sessions SET paused = TRUE, updated_at = now() WHERE active AND NOT paused",
        )
        .execute(&st.db)
        .await;
        if paused.is_ok_and(|r| r.rows_affected() > 0) {
            st.hub
                .publish(ServerEvent::changed("fleet_sessions", None::<String>));
        }
    }

    st.hub.publish(ServerEvent::Estop {
        device_id: None,
        active,
        by: user.name.clone(),
    });
    st.hub
        .publish(ServerEvent::changed("safety", None::<String>));
    audit::record(
        st,
        user,
        audit::Kind::Control,
        if active {
            format!("{} 触发全局急停", user.name)
        } else {
            format!("{} 解除全局急停", user.name)
        },
        "全部设备",
        json!({}),
    )
    .await;
    Ok(())
}
