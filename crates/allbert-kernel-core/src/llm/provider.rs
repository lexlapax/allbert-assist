use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::config::ModelConfig;
use crate::error::LlmError;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ChatAttachmentKind {
    Image,
    File,
    Audio,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatAttachment {
    pub kind: ChatAttachmentKind,
    pub path: PathBuf,
    #[serde(default)]
    pub mime_type: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
    #[serde(default)]
    pub attachments: Vec<ChatAttachment>,
}

#[derive(Debug, Clone)]
pub struct CompletionRequest {
    pub system: Option<String>,
    pub messages: Vec<ChatMessage>,
    pub model: String,
    pub max_tokens: u32,
    pub tools: Vec<ToolDeclaration>,
    pub response_format: CompletionResponseFormat,
    pub temperature: Option<f32>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum CompletionResponseFormat {
    #[default]
    Text,
    JsonSchema {
        name: String,
        schema: serde_json::Value,
        strict: bool,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ToolDeclaration {
    pub name: String,
    pub description: String,
    pub schema: serde_json::Value,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct Usage {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_read: u64,
    pub cache_create: u64,
}

#[derive(Debug, Clone)]
pub struct CompletionResponse {
    pub text: String,
    pub usage: Usage,
    pub tool_calls: Vec<ToolCallSpan>,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct ToolCallSpan {
    pub call_id: String,
    pub name: String,
    pub input: serde_json::Value,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pricing {
    pub prompt_per_token_usd: f64,
    pub completion_per_token_usd: f64,
    pub cache_read_per_token_usd: f64,
    pub cache_create_per_token_usd: f64,
    pub request_usd: f64,
}

#[async_trait]
pub trait LlmProvider: Send + Sync {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError>;
    fn pricing(&self, model: &str) -> Option<Pricing>;
    fn provider_name(&self) -> &'static str;
    fn supports_image_input(&self, _model: &str) -> bool {
        false
    }
}

#[async_trait]
pub trait ProviderFactory: Send + Sync {
    async fn build(&self, model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError>;
}
