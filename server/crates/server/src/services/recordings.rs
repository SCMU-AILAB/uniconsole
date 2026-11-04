//! 录制：基于服务端持久化的遥测（1 Hz）与指令日志。视频 / 点云需要机器人端录制，暂不包含。

use chrono::{DateTime, Utc};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{error::AppResult, models::RecordingRow, protocol::ServerEvent, state::AppState};

/// 自动录制（告警前后 60 秒、联调会话），返回录制 id
pub async fn auto_record(
    st: &AppState,
    name: &str,
    device_ids: &[String],
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    tag: &str,
    source_id: &str,
) -> AppResult<Uuid> {
    let id: Uuid = sqlx::query_scalar(
        "INSERT INTO recordings (name, device_ids, start_at, end_at, tags, source_id)
         VALUES ($1, $2, $3, $4, ARRAY[$5], $6) RETURNING id",
    )
    .bind(name)
    .bind(device_ids)
    .bind(start)
    .bind(end)
    .bind(tag)
    .bind(source_id)
    .fetch_one(&st.db)
    .await?;
    st.hub.publish(ServerEvent::changed("recordings", Some(id)));
    Ok(id)
}

const BUCKETS: i32 = 100;

fn segments(buckets: &[i32]) -> Vec<[f64; 2]> {
    let mut out: Vec<[f64; 2]> = Vec::new();
    let mut sorted = buckets.to_vec();
    sorted.sort_unstable();
    for b in sorted {
        let (lo, hi) = ((b - 1) as f64 / BUCKETS as f64, b as f64 / BUCKETS as f64);
        match out.last_mut() {
            Some(last) if (last[1] - lo).abs() < 1e-9 => last[1] = hi,
            _ => out.push([lo, hi]),
        }
    }
    out
}

async fn track(
    st: &AppState,
    r: &RecordingRow,
    table: &str,
    ts_col: &str,
) -> AppResult<Vec<[f64; 2]>> {
    let sql = format!(
        "SELECT DISTINCT width_bucket(extract(epoch FROM {ts_col}), extract(epoch FROM $2::timestamptz),
                                      extract(epoch FROM $3::timestamptz), {BUCKETS})::int
         FROM {table} WHERE device_id = ANY($1) AND {ts_col} BETWEEN $2 AND $3"
    );
    let b: Vec<i32> = sqlx::query_scalar(sqlx::AssertSqlSafe(sql))
        .bind(&r.device_ids)
        .bind(r.start_at)
        .bind(r.end_at)
        .fetch_all(&st.db)
        .await?;
    Ok(segments(
        &b.into_iter()
            .filter(|x| (1..=BUCKETS).contains(x))
            .collect::<Vec<_>>(),
    ))
}

/// 列表 / 详情的对外形状
pub async fn view(st: &AppState, r: RecordingRow) -> AppResult<Value> {
    let joints = track(st, &r, "telemetry", "ts").await?;
    let commands = track(st, &r, "command_log", "created_at").await?;
    let size: i64 = sqlx::query_scalar(
        "SELECT COALESCE(sum(pg_column_size(t.*)), 0)::bigint FROM telemetry t
         WHERE device_id = ANY($1) AND ts BETWEEN $2 AND $3",
    )
    .bind(&r.device_ids)
    .bind(r.start_at)
    .bind(r.end_at)
    .fetch_one(&st.db)
    .await?;
    let events: Vec<(i64, String, String)> = sqlx::query_as(
        "SELECT (extract(epoch FROM created_at - $2) * 1000)::bigint, title, severity::text
         FROM alerts WHERE device_id = ANY($1) AND created_at BETWEEN $2 AND $3 ORDER BY created_at",
    )
    .bind(&r.device_ids)
    .bind(r.start_at)
    .bind(r.end_at)
    .fetch_all(&st.db)
    .await?;
    let mut tracks = Vec::new();
    if !joints.is_empty() {
        tracks.push(json!({ "kind": "joints", "segments": joints }));
    }
    if !commands.is_empty() {
        tracks.push(json!({ "kind": "commands", "segments": commands }));
    }
    let mut v = serde_json::to_value(&r).map_err(anyhow::Error::from)?;
    v["size_bytes"] = json!(size);
    v["tracks"] = json!(tracks);
    v["streams"] = json!("关节 / IMU / 电量 / 指令（视频与点云需机器人端录制）");
    v["events"] = json!(
        events
            .into_iter()
            .map(|(ms, label, sev)| json!({ "offset_ms": ms, "label": label, "tone": sev }))
            .collect::<Vec<_>>()
    );
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::segments;

    #[test]
    fn contiguous_buckets_merge() {
        assert_eq!(segments(&[1, 2, 3, 10]), vec![[0.0, 0.03], [0.09, 0.1]]);
        assert!(segments(&[]).is_empty());
    }
}
