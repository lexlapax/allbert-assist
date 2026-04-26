use async_trait::async_trait;
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use serde::{Deserialize, Serialize};

use crate::error::LlmError;

use super::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, LlmProvider, Pricing, Usage,
};

const OLLAMA_BASE_URL: &str = "http://127.0.0.1:11434";

pub struct OllamaProvider {
    client: reqwest::Client,
    chat_url: String,
}

impl OllamaProvider {
    pub fn new(client: reqwest::Client, base_url: Option<String>) -> Self {
        let base_url = base_url.unwrap_or_else(|| OLLAMA_BASE_URL.into());
        Self::new_with_chat_url(
            format!("{}/api/chat", base_url.trim_end_matches('/')),
            client,
        )
    }

    pub(crate) fn new_with_chat_url(chat_url: String, client: reqwest::Client) -> Self {
        Self { client, chat_url }
    }
}

#[async_trait]
impl LlmProvider for OllamaProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let mut messages = Vec::new();
        if let Some(system) = req.system {
            messages.push(OllamaMessage {
                role: "system",
                content: system,
                images: Vec::new(),
            });
        }
        messages.extend(
            req.messages
                .into_iter()
                .map(OllamaMessage::try_from)
                .collect::<Result<Vec<_>, _>>()?,
        );
        let body = OllamaRequest {
            model: req.model,
            messages,
            stream: false,
            options: OllamaOptions {
                num_predict: req.max_tokens,
            },
        };

        let response = self
            .client
            .post(&self.chat_url)
            .header("content-type", "application/json")
            .json(&body)
            .send()
            .await
            .map_err(|err| LlmError::Http(err.to_string()))?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(LlmError::Response(format!(
                "ollama status {}: {}",
                status, body
            )));
        }

        let parsed: OllamaResponse = response
            .json()
            .await
            .map_err(|err| LlmError::Response(err.to_string()))?;
        let text = parsed.message.content;
        Ok(CompletionResponse {
            text,
            usage: Usage {
                input_tokens: parsed.prompt_eval_count.unwrap_or(0),
                output_tokens: parsed.eval_count.unwrap_or(0),
                cache_read: 0,
                cache_create: 0,
            },
            tool_calls: Vec::new(),
        })
    }

    fn pricing(&self, _model: &str) -> Option<Pricing> {
        Some(Pricing {
            prompt_per_token_usd: 0.0,
            completion_per_token_usd: 0.0,
            cache_read_per_token_usd: 0.0,
            cache_create_per_token_usd: 0.0,
            request_usd: 0.0,
        })
    }

    fn provider_name(&self) -> &'static str {
        "ollama"
    }

    fn supports_image_input(&self, model: &str) -> bool {
        let model = model.to_ascii_lowercase();
        model.contains("gemma4") || model.contains("llava") || model.contains("vision")
    }
}

#[derive(Serialize)]
struct OllamaRequest {
    model: String,
    messages: Vec<OllamaMessage>,
    stream: bool,
    options: OllamaOptions,
}

#[derive(Serialize)]
struct OllamaMessage {
    role: &'static str,
    content: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    images: Vec<String>,
}

#[derive(Serialize)]
struct OllamaOptions {
    num_predict: u32,
}

impl TryFrom<ChatMessage> for OllamaMessage {
    type Error = LlmError;

    fn try_from(value: ChatMessage) -> Result<Self, Self::Error> {
        let role = match value.role {
            ChatRole::User => "user",
            ChatRole::Assistant => "assistant",
        };
        Ok(Self {
            role,
            content: value.content,
            images: value
                .attachments
                .iter()
                .map(attachment_base64)
                .collect::<Result<Vec<_>, _>>()?,
        })
    }
}

fn attachment_base64(attachment: &ChatAttachment) -> Result<String, LlmError> {
    if attachment.kind != ChatAttachmentKind::Image {
        return Err(LlmError::Response(format!(
            "ollama only supports image attachments, got {:?}",
            attachment.kind
        )));
    }
    let raw = std::fs::read(&attachment.path)
        .map_err(|err| LlmError::Response(format!("read {}: {err}", attachment.path.display())))?;
    Ok(BASE64_STANDARD.encode(raw))
}

#[derive(Deserialize)]
struct OllamaResponse {
    message: OllamaResponseMessage,
    #[serde(default)]
    prompt_eval_count: Option<u64>,
    #[serde(default)]
    eval_count: Option<u64>,
}

#[derive(Deserialize)]
struct OllamaResponseMessage {
    content: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn maps_chat_request_and_usage() {
        let (url, request_rx) = spawn_json_server(
            "200 OK",
            r#"{"message":{"content":"hello local"},"prompt_eval_count":5,"eval_count":2}"#,
        )
        .await;
        let provider = OllamaProvider::new_with_chat_url(url, reqwest::Client::new());

        let response = provider
            .complete(CompletionRequest {
                system: Some("system".into()),
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: "hi".into(),
                    attachments: Vec::new(),
                }],
                model: "gemma4".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");

        assert_eq!(body["model"], "gemma4");
        assert_eq!(body["stream"], false);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["options"]["num_predict"], 12);
        assert_eq!(response.text, "hello local");
        assert_eq!(response.usage.input_tokens, 5);
        assert_eq!(response.usage.output_tokens, 2);
        assert_eq!(
            provider.pricing("gemma4").unwrap().prompt_per_token_usd,
            0.0
        );
    }

    #[tokio::test]
    async fn serializes_images_as_base64_arrays() {
        let image = tempfile::Builder::new()
            .suffix(".png")
            .tempfile()
            .expect("temp image");
        std::fs::write(image.path(), b"png-bytes").expect("write temp image");
        let (url, request_rx) =
            spawn_json_server("200 OK", r#"{"message":{"content":"image ok"}}"#).await;
        let provider = OllamaProvider::new_with_chat_url(url, reqwest::Client::new());

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
                model: "gemma4".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect("request should succeed");
        let raw_request = request_rx.await.expect("server should capture request");
        let body: Value = serde_json::from_str(http_body(&raw_request)).expect("json body");
        assert!(body["messages"][0]["images"][0].as_str().unwrap().len() > 4);
    }

    #[tokio::test]
    async fn surfaces_http_errors() {
        let (url, _request_rx) =
            spawn_json_server("500 Internal Server Error", r#"{"error":"boom"}"#).await;
        let provider = OllamaProvider::new_with_chat_url(url, reqwest::Client::new());
        let err = provider
            .complete(CompletionRequest {
                system: None,
                messages: Vec::new(),
                model: "gemma4".into(),
                max_tokens: 12,
                tools: Vec::new(),
            })
            .await
            .expect_err("request should fail");
        assert!(err.to_string().contains("ollama status 500"));
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
