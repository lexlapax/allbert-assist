use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;

use crate::cost::{append_cost_entry, build_cost_entry, CostEntry};
use crate::events::KernelEvent;
use crate::llm::{Pricing, Usage};
use crate::paths::AllbertPaths;

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
    pub session_id: String,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub usage: Option<Usage>,
    pub pricing: Option<Pricing>,
    pub paths: Option<AllbertPaths>,
    pub pending_events: Vec<KernelEvent>,
    pub recorded_cost: Option<CostEntry>,
}

impl HookCtx {
    pub fn on_model_response(
        session_id: &str,
        provider: &str,
        model: &str,
        usage: Usage,
        pricing: Option<Pricing>,
        paths: &AllbertPaths,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            provider: Some(provider.into()),
            model: Some(model.into()),
            usage: Some(usage),
            pricing,
            paths: Some(paths.clone()),
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }
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
        self.by_point
            .get(&point)
            .map(|v| v.as_slice())
            .unwrap_or(&[])
    }

    pub async fn run(&self, point: HookPoint, ctx: &mut HookCtx) -> HookOutcome {
        for hook in self.hooks_for(point) {
            match hook.call(ctx).await {
                HookOutcome::Continue => continue,
                HookOutcome::Abort(message) => return HookOutcome::Abort(message),
            }
        }
        HookOutcome::Continue
    }
}

pub struct CostHook;

#[async_trait]
impl Hook for CostHook {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
        let (Some(provider), Some(model), Some(usage), Some(paths)) = (
            ctx.provider.as_deref(),
            ctx.model.as_deref(),
            ctx.usage.as_ref(),
            ctx.paths.as_ref(),
        ) else {
            return HookOutcome::Continue;
        };

        match build_cost_entry(&ctx.session_id, provider, model, usage, ctx.pricing) {
            Ok(entry) => {
                if let Err(err) = append_cost_entry(&paths.costs, &entry) {
                    return HookOutcome::Abort(format!("failed to append cost entry: {err}"));
                }
                ctx.recorded_cost = Some(entry.clone());
                ctx.pending_events.push(KernelEvent::Cost(entry));
                HookOutcome::Continue
            }
            Err(err) => HookOutcome::Abort(format!("failed to build cost entry: {err}")),
        }
    }
}

pub struct SecurityHook;

#[async_trait]
impl Hook for SecurityHook {
    async fn call(&self, _ctx: &mut HookCtx) -> HookOutcome {
        HookOutcome::Continue
    }
}

pub struct MemoryIndexHook;

#[async_trait]
impl Hook for MemoryIndexHook {
    async fn call(&self, _ctx: &mut HookCtx) -> HookOutcome {
        HookOutcome::Continue
    }
}
