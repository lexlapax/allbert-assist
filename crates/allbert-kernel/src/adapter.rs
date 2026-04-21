use std::path::PathBuf;
use std::sync::{Arc, Mutex};

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

#[derive(Clone)]
pub struct DynamicConfirmPrompter {
    current: Arc<Mutex<Arc<dyn ConfirmPrompter>>>,
}

impl DynamicConfirmPrompter {
    pub fn new(initial: Arc<dyn ConfirmPrompter>) -> Self {
        Self {
            current: Arc::new(Mutex::new(initial)),
        }
    }

    pub fn set(&self, next: Arc<dyn ConfirmPrompter>) {
        *self.current.lock().unwrap() = next;
    }
}

#[async_trait]
impl ConfirmPrompter for DynamicConfirmPrompter {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
        let current = self.current.lock().unwrap().clone();
        current.confirm(req).await
    }
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
    Timeout,
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
