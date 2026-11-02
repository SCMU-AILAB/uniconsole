//! 控制权租约（Lease.dc.html）。
//!
//! 规则：同一时刻一台设备只有一个控制者（`leases.device_id` 主键保证）。
//! 获取 / 续约 / 转移都通过一条带条件的 UPSERT 原子完成，避免并发竞争；
//! 内存缓存用于高频摇杆指令的鉴权（每帧不查库）。

use std::sync::Arc;

use chrono::Utc;
use dashmap::DashMap;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::{Lease, LeaseHolderKind, LeaseRequest, Role},
    protocol::ServerEvent,
    realtime::Hub,
};

#[derive(Debug, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum AcquireOutcome {
    Granted { lease: Lease },
    Queued { request: LeaseRequest },
}

#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum TransferTarget {
    User { id: Uuid },
    Task { id: Uuid },
}

const UPSERT_USER_LEASE: &str = "
    INSERT INTO leases (device_id, holder_kind, holder_id, source, acquired_at, expires_at)
    VALUES ($1, 'user', $2, $3, now(), now() + make_interval(secs => $4))
    ON CONFLICT (device_id) DO UPDATE SET
        holder_kind = 'user',
        holder_id   = EXCLUDED.holder_id,
        task_id     = NULL,
        session_id  = NULL,
        source      = EXCLUDED.source,
        acquired_at = CASE WHEN leases.holder_kind = 'user' AND leases.holder_id = EXCLUDED.holder_id
                           THEN leases.acquired_at ELSE now() END,
        expires_at  = EXCLUDED.expires_at
    WHERE (leases.expires_at IS NOT NULL AND leases.expires_at <= now())
       OR (leases.holder_kind = 'user' AND leases.holder_id = EXCLUDED.holder_id)
       OR $5
    RETURNING *";

pub struct LeaseService {
    db: PgPool,
    hub: Arc<Hub>,
    cache: DashMap<String, Lease>,
    default_secs: i64,
}

impl LeaseService {
    pub async fn load(db: PgPool, hub: Arc<Hub>, default_secs: i64) -> anyhow::Result<Self> {
        let rows: Vec<Lease> = sqlx::query_as("SELECT * FROM leases")
            .fetch_all(&db)
            .await?;
        let cache = rows.into_iter().map(|l| (l.device_id.clone(), l)).collect();
        Ok(Self {
            db,
            hub,
            cache,
            default_secs,
        })
    }

    /// 当前有效租约（已过期的视为无）
    pub fn current(&self, device_id: &str) -> Option<Lease> {
        self.cache
            .get(device_id)
            .map(|l| l.clone())
            .filter(|l| !l.is_expired(Utc::now()))
    }

    pub fn is_user_holder(&self, device_id: &str, user: Uuid) -> bool {
        self.current(device_id)
            .is_some_and(|l| l.held_by_user(user))
    }

    /// 用户是否可以对该设备下发运动指令（单机租约或自己的联调会话）
    pub async fn can_drive(&self, device_id: &str, user: Uuid) -> AppResult<bool> {
        let Some(lease) = self.current(device_id) else {
            return Ok(false);
        };
        match lease.holder_kind {
            LeaseHolderKind::User => Ok(lease.holder_id == Some(user)),
            LeaseHolderKind::Session => {
                let owner: Option<(Uuid,)> =
                    sqlx::query_as("SELECT owner_id FROM fleet_sessions WHERE id = $1")
                        .bind(lease.session_id)
                        .fetch_optional(&self.db)
                        .await?;
                Ok(owner.is_some_and(|(o,)| o == user))
            }
            LeaseHolderKind::Task => Ok(false),
        }
    }

    async fn changed(&self, device_id: &str, lease: Option<Lease>) {
        match &lease {
            Some(l) => {
                self.cache.insert(device_id.to_owned(), l.clone());
            }
            None => {
                self.cache.remove(device_id);
            }
        }
        let queue_len = self.queue_len(device_id).await.unwrap_or(0);
        self.hub.publish(ServerEvent::LeaseChanged {
            device_id: device_id.to_owned(),
            lease,
            queue_len,
        });
    }

    pub async fn queue_len(&self, device_id: &str) -> AppResult<i64> {
        let (n,): (i64,) = sqlx::query_as(
            "SELECT count(*) FROM lease_requests WHERE device_id = $1 AND state = 'pending'",
        )
        .bind(device_id)
        .fetch_one(&self.db)
        .await?;
        Ok(n)
    }

    pub async fn pending_requests(&self, device_id: &str) -> AppResult<Vec<LeaseRequest>> {
        Ok(sqlx::query_as(
            "SELECT * FROM lease_requests WHERE device_id = $1 AND state = 'pending' ORDER BY created_at",
        )
        .bind(device_id)
        .fetch_all(&self.db)
        .await?)
    }

    /// 申请控制权：空闲或已过期则直接获得，否则进入申请队列
    pub async fn acquire(
        &self,
        user: &AuthUser,
        device_id: &str,
        reason: String,
        expected_secs: Option<i32>,
    ) -> AppResult<AcquireOutcome> {
        let granted: Option<Lease> = sqlx::query_as(UPSERT_USER_LEASE)
            .bind(device_id)
            .bind(user.id)
            .bind("单机操控")
            .bind(self.default_secs as f64)
            .bind(false)
            .fetch_optional(&self.db)
            .await?;

        if let Some(lease) = granted {
            self.changed(device_id, Some(lease.clone())).await;
            return Ok(AcquireOutcome::Granted { lease });
        }

        // 已被他人持有：排队（同一用户重复申请返回已有申请）
        if let Some(existing) = sqlx::query_as::<_, LeaseRequest>(
            "SELECT * FROM lease_requests WHERE device_id = $1 AND requester_id = $2 AND state = 'pending'",
        )
        .bind(device_id)
        .bind(user.id)
        .fetch_optional(&self.db)
        .await?
        {
            return Ok(AcquireOutcome::Queued { request: existing });
        }

        let request: LeaseRequest = sqlx::query_as(
            "INSERT INTO lease_requests (device_id, requester_id, reason, expected_secs)
             VALUES ($1, $2, $3, $4) RETURNING *",
        )
        .bind(device_id)
        .bind(user.id)
        .bind(reason)
        .bind(
            expected_secs
                .unwrap_or(self.default_secs as i32)
                .clamp(30, 4 * 3600),
        )
        .fetch_one(&self.db)
        .await?;

        self.hub.publish(ServerEvent::LeaseRequested {
            device_id: device_id.to_owned(),
            request_id: request.id,
            requester: user.name.clone(),
        });
        let queue_len = self.queue_len(device_id).await?;
        self.hub.publish(ServerEvent::LeaseChanged {
            device_id: device_id.to_owned(),
            lease: self.current(device_id),
            queue_len,
        });
        Ok(AcquireOutcome::Queued { request })
    }

    /// 续约（操控页面应在剩余 1/3 时自动续约）
    pub async fn renew(&self, user: &AuthUser, device_id: &str) -> AppResult<Lease> {
        let lease: Option<Lease> = sqlx::query_as(
            "UPDATE leases SET expires_at = now() + make_interval(secs => $3)
             WHERE device_id = $1 AND holder_kind = 'user' AND holder_id = $2 AND expires_at > now()
             RETURNING *",
        )
        .bind(device_id)
        .bind(user.id)
        .bind(self.default_secs as f64)
        .fetch_optional(&self.db)
        .await?;
        let lease = lease.ok_or_else(|| AppError::conflict("你当前未持有该设备的控制权"))?;
        self.changed(device_id, Some(lease.clone())).await;
        Ok(lease)
    }

    /// 释放；`force` 供管理员强制收回
    pub async fn release(&self, user: &AuthUser, device_id: &str, force: bool) -> AppResult<()> {
        let res = sqlx::query(
            "DELETE FROM leases WHERE device_id = $1
             AND ($3 OR (holder_kind = 'user' AND holder_id = $2))",
        )
        .bind(device_id)
        .bind(user.id)
        .bind(force)
        .execute(&self.db)
        .await?;
        if res.rows_affected() == 0 {
            return Err(AppError::conflict("你当前未持有该设备的控制权"));
        }
        self.changed(device_id, None).await;
        Ok(())
    }

    /// 是否有权处理该设备的申请 / 转移：当前持有者、平台管理员、设备管理者
    async fn can_decide(&self, user: &AuthUser, device_id: &str) -> AppResult<bool> {
        if user.role == Role::Admin || self.is_user_holder(device_id, user.id) {
            return Ok(true);
        }
        let owner: Option<(Option<Uuid>,)> =
            sqlx::query_as("SELECT owner_id FROM devices WHERE id = $1")
                .bind(device_id)
                .fetch_optional(&self.db)
                .await?;
        Ok(owner.and_then(|(o,)| o) == Some(user.id))
    }

    async fn pending_request(&self, request_id: Uuid) -> AppResult<LeaseRequest> {
        sqlx::query_as("SELECT * FROM lease_requests WHERE id = $1 AND state = 'pending'")
            .bind(request_id)
            .fetch_optional(&self.db)
            .await?
            .ok_or_else(|| AppError::not_found("申请不存在或已处理"))
    }

    /// 批准申请：控制权转移给申请人
    pub async fn approve(&self, user: &AuthUser, request_id: Uuid) -> AppResult<Lease> {
        let req = self.pending_request(request_id).await?;
        if !self.can_decide(user, &req.device_id).await? {
            return Err(AppError::forbidden("只有当前控制者或管理者可以批准"));
        }

        let mut tx = self.db.begin().await?;
        let updated = sqlx::query(
            "UPDATE lease_requests SET state = 'approved', decided_by = $2, decided_at = now()
             WHERE id = $1 AND state = 'pending'",
        )
        .bind(request_id)
        .bind(user.id)
        .execute(&mut *tx)
        .await?;
        if updated.rows_affected() == 0 {
            return Err(AppError::conflict("申请已被处理"));
        }
        let lease: Lease = sqlx::query_as(UPSERT_USER_LEASE)
            .bind(&req.device_id)
            .bind(req.requester_id)
            .bind(format!("单机 · 由 {} 转移", user.name))
            .bind(req.expected_secs as f64)
            .bind(true)
            .fetch_one(&mut *tx)
            .await?;
        tx.commit().await?;

        self.changed(&req.device_id, Some(lease.clone())).await;
        Ok(lease)
    }

    pub async fn deny(&self, user: &AuthUser, request_id: Uuid) -> AppResult<LeaseRequest> {
        let req = self.pending_request(request_id).await?;
        if !self.can_decide(user, &req.device_id).await? {
            return Err(AppError::forbidden("只有当前控制者或管理者可以拒绝"));
        }
        let req: LeaseRequest = sqlx::query_as(
            "UPDATE lease_requests SET state = 'denied', decided_by = $2, decided_at = now()
             WHERE id = $1 AND state = 'pending' RETURNING *",
        )
        .bind(request_id)
        .bind(user.id)
        .fetch_optional(&self.db)
        .await?
        .ok_or_else(|| AppError::conflict("申请已被处理"))?;
        let lease = self.current(&req.device_id);
        self.changed(&req.device_id, lease).await;
        Ok(req)
    }

    /// 主动转移给成员或自动任务
    pub async fn transfer(
        &self,
        user: &AuthUser,
        device_id: &str,
        target: TransferTarget,
    ) -> AppResult<Lease> {
        if !self.can_decide(user, device_id).await? {
            return Err(AppError::forbidden("只有当前控制者或管理者可以转移控制权"));
        }
        let lease: Lease = match target {
            TransferTarget::User { id } => sqlx::query_as(UPSERT_USER_LEASE)
                .bind(device_id)
                .bind(id)
                .bind(format!("单机 · 由 {} 转移", user.name))
                .bind(self.default_secs as f64)
                .bind(true)
                .fetch_one(&self.db)
                .await?,
            TransferTarget::Task { id } => sqlx::query_as(
                "INSERT INTO leases (device_id, holder_kind, task_id, source, expires_at)
                 VALUES ($1, 'task', $2, COALESCE((SELECT name FROM missions WHERE id = $2), '自动任务'), NULL)
                 ON CONFLICT (device_id) DO UPDATE SET holder_kind = 'task', holder_id = NULL,
                    task_id = EXCLUDED.task_id, session_id = NULL, source = EXCLUDED.source,
                    acquired_at = now(), expires_at = NULL
                 RETURNING *",
            )
            .bind(device_id)
            .bind(id)
            .fetch_one(&self.db)
            .await?,
        };
        self.changed(device_id, Some(lease.clone())).await;
        Ok(lease)
    }

    /// 联调会话一次性获取多台设备；任何一台被占用则全部回滚
    pub async fn acquire_for_session(
        &self,
        session_id: Uuid,
        name: &str,
        device_ids: &[String],
    ) -> AppResult<Vec<Lease>> {
        let mut tx = self.db.begin().await?;
        let mut leases = Vec::with_capacity(device_ids.len());
        for id in device_ids {
            let lease: Option<Lease> = sqlx::query_as(
                "INSERT INTO leases (device_id, holder_kind, session_id, source, expires_at)
                 VALUES ($1, 'session', $2, $3, NULL)
                 ON CONFLICT (device_id) DO UPDATE SET holder_kind = 'session', holder_id = NULL,
                    task_id = NULL, session_id = EXCLUDED.session_id, source = EXCLUDED.source,
                    acquired_at = now(), expires_at = NULL
                 WHERE (leases.expires_at IS NOT NULL AND leases.expires_at <= now())
                    OR leases.session_id = EXCLUDED.session_id
                 RETURNING *",
            )
            .bind(id)
            .bind(session_id)
            .bind(format!("联调会话 · {name}"))
            .fetch_optional(&mut *tx)
            .await?;
            match lease {
                Some(l) => leases.push(l),
                None => {
                    return Err(AppError::conflict(format!(
                        "设备 {id} 正被他人控制，请先申请控制权"
                    )));
                }
            }
        }
        tx.commit().await?;
        for l in &leases {
            self.changed(&l.device_id, Some(l.clone())).await;
        }
        Ok(leases)
    }

    pub async fn release_session(&self, session_id: Uuid) -> AppResult<()> {
        let ids: Vec<(String,)> =
            sqlx::query_as("DELETE FROM leases WHERE session_id = $1 RETURNING device_id")
                .bind(session_id)
                .fetch_all(&self.db)
                .await?;
        for (id,) in ids {
            self.changed(&id, None).await;
        }
        Ok(())
    }

    /// 清理过期租约，返回被清理的租约（调用方负责下发停止指令）
    pub async fn sweep_expired(&self) -> AppResult<Vec<Lease>> {
        let expired: Vec<Lease> = sqlx::query_as(
            "DELETE FROM leases WHERE expires_at IS NOT NULL AND expires_at <= now() RETURNING *",
        )
        .fetch_all(&self.db)
        .await?;
        for l in &expired {
            self.changed(&l.device_id, None).await;
        }
        Ok(expired)
    }
}
