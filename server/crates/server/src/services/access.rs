//! 设备级权限：◐（Scoped）= 自己管理（owner_id）或被授权（device_grants）的设备。

use sqlx::PgPool;

use crate::{
    auth::{Access, AuthUser, Perm},
    error::{AppError, AppResult},
};

/// 校验用户对某台设备是否具有某项权限
pub async fn require_device(
    db: &PgPool,
    user: &AuthUser,
    perm: Perm,
    device_id: &str,
) -> AppResult<()> {
    match user.access(perm) {
        Access::All => {
            ensure_exists(db, device_id).await?;
            Ok(())
        }
        Access::None => Err(AppError::forbidden("没有权限执行该操作")),
        Access::Scoped => {
            let row: Option<(bool,)> = sqlx::query_as(
                "SELECT (d.owner_id = $2 OR EXISTS (
                     SELECT 1 FROM device_grants g WHERE g.device_id = d.id AND g.member_id = $2))
                 FROM devices d WHERE d.id = $1",
            )
            .bind(device_id)
            .bind(user.id)
            .fetch_optional(db)
            .await?;
            match row {
                None => Err(AppError::not_found(format!("设备 {device_id} 不存在"))),
                Some((true,)) => Ok(()),
                Some((false,)) => Err(AppError::forbidden("你没有该设备的权限")),
            }
        }
    }
}

/// 返回用户可见的设备 id 列表；None 表示全部
pub async fn visible_devices(db: &PgPool, user: &AuthUser) -> AppResult<Option<Vec<String>>> {
    match user.access(Perm::ViewDevice) {
        Access::All => Ok(None),
        Access::None => Ok(Some(vec![])),
        Access::Scoped => {
            let ids: Vec<(String,)> = sqlx::query_as(
                "SELECT id FROM devices WHERE owner_id = $1
                 UNION SELECT device_id FROM device_grants WHERE member_id = $1",
            )
            .bind(user.id)
            .fetch_all(db)
            .await?;
            Ok(Some(ids.into_iter().map(|(id,)| id).collect()))
        }
    }
}

async fn ensure_exists(db: &PgPool, device_id: &str) -> AppResult<()> {
    let found: Option<(String,)> = sqlx::query_as("SELECT id FROM devices WHERE id = $1")
        .bind(device_id)
        .fetch_optional(db)
        .await?;
    found
        .map(|_| ())
        .ok_or_else(|| AppError::not_found(format!("设备 {device_id} 不存在")))
}
