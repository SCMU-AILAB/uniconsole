//! 发信（注册验证码、新成员提醒）。
//!
//! `SMTP_URL` 指向发信服务器，例如：
//! - `smtp://127.0.0.1:25`：本机 Postfix（推荐，由 Postfix 排队重试并经中继发出，见 deploy/mail.md）；
//! - `smtp://user:pass@smtp.example.com:587?tls=required`：直连带 STARTTLS 的中继；
//! - `smtps://user:pass@smtp.example.com:465`：直连 SMTPS。
//!
//! 未配置 `SMTP_URL` 时不发信，只把邮件内容写进日志（仅限开发环境）。

use anyhow::Context;
use lettre::{
    AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor,
    message::{Mailbox, header::ContentType},
};

use crate::{
    config::Config,
    error::{AppError, AppResult},
};

pub struct Mailer {
    transport: Option<AsyncSmtpTransport<Tokio1Executor>>,
    from: Mailbox,
}

impl Mailer {
    pub fn from_config(cfg: &Config) -> anyhow::Result<Self> {
        let from: Mailbox = cfg
            .mail_from
            .parse()
            .with_context(|| format!("MAIL_FROM「{}」不是有效的发件人", cfg.mail_from))?;
        let transport = match &cfg.smtp_url {
            Some(url) => Some(
                AsyncSmtpTransport::<Tokio1Executor>::from_url(url)
                    .context("SMTP_URL 无效")?
                    .timeout(Some(std::time::Duration::from_secs(15)))
                    .build(),
            ),
            None => {
                tracing::warn!("SMTP_URL 未设置：邮件只写进日志，不会真正发出（仅限开发环境）");
                None
            }
        };
        Ok(Self { transport, from })
    }

    /// 发送纯文本邮件。发送失败返回 502（给人看的提示），细节写日志
    pub async fn send(&self, to: &str, subject: &str, body: String) -> AppResult<()> {
        let to_box: Mailbox = to
            .parse()
            .map_err(|_| AppError::bad_request("邮箱格式不正确"))?;
        let Some(transport) = &self.transport else {
            tracing::warn!(to, subject, body, "（未配置 SMTP）邮件未发送");
            return Ok(());
        };
        let msg = Message::builder()
            .from(self.from.clone())
            .to(to_box)
            .subject(subject)
            .header(ContentType::TEXT_PLAIN)
            .body(body)
            .map_err(|e| AppError::Internal(e.into()))?;
        transport.send(msg).await.map_err(|e| {
            tracing::warn!(error = %e, to, "邮件发送失败");
            AppError::Upstream("邮件发送失败，请稍后再试".into())
        })?;
        Ok(())
    }
}
