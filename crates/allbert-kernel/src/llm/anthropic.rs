use std::collections::HashMap;

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::error::LlmError;

use super::provider::{
    ChatMessage, CompletionRequest, CompletionResponse, LlmProvider, Pricing, Usage,
};

const MESSAGES_URL: &str = "https://api.anthropic.com/v1/messages";

pub struct AnthropicProvider {
    client: reqwest::Client,
    api_key_env: String,
    pricing_table: HashMap<String, Pricing>,
}

impl AnthropicProvider {
    pub fn new(client: reqwest::Client, api_key_env: String) -> Self {
        Self {
            client,
            api_key_env,
            pricing_table: anthropic_pricing_table(),
        }
    }

    fn api_key(&self) -> Result<String, LlmError> {
        std::env::var(&self.api_key_env)
            .map_err(|_| LlmError::MissingApiKeyEnv(self.api_key_env.clone()))
    }
}

#[async_trait]
impl LlmProvider for AnthropicProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let api_key = self.api_key()?;
        let body = AnthropicRequest {
            model: req.model,
            max_tokens: req.max_tokens,
            system: req.system,
            messages: req
                .messages
                .into_iter()
                .map(AnthropicMessage::from)
                .collect(),
        };

        let response = self
            .client
            .post(MESSAGES_URL)
            .header("x-api-key", api_key)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|err| LlmError::Http(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(LlmError::Response(format!(
                "anthropic status {}: {}",
                status, body
            )));
        }

        let parsed: AnthropicResponse = response
            .json()
            .await
            .map_err(|err| LlmError::Response(err.to_string()))?;

        let text = parsed
            .content
            .into_iter()
            .filter(|block| block.kind == "text")
            .filter_map(|block| block.text)
            .collect::<Vec<_>>()
            .join("\n\n");

        Ok(CompletionResponse {
            text,
            usage: Usage {
                input_tokens: parsed.usage.input_tokens,
                output_tokens: parsed.usage.output_tokens,
                cache_read: parsed.usage.cache_read_input_tokens,
                cache_create: parsed.usage.cache_creation_input_tokens,
            },
        })
    }

    fn pricing(&self, model: &str) -> Option<Pricing> {
        self.pricing_table.get(model).copied()
    }

    fn provider_name(&self) -> &'static str {
        "anthropic"
    }
}

#[derive(Serialize)]
struct AnthropicRequest {
    model: String,
    max_tokens: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    system: Option<String>,
    messages: Vec<AnthropicMessage>,
}

#[derive(Serialize)]
struct AnthropicMessage {
    role: &'static str,
    content: String,
}

impl From<ChatMessage> for AnthropicMessage {
    fn from(value: ChatMessage) -> Self {
        let role = match value.role {
            super::provider::ChatRole::User => "user",
            super::provider::ChatRole::Assistant => "assistant",
        };
        Self {
            role,
            content: value.content,
        }
    }
}

#[derive(Deserialize)]
struct AnthropicResponse {
    content: Vec<AnthropicContentBlock>,
    usage: AnthropicUsage,
}

#[derive(Deserialize)]
struct AnthropicContentBlock {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
struct AnthropicUsage {
    input_tokens: u64,
    output_tokens: u64,
    #[serde(default)]
    cache_read_input_tokens: u64,
    #[serde(default)]
    cache_creation_input_tokens: u64,
}

fn anthropic_pricing_table() -> HashMap<String, Pricing> {
    let mut table = HashMap::new();
    table.insert(
        "claude-sonnet-4-20250514".into(),
        pricing_per_mtok(3.0, 15.0, 0.30, 3.75),
    );
    table.insert(
        "claude-sonnet-4-0".into(),
        pricing_per_mtok(3.0, 15.0, 0.30, 3.75),
    );
    table.insert(
        "claude-3-7-sonnet-20250219".into(),
        pricing_per_mtok(3.0, 15.0, 0.30, 3.75),
    );
    table.insert(
        "claude-3-7-sonnet-latest".into(),
        pricing_per_mtok(3.0, 15.0, 0.30, 3.75),
    );
    table.insert(
        "claude-3-5-haiku-20241022".into(),
        pricing_per_mtok(0.80, 4.0, 0.08, 1.0),
    );
    table.insert(
        "claude-3-5-haiku-latest".into(),
        pricing_per_mtok(0.80, 4.0, 0.08, 1.0),
    );
    table.insert(
        "claude-opus-4-20250514".into(),
        pricing_per_mtok(15.0, 75.0, 1.50, 18.75),
    );
    table.insert(
        "claude-opus-4-0".into(),
        pricing_per_mtok(15.0, 75.0, 1.50, 18.75),
    );
    table
}

fn pricing_per_mtok(prompt: f64, completion: f64, cache_read: f64, cache_write: f64) -> Pricing {
    Pricing {
        prompt_per_token_usd: prompt / 1_000_000.0,
        completion_per_token_usd: completion / 1_000_000.0,
        cache_read_per_token_usd: cache_read / 1_000_000.0,
        cache_create_per_token_usd: cache_write / 1_000_000.0,
        request_usd: 0.0,
    }
}
