//! 对讲与播报（前端交接文档 §13）。
//!
//! 播报 = 向目标设备下发 `{"kind":"action","name":"say","params":{"text"}}`，由机器人端 TTS 播放，
//! 返回实际播放成功（回执 ok）的设备数。播报不是运动指令：不需要控制权、急停中也可以播报，
//! 但要求对每台设备有「申请 / 持有控制权」权限（观察者不能播报，使用者只能播报给被授权的设备）。
//! 按住说话（双向实时音频）走 WebRTC，见 API.md §4。

use axum::{Json, extract::State};
use futures::future::join_all;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    auth::{AuthUser, Perm},
    error::{AppError, AppResult},
    protocol::Command,
    services::{
        access, audit,
        control::{self, Actor},
        settings,
    },
    state::AppState,
};

/// 播报对象：全部设备 + 各设备分组 + 单台设备
async fn targets(st: &AppState) -> AppResult<Vec<(String, String, Vec<String>)>> {
    let devices: Vec<(String, String)> =
        sqlx::query_as("SELECT id, name FROM devices ORDER BY code")
            .fetch_all(&st.db)
            .await?;
    let groups: Vec<(String, String, Vec<String>)> = sqlx::query_as(
        "SELECT g.id, g.name, COALESCE(array_agg(d.id ORDER BY d.code) FILTER (WHERE d.id IS NOT NULL), '{}')
         FROM device_groups g LEFT JOIN devices d ON d.group_id = g.id GROUP BY g.id, g.name, g.sort ORDER BY g.sort, g.name",
    )
    .fetch_all(&st.db)
    .await?;
    let mut out = vec![(
        "all".to_owned(),
        "全部设备".to_owned(),
        devices.iter().map(|(id, _)| id.clone()).collect(),
    )];
    out.extend(
        groups
            .into_iter()
            .map(|(id, name, ids)| (format!("group:{id}"), name, ids)),
    );
    out.extend(
        devices
            .into_iter()
            .map(|(id, name)| (format!("device:{id}"), name, vec![id])),
    );
    Ok(out)
}

/// GET /intercom/targets：`[{id, label, device_ids}]`，id 为 `all` / `group:<分组>` / `device:<设备>`
pub async fn list_targets(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    let out: Vec<Value> = targets(&st)
        .await?
        .into_iter()
        .map(|(id, label, ids)| json!({ "id": id, "label": label, "device_ids": ids }))
        .collect();
    Ok(Json(json!(out)))
}

pub async fn presets(State(st): State<AppState>, _user: AuthUser) -> AppResult<Json<Value>> {
    Ok(Json(
        settings::get(
            &st,
            "intercom_presets",
            json!(["请注意，设备正在通过", "请勿靠近设备", "巡检进行中，请让行"]),
        )
        .await?,
    ))
}

#[derive(Deserialize)]
pub struct Broadcast {
    pub target_id: String,
    pub text: String,
}

/// POST /intercom/broadcast `{target_id, text}` → `{played, total, failed: [{device_id, message}]}`
pub async fn broadcast(
    State(st): State<AppState>,
    user: AuthUser,
    Json(req): Json<Broadcast>,
) -> AppResult<Json<Value>> {
    let text = req.text.trim();
    if text.is_empty() || text.chars().count() > 200 {
        return Err(AppError::bad_request("播报内容需要 1–200 个字"));
    }
    let (_, label, ids) = targets(&st)
        .await?
        .into_iter()
        .find(|(id, _, _)| *id == req.target_id)
        .ok_or_else(|| AppError::not_found("播报对象不存在"))?;

    let mut allowed = Vec::new();
    let mut failed = Vec::new();
    for id in ids {
        match access::require_device(&st.db, &user, Perm::HoldLease, &id).await {
            Ok(()) => allowed.push(id),
            Err(e) => failed.push(json!({ "device_id": id, "message": e.to_string() })),
        }
    }
    if allowed.is_empty() && !failed.is_empty() {
        return Err(AppError::forbidden("你没有向这些设备播报的权限"));
    }

    let results = join_all(allowed.iter().map(|id| {
        let (st, user) = (&st, &user);
        async move {
            let cmd = Command::Action {
                name: "say".into(),
                params: json!({ "text": text }),
            };
            // 播报不是运动：走 Override，不检查控制权与急停
            let r = control::execute(st, Actor::Override(user), id, cmd, true).await;
            (id, r)
        }
    }))
    .await;
    let mut played = 0;
    for (id, r) in results {
        match r {
            Ok(r) if r.ok == Some(true) => played += 1,
            Ok(r) => failed.push(json!({
                "device_id": id,
                "message": r.message.unwrap_or_else(|| "机器人执行失败".into()),
            })),
            Err(e) => failed.push(json!({ "device_id": id, "message": e.to_string() })),
        }
    }
    audit::record(
        &st,
        &user,
        audit::Kind::Control,
        format!("向{label}播报「{text}」（{played} 台已播放）"),
        &label,
        json!({ "target_id": req.target_id, "played": played }),
    )
    .await;
    Ok(Json(json!({
        "played": played,
        "total": played + failed.len(),
        "failed": failed,
    })))
}
