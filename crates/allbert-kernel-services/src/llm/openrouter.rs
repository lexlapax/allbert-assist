use std::collections::{HashMap, HashSet};

use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use serde::{Deserialize, Serialize};

use crate::error::LlmError;

use super::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, LlmProvider, Pricing, Usage,
};

const CHAT_COMPLETIONS_URL: &str = "https://openrouter.ai/api/v1/chat/completions";
const MODELS_URL: &str = "https://openrouter.ai/api/v1/models";

pub struct OpenRouterProvider {
    client: reqwest::Client,
    api_key_env: String,
    chat_completions_url: String,
    pricing_table: HashMap<String, Pricing>,
    image_input_models: HashSet<String>,
}

impl OpenRouterProvider {
    pub async fn new(client: reqwest::Client, api_key_env: String) -> Self {
        Self::new_with_urls(
            client,
            api_key_env,
            std::env::var("OPENROUTER_API_KEY_BOOTSTRAP").ok(),
            CHAT_COMPLETIONS_URL.into(),
            MODELS_URL.into(),
        )
        .await
    }

    pub(crate) async fn new_with_urls(
        client: reqwest::Client,
        api_key_env: String,
        bootstrap_api_key: Option<String>,
        chat_completions_url: String,
        models_url: String,
    ) -> Self {
        let fallback = fallback_pricing_table();
        let api_key = bootstrap_api_key.or_else(|| std::env::var(&api_key_env).ok());
        let (pricing_table, image_input_models) = if let Some(api_key) = api_key {
            match fetch_live_catalog(&client, &api_key, &models_url).await {
                Ok(catalog) => (catalog.pricing_table, catalog.image_input_models),
                Err(err) => {
                    tracing::warn!(
                        "openrouter metadata unavailable, using fallback pricing and empty modality catalog: {err}"
                    );
                    (fallback, HashSet::new())
                }
            }
        } else {
            tracing::warn!(
                "openrouter metadata unavailable at boot because {} is unset; using fallback pricing",
                api_key_env
            );
            (fallback, HashSet::new())
        };

        Self {
            client,
            api_key_env,
            chat_completions_url,
            pricing_table,
            image_input_models,
        }
    }

    fn api_key(&self) -> Result<String, LlmError> {
        std::env::var(&self.api_key_env)
            .map_err(|_| LlmError::MissingApiKeyEnv(self.api_key_env.clone()))
    }
}

#[async_trait]
impl LlmProvider for OpenRouterProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let api_key = self.api_key()?;
        let mut messages = Vec::new();
        if let Some(system) = req.system {
            messages.push(OpenRouterMessage {
                role: "system".into(),
                content: OpenRouterContent::Text(system),
            });
        }
        messages.extend(
            req.messages
                .into_iter()
                .map(OpenRouterMessage::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        );

        let response = self
            .client
            .post(&self.chat_completions_url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("Content-Type", "application/json")
            .json(&OpenRouterRequest {
                model: req.model,
                max_tokens: req.max_tokens,
                messages,
            })
            .send()
            .await
            .map_err(|err| LlmError::Http(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(LlmError::Response(format!(
                "openrouter status {}: {}",
                status, body
            )));
        }

        let parsed: OpenRouterResponse = response
            .json()
            .await
            .map_err(|err| LlmError::Response(err.to_string()))?;

        let choice = parsed
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| LlmError::Response("openrouter response missing choices".into()))?;

        Ok(CompletionResponse {
            text: choice.message.content.into_text(),
            usage: Usage {
                input_tokens: parsed.usage.as_ref().map(|u| u.prompt_tokens).unwrap_or(0),
                output_tokens: parsed
                    .usage
                    .as_ref()
                    .map(|u| u.completion_tokens)
                    .unwrap_or(0),
                cache_read: 0,
                cache_create: 0,
            },
            tool_calls: Vec::new(),
        })
    }

    fn pricing(&self, model: &str) -> Option<Pricing> {
        self.pricing_table.get(model).copied()
    }

    fn provider_name(&self) -> &'static str {
        "openrouter"
    }

    fn supports_image_input(&self, model: &str) -> bool {
        self.image_input_models.contains(model)
    }
}

#[derive(Serialize)]
struct OpenRouterRequest {
    model: String,
    max_tokens: u32,
    messages: Vec<OpenRouterMessage>,
}

#[derive(Serialize)]
struct OpenRouterMessage {
    role: String,
    content: OpenRouterContent,
}

impl TryFrom<ChatMessage> for OpenRouterMessage {
    type Error = LlmError;

    fn try_from(value: ChatMessage) -> Result<Self, Self::Error> {
        let role = match value.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "assistant",
        };
        let content = if value.attachments.is_empty() {
            OpenRouterContent::Text(value.content)
        } else {
            let mut parts = Vec::new();
            if !value.content.trim().is_empty() {
                parts.push(OpenRouterContentPart::Text {
                    text: value.content.clone(),
                });
            }
            for attachment in value.attachments {
                parts.push(OpenRouterContentPart::ImageUrl {
                    image_url: OpenRouterImageUrl {
                        url: attachment_data_url(&attachment)?,
                    },
                });
            }
            OpenRouterContent::Parts(parts)
        };
        Ok(Self {
            role: role.into(),
            content,
        })
    }
}

#[derive(Serialize)]
#[serde(untagged)]
enum OpenRouterContent {
    Text(String),
    Parts(Vec<OpenRouterContentPart>),
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OpenRouterContentPart {
    Text { text: String },
    ImageUrl { image_url: OpenRouterImageUrl },
}

#[derive(Serialize)]
struct OpenRouterImageUrl {
    url: String,
}

#[derive(Deserialize)]
struct OpenRouterResponse {
    choices: Vec<OpenRouterChoice>,
    usage: Option<OpenRouterUsage>,
}

#[derive(Deserialize)]
struct OpenRouterChoice {
    message: OpenRouterAssistantMessage,
}

#[derive(Deserialize)]
struct OpenRouterAssistantMessage {
    #[serde(default)]
    content: OpenRouterAssistantContent,
}

#[derive(Default, Deserialize)]
#[serde(untagged)]
enum OpenRouterAssistantContent {
    #[default]
    Missing,
    Text(String),
    Parts(Vec<OpenRouterAssistantContentPart>),
}

impl OpenRouterAssistantContent {
    fn into_text(self) -> String {
        match self {
            Self::Missing => String::new(),
            Self::Text(value) => value,
            Self::Parts(parts) => parts
                .into_iter()
                .filter_map(|part| match part {
                    OpenRouterAssistantContentPart::Text { text } => Some(text),
                    OpenRouterAssistantContentPart::Other => None,
                })
                .collect::<Vec<_>>()
                .join("\n\n"),
        }
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OpenRouterAssistantContentPart {
    Text {
        text: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct OpenRouterUsage {
    prompt_tokens: u64,
    completion_tokens: u64,
}

#[derive(Deserialize)]
struct OpenRouterModelsResponse {
    data: Vec<OpenRouterModel>,
}

#[derive(Deserialize)]
struct OpenRouterModel {
    id: String,
    #[serde(default)]
    canonical_slug: Option<String>,
    #[serde(default)]
    architecture: Option<OpenRouterArchitecture>,
    pricing: OpenRouterPricing,
}

#[derive(Deserialize)]
struct OpenRouterPricing {
    prompt: String,
    completion: String,
    #[serde(default)]
    request: String,
    #[serde(default)]
    input_cache_read: String,
    #[serde(default)]
    input_cache_write: String,
}

#[derive(Default)]
struct OpenRouterCatalog {
    pricing_table: HashMap<String, Pricing>,
    image_input_models: HashSet<String>,
}

#[derive(Deserialize, Default)]
struct OpenRouterArchitecture {
    #[serde(default)]
    input_modalities: Vec<String>,
}

async fn fetch_live_catalog(
    client: &reqwest::Client,
    api_key: &str,
    models_url: &str,
) -> Result<OpenRouterCatalog, LlmError> {
    let response = client
        .get(models_url)
        .header("Authorization", format!("Bearer {api_key}"))
        .send()
        .await
        .map_err(|err| LlmError::Http(err.to_string()))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(LlmError::Response(format!(
            "openrouter models status {}: {}",
            status, body
        )));
    }

    let parsed: OpenRouterModelsResponse = response
        .json()
        .await
        .map_err(|err| LlmError::Response(err.to_string()))?;

    let mut catalog = OpenRouterCatalog::default();
    for model in parsed.data {
        if let Some(pricing) = parse_pricing(model.pricing) {
            catalog.pricing_table.insert(model.id.clone(), pricing);
        }
        if model_supports_image_input(model.architecture.as_ref()) {
            catalog.image_input_models.insert(model.id.clone());
            if let Some(slug) = model.canonical_slug {
                catalog.image_input_models.insert(slug);
            }
        }
    }
    Ok(catalog)
}

fn model_supports_image_input(architecture: Option<&OpenRouterArchitecture>) -> bool {
    architecture
        .map(|value| {
            value
                .input_modalities
                .iter()
                .any(|modality| modality.eq_ignore_ascii_case("image"))
        })
        .unwrap_or(false)
}

fn parse_pricing(pricing: OpenRouterPricing) -> Option<Pricing> {
    Some(Pricing {
        prompt_per_token_usd: pricing.prompt.parse().ok()?,
        completion_per_token_usd: pricing.completion.parse().ok()?,
        cache_read_per_token_usd: parse_optional_decimal(&pricing.input_cache_read),
        cache_create_per_token_usd: parse_optional_decimal(&pricing.input_cache_write),
        request_usd: parse_optional_decimal(&pricing.request),
    })
}

fn parse_optional_decimal(raw: &str) -> f64 {
    if raw.trim().is_empty() {
        0.0
    } else {
        raw.parse().unwrap_or(0.0)
    }
}

fn attachment_data_url(attachment: &ChatAttachment) -> Result<String, LlmError> {
    if attachment.kind != ChatAttachmentKind::Image {
        return Err(LlmError::Response(format!(
            "openrouter only supports image attachments, got {:?}",
            attachment.kind
        )));
    }
    let media_type = attachment
        .mime_type
        .clone()
        .or_else(|| infer_image_media_type(&attachment.path))
        .ok_or_else(|| {
            LlmError::Response(format!(
                "unsupported image media type for {}",
                attachment.path.display()
            ))
        })?;
    let raw = std::fs::read(&attachment.path)
        .map_err(|err| LlmError::Response(format!("read {}: {err}", attachment.path.display())))?;
    Ok(format!(
        "data:{media_type};base64,{}",
        BASE64_STANDARD.encode(raw)
    ))
}

fn infer_image_media_type(path: &std::path::Path) -> Option<String> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "jpg" | "jpeg" => Some("image/jpeg".into()),
        "png" => Some("image/png".into()),
        "gif" => Some("image/gif".into()),
        "webp" => Some("image/webp".into()),
        _ => None,
    }
}

fn fallback_pricing_table() -> HashMap<String, Pricing> {
    let mut table = HashMap::new();
    table.insert(
        "openai/gpt-4".into(),
        Pricing {
            prompt_per_token_usd: 0.00003,
            completion_per_token_usd: 0.00006,
            cache_read_per_token_usd: 0.0,
            cache_create_per_token_usd: 0.0,
            request_usd: 0.0,
        },
    );
    table.insert(
        "anthropic/claude-sonnet-4".into(),
        Pricing {
            prompt_per_token_usd: 0.000003,
            completion_per_token_usd: 0.000015,
            cache_read_per_token_usd: 0.0,
            cache_create_per_token_usd: 0.0,
            request_usd: 0.0,
        },
    );
    table.insert(
        "anthropic/claude-3.5-sonnet".into(),
        Pricing {
            prompt_per_token_usd: 0.000003,
            completion_per_token_usd: 0.000015,
            cache_read_per_token_usd: 0.0,
            cache_create_per_token_usd: 0.0,
            request_usd: 0.0,
        },
    );
    table
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn falls_back_to_hardcoded_pricing_when_metadata_fetch_fails() {
        let provider = OpenRouterProvider::new_with_urls(
            reqwest::Client::new(),
            "OPENROUTER_API_KEY".into(),
            Some("test-key".into()),
            CHAT_COMPLETIONS_URL.into(),
            "http://127.0.0.1:9/models".into(),
        )
        .await;

        let fallback = provider
            .pricing("anthropic/claude-sonnet-4")
            .expect("fallback pricing should be present");

        assert_eq!(provider.provider_name(), "openrouter");
        assert!(fallback.prompt_per_token_usd > 0.0);
        assert!(fallback.completion_per_token_usd > 0.0);
        assert!(!provider.supports_image_input("anthropic/claude-sonnet-4"));
    }

    #[test]
    fn model_supports_image_input_when_metadata_declares_image_modality() {
        let architecture = OpenRouterArchitecture {
            input_modalities: vec!["text".into(), "image".into()],
        };
        assert!(model_supports_image_input(Some(&architecture)));
        assert!(!model_supports_image_input(None));
    }
}
