pub mod adapter;
pub mod agent;
mod bootstrap;
pub mod config;
pub mod cost;
pub mod error;
pub mod events;
pub mod hooks;
pub mod intent;
pub mod job_manager;
pub mod llm;
pub mod memory;
pub mod paths;
pub mod security;
pub mod skills;
pub mod tools;
pub mod trace;

use std::sync::{Arc, Mutex};

use serde_json::json;

pub use adapter::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, FrontendAdapter, InputPrompter, InputRequest,
    InputResponse,
};
pub use agent::{Agent, AgentDefinition, AgentState};
pub use config::{
    Config, DaemonConfig, IntentClassifierConfig, JobsConfig, LimitsConfig, ModelConfig, Provider,
    SecurityConfig, SetupConfig, WebSecurityConfig,
};
pub use cost::CostEntry;
pub use error::{ConfigError, KernelError, SkillError, ToolError};
pub use events::KernelEvent;
pub use hooks::{
    BootstrapContextHook, CostHook, Hook, HookCtx, HookOutcome, HookPoint, MemoryIndexHook,
};
pub use intent::Intent;
pub use job_manager::{JobManager, ListJobRunsInput, NamedJobInput, UpsertJobInput};
pub use llm::{ChatMessage, ChatRole};
pub use memory::{ReadMemoryInput, WriteMemoryInput, WriteMemoryMode};
pub use paths::AllbertPaths;
pub use security::SecurityHook;
pub use skills::{
    ActiveSkill, ContributedAgent, CreateSkillInput, InvokeSkillInput, Skill, SkillStore,
};
pub use tools::{ToolCtx, ToolInvocation, ToolOutput, ToolRegistry};
pub use trace::TraceHandles;

use hooks::HookRegistry;
use intent::{classify_by_rules, default_intent};
use llm::{CompletionRequest, DefaultProviderFactory, LlmProvider, ProviderFactory};

pub struct TurnSummary {
    pub hit_turn_limit: bool,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct SpawnSubagentInput {
    name: String,
    prompt: String,
    #[serde(default)]
    context: Option<serde_json::Value>,
}

#[derive(Debug, Clone, serde::Serialize)]
struct SpawnSubagentResult {
    agent_name: String,
    parent_agent_name: String,
    hit_turn_limit: bool,
    cost_usd: f64,
    assistant_text: Option<String>,
}

struct AgentRunSummary {
    hit_turn_limit: bool,
    assistant_text: Option<String>,
}

pub struct Kernel {
    config: Config,
    paths: AllbertPaths,
    adapter: FrontendAdapter,
    hooks: HookRegistry,
    skills: SkillStore,
    state: AgentState,
    provider_factory: Arc<dyn ProviderFactory>,
    llm: Box<dyn LlmProvider>,
    tools: ToolRegistry,
    job_manager: Option<Arc<dyn JobManager>>,
    security_state: Arc<Mutex<SecurityConfig>>,
    #[allow(dead_code)]
    trace: TraceHandles,
}

impl Kernel {
    pub async fn boot(config: Config, adapter: FrontendAdapter) -> Result<Self, KernelError> {
        let paths = AllbertPaths::from_home()?;
        Self::boot_with_parts(
            config,
            adapter,
            paths,
            Arc::new(DefaultProviderFactory::default()),
        )
        .await
    }

    pub async fn boot_with_paths_and_factory(
        config: Config,
        adapter: FrontendAdapter,
        paths: AllbertPaths,
        provider_factory: Arc<dyn ProviderFactory>,
        session_id: Option<String>,
    ) -> Result<Self, KernelError> {
        Self::boot_with_parts_and_session(config, adapter, paths, provider_factory, session_id)
            .await
    }

    async fn boot_with_parts(
        config: Config,
        adapter: FrontendAdapter,
        paths: AllbertPaths,
        provider_factory: Arc<dyn ProviderFactory>,
    ) -> Result<Self, KernelError> {
        Self::boot_with_parts_and_session(config, adapter, paths, provider_factory, None).await
    }

    async fn boot_with_parts_and_session(
        config: Config,
        adapter: FrontendAdapter,
        paths: AllbertPaths,
        provider_factory: Arc<dyn ProviderFactory>,
        session_id: Option<String>,
    ) -> Result<Self, KernelError> {
        paths.ensure()?;

        let session_id = session_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let trace = trace::init_tracing(config.trace, &paths, &session_id)?;
        let llm = provider_factory.build(&config.model).await?;
        let skills = SkillStore::discover(&paths.skills);
        let security_state = Arc::new(Mutex::new(config.security.clone()));
        let mut hooks = HookRegistry::default();
        hooks.register(
            HookPoint::BeforeTool,
            Arc::new(SecurityHook::new(
                security_state.clone(),
                paths.clone(),
                adapter.confirm.clone(),
            )),
        );
        hooks.register(HookPoint::BeforePrompt, Arc::new(BootstrapContextHook));
        hooks.register(HookPoint::BeforePrompt, Arc::new(MemoryIndexHook));
        hooks.register(HookPoint::OnModelResponse, Arc::new(CostHook));

        tracing::info!(session = %session_id, agent = "allbert/root", "kernel boot");

        Ok(Self {
            config,
            paths,
            adapter,
            hooks,
            skills,
            state: AgentState::new(session_id),
            provider_factory,
            llm,
            tools: ToolRegistry::builtins(),
            job_manager: None,
            security_state,
            trace,
        })
    }

    pub async fn run_turn(&mut self, user_input: &str) -> Result<TurnSummary, KernelError> {
        let placeholder = AgentState::new(self.state.session_id.clone());
        let mut state = std::mem::replace(&mut self.state, placeholder);
        let result = self
            .run_turn_for_agent(&mut state, user_input, None, true)
            .await;
        self.state = state;
        result.map(|summary| TurnSummary {
            hit_turn_limit: summary.hit_turn_limit,
        })
    }

    pub async fn run_job_turn(
        &mut self,
        job_name: &str,
        user_input: &str,
    ) -> Result<TurnSummary, KernelError> {
        let placeholder = AgentState::new(self.state.session_id.clone());
        let mut state = std::mem::replace(&mut self.state, placeholder);
        let mut before_ctx =
            HookCtx::before_job_run(&state.session_id, state.agent_name(), job_name);
        match self
            .hooks
            .run(HookPoint::BeforeJobRun, &mut before_ctx)
            .await
        {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => {
                self.state = state;
                return Err(KernelError::Hook(message));
            }
        }

        let result = self
            .run_turn_for_agent(&mut state, user_input, None, false)
            .await;

        let turn_summary = match &result {
            Ok(summary) => json!({
                "job_name": job_name,
                "hit_turn_limit": summary.hit_turn_limit,
                "cost_usd": state.cost_total_usd,
            }),
            Err(err) => json!({
                "job_name": job_name,
                "error": err.to_string(),
                "cost_usd": state.cost_total_usd,
            }),
        };
        let mut after_ctx = HookCtx::after_job_run(
            &state.session_id,
            state.agent_name(),
            job_name,
            turn_summary,
        );
        let after_result = self.hooks.run(HookPoint::AfterJobRun, &mut after_ctx).await;
        self.state = state;

        match after_result {
            HookOutcome::Continue => result.map(|summary| TurnSummary {
                hit_turn_limit: summary.hit_turn_limit,
            }),
            HookOutcome::Abort(message) => Err(KernelError::Hook(message)),
        }
    }

    async fn run_turn_for_agent(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        parent_agent_name: Option<String>,
        emit_terminal_events: bool,
    ) -> Result<AgentRunSummary, KernelError> {
        state.turn_count = state.turn_count.saturating_add(1);
        let resolved_intent = self
            .resolve_intent_for_turn(state, user_input, parent_agent_name.clone())
            .await?;
        tracing::info!(
            session = %state.session_id,
            agent = %state.agent_name(),
            parent_agent = ?parent_agent_name,
            turn = state.turn_count,
            intent = ?resolved_intent.as_ref().map(Intent::as_str),
            "turn start"
        );
        state.messages.push(ChatMessage {
            role: ChatRole::User,
            content: user_input.into(),
        });

        let mut tool_calls_used = 0usize;
        let mut tool_output_total = 0usize;

        for _round in 0..self.config.limits.max_turns {
            let effective_model = state.model_override.as_ref().unwrap_or(&self.config.model);
            let mut prompt_ctx = HookCtx::before_prompt(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                &self.paths,
                &self.config.limits,
            );
            prompt_ctx.intent = resolved_intent.clone();
            match self
                .hooks
                .run(HookPoint::BeforePrompt, &mut prompt_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }

            let response = self
                .llm
                .complete(CompletionRequest {
                    system: Some(self.system_prompt_for_state(
                        state,
                        parent_agent_name.as_deref(),
                        resolved_intent.as_ref(),
                        &prompt_ctx.prompt_sections,
                    )),
                    messages: state.messages.clone(),
                    model: effective_model.model_id.clone(),
                    max_tokens: effective_model.max_tokens,
                })
                .await?;

            tracing::debug!(
                session = %state.session_id,
                agent = %state.agent_name(),
                parent_agent = ?parent_agent_name,
                provider = %self.llm.provider_name(),
                model = %effective_model.model_id,
                "model response received"
            );

            let mut hook_ctx = HookCtx::on_model_response(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                self.llm.provider_name(),
                &effective_model.model_id,
                response.usage.clone(),
                self.llm.pricing(&effective_model.model_id),
                &self.paths,
            );
            hook_ctx.intent = resolved_intent.clone();

            match self
                .hooks
                .run(HookPoint::OnModelResponse, &mut hook_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }

            if let Some(entry) = hook_ctx.recorded_cost.as_ref() {
                state.cost_total_usd += entry.usd_estimate;
            }

            state.messages.push(ChatMessage {
                role: ChatRole::Assistant,
                content: response.text.clone(),
            });

            for event in hook_ctx.pending_events {
                (self.adapter.on_event)(&event);
            }

            let tool_calls = parse_tool_calls(&response.text);
            if tool_calls.is_empty() {
                if emit_terminal_events {
                    (self.adapter.on_event)(&KernelEvent::AssistantText(response.text.clone()));
                    (self.adapter.on_event)(&KernelEvent::TurnDone {
                        hit_turn_limit: false,
                    });
                }
                let mut end_ctx =
                    HookCtx::on_turn_end(&state.session_id, state.agent_name(), parent_agent_name);
                end_ctx.intent = resolved_intent.clone();
                match self.hooks.run(HookPoint::OnTurnEnd, &mut end_ctx).await {
                    HookOutcome::Continue => {}
                    HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
                }
                return Ok(AgentRunSummary {
                    hit_turn_limit: false,
                    assistant_text: Some(response.text),
                });
            }

            for invocation in tool_calls {
                if tool_calls_used >= self.config.limits.max_tool_calls_per_turn as usize {
                    let content = "tool call budget exhausted".to_string();
                    state.messages.push(ChatMessage {
                        role: ChatRole::User,
                        content: format!("Tool result for limit (ok=false):\n{content}"),
                    });
                    if emit_terminal_events {
                        (self.adapter.on_event)(&KernelEvent::ToolResult {
                            name: "tool_budget".into(),
                            ok: false,
                            content,
                        });
                        (self.adapter.on_event)(&KernelEvent::TurnDone {
                            hit_turn_limit: true,
                        });
                    }
                    let mut end_ctx = HookCtx::on_turn_end(
                        &state.session_id,
                        state.agent_name(),
                        parent_agent_name.clone(),
                    );
                    end_ctx.intent = resolved_intent.clone();
                    match self.hooks.run(HookPoint::OnTurnEnd, &mut end_ctx).await {
                        HookOutcome::Continue => {}
                        HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
                    }
                    return Ok(AgentRunSummary {
                        hit_turn_limit: true,
                        assistant_text: None,
                    });
                }

                tool_calls_used += 1;
                if emit_terminal_events {
                    (self.adapter.on_event)(&KernelEvent::ToolCall {
                        name: invocation.name.clone(),
                        input: invocation.input.clone(),
                    });
                }

                tracing::debug!(
                    session = %state.session_id,
                    agent = %state.agent_name(),
                    parent_agent = ?parent_agent_name,
                    tool = %invocation.name,
                    "dispatch tool"
                );

                let mut tool_hook_ctx = HookCtx::before_tool(
                    &state.session_id,
                    state.agent_name(),
                    parent_agent_name.clone(),
                    invocation.clone(),
                    combined_allowed_tools(
                        self.skills.allowed_tool_union(&state.active_skills),
                        state.allowed_tools.clone(),
                    ),
                );
                tool_hook_ctx.intent = resolved_intent.clone();
                let tool_output = match self
                    .hooks
                    .run(HookPoint::BeforeTool, &mut tool_hook_ctx)
                    .await
                {
                    HookOutcome::Continue => {
                        self.dispatch_tool_for_state(
                            state,
                            parent_agent_name.clone(),
                            invocation.clone(),
                        )
                        .await
                    }
                    HookOutcome::Abort(message) => ToolOutput {
                        content: message,
                        ok: false,
                    },
                };

                let mut after_tool_ctx = HookCtx::before_tool(
                    &state.session_id,
                    state.agent_name(),
                    parent_agent_name.clone(),
                    invocation.clone(),
                    combined_allowed_tools(
                        self.skills.allowed_tool_union(&state.active_skills),
                        state.allowed_tools.clone(),
                    ),
                );
                after_tool_ctx.intent = resolved_intent.clone();
                match self
                    .hooks
                    .run(HookPoint::AfterTool, &mut after_tool_ctx)
                    .await
                {
                    HookOutcome::Continue => {}
                    HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
                }

                let remaining = self
                    .config
                    .limits
                    .max_tool_output_bytes_total
                    .saturating_sub(tool_output_total);
                if remaining == 0 {
                    if emit_terminal_events {
                        (self.adapter.on_event)(&KernelEvent::TurnDone {
                            hit_turn_limit: true,
                        });
                    }
                    let mut end_ctx = HookCtx::on_turn_end(
                        &state.session_id,
                        state.agent_name(),
                        parent_agent_name.clone(),
                    );
                    end_ctx.intent = resolved_intent.clone();
                    match self.hooks.run(HookPoint::OnTurnEnd, &mut end_ctx).await {
                        HookOutcome::Continue => {}
                        HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
                    }
                    return Ok(AgentRunSummary {
                        hit_turn_limit: true,
                        assistant_text: None,
                    });
                }

                let per_call_limit = self
                    .config
                    .limits
                    .max_tool_output_bytes_per_call
                    .min(remaining);
                let content = truncate_to_bytes(&tool_output.content, per_call_limit);
                tool_output_total += content.as_bytes().len();

                if emit_terminal_events {
                    (self.adapter.on_event)(&KernelEvent::ToolResult {
                        name: invocation.name.clone(),
                        ok: tool_output.ok,
                        content: content.clone(),
                    });
                }

                state.messages.push(ChatMessage {
                    role: ChatRole::User,
                    content: format!(
                        "Tool result for {} (ok={}):\n{}",
                        invocation.name, tool_output.ok, content
                    ),
                });
            }
        }

        if emit_terminal_events {
            (self.adapter.on_event)(&KernelEvent::TurnDone {
                hit_turn_limit: true,
            });
        }
        let mut end_ctx =
            HookCtx::on_turn_end(&state.session_id, state.agent_name(), parent_agent_name);
        end_ctx.intent = resolved_intent;
        match self.hooks.run(HookPoint::OnTurnEnd, &mut end_ctx).await {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
        }
        Ok(AgentRunSummary {
            hit_turn_limit: true,
            assistant_text: None,
        })
    }

    pub fn register_hook(&mut self, point: HookPoint, hook: Arc<dyn Hook>) {
        self.hooks.register(point, hook);
    }

    pub fn list_skills(&self) -> &[Skill] {
        self.skills.all()
    }

    pub fn list_agents(&self) -> Vec<&ContributedAgent> {
        self.skills.contributed_agents()
    }

    pub fn active_skills(&self) -> &[ActiveSkill] {
        &self.state.active_skills
    }

    pub fn activate_session_skill(
        &mut self,
        name: &str,
        args: Option<serde_json::Value>,
    ) -> Result<(), KernelError> {
        Self::activate_skill_with_config(&self.skills, &self.config, &mut self.state, name, args)
    }

    fn activate_skill_with_config(
        skills: &SkillStore,
        config: &Config,
        state: &mut AgentState,
        name: &str,
        args: Option<serde_json::Value>,
    ) -> Result<(), KernelError> {
        let Some(_skill) = skills.get(name) else {
            return Err(KernelError::InitFailed(format!("skill not found: {name}")));
        };
        if let Some(args) = &args {
            let serialized = serde_json::to_string(args).unwrap_or_default();
            if serialized.as_bytes().len() > config.limits.max_skill_args_bytes {
                return Err(KernelError::InitFailed(
                    "invoke_skill args exceed limits.max_skill_args_bytes".into(),
                ));
            }
        }
        SkillStore::upsert_active_skill(&mut state.active_skills, name, args);
        Ok(())
    }

    pub fn reset_session(&mut self) {
        let new_id = uuid::Uuid::new_v4().to_string();
        self.state.reset(new_id);
    }

    pub fn session_cost_usd(&self) -> f64 {
        self.state.cost_total_usd
    }

    pub fn session_id(&self) -> &str {
        &self.state.session_id
    }

    pub fn agent_name(&self) -> &str {
        self.state.agent_name()
    }

    pub fn set_adapter(&mut self, adapter: FrontendAdapter) {
        self.adapter = adapter;
    }

    pub fn register_job_manager(&mut self, job_manager: Arc<dyn JobManager>) {
        self.job_manager = Some(job_manager);
    }

    pub fn provider_name(&self) -> &'static str {
        self.llm.provider_name()
    }

    pub fn model(&self) -> &ModelConfig {
        &self.config.model
    }

    pub async fn set_model(&mut self, model: ModelConfig) -> Result<(), KernelError> {
        let llm = self.provider_factory.build(&model).await?;
        self.config.model = model;
        self.llm = llm;
        Ok(())
    }

    pub async fn apply_config(&mut self, config: Config) -> Result<(), KernelError> {
        let model_changed = self.config.model != config.model;
        if model_changed {
            self.llm = self.provider_factory.build(&config.model).await?;
        }

        self.config = config;
        *self.security_state.lock().unwrap() = self.config.security.clone();
        Ok(())
    }

    pub fn today_cost_usd(&self) -> Result<f64, KernelError> {
        cost::sum_costs_for_today(&self.paths.costs)
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn paths(&self) -> &AllbertPaths {
        &self.paths
    }

    async fn resolve_intent_for_turn(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        parent_agent_name: Option<String>,
    ) -> Result<Option<Intent>, KernelError> {
        if !self.config.intent_classifier.enabled {
            return Ok(None);
        }

        let mut before_ctx = HookCtx::before_intent(
            &state.session_id,
            state.agent_name(),
            parent_agent_name.clone(),
            user_input,
        );
        match self
            .hooks
            .run(HookPoint::BeforeIntent, &mut before_ctx)
            .await
        {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
        }

        let intent = if let Some(intent) = before_ctx.intent.clone() {
            intent
        } else if let Some(intent) = classify_by_rules(user_input) {
            intent
        } else if self.config.intent_classifier.rule_only
            || !within_intent_budget(
                user_input,
                self.config.intent_classifier.per_turn_token_budget,
            )
        {
            default_intent(user_input)
        } else {
            self.classify_intent_with_llm(state, user_input, parent_agent_name.clone())
                .await?
                .unwrap_or_else(|| default_intent(user_input))
        };

        let mut after_ctx = HookCtx::after_intent(
            &state.session_id,
            state.agent_name(),
            parent_agent_name,
            user_input,
            intent,
        );
        match self.hooks.run(HookPoint::AfterIntent, &mut after_ctx).await {
            HookOutcome::Continue => Ok(after_ctx.intent),
            HookOutcome::Abort(message) => Err(KernelError::Hook(message)),
        }
    }

    async fn classify_intent_with_llm(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        parent_agent_name: Option<String>,
    ) -> Result<Option<Intent>, KernelError> {
        let classifier_model = if self.config.intent_classifier.model.trim().is_empty() {
            self.config.model.model_id.clone()
        } else {
            self.config.intent_classifier.model.clone()
        };
        let max_tokens = self
            .config
            .intent_classifier
            .per_turn_token_budget
            .clamp(8, 64);
        let response = self
            .llm
            .complete(CompletionRequest {
                system: Some(
                    "Classify the user's message into exactly one intent label.\n\
Allowed labels: task, chat, schedule, memory_query, meta.\n\
Respond with only the lowercase label and no other text."
                        .into(),
                ),
                messages: vec![ChatMessage {
                    role: ChatRole::User,
                    content: user_input.into(),
                }],
                model: classifier_model.clone(),
                max_tokens,
            })
            .await?;

        tracing::debug!(
            session = %state.session_id,
            agent = "intent-classifier",
            parent_agent = %state.agent_name(),
            model = %classifier_model,
            "intent classifier response received"
        );

        let mut hook_ctx = HookCtx::on_model_response(
            &state.session_id,
            "intent-classifier",
            Some(parent_agent_name.unwrap_or_else(|| state.agent_name().to_string())),
            self.llm.provider_name(),
            &classifier_model,
            response.usage.clone(),
            self.llm.pricing(&classifier_model),
            &self.paths,
        );
        match self
            .hooks
            .run(HookPoint::OnModelResponse, &mut hook_ctx)
            .await
        {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
        }
        if let Some(entry) = hook_ctx.recorded_cost.as_ref() {
            state.cost_total_usd += entry.usd_estimate;
        }
        for event in hook_ctx.pending_events {
            (self.adapter.on_event)(&event);
        }

        Ok(Intent::parse(response.text.trim()))
    }

    fn system_prompt_for_state(
        &self,
        state: &AgentState,
        parent_agent_name: Option<&str>,
        resolved_intent: Option<&Intent>,
        prompt_sections: &[String],
    ) -> String {
        let mut prompt = String::from(
            "You are Allbert, a local personal assistant running inside a Rust kernel. \
Answer helpfully and concisely. Treat the runtime bootstrap context below as durable \
guidance for tone, identity, and user preferences. If the user's current request \
directly conflicts with that context, follow the user's current request.\n\n\
If you need a tool, respond with one or more XML blocks and no prose:\n\
<tool_call>{\"name\":\"tool_name\",\"input\":{...}}</tool_call>\n\
After tool results are returned, either emit more <tool_call> blocks or answer normally.\n\n\
Available tools:\n",
        );

        prompt.push_str(&format!("\nCurrent agent: {}\n", state.agent_name()));
        if let Some(parent) = parent_agent_name {
            prompt.push_str(&format!("Parent agent: {parent}\n"));
        }
        if let Some(intent) = resolved_intent {
            prompt.push_str(&format!("Resolved intent: {}\n", intent.as_str()));
        }

        prompt.push_str(&self.tools.prompt_catalog());
        prompt.push_str("\n- read_memory: Read a memory file relative to ~/.allbert/memory.\n  schema: {\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"}}}\n");
        prompt.push_str("\n- write_memory: Write, append, or daily-append memory content.\n  schema: {\"type\":\"object\",\"required\":[\"content\",\"mode\"],\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"mode\":{\"enum\":[\"write\",\"append\",\"daily\"]},\"summary\":{\"type\":\"string\"}}}\n");
        prompt.push_str("\n- list_skills: List installed skills and their descriptions.\n  schema: {\"type\":\"object\",\"properties\":{}}\n");
        prompt.push_str("\n- invoke_skill: Activate a skill for this session, optionally with JSON args.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"},\"args\":{\"type\":\"object\"}}}\n");
        prompt.push_str("\n- create_skill: Create a skill under ~/.allbert/skills/<name>/SKILL.md.\n  schema: {\"type\":\"object\",\"required\":[\"name\",\"description\",\"allowed_tools\",\"body\"],\"properties\":{\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"allowed_tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"body\":{\"type\":\"string\"}}}\n");
        prompt.push_str("\n- spawn_subagent: Run a bounded sub-agent with a fresh message history inside the current session.\n  schema: {\"type\":\"object\",\"required\":[\"name\",\"prompt\"],\"properties\":{\"name\":{\"type\":\"string\"},\"prompt\":{\"type\":\"string\"},\"context\":{}}}\n");
        if self.job_manager.is_some() {
            prompt.push_str(
                "\nWhen the user asks for recurring or scheduled work, use the daemon-backed job tools instead of generic file edits or subprocesses.\n\
Common schedule forms you may compile to are:\n\
- @daily at HH:MM\n\
- @weekly on monday at HH:MM\n\
- every <duration> such as every 2h\n\
- once at <RFC3339>\n\
- cron: <5-field expression> only when the user explicitly wants cron-like control\n\
For \"why did that job fail?\" inspect the job with get_job and recent runs with list_job_runs, usually with only_failures=true.\n\
Do not claim a durable schedule change succeeded until the upsert/pause/resume/remove tool has actually completed after the explicit confirmation step.\n",
            );
            prompt.push_str("\n- list_jobs: List recurring jobs managed by the daemon.\n  schema: {\"type\":\"object\",\"properties\":{}}\n");
            prompt.push_str("\n- get_job: Inspect one recurring job by name.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- upsert_job: Create or update a recurring job through the daemon-owned scheduler.\n  schema: {\"type\":\"object\",\"required\":[\"name\",\"description\",\"schedule\",\"prompt\"],\"properties\":{\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"enabled\":{\"type\":\"boolean\"},\"schedule\":{\"type\":\"string\"},\"skills\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"timezone\":{\"type\":\"string\"},\"model\":{\"type\":\"object\"},\"allowed_tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"timeout_s\":{\"type\":\"integer\",\"minimum\":1},\"report\":{\"enum\":[\"always\",\"on_failure\",\"on_anomaly\"]},\"max_turns\":{\"type\":\"integer\",\"minimum\":1},\"prompt\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- pause_job: Pause a recurring job by name.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- resume_job: Resume a recurring job by name.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- run_job: Manually trigger a recurring job by name.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- remove_job: Remove a recurring job by name.\n  schema: {\"type\":\"object\",\"required\":[\"name\"],\"properties\":{\"name\":{\"type\":\"string\"}}}\n");
            prompt.push_str("\n- list_job_runs: Inspect recent job runs, optionally filtered by name or failures only.\n  schema: {\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\"},\"only_failures\":{\"type\":\"boolean\"},\"limit\":{\"type\":\"integer\",\"minimum\":1}}}\n");
        }

        for section in prompt_sections {
            prompt.push_str("\n\n");
            prompt.push_str(section);
        }

        prompt.push_str("\n\nAvailable skill manifests:\n");
        prompt.push_str(&self.skills.manifest_prompt());
        if let Some(intent) = resolved_intent {
            if let Some(relevant) = self.skills.intent_hint_prompt(intent) {
                prompt.push_str("\n\nLikely relevant skills for this intent:\n");
                prompt.push_str(&relevant);
            }
        }

        let active = self.skills.active_prompt(
            &state.active_skills,
            self.config.limits.max_skill_args_bytes,
        );
        if !active.is_empty() {
            prompt.push_str("\n\nActive skill bodies:\n");
            prompt.push_str(&active);
        }

        prompt
    }

    async fn dispatch_tool_for_state(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        invocation: ToolInvocation,
    ) -> ToolOutput {
        match invocation.name.as_str() {
            "read_memory" => self.dispatch_read_memory(invocation.input),
            "write_memory" => self.dispatch_write_memory(invocation.input),
            "list_skills" => ToolOutput {
                content: self.skills.manifest_prompt(),
                ok: true,
            },
            "invoke_skill" => self.dispatch_invoke_skill(state, invocation.input),
            "create_skill" => self.dispatch_create_skill(invocation.input),
            "spawn_subagent" => {
                self.dispatch_spawn_subagent(state, parent_agent_name, invocation.input)
                    .await
            }
            "list_jobs" => self.dispatch_list_jobs().await,
            "get_job" => self.dispatch_get_job(invocation.input).await,
            "upsert_job" => self.dispatch_upsert_job(invocation.input).await,
            "pause_job" => self.dispatch_pause_job(invocation.input).await,
            "resume_job" => self.dispatch_resume_job(invocation.input).await,
            "run_job" => self.dispatch_run_job(invocation.input).await,
            "remove_job" => self.dispatch_remove_job(invocation.input).await,
            "list_job_runs" => self.dispatch_list_job_runs(invocation.input).await,
            _ => {
                let ctx = ToolCtx {
                    input: self.adapter.input.clone(),
                    security: self.config.security.clone(),
                    web_client: reqwest::Client::new(),
                };
                match self.tools.dispatch(invocation, &ctx).await {
                    Ok(output) => output,
                    Err(err) => ToolOutput {
                        content: err.to_string(),
                        ok: false,
                    },
                }
            }
        }
    }

    fn dispatch_invoke_skill(
        &mut self,
        state: &mut AgentState,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<InvokeSkillInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid invoke_skill input: {err}"),
                    ok: false,
                }
            }
        };

        let Some(skill) = self.skills.get(&parsed.name) else {
            return ToolOutput {
                content: format!("skill not found: {}", parsed.name),
                ok: false,
            };
        };
        if let Err(err) = Self::activate_skill_with_config(
            &self.skills,
            &self.config,
            state,
            &parsed.name,
            parsed.args,
        ) {
            return ToolOutput {
                content: err.to_string(),
                ok: false,
            };
        }
        ToolOutput {
            content: format!("activated skill {}", skill.name),
            ok: true,
        }
    }

    async fn dispatch_spawn_subagent(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<SpawnSubagentInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid spawn_subagent input: {err}"),
                    ok: false,
                }
            }
        };

        if parent_agent_name.is_some() {
            return ToolOutput {
                content: "recursive sub-agent spawning is not allowed in v0.3".into(),
                ok: false,
            };
        }

        let mut before_ctx = HookCtx::before_agent_spawn(
            &state.session_id,
            state.agent_name(),
            None,
            json!({
                "name": parsed.name,
                "prompt": parsed.prompt,
                "context": parsed.context
            }),
        );
        match self
            .hooks
            .run(HookPoint::BeforeAgentSpawn, &mut before_ctx)
            .await
        {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => {
                return ToolOutput {
                    content: message,
                    ok: false,
                }
            }
        }

        let contributed_agent = self.skills.get_contributed_agent(&parsed.name).cloned();
        let mut subagent_state = AgentState::for_agent(
            state.session_id.clone(),
            AgentDefinition {
                name: contributed_agent
                    .as_ref()
                    .map(|agent| agent.name.clone())
                    .unwrap_or_else(|| parsed.name.clone()),
                description: contributed_agent
                    .as_ref()
                    .map(|agent| agent.description.clone())
                    .unwrap_or_else(|| "Spawned sub-agent".into()),
            },
        );
        if let Some(agent) = contributed_agent.as_ref() {
            subagent_state.allowed_tools = Some(agent.allowed_tools.iter().cloned().collect());
            subagent_state.model_override = agent.model.clone();
        }
        let contributed_preamble = contributed_agent
            .as_ref()
            .map(|agent| {
                format!(
                    "Registered agent prompt ({})\n{}\n\nDelegated task:\n{}",
                    agent.name,
                    agent.body.trim(),
                    parsed.prompt.trim()
                )
            })
            .unwrap_or_else(|| parsed.prompt.trim().to_string());
        let composed_prompt = match parsed.context {
            Some(context) => format!(
                "{}\n\nContext (JSON):\n{}",
                contributed_preamble,
                serde_json::to_string_pretty(&context).unwrap_or_else(|_| "{}".into())
            ),
            None => contributed_preamble,
        };

        let run_result = Box::pin(self.run_turn_for_agent(
            &mut subagent_state,
            &composed_prompt,
            Some(state.agent_name().to_string()),
            false,
        ))
        .await;

        state.cost_total_usd += subagent_state.cost_total_usd;

        let tool_output = match run_result {
            Ok(summary) => {
                let result = SpawnSubagentResult {
                    agent_name: subagent_state.agent_name().to_string(),
                    parent_agent_name: state.agent_name().to_string(),
                    hit_turn_limit: summary.hit_turn_limit,
                    cost_usd: subagent_state.cost_total_usd,
                    assistant_text: summary.assistant_text,
                };
                let content = serde_json::to_string_pretty(&result)
                    .unwrap_or_else(|_| "{\"error\":\"failed to encode spawn result\"}".into());
                ToolOutput { content, ok: true }
            }
            Err(err) => ToolOutput {
                content: format!("sub-agent failed: {err}"),
                ok: false,
            },
        };

        let result_json = json!({
            "agent_name": parsed.name,
            "ok": tool_output.ok,
            "content": tool_output.content,
        });
        let mut after_ctx =
            HookCtx::after_agent_spawn(&state.session_id, state.agent_name(), None, result_json);
        match self
            .hooks
            .run(HookPoint::AfterAgentSpawn, &mut after_ctx)
            .await
        {
            HookOutcome::Continue => tool_output,
            HookOutcome::Abort(message) => ToolOutput {
                content: message,
                ok: false,
            },
        }
    }

    fn dispatch_create_skill(&mut self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<CreateSkillInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid create_skill input: {err}"),
                    ok: false,
                }
            }
        };

        match self.skills.create(
            &self.paths.skills,
            &parsed.name,
            &parsed.description,
            &parsed.allowed_tools,
            &parsed.body,
        ) {
            Ok(skill) => ToolOutput {
                content: format!("created skill {} at {}", skill.name, skill.path.display()),
                ok: true,
            },
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    fn dispatch_read_memory(&self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<ReadMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid read_memory input: {err}"),
                    ok: false,
                }
            }
        };

        match memory::read_memory(&self.paths, parsed) {
            Ok(content) => ToolOutput { content, ok: true },
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    fn dispatch_write_memory(&self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<WriteMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid write_memory input: {err}"),
                    ok: false,
                }
            }
        };

        match memory::write_memory(&self.paths, parsed) {
            Ok(content) => ToolOutput { content, ok: true },
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_list_jobs(&self) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        match job_manager.list_jobs().await {
            Ok(jobs) => serialize_tool_value(&jobs),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_get_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<NamedJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid get_job input: {err}"),
                    ok: false,
                }
            }
        };
        match job_manager.get_job(&parsed.name).await {
            Ok(job) => serialize_tool_value(&job),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_upsert_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<UpsertJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid upsert_job input: {err}"),
                    ok: false,
                }
            }
        };
        let definition = parsed.into_payload();
        let existing = match job_manager.list_jobs().await {
            Ok(jobs) => jobs
                .into_iter()
                .find(|job| job.definition.name == definition.name),
            Err(err) => {
                return ToolOutput {
                    content: err,
                    ok: false,
                }
            }
        };
        let preview = render_upsert_job_preview(existing.as_ref(), &definition);
        if let Err(output) = self
            .confirm_job_mutation("upsert_job", vec![definition.name.clone()], preview)
            .await
        {
            return output;
        }
        match job_manager.upsert_job(definition).await {
            Ok(job) => serialize_tool_value(&job),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_pause_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<NamedJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid pause_job input: {err}"),
                    ok: false,
                }
            }
        };
        let current = match job_manager.get_job(&parsed.name).await {
            Ok(job) => job,
            Err(err) => {
                return ToolOutput {
                    content: err,
                    ok: false,
                }
            }
        };
        if let Err(output) = self
            .confirm_job_mutation(
                "pause_job",
                vec![parsed.name.clone()],
                render_job_status_preview("pause recurring job", &current),
            )
            .await
        {
            return output;
        }
        match job_manager.pause_job(&parsed.name).await {
            Ok(job) => serialize_tool_value(&job),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_resume_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<NamedJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid resume_job input: {err}"),
                    ok: false,
                }
            }
        };
        let current = match job_manager.get_job(&parsed.name).await {
            Ok(job) => job,
            Err(err) => {
                return ToolOutput {
                    content: err,
                    ok: false,
                }
            }
        };
        if let Err(output) = self
            .confirm_job_mutation(
                "resume_job",
                vec![parsed.name.clone()],
                render_job_status_preview("resume recurring job", &current),
            )
            .await
        {
            return output;
        }
        match job_manager.resume_job(&parsed.name).await {
            Ok(job) => serialize_tool_value(&job),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_run_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<NamedJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid run_job input: {err}"),
                    ok: false,
                }
            }
        };
        match job_manager.run_job(&parsed.name).await {
            Ok(run) => serialize_tool_value(&run),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_remove_job(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<NamedJobInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid remove_job input: {err}"),
                    ok: false,
                }
            }
        };
        let current = match job_manager.get_job(&parsed.name).await {
            Ok(job) => job,
            Err(err) => {
                return ToolOutput {
                    content: err,
                    ok: false,
                }
            }
        };
        if let Err(output) = self
            .confirm_job_mutation(
                "remove_job",
                vec![parsed.name.clone()],
                render_job_status_preview("remove recurring job", &current),
            )
            .await
        {
            return output;
        }
        match job_manager.remove_job(&parsed.name).await {
            Ok(()) => serialize_tool_value(&json!({ "removed": parsed.name })),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn dispatch_list_job_runs(&self, input: serde_json::Value) -> ToolOutput {
        let Some(job_manager) = self.job_manager.as_ref() else {
            return unavailable_job_manager_output();
        };
        let parsed = match serde_json::from_value::<ListJobRunsInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid list_job_runs input: {err}"),
                    ok: false,
                }
            }
        };
        let limit = parsed.limit.clamp(1, 100);
        match job_manager
            .list_job_runs(parsed.name.as_deref(), parsed.only_failures, limit)
            .await
        {
            Ok(runs) => serialize_tool_value(&runs),
            Err(err) => ToolOutput {
                content: err,
                ok: false,
            },
        }
    }

    async fn confirm_job_mutation(
        &self,
        program: &str,
        args: Vec<String>,
        rendered: String,
    ) -> Result<(), ToolOutput> {
        match self
            .adapter
            .confirm
            .confirm(ConfirmRequest {
                program: program.into(),
                args,
                cwd: None,
                rendered,
            })
            .await
        {
            ConfirmDecision::Deny => Err(ToolOutput {
                content: "job mutation denied by user".into(),
                ok: false,
            }),
            ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => Ok(()),
        }
    }
}

fn unavailable_job_manager_output() -> ToolOutput {
    ToolOutput {
        content: "job management is not available in this session".into(),
        ok: false,
    }
}

fn serialize_tool_value<T: serde::Serialize>(value: &T) -> ToolOutput {
    match serde_json::to_string_pretty(value) {
        Ok(content) => ToolOutput { content, ok: true },
        Err(err) => ToolOutput {
            content: format!("failed to encode tool result: {err}"),
            ok: false,
        },
    }
}

fn combined_allowed_tools(
    active_skill_allowed: Option<std::collections::HashSet<String>>,
    agent_allowed: Option<std::collections::HashSet<String>>,
) -> Option<std::collections::HashSet<String>> {
    match (active_skill_allowed, agent_allowed) {
        (None, None) => None,
        (Some(allowed), None) | (None, Some(allowed)) => Some(allowed),
        (Some(active), Some(agent)) => Some(active.intersection(&agent).cloned().collect()),
    }
}

fn within_intent_budget(input: &str, budget: u32) -> bool {
    let estimated_tokens = (input.chars().count() / 4).max(1) as u32 + 64;
    estimated_tokens <= budget
}

fn render_upsert_job_preview(
    existing: Option<&allbert_proto::JobStatusPayload>,
    definition: &allbert_proto::JobDefinitionPayload,
) -> String {
    let mut lines = vec![
        "durable job change preview".to_string(),
        format!(
            "action:            {}",
            if existing.is_some() {
                "update recurring job"
            } else {
                "create recurring job"
            }
        ),
    ];
    if let Some(existing) = existing {
        lines.push(format!(
            "existing schedule: {}",
            existing.definition.schedule
        ));
        lines.push(format!(
            "existing timezone: {}",
            existing
                .definition
                .timezone
                .as_deref()
                .unwrap_or("(default)")
        ));
    }
    lines.extend(render_job_definition_lines(definition));
    lines.join("\n")
}

fn render_job_status_preview(action: &str, job: &allbert_proto::JobStatusPayload) -> String {
    let mut lines = vec![
        "durable job change preview".to_string(),
        format!("action:            {action}"),
    ];
    lines.extend(render_job_definition_lines(&job.definition));
    lines.push(format!("currently paused:  {}", yes_no(job.state.paused)));
    lines.push(format!("currently running: {}", yes_no(job.state.running)));
    lines.push(format!(
        "next due:          {}",
        job.state.next_due_at.as_deref().unwrap_or("(none)")
    ));
    lines.push(format!(
        "last outcome:      {}",
        job.state.last_outcome.as_deref().unwrap_or("(none)")
    ));
    lines.join("\n")
}

fn render_job_definition_lines(definition: &allbert_proto::JobDefinitionPayload) -> Vec<String> {
    vec![
        format!("name:              {}", definition.name),
        format!("description:       {}", definition.description),
        format!("enabled:           {}", yes_no(definition.enabled)),
        format!("schedule:          {}", definition.schedule),
        format!(
            "timezone:          {}",
            definition.timezone.as_deref().unwrap_or("(default)")
        ),
        format!(
            "model override:    {}",
            render_job_model(definition.model.as_ref())
        ),
        format!("skills:            {}", render_list(&definition.skills)),
        format!(
            "allowed tools:     {}",
            render_list(&definition.allowed_tools)
        ),
        format!(
            "report policy:     {}",
            render_job_report(definition.report)
        ),
        format!(
            "timeout:           {}",
            definition
                .timeout_s
                .map(|value| format!("{value}s"))
                .unwrap_or_else(|| "(default)".into())
        ),
        format!(
            "max turns:         {}",
            definition
                .max_turns
                .map(|value| value.to_string())
                .unwrap_or_else(|| "(default)".into())
        ),
        format!(
            "prompt:\n{}",
            indent_block(if definition.prompt.trim().is_empty() {
                "(empty)"
            } else {
                definition.prompt.trim()
            })
        ),
    ]
}

fn render_job_model(model: Option<&allbert_proto::ModelConfigPayload>) -> String {
    match model {
        Some(model) => format!("{:?} / {}", model.provider, model.model_id),
        None => "(daemon default)".into(),
    }
}

fn render_job_report(report: Option<allbert_proto::JobReportPolicyPayload>) -> &'static str {
    match report {
        Some(allbert_proto::JobReportPolicyPayload::Always) => "always",
        Some(allbert_proto::JobReportPolicyPayload::OnFailure) => "on_failure",
        Some(allbert_proto::JobReportPolicyPayload::OnAnomaly) => "on_anomaly",
        None => "(default)",
    }
}

fn render_list(values: &[String]) -> String {
    if values.is_empty() {
        "(none)".into()
    } else {
        values.join(", ")
    }
}

fn indent_block(text: &str) -> String {
    text.lines()
        .map(|line| format!("  {line}"))
        .collect::<Vec<_>>()
        .join("\n")
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn parse_tool_calls(text: &str) -> Vec<ToolInvocation> {
    let mut calls = Vec::new();
    let mut start = 0usize;
    let open = "<tool_call>";
    let close = "</tool_call>";

    while let Some(open_idx_rel) = text[start..].find(open) {
        let open_idx = start + open_idx_rel + open.len();
        let Some(close_idx_rel) = text[open_idx..].find(close) else {
            break;
        };
        let close_idx = open_idx + close_idx_rel;
        let raw = text[open_idx..close_idx].trim();
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) {
            if let (Some(name), Some(input)) = (
                value.get("name").and_then(|value| value.as_str()),
                value.get("input"),
            ) {
                calls.push(ToolInvocation {
                    name: name.to_string(),
                    input: input.clone(),
                });
            }
        }
        start = close_idx + close.len();
    }

    calls
}

fn truncate_to_bytes(input: &str, max_bytes: usize) -> String {
    if input.as_bytes().len() <= max_bytes {
        return input.to_string();
    }

    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use serde_json::json;

    use super::*;
    use crate::error::LlmError;
    use crate::llm::{CompletionRequest, CompletionResponse, Pricing, Usage};
    use crate::security::{exec_policy, sandbox, web_policy, NormalizedExec, PolicyDecision};

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!("allbert-test-{}", uuid::Uuid::new_v4()));
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }

    struct NoopConfirm;

    #[async_trait]
    impl ConfirmPrompter for NoopConfirm {
        async fn confirm(&self, _req: ConfirmRequest) -> ConfirmDecision {
            ConfirmDecision::Deny
        }
    }

    struct NoopInput;

    #[async_trait]
    impl InputPrompter for NoopInput {
        async fn request_input(&self, _req: InputRequest) -> InputResponse {
            InputResponse::Cancelled
        }
    }

    fn test_adapter(events: Arc<Mutex<Vec<KernelEvent>>>) -> FrontendAdapter {
        test_adapter_with(events, Arc::new(NoopConfirm), Arc::new(NoopInput))
    }

    fn test_adapter_with(
        events: Arc<Mutex<Vec<KernelEvent>>>,
        confirm: Arc<dyn ConfirmPrompter>,
        input: Arc<dyn InputPrompter>,
    ) -> FrontendAdapter {
        FrontendAdapter {
            on_event: Box::new(move |event| {
                events.lock().unwrap().push(event.clone());
            }),
            confirm,
            input,
        }
    }

    fn write_skill(
        paths: &AllbertPaths,
        name: &str,
        description: &str,
        allowed_tools: &str,
        body: &str,
    ) {
        let dir = paths.skills.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!(
                "---\nname: {name}\ndescription: {description}\nallowed-tools: {allowed_tools}\n---\n\n{body}\n"
            ),
        )
        .unwrap();
    }

    fn write_skill_raw(paths: &AllbertPaths, name: &str, raw: &str) {
        let dir = paths.skills.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), raw).unwrap();
    }

    struct QueueConfirm {
        decisions: Arc<Mutex<VecDeque<ConfirmDecision>>>,
        seen: Arc<Mutex<Vec<ConfirmRequest>>>,
    }

    impl QueueConfirm {
        fn new(decisions: Vec<ConfirmDecision>) -> Self {
            Self {
                decisions: Arc::new(Mutex::new(decisions.into())),
                seen: Arc::new(Mutex::new(Vec::new())),
            }
        }

        fn seen(&self) -> Arc<Mutex<Vec<ConfirmRequest>>> {
            Arc::clone(&self.seen)
        }
    }

    #[async_trait]
    impl ConfirmPrompter for QueueConfirm {
        async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
            self.seen.lock().unwrap().push(req);
            self.decisions
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(ConfirmDecision::Deny)
        }
    }

    struct QueueInput {
        responses: Arc<Mutex<VecDeque<InputResponse>>>,
    }

    impl QueueInput {
        fn new(responses: Vec<InputResponse>) -> Self {
            Self {
                responses: Arc::new(Mutex::new(responses.into())),
            }
        }
    }

    #[async_trait]
    impl InputPrompter for QueueInput {
        async fn request_input(&self, _req: InputRequest) -> InputResponse {
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or(InputResponse::Cancelled)
        }
    }

    struct RecordingHook {
        label: &'static str,
        seen: Arc<Mutex<Vec<(String, Option<Intent>)>>>,
    }

    #[async_trait]
    impl Hook for RecordingHook {
        async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
            self.seen
                .lock()
                .unwrap()
                .push((self.label.to_string(), ctx.intent.clone()));
            HookOutcome::Continue
        }
    }

    #[test]
    fn load_or_create_writes_default_config() {
        let temp = TempRoot::new();
        let paths = temp.paths();

        let config = Config::load_or_create(&paths).expect("default config should be created");

        assert!(paths.config.exists(), "config file should exist");
        assert!(paths.soul.exists(), "SOUL.md should exist");
        assert!(paths.user.exists(), "USER.md should exist");
        assert!(paths.identity.exists(), "IDENTITY.md should exist");
        assert!(paths.tools_notes.exists(), "TOOLS.md should exist");
        assert!(paths.bootstrap.exists(), "BOOTSTRAP.md should exist");
        assert_eq!(config.model.provider, Provider::Anthropic);
        assert_eq!(config.model.api_key_env, "ANTHROPIC_API_KEY");
        assert_eq!(config.limits.max_bootstrap_file_bytes, 2 * 1024);
        assert_eq!(config.limits.max_prompt_bootstrap_bytes, 6 * 1024);
    }

    #[tokio::test]
    async fn kernel_boot_creates_expected_directory_tree() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(events),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                Vec::new(),
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        assert!(paths.root.exists());
        assert!(paths.soul.exists());
        assert!(paths.user.exists());
        assert!(paths.identity.exists());
        assert!(paths.tools_notes.exists());
        assert!(paths.bootstrap.exists());
        assert!(paths.skills.exists());
        assert!(paths.memory.exists());
        assert!(paths.memory_daily.exists());
        assert!(paths.memory_topics.exists());
        assert!(paths.memory_people.exists());
        assert!(paths.memory_projects.exists());
        assert!(paths.memory_decisions.exists());
        assert!(paths.traces.exists());
        assert_eq!(kernel.paths().root, paths.root);
    }

    #[tokio::test]
    async fn run_turn_emits_cost_and_assistant_events() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![CompletionResponse {
                    text: "4".into(),
                    usage: Usage {
                        input_tokens: 10,
                        output_tokens: 5,
                        cache_read: 0,
                        cache_create: 0,
                    },
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel.run_turn("hello").await.expect("turn should succeed");
        let recorded = events.lock().unwrap();

        assert!(!summary.hit_turn_limit);
        assert_eq!(
            recorded.len(),
            3,
            "turn should emit cost, text, and done events"
        );

        let cost_entry = match &recorded[0] {
            KernelEvent::Cost(entry) => entry,
            other => panic!("expected Cost event, got {other:?}"),
        };
        assert_eq!(cost_entry.agent_name, "allbert/root");
        assert_eq!(cost_entry.parent_agent_name, None);
        assert_eq!(cost_entry.provider, "anthropic");
        assert_eq!(cost_entry.model, "claude-sonnet-4-5");
        assert!((cost_entry.usd_estimate - 0.02).abs() < 1e-9);

        match &recorded[1] {
            KernelEvent::AssistantText(text) => assert_eq!(text, "4"),
            other => panic!("expected AssistantText, got {other:?}"),
        }

        match &recorded[2] {
            KernelEvent::TurnDone { hit_turn_limit } => assert!(!hit_turn_limit),
            other => panic!("expected TurnDone, got {other:?}"),
        }

        let log =
            std::fs::read_to_string(kernel.paths().costs.clone()).expect("cost log should exist");
        assert_eq!(log.lines().count(), 1);
        assert!((kernel.session_cost_usd() - 0.02).abs() < 1e-9);
    }

    #[tokio::test]
    async fn kernel_boots_with_root_agent_identity() {
        let temp = TempRoot::new();
        let paths = temp.paths();

        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                Vec::new(),
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        assert_eq!(kernel.agent_name(), "allbert/root");
    }

    #[tokio::test]
    async fn spawn_subagent_uses_fresh_history_and_records_costs_per_agent() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "researcher",
                                    "prompt": "Reply with exactly SUBAGENT_OK and nothing else."
                                }
                            })
                        ),
                        usage: Usage {
                            input_tokens: 10,
                            output_tokens: 1,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "SUBAGENT_OK".into(),
                        usage: Usage {
                            input_tokens: 5,
                            output_tokens: 2,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "ROOT_OK".into(),
                        usage: Usage {
                            input_tokens: 7,
                            output_tokens: 1,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel
            .run_turn("delegate this")
            .await
            .expect("turn should succeed");
        assert!(!summary.hit_turn_limit);
        assert!((kernel.session_cost_usd() - 0.03).abs() < 1e-9);

        let recorded_requests = requests.lock().unwrap();
        assert_eq!(
            recorded_requests.len(),
            3,
            "root, sub-agent, root follow-up"
        );
        assert_eq!(
            recorded_requests[1].messages.len(),
            1,
            "sub-agent should start with fresh history"
        );
        assert_eq!(
            recorded_requests[1].messages[0].content,
            "Reply with exactly SUBAGENT_OK and nothing else."
        );
        assert!(
            recorded_requests[2]
                .messages
                .last()
                .unwrap()
                .content
                .contains("\"agent_name\": \"researcher\""),
            "root follow-up should see structured sub-agent result"
        );

        let log = std::fs::read_to_string(paths.costs).expect("cost log should exist");
        let entries = log
            .lines()
            .map(|line| serde_json::from_str::<CostEntry>(line).expect("valid cost entry"))
            .collect::<Vec<_>>();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0].agent_name, "allbert/root");
        assert_eq!(entries[0].parent_agent_name, None);
        assert_eq!(entries[1].agent_name, "researcher");
        assert_eq!(
            entries[1].parent_agent_name.as_deref(),
            Some("allbert/root")
        );
        assert_eq!(entries[2].agent_name, "allbert/root");
    }

    #[tokio::test]
    async fn spawn_subagent_refuses_recursive_spawns() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "researcher",
                                    "prompt": "Try to spawn another sub-agent."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "nested",
                                    "prompt": "Reply with NESTED."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_DONE".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "ROOT_DONE".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("delegate nested work")
            .await
            .expect("turn should succeed");

        let recorded_requests = requests.lock().unwrap();
        assert_eq!(recorded_requests.len(), 4);
        assert!(
            recorded_requests[2]
                .messages
                .last()
                .unwrap()
                .content
                .contains("recursive sub-agent spawning is not allowed"),
            "sub-agent follow-up should see recursion refusal"
        );
    }

    #[tokio::test]
    async fn spawn_subagent_respects_shared_policy_envelope() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let workspace_root = paths.root.join("workspace");
        fs::create_dir_all(&workspace_root).expect("workspace root should exist");

        let mut config = Config::default_template();
        config.security.fs_roots = vec![workspace_root];

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "reader",
                                    "prompt": "Try to read /etc/passwd."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "read_file",
                                "input": {
                                    "path": "/etc/passwd"
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_POLICY_OK".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "ROOT_POLICY_OK".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("delegate file work")
            .await
            .expect("turn should succeed");

        let recorded_requests = requests.lock().unwrap();
        assert_eq!(recorded_requests.len(), 4);
        assert!(
            recorded_requests[2]
                .messages
                .last()
                .unwrap()
                .content
                .contains("outside configured roots"),
            "sub-agent follow-up should see the same filesystem policy denial"
        );
    }

    #[tokio::test]
    async fn intent_rule_fast_path_sets_schedule_intent_without_extra_model_call() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![CompletionResponse {
                    text: "SCHEDULE_OK".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("schedule a daily review at 07:00")
            .await
            .expect("turn should succeed");

        let requests = requests.lock().unwrap();
        assert_eq!(
            requests.len(),
            1,
            "rule classifier should avoid an LLM sub-call"
        );
        let system = requests[0]
            .system
            .as_ref()
            .expect("system prompt should exist");
        assert!(system.contains("Resolved intent: schedule"));
    }

    #[tokio::test]
    async fn intent_classifier_fallback_uses_llm_and_records_costs() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: "chat".into(),
                        usage: Usage {
                            input_tokens: 2,
                            output_tokens: 1,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "CHAT_OK".into(),
                        usage: Usage {
                            input_tokens: 3,
                            output_tokens: 1,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("hmm maybe")
            .await
            .expect("turn should succeed");

        let requests = requests.lock().unwrap();
        assert_eq!(
            requests.len(),
            2,
            "fallback classifier should use a model sub-call"
        );
        assert!(
            requests[0]
                .system
                .as_ref()
                .unwrap()
                .contains("Classify the user's message"),
            "first request should be the classifier sub-call"
        );
        assert!(
            requests[1]
                .system
                .as_ref()
                .unwrap()
                .contains("Resolved intent: chat"),
            "main turn should receive the resolved intent"
        );

        let log = fs::read_to_string(kernel.paths().costs.clone()).expect("cost log should exist");
        assert!(
            log.contains("\"agent_name\":\"intent-classifier\""),
            "classifier call should be attributed separately in cost logs"
        );
        assert!(kernel.session_cost_usd() > 0.0);
    }

    #[tokio::test]
    async fn intent_classifier_budget_limit_skips_llm_fallback() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut config = Config::default_template();
        config.intent_classifier.per_turn_token_budget = 8;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![CompletionResponse {
                    text: "TASK_OK".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let large_ambiguous = "lorem ipsum ".repeat(200);
        kernel
            .run_turn(&large_ambiguous)
            .await
            .expect("turn should succeed");

        let requests = requests.lock().unwrap();
        assert_eq!(
            requests.len(),
            1,
            "budget enforcement should skip the classifier sub-call"
        );
        assert!(
            requests[0]
                .system
                .as_ref()
                .unwrap()
                .contains("Resolved intent: task"),
            "budget fallback should use the default task intent"
        );
    }

    #[tokio::test]
    async fn intent_hooks_fire_in_order_and_carry_resolved_intent() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let seen = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![CompletionResponse {
                    text: "HOOK_OK".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.register_hook(
            HookPoint::BeforeIntent,
            Arc::new(RecordingHook {
                label: "before_intent",
                seen: seen.clone(),
            }),
        );
        kernel.register_hook(
            HookPoint::AfterIntent,
            Arc::new(RecordingHook {
                label: "after_intent",
                seen: seen.clone(),
            }),
        );
        kernel.register_hook(
            HookPoint::BeforePrompt,
            Arc::new(RecordingHook {
                label: "before_prompt",
                seen: seen.clone(),
            }),
        );
        kernel.register_hook(
            HookPoint::OnTurnEnd,
            Arc::new(RecordingHook {
                label: "on_turn_end",
                seen: seen.clone(),
            }),
        );

        kernel
            .run_turn("what can you do?")
            .await
            .expect("turn should succeed");

        let seen = seen.lock().unwrap();
        assert_eq!(
            seen.iter()
                .map(|(label, _)| label.as_str())
                .collect::<Vec<_>>(),
            vec![
                "before_intent",
                "after_intent",
                "before_prompt",
                "on_turn_end"
            ]
        );
        assert_eq!(seen[0].1, None);
        assert_eq!(seen[1].1, Some(Intent::Meta));
        assert_eq!(seen[2].1, Some(Intent::Meta));
        assert_eq!(seen[3].1, Some(Intent::Meta));
    }

    #[tokio::test]
    async fn fake_provider_selection_tracks_configured_provider() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let seen = Arc::new(Mutex::new(Vec::new()));

        let anthropic_factory = Arc::new(TestFactory::with_seen(
            "anthropic",
            seen.clone(),
            Vec::new(),
            Some(test_pricing()),
        ));
        let anthropic_kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            anthropic_factory,
        )
        .await
        .expect("anthropic kernel should boot");
        assert_eq!(anthropic_kernel.provider_name(), "anthropic");

        let mut openrouter_config = Config::default_template();
        openrouter_config.model.provider = Provider::Openrouter;
        openrouter_config.model.model_id = "anthropic/claude-sonnet-4".into();
        openrouter_config.model.api_key_env = "OPENROUTER_API_KEY".into();

        let openrouter_factory = Arc::new(TestFactory::with_seen(
            "openrouter",
            seen.clone(),
            Vec::new(),
            Some(test_pricing()),
        ));
        let openrouter_kernel = Kernel::boot_with_parts(
            openrouter_config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            openrouter_factory,
        )
        .await
        .expect("openrouter kernel should boot");
        assert_eq!(openrouter_kernel.provider_name(), "openrouter");

        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert_eq!(seen[0], Provider::Anthropic);
        assert_eq!(seen[1], Provider::Openrouter);
    }

    #[tokio::test]
    async fn session_cost_accumulates_across_turns() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(events),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "first".into(),
                        usage: Usage {
                            input_tokens: 10,
                            output_tokens: 5,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "second".into(),
                        usage: Usage {
                            input_tokens: 10,
                            output_tokens: 5,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("one")
            .await
            .expect("first turn should pass");
        kernel
            .run_turn("two")
            .await
            .expect("second turn should pass");

        assert!((kernel.session_cost_usd() - 0.04).abs() < 1e-9);
        let log = std::fs::read_to_string(paths.costs).expect("cost log should exist");
        assert_eq!(log.lines().count(), 2);
    }

    #[tokio::test]
    async fn run_turn_builds_system_prompt_from_bootstrap_files() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("bootstrap files should be created");

        std::fs::write(&paths.soul, "# SOUL\n\n## Tone\n- Quietly relentless.\n")
            .expect("should write SOUL.md");
        std::fs::write(&paths.user, "# USER\n\n## Preferred name\n- Lex\n")
            .expect("should write USER.md");

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "ok".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("hello").await.expect("turn should succeed");

        let requests = captured_requests.lock().unwrap();
        let system = requests[0]
            .system
            .as_ref()
            .expect("system prompt should be set");

        assert!(system.contains("## SOUL.md"));
        assert!(system.contains("Quietly relentless."));
        assert!(system.contains("## USER.md"));
        assert!(system.contains("Lex"));
        assert!(system.contains("## IDENTITY.md"));
        assert!(system.contains("## TOOLS.md"));
        assert!(system.contains("## BOOTSTRAP.md"));

        let soul_idx = system
            .find("## SOUL.md")
            .expect("SOUL.md section should exist");
        let user_idx = system
            .find("## USER.md")
            .expect("USER.md section should exist");
        let identity_idx = system
            .find("## IDENTITY.md")
            .expect("IDENTITY.md section should exist");
        assert!(soul_idx < user_idx);
        assert!(user_idx < identity_idx);
    }

    #[tokio::test]
    async fn fresh_turns_reread_bootstrap_files() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("bootstrap files should be created");

        std::fs::write(&paths.soul, "# SOUL\n\n## Tone\n- First stance.\n")
            .expect("should write initial SOUL.md");

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![
                    CompletionResponse {
                        text: "first".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "second".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("one")
            .await
            .expect("first turn should work");

        std::fs::write(&paths.soul, "# SOUL\n\n## Tone\n- Second stance.\n")
            .expect("should rewrite SOUL.md");

        kernel
            .run_turn("two")
            .await
            .expect("second turn should work");

        let requests = captured_requests.lock().unwrap();
        let first = requests[0]
            .system
            .as_ref()
            .expect("first turn should have a system prompt");
        let second = requests[1]
            .system
            .as_ref()
            .expect("second turn should have a system prompt");

        assert!(first.contains("First stance."));
        assert!(second.contains("Second stance."));
        assert!(!second.contains("First stance."));
    }

    #[tokio::test]
    async fn bootstrap_prompt_omits_bootstrap_file_when_removed() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("bootstrap files should be created");
        std::fs::remove_file(&paths.bootstrap).expect("BOOTSTRAP.md should be removable");

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "ok".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("hello").await.expect("turn should succeed");

        let requests = captured_requests.lock().unwrap();
        let system = requests[0]
            .system
            .as_ref()
            .expect("system prompt should be set");
        assert!(!system.contains("## BOOTSTRAP.md"));
    }

    #[tokio::test]
    async fn bootstrap_prompt_respects_per_file_and_total_limits() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("bootstrap files should be created");

        std::fs::write(&paths.soul, "ABCDEFGHIJKLMNOPQRSTUVWXYZ").expect("should write SOUL.md");
        std::fs::write(&paths.user, "01234567890123456789").expect("should write USER.md");
        std::fs::remove_file(&paths.bootstrap).expect("BOOTSTRAP.md should be removable");

        let mut config = Config::default_template();
        config.limits.max_bootstrap_file_bytes = 20;
        config.limits.max_prompt_bootstrap_bytes = "## SOUL.md\n".len() + 20;

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "ok".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("hello").await.expect("turn should succeed");

        let requests = captured_requests.lock().unwrap();
        let system = requests[0]
            .system
            .as_ref()
            .expect("system prompt should be set");

        assert!(system.contains("## SOUL.md"));
        assert!(system.contains("ABCDEFGHIJKLMNOPQRST"));
        assert!(!system.contains("UVWXYZ"));
        assert!(!system.contains("## USER.md"));
    }

    #[test]
    fn exec_policy_covers_deny_allow_and_confirm() {
        let mut security = SecurityConfig::default();
        security.exec_allow.push("echo".into());

        let deny = exec_policy(
            &NormalizedExec {
                program: "bash".into(),
                args: vec!["-c".into(), "ls".into()],
                cwd: None,
            },
            &security,
            &Default::default(),
        );
        assert!(matches!(deny, PolicyDecision::Deny(_)));

        let allow = exec_policy(
            &NormalizedExec {
                program: "echo".into(),
                args: vec!["hello".into()],
                cwd: None,
            },
            &security,
            &Default::default(),
        );
        assert!(matches!(allow, PolicyDecision::AutoAllow));

        let confirm = exec_policy(
            &NormalizedExec {
                program: "ls".into(),
                args: vec![],
                cwd: None,
            },
            &security,
            &Default::default(),
        );
        assert!(matches!(confirm, PolicyDecision::NeedsConfirm(_)));
    }

    #[test]
    fn sandbox_blocks_paths_outside_roots_and_symlink_escapes() {
        let temp = TempRoot::new();
        let root = temp.path.join("root");
        let outside = temp.path.join("outside");
        fs::create_dir_all(&root).unwrap();
        fs::create_dir_all(&outside).unwrap();
        fs::write(root.join("inside.txt"), "ok").unwrap();
        fs::write(outside.join("secret.txt"), "nope").unwrap();
        std::os::unix::fs::symlink(outside.join("secret.txt"), root.join("link.txt")).unwrap();

        let roots = vec![root.clone()];
        assert!(sandbox::check(&root.join("inside.txt"), &roots).is_ok());
        assert!(sandbox::check(&outside.join("secret.txt"), &roots).is_err());
        assert!(sandbox::check(&root.join("link.txt"), &roots).is_err());
    }

    #[tokio::test]
    async fn web_policy_guards_scheme_ssrf_dns_and_host_rules() {
        let mut config = WebSecurityConfig::default();
        config.timeout_s = 1;

        assert!(matches!(
            web_policy("file:///tmp/test", &config).await,
            PolicyDecision::Deny(_)
        ));
        assert!(matches!(
            web_policy("http://127.0.0.1/test", &config).await,
            PolicyDecision::Deny(_)
        ));
        assert!(matches!(
            web_policy("http://definitely-not-a-real-host.invalid", &config).await,
            PolicyDecision::Deny(_)
        ));

        let mut allow = WebSecurityConfig::default();
        allow.allow_hosts = vec!["example.com".into()];
        allow.timeout_s = 0;
        assert!(matches!(
            web_policy("https://news.ycombinator.com", &allow).await,
            PolicyDecision::Deny(_)
        ));

        let mut timeout = WebSecurityConfig::default();
        timeout.timeout_s = 0;
        assert!(matches!(
            web_policy("https://example.com", &timeout).await,
            PolicyDecision::Deny(_)
        ));

        let mut deny = WebSecurityConfig::default();
        deny.deny_hosts = vec!["example.com".into()];
        assert!(matches!(
            web_policy("https://example.com", &deny).await,
            PolicyDecision::Deny(_)
        ));
    }

    #[tokio::test]
    async fn request_input_tool_continues_with_submitted_value() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![InputResponse::Submitted("blue".into())])),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"favorite color?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Thanks, I noted blue.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel
            .run_turn("help me")
            .await
            .expect("turn should succeed");
        let recorded = events.lock().unwrap();

        assert!(!summary.hit_turn_limit);
        assert!(
            matches!(&recorded[1], KernelEvent::ToolCall { name, .. } if name == "request_input")
        );
        assert!(
            matches!(&recorded[2], KernelEvent::ToolResult { name, ok, content } if name == "request_input" && *ok && content == "blue")
        );
        assert!(
            matches!(&recorded[4], KernelEvent::AssistantText(text) if text == "Thanks, I noted blue.")
        );
    }

    #[tokio::test]
    async fn request_input_tool_surfaces_cancelled_state() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![InputResponse::Cancelled])),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"anything else?\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "No extra input arrived.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("help me")
            .await
            .expect("turn should succeed");
        let recorded = events.lock().unwrap();

        assert!(
            matches!(&recorded[2], KernelEvent::ToolResult { name, ok, content } if name == "request_input" && !*ok && content.contains("cancelled"))
        );
    }

    #[tokio::test]
    async fn tool_output_is_truncated_per_call_limit() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.limits.max_tool_output_bytes_per_call = 4;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![InputResponse::Submitted("123456789".into())])),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"x\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("truncate")
            .await
            .expect("turn should succeed");
        let recorded = events.lock().unwrap();
        assert!(
            matches!(&recorded[2], KernelEvent::ToolResult { content, .. } if content == "1234")
        );
    }

    #[tokio::test]
    async fn tool_loop_budget_enforcement_sets_hit_turn_limit() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.limits.max_tool_calls_per_turn = 1;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![
                    InputResponse::Submitted("first".into()),
                    InputResponse::Submitted("second".into()),
                ])),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"one\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"two\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel
            .run_turn("budget")
            .await
            .expect("turn should succeed");
        let recorded = events.lock().unwrap();
        assert!(summary.hit_turn_limit);
        assert!(
            matches!(&recorded.last().unwrap(), KernelEvent::TurnDone { hit_turn_limit } if *hit_turn_limit)
        );
    }

    #[tokio::test]
    async fn process_exec_session_approval_is_cached_exactly() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let confirm = Arc::new(QueueConfirm::new(vec![ConfirmDecision::AllowSession]));
        let seen = confirm.seen();

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(
                Arc::clone(&events),
                confirm,
                Arc::new(NoopInput),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({"name":"process_exec","input":{"program":"/bin/echo","args":["hello"]}})
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done one".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({"name":"process_exec","input":{"program":"/bin/echo","args":["hello"]}})
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done two".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("one")
            .await
            .expect("first turn should succeed");
        kernel
            .run_turn("two")
            .await
            .expect("second turn should succeed");

        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn skill_discovery_is_fail_soft_for_invalid_files() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        write_skill(
            &paths,
            "good-skill",
            "A valid skill",
            "request_input",
            "Do good things.",
        );
        let broken_dir = paths.skills.join("broken");
        fs::create_dir_all(&broken_dir).unwrap();
        fs::write(broken_dir.join("SKILL.md"), "not frontmatter").unwrap();

        let store = SkillStore::discover(&paths.skills);
        assert_eq!(store.all().len(), 1);
        assert_eq!(store.all()[0].name, "good-skill");
    }

    #[tokio::test]
    async fn invoke_skill_activates_skill_and_renders_args_into_prompt() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(
            &paths,
            "note-taker",
            "Capture notes",
            "write_file request_input",
            "Use write_file to persist notes.",
        );

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"note-taker\",\"args\":{\"topic\":\"retro\"}}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Skill is active now.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Using the active skill.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("activate it")
            .await
            .expect("turn should pass");
        kernel.run_turn("use it").await.expect("turn should pass");

        let requests = captured_requests.lock().unwrap();
        let second_turn_system = requests[2].system.as_ref().unwrap();
        assert!(second_turn_system.contains("Available skill manifests:"));
        assert!(second_turn_system.contains("note-taker: Capture notes"));
        assert!(second_turn_system.contains("Active skill bodies:"));
        assert!(second_turn_system.contains("Invocation arguments (JSON):"));
        assert!(second_turn_system.contains("\"topic\": \"retro\""));
        assert!(second_turn_system.contains("Use write_file to persist notes."));
    }

    #[tokio::test]
    async fn invoke_skill_rejects_args_over_limit() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(
            &paths,
            "small-skill",
            "Small skill",
            "request_input",
            "Body",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.limits.max_skill_args_bytes = 8;
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"small-skill\",\"args\":{\"long\":\"1234567890\"}}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("activate").await.expect("turn should pass");
        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "invoke_skill" && !*ok && content.contains("max_skill_args_bytes")
        )));
    }

    #[tokio::test]
    async fn create_skill_writes_file_and_created_skill_can_be_invoked() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let captured_requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name":"create_skill",
                                "input":{
                                    "name":"weather-note",
                                    "description":"Capture weather notes",
                                    "allowed_tools":["request_input"],
                                    "body":"Ask for weather details with request_input."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "created".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"weather-note\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "invoked".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "final".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("create skill")
            .await
            .expect("create turn should pass");
        assert!(paths.skills.join("weather-note").join("SKILL.md").exists());

        kernel
            .run_turn("invoke skill")
            .await
            .expect("invoke turn should pass");
        kernel
            .run_turn("use skill")
            .await
            .expect("use turn should pass");

        let requests = captured_requests.lock().unwrap();
        let last_system = requests.last().unwrap().system.as_ref().unwrap();
        assert!(last_system.contains("weather-note"));
        assert!(last_system.contains("Ask for weather details with request_input."));
    }

    #[tokio::test]
    async fn create_skill_overwrite_requires_confirm() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(&paths, "overwrite-me", "Old", "request_input", "Old body");
        let events = Arc::new(Mutex::new(Vec::new()));
        let confirm = Arc::new(QueueConfirm::new(vec![ConfirmDecision::Deny]));
        let seen = confirm.seen();

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(Arc::clone(&events), confirm, Arc::new(NoopInput)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name":"create_skill",
                                "input":{
                                    "name":"overwrite-me",
                                    "description":"New",
                                    "allowed_tools":["request_input"],
                                    "body":"New body"
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("overwrite")
            .await
            .expect("turn should pass");
        assert_eq!(seen.lock().unwrap().len(), 1);
        let persisted =
            fs::read_to_string(paths.skills.join("overwrite-me").join("SKILL.md")).unwrap();
        assert!(persisted.contains("Old body"));
    }

    #[tokio::test]
    async fn skill_frontmatter_preview_parses_intents_and_contributed_agents() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let skill_dir = paths.skills.join("planner");
        fs::create_dir_all(skill_dir.join("agents")).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            concat!(
                "---\n",
                "name: planner\n",
                "description: Planner skill\n",
                "intents:\n",
                "  - schedule\n",
                "agents:\n",
                "  - agents/researcher.md\n",
                "allowed-tools: list_jobs\n",
                "---\n\n",
                "Plan scheduled work carefully.\n"
            ),
        )
        .unwrap();
        fs::write(
            skill_dir.join("agents/researcher.md"),
            concat!(
                "---\n",
                "name: researcher\n",
                "description: Research delegated work\n",
                "allowed-tools: read_file\n",
                "---\n\n",
                "Only read files and summarize findings.\n"
            ),
        )
        .unwrap();

        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                Vec::new(),
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let skill = kernel
            .list_skills()
            .iter()
            .find(|skill| skill.name == "planner")
            .expect("planner skill should load");
        assert_eq!(skill.intents, vec![Intent::Schedule]);
        assert_eq!(skill.agents.len(), 1);
        assert_eq!(skill.agents[0].name, "planner/researcher");
        assert_eq!(skill.agents[0].allowed_tools, vec!["read_file"]);

        let agents = kernel.list_agents();
        assert_eq!(agents.len(), 1);
        assert_eq!(agents[0].name, "planner/researcher");
    }

    #[tokio::test]
    async fn explicit_skill_intents_drive_intent_hint_prompt() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_raw(
            &paths,
            "planner",
            concat!(
                "---\n",
                "name: planner\n",
                "description: General planning helper\n",
                "intents:\n",
                "  - schedule\n",
                "allowed-tools: list_jobs\n",
                "---\n\n",
                "Use daemon job tools for recurring work.\n"
            ),
        );
        let captured_requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "scheduled".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("schedule a recurring review")
            .await
            .expect("turn should pass");

        let requests = captured_requests.lock().unwrap();
        let system = requests[0].system.as_ref().unwrap();
        assert!(system.contains("Resolved intent: schedule"));
        assert!(system.contains("Likely relevant skills for this intent:"));
        assert!(system.contains("planner: General planning helper"));
    }

    #[tokio::test]
    async fn contributed_agent_registry_can_shape_spawned_subagent_policy() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let skill_dir = paths.skills.join("planner");
        fs::create_dir_all(skill_dir.join("agents")).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            concat!(
                "---\n",
                "name: planner\n",
                "description: Planning skill\n",
                "agents:\n",
                "  - agents/researcher.md\n",
                "---\n\n",
                "Spawn researcher when deeper reading is needed.\n"
            ),
        )
        .unwrap();
        fs::write(
            skill_dir.join("agents/researcher.md"),
            concat!(
                "---\n",
                "name: researcher\n",
                "description: Research helper\n",
                "allowed-tools: read_file\n",
                "---\n\n",
                "Only use read_file.\n"
            ),
        )
        .unwrap();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "planner/researcher",
                                    "prompt": "Try to run a shell command."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"blocked\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_DONE".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "ROOT_DONE".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("delegate").await.expect("turn should pass");

        let recorded_requests = requests.lock().unwrap();
        assert!(recorded_requests[1]
            .system
            .as_ref()
            .unwrap()
            .contains("Current agent: planner/researcher"));
        assert!(recorded_requests[1].messages[0]
            .content
            .contains("Registered agent prompt (planner/researcher)"));
        assert!(
            recorded_requests[2]
                .messages
                .last()
                .unwrap()
                .content
                .contains("not permitted by active skill"),
            "contributed agent allowed-tools should fence spawned sub-agent tools"
        );
    }

    #[tokio::test]
    async fn run_job_turn_fires_job_hooks_and_keeps_attached_skills_active() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(
            &paths,
            "job-helper",
            "Job helper",
            "request_input",
            "Use request_input to collect missing detail.",
        );
        let seen = Arc::new(Mutex::new(Vec::new()));
        let captured_requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "JOB_OK".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.register_hook(
            HookPoint::BeforeJobRun,
            Arc::new(RecordingHook {
                label: "before_job",
                seen: seen.clone(),
            }),
        );
        kernel.register_hook(
            HookPoint::AfterJobRun,
            Arc::new(RecordingHook {
                label: "after_job",
                seen: seen.clone(),
            }),
        );
        kernel
            .activate_session_skill("job-helper", None)
            .expect("skill should activate");

        let summary = kernel
            .run_job_turn("nightly-check", "collect missing info")
            .await
            .expect("job turn should pass");
        assert!(!summary.hit_turn_limit);

        let seen = seen.lock().unwrap();
        assert_eq!(
            seen.iter()
                .map(|(label, _)| label.as_str())
                .collect::<Vec<_>>(),
            vec!["before_job", "after_job"]
        );

        let requests = captured_requests.lock().unwrap();
        let system = requests[0].system.as_ref().unwrap();
        assert!(system.contains("### Skill: job-helper"));
        assert!(system.contains("Use request_input to collect missing detail."));
    }

    #[tokio::test]
    async fn active_skill_fence_blocks_tools_outside_allowed_set() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(
            &paths,
            "writer-only",
            "Can only write files",
            "write_file",
            "Only use write_file.",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![InputResponse::Submitted("hi".into())])),
            ),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"writer-only\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"still allowed?\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"blocked\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("activate and continue")
            .await
            .expect("turn");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "request_input" && *ok && content == "hi"
        )));
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "process_exec" && !*ok && content.contains("not permitted by active skill")
        )));
    }

    #[tokio::test]
    async fn active_skills_do_not_bypass_global_fs_or_exec_policy() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill(
            &paths,
            "bypass-attempt",
            "Attempts to bypass policy",
            "process_exec write_file",
            "Try the dangerous thing.",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"bypass-attempt\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"bash\",\"args\":[\"-c\",\"echo nope\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"write_file\",\"input\":{\"path\":\"/tmp/outside.txt\",\"content\":\"oops\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("activate and continue")
            .await
            .expect("turn");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "process_exec" && !*ok && content.contains("denied by policy")
        )));
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "write_file" && !*ok && content.contains("outside configured roots")
        )));
    }

    #[test]
    fn write_memory_summary_updates_index_and_deduplicates_entries() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: Some("projects/rust.md".into()),
                content: "# Rust\n\nFavorite language.\n".into(),
                mode: WriteMemoryMode::Write,
                summary: Some("Language preferences".into()),
            },
        )
        .unwrap();

        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: Some("projects/rust.md".into()),
                content: "Still Rust.\n".into(),
                mode: WriteMemoryMode::Append,
                summary: None,
            },
        )
        .unwrap();

        let index = fs::read_to_string(&paths.memory_index).unwrap();
        assert!(index.contains("- [[projects/rust.md]] — Language preferences"));
        assert_eq!(index.matches("[[projects/rust.md]]").count(), 1);
    }

    #[test]
    fn write_memory_derives_summary_when_missing() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: Some("people/alex.md".into()),
                content: "# Alex\n\nPrefers async updates.\n".into(),
                mode: WriteMemoryMode::Write,
                summary: None,
            },
        )
        .unwrap();

        let index = fs::read_to_string(&paths.memory_index).unwrap();
        assert!(index.contains("- [[people/alex.md]] — Alex"));
    }

    #[test]
    fn write_memory_daily_appends_to_todays_note() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: None,
                content: "first note".into(),
                mode: WriteMemoryMode::Daily,
                summary: None,
            },
        )
        .unwrap();
        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: None,
                content: "second note".into(),
                mode: WriteMemoryMode::Daily,
                summary: None,
            },
        )
        .unwrap();

        let daily = fs::read_dir(&paths.memory_daily)
            .unwrap()
            .flatten()
            .next()
            .unwrap()
            .path();
        let content = fs::read_to_string(daily).unwrap();
        assert!(content.contains("first note"));
        assert!(content.contains("second note"));
    }

    #[test]
    fn prompt_memory_respects_byte_limit() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::write(
            &paths.memory_index,
            "# MEMORY\n\n- [[topics/one.md]] — 1234567890\n- [[topics/two.md]] — abcdefghij\n",
        )
        .unwrap();

        let sections = memory::load_prompt_memory(&paths, 30).unwrap();
        let joined = sections.join("\n");
        assert!(joined.contains("## MEMORY.md"));
        assert!(!joined.contains("two.md"));
    }

    #[tokio::test]
    async fn fresh_kernel_session_recalls_memory_from_files_not_chat_history() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();

        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: Some("topics/preferences.md".into()),
                content: "# Preferences\n\nFavorite language is Rust.\n".into(),
                mode: WriteMemoryMode::Write,
                summary: Some("Favorite language is Rust".into()),
            },
        )
        .unwrap();
        memory::write_memory(
            &paths,
            WriteMemoryInput {
                path: None,
                content: "today we confirmed recall".into(),
                mode: WriteMemoryMode::Daily,
                summary: None,
            },
        )
        .unwrap();

        let captured_requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                captured_requests.clone(),
                vec![CompletionResponse {
                    text: "I remember.".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("what do you remember?").await.unwrap();

        let requests = captured_requests.lock().unwrap();
        let system = requests[0].system.as_ref().unwrap();
        assert!(system.contains("## MEMORY.md"));
        assert!(system.contains("Favorite language is Rust"));
        assert!(system.contains("## Today's daily note"));
        assert!(system.contains("today we confirmed recall"));
    }

    fn test_pricing() -> Pricing {
        Pricing {
            prompt_per_token_usd: 0.001,
            completion_per_token_usd: 0.002,
            cache_read_per_token_usd: 0.0,
            cache_create_per_token_usd: 0.0,
            request_usd: 0.0,
        }
    }

    struct TestFactory {
        provider_name: &'static str,
        seen: Arc<Mutex<Vec<Provider>>>,
        requests: Arc<Mutex<Vec<CompletionRequest>>>,
        responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
        pricing: Option<Pricing>,
    }

    impl TestFactory {
        fn new(
            provider_name: &'static str,
            responses: Vec<CompletionResponse>,
            pricing: Option<Pricing>,
        ) -> Self {
            Self {
                provider_name,
                seen: Arc::new(Mutex::new(Vec::new())),
                requests: Arc::new(Mutex::new(Vec::new())),
                responses: Arc::new(Mutex::new(responses.into())),
                pricing,
            }
        }

        fn with_seen(
            provider_name: &'static str,
            seen: Arc<Mutex<Vec<Provider>>>,
            responses: Vec<CompletionResponse>,
            pricing: Option<Pricing>,
        ) -> Self {
            Self {
                provider_name,
                seen,
                requests: Arc::new(Mutex::new(Vec::new())),
                responses: Arc::new(Mutex::new(responses.into())),
                pricing,
            }
        }

        fn with_requests(
            provider_name: &'static str,
            requests: Arc<Mutex<Vec<CompletionRequest>>>,
            responses: Vec<CompletionResponse>,
            pricing: Option<Pricing>,
        ) -> Self {
            Self {
                provider_name,
                seen: Arc::new(Mutex::new(Vec::new())),
                requests,
                responses: Arc::new(Mutex::new(responses.into())),
                pricing,
            }
        }
    }

    #[async_trait]
    impl ProviderFactory for TestFactory {
        async fn build(
            &self,
            model_config: &ModelConfig,
        ) -> Result<Box<dyn LlmProvider>, LlmError> {
            self.seen.lock().unwrap().push(model_config.provider);
            Ok(Box::new(TestProvider {
                provider_name: self.provider_name,
                requests: Arc::clone(&self.requests),
                responses: Arc::clone(&self.responses),
                pricing: self.pricing,
            }))
        }
    }

    struct TestProvider {
        provider_name: &'static str,
        requests: Arc<Mutex<Vec<CompletionRequest>>>,
        responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
        pricing: Option<Pricing>,
    }

    #[async_trait]
    impl LlmProvider for TestProvider {
        async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
            self.requests.lock().unwrap().push(req);
            self.responses
                .lock()
                .unwrap()
                .pop_front()
                .ok_or_else(|| LlmError::Response("no scripted response left".into()))
        }

        fn pricing(&self, _model: &str) -> Option<Pricing> {
            self.pricing
        }

        fn provider_name(&self) -> &'static str {
            self.provider_name
        }
    }

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repo root should resolve")
    }

    fn install_example_skill(paths: &AllbertPaths) {
        let source = repo_root().join("examples/skills/note-taker/SKILL.md");
        let target_dir = paths.skills.join("note-taker");
        fs::create_dir_all(&target_dir).expect("skill dir should exist");
        fs::write(
            target_dir.join("SKILL.md"),
            fs::read_to_string(source).expect("example skill should be readable"),
        )
        .expect("example skill should be copied");
    }

    fn seed_completed_setup(paths: &AllbertPaths, config: &Config) {
        paths.ensure().expect("paths should exist");
        fs::write(
            &paths.user,
            "# USER\n\n## Preferred name\n- Spuri\n\n## Timezone\n- America/Los_Angeles\n\n## Working style\n- Short updates and concrete next steps.\n\n## Current priorities\n- Ship v0.1 cleanly.\n",
        )
        .expect("USER.md should be writable");
        if paths.bootstrap.exists() {
            fs::remove_file(&paths.bootstrap).expect("BOOTSTRAP.md should be removable");
        }
        config.persist(paths).expect("config should persist");
    }

    async fn run_tool_via_kernel(kernel: &mut Kernel, invocation: ToolInvocation) -> ToolOutput {
        let mut tool_hook_ctx = HookCtx::before_tool(
            &kernel.state.session_id,
            kernel.state.agent_name(),
            None,
            invocation.clone(),
            kernel
                .skills
                .allowed_tool_union(&kernel.state.active_skills),
        );
        match kernel
            .hooks
            .run(HookPoint::BeforeTool, &mut tool_hook_ctx)
            .await
        {
            HookOutcome::Continue => {
                let placeholder = AgentState::new(kernel.state.session_id.clone());
                let mut state = std::mem::replace(&mut kernel.state, placeholder);
                let output = kernel
                    .dispatch_tool_for_state(&mut state, None, invocation)
                    .await;
                kernel.state = state;
                output
            }
            HookOutcome::Abort(message) => ToolOutput {
                content: message,
                ok: false,
            },
        }
    }

    fn latest_assistant_text(events: &Arc<Mutex<Vec<KernelEvent>>>) -> String {
        events
            .lock()
            .unwrap()
            .iter()
            .rev()
            .find_map(|event| match event {
                KernelEvent::AssistantText(text) => Some(text.clone()),
                _ => None,
            })
            .expect("assistant text event should exist")
    }

    fn trace_file_exists(paths: &AllbertPaths) -> bool {
        fs::read_dir(&paths.traces)
            .expect("trace dir should exist")
            .flatten()
            .any(|entry| entry.path().is_file())
    }

    async fn run_live_release_smoke(
        start_provider: Provider,
        start_model_id: &str,
        start_api_key_env: &str,
        switch_provider: Provider,
        switch_model_id: &str,
        switch_api_key_env: &str,
    ) {
        assert!(
            std::env::var_os(start_api_key_env).is_some(),
            "{start_api_key_env} must be set for live smoke"
        );
        assert!(
            std::env::var_os(switch_api_key_env).is_some(),
            "{switch_api_key_env} must be set for live smoke"
        );

        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let workspace_root = repo_root();

        let mut config = Config::default_template();
        config.trace = true;
        config.setup.version = 1;
        config.model.provider = start_provider;
        config.model.model_id = start_model_id.into();
        config.model.api_key_env = start_api_key_env.into();
        config.model.max_tokens = 64;
        config.security.fs_roots = vec![workspace_root.clone()];

        seed_completed_setup(&paths, &config);
        install_example_skill(&paths);

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(events.clone()),
            paths.clone(),
            Arc::new(llm::DefaultProviderFactory::default()),
        )
        .await
        .expect("live kernel should boot");

        kernel
            .run_turn(
                "If the runtime context says the preferred name is Spuri, reply with exactly PROFILE_OK and nothing else.",
            )
            .await
            .expect("profile prompt should succeed");
        assert_eq!(latest_assistant_text(&events).trim(), "PROFILE_OK");

        let cargo_toml = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "read_file".into(),
                input: json!({ "path": workspace_root.join("Cargo.toml").display().to_string() }),
            },
        )
        .await;
        assert!(cargo_toml.ok, "trusted-root file read should succeed");
        assert!(cargo_toml.content.contains("allbert-kernel"));

        let denied = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "read_file".into(),
                input: json!({ "path": "/etc/passwd" }),
            },
        )
        .await;
        assert!(!denied.ok, "out-of-root read should be denied");

        let written = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "write_memory".into(),
                input: json!({
                    "path": "projects/release-smoke.md",
                    "content": "# Release Smoke\n\nLive provider smoke succeeded.\n",
                    "mode": "write",
                    "summary": "Live provider smoke succeeded"
                }),
            },
        )
        .await;
        assert!(written.ok);

        let read_back = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "read_memory".into(),
                input: json!({ "path": "projects/release-smoke.md" }),
            },
        )
        .await;
        assert!(read_back.ok);
        assert!(read_back.content.contains("Live provider smoke succeeded."));

        let skills = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "list_skills".into(),
                input: json!({}),
            },
        )
        .await;
        assert!(skills.ok);
        assert!(skills.content.contains("note-taker"));

        let invoked = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "invoke_skill".into(),
                input: json!({ "name": "note-taker", "args": { "kind": "release-smoke" } }),
            },
        )
        .await;
        assert!(invoked.ok);
        assert_eq!(kernel.active_skills()[0].name, "note-taker");

        assert!(
            paths.costs.exists(),
            "cost log should exist after live turn"
        );
        assert!(trace_file_exists(&paths), "trace file should exist");

        kernel
            .set_model(ModelConfig {
                provider: switch_provider,
                model_id: switch_model_id.into(),
                api_key_env: switch_api_key_env.into(),
                max_tokens: 64,
            })
            .await
            .expect("provider switch should succeed");
        kernel
            .run_turn("Reply with exactly SWITCH_OK and nothing else.")
            .await
            .expect("switched-provider prompt should succeed");
        assert_eq!(latest_assistant_text(&events).trim(), "SWITCH_OK");
        assert!(
            kernel.today_cost_usd().expect("today cost should sum") > 0.0,
            "cost tracking should record live provider usage"
        );
    }

    #[tokio::test]
    #[ignore = "live smoke requires ANTHROPIC_API_KEY and OPENROUTER_API_KEY"]
    async fn anthropic_release_smoke() {
        run_live_release_smoke(
            Provider::Anthropic,
            "claude-sonnet-4-5",
            "ANTHROPIC_API_KEY",
            Provider::Openrouter,
            "anthropic/claude-sonnet-4",
            "OPENROUTER_API_KEY",
        )
        .await;
    }

    #[tokio::test]
    #[ignore = "live smoke requires ANTHROPIC_API_KEY and OPENROUTER_API_KEY"]
    async fn openrouter_release_smoke() {
        run_live_release_smoke(
            Provider::Openrouter,
            "anthropic/claude-sonnet-4",
            "OPENROUTER_API_KEY",
            Provider::Anthropic,
            "claude-sonnet-4-5",
            "ANTHROPIC_API_KEY",
        )
        .await;
    }
}
