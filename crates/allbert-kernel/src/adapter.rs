use std::path::PathBuf;
use std::sync::Arc;

use async_trait::async_trait;

use crate::events::KernelEvent;

pub struct FrontendAdapter {
    pub on_event: Box<dyn Fn(&KernelEvent) + Send + Sync>,
    pub confirm: Arc<dyn ConfirmPrompter>,
    pub input: Arc<dyn InputPrompter>,
}

#[async_trait]
pub trait ConfirmPrompter: Send + Sync {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision;
}

#[derive(Debug, Clone)]
pub struct ConfirmRequest {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub rendered: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfirmDecision {
    Deny,
    AllowOnce,
    AllowSession,
}

#[async_trait]
pub trait InputPrompter: Send + Sync {
    async fn request_input(&self, req: InputRequest) -> InputResponse;
}

#[derive(Debug, Clone)]
pub struct InputRequest {
    pub prompt: String,
    pub allow_empty: bool,
}

#[derive(Debug, Clone)]
pub enum InputResponse {
    Submitted(String),
    Cancelled,
}

