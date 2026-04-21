pub mod anthropic;
pub mod openrouter;
pub mod provider;

use async_trait::async_trait;

use crate::config::{ModelConfig, Provider};
use crate::error::LlmError;

pub use anthropic::AnthropicProvider;
pub use openrouter::OpenRouterProvider;
pub use provider::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, LlmProvider, Pricing, ProviderFactory, Usage,
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
                model_config.api_key_env.clone(),
            ))),
            Provider::Openrouter => Ok(Box::new(
                OpenRouterProvider::new(self.client.clone(), model_config.api_key_env.clone())
                    .await,
            )),
        }
    }
}
