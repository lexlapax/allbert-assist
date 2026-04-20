use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use async_trait::async_trait;

use crate::bootstrap;
use crate::config::LimitsConfig;
use crate::cost::{append_cost_entry, build_cost_entry, CostEntry};
use crate::events::KernelEvent;
use crate::intent::Intent;
use crate::llm::{Pricing, Usage};
use crate::paths::AllbertPaths;
use crate::tools::ToolInvocation;

#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
pub enum HookPoint {
    BeforePrompt,
    BeforeModel,
    BeforeTool,
    AfterTool,
    OnModelResponse,
    OnTurnEnd,
    BeforeIntent,
    AfterIntent,
    BeforeJobRun,
    AfterJobRun,
    BeforeAgentSpawn,
    AfterAgentSpawn,
    BeforeMemoryPrefetch,
    AfterMemoryPrefetch,
    SynopsisTrimmed,
    BeforeMemoryStage,
    AfterMemoryStage,
    BeforeMemoryPromote,
    AfterMemoryPromote,
    BeforeMemoryForget,
    AfterMemoryForget,
    BeforeIndexRebuild,
    IndexRebuildProgress,
    AfterIndexRebuild,
    MemoryManifestRebuilt,
}

#[async_trait]
pub trait Hook: Send + Sync {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome;
}

#[derive(Debug, Default)]
pub struct HookCtx {
    pub session_id: String,
    pub agent_name: String,
    pub parent_agent_name: Option<String>,
    pub provider: Option<String>,
    pub model: Option<String>,
    pub usage: Option<Usage>,
    pub pricing: Option<Pricing>,
    pub limits: Option<LimitsConfig>,
    pub paths: Option<AllbertPaths>,
    pub turn_input: Option<String>,
    pub intent: Option<Intent>,
    pub job_name: Option<String>,
    pub job_result: Option<serde_json::Value>,
    pub prompt_sections: Vec<String>,
    pub tool_invocation: Option<ToolInvocation>,
    pub active_allowed_tools: Option<HashSet<String>>,
    pub spawn_request: Option<serde_json::Value>,
    pub spawn_result: Option<serde_json::Value>,
    pub memory_payload: Option<serde_json::Value>,
    pub memory_refresh: bool,
    pub pending_events: Vec<KernelEvent>,
    pub recorded_cost: Option<CostEntry>,
}

impl HookCtx {
    pub fn before_prompt(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        paths: &AllbertPaths,
        limits: &LimitsConfig,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: Some(limits.clone()),
            paths: Some(paths.clone()),
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn before_tool(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        invocation: ToolInvocation,
        active_allowed_tools: Option<HashSet<String>>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: Some(invocation),
            active_allowed_tools,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn on_model_response(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        provider: &str,
        model: &str,
        usage: Usage,
        pricing: Option<Pricing>,
        paths: &AllbertPaths,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: Some(provider.into()),
            model: Some(model.into()),
            usage: Some(usage),
            pricing,
            limits: None,
            paths: Some(paths.clone()),
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn before_agent_spawn(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        spawn_request: serde_json::Value,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: Some(spawn_request),
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn after_agent_spawn(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        spawn_result: serde_json::Value,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: Some(spawn_result),
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn on_turn_end(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn before_intent(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        input: &str,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: Some(input.into()),
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn after_intent(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        input: &str,
        intent: Intent,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: Some(input.into()),
            intent: Some(intent),
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn before_job_run(session_id: &str, agent_name: &str, job_name: &str) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name: None,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: Some(job_name.into()),
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn after_job_run(
        session_id: &str,
        agent_name: &str,
        job_name: &str,
        job_result: serde_json::Value,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name: None,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: Some(job_name.into()),
            job_result: Some(job_result),
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: None,
            memory_refresh: false,
            pending_events: Vec::new(),
            recorded_cost: None,
        }
    }

    pub fn memory_event(
        session_id: &str,
        agent_name: &str,
        parent_agent_name: Option<String>,
        payload: serde_json::Value,
        refresh: bool,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            agent_name: agent_name.into(),
            parent_agent_name,
            provider: None,
            model: None,
            usage: None,
            pricing: None,
            limits: None,
            paths: None,
            turn_input: None,
            intent: None,
            job_name: None,
            job_result: None,
            prompt_sections: Vec::new(),
            tool_invocation: None,
            active_allowed_tools: None,
            spawn_request: None,
            spawn_result: None,
            memory_payload: Some(payload),
            memory_refresh: refresh,
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

        match build_cost_entry(
            &ctx.session_id,
            &ctx.agent_name,
            ctx.parent_agent_name.as_deref(),
            provider,
            model,
            usage,
            ctx.pricing,
        ) {
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

pub struct BootstrapContextHook;

#[async_trait]
impl Hook for BootstrapContextHook {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
        let (Some(paths), Some(limits)) = (ctx.paths.as_ref(), ctx.limits.as_ref()) else {
            return HookOutcome::Continue;
        };

        match bootstrap::snapshot_prompt_sections(paths, limits) {
            Ok(sections) => {
                ctx.prompt_sections.extend(sections);
                HookOutcome::Continue
            }
            Err(err) => HookOutcome::Abort(format!("failed to load bootstrap context: {err}")),
        }
    }
}

pub struct MemoryIndexHook;

#[async_trait]
impl Hook for MemoryIndexHook {
    async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
        let _ = (&ctx.paths, &ctx.limits);
        HookOutcome::Continue
    }
}
