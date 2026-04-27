use std::collections::HashMap;

use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use serde::{Deserialize, Serialize};

use crate::error::LlmError;

use super::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, CompletionResponseFormat, LlmProvider, Pricing, Usage,
};

const RESPONSES_URL: &str = "https://api.openai.com/v1/responses";

pub struct OpenAiProvider {
    client: reqwest::Client,
    api_key_env: String,
    api_key_override: Option<String>,
    responses_url: String,
    pricing_table: HashMap<String, Pricing>,
}

impl OpenAiProvider {
    pub fn new(client: reqwest::Client, api_key_env: String, base_url: Option<String>) -> Self {
        let responses_url = base_url
            .map(|url| format!("{}/v1/responses", url.trim_end_matches('/')))
            .unwrap_or_else(|| RESPONSES_URL.into());
        Self::new_with_url(client, api_key_env, None, responses_url)
    }

    pub(crate) fn new_with_url(
        client: reqwest::Client,
        api_key_env: String,
        api_key_override: Option<String>,
        responses_url: String,
    ) -> Self {
        Self {
            client,
            api_key_env,
            api_key_override,
            responses_url,
            pricing_table: openai_pricing_table(),
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
impl LlmProvider for OpenAiProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let api_key = self.api_key()?;
        let input = req
            .messages
            .into_iter()
            .map(OpenAiInputMessage::try_from)
            .collect::<Result<Vec<_>, _>>()?;
        let body = OpenAiRequest {
            model: req.model,
            instructions: req.system,
            input,
            max_output_tokens: req.max_tokens,
            store: false,
            text: OpenAiTextConfig::from_response_format(req.response_format),
            temperature: req.temperature,
        };

        let response = self
            .client
            .post(&self.responses_url)
            .header("Authorization", format!("Bearer {api_key}"))
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|err| LlmError::Http(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(LlmError::Response(format!(
                "openai status {}: {}",
                status, body
            )));
        }

        let parsed: OpenAiResponse = response
            .json()
            .await
            .map_err(|err| LlmError::Response(err.to_string()))?;
        let text = parsed.output_text();
        if text.is_empty() {
            return Err(LlmError::Response(
                "openai response missing output text".into(),
            ));
        }
        let usage = parsed.usage;
        Ok(CompletionResponse {
            text,
            usage: Usage {
                input_tokens: usage.as_ref().map(|usage| usage.input_tokens).unwrap_or(0),
                output_tokens: usage.as_ref().map(|usage| usage.output_tokens).unwrap_or(0),
                cache_read: usage
                    .as_ref()
                    .and_then(|usage| usage.input_tokens_details.as_ref())
                    .map(|details| details.cached_tokens)
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
        "openai"
    }

    fn supports_image_input(&self, _model: &str) -> bool {
        true
    }
}

#[derive(Serialize)]
struct OpenAiRequest {
    model: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    instructions: Option<String>,
    input: Vec<OpenAiInputMessage>,
    max_output_tokens: u32,
    store: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    text: Option<OpenAiTextConfig>,
    #[serde(skip_serializing_if = "Option::is_none")]
    temperature: Option<f32>,
}

#[derive(Serialize)]
struct OpenAiTextConfig {
    format: OpenAiTextFormat,
}

impl OpenAiTextConfig {
    fn from_response_format(format: CompletionResponseFormat) -> Option<Self> {
        match format {
            CompletionResponseFormat::Text => None,
            CompletionResponseFormat::JsonSchema {
                name,
                schema,
                strict,
            } => Some(Self {
                format: OpenAiTextFormat::JsonSchema {
                    name,
                    schema,
                    strict,
                },
            }),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OpenAiTextFormat {
    JsonSchema {
        name: String,
        schema: serde_json::Value,
        strict: bool,
    },
}

#[derive(Serialize)]
struct OpenAiInputMessage {
    role: &'static str,
    content: Vec<OpenAiInputContent>,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum OpenAiInputContent {
    InputText {
        text: String,
    },
    OutputText {
        text: String,
    },
    InputImage {
        image_url: String,
        detail: &'static str,
    },
}

impl TryFrom<ChatMessage> for OpenAiInputMessage {
    type Error = LlmError;

    fn try_from(value: ChatMessage) -> Result<Self, Self::Error> {
        let role = match value.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "assistant",
        };
        let mut content = Vec::new();
        if !value.content.trim().is_empty() {
            match value.role {
                ChatRole::User => content.push(OpenAiInputContent::InputText {
                    text: value.content,
                }),
                ChatRole::Assistant => content.push(OpenAiInputContent::OutputText {
                    text: value.content,
                }),
            }
        }
        for attachment in value.attachments {
            if value.role != ChatRole::User {
                return Err(LlmError::Response(
                    "openai image attachments are only supported on user messages".into(),
                ));
            }
            content.push(OpenAiInputContent::InputImage {
                image_url: attachment_data_url(&attachment)?,
                detail: "auto",
            });
        }
        Ok(Self { role, content })
    }
}

fn attachment_data_url(attachment: &ChatAttachment) -> Result<String, LlmError> {
    if attachment.kind != ChatAttachmentKind::Image {
        return Err(LlmError::Response(format!(
            "openai only supports image attachments, got {:?}",
            attachment.kind
        )));
    }
    let media_type = image_media_type(attachment)?;
    let raw = std::fs::read(&attachment.path)
        .map_err(|err| LlmError::Response(format!("read {}: {err}", attachment.path.display())))?;
    Ok(format!(
        "data:{media_type};base64,{}",
        BASE64_STANDARD.encode(raw)
    ))
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
struct OpenAiResponse {
    #[serde(default)]
    output_text: Option<String>,
    #[serde(default)]
    output: Vec<OpenAiOutputItem>,
    #[serde(default)]
    usage: Option<OpenAiUsage>,
}

impl OpenAiResponse {
    fn output_text(&self) -> String {
        if let Some(text) = &self.output_text {
            if !text.trim().is_empty() {
                return text.clone();
            }
        }
        self.output
            .iter()
            .flat_map(|item| item.content.clone().unwrap_or_default())
            .filter(|content| content.kind == "output_text")
            .filter_map(|content| content.text)
            .collect::<Vec<_>>()
            .join("\n\n")
    }
}

#[derive(Clone, Deserialize)]
struct OpenAiOutputItem {
    #[serde(default)]
    content: Option<Vec<OpenAiOutputContent>>,
}

#[derive(Clone, Deserialize)]
struct OpenAiOutputContent {
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    text: Option<String>,
}

#[derive(Default, Deserialize)]
struct OpenAiUsage {
    #[serde(default)]
    input_tokens: u64,
    #[serde(default)]
    output_tokens: u64,
    #[serde(default)]
    input_tokens_details: Option<OpenAiInputTokenDetails>,
}

#[derive(Deserialize)]
struct OpenAiInputTokenDetails {
    #[serde(default)]
    cached_tokens: u64,
}

fn openai_pricing_table() -> HashMap<String, Pricing> {
    let mut table = HashMap::new();
    table.insert("gpt-5.4-mini".into(), pricing_per_mtok(0.75, 4.50, 0.075));
    table.insert("gpt-5.4".into(), pricing_per_mtok(2.50, 15.00, 0.25));
    table.insert("gpt-5.4-nano".into(), pricing_per_mtok(0.20, 1.25, 0.02));
    table.insert("gpt-5.4-pro".into(), pricing_per_mtok(30.00, 180.00, 0.0));
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
    async fn maps_responses_request_and_usage() {
        let (url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"output":[{"content":[{"type":"output_text","text":"hello"}]}],"usage":{"input_tokens":7,"output_tokens":3,"input_tokens_details":{"cached_tokens":2}}}"#,
        )
        .await;
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            url,
        );

        let response = provider
            .complete(CompletionRequest {
                system: Some("system".into()),
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "hi".into(),
                    attachments: Vec::new(),
                }],
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::Text,
                temperature: None,
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");

        assert_eq!(body["model"], "gpt-5.4-mini");
        assert_eq!(body["instructions"], "system");
        assert_eq!(body["store"], false);
        assert_eq!(body["max_output_tokens"], 12);
        assert_eq!(body["input"][0]["role"], "user");
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(response.text, "hello");
        assert_eq!(response.usage.input_tokens, 7);
        assert_eq!(response.usage.output_tokens, 3);
        assert_eq!(response.usage.cache_read, 2);
        assert!(provider.pricing("gpt-5.4-mini").is_some());
    }

    #[tokio::test]
    async fn maps_json_schema_response_format_to_responses_text_format() {
        let (url, request_rx) =
            spawn_json_server("200 OK", r#"{"output_text":"{}","usage":{}}"#).await;
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            url,
        );

        provider
            .complete(CompletionRequest {
                system: Some("route".into()),
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "classify".into(),
                    attachments: Vec::new(),
                }],
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::JsonSchema {
                    name: "route_decision".into(),
                    schema: serde_json::json!({
                        "type": "object",
                        "additionalProperties": false,
                        "properties": {}
                    }),
                    strict: true,
                },
                temperature: Some(0.0),
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");
        assert_eq!(body["text"]["format"]["type"], "json_schema");
        assert_eq!(body["text"]["format"]["name"], "route_decision");
        assert_eq!(body["text"]["format"]["strict"], true);
        assert_eq!(body["temperature"], 0.0);
    }

    #[tokio::test]
    async fn serializes_assistant_history_as_output_text() {
        let (url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"output_text":"ok","usage":{"input_tokens":5,"output_tokens":1}}"#,
        )
        .await;
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            url,
        );

        provider
            .complete(CompletionRequest {
                system: Some("system".into()),
                messages: vec![
                    ChatMessage {
                        role: ChatRole::User,
                        content: "hello".into(),
                        attachments: Vec::new(),
                    },
                    ChatMessage {
                        role: ChatRole::Assistant,
                        content: "hi there".into(),
                        attachments: Vec::new(),
                    },
                    ChatMessage {
                        role: ChatRole::User,
                        content: "again".into(),
                        attachments: Vec::new(),
                    },
                ],
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::Text,
                temperature: None,
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");

        assert_eq!(body["input"][0]["role"], "user");
        assert_eq!(body["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(body["input"][1]["role"], "assistant");
        assert_eq!(body["input"][1]["content"][0]["type"], "output_text");
        assert_eq!(body["input"][2]["role"], "user");
        assert_eq!(body["input"][2]["content"][0]["type"], "input_text");
    }

    #[tokio::test]
    async fn serializes_images_as_data_urls() {
        let image_path = tempfile::Builder::new()
            .suffix(".png")
            .tempfile()
            .expect("temp image")
            .into_temp_path();
        std::fs::write(&image_path, b"png-bytes").expect("write temp image");
        let (url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"output_text":"image ok","usage":{"input_tokens":1,"output_tokens":1}}"#,
        )
        .await;
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            url,
        );

        provider
            .complete(CompletionRequest {
                system: None,
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "describe".into(),
                    attachments: vec![ChatAttachment {
                        kind: ChatAttachmentKind::Image,
                        path: image_path.to_path_buf(),
                        mime_type: None,
                        display_name: None,
                    }],
                }],
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::Text,
                temperature: None,
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");
        assert_eq!(body["input"][0]["content"][1]["type"], "input_image");
        assert!(body["input"][0]["content"][1]["image_url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,"));
    }

    #[tokio::test]
    async fn rejects_assistant_image_attachments_before_provider_call() {
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            "http://127.0.0.1:1/v1/responses".into(),
        );

        let err = provider
            .complete(CompletionRequest {
                system: None,
                messages: vec![ChatMessage {
                    role: ChatRole::Assistant,
                    content: "I saw this earlier".into(),
                    attachments: vec![ChatAttachment {
                        kind: ChatAttachmentKind::Image,
                        path: std::path::PathBuf::from("assistant-image.png"),
                        mime_type: Some("image/png".into()),
                        display_name: None,
                    }],
                }],
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::Text,
                temperature: None,
            })
            .await
            .expect_err("assistant-side image should fail before HTTP");

        assert!(err
            .to_string()
            .contains("openai image attachments are only supported on user messages"));
    }

    #[tokio::test]
    async fn surfaces_http_errors() {
        let (url, _request_rx) =
            spawn_json_server("429 Too Many Requests", r#"{"error":"rate"}"#).await;
        let provider = OpenAiProvider::new_with_url(
            reqwest::Client::new(),
            "OPENAI_API_KEY".into(),
            Some("test-key".into()),
            url,
        );
        let err = provider
            .complete(CompletionRequest {
                system: None,
                messages: Vec::new(),
                model: "gpt-5.4-mini".into(),
                max_tokens: 12,
                tools: Vec::new(),
                response_format: CompletionResponseFormat::Text,
                temperature: None,
            })
            .await
            .expect_err("request should fail");
        assert!(err.to_string().contains("openai status 429"));
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
