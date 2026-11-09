//! 录制导出为 MCAP（Foxglove Studio 可直接打开）。
//!
//! 内容 = 服务端持久化的数据：每台设备的 1 Hz 遥测、指令日志，以及录制期间的设备事件。
//! 每个 topic 一个 JSON 通道（schema 编码 `jsonschema`，消息编码 `json`），时间戳用纳秒：
//! - `/{device_id}/telemetry`：遥测完整报文（同 WS `telemetry`，含关节温度、足端力、pose…）
//! - `/{device_id}/commands`：`{actor, command, ok, error}`
//! - `/{device_id}/events`：`{text, tone}`
//!
//! 下载链接用短时签名（HMAC-SHA256，密钥 = JWT_SECRET），浏览器 / 下载器无需带 Authorization 头。

use std::{collections::BTreeMap, io::Cursor};

use axum::{body::Body, http::header, response::Response};
use chrono::{DateTime, Utc};
use data_encoding::BASE64URL_NOPAD;
use hmac::{Hmac, KeyInit, Mac};
use serde_json::{Value, json};
use sha2::Sha256;

use crate::{
    error::{AppError, AppResult},
    models::RecordingRow,
    state::AppState,
};

/// 下载链接有效期
pub const LINK_TTL_SECS: i64 = 15 * 60;

fn sign(secret: &str, purpose: &str, exp: i64) -> String {
    let mut mac = Hmac::<Sha256>::new_from_slice(secret.as_bytes()).expect("hmac key");
    mac.update(format!("download:{purpose}:{exp}").as_bytes());
    BASE64URL_NOPAD.encode(&mac.finalize().into_bytes())
}

/// 生成下载令牌 `<过期时间戳>.<签名>`。`purpose` 标明下载的是什么（如 `recording:<id>`），换了内容签名就对不上
pub fn link_token(secret: &str, purpose: &str, now: DateTime<Utc>) -> String {
    let exp = now.timestamp() + LINK_TTL_SECS;
    format!("{exp}.{}", sign(secret, purpose, exp))
}

pub fn verify_token(secret: &str, purpose: &str, token: &str, now: DateTime<Utc>) -> bool {
    let Some((exp, sig)) = token.split_once('.') else {
        return false;
    };
    let Ok(exp) = exp.parse::<i64>() else {
        return false;
    };
    if exp < now.timestamp() {
        return false;
    }
    let expected = sign(secret, purpose, exp);
    expected.len() == sig.len()
        && expected
            .bytes()
            .zip(sig.bytes())
            .fold(0u8, |acc, (a, b)| acc | (a ^ b))
            == 0
}

/// 附件下载响应，文件名兼容中文（RFC 6266 `filename*`）
pub fn attachment(name: &str, content_type: &str, bytes: Vec<u8>) -> AppResult<Response> {
    let ascii: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_graphic() && c != '"' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let encoded: String = name
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();
    Response::builder()
        .header(header::CONTENT_TYPE, content_type)
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{encoded}"),
        )
        .body(Body::from(bytes))
        .map_err(|e| AppError::Internal(e.into()))
}

/// 文件名：录制名里的路径分隔符等替换掉
pub fn filename(r: &RecordingRow) -> String {
    let safe: String = r
        .name
        .chars()
        .map(|c| {
            if c.is_control() || "/\\:*?\"<>|".contains(c) {
                '_'
            } else {
                c
            }
        })
        .collect();
    format!(
        "{}_{}.mcap",
        safe.trim(),
        r.start_at.format("%Y%m%d-%H%M%S")
    )
}

fn nanos(t: DateTime<Utc>) -> u64 {
    t.timestamp_nanos_opt().unwrap_or(0).max(0) as u64
}

/// 指令日志一行：(设备, 时间, 操作者, 指令, 是否成功, 错误)
type CommandRow = (
    String,
    DateTime<Utc>,
    Option<String>,
    Value,
    Option<bool>,
    Option<String>,
);

const OBJECT_SCHEMA: &[u8] = br#"{"type":"object"}"#;

struct Topics<'a> {
    writer: mcap::Writer<Cursor<Vec<u8>>>,
    schema: u16,
    channels: BTreeMap<String, u16>,
    seq: u32,
    meta: &'a BTreeMap<String, String>,
}

impl Topics<'_> {
    fn write(&mut self, topic: &str, at: DateTime<Utc>, msg: &Value) -> AppResult<()> {
        let channel = match self.channels.get(topic) {
            Some(c) => *c,
            None => {
                let c = self
                    .writer
                    .add_channel(self.schema, topic, "json", self.meta)
                    .map_err(|e| AppError::Internal(e.into()))?;
                self.channels.insert(topic.to_owned(), c);
                c
            }
        };
        self.seq += 1;
        let t = nanos(at);
        self.writer
            .write_to_known_channel(
                &mcap::records::MessageHeader {
                    channel_id: channel,
                    sequence: self.seq,
                    log_time: t,
                    publish_time: t,
                },
                msg.to_string().as_bytes(),
            )
            .map_err(|e| AppError::Internal(e.into()))
    }
}

/// 生成整段录制的 MCAP 文件
pub async fn build_mcap(st: &AppState, r: &RecordingRow) -> AppResult<Vec<u8>> {
    let telemetry: Vec<(String, DateTime<Utc>, Value)> = sqlx::query_as(
        "SELECT device_id, ts, data FROM telemetry
         WHERE device_id = ANY($1) AND ts >= $2 AND ts <= $3 ORDER BY ts",
    )
    .bind(&r.device_ids)
    .bind(r.start_at)
    .bind(r.end_at)
    .fetch_all(&st.db)
    .await?;
    let commands: Vec<CommandRow> =
        sqlx::query_as(
            "SELECT device_id, created_at, actor_name, command, ok, error FROM command_log
             WHERE device_id = ANY($1) AND created_at >= $2 AND created_at <= $3 ORDER BY created_at",
        )
        .bind(&r.device_ids)
        .bind(r.start_at)
        .bind(r.end_at)
        .fetch_all(&st.db)
        .await?;
    let events: Vec<(String, DateTime<Utc>, String, String)> = sqlx::query_as(
        "SELECT device_id, at, text, tone FROM device_events
         WHERE device_id = ANY($1) AND at >= $2 AND at <= $3 ORDER BY at",
    )
    .bind(&r.device_ids)
    .bind(r.start_at)
    .bind(r.end_at)
    .fetch_all(&st.db)
    .await?;

    let meta = BTreeMap::from([
        ("recording_id".to_owned(), r.id.to_string()),
        ("recording_name".to_owned(), r.name.clone()),
    ]);
    let mut writer =
        mcap::Writer::new(Cursor::new(Vec::new())).map_err(|e| AppError::Internal(e.into()))?;
    let schema = writer
        .add_schema("uniconsole.Json", "jsonschema", OBJECT_SCHEMA)
        .map_err(|e| AppError::Internal(e.into()))?;
    let mut t = Topics {
        writer,
        schema,
        channels: BTreeMap::new(),
        seq: 0,
        meta: &meta,
    };

    // 按时间合并三类消息，MCAP 里保持时间顺序
    let mut all: Vec<(DateTime<Utc>, String, Value)> =
        Vec::with_capacity(telemetry.len() + commands.len() + events.len());
    all.extend(
        telemetry
            .into_iter()
            .map(|(d, ts, data)| (ts, format!("/{d}/telemetry"), data)),
    );
    all.extend(commands.into_iter().map(|(d, at, actor, cmd, ok, err)| {
        (
            at,
            format!("/{d}/commands"),
            json!({ "actor": actor, "command": cmd, "ok": ok, "error": err }),
        )
    }));
    all.extend(events.into_iter().map(|(d, at, text, tone)| {
        (
            at,
            format!("/{d}/events"),
            json!({ "text": text, "tone": tone }),
        )
    }));
    all.sort_by_key(|(at, _, _)| *at);
    for (at, topic, msg) in &all {
        t.write(topic, *at, msg)?;
    }
    t.writer
        .finish()
        .map_err(|e| AppError::Internal(e.into()))?;
    Ok(t.writer.into_inner().into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn link_tokens() {
        let now = Utc::now();
        let tok = link_token("secret", "recording:1", now);
        assert!(verify_token("secret", "recording:1", &tok, now));
        assert!(!verify_token("other", "recording:1", &tok, now));
        assert!(!verify_token("secret", "recording:2", &tok, now));
        assert!(!verify_token(
            "secret",
            "recording:1",
            &tok,
            now + chrono::Duration::seconds(LINK_TTL_SECS + 1)
        ));
        assert!(!verify_token("secret", "recording:1", "garbage", now));
    }
}
