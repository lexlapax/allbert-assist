use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub enum HookPoint {
    BeforePrompt,
    BeforeModel,
    BeforeTool,
    AfterTool,
    OnModelResponse,
    OnTurnEnd,
}

#[async_trait]
pub trait Hook: Send + Sync {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome;
}

#[derive(Debug, Default)]
pub struct HookCtx {
    // Stub: populated in later milestones with per-point structured context
    // (model request, tool call, memory snapshot, etc.).
}

#[derive(Debug, Clone)]
pub enum HookOutcome {
    Continue,
    Abort(String),
}

#[derive(Default)]
pub(crate) struct HookRegistry {
    by_point: HashMap<HookPoint, Vec<Arc<dyn Hook>>>,
}

impl HookRegistry {
    pub fn register(&mut self, point: HookPoint, hook: Arc<dyn Hook>) {
        self.by_point.entry(point).or_default().push(hook);
    }

    #[allow(dead_code)]
    pub fn hooks_for(&self, point: HookPoint) -> &[Arc<dyn Hook>] {
        self.by_point.get(&point).map(|v| v.as_slice()).unwrap_or(&[])
    }
}
