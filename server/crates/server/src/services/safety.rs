//! 全局急停状态与安全策略（Safety.dc.html），内存缓存 + 数据库持久化。

use std::sync::{
    RwLock,
    atomic::{AtomicBool, Ordering},
};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::{AppError, AppResult};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Policies {
    pub auto_dock: bool,
    pub dock_threshold_pct: f32,
    pub heartbeat_timeout_ms: u64,
    /// stop / down
    pub disconnect_action: String,
    /// stop_and_release / release
    pub lease_expire_action: String,
    pub max_speed_mps: f32,
    pub max_yaw_rate: f32,
    pub human_stop: bool,
    pub min_device_distance_m: f32,
    pub fall_detection: bool,
    pub collision_detection: bool,
    pub edge_detection: bool,
    pub estop_release_requires_manager: bool,
}

impl Default for Policies {
    fn default() -> Self {
        Self {
            auto_dock: true,
            dock_threshold_pct: 20.0,
            heartbeat_timeout_ms: 1500,
            disconnect_action: "stop".into(),
            lease_expire_action: "stop_and_release".into(),
            max_speed_mps: 1.5,
            max_yaw_rate: 2.0,
            human_stop: true,
            min_device_distance_m: 0.8,
            fall_detection: true,
            collision_detection: true,
            edge_detection: true,
            estop_release_requires_manager: true,
        }
    }
}

pub struct SafetyService {
    global_estop: AtomicBool,
    policies: RwLock<Policies>,
}

impl SafetyService {
    pub async fn load(db: &PgPool) -> anyhow::Result<Self> {
        let (estop, policies): (bool, Value) =
            sqlx::query_as("SELECT global_estop, policies FROM safety_state WHERE id = 1")
                .fetch_one(db)
                .await?;
        Ok(Self {
            global_estop: AtomicBool::new(estop),
            policies: RwLock::new(serde_json::from_value(policies).unwrap_or_default()),
        })
    }

    pub fn is_global_estop(&self) -> bool {
        self.global_estop.load(Ordering::SeqCst)
    }

    pub fn policies(&self) -> Policies {
        self.policies.read().expect("policies lock").clone()
    }

    pub async fn set_global_estop(&self, db: &PgPool, on: bool, by: Option<Uuid>) -> AppResult<()> {
        // 先改内存：急停要立即生效，数据库写入失败也不能阻止急停
        self.global_estop.store(on, Ordering::SeqCst);
        sqlx::query(
            "UPDATE safety_state SET global_estop = $1, estop_by = $2,
             estop_at = CASE WHEN $1 THEN now() ELSE estop_at END WHERE id = 1",
        )
        .bind(on)
        .bind(by)
        .execute(db)
        .await?;
        Ok(())
    }

    /// 局部更新策略：传入的 JSON 字段覆盖现有值
    pub async fn update_policies(&self, db: &PgPool, patch: Value) -> AppResult<Policies> {
        let Value::Object(patch) = patch else {
            return Err(AppError::bad_request("策略必须是 JSON 对象"));
        };
        let mut merged = serde_json::to_value(self.policies()).map_err(anyhow::Error::from)?;
        if let Value::Object(m) = &mut merged {
            for (k, v) in patch {
                if !m.contains_key(&k) {
                    return Err(AppError::bad_request(format!("未知策略项 {k}")));
                }
                m.insert(k, v);
            }
        }
        let policies: Policies = serde_json::from_value(merged.clone())
            .map_err(|e| AppError::bad_request(format!("策略格式错误：{e}")))?;
        sqlx::query("UPDATE safety_state SET policies = $1 WHERE id = 1")
            .bind(&merged)
            .execute(db)
            .await?;
        *self.policies.write().expect("policies lock") = policies.clone();
        Ok(policies)
    }
}
