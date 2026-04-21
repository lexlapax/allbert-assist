use std::path::PathBuf;
use std::sync::Arc;

use allbert_proto::ChannelKind;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LatencyClass {
    Synchronous,
    Asynchronous,
    Batch,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelCapabilities {
    pub supports_inline_confirm: bool,
    pub supports_async_confirm: bool,
    pub supports_rich_output: bool,
    pub supports_file_attach: bool,
    pub supports_image_input: bool,
    pub supports_image_output: bool,
    pub supports_voice_input: bool,
    pub supports_voice_output: bool,
    pub supports_audio_attach: bool,
    pub max_message_size: usize,
    pub latency_class: LatencyClass,
}

impl ChannelCapabilities {
    pub fn for_builtin(kind: ChannelKind) -> Self {
        match kind {
            ChannelKind::Cli | ChannelKind::Repl => Self {
                supports_inline_confirm: true,
                supports_async_confirm: false,
                supports_rich_output: false,
                supports_file_attach: false,
                supports_image_input: false,
                supports_image_output: false,
                supports_voice_input: false,
                supports_voice_output: false,
                supports_audio_attach: false,
                max_message_size: usize::MAX,
                latency_class: LatencyClass::Synchronous,
            },
            ChannelKind::Jobs => Self {
                supports_inline_confirm: false,
                supports_async_confirm: false,
                supports_rich_output: false,
                supports_file_attach: false,
                supports_image_input: false,
                supports_image_output: false,
                supports_voice_input: false,
                supports_voice_output: false,
                supports_audio_attach: false,
                max_message_size: 0,
                latency_class: LatencyClass::Batch,
            },
            ChannelKind::Telegram => Self {
                supports_inline_confirm: false,
                supports_async_confirm: true,
                supports_rich_output: true,
                supports_file_attach: true,
                supports_image_input: true,
                supports_image_output: false,
                supports_voice_input: false,
                supports_voice_output: false,
                supports_audio_attach: false,
                max_message_size: 4096,
                latency_class: LatencyClass::Asynchronous,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelAttachment {
    pub kind: AttachmentKind,
    pub path: PathBuf,
    pub mime_type: Option<String>,
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AttachmentKind {
    File,
    Image,
    Audio,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelInbound {
    pub sender_id: String,
    pub text: Option<String>,
    pub attachments: Vec<ChannelAttachment>,
    pub message_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChannelOutbound {
    pub text: Option<String>,
    pub attachments: Vec<ChannelAttachment>,
    pub reply_to_message_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConfirmPrompt {
    pub request_id: Option<String>,
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub rendered: String,
    pub expires_at: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConfirmOutcome {
    Deny,
    AllowOnce,
    AllowSession,
    Timeout,
}

#[derive(Debug, Error)]
pub enum ChannelError {
    #[error("channel operation not supported: {0}")]
    Unsupported(&'static str),
    #[error("channel disconnected")]
    Disconnected,
    #[error("{0}")]
    Message(String),
}

#[async_trait]
pub trait Channel: Send + Sync {
    fn kind(&self) -> ChannelKind;
    fn capabilities(&self) -> ChannelCapabilities;

    async fn receive(&self) -> Result<ChannelInbound, ChannelError>;
    async fn send(&self, out: ChannelOutbound) -> Result<(), ChannelError>;
    async fn confirm(&self, prompt: ConfirmPrompt) -> Result<ConfirmOutcome, ChannelError>;
    async fn shutdown(self: Arc<Self>) -> Result<(), ChannelError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_repl_and_cli_channels_are_inline_and_synchronous() {
        for kind in [ChannelKind::Cli, ChannelKind::Repl] {
            let caps = ChannelCapabilities::for_builtin(kind);
            assert!(caps.supports_inline_confirm);
            assert!(!caps.supports_async_confirm);
            assert_eq!(caps.latency_class, LatencyClass::Synchronous);
        }
    }

    #[test]
    fn builtin_jobs_channel_is_batch_and_fail_closed() {
        let caps = ChannelCapabilities::for_builtin(ChannelKind::Jobs);
        assert!(!caps.supports_inline_confirm);
        assert!(!caps.supports_async_confirm);
        assert_eq!(caps.latency_class, LatencyClass::Batch);
    }

    #[test]
    fn telegram_pilot_capabilities_match_v0_7_contract() {
        let caps = ChannelCapabilities::for_builtin(ChannelKind::Telegram);
        assert!(caps.supports_async_confirm);
        assert!(caps.supports_rich_output);
        assert!(caps.supports_file_attach);
        assert!(caps.supports_image_input);
        assert_eq!(caps.max_message_size, 4096);
        assert_eq!(caps.latency_class, LatencyClass::Asynchronous);
    }
}
