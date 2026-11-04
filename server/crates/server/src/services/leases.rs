//! 控制权租约（Lease.dc.html）。
//!
//! 规则：同一时刻一台设备只有一个控制者（`leases.device_id` 主键保证）。
//! 获取 / 续约 / 转移都通过一条带条件的 UPSERT 原子完成，避免并发竞争；
//! 内存缓存用于高频摇杆指令的鉴权（每帧不查库）。
//! 租约时长、空闲释放、过期动作来自安全策略（`/safety` 的 policies）。

use std::{
    collections::HashMap,
    sync::Arc,
    time::{Duration, Instant},
};

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
    /// 设备 → (持有者, 最近一次操作)，用于空闲释放
    activity: DashMap<String, (Uuid, Instant)>,
    /// stop_only 策略下已经处理过（停过车）的过期租约
    expired_handled: DashMap<String, ()>,
}

impl LeaseService {
    pub async fn load(db: PgPool, hub: Arc<Hub>) -> anyhow::Result<Self> {
        let rows: Vec<Lease> = sqlx::query_as("SELECT * FROM leases")
            .fetch_all(&db)
            .await?;
        let cache = rows.into_iter().map(|l| (l.device_id.clone(), l)).collect();
        Ok(Self {
            db,
            hub,
            cache,
            activity: DashMap::new(),
            expired_handled: DashMap::new(),
        })
    }

    /// 当前有效租约（已过期的视为无；不含申请队列）
    pub fn current(&self, device_id: &str) -> Option<Lease> {
        self.cache
            .get(device_id)
            .map(|l| l.clone())
            .filter(|l| !l.is_expired(Utc::now()))
    }

    /// 当前有效租约 + 申请队列（对外返回用）
    pub async fn full(&self, device_id: &str) -> AppResult<Option<Lease>> {
        let Some(mut l) = self.current(device_id) else {
            return Ok(None);
        };
        l.queue = self.pending_requests(device_id).await?;
        Ok(Some(l))
    }

    /// 多台设备的申请队列（列表接口一次查完）
    pub async fn queues(
        &self,
        device_ids: &[String],
    ) -> AppResult<HashMap<String, Vec<LeaseRequest>>> {
        let rows: Vec<LeaseRequest> = sqlx::query_as(
            "SELECT * FROM lease_requests WHERE state = 'pending' AND device_id = ANY($1)
             ORDER BY created_at",
        )
        .bind(device_ids)
        .fetch_all(&self.db)
        .await?;
        let mut map: HashMap<String, Vec<LeaseRequest>> = HashMap::new();
        for r in rows {
            map.entry(r.device_id.clone()).or_default().push(r);
        }
        Ok(map)
    }

    pub fn is_user_holder(&self, device_id: &str, user: Uuid) -> bool {
        self.current(device_id)
            .is_some_and(|l| l.held_by_user(user))
    }

    /// 用户是否可以对该设备下发运动指令（单机租约或自己发起的联调会话）
    pub async fn can_drive(&self, device_id: &str, user: Uuid) -> AppResult<bool> {
        let Some(lease) = self.current(device_id) else {
            return Ok(false);
        };
        match lease.holder_kind {
            LeaseHolderKind::User => Ok(lease.holder_id == Some(user)),
            LeaseHolderKind::Session => {
                let owner: Option<Uuid> =
                    sqlx::query_scalar("SELECT owner_id FROM fleet_sessions WHERE id = $1")
                        .bind(lease.session_id)
                        .fetch_optional(&self.db)
                        .await?;
                Ok(owner == Some(user))
            }
            LeaseHolderKind::Task => Ok(false),
        }
    }

    /// 持有者操作了设备（空闲释放计时清零）
    pub fn touch(&self, device_id: &str, user: Uuid) {
        self.activity
            .insert(device_id.to_owned(), (user, Instant::now()));
    }

    async fn changed(&self, device_id: &str, lease: Option<Lease>) {
        match &lease {
            Some(l) => {
                self.cache.insert(device_id.to_owned(), l.clone());
                if l.holder_kind == LeaseHolderKind::User
                    && let Some(h) = l.holder_id
                {
                    self.touch(device_id, h);
                }
            }
            None => {
                self.cache.remove(device_id);
                self.activity.remove(device_id);
            }
        }
        self.expired_handled.remove(device_id);
        self.publish(device_id).await;
    }

    /// 推送完整租约（含队列）
    pub async fn publish(&self, device_id: &str) {
        let queue = self.pending_requests(device_id).await.unwrap_or_default();
        let lease = self.current(device_id).map(|mut l| {
            l.queue = queue.clone();
            l
        });
        self.hub.publish(ServerEvent::LeaseChanged {
            device_id: device_id.to_owned(),
            lease,
            queue_len: queue.len() as i64,
        });
        self.hub
            .publish(ServerEvent::changed("leases", Some(device_id)));
    }

    pub async fn pending_requests(&self, device_id: &str) -> AppResult<Vec<LeaseRequest>> {
        Ok(sqlx::query_as(
            "SELECT * FROM lease_requests WHERE device_id = $1 AND state = 'pending' ORDER BY created_at",
        )
        .bind(device_id)
        .fetch_all(&self.db)
        .await?)
    }

    /// 申请控制权：空闲或已过期则直接获得，否则进入申请队列。
    /// 幂等：持有者再申请返回 granted（并续期），已在队列中的人再申请返回原申请。
    pub async fn acquire(
        &self,
        user: &AuthUser,
        device_id: &str,
        reason: String,
        expected_secs: Option<i32>,
        term_secs: i64,
    ) -> AppResult<AcquireOutcome> {
        let granted: Option<Lease> = sqlx::query_as(UPSERT_USER_LEASE)
            .bind(device_id)
            .bind(user.id)
            .bind("单机操控")
            .bind(term_secs as f64)
            .bind(false)
            .fetch_optional(&self.db)
            .await?;

        if let Some(lease) = granted {
            // 拿到控制权后，自己之前的排队申请自动撤销
            sqlx::query(
                "UPDATE lease_requests SET state = 'cancelled', decided_at = now()
                 WHERE device_id = $1 AND requester_id = $2 AND state = 'pending'",
            )
            .bind(device_id)
            .bind(user.id)
            .execute(&self.db)
            .await?;
            self.changed(device_id, Some(lease.clone())).await;
            return Ok(AcquireOutcome::Granted { lease });
        }

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
                .unwrap_or(term_secs as i32)
                .clamp(30, 4 * 3600),
        )
        .fetch_one(&self.db)
        .await?;

        self.hub.publish(ServerEvent::LeaseRequested {
            device_id: device_id.to_owned(),
            request_id: request.id,
            requester: user.name.clone(),
        });
        self.publish(device_id).await;
        Ok(AcquireOutcome::Queued { request })
    }

    /// 续约（操控页面应在剩余 1/3 时自动续约）。
    /// `allow_expired`：stop_only 策略下过期但未被他人接管的租约也可以续回来。
    pub async fn renew(
        &self,
        user: &AuthUser,
        device_id: &str,
        term_secs: i64,
        allow_expired: bool,
    ) -> AppResult<Lease> {
        let lease: Option<Lease> = sqlx::query_as(
            "UPDATE leases SET expires_at = now() + make_interval(secs => $3)
             WHERE device_id = $1 AND holder_kind = 'user' AND holder_id = $2
               AND (expires_at > now() OR $4)
             RETURNING *",
        )
        .bind(device_id)
        .bind(user.id)
        .bind(term_secs as f64)
        .bind(allow_expired)
        .fetch_optional(&self.db)
        .await?;
        let lease = lease.ok_or_else(|| AppError::conflict("你当前未持有该设备的控制权"))?;
        self.changed(device_id, Some(lease.clone())).await;
        Ok(lease)
    }

    /// 释放。`holder = Some(id)` 只释放该成员持有的租约；`None` 为强制收回（任何持有者）。
    pub async fn release(&self, device_id: &str, holder: Option<Uuid>) -> AppResult<Lease> {
        let released: Option<Lease> = sqlx::query_as(
            "DELETE FROM leases WHERE device_id = $1
             AND ($2::uuid IS NULL OR (holder_kind = 'user' AND holder_id = $2))
             RETURNING *",
        )
        .bind(device_id)
        .bind(holder)
        .fetch_optional(&self.db)
        .await?;
        let lease = released.ok_or_else(|| {
            AppError::conflict(if holder.is_some() {
                "你当前未持有该设备的控制权"
            } else {
                "该设备当前无人控制"
            })
        })?;
        self.changed(device_id, None).await;
        Ok(lease)
    }

    /// 是否有权处理该设备的申请 / 转交：当前持有者、平台管理员、设备管理者
    pub async fn can_decide(&self, user: &AuthUser, device_id: &str) -> AppResult<bool> {
        if user.role == Role::Admin || self.is_user_holder(device_id, user.id) {
            return Ok(true);
        }
        self.is_device_owner(user.id, device_id).await
    }

    pub async fn is_device_owner(&self, user: Uuid, device_id: &str) -> AppResult<bool> {
        let owner: Option<Option<Uuid>> =
            sqlx::query_scalar("SELECT owner_id FROM devices WHERE id = $1")
                .bind(device_id)
                .fetch_optional(&self.db)
                .await?;
        Ok(owner.flatten() == Some(user))
    }

    async fn pending_request(&self, request_id: Uuid) -> AppResult<LeaseRequest> {
        let req: LeaseRequest = sqlx::query_as("SELECT * FROM lease_requests WHERE id = $1")
            .bind(request_id)
            .fetch_optional(&self.db)
            .await?
            .ok_or_else(|| AppError::not_found("申请不存在"))?;
        if req.state != crate::models::RequestState::Pending {
            return Err(AppError::conflict("该申请已处理"));
        }
        Ok(req)
    }

    fn ensure_not_session(&self, device_id: &str, label: &str) -> AppResult<()> {
        if self
            .current(device_id)
            .is_some_and(|l| l.holder_kind == LeaseHolderKind::Session)
        {
            return Err(AppError::ConflictDevices {
                message: format!("{label} 正在联调会话中，请先结束会话或把它移出会话"),
                device_ids: vec![device_id.to_owned()],
            });
        }
        Ok(())
    }

    /// 批准申请：控制权转给申请人，时长为申请里的预计时长
    pub async fn approve(
        &self,
        user: &AuthUser,
        request_id: Uuid,
        device_label: &str,
    ) -> AppResult<(Lease, LeaseRequest)> {
        let req = self.pending_request(request_id).await?;
        if !self.can_decide(user, &req.device_id).await? {
            return Err(AppError::forbidden("只有当前控制者或管理者可以批准"));
        }
        self.ensure_not_session(&req.device_id, device_label)?;

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
            return Err(AppError::conflict("该申请已处理"));
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
        Ok((lease, req))
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
        .ok_or_else(|| AppError::conflict("该申请已处理"))?;
        self.publish(&req.device_id).await;
        Ok(req)
    }

    /// 主动转交给成员或自动任务（联调会话持有的设备不能转交）
    pub async fn transfer(
        &self,
        user: &AuthUser,
        device_id: &str,
        device_label: &str,
        target: &TransferTarget,
        term_secs: i64,
    ) -> AppResult<Lease> {
        if !self.can_decide(user, device_id).await? {
            return Err(AppError::forbidden("只有当前控制者或管理者可以转交控制权"));
        }
        self.ensure_not_session(device_id, device_label)?;
        let lease: Lease = match target {
            TransferTarget::User { id } => {
                sqlx::query_as(UPSERT_USER_LEASE)
                    .bind(device_id)
                    .bind(id)
                    .bind(format!("单机 · 由 {} 转交", user.name))
                    .bind(term_secs as f64)
                    .bind(true)
                    .fetch_one(&self.db)
                    .await?
            }
            TransferTarget::Task { id } => {
                sqlx::query_as(
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
                .await?
            }
        };
        self.changed(device_id, Some(lease.clone())).await;
        Ok(lease)
    }

    /// 联调会话获取多台设备；任何一台被他人占用则整体失败，并返回所有冲突设备
    pub async fn acquire_for_session(
        &self,
        session_id: Uuid,
        source: &str,
        device_ids: &[String],
    ) -> AppResult<Vec<Lease>> {
        let conflicts: Vec<(String, String)> = sqlx::query_as(
            "SELECT l.device_id, d.name FROM leases l JOIN devices d ON d.id = l.device_id
             WHERE l.device_id = ANY($1)
               AND (l.expires_at IS NULL OR l.expires_at > now())
               AND l.session_id IS DISTINCT FROM $2
             ORDER BY d.code",
        )
        .bind(device_ids)
        .bind(session_id)
        .fetch_all(&self.db)
        .await?;
        if !conflicts.is_empty() {
            let names: Vec<&str> = conflicts.iter().map(|(_, n)| n.as_str()).collect();
            return Err(AppError::ConflictDevices {
                message: format!("{} 正被他人控制，请先申请控制权", names.join("、")),
                device_ids: conflicts.into_iter().map(|(id, _)| id).collect(),
            });
        }

        let mut tx = self.db.begin().await?;
        let mut leases = Vec::with_capacity(device_ids.len());
        for id in device_ids {
            let lease: Option<Lease> = sqlx::query_as(
                "INSERT INTO leases (device_id, holder_kind, session_id, source, expires_at)
                 VALUES ($1, 'session', $2, $3, NULL)
                 ON CONFLICT (device_id) DO UPDATE SET holder_kind = 'session', holder_id = NULL,
                    task_id = NULL, session_id = EXCLUDED.session_id, source = EXCLUDED.source,
                    acquired_at = CASE WHEN leases.session_id = EXCLUDED.session_id
                                       THEN leases.acquired_at ELSE now() END,
                    expires_at = NULL
                 WHERE (leases.expires_at IS NOT NULL AND leases.expires_at <= now())
                    OR leases.session_id = EXCLUDED.session_id
                 RETURNING *",
            )
            .bind(id)
            .bind(session_id)
            .bind(source)
            .fetch_optional(&mut *tx)
            .await?;
            match lease {
                Some(l) => leases.push(l),
                None => {
                    return Err(AppError::ConflictDevices {
                        message: format!("设备 {id} 刚刚被他人占用，请重试"),
                        device_ids: vec![id.clone()],
                    });
                }
            }
        }
        tx.commit().await?;
        for l in &leases {
            self.changed(&l.device_id, Some(l.clone())).await;
        }
        Ok(leases)
    }

    /// 释放联调会话持有的租约；`only` 为空表示全部
    pub async fn release_session(
        &self,
        session_id: Uuid,
        only: Option<&[String]>,
    ) -> AppResult<()> {
        let ids: Vec<String> = sqlx::query_scalar(
            "DELETE FROM leases WHERE session_id = $1 AND ($2::text[] IS NULL OR device_id = ANY($2))
             RETURNING device_id",
        )
        .bind(session_id)
        .bind(only)
        .fetch_all(&self.db)
        .await?;
        for id in ids {
            self.changed(&id, None).await;
        }
        Ok(())
    }

    /// 某成员当前持有的单机租约
    pub fn held_by(&self, user: Uuid) -> Vec<Lease> {
        self.cache
            .iter()
            .filter(|l| l.held_by_user(user) && !l.is_expired(Utc::now()))
            .map(|l| l.clone())
            .collect()
    }

    /// 处理过期租约。`release = true` 删除（stop_release）；否则只返回一次（stop_only，由调用方停车）。
    pub async fn sweep_expired(&self, release: bool) -> AppResult<Vec<Lease>> {
        if release {
            let expired: Vec<Lease> = sqlx::query_as(
                "DELETE FROM leases WHERE expires_at IS NOT NULL AND expires_at <= now() RETURNING *",
            )
            .fetch_all(&self.db)
            .await?;
            for l in &expired {
                self.changed(&l.device_id, None).await;
            }
            return Ok(expired);
        }
        let now = Utc::now();
        let mut fresh = Vec::new();
        for l in self.cache.iter() {
            if l.is_expired(now) && !self.expired_handled.contains_key(&l.device_id) {
                fresh.push(l.clone());
            }
        }
        for l in &fresh {
            self.expired_handled.insert(l.device_id.clone(), ());
            self.publish(&l.device_id).await;
        }
        Ok(fresh)
    }

    /// 释放持有者空闲超过 `idle` 的单机租约
    pub async fn sweep_idle(&self, idle: Duration) -> AppResult<Vec<Lease>> {
        let stale: Vec<(String, Uuid)> = self
            .activity
            .iter()
            .filter(|e| e.value().1.elapsed() >= idle)
            .map(|e| (e.key().clone(), e.value().0))
            .collect();
        let mut released = Vec::new();
        for (device, holder) in stale {
            if self.is_user_holder(&device, holder)
                && let Ok(l) = self.release(&device, Some(holder)).await
            {
                released.push(l);
            } else {
                self.activity.remove(&device);
            }
        }
        Ok(released)
    }
}
