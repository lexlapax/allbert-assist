use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::config::ModelConfig;
use crate::error::LlmError;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ChatRole {
    User,
    Assistant,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: ChatRole,
    pub content: String,
}

#[derive(Debug, Clone)]
pub struct CompletionRequest {
    pub system: Option<String>,
    pub messages: Vec<ChatMessage>,
    pub model: String,
    pub max_tokens: u32,
}

#[derive(Debug, Clone, Default)]
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
}

#[async_trait]
pub trait ProviderFactory: Send + Sync {
    async fn build(&self, model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError>;
}
