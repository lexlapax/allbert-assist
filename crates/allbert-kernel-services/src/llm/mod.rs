pub mod anthropic;
pub mod gemini;
pub mod ollama;
pub mod openai;
pub mod openrouter;
pub mod provider;

use async_trait::async_trait;

use crate::config::{ModelConfig, Provider};
use crate::error::LlmError;

pub use anthropic::AnthropicProvider;
pub use gemini::GeminiProvider;
pub use ollama::OllamaProvider;
pub use openai::OpenAiProvider;
pub use openrouter::OpenRouterProvider;
pub use provider::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, LlmProvider, Pricing, ProviderFactory, ToolCallSpan, ToolDeclaration,
    Usage,
};

#[derive(Clone)]
pub struct DefaultProviderFactory {
    client: reqwest::Client,
}

impl Default for DefaultProviderFactory {
    fn default() -> Self {
        Self {
            client: reqwest::Client::new(),
        }
    }
}

#[async_trait]
impl ProviderFactory for DefaultProviderFactory {
    async fn build(&self, model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
        match model_config.provider {
            Provider::Anthropic => Ok(Box::new(AnthropicProvider::new(
                self.client.clone(),
                api_key_env_or_default(model_config)?,
            ))),
            Provider::Openrouter => Ok(Box::new(
                OpenRouterProvider::new(self.client.clone(), api_key_env_or_default(model_config)?)
                    .await,
            )),
            Provider::Openai => Ok(Box::new(OpenAiProvider::new(
                self.client.clone(),
                api_key_env_or_default(model_config)?,
                model_config.base_url.clone(),
            ))),
            Provider::Gemini => Ok(Box::new(GeminiProvider::new(
                self.client.clone(),
                api_key_env_or_default(model_config)?,
                model_config.base_url.clone(),
            ))),
            Provider::Ollama => Ok(Box::new(OllamaProvider::new(
                self.client.clone(),
                model_config
                    .base_url
                    .clone()
                    .or_else(|| model_config.provider.default_base_url().map(str::to_string)),
            ))),
        }
    }
}

fn api_key_env_or_default(model_config: &ModelConfig) -> Result<String, LlmError> {
    model_config
        .api_key_env
        .clone()
        .or_else(|| {
            model_config
                .provider
                .default_api_key_env()
                .map(str::to_string)
        })
        .ok_or_else(|| {
            LlmError::UnsupportedProvider(format!(
                "{} requires an API key env",
                model_config.provider.label()
            ))
        })
}
