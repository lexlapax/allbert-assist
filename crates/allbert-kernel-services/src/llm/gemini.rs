use std::collections::HashMap;

use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use serde::{Deserialize, Serialize};

use crate::error::LlmError;

use super::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, LlmProvider, Pricing, Usage,
};

const GEMINI_BASE_URL: &str = "https://generativelanguage.googleapis.com/v1beta";

pub struct GeminiProvider {
    client: reqwest::Client,
    api_key_env: String,
    api_key_override: Option<String>,
    base_url: String,
    pricing_table: HashMap<String, Pricing>,
}

impl GeminiProvider {
    pub fn new(client: reqwest::Client, api_key_env: String, base_url: Option<String>) -> Self {
        Self::new_with_base_url(
            client,
            api_key_env,
            None,
            base_url.unwrap_or_else(|| GEMINI_BASE_URL.into()),
        )
    }

    pub(crate) fn new_with_base_url(
        client: reqwest::Client,
        api_key_env: String,
        api_key_override: Option<String>,
        base_url: String,
    ) -> Self {
        Self {
            client,
            api_key_env,
            api_key_override,
            base_url,
            pricing_table: gemini_pricing_table(),
        }
    }

    fn api_key(&self) -> Result<String, LlmError> {
        self.api_key_override
            .clone()
            .or_else(|| std::env::var(&self.api_key_env).ok())
            .ok_or_else(|| LlmError::MissingApiKeyEnv(self.api_key_env.clone()))
    }
}

#[async_trait]
impl LlmProvider for GeminiProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let api_key = self.api_key()?;
        let endpoint = format!(
            "{}/models/{}:generateContent",
            self.base_url.trim_end_matches('/'),
            req.model
        );
        let body = GeminiRequest {
            system_instruction: req.system.map(|text| GeminiContent {
                role: None,
                parts: vec![GeminiPart::Text { text }],
            }),
            contents: req
                .messages
                .into_iter()
                .map(GeminiContent::try_from)
                .collect::<Result<Vec<_>, _>>()?,
            generation_config: GeminiGenerationConfig {
                max_output_tokens: req.max_tokens,
            },
        };

        let response = self
            .client
            .post(endpoint)
            .header("x-goog-api-key", api_key)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|err| LlmError::Http(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(LlmError::Response(format!(
                "gemini status {}: {}",
                status, body
            )));
        }

        let parsed: GeminiResponse = response
            .json()
            .await
            .map_err(|err| LlmError::Response(err.to_string()))?;
        let text = parsed.output_text();
        if text.is_empty() {
            return Err(LlmError::Response(
                "gemini response missing output text".into(),
            ));
        }
        let usage = parsed.usage_metadata.as_ref();
        Ok(CompletionResponse {
            text,
            usage: Usage {
                input_tokens: usage.map(|usage| usage.prompt_token_count).unwrap_or(0),
                output_tokens: usage.map(|usage| usage.candidates_token_count).unwrap_or(0),
                cache_read: usage
                    .map(|usage| usage.cached_content_token_count)
                    .unwrap_or(0),
                cache_create: 0,
            },
            tool_calls: Vec::new(),
        })
    }

    fn pricing(&self, model: &str) -> Option<Pricing> {
        self.pricing_table.get(model).copied()
    }

    fn provider_name(&self) -> &'static str {
        "gemini"
    }

    fn supports_image_input(&self, _model: &str) -> bool {
        true
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeminiRequest {
    #[serde(skip_serializing_if = "Option::is_none")]
    system_instruction: Option<GeminiContent>,
    contents: Vec<GeminiContent>,
    generation_config: GeminiGenerationConfig,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeminiGenerationConfig {
    max_output_tokens: u32,
}

#[derive(Serialize, Deserialize)]
struct GeminiContent {
    #[serde(skip_serializing_if = "Option::is_none")]
    role: Option<String>,
    parts: Vec<GeminiPart>,
}

#[derive(Serialize, Deserialize)]
#[serde(untagged)]
enum GeminiPart {
    Text {
        text: String,
    },
    #[serde(rename_all = "camelCase")]
    InlineData {
        inline_data: GeminiInlineData,
    },
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiInlineData {
    mime_type: String,
    data: String,
}

impl TryFrom<ChatMessage> for GeminiContent {
    type Error = LlmError;

    fn try_from(value: ChatMessage) -> Result<Self, Self::Error> {
        let role = match value.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "model",
        };
        let mut parts = Vec::new();
        if !value.content.trim().is_empty() {
            parts.push(GeminiPart::Text {
                text: value.content,
            });
        }
        for attachment in value.attachments {
            parts.push(GeminiPart::InlineData {
                inline_data: attachment_inline_data(&attachment)?,
            });
        }
        Ok(Self {
            role: Some(role.into()),
            parts,
        })
    }
}

fn attachment_inline_data(attachment: &ChatAttachment) -> Result<GeminiInlineData, LlmError> {
    if attachment.kind != ChatAttachmentKind::Image {
        return Err(LlmError::Response(format!(
            "gemini only supports image attachments, got {:?}",
            attachment.kind
        )));
    }
    let media_type = image_media_type(attachment)?;
    let raw = std::fs::read(&attachment.path)
        .map_err(|err| LlmError::Response(format!("read {}: {err}", attachment.path.display())))?;
    Ok(GeminiInlineData {
        mime_type: media_type,
        data: BASE64_STANDARD.encode(raw),
    })
}

fn image_media_type(attachment: &ChatAttachment) -> Result<String, LlmError> {
    if let Some(media_type) = attachment.mime_type.as_ref() {
        return Ok(media_type.clone());
    }
    let extension = attachment
        .path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    match extension.as_str() {
        "jpg" | "jpeg" => Ok("image/jpeg".into()),
        "png" => Ok("image/png".into()),
        "gif" => Ok("image/gif".into()),
        "webp" => Ok("image/webp".into()),
        _ => Err(LlmError::Response(format!(
            "unsupported image media type for {}",
            attachment.path.display()
        ))),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiResponse {
    #[serde(default)]
    candidates: Vec<GeminiCandidate>,
    #[serde(default)]
    usage_metadata: Option<GeminiUsageMetadata>,
}

impl GeminiResponse {
    fn output_text(&self) -> String {
        self.candidates
            .iter()
            .flat_map(|candidate| &candidate.content.parts)
            .filter_map(|part| match part {
                GeminiPart::Text { text } => Some(text.clone()),
                GeminiPart::InlineData { .. } => None,
            })
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

#[derive(Deserialize)]
struct GeminiCandidate {
    content: GeminiContent,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GeminiUsageMetadata {
    #[serde(default)]
    prompt_token_count: u64,
    #[serde(default)]
    cached_content_token_count: u64,
    #[serde(default)]
    candidates_token_count: u64,
}

fn gemini_pricing_table() -> HashMap<String, Pricing> {
    let mut table = HashMap::new();
    table.insert(
        "gemini-2.5-flash".into(),
        pricing_per_mtok(0.30, 2.50, 0.03),
    );
    table.insert(
        "gemini-2.5-flash-lite".into(),
        pricing_per_mtok(0.10, 0.40, 0.01),
    );
    table.insert(
        "gemini-2.5-pro".into(),
        pricing_per_mtok(1.25, 10.00, 0.125),
    );
    table
}

fn pricing_per_mtok(prompt: f64, completion: f64, cache_read: f64) -> Pricing {
    Pricing {
        prompt_per_token_usd: prompt / 1_000_000.0,
        completion_per_token_usd: completion / 1_000_000.0,
        cache_read_per_token_usd: cache_read / 1_000_000.0,
        cache_create_per_token_usd: 0.0,
        request_usd: 0.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn maps_generate_content_request_and_usage() {
        let (base_url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"candidates":[{"content":{"parts":[{"text":"hello gemini"}]}}],"usageMetadata":{"promptTokenCount":8,"cachedContentTokenCount":2,"candidatesTokenCount":4}}"#,
        )
        .await;
        let provider = GeminiProvider::new_with_base_url(
            reqwest::Client::new(),
            "GEMINI_API_KEY".into(),
            Some("test-key".into()),
            base_url,
        );

        let response = provider
            .complete(CompletionRequest {
                system: Some("system".into()),
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "hi".into(),
                    attachments: Vec::new(),
                }],
                model: "gemini-2.5-flash".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");

        assert!(raw_request.contains("/models/gemini-2.5-flash:generateContent"));
        assert_eq!(body["systemInstruction"]["parts"][0]["text"], "system");
        assert_eq!(body["contents"][0]["role"], "user");
        assert_eq!(body["generationConfig"]["maxOutputTokens"], 12);
        assert_eq!(response.text, "hello gemini");
        assert_eq!(response.usage.input_tokens, 8);
        assert_eq!(response.usage.output_tokens, 4);
        assert_eq!(response.usage.cache_read, 2);
        assert!(provider.pricing("gemini-2.5-flash").is_some());
    }

    #[tokio::test]
    async fn serializes_images_as_inline_data() {
        let image = tempfile::Builder::new()
            .suffix(".png")
            .tempfile()
            .expect("temp image");
        std::fs::write(image.path(), b"png-bytes").expect("write temp image");
        let (base_url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"candidates":[{"content":{"parts":[{"text":"image ok"}]}}]}"#,
        )
        .await;
        let provider = GeminiProvider::new_with_base_url(
            reqwest::Client::new(),
            "GEMINI_API_KEY".into(),
            Some("test-key".into()),
            base_url,
        );

        provider
            .complete(CompletionRequest {
                system: None,
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "describe".into(),
                    attachments: vec![ChatAttachment {
                        kind: ChatAttachmentKind::Image,
                        path: image.path().to_path_buf(),
                        mime_type: None,
                        display_name: None,
                    }],
                }],
                model: "gemini-2.5-flash".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");
        assert_eq!(
            body["contents"][0]["parts"][1]["inlineData"]["mimeType"],
            "image/png"
        );
    }

    #[tokio::test]
    async fn surfaces_http_errors() {
        let (base_url, _request_rx) =
            spawn_json_server("400 Bad Request", r#"{"error":"bad"}"#).await;
        let provider = GeminiProvider::new_with_base_url(
            reqwest::Client::new(),
            "GEMINI_API_KEY".into(),
            Some("test-key".into()),
            base_url,
        );
        let err = provider
            .complete(CompletionRequest {
                system: None,
                messages: Vec::new(),
                model: "gemini-2.5-flash".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect_err("request should fail");
        assert!(err.to_string().contains("gemini status 400"));
    }

    async fn spawn_json_server(
        status: &'static str,
        body: &'static str,
    ) -> (String, tokio::sync::oneshot::Receiver<String>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind mock server");
        let addr = listener.local_addr().expect("local addr");
        let (tx, rx) = tokio::sync::oneshot::channel();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.expect("accept request");
            let mut buffer = vec![0; 65536];
            let n = stream.read(&mut buffer).await.expect("read request");
            let request = String::from_utf8_lossy(&buffer[..n]).to_string();
            let _ = tx.send(request);
            let response = format!(
                "HTTP/1.1 {status}\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{body}",
                body.len()
            );
            stream
                .write_all(response.as_bytes())
                .await
                .expect("write response");
        });
        (format!("http://{addr}"), rx)
    }

    fn http_body(request: &str) -> &str {
        request.split("\r\n\r\n").nth(1).unwrap_or_default()
    }
}
