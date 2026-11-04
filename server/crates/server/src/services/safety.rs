//! 全局急停状态与安全策略（Safety.dc.html），内存缓存 + 数据库持久化。
//! 策略字段名与前端 `SafetyPolicies`（lib/data/models/safety.dart）一致。

use std::sync::{
    RwLock,
    atomic::{AtomicBool, Ordering},
};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::{AppError, AppResult};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(default)]
pub struct Policies {
    /// 低电量自动回桩
    pub auto_dock: bool,
    /// 回桩阈值（%）
    pub dock_threshold: f32,
    /// 机器人心跳超时，超过即判定断联
    pub heartbeat_timeout_ms: u64,
    /// 机器人与服务器断联后的动作：stop | down | dock
    pub lost_link_action: String,
    /// 控制租约过期：stop_release（停止并释放）| stop_only（只停止，持有者续约前任何人都可以申请）
    pub lease_expiry_action: String,
    /// 全局限速 m/s
    pub speed_limit: f32,
    /// 最大转向角速度 rad/s（前端暂未显示）
    pub max_yaw_rate: f32,
    pub stop_near_people: bool,
    /// 设备间最小距离 m（联调 / 编队）
    pub min_distance: f32,
    pub fall_detection: bool,
    pub collision_detection: bool,
    pub cliff_detection: bool,
    /// 解除急停需要管理者
    pub release_needs_manager: bool,
    /// 已配对的硬件急停遥控器数量（展示用）
    pub hardware_remotes: u32,
    /// 单机控制租约时长
    pub lease_term_secs: i64,
    /// 持有者无操作多久自动释放（0 = 不释放）
    pub idle_release_secs: i64,
    /// 前端（操控者）断线多久后停止其控制的设备
    pub disconnect_stop_secs: i64,
    /// 前端断线多久后释放其控制权
    pub disconnect_release_secs: i64,
}

impl Default for Policies {
    fn default() -> Self {
        Self {
            auto_dock: true,
            dock_threshold: 20.0,
            heartbeat_timeout_ms: 1500,
            lost_link_action: "stop".into(),
            lease_expiry_action: "stop_release".into(),
            speed_limit: 1.5,
            max_yaw_rate: 2.0,
            stop_near_people: true,
            min_distance: 0.8,
            fall_detection: true,
            collision_detection: true,
            cliff_detection: true,
            release_needs_manager: true,
            hardware_remotes: 0,
            lease_term_secs: 300,
            idle_release_secs: 600,
            disconnect_stop_secs: 3,
            disconnect_release_secs: 60,
        }
    }
}

impl Policies {
    fn validate(&self) -> Result<(), String> {
        let in_range = |name: &str, v: f64, lo: f64, hi: f64| {
            if v.is_finite() && (lo..=hi).contains(&v) {
                Ok(())
            } else {
                Err(format!("{name} 必须在 {lo}–{hi} 之间"))
            }
        };
        if !matches!(self.lost_link_action.as_str(), "stop" | "down" | "dock") {
            return Err("lost_link_action 只能是 stop、down、dock".into());
        }
        if !matches!(
            self.lease_expiry_action.as_str(),
            "stop_release" | "stop_only"
        ) {
            return Err("lease_expiry_action 只能是 stop_release、stop_only".into());
        }
        in_range("dock_threshold", self.dock_threshold as f64, 0.0, 100.0)?;
        in_range(
            "heartbeat_timeout_ms",
            self.heartbeat_timeout_ms as f64,
            300.0,
            60_000.0,
        )?;
        in_range("speed_limit", self.speed_limit as f64, 0.1, 5.0)?;
        in_range("max_yaw_rate", self.max_yaw_rate as f64, 0.1, 6.0)?;
        in_range("min_distance", self.min_distance as f64, 0.0, 10.0)?;
        in_range(
            "lease_term_secs",
            self.lease_term_secs as f64,
            30.0,
            86_400.0,
        )?;
        in_range(
            "idle_release_secs",
            self.idle_release_secs as f64,
            0.0,
            86_400.0,
        )?;
        in_range(
            "disconnect_stop_secs",
            self.disconnect_stop_secs as f64,
            0.0,
            600.0,
        )?;
        in_range(
            "disconnect_release_secs",
            self.disconnect_release_secs as f64,
            0.0,
            86_400.0,
        )?;
        if self.disconnect_release_secs < self.disconnect_stop_secs {
            return Err("断线释放时间不能早于断线停止时间".into());
        }
        Ok(())
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

    /// 局部更新策略：传入的字段覆盖现有值；未知字段 400
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
        policies.validate().map_err(AppError::bad_request)?;
        sqlx::query("UPDATE safety_state SET policies = $1 WHERE id = 1")
            .bind(&merged)
            .execute(db)
            .await?;
        *self.policies.write().expect("policies lock") = policies.clone();
        Ok(policies)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_valid_and_roundtrip() {
        let p = Policies::default();
        assert!(p.validate().is_ok());
        let v = serde_json::to_value(&p).unwrap();
        assert_eq!(serde_json::from_value::<Policies>(v).unwrap(), p);
    }

    #[test]
    fn rejects_bad_values() {
        let p = Policies {
            lost_link_action: "fly".into(),
            ..Default::default()
        };
        assert!(p.validate().is_err());
        let p = Policies {
            disconnect_stop_secs: 10,
            disconnect_release_secs: 5,
            ..Default::default()
        };
        assert!(p.validate().is_err());
    }
}
