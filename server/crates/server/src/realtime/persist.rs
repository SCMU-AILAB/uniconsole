//! 遥测批量入库：机器人连接任务把抽样后的帧放进队列，这里每秒批量 INSERT 一次，
//! 避免高频单条写入压垮数据库。队列满时直接丢弃（实时链路优先）。

use std::time::Duration;

use sqlx::{PgPool, Postgres, QueryBuilder};
use tokio::sync::mpsc;

use crate::protocol::Telemetry;

pub struct TelemetrySample {
    pub device_id: String,
    pub data: Telemetry,
}

const QUEUE: usize = 10_000;
const MAX_BATCH: usize = 1_000;

pub fn spawn_telemetry_writer(db: PgPool) -> mpsc::Sender<TelemetrySample> {
    let (tx, mut rx) = mpsc::channel::<TelemetrySample>(QUEUE);
    tokio::spawn(async move {
        let mut buf = Vec::with_capacity(MAX_BATCH);
        let mut tick = tokio::time::interval(Duration::from_secs(1));
        loop {
            tokio::select! {
                n = rx.recv_many(&mut buf, MAX_BATCH) => {
                    if n == 0 { break; } // 所有发送端已关闭
                    if buf.len() < MAX_BATCH { continue; }
                }
                _ = tick.tick() => {}
            }
            if buf.is_empty() {
                continue;
            }
            if let Err(e) = flush(&db, &buf).await {
                tracing::warn!(error = %e, rows = buf.len(), "遥测入库失败");
            }
            buf.clear();
        }
        if !buf.is_empty() {
            let _ = flush(&db, &buf).await;
        }
    });
    tx
}

async fn flush(db: &PgPool, rows: &[TelemetrySample]) -> sqlx::Result<()> {
    let mut qb: QueryBuilder<Postgres> = QueryBuilder::new(
        "INSERT INTO telemetry (device_id, ts, battery, vx, vy, wz, roll, pitch, yaw, voltage, current, max_motor_temp, data) ",
    );
    qb.push_values(rows, |mut b, s| {
        let t = &s.data;
        b.push_bind(&s.device_id)
            .push_bind(t.ts)
            .push_bind(t.battery)
            .push_bind(t.vx)
            .push_bind(t.vy)
            .push_bind(t.wz)
            .push_bind(t.roll)
            .push_bind(t.pitch)
            .push_bind(t.yaw)
            .push_bind(t.voltage)
            .push_bind(t.current)
            .push_bind(t.max_motor_temp())
            .push_bind(serde_json::to_value(t).unwrap_or_default());
    });
    qb.push(" ON CONFLICT DO NOTHING");
    qb.build().execute(db).await?;
    Ok(())
}
