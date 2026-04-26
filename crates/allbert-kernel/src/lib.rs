pub mod adapter;
pub mod adapters;
pub mod agent;
pub mod atomic;
mod bootstrap;
pub mod command_catalog;
pub mod config;
pub mod cost;
pub mod error;
pub mod events;
pub mod heartbeat;
pub mod hooks;
pub mod identity;
pub mod intent;
pub mod job_manager;
pub mod learning;
pub mod llm;
pub mod memory;
pub mod paths;
pub mod replay;
pub mod scripting;
pub mod security;
pub mod self_improvement;
pub mod settings;
pub mod skills;
pub mod tools;
pub mod trace;

use std::collections::{BTreeMap, HashSet};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;

pub use adapter::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, DynamicConfirmPrompter, FrontendAdapter,
    InputPrompter, InputRequest, InputResponse,
};
pub use adapters::{
    activate_adapter, active_adapter_for_model, build_adapter_corpus, cleanup_runtime_files,
    deactivate_adapter, golden_pass_rate, load_golden_cases, preview_personality_adapter_training,
    read_adapter_manifest, register_ollama_adapter, render_ascii_loss_curve,
    render_behavioral_diff, run_fixed_evals, run_personality_adapter_training,
    run_personality_adapter_training_with_session, write_adapter_manifest, AdapterActivation,
    AdapterCorpusConfig, AdapterCorpusItem, AdapterCorpusSnapshot, AdapterEvalArtifacts,
    AdapterStore, AdapterTrainer, CancellationToken, DerivedOllamaAdapter, FakeAdapterTrainer,
    GoldenCase, HostedAdapterNotice, LlamaCppLoraTrainer, MlxLoraTrainer, PersonalityAdapterJob,
    TrainerCommand, TrainerError, TrainerHooks, TrainerProgress, TrainingOutcome, TrainingPlan,
    DEFAULT_ADAPTER_COMPUTE_CAP_WALL_SECONDS, DEFAULT_MIN_GOLDEN_PASS_RATE,
    PERSONALITY_ADAPTER_JOB_NAME, PERSONALITY_ADAPTER_SESSION_ID, TRAINER_STDIO_CAPTURE_BYTES,
    TRAINER_TRUNCATION_MARKER,
};
pub use agent::{
    ActiveTurnBudget, Agent, AgentDefinition, AgentState, StagedNoticeEntry, TurnBudget,
};
pub use atomic::atomic_write;
pub use command_catalog::{
    command_catalog, command_catalog_errors, command_groups, CommandDescriptor, CommandGroup,
    CommandGroupDescriptor, CommandSurface,
};
pub use config::{
    ensure_adapter_training_defaults_block, ensure_trace_defaults_block, restore_last_good_config,
    write_last_good_config, ActivityConfig, AdapterTrainingConfig,
    AdapterTrainingDefaultsWriteResult, Config, CrossChannelRouting, DaemonConfig,
    IntentClassifierConfig, JobsConfig, LearningConfig, LimitsConfig, MemoryConfig,
    MemoryEpisodesConfig, MemoryFactsConfig, MemoryRoutingConfig, MemoryRoutingMode,
    MemorySemanticConfig, ModelConfig, OperatorUxConfig, PersonalityDigestConfig, Provider,
    ReplConfig, ReplUiMode, ScriptingConfig, ScriptingEngineConfig, SecurityConfig,
    SelfImprovementConfig, SelfImprovementInstallMode, SessionsConfig, SetupConfig,
    StatusLineConfig, StatusLineItem, TraceConfig, TraceDefaultsWriteResult, TraceFieldPolicy,
    TraceRedactionConfig, TuiConfig, TuiSpinnerStyle, WebSecurityConfig, CURRENT_SETUP_VERSION,
};
pub use cost::CostEntry;
pub use error::{
    append_error_hint, error_hint_for_message, ConfigError, KernelError, SkillError, ToolError,
};
pub use events::{ActivityTransition, KernelEvent};
pub use heartbeat::{
    check_in_enabled, load_heartbeat_record, parse_heartbeat_markdown, quiet_hours_active,
    supports_proactive_delivery, validate_heartbeat_record, HeartbeatCheckIn, HeartbeatCheckIns,
    HeartbeatInboxNag, HeartbeatNagCadence, HeartbeatRecord, HeartbeatValidation,
};
pub use hooks::{
    BootstrapContextHook, CostHook, Hook, HookCtx, HookOutcome, HookPoint, MemoryIndexHook,
};
pub use identity::{
    add_identity_channel, ensure_identity_record, identity_inconsistencies, load_identity_record,
    remove_identity_channel, rename_identity, resolve_identity_id_for_sender, save_identity_record,
    IdentityChannelBinding, IdentityConsistency, IdentityRecord, LEGACY_SENTINEL_IDENTITY,
    LOCAL_REPL_SENDER,
};
pub use intent::Intent;
pub use job_manager::{JobManager, ListJobRunsInput, NamedJobInput, UpsertJobInput};
pub use learning::{
    preview_personality_digest, resolve_digest_output_path, run_personality_digest, LearningCorpus,
    LearningCorpusItem, LearningCorpusSummary, LearningJob, LearningJobContext, LearningJobReport,
    LearningOutputArtifact, PersonalityDigestJob, PersonalityDigestPreview,
};
pub use llm::{ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, Usage};
pub use memory::{
    MemoryFact, MemoryTier, SearchMemoryHit, SearchMemoryInput, StageMemoryInput, StagedMemoryKind,
};
pub use memory::{ReadMemoryInput, WriteMemoryInput, WriteMemoryMode};
pub use paths::AllbertPaths;
pub use replay::{
    apply_trace_gc, export_session_otlp_json, plan_trace_gc, read_session_trace_dir,
    recover_all_in_flight_spans, trace_artifact_bytes, trace_artifact_count, ActiveTraceSpan,
    JsonlTraceWriter, SecretRedactor, TraceCapturePolicy, TraceGcCandidate, TraceGcPlan,
    TraceGcResult, TraceReadResult, TraceReadWarning, TraceReader, TraceRecord, TraceRecordError,
    TraceRecordType, TraceStorageLimits, TraceStoreError, TraceWriter, TracingHooks,
    TRACE_RECORD_SCHEMA_VERSION,
};
pub use scripting::{
    BudgetUsed, CapKind, LoadedScript, LuaEngine, LuaSandboxPolicy, ScriptBudget, ScriptOutcome,
    ScriptingCapabilities, ScriptingEngine, ScriptingError, LUA_MAX_EXECUTION_MS_CEILING,
    LUA_MAX_MEMORY_KB_CEILING, LUA_MAX_OUTPUT_BYTES_CEILING,
};
pub use security::SecurityHook;
pub use self_improvement::{
    assert_rust_rebuild_ready, check_self_improvement_write_target, collect_worktree_gc,
    create_rust_rebuild_worktree, emit_patch_artifact, ensure_worktree_creation_allowed,
    has_pinned_rust_toolchain, render_bytes, resolve_source_checkout, resolve_source_checkout_from,
    resolve_worktree_root, run_tier_a_validation, run_validation_commands,
    tier_a_validation_commands, worktree_disk_usage, PatchArtifact, RebuildWorktree,
    ResolvedSourceCheckout, SourceCheckoutSource, TierAValidationReport, ValidationCommand,
    ValidationOverall, ValidationStepResult, WorktreeDiskEntry, WorktreeDiskUsage,
    WorktreeGcReport,
};
pub use settings::{
    find_setting, persist_setting_value, reset_setting_value, settings_catalog,
    settings_catalog_errors, settings_for_config, validate_setting_value, SettingDescriptor,
    SettingMutation, SettingPathPolicy, SettingPersistenceError, SettingRedactionPolicy,
    SettingRestartRequirement, SettingValidationError, SettingValueType, SettingView,
    SettingsGroup,
};
pub use skills::{
    ActiveSkill, ContributedAgent, CreateSkillInput, InvokeSkillInput, Skill, SkillProvenance,
    SkillStore,
};
pub use tools::{ProcessExecInput, ToolCtx, ToolInvocation, ToolOutput, ToolRegistry, ToolRuntime};
pub use trace::TraceHandles;

use hooks::HookRegistry;
use intent::{classify_by_rules, default_intent};
use llm::{CompletionRequest, DefaultProviderFactory, LlmProvider, ProviderFactory};
use replay::new_trace_id;

struct DailyCostCache {
    utc_day: time::Date,
    total_usd: f64,
    refreshed_at: Instant,
}

pub fn refresh_agents_markdown(paths: &AllbertPaths) -> Result<String, KernelError> {
    paths.ensure()?;
    let config = Config::load_or_create(paths)?;
    let skills = SkillStore::discover(&paths.skills);
    let rendered = skills.render_agents_markdown_with_routing(&config.memory.routing);
    atomic_write(&paths.agents_notes, rendered.as_bytes()).map_err(|e| {
        KernelError::InitFailed(format!("write {}: {e}", paths.agents_notes.display()))
    })?;
    Ok(rendered)
}

#[derive(Debug)]
pub struct TurnSummary {
    pub hit_turn_limit: bool,
    pub stop_reason: Option<String>,
}

fn render_user_input_for_history(user_input: &str, attachments: &[ChatAttachment]) -> String {
    if attachments.is_empty() {
        return user_input.to_string();
    }

    let mut rendered = user_input.trim().to_string();
    if rendered.is_empty() {
        rendered = "Please analyze the attached image.".into();
    }
    for attachment in attachments {
        let kind = match attachment.kind {
            ChatAttachmentKind::Image => "image",
            ChatAttachmentKind::File => "file",
            ChatAttachmentKind::Audio => "audio",
            ChatAttachmentKind::Other => "attachment",
        };
        rendered.push_str(&format!(
            "\n[Attached {kind}: {}]",
            attachment.path.display()
        ));
    }
    rendered
}

fn summarize_tool_invocation(name: &str, input: &serde_json::Value) -> String {
    match input {
        serde_json::Value::Object(map) => {
            for key in ["path", "file", "query", "command", "name"] {
                if let Some(value) = map.get(key).and_then(|value| value.as_str()) {
                    let value = redact_activity_summary(value);
                    return format!("{name} {value}");
                }
            }
            format!("{name} with {} fields", map.len())
        }
        _ => name.to_string(),
    }
}

fn redact_activity_summary(value: &str) -> String {
    let first = value.split_whitespace().next().unwrap_or(value);
    if first.to_ascii_lowercase().contains("token")
        || first.to_ascii_lowercase().contains("secret")
        || first.starts_with("sk-")
    {
        "[redacted]".into()
    } else if first.chars().count() > 80 {
        format!("{}...", first.chars().take(77).collect::<String>())
    } else {
        first.to_string()
    }
}

fn build_trace_hooks(
    config: &Config,
    paths: &AllbertPaths,
    session_id: &str,
) -> Result<Option<Arc<dyn TracingHooks>>, KernelError> {
    if !config.trace.enabled {
        return Ok(None);
    }
    let writer = JsonlTraceWriter::with_policy(
        paths,
        session_id,
        TraceStorageLimits::from_session_cap_mb(config.trace.session_disk_cap_mb.into()),
        config.trace.clone().into(),
    )
    .map_err(|err| KernelError::Trace(err.to_string()))?;
    let recovered = writer
        .recover_in_flight()
        .map_err(|err| KernelError::Trace(err.to_string()))?;
    if !recovered.is_empty() {
        tracing::warn!(
            session = %session_id,
            recovered = recovered.len(),
            "recovered stale in-flight trace spans"
        );
    }
    Ok(Some(Arc::new(writer)))
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SessionSnapshot {
    pub session_id: String,
    pub root_agent_name: String,
    pub messages: Vec<ChatMessage>,
    pub active_skills: Vec<ActiveSkill>,
    pub turn_count: u32,
    pub cost_total_usd: f64,
    #[serde(default)]
    pub session_usage: llm::Usage,
    pub last_resolved_intent: Option<Intent>,
    pub last_agent_stack: Vec<String>,
    pub ephemeral_memory: Vec<String>,
    pub model: ModelConfig,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KernelMemoryStatus {
    pub synopsis_bytes: usize,
    pub ephemeral_bytes: usize,
    pub durable_count: usize,
    pub staged_count: usize,
    pub staged_this_turn: usize,
    pub prefetch_hit_count: usize,
    pub episode_count: usize,
    pub fact_count: usize,
}

fn usage_to_payload(usage: &Usage) -> allbert_proto::TokenUsagePayload {
    allbert_proto::TokenUsagePayload {
        input_tokens: usage.input_tokens,
        output_tokens: usage.output_tokens,
        cache_read_tokens: usage.cache_read,
        cache_create_tokens: usage.cache_create,
        total_tokens: usage
            .input_tokens
            .saturating_add(usage.output_tokens)
            .saturating_add(usage.cache_read)
            .saturating_add(usage.cache_create),
    }
}

#[derive(Debug, Clone, serde::Deserialize)]
struct SpawnSubagentInput {
    name: String,
    prompt: String,
    #[serde(default)]
    context: Option<serde_json::Value>,
    #[serde(default)]
    memory_hints: Option<Vec<String>>,
    #[serde(default)]
    budget: Option<SpawnBudgetInput>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct SpawnBudgetInput {
    #[serde(default)]
    usd: Option<f64>,
    #[serde(default)]
    seconds: Option<u64>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct ReadReferenceInput {
    skill: String,
    path: String,
    #[serde(default)]
    max_bytes: Option<usize>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct RunSkillScriptInput {
    skill: String,
    script: String,
    #[serde(default)]
    args: Vec<String>,
    #[serde(default)]
    input: Option<serde_json::Value>,
    #[serde(default)]
    budget: Option<scripting::ScriptBudget>,
    #[serde(default)]
    timeout_s: Option<u64>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct ListStagedMemoryInput {
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct PromoteStagedMemoryInput {
    id: String,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    summary: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct RejectStagedMemoryInput {
    id: String,
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
struct ForgetMemoryInput {
    target: String,
}

#[derive(Debug, Clone, serde::Serialize)]
struct SpawnSubagentResult {
    agent_name: String,
    parent_agent_name: String,
    hit_turn_limit: bool,
    cost_usd: f64,
    assistant_text: Option<String>,
    stop_reason: Option<String>,
}

struct AgentRunSummary {
    hit_turn_limit: bool,
    assistant_text: Option<String>,
    stop_reason: Option<String>,
}

#[derive(Debug, Clone, Copy)]
struct RequestedTurnBudget {
    usd: Option<f64>,
    seconds: Option<u64>,
}

struct IntentShape {
    prompt_preamble: &'static str,
    tool_priority_order: &'static [&'static str],
}

#[derive(Debug, Clone)]
struct TraceContext {
    session_id: String,
    trace_id: String,
    parent_span_id: String,
}

#[derive(Debug, Clone)]
struct TraceParent {
    trace_id: String,
    span_id: String,
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
    dynamic_confirm: DynamicConfirmPrompter,
    daily_cost_cache: Option<DailyCostCache>,
    pending_turn_cost_override_reason: Option<String>,
    pending_turn_budget_override: RequestedTurnBudget,
    #[allow(dead_code)]
    trace: TraceHandles,
    trace_hooks: Option<Arc<dyn TracingHooks>>,
    trace_context_stack: Vec<TraceContext>,
    adapter_notice_sessions: HashSet<String>,
}

struct KernelToolRuntime<'a> {
    kernel: &'a mut Kernel,
    state: &'a mut AgentState,
    parent_agent_name: Option<String>,
}

#[async_trait::async_trait]
impl ToolRuntime for KernelToolRuntime<'_> {
    fn read_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_read_memory(input)
    }

    fn write_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_write_memory(input)
    }

    fn search_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_search_memory(input)
    }

    async fn stage_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel
            .dispatch_stage_memory(self.state, self.parent_agent_name.clone(), input)
            .await
    }

    fn list_staged_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_list_staged_memory(input)
    }

    async fn promote_staged_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel
            .dispatch_promote_staged_memory(self.state, self.parent_agent_name.clone(), input)
            .await
    }

    fn reject_staged_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_reject_staged_memory(input)
    }

    async fn forget_memory(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel
            .dispatch_forget_memory(self.state, self.parent_agent_name.clone(), input)
            .await
    }

    fn list_skills(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_list_skills(input)
    }

    fn invoke_skill(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_invoke_skill(self.state, input)
    }

    fn read_reference(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_read_reference(self.state, input)
    }

    async fn run_skill_script(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel
            .dispatch_run_skill_script(self.state, input)
            .await
    }

    fn create_skill(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel.dispatch_create_skill(input)
    }

    async fn spawn_subagent(&mut self, input: serde_json::Value) -> ToolOutput {
        self.kernel
            .dispatch_spawn_subagent(self.state, self.parent_agent_name.clone(), input)
            .await
    }
}

impl Kernel {
    pub async fn boot(config: Config, adapter: FrontendAdapter) -> Result<Self, KernelError> {
        let paths = AllbertPaths::from_home()?;
        Self::boot_with_parts(
            config,
            adapter,
            paths.clone(),
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
        memory::bootstrap_curated_memory(&paths, &config.memory)?;

        let session_id = session_id.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let trace = trace::init_tracing(config.trace.enabled, &paths, &session_id)?;
        let trace_hooks = build_trace_hooks(&config, &paths, &session_id)?;
        let llm = provider_factory.build(&config.model).await?;
        let skills = SkillStore::discover(&paths.skills);
        let rendered_agents = skills.render_agents_markdown_with_routing(&config.memory.routing);
        atomic_write(&paths.agents_notes, rendered_agents.as_bytes()).map_err(|e| {
            KernelError::InitFailed(format!("write {}: {e}", paths.agents_notes.display()))
        })?;
        let security_state = Arc::new(Mutex::new(config.security.clone()));
        let dynamic_confirm = DynamicConfirmPrompter::new(adapter.confirm.clone());
        let mut hooks = HookRegistry::default();
        hooks.register(
            HookPoint::BeforeTool,
            Arc::new(SecurityHook::new(
                security_state.clone(),
                paths.clone(),
                Arc::new(dynamic_confirm.clone()),
            )),
        );
        hooks.register(HookPoint::BeforePrompt, Arc::new(BootstrapContextHook));
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
            dynamic_confirm,
            daily_cost_cache: None,
            pending_turn_cost_override_reason: None,
            pending_turn_budget_override: RequestedTurnBudget {
                usd: None,
                seconds: None,
            },
            trace,
            trace_hooks,
            trace_context_stack: Vec::new(),
            adapter_notice_sessions: HashSet::new(),
        })
    }

    pub async fn run_turn(&mut self, user_input: &str) -> Result<TurnSummary, KernelError> {
        self.run_turn_with_attachments(user_input, Vec::new()).await
    }

    pub async fn run_turn_with_attachments(
        &mut self,
        user_input: &str,
        attachments: Vec<ChatAttachment>,
    ) -> Result<TurnSummary, KernelError> {
        let placeholder = AgentState::new(self.state.session_id.clone());
        let mut state = std::mem::replace(&mut self.state, placeholder);
        let result = self
            .run_turn_for_agent(&mut state, user_input, attachments, None, false, None, true)
            .await;
        self.state = state;
        result.map(|summary| TurnSummary {
            hit_turn_limit: summary.hit_turn_limit,
            stop_reason: summary.stop_reason,
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
        let previous_job_name = state.current_job_name.replace(job_name.to_string());
        match self
            .hooks
            .run(HookPoint::BeforeJobRun, &mut before_ctx)
            .await
        {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => {
                state.current_job_name = previous_job_name;
                self.state = state;
                return Err(KernelError::Hook(message));
            }
        }

        let result = self
            .run_turn_for_agent(&mut state, user_input, Vec::new(), None, false, None, false)
            .await;

        let turn_summary = match &result {
            Ok(summary) => json!({
                "job_name": job_name,
                "hit_turn_limit": summary.hit_turn_limit,
                "stop_reason": summary.stop_reason,
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
        state.current_job_name = previous_job_name;
        self.state = state;

        match after_result {
            HookOutcome::Continue => result.map(|summary| TurnSummary {
                hit_turn_limit: summary.hit_turn_limit,
                stop_reason: summary.stop_reason,
            }),
            HookOutcome::Abort(message) => Err(KernelError::Hook(message)),
        }
    }

    fn emit_activity(
        &self,
        phase: allbert_proto::ActivityPhase,
        label: impl Into<String>,
        next_actions: Vec<String>,
    ) {
        self.emit_activity_with(phase, label, None, None, None, None, next_actions);
    }

    #[allow(clippy::too_many_arguments)]
    fn emit_activity_with(
        &self,
        phase: allbert_proto::ActivityPhase,
        label: impl Into<String>,
        tool_name: Option<String>,
        tool_summary: Option<String>,
        skill_name: Option<String>,
        approval_id: Option<String>,
        next_actions: Vec<String>,
    ) {
        (self.adapter.on_event)(&KernelEvent::Activity(ActivityTransition {
            phase,
            label: label.into(),
            tool_name,
            tool_summary,
            skill_name,
            approval_id,
            next_actions,
        }));
    }

    fn current_trace_context(&self) -> Option<&TraceContext> {
        self.trace_context_stack.last()
    }

    fn begin_trace_span(
        &self,
        name: impl Into<String>,
        kind: allbert_proto::SpanKind,
    ) -> Option<ActiveTraceSpan> {
        let context = self.current_trace_context()?;
        Some(ActiveTraceSpan::new(
            self.trace_hooks.clone(),
            &context.session_id,
            &context.trace_id,
            Some(context.parent_span_id.clone()),
            name,
            kind,
        ))
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_turn_for_agent(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        user_attachments: Vec<ChatAttachment>,
        parent_agent_name: Option<String>,
        inherited_cost_override: bool,
        inherited_turn_budget: Option<TurnBudget>,
        emit_terminal_events: bool,
    ) -> Result<AgentRunSummary, KernelError> {
        self.run_turn_for_agent_with_trace_parent(
            state,
            user_input,
            user_attachments,
            parent_agent_name,
            inherited_cost_override,
            inherited_turn_budget,
            emit_terminal_events,
            None,
        )
        .await
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_turn_for_agent_with_trace_parent(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        user_attachments: Vec<ChatAttachment>,
        parent_agent_name: Option<String>,
        inherited_cost_override: bool,
        inherited_turn_budget: Option<TurnBudget>,
        emit_terminal_events: bool,
        trace_parent: Option<TraceParent>,
    ) -> Result<AgentRunSummary, KernelError> {
        let trace_id = trace_parent
            .as_ref()
            .map(|parent| parent.trace_id.clone())
            .unwrap_or_else(new_trace_id);
        let parent_span_id = trace_parent.map(|parent| parent.span_id);
        let mut turn_span = ActiveTraceSpan::new(
            self.trace_hooks.clone(),
            &state.session_id,
            &trace_id,
            parent_span_id,
            "turn",
            allbert_proto::SpanKind::Internal,
        );
        turn_span.set_attribute(
            "allbert.agent.name",
            allbert_proto::AttributeValue::String(state.agent_name().to_string()),
        );
        turn_span.set_attribute(
            "allbert.turn.input_bytes",
            allbert_proto::AttributeValue::Int(user_input.len().try_into().unwrap_or(i64::MAX)),
        );
        if let Some(parent) = parent_agent_name.as_ref() {
            turn_span.set_attribute(
                "allbert.parent_agent.name",
                allbert_proto::AttributeValue::String(parent.clone()),
            );
        }
        let context = TraceContext {
            session_id: state.session_id.clone(),
            trace_id: trace_id.clone(),
            parent_span_id: turn_span.id().to_string(),
        };
        self.trace_context_stack.push(context);
        let result = self
            .run_turn_for_agent_inner(
                state,
                user_input,
                user_attachments,
                parent_agent_name,
                inherited_cost_override,
                inherited_turn_budget,
                emit_terminal_events,
            )
            .await;
        self.trace_context_stack.pop();
        match &result {
            Ok(summary) => {
                turn_span.set_attribute(
                    "allbert.turn.hit_limit",
                    allbert_proto::AttributeValue::Bool(summary.hit_turn_limit),
                );
                if let Some(stop_reason) = summary.stop_reason.as_ref() {
                    turn_span.set_attribute(
                        "allbert.turn.stop_reason",
                        allbert_proto::AttributeValue::String(stop_reason.clone()),
                    );
                }
                turn_span.finish_ok();
            }
            Err(err) => {
                turn_span.finish_error(err.to_string());
            }
        }
        result
    }

    #[allow(clippy::too_many_arguments)]
    async fn run_turn_for_agent_inner(
        &mut self,
        state: &mut AgentState,
        user_input: &str,
        user_attachments: Vec<ChatAttachment>,
        parent_agent_name: Option<String>,
        inherited_cost_override: bool,
        inherited_turn_budget: Option<TurnBudget>,
        emit_terminal_events: bool,
    ) -> Result<AgentRunSummary, KernelError> {
        state.turn_count = state.turn_count.saturating_add(1);
        state.begin_turn();
        self.enforce_daily_cost_cap_for_turn(state, inherited_cost_override)?;
        let cost_override_active =
            inherited_cost_override || state.cost_cap_override_active_this_turn;
        let turn_budget = match inherited_turn_budget {
            Some(budget) => budget,
            None => self.effective_root_turn_budget(state, cost_override_active)?,
        };
        self.begin_turn_budget(state, turn_budget);
        state.last_agent_stack = match parent_agent_name.as_deref() {
            Some(parent) => vec![parent.to_string(), state.agent_name().to_string()],
            None => vec![state.agent_name().to_string()],
        };
        if emit_terminal_events {
            self.emit_activity(
                allbert_proto::ActivityPhase::ClassifyingIntent,
                "classifying intent",
                Vec::new(),
            );
        }
        let mut classify_span =
            self.begin_trace_span("classify_intent", allbert_proto::SpanKind::Internal);
        let resolved_intent = match self
            .resolve_intent_for_turn(state, user_input, parent_agent_name.clone())
            .await
        {
            Ok(intent) => {
                if let Some(span) = classify_span.as_mut() {
                    span.set_attribute(
                        "allbert.intent",
                        allbert_proto::AttributeValue::String(
                            intent
                                .as_ref()
                                .map(Intent::as_str)
                                .unwrap_or("none")
                                .to_string(),
                        ),
                    );
                }
                if let Some(span) = classify_span {
                    span.finish_ok();
                }
                intent
            }
            Err(err) => {
                if let Some(span) = classify_span {
                    span.finish_error(err.to_string());
                }
                return Err(err);
            }
        };
        state.last_resolved_intent = resolved_intent.clone();
        let route_span = self.begin_trace_span("route_skill", allbert_proto::SpanKind::Internal);
        if let Err(err) = self.apply_memory_routing(
            state,
            resolved_intent.as_ref(),
            user_input,
            parent_agent_name.is_none(),
        ) {
            if let Some(span) = route_span {
                span.finish_error(err.to_string());
            }
            return Err(err);
        }
        if let Some(span) = route_span {
            span.finish_ok();
        }
        tracing::info!(
            session = %state.session_id,
            agent = %state.agent_name(),
            parent_agent = ?parent_agent_name,
            turn = state.turn_count,
            intent = ?resolved_intent.as_ref().map(Intent::as_str),
            "turn start"
        );
        let rendered_user_input = render_user_input_for_history(user_input, &user_attachments);
        state.append_ephemeral_note(
            format!("User: {}", rendered_user_input.trim()),
            self.config.memory.max_ephemeral_bytes,
        );
        state.messages.push(ChatMessage {
            role: ChatRole::User,
            content: rendered_user_input,
            attachments: user_attachments,
        });

        let mut tool_calls_used = 0usize;
        let mut tool_output_total = 0usize;

        for round in 0..self.config.limits.max_turns {
            if let Err(summary) = self.enforce_turn_budget_before_round(state) {
                if emit_terminal_events {
                    (self.adapter.on_event)(&KernelEvent::TurnDone {
                        hit_turn_limit: summary.hit_turn_limit,
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
                return Ok(summary);
            }
            let effective_model = state
                .model_override
                .clone()
                .unwrap_or_else(|| self.config.model.clone());
            let mut effective_model = effective_model;
            self.apply_active_adapter_to_effective_model(&mut effective_model, &state.session_id)
                .await?;
            if emit_terminal_events {
                self.emit_activity(
                    allbert_proto::ActivityPhase::PreparingContext,
                    "preparing context",
                    Vec::new(),
                );
            }
            let prepare_span =
                self.begin_trace_span("prepare_context", allbert_proto::SpanKind::Internal);
            let mut prompt_ctx = HookCtx::before_prompt(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                &self.paths,
                &self.config.limits,
                Some(
                    self.paths
                        .root
                        .join(&self.config.learning.personality_digest.output_path),
                ),
            );
            prompt_ctx.intent = resolved_intent.clone();
            match self
                .hooks
                .run(HookPoint::BeforePrompt, &mut prompt_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => {
                    if let Some(span) = prepare_span {
                        span.finish_error(message.clone());
                    }
                    return Err(KernelError::Hook(message));
                }
            }

            let refresh_query = if round == 0 {
                None
            } else {
                state.pending_memory_refresh_query.take()
            };
            let turn_memory = match self
                .build_turn_memory_prompt(
                    state,
                    parent_agent_name.clone(),
                    resolved_intent.as_ref(),
                    user_input,
                    refresh_query.as_deref(),
                )
                .await
            {
                Ok(snapshot) => snapshot,
                Err(err) => {
                    if let Some(span) = prepare_span {
                        span.finish_error(err.to_string());
                    }
                    return Err(err);
                }
            };
            state.last_memory_context_bytes = turn_memory
                .sections
                .iter()
                .map(|section| section.len())
                .sum();
            prompt_ctx.prompt_sections.extend(turn_memory.sections);
            state.turn_prefetch_hits = turn_memory.prefetch_hits;
            if let Some(span) = prepare_span {
                span.finish_ok();
            }

            if emit_terminal_events {
                self.emit_activity(
                    allbert_proto::ActivityPhase::CallingModel,
                    format!("calling model {}", effective_model.model_id),
                    vec!["wait for the model response".into()],
                );
            }
            let mut chat_span = self.begin_trace_span("chat", allbert_proto::SpanKind::Client);
            if let Some(span) = chat_span.as_mut() {
                span.set_attribute(
                    "gen_ai.provider.name",
                    allbert_proto::AttributeValue::String(self.llm.provider_name().into()),
                );
                span.set_attribute(
                    "gen_ai.request.model",
                    allbert_proto::AttributeValue::String(effective_model.model_id.clone()),
                );
                span.set_attribute(
                    "gen_ai.operation.name",
                    allbert_proto::AttributeValue::String("chat".into()),
                );
            }
            let response = match self
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
                .await
            {
                Ok(response) => {
                    if let Some(span) = chat_span.as_mut() {
                        span.set_attribute(
                            "gen_ai.usage.input_tokens",
                            allbert_proto::AttributeValue::Int(
                                response.usage.input_tokens.try_into().unwrap_or(i64::MAX),
                            ),
                        );
                        span.set_attribute(
                            "gen_ai.usage.output_tokens",
                            allbert_proto::AttributeValue::Int(
                                response.usage.output_tokens.try_into().unwrap_or(i64::MAX),
                            ),
                        );
                    }
                    if let Some(span) = chat_span {
                        span.finish_ok();
                    }
                    response
                }
                Err(err) => {
                    if let Some(mut span) = chat_span {
                        span.add_event("retry", BTreeMap::new());
                        span.finish_error(err.to_string());
                    }
                    return Err(err.into());
                }
            };

            tracing::debug!(
                session = %state.session_id,
                agent = %state.agent_name(),
                parent_agent = ?parent_agent_name,
                provider = %self.llm.provider_name(),
                model = %effective_model.model_id,
                "model response received"
            );
            state.record_response_usage(response.usage.clone());
            if emit_terminal_events {
                self.emit_activity(
                    allbert_proto::ActivityPhase::StreamingResponse,
                    "processing model response",
                    Vec::new(),
                );
            }

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
                self.record_cached_cost_delta(entry.usd_estimate);
            }

            let final_text = self.finish_turn_output(state, &response.text);
            state.messages.push(ChatMessage {
                role: ChatRole::Assistant,
                content: final_text.clone(),
                attachments: Vec::new(),
            });

            for event in hook_ctx.pending_events {
                (self.adapter.on_event)(&event);
            }

            let tool_calls = parse_tool_calls(&response.text);
            state.spawn_siblings_remaining_this_round = tool_calls
                .iter()
                .filter(|invocation| invocation.name == "spawn_subagent")
                .count();
            if tool_calls.is_empty() {
                let finalize_span =
                    self.begin_trace_span("finalize", allbert_proto::SpanKind::Internal);
                if emit_terminal_events {
                    self.emit_activity(
                        allbert_proto::ActivityPhase::Finalizing,
                        "finalizing turn",
                        Vec::new(),
                    );
                }
                state.append_ephemeral_note(
                    format!("Assistant: {}", final_text.trim()),
                    self.config.memory.max_ephemeral_bytes,
                );
                if emit_terminal_events {
                    (self.adapter.on_event)(&KernelEvent::AssistantText(final_text.clone()));
                    (self.adapter.on_event)(&KernelEvent::TurnDone {
                        hit_turn_limit: false,
                    });
                }
                let mut end_ctx =
                    HookCtx::on_turn_end(&state.session_id, state.agent_name(), parent_agent_name);
                end_ctx.intent = resolved_intent.clone();
                match self.hooks.run(HookPoint::OnTurnEnd, &mut end_ctx).await {
                    HookOutcome::Continue => {}
                    HookOutcome::Abort(message) => {
                        if let Some(span) = finalize_span {
                            span.finish_error(message.clone());
                        }
                        return Err(KernelError::Hook(message));
                    }
                }
                if let Some(span) = finalize_span {
                    span.finish_ok();
                }
                return Ok(AgentRunSummary {
                    hit_turn_limit: false,
                    assistant_text: Some(final_text),
                    stop_reason: None,
                });
            }

            for invocation in tool_calls {
                if tool_calls_used >= self.config.limits.max_tool_calls_per_turn as usize {
                    let content = "tool call budget exhausted".to_string();
                    state.messages.push(ChatMessage {
                        role: ChatRole::User,
                        content: format!("Tool result for limit (ok=false):\n{content}"),
                        attachments: Vec::new(),
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
                        stop_reason: Some("tool call budget exhausted".into()),
                    });
                }

                tool_calls_used += 1;
                if emit_terminal_events {
                    self.emit_activity_with(
                        allbert_proto::ActivityPhase::CallingTool,
                        format!("calling tool {}", invocation.name),
                        Some(invocation.name.clone()),
                        Some(summarize_tool_invocation(
                            &invocation.name,
                            &invocation.input,
                        )),
                        None,
                        None,
                        vec!["wait for the tool result".into()],
                    );
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

                let mut tool_span =
                    self.begin_trace_span("execute_tool", allbert_proto::SpanKind::Internal);
                if let Some(span) = tool_span.as_mut() {
                    span.set_attribute(
                        "allbert.tool.name",
                        allbert_proto::AttributeValue::String(invocation.name.clone()),
                    );
                    span.set_attribute(
                        "allbert.tool.args",
                        allbert_proto::AttributeValue::String(invocation.input.to_string()),
                    );
                }
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
                    HookOutcome::Abort(message) => {
                        if let Some(span) = tool_span {
                            span.finish_error(message.clone());
                        }
                        return Err(KernelError::Hook(message));
                    }
                }

                let remaining = self
                    .config
                    .limits
                    .max_tool_output_bytes_total
                    .saturating_sub(tool_output_total);
                if remaining == 0 {
                    if let Some(span) = tool_span {
                        span.finish_error("tool output budget exhausted");
                    }
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
                        stop_reason: Some("tool output budget exhausted".into()),
                    });
                }

                let per_call_limit = self
                    .config
                    .limits
                    .max_tool_output_bytes_per_call
                    .min(remaining);
                let content = truncate_to_bytes(&tool_output.content, per_call_limit);
                tool_output_total += content.len();
                if let Some(span) = tool_span.as_mut() {
                    span.set_attribute(
                        "allbert.tool.ok",
                        allbert_proto::AttributeValue::Bool(tool_output.ok),
                    );
                    span.set_attribute(
                        "allbert.tool.output_bytes",
                        allbert_proto::AttributeValue::Int(
                            content.len().try_into().unwrap_or(i64::MAX),
                        ),
                    );
                    span.set_attribute(
                        "allbert.tool.result",
                        allbert_proto::AttributeValue::String(content.clone()),
                    );
                }
                if let Some(span) = tool_span {
                    if tool_output.ok {
                        span.finish_ok();
                    } else {
                        span.finish_error("tool returned ok=false");
                    }
                }

                if emit_terminal_events {
                    self.emit_activity(
                        allbert_proto::ActivityPhase::Finalizing,
                        "recording tool result",
                        Vec::new(),
                    );
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
                    attachments: Vec::new(),
                });
                state.append_ephemeral_note(
                    format!(
                        "Tool {} (ok={}): {}",
                        invocation.name,
                        tool_output.ok,
                        truncate_to_bytes(&content, 512)
                    ),
                    self.config.memory.max_ephemeral_bytes,
                );
                self.maybe_schedule_memory_refresh(
                    state,
                    resolved_intent.as_ref(),
                    &invocation.name,
                    &content,
                    tool_output.ok,
                );
            }
            state.spawn_siblings_remaining_this_round = 0;
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
            stop_reason: Some("hit max-turns limit".into()),
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

    pub fn agents_markdown(&self) -> String {
        self.skills
            .render_agents_markdown_with_routing(&self.config.memory.routing)
    }

    pub fn active_skills(&self) -> &[ActiveSkill] {
        &self.state.active_skills
    }

    pub fn refresh_skill_catalog(&mut self) -> Result<(), KernelError> {
        self.skills = SkillStore::discover(&self.paths.skills);
        let rendered = self
            .skills
            .render_agents_markdown_with_routing(&self.config.memory.routing);
        atomic_write(&self.paths.agents_notes, rendered.as_bytes()).map_err(|e| {
            KernelError::InitFailed(format!("write {}: {e}", self.paths.agents_notes.display()))
        })?;
        Ok(())
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
            if serialized.len() > config.limits.max_skill_args_bytes {
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
        self.refresh_trace_hooks_for_current_session().ok();
    }

    pub fn export_session_snapshot(&self) -> SessionSnapshot {
        SessionSnapshot {
            session_id: self.state.session_id.clone(),
            root_agent_name: self.state.root_agent.name.clone(),
            messages: self.state.messages.clone(),
            active_skills: self.state.active_skills.clone(),
            turn_count: self.state.turn_count,
            cost_total_usd: self.state.cost_total_usd,
            session_usage: self.state.session_usage.clone(),
            last_resolved_intent: self.state.last_resolved_intent.clone(),
            last_agent_stack: self.state.last_agent_stack.clone(),
            ephemeral_memory: self.state.ephemeral_notes(),
            model: self.config.model.clone(),
        }
    }

    pub async fn restore_session_snapshot(
        &mut self,
        snapshot: SessionSnapshot,
    ) -> Result<(), KernelError> {
        if self.config.model != snapshot.model {
            self.llm = self.provider_factory.build(&snapshot.model).await?;
            self.config.model = snapshot.model.clone();
        }

        self.state.reset(snapshot.session_id.clone());
        self.state.session_id = snapshot.session_id;
        self.state.root_agent.name = snapshot.root_agent_name;
        self.state.messages = snapshot.messages;
        self.state.turn_count = snapshot.turn_count;
        self.state.cost_total_usd = snapshot.cost_total_usd;
        self.state.session_usage = snapshot.session_usage;
        self.state.last_response_usage = None;
        self.state.last_resolved_intent = snapshot.last_resolved_intent;
        self.state.last_agent_stack = snapshot.last_agent_stack;
        self.state.replace_ephemeral_memory(
            snapshot.ephemeral_memory,
            self.config.memory.max_ephemeral_bytes,
        );
        self.refresh_trace_hooks_for_current_session()?;

        let mut restored_skills = Vec::new();
        for skill in snapshot.active_skills {
            if self.skills.get(&skill.name).is_some() {
                restored_skills.push(skill);
            }
        }
        self.state.active_skills = restored_skills;
        self.state.begin_turn();
        Ok(())
    }

    pub fn session_cost_usd(&self) -> f64 {
        self.state.cost_total_usd
    }

    pub fn set_cost_override(&mut self, reason: String) {
        self.pending_turn_cost_override_reason = Some(reason);
    }

    pub fn set_turn_budget_override(
        &mut self,
        usd: Option<f64>,
        seconds: Option<u64>,
    ) -> Result<(), KernelError> {
        if let Some(value) = usd {
            if value <= 0.0 {
                return Err(KernelError::Request(
                    "budget-invalid: turn budget usd must be > 0".into(),
                ));
            }
            self.pending_turn_budget_override.usd = Some(value);
        }
        if let Some(value) = seconds {
            if value == 0 {
                return Err(KernelError::Request(
                    "budget-invalid: turn budget seconds must be >= 1".into(),
                ));
            }
            self.pending_turn_budget_override.seconds = Some(value);
        }
        Ok(())
    }

    pub fn session_id(&self) -> &str {
        &self.state.session_id
    }

    pub fn agent_name(&self) -> &str {
        self.state.agent_name()
    }

    pub fn last_resolved_intent(&self) -> Option<&Intent> {
        self.state.last_resolved_intent.as_ref()
    }

    pub fn last_agent_stack(&self) -> &[String] {
        &self.state.last_agent_stack
    }

    pub fn ephemeral_memory_entries(&self) -> Vec<String> {
        self.state.ephemeral_notes()
    }

    pub fn restore_ephemeral_memory(&mut self, entries: Vec<String>) {
        self.state
            .replace_ephemeral_memory(entries, self.config.memory.max_ephemeral_bytes);
    }

    pub fn memory_status(&self) -> Result<KernelMemoryStatus, KernelError> {
        let snapshot =
            memory::memory_status(&self.paths, &self.config.memory, self.config.setup.version)?;
        let staged_count = snapshot.staged_counts.values().copied().sum();
        Ok(KernelMemoryStatus {
            synopsis_bytes: self.state.last_memory_context_bytes,
            ephemeral_bytes: self.state.ephemeral_memory_bytes(),
            durable_count: snapshot.manifest_docs,
            staged_count,
            staged_this_turn: self.state.staged_entries_this_turn,
            prefetch_hit_count: self.state.turn_prefetch_hits.len(),
            episode_count: snapshot.episode_count,
            fact_count: snapshot.fact_count,
        })
    }

    pub fn session_telemetry(
        &self,
        channel: allbert_proto::ChannelKind,
        inbox_count: usize,
        trace_enabled: bool,
    ) -> Result<allbert_proto::TelemetrySnapshot, KernelError> {
        let memory_status = self.memory_status()?;
        let model = self.model().clone();
        let last_response_usage = self
            .state
            .last_response_usage
            .as_ref()
            .map(usage_to_payload);
        let context_used_tokens = last_response_usage
            .as_ref()
            .map(|usage| usage.input_tokens.saturating_add(usage.output_tokens))
            .filter(|tokens| *tokens > 0);
        let context_percent = match (model.context_window_tokens, context_used_tokens) {
            (window, Some(tokens)) if window > 0 => Some((tokens as f64 / window as f64) * 100.0),
            _ => None,
        };
        let remaining = self.state.remaining_turn_budget();
        let limit = self
            .state
            .active_turn_budget
            .as_ref()
            .map(|budget| budget.limit)
            .unwrap_or(TurnBudget {
                usd: self.config.limits.max_turn_usd,
                seconds: self.config.limits.max_turn_s,
            });

        Ok(allbert_proto::TelemetrySnapshot {
            session_id: self.session_id().into(),
            channel,
            provider: self.provider_name().into(),
            model: allbert_proto::ModelConfigPayload {
                provider: model.provider.to_proto_kind(),
                model_id: model.model_id.clone(),
                api_key_env: model.api_key_env.clone(),
                base_url: model.base_url.clone(),
                max_tokens: model.max_tokens,
                context_window_tokens: model.context_window_tokens,
            },
            context_window_tokens: model.context_window_tokens,
            context_used_tokens,
            context_percent,
            last_response_usage,
            session_usage: usage_to_payload(&self.state.session_usage),
            session_cost_usd: self.session_cost_usd(),
            today_cost_usd: self.today_cost_usd()?,
            turn_budget: allbert_proto::TurnBudgetTelemetry {
                limit_usd: limit.usd,
                limit_seconds: limit.seconds,
                remaining_usd: remaining.map(|budget| budget.usd),
                remaining_seconds: remaining.map(|budget| budget.seconds),
            },
            memory: allbert_proto::MemoryTelemetry {
                synopsis_bytes: memory_status.synopsis_bytes,
                ephemeral_bytes: memory_status.ephemeral_bytes,
                durable_count: memory_status.durable_count,
                staged_count: memory_status.staged_count,
                staged_this_turn: memory_status.staged_this_turn,
                prefetch_hit_count: memory_status.prefetch_hit_count,
                episode_count: memory_status.episode_count,
                fact_count: memory_status.fact_count,
                always_eligible_skills: self.config.memory.routing.always_eligible_skills.clone(),
            },
            active_skills: self
                .active_skills()
                .iter()
                .map(|skill| skill.name.clone())
                .collect(),
            last_agent_stack: self.last_agent_stack().to_vec(),
            last_resolved_intent: self
                .last_resolved_intent()
                .map(|intent| intent.as_str().to_string()),
            inbox_count,
            trace_enabled,
            setup_version: self.config.setup.version,
            adapter: self.adapter_telemetry().ok().flatten(),
            current_activity: None,
        })
    }

    fn adapter_telemetry(&self) -> Result<Option<allbert_proto::AdapterTelemetry>, KernelError> {
        let store = AdapterStore::new(self.paths.clone());
        let Some(active) = store.active()? else {
            return Ok(None);
        };
        let Some(manifest) = store.show(&active.adapter_id)? else {
            return Ok(None);
        };
        Ok(Some(allbert_proto::AdapterTelemetry {
            active_id: active.adapter_id,
            base_model: manifest.base_model.model_id,
            provenance: format!("{:?}", manifest.provenance),
            trained_at: manifest.created_at.to_rfc3339(),
            golden_pass_rate: manifest.eval_summary.golden_pass_rate,
        }))
    }

    fn effective_root_turn_budget(
        &mut self,
        state: &AgentState,
        inherited_cost_override: bool,
    ) -> Result<TurnBudget, KernelError> {
        let mut budget = TurnBudget {
            usd: self.config.limits.max_turn_usd,
            seconds: self.config.limits.max_turn_s,
        };
        if inherited_cost_override {
            return Ok(budget);
        }

        if let Some(cap) = self.config.limits.daily_usd_cap {
            let utc_day = time::OffsetDateTime::now_utc().date();
            let total = self.current_utc_cost_total(utc_day)?;
            let remaining = (cap - total).max(0.0);
            budget.usd = budget.usd.min(remaining);
        }
        if let Some(value) = self.pending_turn_budget_override.usd.take() {
            budget.usd = value;
        }
        if let Some(value) = self.pending_turn_budget_override.seconds.take() {
            budget.seconds = value;
        }
        tracing::debug!(
            session = %state.session_id,
            agent = %state.agent_name(),
            max_turn_usd = budget.usd,
            max_turn_s = budget.seconds,
            "resolved root turn budget"
        );
        Ok(budget)
    }

    fn begin_turn_budget(&self, state: &mut AgentState, budget: TurnBudget) {
        state.active_turn_budget = Some(ActiveTurnBudget {
            limit: budget,
            cost_at_turn_start: state.cost_total_usd,
            started_at: Instant::now(),
        });
    }

    fn current_turn_remaining_budget_for_state(&self, state: &AgentState) -> Option<TurnBudget> {
        state.remaining_turn_budget()
    }

    fn enforce_turn_budget_before_round(&self, state: &AgentState) -> Result<(), AgentRunSummary> {
        let Some(remaining) = self.current_turn_remaining_budget_for_state(state) else {
            return Ok(());
        };
        if remaining.seconds == 0 {
            return Err(AgentRunSummary {
                hit_turn_limit: true,
                assistant_text: None,
                stop_reason: Some("budget-exhausted: turn time budget exhausted".into()),
            });
        }
        if remaining.usd <= 0.0 {
            return Err(AgentRunSummary {
                hit_turn_limit: true,
                assistant_text: None,
                stop_reason: Some("budget-exhausted: turn usd budget exhausted".into()),
            });
        }
        Ok(())
    }

    fn resolve_subagent_budget(
        &self,
        state: &mut AgentState,
        requested: Option<&SpawnBudgetInput>,
    ) -> Result<TurnBudget, String> {
        let remaining = state
            .remaining_turn_budget()
            .ok_or_else(|| "budget-exhausted: no active parent turn budget".to_string())?;
        if remaining.seconds == 0 || remaining.usd <= 0.0 {
            return Err("budget-exhausted: parent turn budget is exhausted".into());
        }

        let siblings = state.spawn_siblings_remaining_this_round.max(1) as u64;
        let default_usd = remaining.usd / siblings as f64;
        let default_seconds = remaining.seconds / siblings;
        let requested = requested.map(|value| RequestedTurnBudget {
            usd: value.usd,
            seconds: value.seconds,
        });
        let resolved = TurnBudget {
            usd: requested.and_then(|value| value.usd).unwrap_or(default_usd),
            seconds: requested
                .and_then(|value| value.seconds)
                .unwrap_or(default_seconds.max(1)),
        };

        if let Some(value) = requested.and_then(|budget| budget.usd) {
            if value > remaining.usd || value < 0.0 {
                return Err(format!(
                    "budget-invalid: requested usd {:.6} exceeds remaining {:.6}",
                    value, remaining.usd
                ));
            }
        }
        if let Some(value) = requested.and_then(|budget| budget.seconds) {
            if value == 0 || value > remaining.seconds {
                return Err(format!(
                    "budget-invalid: requested seconds {} exceeds remaining {}",
                    value, remaining.seconds
                ));
            }
        }
        if resolved.usd <= 0.0 || resolved.seconds == 0 {
            return Err("budget-exhausted: no usable budget remains for this spawn".into());
        }
        Ok(resolved)
    }

    fn enforce_daily_cost_cap_for_turn(
        &mut self,
        state: &mut AgentState,
        inherited_cost_override: bool,
    ) -> Result<(), KernelError> {
        if inherited_cost_override {
            state.cost_cap_override_active_this_turn = true;
            return Ok(());
        }

        if let Some(reason) = self.pending_turn_cost_override_reason.take() {
            state.cost_cap_override_active_this_turn = true;
            tracing::warn!(
                session = %state.session_id,
                agent = %state.agent_name(),
                reason = %reason,
                "daily cost cap override armed for this turn"
            );
            return Ok(());
        }

        let Some(cap) = self.config.limits.daily_usd_cap else {
            return Ok(());
        };

        let utc_day = time::OffsetDateTime::now_utc().date();
        let total = self.current_utc_cost_total(utc_day)?;
        if total >= cap {
            return Err(KernelError::CostCap(format!(
                "Daily cost cap of ${cap:.2} reached for {}. Current spend: ${total:.2}. Raise limits.daily_usd_cap in config or run `/cost --override <reason>` to continue this turn.",
                utc_day
            )));
        }
        Ok(())
    }

    fn current_utc_cost_total(&mut self, utc_day: time::Date) -> Result<f64, KernelError> {
        if let Some(cache) = self.daily_cost_cache.as_ref() {
            if cache.utc_day == utc_day && cache.refreshed_at.elapsed() < Duration::from_secs(60) {
                return Ok(cache.total_usd);
            }
        }
        let total = cost::sum_costs_for_utc_day(&self.paths.costs, utc_day)?;
        self.daily_cost_cache = Some(DailyCostCache {
            utc_day,
            total_usd: total,
            refreshed_at: Instant::now(),
        });
        Ok(total)
    }

    fn record_cached_cost_delta(&mut self, usd_estimate: f64) {
        let utc_day = time::OffsetDateTime::now_utc().date();
        if let Some(cache) = self.daily_cost_cache.as_mut() {
            if cache.utc_day == utc_day {
                cache.total_usd += usd_estimate;
                cache.refreshed_at = Instant::now();
            }
        }
    }

    pub fn set_adapter(&mut self, adapter: FrontendAdapter) {
        self.dynamic_confirm.set(adapter.confirm.clone());
        self.adapter = adapter;
    }

    pub fn register_job_manager(&mut self, job_manager: Arc<dyn JobManager>) {
        self.job_manager = Some(job_manager);
    }

    pub fn provider_name(&self) -> &'static str {
        self.llm.provider_name()
    }

    pub fn supports_image_input(&self) -> bool {
        self.llm.supports_image_input(&self.config.model.model_id)
    }

    pub fn model(&self) -> &ModelConfig {
        &self.config.model
    }

    pub async fn set_model(&mut self, model: ModelConfig) -> Result<(), KernelError> {
        let store = AdapterStore::new(self.paths.clone());
        active_adapter_for_model(&store, &model)?;
        let llm = self.provider_factory.build(&model).await?;
        self.config.model = model;
        self.llm = llm;
        Ok(())
    }

    async fn apply_active_adapter_to_effective_model(
        &mut self,
        model: &mut ModelConfig,
        session_id: &str,
    ) -> Result<(), KernelError> {
        let store = AdapterStore::new(self.paths.clone());
        let Some(active) = active_adapter_for_model(&store, model)? else {
            return Ok(());
        };
        if model.provider == Provider::Ollama {
            let derived =
                register_ollama_adapter(&self.paths, &active, model.base_url.as_deref()).await?;
            model.model_id = derived.model_name;
            return Ok(());
        }

        let notice_key = format!("{session_id}:{}", active.adapter_id);
        if self.adapter_notice_sessions.insert(notice_key) {
            (self.adapter.on_event)(&KernelEvent::AssistantText(format!(
                "Active adapter `{}` is local-only and is ignored by hosted provider `{}` for this session.",
                active.adapter_id,
                model.provider.label()
            )));
        }
        Ok(())
    }

    pub async fn apply_config(&mut self, config: Config) -> Result<(), KernelError> {
        let model_changed = self.config.model != config.model;
        if model_changed {
            self.llm = self.provider_factory.build(&config.model).await?;
        }

        self.config = config;
        *self.security_state.lock().unwrap() = self.config.security.clone();
        self.refresh_trace_hooks_for_current_session()?;
        let rendered = self
            .skills
            .render_agents_markdown_with_routing(&self.config.memory.routing);
        atomic_write(&self.paths.agents_notes, rendered.as_bytes()).map_err(|e| {
            KernelError::InitFailed(format!("write {}: {e}", self.paths.agents_notes.display()))
        })?;
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

    fn refresh_trace_hooks_for_current_session(&mut self) -> Result<(), KernelError> {
        self.trace_hooks = build_trace_hooks(&self.config, &self.paths, &self.state.session_id)?;
        Ok(())
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
                    attachments: Vec::new(),
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
        state.record_response_usage(response.usage.clone());

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
            self.record_cached_cost_delta(entry.usd_estimate);
        }
        for event in hook_ctx.pending_events {
            (self.adapter.on_event)(&event);
        }

        Ok(Intent::parse(response.text.trim()))
    }

    async fn build_turn_memory_prompt(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        resolved_intent: Option<&Intent>,
        user_input: &str,
        refresh_query: Option<&str>,
    ) -> Result<memory::TurnMemorySnapshot, KernelError> {
        let reconcile_report = memory::reconcile_curated_memory(&self.paths, &self.config.memory)?;
        if reconcile_report.manifest_rebuilt {
            let mut manifest_ctx = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                json!({ "source": "turn-read" }),
                false,
            );
            manifest_ctx.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::MemoryManifestRebuilt, &mut manifest_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }
        }
        if let Some(rebuild_report) = reconcile_report.rebuild_report.as_ref() {
            let mut before_rebuild = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                json!({ "reason": rebuild_report.reason }),
                false,
            );
            before_rebuild.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::BeforeIndexRebuild, &mut before_rebuild)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }

            let mut after_rebuild = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                json!({
                    "docs_indexed": rebuild_report.docs_indexed,
                    "elapsed_ms": rebuild_report.elapsed_ms,
                    "bytes": 0,
                }),
                false,
            );
            after_rebuild.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::AfterIndexRebuild, &mut after_rebuild)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }
        }

        let prefetch_query = if let Some(refresh_query) = refresh_query {
            Some(refresh_query.to_string())
        } else if matches!(state.memory_prefetch_override, Some(false)) {
            None
        } else if self.should_prefetch_memory(resolved_intent, user_input) {
            Some(user_input.trim().to_string())
        } else {
            None
        };
        let refresh = refresh_query.is_some();

        if let Some(query) = prefetch_query.as_deref() {
            let mut before_ctx = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                json!({
                    "query": query,
                    "budget": self.config.memory.max_prefetch_snippets,
                    "refresh": refresh,
                }),
                refresh,
            );
            before_ctx.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::BeforeMemoryPrefetch, &mut before_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }
        }

        let snapshot = memory::build_turn_memory_snapshot(
            &self.paths,
            &self.config.memory,
            &state.ephemeral_summary(self.config.memory.max_ephemeral_summary_bytes),
            prefetch_query.as_deref(),
            self.config.memory.prefetch_default_limit,
        )?;

        for dropped in &snapshot.trimmed_sources {
            let mut trim_ctx = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name.clone(),
                json!({
                    "dropped": dropped,
                    "bytes_over_budget": 1,
                }),
                refresh,
            );
            trim_ctx.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::SynopsisTrimmed, &mut trim_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }
        }

        if prefetch_query.is_some() {
            let mut after_ctx = HookCtx::memory_event(
                &state.session_id,
                state.agent_name(),
                parent_agent_name,
                json!({
                    "results": snapshot.prefetch_hits.clone(),
                    "elapsed_ms": 0,
                    "truncated": !snapshot.trimmed_sources.is_empty(),
                    "refresh": refresh,
                }),
                refresh,
            );
            after_ctx.intent = resolved_intent.cloned();
            match self
                .hooks
                .run(HookPoint::AfterMemoryPrefetch, &mut after_ctx)
                .await
            {
                HookOutcome::Continue => {}
                HookOutcome::Abort(message) => return Err(KernelError::Hook(message)),
            }
        }

        if refresh {
            state.memory_refreshes_this_turn = state.memory_refreshes_this_turn.saturating_add(1);
        }

        let mut sections = snapshot.sections;
        sections.extend(state.memory_context_sections.iter().cloned());

        Ok(memory::TurnMemorySnapshot {
            sections,
            prefetch_hits: snapshot.prefetch_hits,
            trimmed_sources: snapshot.trimmed_sources,
        })
    }

    fn should_prefetch_memory(&self, resolved_intent: Option<&Intent>, user_input: &str) -> bool {
        if !self.config.memory.prefetch_enabled {
            return false;
        }
        match resolved_intent {
            Some(Intent::MemoryQuery) => true,
            Some(Intent::Task) | Some(Intent::Schedule) => true,
            Some(Intent::Chat) | Some(Intent::Meta) | None => has_memory_cues(user_input),
        }
    }

    fn apply_memory_routing(
        &self,
        state: &mut AgentState,
        resolved_intent: Option<&Intent>,
        user_input: &str,
        is_root_turn: bool,
    ) -> Result<(), KernelError> {
        if !is_root_turn || !self.memory_routing_should_activate(resolved_intent, user_input) {
            return Ok(());
        }

        for skill_name in &self.config.memory.routing.always_eligible_skills {
            if self.skills.get(skill_name).is_some() {
                Self::activate_skill_with_config(
                    &self.skills,
                    &self.config,
                    state,
                    skill_name,
                    None,
                )?;
            }
        }
        Ok(())
    }

    fn memory_routing_should_activate(
        &self,
        resolved_intent: Option<&Intent>,
        user_input: &str,
    ) -> bool {
        let routing = &self.config.memory.routing;
        if resolved_intent.is_some_and(|intent| {
            routing
                .auto_activate_intents
                .iter()
                .any(|configured| configured == intent.as_str())
        }) {
            return true;
        }
        if !matches!(resolved_intent, Some(Intent::Chat)) {
            return false;
        }
        let normalized = user_input.to_ascii_lowercase();
        routing.auto_activate_cues.iter().any(|cue| {
            let cue = cue.trim().to_ascii_lowercase();
            !cue.is_empty() && normalized.contains(&cue)
        })
    }

    fn maybe_schedule_memory_refresh(
        &self,
        state: &mut AgentState,
        resolved_intent: Option<&Intent>,
        tool_name: &str,
        content: &str,
        ok: bool,
    ) {
        if !ok
            || !self.config.memory.refresh_after_external_evidence
            || state.pending_memory_refresh_query.is_some()
            || state.memory_refreshes_this_turn >= self.config.memory.max_refreshes_per_turn
        {
            return;
        }
        if matches!(
            tool_name,
            "search_memory"
                | "stage_memory"
                | "list_staged_memory"
                | "promote_staged_memory"
                | "reject_staged_memory"
        ) {
            return;
        }

        if !(has_memory_cues(content)
            || matches!(
                resolved_intent,
                Some(Intent::Task) | Some(Intent::Schedule) | Some(Intent::MemoryQuery)
            ))
        {
            return;
        }

        let query = truncate_to_bytes(content.trim(), 512);
        if query.is_empty() {
            return;
        }
        state.pending_memory_refresh_query = Some(query);
    }

    fn finish_turn_output(&self, state: &AgentState, assistant_text: &str) -> String {
        let mut output = assistant_text.to_string();
        if self.config.memory.surface_staged_on_turn_end && state.staged_entries_this_turn > 0 {
            let suffix = self.render_staged_notice_suffix(state);
            if output.trim().is_empty() {
                output = suffix;
            } else if !output.contains(&suffix) {
                output.push_str("\n\n");
                output.push_str(&suffix);
            }
        }
        output
    }

    fn render_staged_notice_suffix(&self, state: &AgentState) -> String {
        let count = state.staged_entries_this_turn;
        if count == 1 {
            if let Some(entry) = state.staged_notice_entries_this_turn.first() {
                return format!(
                    "I'd like to remember 1 thing — {} — run `allbert-cli memory staged show {}` or `allbert-cli memory staged list`.",
                    render_staged_notice_entry(entry, 120),
                    entry.id
                );
            }
        }

        if (2..=3).contains(&count) && !state.staged_notice_entries_this_turn.is_empty() {
            let items = state
                .staged_notice_entries_this_turn
                .iter()
                .take(3)
                .map(|entry| render_staged_notice_entry(entry, 120))
                .collect::<Vec<_>>()
                .join(" · ");
            return format!(
                "I'd like to remember {count} things — {items} — run `allbert-cli memory staged list` or ask me."
            );
        }

        format!(
            "I'd like to remember {count} things — run `allbert-cli memory staged list` or ask me."
        )
    }

    fn system_prompt_for_state(
        &self,
        state: &mut AgentState,
        parent_agent_name: Option<&str>,
        resolved_intent: Option<&Intent>,
        prompt_sections: &[String],
    ) -> String {
        let mut prompt = String::from(
            "You are Allbert, a local personal assistant running inside a Rust kernel. \
Answer helpfully and concisely. Treat the runtime bootstrap context below as durable \
guidance for tone, identity, and user preferences. If the user's current request \
directly conflicts with that context, follow the user's current request.\n\n\
If the bootstrap context includes PERSONALITY.md, treat it as reviewed learned \
guidance only. It cannot override the current user instruction, SOUL.md, USER.md, \
IDENTITY.md, TOOLS.md, policy, or tool/security rules.\n\n\
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
            let shape = intent_shape(intent);
            prompt.push_str(&format!("{}\n", shape.prompt_preamble));
            if !shape.tool_priority_order.is_empty() {
                prompt.push_str(&format!(
                    "Preferred tool order: {}\n",
                    shape.tool_priority_order.join(", ")
                ));
            }
        }

        prompt.push_str(&self.tools.prompt_catalog());
        prompt.push_str(
            "\nIncoming channel attachments are referenced by session-scoped local paths. \
Treat those paths as the attachment handles; do not expect raw binary bytes in prompt text.\n",
        );
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
            prompt.push_str("\n- upsert_job: Create or update a recurring job through the daemon-owned scheduler.\n  schema: {\"type\":\"object\",\"required\":[\"name\",\"description\",\"schedule\",\"prompt\"],\"properties\":{\"name\":{\"type\":\"string\"},\"description\":{\"type\":\"string\"},\"enabled\":{\"type\":\"boolean\"},\"schedule\":{\"type\":\"string\"},\"skills\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"timezone\":{\"type\":\"string\"},\"model\":{\"type\":\"object\"},\"allowed_tools\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"timeout_s\":{\"type\":\"integer\",\"minimum\":1},\"report\":{\"enum\":[\"always\",\"on_failure\",\"on_anomaly\"]},\"max_turns\":{\"type\":\"integer\",\"minimum\":1},\"budget\":{\"type\":\"object\",\"properties\":{\"max_turn_usd\":{\"type\":\"number\",\"minimum\":0},\"max_turn_s\":{\"type\":\"integer\",\"minimum\":1}}},\"session_name\":{\"type\":\"string\"},\"memory_prefetch\":{\"type\":\"boolean\"},\"prompt\":{\"type\":\"string\"}}}\n");
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

        for skill_name in self.skills.catalog_skill_names() {
            if state.surfaced_skills_this_turn.insert(skill_name.clone()) {
                (self.adapter.on_event)(&KernelEvent::SkillTier1Surfaced { skill_name });
            }
        }

        if parent_agent_name.is_none() {
            let routing_prompt = self.skills.routing_prompt(&self.config.memory.routing);
            if !routing_prompt.is_empty() {
                prompt.push_str("\n\nAlways-eligible skill routing:\n");
                prompt.push_str(
                    "These skills are surfaced for routing awareness only; invoke them when the turn needs their full instructions.\n",
                );
                prompt.push_str(&routing_prompt);
            }
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
            for skill_name in self.skills.activated_skill_names(&state.active_skills) {
                if state.activated_skills_this_turn.insert(skill_name.clone()) {
                    (self.adapter.on_event)(&KernelEvent::SkillTier2Activated { skill_name });
                }
            }
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
            "list_jobs" => self.dispatch_list_jobs().await,
            "get_job" => self.dispatch_get_job(invocation.input).await,
            "upsert_job" => self.dispatch_upsert_job(invocation.input).await,
            "pause_job" => self.dispatch_pause_job(invocation.input).await,
            "resume_job" => self.dispatch_resume_job(invocation.input).await,
            "run_job" => self.dispatch_run_job(invocation.input).await,
            "remove_job" => self.dispatch_remove_job(invocation.input).await,
            "list_job_runs" => self.dispatch_list_job_runs(invocation.input).await,
            _ => {
                let Some(tool) = self.tools.lookup(&invocation.name) else {
                    return ToolOutput {
                        content: ToolError::NotFound(invocation.name).to_string(),
                        ok: false,
                    };
                };
                let mut runtime = KernelToolRuntime {
                    kernel: self,
                    state,
                    parent_agent_name,
                };
                let mut ctx = ToolCtx {
                    input: runtime.kernel.adapter.input.clone(),
                    security: runtime.kernel.config.security.clone(),
                    web_client: reqwest::Client::new(),
                    runtime: &mut runtime,
                };
                match tool.call(invocation.input, &mut ctx).await {
                    Ok(output) => output,
                    Err(err) => ToolOutput {
                        content: err.to_string(),
                        ok: false,
                    },
                }
            }
        }
    }

    fn dispatch_list_skills(&mut self, _input: serde_json::Value) -> ToolOutput {
        ToolOutput {
            content: self.skills.manifest_prompt(),
            ok: true,
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

    fn dispatch_read_reference(
        &mut self,
        state: &mut AgentState,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<ReadReferenceInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid read_reference input: {err}"),
                    ok: false,
                }
            }
        };

        let cache_key = format!("{}::{}", parsed.skill, parsed.path);
        if let Some(content) = state.reference_cache_this_turn.get(&cache_key) {
            return ToolOutput {
                content: content.clone(),
                ok: true,
            };
        }

        match self
            .skills
            .read_reference(&parsed.skill, &parsed.path, parsed.max_bytes)
        {
            Ok(content) => {
                if state
                    .referenced_resources_this_turn
                    .insert(cache_key.clone())
                {
                    (self.adapter.on_event)(&KernelEvent::SkillTier3Referenced {
                        skill_name: parsed.skill.clone(),
                        path: parsed.path.clone(),
                    });
                }
                state
                    .reference_cache_this_turn
                    .insert(cache_key, content.clone());
                ToolOutput { content, ok: true }
            }
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_run_skill_script(
        &mut self,
        state: &mut AgentState,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<RunSkillScriptInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid run_skill_script input: {err}"),
                    ok: false,
                }
            }
        };

        if !state
            .active_skills
            .iter()
            .any(|active| active.name == parsed.skill)
        {
            return ToolOutput {
                content: format!(
                    "skill '{}' must be active before its scripts can run",
                    parsed.skill
                ),
                ok: false,
            };
        }

        let resolved = match self.skills.resolve_script(&parsed.skill, &parsed.script) {
            Ok(resolved) => resolved,
            Err(err) => {
                return ToolOutput {
                    content: err.to_string(),
                    ok: false,
                }
            }
        };

        if resolved.interpreter.eq_ignore_ascii_case("lua") {
            let input = parsed
                .input
                .unwrap_or_else(|| json!({ "args": parsed.args }));
            return self
                .dispatch_lua_skill_script(state, resolved, input, parsed.budget)
                .await;
        }

        if self
            .config
            .security
            .exec_deny
            .iter()
            .any(|value| value == &resolved.interpreter)
        {
            return ToolOutput {
                content: format!(
                    "interpreter '{}' is hard-blocked by config.security.exec_deny",
                    resolved.interpreter
                ),
                ok: false,
            };
        }
        if !self
            .config
            .security
            .exec_allow
            .iter()
            .any(|value| value == &resolved.interpreter)
        {
            return ToolOutput {
                content: format!(
                    "interpreter '{}' is not allowlisted; add it to config.security.exec_allow",
                    resolved.interpreter
                ),
                ok: false,
            };
        }

        let mut args = vec![resolved.path.display().to_string()];
        args.extend(parsed.args.clone());
        let execution_input = json!({
            "program": resolved.interpreter,
            "args": args,
            "cwd": resolved.path.parent().map(|path| path.display().to_string()),
            "timeout_s": parsed.timeout_s,
            "_skill_script": true,
            "skill_name": resolved.skill_name,
            "script_name": resolved.script_name,
            "script_path": resolved.path.display().to_string(),
        });

        let process_tool = match self.tools.lookup("process_exec") {
            Some(tool) => tool,
            None => {
                return ToolOutput {
                    content: "process_exec tool is not registered".into(),
                    ok: false,
                }
            }
        };

        let mut null_runtime = KernelToolRuntime {
            kernel: self,
            state,
            parent_agent_name: None,
        };
        let mut ctx = ToolCtx {
            input: null_runtime.kernel.adapter.input.clone(),
            security: null_runtime.kernel.config.security.clone(),
            web_client: reqwest::Client::new(),
            runtime: &mut null_runtime,
        };

        match process_tool.call(execution_input, &mut ctx).await {
            Ok(output) => output,
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_lua_skill_script(
        &mut self,
        state: &mut AgentState,
        resolved: skills::ResolvedSkillScript,
        input: serde_json::Value,
        requested_budget: Option<scripting::ScriptBudget>,
    ) -> ToolOutput {
        if self.config.scripting.engine != config::ScriptingEngineConfig::Lua {
            return ToolOutput {
                content: "Lua scripting engine is disabled; set scripting.engine = \"lua\" and add \"lua\" to config.security.exec_allow before running Lua skill scripts".into(),
                ok: false,
            };
        }
        if self
            .config
            .security
            .exec_deny
            .iter()
            .any(|value| value == "lua")
        {
            return ToolOutput {
                content: "interpreter 'lua' is hard-blocked by config.security.exec_deny".into(),
                ok: false,
            };
        }
        if !self
            .config
            .security
            .exec_allow
            .iter()
            .any(|value| value == "lua")
        {
            return ToolOutput {
                content:
                    "interpreter 'lua' is not allowlisted; add it to config.security.exec_allow"
                        .into(),
                ok: false,
            };
        }

        let source = match std::fs::read_to_string(&resolved.path) {
            Ok(source) => source,
            Err(err) => {
                return ToolOutput {
                    content: format!("read {}: {err}", resolved.path.display()),
                    ok: false,
                }
            }
        };

        let source_ref = format!("{}/{}", resolved.skill_name, resolved.declared_path);
        let synthetic_name = format!("exec.lua:{source_ref}");
        let budget = match resolve_lua_script_budget(&self.config.scripting, requested_budget) {
            Ok(budget) => budget,
            Err(message) => {
                return ToolOutput {
                    content: message,
                    ok: false,
                }
            }
        };
        let before_input = json!({
            "engine": "lua",
            "skill": resolved.skill_name,
            "script": resolved.script_name,
            "path": resolved.declared_path,
            "source_ref": source_ref,
            "budget": budget,
        });

        let mut before_ctx = HookCtx::before_tool(
            &state.session_id,
            state.agent_name(),
            None,
            ToolInvocation {
                name: synthetic_name.clone(),
                input: before_input.clone(),
            },
            None,
        );
        match self.hooks.run(HookPoint::BeforeTool, &mut before_ctx).await {
            HookOutcome::Continue => {}
            HookOutcome::Abort(message) => {
                return ToolOutput {
                    content: message,
                    ok: false,
                }
            }
        }

        let engine = scripting::LuaEngine::with_policy(scripting::LuaSandboxPolicy {
            allow_stdlib: self.config.scripting.allow_stdlib.clone(),
            deny_stdlib: self.config.scripting.deny_stdlib.clone(),
        });
        let outcome = match engine.load(&source, &source_ref) {
            Ok(script) => engine.invoke(&script, input, budget),
            Err(err) => Err(err),
        };
        let (content, ok, after_input) = match outcome {
            Ok(outcome) => render_script_outcome(before_input, outcome),
            Err(err) => {
                let content = err.to_string();
                (
                    content.clone(),
                    false,
                    json!({
                        "engine": "lua",
                        "source_ref": source_ref,
                        "outcome": "error",
                        "error": content,
                    }),
                )
            }
        };

        let mut after_ctx = HookCtx::before_tool(
            &state.session_id,
            state.agent_name(),
            None,
            ToolInvocation {
                name: synthetic_name,
                input: after_input,
            },
            None,
        );
        match self.hooks.run(HookPoint::AfterTool, &mut after_ctx).await {
            HookOutcome::Continue => ToolOutput { content, ok },
            HookOutcome::Abort(message) => ToolOutput {
                content: message,
                ok: false,
            },
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

        let spawn_budget = match self.resolve_subagent_budget(state, parsed.budget.as_ref()) {
            Ok(budget) => budget,
            Err(message) => {
                state.spawn_siblings_remaining_this_round =
                    state.spawn_siblings_remaining_this_round.saturating_sub(1);
                return ToolOutput {
                    content: message,
                    ok: false,
                };
            }
        };
        state.spawn_siblings_remaining_this_round =
            state.spawn_siblings_remaining_this_round.saturating_sub(1);

        let mut before_ctx = HookCtx::before_agent_spawn(
            &state.session_id,
            state.agent_name(),
            parent_agent_name.clone(),
            json!({
                "name": parsed.name,
                "prompt": parsed.prompt,
                "context": parsed.context,
                "budget": {
                    "usd": spawn_budget.usd,
                    "seconds": spawn_budget.seconds
                }
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
        subagent_state.memory_prefetch_override = Some(false);
        match self.build_subagent_memory_sections(parsed.memory_hints.as_deref()) {
            Ok(sections) => {
                subagent_state.memory_context_sections = sections;
            }
            Err(err) => {
                return ToolOutput {
                    content: err,
                    ok: false,
                };
            }
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

        let mut invoke_span =
            self.begin_trace_span("invoke_agent", allbert_proto::SpanKind::Internal);
        if let Some(span) = invoke_span.as_mut() {
            span.set_attribute(
                "allbert.agent.child_name",
                allbert_proto::AttributeValue::String(subagent_state.agent_name().to_string()),
            );
        }
        let trace_parent = invoke_span.as_ref().and_then(|span| {
            self.current_trace_context().map(|context| TraceParent {
                trace_id: context.trace_id.clone(),
                span_id: span.id().to_string(),
            })
        });

        let run_result = Box::pin(self.run_turn_for_agent_with_trace_parent(
            &mut subagent_state,
            &composed_prompt,
            Vec::new(),
            Some(state.agent_name().to_string()),
            state.cost_cap_override_active_this_turn,
            Some(spawn_budget),
            false,
            trace_parent,
        ))
        .await;

        state.cost_total_usd += subagent_state.cost_total_usd;
        state.merge_child_usage(&subagent_state);
        state.last_agent_stack = subagent_state.last_agent_stack.clone();
        state.last_resolved_intent = subagent_state.last_resolved_intent.clone();

        let tool_output = match run_result {
            Ok(summary) => {
                if let Some(span) = invoke_span.as_mut() {
                    span.set_attribute(
                        "allbert.agent.hit_limit",
                        allbert_proto::AttributeValue::Bool(summary.hit_turn_limit),
                    );
                }
                let result = SpawnSubagentResult {
                    agent_name: subagent_state.agent_name().to_string(),
                    parent_agent_name: state.agent_name().to_string(),
                    hit_turn_limit: summary.hit_turn_limit,
                    cost_usd: subagent_state.cost_total_usd,
                    assistant_text: summary.assistant_text,
                    stop_reason: summary.stop_reason,
                };
                let content = serde_json::to_string_pretty(&result)
                    .unwrap_or_else(|_| "{\"error\":\"failed to encode spawn result\"}".into());
                if let Some(span) = invoke_span {
                    span.finish_ok();
                }
                ToolOutput { content, ok: true }
            }
            Err(err) => {
                if let Some(span) = invoke_span {
                    span.finish_error(err.to_string());
                }
                ToolOutput {
                    content: format!("sub-agent failed: {err}"),
                    ok: false,
                }
            }
        };

        let result_json = json!({
            "agent_name": parsed.name,
            "ok": tool_output.ok,
            "content": tool_output.content,
            "budget": {
                "usd": spawn_budget.usd,
                "seconds": spawn_budget.seconds
            }
        });
        let mut after_ctx = HookCtx::after_agent_spawn(
            &state.session_id,
            state.agent_name(),
            parent_agent_name,
            result_json,
        );
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

        if parsed.skip_quarantine {
            return ToolOutput {
                content: "skip_quarantine=true is reserved for first-party kernel seeding".into(),
                ok: false,
            };
        }

        match self.skills.create(
            &self.paths.skills_incoming,
            &parsed.name,
            &parsed.description,
            &parsed.allowed_tools,
            &parsed.body,
            skills::SkillProvenance::SelfAuthored,
        ) {
            Ok(skill) => ToolOutput {
                content: format!(
                    "created skill draft {} at {}; review and install it through the standard skill install flow",
                    skill.name,
                    skill.path.display()
                ),
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

    fn dispatch_search_memory(&self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<SearchMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid search_memory input: {err}"),
                    ok: false,
                }
            }
        };
        match memory::search_memory(&self.paths, &self.config.memory, parsed) {
            Ok(results) => serialize_tool_value(&results),
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_stage_memory(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<StageMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid stage_memory input: {err}"),
                    ok: false,
                }
            }
        };
        if parsed.summary.trim().is_empty() {
            return ToolOutput {
                content: "stage_memory summary must not be empty".into(),
                ok: false,
            };
        }
        let source = if parent_agent_name.is_some() {
            "subagent"
        } else if state.current_job_name.is_some() {
            "job"
        } else {
            "channel"
        };
        let request = memory::StageMemoryRequest {
            session_id: state.session_id.clone(),
            turn_id: format!("turn-{}", state.turn_count),
            agent: state.agent_name().to_string(),
            source: source.into(),
            content: parsed.content,
            kind: parsed.kind,
            summary: parsed.summary,
            tags: parsed.tags,
            provenance: parsed.provenance,
            fingerprint_basis: parsed.fingerprint_basis,
            facts: parsed.facts,
        };
        let before_payload = json!({
            "kind": request.kind.as_str(),
            "summary": request.summary,
            "source": request.source,
            "agent": request.agent,
        });
        let mut before_ctx = HookCtx::memory_event(
            &state.session_id,
            state.agent_name(),
            parent_agent_name.clone(),
            before_payload,
            false,
        );
        if let Some(intent) = state.last_resolved_intent.clone() {
            before_ctx.intent = Some(intent);
        }
        if let HookOutcome::Abort(message) = self
            .hooks
            .run(HookPoint::BeforeMemoryStage, &mut before_ctx)
            .await
        {
            return ToolOutput {
                content: message,
                ok: false,
            };
        }
        match memory::stage_memory(&self.paths, &self.config.memory, request) {
            Ok(record) => {
                state.staged_entries_this_turn = state.staged_entries_this_turn.saturating_add(1);
                if state.staged_notice_entries_this_turn.len() < 3 {
                    state
                        .staged_notice_entries_this_turn
                        .push(StagedNoticeEntry {
                            id: record.id.clone(),
                            summary: record.summary.clone(),
                        });
                }
                let mut after_ctx = HookCtx::memory_event(
                    &state.session_id,
                    state.agent_name(),
                    parent_agent_name,
                    json!({
                        "id": record.id,
                        "path": record.path,
                    }),
                    false,
                );
                after_ctx.intent = state.last_resolved_intent.clone();
                if let HookOutcome::Abort(message) = self
                    .hooks
                    .run(HookPoint::AfterMemoryStage, &mut after_ctx)
                    .await
                {
                    return ToolOutput {
                        content: message,
                        ok: false,
                    };
                }
                serialize_tool_value(&record)
            }
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    fn dispatch_list_staged_memory(&self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<ListStagedMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid list_staged_memory input: {err}"),
                    ok: false,
                }
            }
        };
        match memory::list_staged_memory(
            &self.paths,
            &self.config.memory,
            parsed.kind.as_deref(),
            None,
            parsed.limit,
        ) {
            Ok(records) => serialize_tool_value(&records),
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_promote_staged_memory(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<PromoteStagedMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid promote_staged_memory input: {err}"),
                    ok: false,
                }
            }
        };
        let preview = match memory::preview_promote_staged_memory(
            &self.paths,
            &self.config.memory,
            &parsed.id,
            parsed.path.as_deref(),
            parsed.summary.as_deref(),
        ) {
            Ok(preview) => preview,
            Err(err) => {
                return ToolOutput {
                    content: err.to_string(),
                    ok: false,
                }
            }
        };
        let mut before_ctx = HookCtx::memory_event(
            &state.session_id,
            state.agent_name(),
            parent_agent_name.clone(),
            json!({ "id": parsed.id }),
            false,
        );
        before_ctx.intent = state.last_resolved_intent.clone();
        match self
            .hooks
            .run(HookPoint::BeforeMemoryPromote, &mut before_ctx)
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
        match self
            .adapter
            .confirm
            .confirm(ConfirmRequest {
                program: "promote_staged_memory".into(),
                args: vec![parsed.id.clone()],
                cwd: None,
                rendered: preview.rendered.clone(),
            })
            .await
        {
            ConfirmDecision::Deny => ToolOutput {
                content: "memory promotion denied by user".into(),
                ok: false,
            },
            ConfirmDecision::Timeout => ToolOutput {
                content: "confirm-timeout".into(),
                ok: false,
            },
            ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => {
                match memory::promote_staged_memory(&self.paths, &self.config.memory, &preview) {
                    Ok(dest_path) => {
                        let mut after_ctx = HookCtx::memory_event(
                            &state.session_id,
                            state.agent_name(),
                            parent_agent_name,
                            json!({
                                "id": parsed.id,
                                "dest_path": dest_path,
                            }),
                            false,
                        );
                        after_ctx.intent = state.last_resolved_intent.clone();
                        match self
                            .hooks
                            .run(HookPoint::AfterMemoryPromote, &mut after_ctx)
                            .await
                        {
                            HookOutcome::Continue => serialize_tool_value(&json!({
                                "id": parsed.id,
                                "destination_path": dest_path,
                            })),
                            HookOutcome::Abort(message) => ToolOutput {
                                content: message,
                                ok: false,
                            },
                        }
                    }
                    Err(err) => ToolOutput {
                        content: err.to_string(),
                        ok: false,
                    },
                }
            }
        }
    }

    fn dispatch_reject_staged_memory(&self, input: serde_json::Value) -> ToolOutput {
        let parsed = match serde_json::from_value::<RejectStagedMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid reject_staged_memory input: {err}"),
                    ok: false,
                }
            }
        };
        match memory::reject_staged_memory(
            &self.paths,
            &self.config.memory,
            &parsed.id,
            parsed.reason.as_deref(),
        ) {
            Ok(path) => serialize_tool_value(&json!({
                "id": parsed.id,
                "rejected_path": path,
            })),
            Err(err) => ToolOutput {
                content: err.to_string(),
                ok: false,
            },
        }
    }

    async fn dispatch_forget_memory(
        &mut self,
        state: &mut AgentState,
        parent_agent_name: Option<String>,
        input: serde_json::Value,
    ) -> ToolOutput {
        let parsed = match serde_json::from_value::<ForgetMemoryInput>(input) {
            Ok(parsed) => parsed,
            Err(err) => {
                return ToolOutput {
                    content: format!("invalid forget_memory input: {err}"),
                    ok: false,
                }
            }
        };
        let preview =
            match memory::preview_forget_memory(&self.paths, &self.config.memory, &parsed.target) {
                Ok(preview) => preview,
                Err(err) => {
                    return ToolOutput {
                        content: err.to_string(),
                        ok: false,
                    }
                }
            };

        let mut before_ctx = HookCtx::memory_event(
            &state.session_id,
            state.agent_name(),
            parent_agent_name.clone(),
            json!({ "target": parsed.target }),
            false,
        );
        before_ctx.intent = state.last_resolved_intent.clone();
        match self
            .hooks
            .run(HookPoint::BeforeMemoryForget, &mut before_ctx)
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

        match self
            .adapter
            .confirm
            .confirm(ConfirmRequest {
                program: "forget_memory".into(),
                args: vec![parsed.target.clone()],
                cwd: None,
                rendered: preview.rendered.clone(),
            })
            .await
        {
            ConfirmDecision::Deny => ToolOutput {
                content: "forget_memory denied by user".into(),
                ok: false,
            },
            ConfirmDecision::Timeout => ToolOutput {
                content: "confirm-timeout".into(),
                ok: false,
            },
            ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => {
                match memory::forget_memory(&self.paths, &self.config.memory, &preview) {
                    Ok(forgotten) => {
                        let mut after_ctx = HookCtx::memory_event(
                            &state.session_id,
                            state.agent_name(),
                            parent_agent_name,
                            json!({
                                "target": parsed.target,
                                "forgotten": forgotten,
                            }),
                            false,
                        );
                        after_ctx.intent = state.last_resolved_intent.clone();
                        match self
                            .hooks
                            .run(HookPoint::AfterMemoryForget, &mut after_ctx)
                            .await
                        {
                            HookOutcome::Continue => serialize_tool_value(&json!({
                                "target": parsed.target,
                                "forgotten": forgotten,
                            })),
                            HookOutcome::Abort(message) => ToolOutput {
                                content: message,
                                ok: false,
                            },
                        }
                    }
                    Err(err) => ToolOutput {
                        content: err.to_string(),
                        ok: false,
                    },
                }
            }
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
            ConfirmDecision::Timeout => Err(ToolOutput {
                content: "confirm-timeout".into(),
                ok: false,
            }),
            ConfirmDecision::AllowOnce | ConfirmDecision::AllowSession => Ok(()),
        }
    }

    fn build_subagent_memory_sections(
        &self,
        memory_hints: Option<&[String]>,
    ) -> Result<Vec<String>, String> {
        let Some(hints) = memory_hints else {
            return Ok(Vec::new());
        };

        let mut sections = Vec::new();
        let mut keywords = Vec::new();

        for hint in hints {
            let hint = hint.trim();
            if hint.is_empty() {
                continue;
            }

            if looks_like_memory_path(hint) {
                let content = memory::read_memory(
                    &self.paths,
                    ReadMemoryInput {
                        path: hint.to_string(),
                    },
                )
                .map_err(|err| {
                    format!("failed to resolve sub-agent memory hint `{hint}`: {err}")
                })?;
                let snippet = truncate_prompt_bytes(
                    content.trim(),
                    self.config.memory.max_prefetch_snippet_bytes,
                );
                if !snippet.is_empty() {
                    sections.push(format!("## Filtered memory note: {hint}\n{snippet}"));
                }
            } else {
                keywords.push(hint.to_string());
            }
        }

        if !keywords.is_empty() {
            let hits = memory::search_memory(
                &self.paths,
                &self.config.memory,
                SearchMemoryInput {
                    query: keywords.join(" "),
                    tier: MemoryTier::Durable,
                    limit: Some(self.config.memory.max_subagent_snippets),
                    include_superseded: false,
                },
            )
            .map_err(|err| format!("failed to search filtered sub-agent memory: {err}"))?;
            if !hits.is_empty() {
                let mut lines = vec!["## Filtered memory recall".to_string()];
                for hit in hits
                    .into_iter()
                    .take(self.config.memory.max_subagent_snippets)
                {
                    let snippet = truncate_prompt_bytes(
                        hit.snippet.trim(),
                        self.config.memory.max_prefetch_snippet_bytes,
                    );
                    lines.push(format!("- {} ({})", hit.title, hit.path));
                    if !snippet.is_empty() {
                        lines.push(snippet);
                    }
                }
                sections.push(lines.join("\n"));
            }
        }

        Ok(sections)
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

fn has_memory_cues(input: &str) -> bool {
    let lower = input.to_ascii_lowercase();
    [
        "remember",
        "memory",
        "recall",
        "what do you know",
        "last time",
        "preference",
        "prefer",
        "decision",
        "we use",
        "context",
        "staged",
        "learned",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn looks_like_memory_path(input: &str) -> bool {
    let value = input.trim();
    value.eq_ignore_ascii_case("MEMORY.md")
        || value.ends_with(".md")
        || value.contains('/')
        || value.starts_with("notes")
        || value.starts_with("daily")
        || value.starts_with("staging")
}

fn truncate_prompt_bytes(input: &str, max_bytes: usize) -> String {
    if input.len() <= max_bytes {
        return input.to_string();
    }

    let mut end = 0usize;
    for (idx, ch) in input.char_indices() {
        let next = idx + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    input[..end].to_string()
}

fn resolve_lua_script_budget(
    config: &config::ScriptingConfig,
    requested: Option<scripting::ScriptBudget>,
) -> Result<scripting::ScriptBudget, String> {
    let budget = requested.unwrap_or(scripting::ScriptBudget {
        max_execution_ms: config.max_execution_ms,
        max_memory_kb: config.max_memory_kb,
        max_output_bytes: config.max_output_bytes,
    });
    if budget.max_execution_ms == 0 || budget.max_memory_kb == 0 || budget.max_output_bytes == 0 {
        return Err("Lua script budget values must be >= 1".into());
    }
    if budget.max_execution_ms > scripting::LUA_MAX_EXECUTION_MS_CEILING {
        return Err(format!(
            "requested Lua max_execution_ms {} exceeds hard ceiling {}",
            budget.max_execution_ms,
            scripting::LUA_MAX_EXECUTION_MS_CEILING
        ));
    }
    if budget.max_memory_kb > scripting::LUA_MAX_MEMORY_KB_CEILING {
        return Err(format!(
            "requested Lua max_memory_kb {} exceeds hard ceiling {}",
            budget.max_memory_kb,
            scripting::LUA_MAX_MEMORY_KB_CEILING
        ));
    }
    if budget.max_output_bytes > scripting::LUA_MAX_OUTPUT_BYTES_CEILING {
        return Err(format!(
            "requested Lua max_output_bytes {} exceeds hard ceiling {}",
            budget.max_output_bytes,
            scripting::LUA_MAX_OUTPUT_BYTES_CEILING
        ));
    }
    Ok(budget)
}

fn render_script_outcome(
    mut base_input: serde_json::Value,
    outcome: scripting::ScriptOutcome,
) -> (String, bool, serde_json::Value) {
    match outcome {
        scripting::ScriptOutcome::Ok {
            result,
            budget_used,
        } => {
            attach_script_outcome_metadata(&mut base_input, "ok", Some(budget_used), None);
            let content =
                serde_json::to_string_pretty(&result).unwrap_or_else(|_| result.to_string());
            (content, true, base_input)
        }
        scripting::ScriptOutcome::CapExceeded { which, budget_used } => {
            let which = cap_kind_label(which);
            attach_script_outcome_metadata(
                &mut base_input,
                "cap-exceeded",
                Some(budget_used),
                Some(which),
            );
            (
                format!("Lua script cap exceeded: {which}"),
                false,
                base_input,
            )
        }
        scripting::ScriptOutcome::Error {
            message,
            budget_used,
        } => {
            attach_script_outcome_metadata(&mut base_input, "error", Some(budget_used), None);
            if let serde_json::Value::Object(map) = &mut base_input {
                map.insert("error".into(), serde_json::Value::String(message.clone()));
            }
            (message, false, base_input)
        }
    }
}

fn attach_script_outcome_metadata(
    value: &mut serde_json::Value,
    outcome: &str,
    budget_used: Option<scripting::BudgetUsed>,
    cap: Option<&str>,
) {
    if let serde_json::Value::Object(map) = value {
        map.insert(
            "outcome".into(),
            serde_json::Value::String(outcome.to_string()),
        );
        if let Some(budget_used) = budget_used {
            map.insert(
                "budget_used".into(),
                serde_json::to_value(budget_used).unwrap_or(serde_json::Value::Null),
            );
        }
        if let Some(cap) = cap {
            map.insert("cap".into(), serde_json::Value::String(cap.to_string()));
        }
    }
}

fn cap_kind_label(kind: scripting::CapKind) -> &'static str {
    match kind {
        scripting::CapKind::ExecutionTime => "execution-time",
        scripting::CapKind::Memory => "memory",
        scripting::CapKind::OutputBytes => "output-bytes",
    }
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
    let mut lines = vec![
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
            "turn budget usd:   {}",
            definition
                .budget
                .as_ref()
                .and_then(|budget| budget.max_turn_usd)
                .map(|value| format!("${value:.2}"))
                .unwrap_or_else(|| "(default)".into())
        ),
        format!(
            "turn budget time:  {}",
            definition
                .budget
                .as_ref()
                .and_then(|budget| budget.max_turn_s)
                .map(|value| format!("{value}s"))
                .unwrap_or_else(|| "(default)".into())
        ),
    ];
    lines.push(format!(
        "session name:      {}",
        definition
            .session_name
            .as_deref()
            .unwrap_or("(fresh per run)")
    ));
    lines.push(format!(
        "memory prefetch:   {}",
        definition
            .memory_prefetch
            .map(yes_no)
            .unwrap_or("(default)")
    ));
    lines.push(format!(
        "prompt:\n{}",
        indent_block(if definition.prompt.trim().is_empty() {
            "(empty)"
        } else {
            definition.prompt.trim()
        })
    ));
    lines
}

fn render_job_model(model: Option<&allbert_proto::ModelConfigPayload>) -> String {
    match model {
        Some(model) => format!(
            "{} / {}",
            Provider::from_proto_kind(model.provider).label(),
            model.model_id
        ),
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
    if input.len() <= max_bytes {
        return input.to_string();
    }

    let mut end = max_bytes;
    while end > 0 && !input.is_char_boundary(end) {
        end -= 1;
    }
    input[..end].to_string()
}

fn render_staged_notice_entry(entry: &StagedNoticeEntry, max_bytes: usize) -> String {
    let raw = format!("{} \"{}\"", entry.id, entry.summary.trim());
    truncate_to_bytes(&raw, max_bytes)
}

fn intent_shape(intent: &Intent) -> IntentShape {
    match intent {
        Intent::Chat => IntentShape {
            prompt_preamble:
                "Intent guidance: stay conversational, keep side effects low, and prefer a natural-language answer unless the user explicitly asks you to act.",
            tool_priority_order: &["request_input", "read_memory", "read_file"],
        },
        Intent::Task => IntentShape {
            prompt_preamble:
                "Intent guidance: use the normal problem-solving posture, act when useful, and keep delegated work within the default sub-agent budget unless the task clearly needs more.",
            tool_priority_order: &[
                "read_file",
                "process_exec",
                "request_input",
                "spawn_subagent",
            ],
        },
        Intent::Schedule => IntentShape {
            prompt_preamble:
                "Intent guidance: prefer daemon-backed job management, foreground durable effects, and use confirmation language that makes recurring changes explicit.",
            tool_priority_order: &[
                "list_jobs",
                "get_job",
                "upsert_job",
                "pause_job",
                "resume_job",
                "run_job",
                "remove_job",
            ],
        },
        Intent::MemoryQuery => IntentShape {
            prompt_preamble:
                "Intent guidance: retrieve first, answer from evidence, and keep the response concise and grounded in cited memory hits when possible.",
            tool_priority_order: &[
                "search_memory",
                "read_memory",
                "list_staged_memory",
                "get_job",
            ],
        },
        Intent::Meta => IntentShape {
            prompt_preamble:
                "Intent guidance: prefer operator and status surfaces, avoid unnecessary side effects, and reach for setup, model, cost, or daemon status tools before broader action.",
            tool_priority_order: &[
                "request_input",
                "read_memory",
                "search_memory",
            ],
        },
    }
}

#[cfg(test)]
#[allow(
    clippy::field_reassign_with_default,
    clippy::io_other_error,
    clippy::too_many_arguments,
    clippy::type_complexity
)]
mod tests {
    use std::collections::VecDeque;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    use async_trait::async_trait;
    use serde_json::json;

    use super::*;
    use crate::error::LlmError;
    use crate::llm::{CompletionRequest, CompletionResponse, Pricing, Usage};
    use crate::security::{
        exec_policy, sandbox, web_policy, web_policy_with_resolver, HostResolver, NormalizedExec,
        PolicyDecision,
    };

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
        let dir = paths.skills_installed.join(name);
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
        let dir = paths.skills_installed.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("SKILL.md"), raw).unwrap();
    }

    fn write_skill_with_reference(
        paths: &AllbertPaths,
        name: &str,
        description: &str,
        allowed_tools: &str,
        body: &str,
        reference_path: &str,
        reference_body: &str,
    ) {
        let dir = paths.skills_installed.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!(
                "---\nname: {name}\ndescription: {description}\nallowed-tools: {allowed_tools}\n---\n\n{body}\n"
            ),
        )
        .unwrap();
        let reference_file = dir.join(reference_path);
        fs::create_dir_all(reference_file.parent().unwrap()).unwrap();
        fs::write(reference_file, reference_body).unwrap();
    }

    fn write_skill_with_script(
        paths: &AllbertPaths,
        name: &str,
        description: &str,
        body: &str,
        script_name: &str,
        interpreter: &str,
        script_rel_path: &str,
        script_body: &str,
    ) {
        let dir = paths.skills_installed.join(name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("SKILL.md"),
            format!(
                "---\nname: {name}\ndescription: {description}\nscripts:\n  - name: {script_name}\n    path: {script_rel_path}\n    interpreter: {interpreter}\n---\n\n{body}\n"
            ),
        )
        .unwrap();
        let script_file = dir.join(script_rel_path);
        fs::create_dir_all(script_file.parent().unwrap()).unwrap();
        fs::write(script_file, script_body).unwrap();
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

    struct FakeResolver {
        result: Result<Vec<std::net::SocketAddr>, std::io::Error>,
        delay_ms: u64,
    }

    impl FakeResolver {
        fn ok(addrs: Vec<std::net::SocketAddr>) -> Self {
            Self {
                result: Ok(addrs),
                delay_ms: 0,
            }
        }

        fn err(message: &str) -> Self {
            Self {
                result: Err(std::io::Error::new(
                    std::io::ErrorKind::Other,
                    message.to_string(),
                )),
                delay_ms: 0,
            }
        }

        fn delayed_ok(addrs: Vec<std::net::SocketAddr>, delay_ms: u64) -> Self {
            Self {
                result: Ok(addrs),
                delay_ms,
            }
        }
    }

    #[async_trait]
    impl HostResolver for FakeResolver {
        async fn lookup_host(
            &self,
            _host: &str,
            _port: u16,
        ) -> std::io::Result<Vec<std::net::SocketAddr>> {
            if self.delay_ms > 0 {
                tokio::time::sleep(Duration::from_millis(self.delay_ms)).await;
            }
            match &self.result {
                Ok(addrs) => Ok(addrs.clone()),
                Err(err) => Err(std::io::Error::new(err.kind(), err.to_string())),
            }
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

    struct ToolHookRecorder {
        label: &'static str,
        seen: Arc<Mutex<Vec<(String, String, serde_json::Value)>>>,
    }

    #[async_trait]
    impl Hook for ToolHookRecorder {
        async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
            if let Some(invocation) = &ctx.tool_invocation {
                self.seen.lock().unwrap().push((
                    self.label.to_string(),
                    invocation.name.clone(),
                    invocation.input.clone(),
                ));
            }
            HookOutcome::Continue
        }
    }

    struct MemoryRecordingHook {
        label: &'static str,
        seen: Arc<Mutex<Vec<(String, bool)>>>,
    }

    #[async_trait]
    impl Hook for MemoryRecordingHook {
        async fn call(&self, ctx: &mut HookCtx) -> HookOutcome {
            self.seen
                .lock()
                .unwrap()
                .push((self.label.to_string(), ctx.memory_refresh));
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
        assert!(
            !paths.personality.exists(),
            "PERSONALITY.md should be optional and absent by default"
        );
        assert!(paths.bootstrap.exists(), "BOOTSTRAP.md should exist");
        assert_eq!(config.model.provider, Provider::Ollama);
        assert_eq!(config.model.model_id, "gemma4");
        assert_eq!(config.model.api_key_env, None);
        assert_eq!(
            config.model.base_url.as_deref(),
            Some("http://127.0.0.1:11434")
        );
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
        assert!(paths.agents_notes.exists());
        assert!(paths.bootstrap.exists());
        assert!(paths.skills.exists());
        assert!(paths.memory.exists());
        assert!(paths.memory_index.exists());
        assert!(paths.memory_manifest.exists());
        assert!(paths.memory_daily.exists());
        assert!(paths.memory_notes.exists());
        assert!(paths.memory_staging.exists());
        assert!(paths.memory_staging_expired.exists());
        assert!(paths.memory_staging_rejected.exists());
        assert!(paths.memory_index_dir.exists());
        assert!(paths.memory_migrations.exists());
        assert!(paths.memory_trash.exists());
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
            paths.clone(),
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
        let cost_entry = recorded
            .iter()
            .find_map(|event| match event {
                KernelEvent::Cost(entry) => Some(entry),
                _ => None,
            })
            .expect("cost event should be emitted");
        assert_eq!(cost_entry.agent_name, "allbert/root");
        assert_eq!(cost_entry.parent_agent_name, None);
        assert_eq!(cost_entry.provider, "anthropic");
        assert_eq!(cost_entry.model, "gemma4");
        assert!((cost_entry.usd_estimate - 0.02).abs() < 1e-9);

        assert!(recorded
            .iter()
            .any(|event| matches!(event, KernelEvent::AssistantText(text) if text == "4")));
        assert!(recorded.iter().any(
            |event| matches!(event, KernelEvent::TurnDone { hit_turn_limit } if !hit_turn_limit)
        ));

        let log =
            std::fs::read_to_string(kernel.paths().costs.clone()).expect("cost log should exist");
        assert_eq!(log.lines().count(), 1);
        assert!((kernel.session_cost_usd() - 0.02).abs() < 1e-9);
    }

    #[tokio::test]
    async fn telemetry_context_percentage_is_unknown_when_context_window_zero() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut config = Config::default_template();
        config.model.context_window_tokens = 0;
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "ollama",
                vec![CompletionResponse {
                    text: "hello".into(),
                    usage: Usage {
                        input_tokens: 10,
                        output_tokens: 5,
                        cache_read: 2,
                        cache_create: 1,
                    },
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("hello").await.expect("turn should succeed");
        let telemetry = kernel
            .session_telemetry(allbert_proto::ChannelKind::Repl, 0, false)
            .expect("telemetry should compose");

        assert_eq!(telemetry.context_window_tokens, 0);
        assert_eq!(telemetry.context_used_tokens, Some(15));
        assert_eq!(telemetry.context_percent, None);
    }

    #[tokio::test]
    async fn telemetry_tracks_latest_usage_without_changing_cost_accounting() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut config = Config::default_template();
        config.model.context_window_tokens = 100;
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "ollama",
                vec![CompletionResponse {
                    text: "hello".into(),
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

        kernel.run_turn("hello").await.expect("turn should succeed");
        let cost_before = kernel.session_cost_usd();
        let telemetry = kernel
            .session_telemetry(allbert_proto::ChannelKind::Cli, 2, true)
            .expect("telemetry should compose");

        assert_eq!(kernel.session_cost_usd(), cost_before);
        assert_eq!(telemetry.context_percent, Some(15.0));
        assert_eq!(telemetry.inbox_count, 2);
        assert!(telemetry.trace_enabled);
        assert_eq!(
            telemetry.last_response_usage.as_ref().map(|usage| (
                usage.input_tokens,
                usage.output_tokens,
                usage.total_tokens
            )),
            Some((10, 5, 15))
        );
        assert_eq!(telemetry.session_usage.total_tokens, 15);
        assert_eq!(telemetry.session_cost_usd, cost_before);
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
    async fn spawn_subagent_without_memory_hints_starts_with_zero_retrieved_memory() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(&paths.memory_notes).unwrap();
        fs::write(
            paths.memory_notes.join("postgres.md"),
            "# Postgres\n\nUniqueMemoryAlpha lives here.\n",
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
                                    "name": "researcher",
                                    "prompt": "Summarize what memory says."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_OK".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "ROOT_OK".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("delegate memory work").await.unwrap();

        let recorded_requests = requests.lock().unwrap();
        let subagent_system = recorded_requests[1].system.as_ref().unwrap();
        assert!(
            !subagent_system.contains("UniqueMemoryAlpha"),
            "sub-agent should not inherit retrieved memory without explicit hints"
        );
        assert!(
            !subagent_system.contains("Filtered memory recall"),
            "sub-agent should not get a filtered slice when no hints are passed"
        );
    }

    #[tokio::test]
    async fn spawn_subagent_with_memory_hints_gets_filtered_memory_slice() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::create_dir_all(&paths.memory_notes).unwrap();
        fs::write(
            paths.memory_notes.join("postgres.md"),
            "# Postgres\n\nUniqueMemoryBeta lives here.\n",
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
                                    "name": "researcher",
                                    "prompt": "Summarize what memory says.",
                                    "memory_hints": ["notes/postgres.md", "UniqueMemoryBeta"]
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_OK".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "ROOT_OK".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("delegate memory work").await.unwrap();

        let recorded_requests = requests.lock().unwrap();
        let subagent_system = recorded_requests[1].system.as_ref().unwrap();
        assert!(subagent_system.contains("Filtered memory note: notes/postgres.md"));
        assert!(subagent_system.contains("UniqueMemoryBeta"));
    }

    #[tokio::test]
    async fn spawn_subagent_allows_recursive_spawns_when_budget_remains() {
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
                                    "prompt": "Reply with NESTED.",
                                    "budget": {
                                        "usd": 0.01,
                                        "seconds": 30
                                    }
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "NESTED_DONE".into(),
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
        assert_eq!(recorded_requests.len(), 5);
        assert!(
            recorded_requests[2].messages[0]
                .content
                .contains("Reply with NESTED."),
            "nested sub-agent should receive the delegated prompt"
        );
        assert!(
            recorded_requests[3]
                .messages
                .last()
                .unwrap()
                .content
                .contains("\"agent_name\": \"nested\""),
            "intermediate sub-agent should see structured nested-agent output"
        );
    }

    #[tokio::test]
    async fn spawn_subagent_rejects_invalid_budget_requests() {
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
                                    "prompt": "Try an impossible budget.",
                                    "budget": {
                                        "usd": 99.0,
                                        "seconds": 9999
                                    }
                                }
                            })
                        ),
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
            .run_turn("delegate invalid work")
            .await
            .expect("turn should succeed");

        let recorded_requests = requests.lock().unwrap();
        assert_eq!(recorded_requests.len(), 2);
        assert!(
            recorded_requests[1]
                .messages
                .last()
                .unwrap()
                .content
                .contains("budget-invalid"),
            "root follow-up should receive the structured invalid-budget tool error"
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
        assert!(system.contains("prefer daemon-backed job management"));
        assert!(system.contains("Preferred tool order: list_jobs, get_job, upsert_job"));
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
        assert!(
            requests[1]
                .system
                .as_ref()
                .unwrap()
                .contains("stay conversational"),
            "chat intent should shape the prompt preamble"
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
        assert!(
            requests[0].system.as_ref().unwrap().contains(
                "Preferred tool order: read_file, process_exec, request_input, spawn_subagent"
            ),
            "task intent should surface its preferred tool ordering"
        );
    }

    #[tokio::test]
    async fn meta_intent_shapes_prompt_without_hard_gating() {
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
                    text: "META_OK".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("show status")
            .await
            .expect("turn should succeed");

        let requests = requests.lock().unwrap();
        let system = requests[0].system.as_ref().unwrap();
        assert!(system.contains("Resolved intent: meta"));
        assert!(system.contains("prefer operator and status surfaces"));
        assert!(system.contains("Preferred tool order: request_input, read_memory, search_memory"));
        assert!(
            system.contains("- process_exec:") || system.contains("\"name\":\"process_exec\""),
            "meta intent should not hard-gate tools out of the prompt surface"
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

        let ollama_factory = Arc::new(TestFactory::with_seen(
            "anthropic",
            seen.clone(),
            Vec::new(),
            Some(test_pricing()),
        ));
        let ollama_kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            ollama_factory,
        )
        .await
        .expect("ollama default kernel should boot");
        assert_eq!(ollama_kernel.provider_name(), "anthropic");

        let mut openrouter_config = Config::default_template();
        openrouter_config.model.provider = Provider::Openrouter;
        openrouter_config.model.model_id = "anthropic/claude-sonnet-4".into();
        openrouter_config.model.api_key_env = Some("OPENROUTER_API_KEY".into());

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
        assert_eq!(seen[0], Provider::Ollama);
        assert_eq!(seen[1], Provider::Openrouter);
    }

    #[tokio::test]
    async fn run_turn_with_attachments_keeps_session_scoped_image_in_model_history() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests_and_image_support(
                "anthropic",
                requests.clone(),
                vec![CompletionResponse {
                    text: "done".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
                true,
            )),
        )
        .await
        .expect("kernel should boot");

        let attachment = ChatAttachment {
            kind: ChatAttachmentKind::Image,
            path: temp.path.join("sessions/session-1/artifacts/photo.jpg"),
            mime_type: Some("image/jpeg".into()),
            display_name: Some("telegram photo".into()),
        };
        kernel
            .run_turn_with_attachments("what is in this image?", vec![attachment.clone()])
            .await
            .expect("turn should succeed");

        let recorded = requests.lock().unwrap();
        assert_eq!(recorded.len(), 1);
        let user_message = recorded[0]
            .messages
            .first()
            .expect("user message should exist");
        assert_eq!(user_message.attachments, vec![attachment]);
        assert!(user_message.content.contains("[Attached image:"));
    }

    #[tokio::test]
    async fn supports_image_input_reflects_provider_capability() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests_and_image_support(
                "anthropic",
                Arc::new(Mutex::new(Vec::new())),
                Vec::new(),
                Some(test_pricing()),
                true,
            )),
        )
        .await
        .expect("kernel should boot");

        assert!(kernel.supports_image_input());
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
        std::fs::write(
            &paths.personality,
            "# PERSONALITY\n\n## Learned Collaboration Style\n- Prefer concrete next steps.\n",
        )
        .expect("should write PERSONALITY.md");

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
        assert!(system.contains("## PERSONALITY.md"));
        assert!(system.contains("Prefer concrete next steps."));
        assert!(system.contains("## AGENTS.md"));
        assert!(system.contains("## HEARTBEAT.md"));
        assert!(system.contains("## allbert/root"));
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
        let tools_idx = system
            .find("## TOOLS.md")
            .expect("TOOLS.md section should exist");
        let personality_idx = system
            .find("## PERSONALITY.md")
            .expect("PERSONALITY.md section should exist");
        let agents_idx = system
            .find("## AGENTS.md")
            .expect("AGENTS.md section should exist");
        assert!(soul_idx < user_idx);
        assert!(user_idx < identity_idx);
        assert!(identity_idx < tools_idx);
        assert!(tools_idx < personality_idx);
        assert!(personality_idx < agents_idx);
        assert!(system.contains("PERSONALITY.md, treat it as reviewed learned"));
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
                program: "sh".into(),
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
    async fn web_policy_deterministically_covers_timeout_lookup_and_ssrf_cases() {
        let mut config = WebSecurityConfig::default();
        config.timeout_s = 1;

        let public = FakeResolver::ok(vec!["93.184.216.34:443".parse().unwrap()]);
        assert!(matches!(
            web_policy_with_resolver("https://example.com", &config, &public).await,
            PolicyDecision::AutoAllow
        ));

        let blocked = FakeResolver::ok(vec!["127.0.0.1:443".parse().unwrap()]);
        assert!(matches!(
            web_policy_with_resolver("https://example.com", &config, &blocked).await,
            PolicyDecision::Deny(_)
        ));

        let empty = FakeResolver::ok(Vec::new());
        assert!(matches!(
            web_policy_with_resolver("https://example.com", &config, &empty).await,
            PolicyDecision::Deny(_)
        ));

        let lookup_err = FakeResolver::err("nxdomain");
        assert!(matches!(
            web_policy_with_resolver("https://example.com", &config, &lookup_err).await,
            PolicyDecision::Deny(_)
        ));

        let mut timeout = WebSecurityConfig::default();
        timeout.timeout_s = 0;
        let delayed = FakeResolver::delayed_ok(vec!["93.184.216.34:443".parse().unwrap()], 5);
        assert!(matches!(
            web_policy_with_resolver("https://example.com", &timeout, &delayed).await,
            PolicyDecision::Deny(_)
        ));
    }

    #[tokio::test]
    async fn web_policy_real_integration_covers_stable_scheme_and_host_rules() {
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
        allow.timeout_s = 1;
        assert!(matches!(
            web_policy("https://news.ycombinator.com", &allow).await,
            PolicyDecision::Deny(_)
        ));

        let mut deny = WebSecurityConfig::default();
        deny.deny_hosts = vec!["example.com".into()];
        deny.timeout_s = 1;
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
        assert!(recorded.iter().any(
            |event| matches!(event, KernelEvent::ToolCall { name, .. } if name == "request_input")
        ));
        assert!(recorded
            .iter()
            .any(|event| matches!(event, KernelEvent::ToolResult { name, ok, content } if name == "request_input" && *ok && content == "blue")));
        assert!(recorded
            .iter()
            .any(|event| matches!(event, KernelEvent::AssistantText(text) if text == "Thanks, I noted blue.")));
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

        assert!(recorded
            .iter()
            .any(|event| matches!(event, KernelEvent::ToolResult { name, ok, content } if name == "request_input" && !*ok && content.contains("cancelled"))));
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
        assert!(recorded.iter().any(
            |event| matches!(event, KernelEvent::ToolResult { content, .. } if content == "1234")
        ));
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
        let broken_dir = paths.skills_installed.join("broken");
        fs::create_dir_all(&broken_dir).unwrap();
        fs::write(broken_dir.join("SKILL.md"), "not frontmatter").unwrap();

        let store = SkillStore::discover(&paths.skills);
        assert!(store.all().iter().any(|skill| skill.name == "good-skill"));
        assert!(!store.all().iter().any(|skill| skill.name == "broken"));
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
    async fn active_skill_prompt_does_not_inline_reference_content() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_reference(
            &paths,
            "research-assistant",
            "Research with references",
            "read_reference",
            "When needed, consult references/guide.md before answering.",
            "references/guide.md",
            "DEEP REFERENCE MATERIAL",
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
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"research-assistant\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Using the skill body only.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("activate the skill")
            .await
            .expect("activation should succeed");
        kernel
            .run_turn("use the skill")
            .await
            .expect("follow-up turn should succeed");

        let requests = captured_requests.lock().unwrap();
        let second_turn_system = requests[2].system.as_ref().unwrap();
        assert!(second_turn_system.contains("research-assistant: Research with references"));
        assert!(second_turn_system
            .contains("When needed, consult references/guide.md before answering."));
        assert!(
            !second_turn_system.contains("DEEP REFERENCE MATERIAL"),
            "tier 3 references should not be inlined into the prompt"
        );
    }

    #[tokio::test]
    async fn read_reference_caches_per_turn_and_emits_tier_events_in_order() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_reference(
            &paths,
            "research-assistant",
            "Research with references",
            "read_reference",
            "Use references/guide.md when the user asks for supporting detail.",
            "references/guide.md",
            "DEEP REFERENCE MATERIAL",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"research-assistant\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: concat!(
                            "<tool_call>{\"name\":\"read_reference\",\"input\":{\"skill\":\"research-assistant\",\"path\":\"references/guide.md\"}}</tool_call>",
                            "<tool_call>{\"name\":\"read_reference\",\"input\":{\"skill\":\"research-assistant\",\"path\":\"references/guide.md\"}}</tool_call>"
                        )
                        .into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done with the reference.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("activate the skill")
            .await
            .expect("activation should succeed");
        events.lock().unwrap().clear();

        kernel
            .run_turn("use the supporting material")
            .await
            .expect("reference turn should succeed");

        let recorded = events.lock().unwrap();
        let tier1_idx = recorded
            .iter()
            .position(|event| {
                matches!(
                    event,
                    KernelEvent::SkillTier1Surfaced { skill_name }
                        if skill_name == "research-assistant"
                )
            })
            .expect("tier 1 event should fire");
        let tier2_idx = recorded
            .iter()
            .position(|event| {
                matches!(
                    event,
                    KernelEvent::SkillTier2Activated { skill_name }
                        if skill_name == "research-assistant"
                )
            })
            .expect("tier 2 event should fire");
        let tier3_events = recorded
            .iter()
            .filter(|event| {
                matches!(
                    event,
                    KernelEvent::SkillTier3Referenced { skill_name, path }
                        if skill_name == "research-assistant" && path == "references/guide.md"
                )
            })
            .count();
        assert_eq!(tier3_events, 1, "tier 3 reads should be cached per turn");

        let tool_results = recorded
            .iter()
            .filter_map(|event| match event {
                KernelEvent::ToolResult { name, ok, content } if name == "read_reference" => {
                    Some((*ok, content.clone()))
                }
                _ => None,
            })
            .collect::<Vec<_>>();
        assert_eq!(tool_results.len(), 2);
        assert!(tool_results.iter().all(|(ok, _)| *ok));
        assert!(
            tool_results
                .iter()
                .all(|(_, content)| content == "DEEP REFERENCE MATERIAL"),
            "cached and uncached reference reads should return identical content"
        );

        let tier3_idx = recorded
            .iter()
            .position(|event| {
                matches!(
                    event,
                    KernelEvent::SkillTier3Referenced { skill_name, path }
                        if skill_name == "research-assistant" && path == "references/guide.md"
                )
            })
            .expect("tier 3 event should fire");
        assert!(tier1_idx < tier2_idx);
        assert!(tier2_idx < tier3_idx);
    }

    #[tokio::test]
    async fn run_skill_script_executes_declared_python_script_via_exec_path() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "script-runner",
            "Run a helper script",
            "Use the helper script when needed.",
            "helper",
            "python",
            "scripts/helper.py",
            "import sys\nprint('script:' + ' '.join(sys.argv[1:]))\n",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"script-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"script-runner\",\"script\":\"helper\",\"args\":[\"alpha\",\"beta\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script" && *ok && content.contains("script:alpha beta")
        )));
    }

    #[tokio::test]
    async fn run_skill_script_reports_missing_interpreter_allowlist() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "node-runner",
            "Run a node helper",
            "Use the node helper when needed.",
            "helper",
            "node",
            "scripts/helper.js",
            "console.log('hello');\n",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"node-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"node-runner\",\"script\":\"helper\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script"
                    && !*ok
                    && content.contains("not allowlisted")
                    && content.contains("config.security.exec_allow")
        )));
    }

    #[tokio::test]
    async fn scripting_lua_skill_loads_but_reports_engine_disabled() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "lua-runner",
            "Run a Lua helper",
            "Use the Lua helper when needed.",
            "helper",
            "lua",
            "scripts/helper.lua",
            "return function(input) return { ok = true, args = input.args } end\n",
        );

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"lua-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"args\":[\"alpha\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot with Lua-declaring skill");

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script"
                    && !*ok
                    && content.contains("Lua scripting engine is disabled")
        )));
    }

    #[tokio::test]
    async fn lua_two_step_opt_in_requires_exec_allow() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "lua-runner",
            "Run a Lua helper",
            "Use the Lua helper when needed.",
            "helper",
            "lua",
            "scripts/helper.lua",
            "return function(_) return { ok = true } end\n",
        );

        let mut config = Config::default_template();
        config.scripting.engine = config::ScriptingEngineConfig::Lua;

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"lua-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script"
                    && !*ok
                    && content.contains("not allowlisted")
        )));
    }

    #[tokio::test]
    async fn scripting_lua_invocation_emits_synthetic_hook_metadata() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "lua-runner",
            "Run a Lua helper",
            "Use the Lua helper when needed.",
            "helper",
            "lua",
            "scripts/helper.lua",
            "return function(input) return { message = 'hello ' .. input.name } end\n",
        );

        let mut config = Config::default_template();
        config.scripting.engine = config::ScriptingEngineConfig::Lua;
        config.security.exec_allow.push("lua".into());

        let events = Arc::new(Mutex::new(Vec::new()));
        let hook_events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"lua-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"input\":{\"name\":\"Allbert\"}}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");
        kernel.register_hook(
            HookPoint::BeforeTool,
            Arc::new(ToolHookRecorder {
                label: "before",
                seen: Arc::clone(&hook_events),
            }),
        );
        kernel.register_hook(
            HookPoint::AfterTool,
            Arc::new(ToolHookRecorder {
                label: "after",
                seen: Arc::clone(&hook_events),
            }),
        );

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        hook_events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script"
                    && *ok
                    && content.contains("\"message\": \"hello Allbert\"")
        )));

        let hooks = hook_events.lock().unwrap();
        assert!(hooks.iter().any(|(label, name, input)| {
            label == "before"
                && name == "exec.lua:lua-runner/scripts/helper.lua"
                && input["engine"] == "lua"
        }));
        assert!(hooks.iter().any(|(label, name, input)| {
            label == "after"
                && name == "exec.lua:lua-runner/scripts/helper.lua"
                && input["outcome"] == "ok"
                && input["budget_used"]["output_bytes"].as_u64().unwrap_or(0) > 0
        }));
    }

    #[tokio::test]
    async fn lua_budget_override_above_hard_ceiling_is_denied() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        write_skill_with_script(
            &paths,
            "lua-runner",
            "Run a Lua helper",
            "Use the Lua helper when needed.",
            "helper",
            "lua",
            "scripts/helper.lua",
            "return function(_) return { ok = true } end\n",
        );

        let mut config = Config::default_template();
        config.scripting.engine = config::ScriptingEngineConfig::Lua;
        config.security.exec_allow.push("lua".into());

        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"lua-runner\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"budget\":{\"max_execution_ms\":30001,\"max_memory_kb\":1024,\"max_output_bytes\":4096}}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("activate").await.expect("turn should pass");
        events.lock().unwrap().clear();
        kernel.run_turn("run it").await.expect("turn should pass");

        let recorded = events.lock().unwrap();
        assert!(recorded.iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "run_skill_script"
                    && !*ok
                    && content.contains("exceeds hard ceiling")
        )));
    }

    #[tokio::test]
    async fn normalized_example_skill_can_activate_read_reference_and_run_script() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        install_example_skill(&paths);

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::new("anthropic", vec![], Some(test_pricing()))),
        )
        .await
        .expect("kernel should boot");

        let invoked = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "invoke_skill".into(),
                input: json!({ "name": "note-taker", "args": { "title": "Release Retro" } }),
            },
        )
        .await;
        assert!(invoked.ok);
        assert_eq!(kernel.active_skills()[0].name, "note-taker");

        let reference = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "read_reference".into(),
                input: json!({ "skill": "note-taker", "path": "references/note-template.md" }),
            },
        )
        .await;
        assert!(reference.ok);
        assert!(reference.content.contains("# Note Template"));

        let script = run_tool_via_kernel(
            &mut kernel,
            ToolInvocation {
                name: "run_skill_script".into(),
                input: json!({ "skill": "note-taker", "script": "slugify", "args": ["Release Retro"] }),
            },
        )
        .await;
        assert!(script.ok);
        assert!(script.content.contains("release-retro"));
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
    async fn provenance_create_skill_writes_incoming_draft_and_does_not_install() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
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
                                    "name":"weather-note",
                                    "description":"Capture weather notes",
                                    "skip_quarantine":false,
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
        assert!(paths
            .skills_incoming
            .join("weather-note")
            .join("SKILL.md")
            .exists());
        assert!(!paths
            .skills_installed
            .join("weather-note")
            .join("SKILL.md")
            .exists());
        let persisted =
            fs::read_to_string(paths.skills_incoming.join("weather-note").join("SKILL.md"))
                .unwrap();
        assert!(persisted.contains("provenance: self-authored"));
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "create_skill" && *ok && content.contains("standard skill install flow")
        )));
    }

    #[tokio::test]
    async fn provenance_create_skill_overwrite_requires_confirm() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let incoming = paths.skills_incoming.join("overwrite-me");
        fs::create_dir_all(&incoming).unwrap();
        fs::write(
            incoming.join("SKILL.md"),
            "---\nname: overwrite-me\ndescription: Old\nprovenance: self-authored\nallowed-tools: request_input\n---\n\nOld body\n",
        )
        .unwrap();
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
                                    "skip_quarantine":false,
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
            fs::read_to_string(paths.skills_incoming.join("overwrite-me").join("SKILL.md"))
                .unwrap();
        assert!(persisted.contains("Old body"));
    }

    #[tokio::test]
    async fn provenance_create_skill_requires_explicit_quarantine_choice() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name":"create_skill",
                                "input":{
                                    "name":"missing-choice",
                                    "description":"Missing",
                                    "allowed_tools":["request_input"],
                                    "body":"Body"
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

        kernel.run_turn("create").await.expect("turn should pass");
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "create_skill" && !*ok && content.contains("skip_quarantine")
        )));
    }

    #[tokio::test]
    async fn provenance_create_skill_rejects_prompt_originated_quarantine_bypass() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name":"create_skill",
                                "input":{
                                    "name":"bypass",
                                    "description":"Bypass",
                                    "skip_quarantine":true,
                                    "allowed_tools":["request_input"],
                                    "body":"Body"
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

        kernel.run_turn("create").await.expect("turn should pass");
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "create_skill" && !*ok && content.contains("first-party kernel seeding")
        )));
    }

    #[tokio::test]
    async fn skill_author_seeded_into_skill_catalog_prompt() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                Arc::clone(&requests),
                vec![CompletionResponse {
                    text: "ready".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("make me a skill that summarizes release notes")
            .await
            .expect("turn should pass");
        assert!(paths
            .skills_installed
            .join("skill-author/SKILL.md")
            .exists());
        let recorded = requests.lock().unwrap();
        let system = recorded
            .first()
            .and_then(|request| request.system.as_deref())
            .expect("system prompt should be captured");
        assert!(system.contains("- skill-author:"));
        assert!(system.contains("provenance: external"));
    }

    #[tokio::test]
    async fn skill_author_flow_creates_persistent_incoming_draft() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(
                Arc::clone(&events),
                Arc::new(NoopConfirm),
                Arc::new(QueueInput::new(vec![
                    InputResponse::Submitted("release-note-helper".into()),
                    InputResponse::Submitted("Summarize release notes.".into()),
                    InputResponse::Submitted(
                        "Read release notes and produce a concise operator summary.".into(),
                    ),
                    InputResponse::Submitted("python".into()),
                    InputResponse::Submitted("read_reference".into()),
                ])),
            ),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"skill-author\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Skill name?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Description?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Capability summary?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Interpreter?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Allowed tools?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name":"create_skill",
                                "input":{
                                    "name":"release-note-helper",
                                    "description":"Summarize release notes.",
                                    "skip_quarantine":false,
                                    "allowed_tools":["read_reference"],
                                    "body":"Use this skill to read release notes and produce a concise operator summary. Prefer Python only if a future script is needed."
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Draft is ready for install preview.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel
            .run_turn("make me a skill that summarizes release notes")
            .await
            .expect("turn should pass");
        assert!(!summary.hit_turn_limit);

        let draft_path = paths.skills_incoming.join("release-note-helper/SKILL.md");
        assert!(draft_path.exists(), "draft should persist in quarantine");
        assert!(!paths
            .skills_installed
            .join("release-note-helper/SKILL.md")
            .exists());
        let draft = fs::read_to_string(&draft_path).expect("draft should be readable");
        assert!(draft.contains("provenance: self-authored"));
        assert!(events.lock().unwrap().iter().any(|event| matches!(
            event,
            KernelEvent::ToolResult { name, ok, content }
                if name == "create_skill" && *ok && content.contains("standard skill install flow")
        )));

        let _second = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::new("anthropic", vec![], Some(test_pricing()))),
        )
        .await
        .expect("second kernel should boot");
        assert!(
            draft_path.exists(),
            "incoming draft should survive a fresh kernel session"
        );
    }

    #[tokio::test]
    async fn skill_frontmatter_preview_parses_intents_and_contributed_agents() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let skill_dir = paths.skills_installed.join("planner");
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
                "model:\n",
                "  provider: ollama\n",
                "  model_id: gemma4\n",
                "  base_url: http://127.0.0.1:11434\n",
                "  max_tokens: 2048\n",
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
        let model = skill.agents[0]
            .model
            .as_ref()
            .expect("contributed agent model should parse");
        assert_eq!(model.provider, Provider::Ollama);
        assert_eq!(model.model_id, "gemma4");
        assert_eq!(model.api_key_env, None);
        assert_eq!(model.base_url.as_deref(), Some("http://127.0.0.1:11434"));
        assert_eq!(model.max_tokens, 2048);

        let agents = kernel.list_agents();
        assert!(agents
            .iter()
            .any(|agent| agent.name == "planner/researcher"));
    }

    #[tokio::test]
    async fn agents_markdown_is_generated_on_boot_with_read_only_header() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let skill_dir = paths.skills_installed.join("planner");
        fs::create_dir_all(skill_dir.join("agents")).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            concat!(
                "---\n",
                "name: planner\n",
                "description: Planner skill\n",
                "agents:\n",
                "  - agents/researcher.md\n",
                "---\n\n",
                "Plan work.\n"
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
                "Research carefully.\n"
            ),
        )
        .unwrap();

        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                Vec::new(),
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let rendered = fs::read_to_string(&paths.agents_notes).expect("AGENTS.md should exist");
        assert!(rendered.starts_with("<!-- This file is generated by Allbert."));
        assert!(rendered.contains("## allbert/root"));
        assert!(rendered.contains("## planner/researcher"));
        assert!(rendered.contains("- contributing skill: planner"));
        assert_eq!(kernel.agents_markdown(), rendered);
    }

    #[tokio::test]
    async fn refresh_skill_catalog_regenerates_agents_markdown() {
        let temp = TempRoot::new();
        let paths = temp.paths();

        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                Vec::new(),
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let skill_dir = paths.skills_installed.join("planner");
        fs::create_dir_all(skill_dir.join("agents")).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            concat!(
                "---\n",
                "name: planner\n",
                "description: Planner skill\n",
                "agents:\n",
                "  - agents/researcher.md\n",
                "---\n\n",
                "Plan work.\n"
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
                "Research carefully.\n"
            ),
        )
        .unwrap();

        kernel
            .refresh_skill_catalog()
            .expect("skill catalog refresh should succeed");

        let rendered = fs::read_to_string(&paths.agents_notes).expect("AGENTS.md should exist");
        assert!(rendered.contains("## planner/researcher"));
    }

    #[test]
    fn refresh_agents_markdown_writes_catalog_without_kernel_boot() {
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

        let rendered = refresh_agents_markdown(&paths).expect("catalog should refresh");
        assert!(rendered.contains("## allbert/root"));
        assert!(paths.agents_notes.exists());
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
        let skill_dir = paths.skills_installed.join("planner");
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
    async fn run_job_turn_stages_entries_with_job_source_attribution() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"Nightly summary content\",\"kind\":\"job_summary\",\"summary\":\"Nightly summary\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "JOB_OK".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_job_turn("nightly-summary", "collect findings")
            .await
            .expect("job turn should pass");

        let staged =
            memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
                .expect("staged entries should list");
        assert_eq!(staged.len(), 1);
        assert_eq!(staged[0].kind, "job_summary");
        assert_eq!(staged[0].source, "job");
        assert_eq!(staged[0].agent, "allbert/root");
    }

    #[tokio::test]
    async fn stage_memory_surfaces_turn_end_hint() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"We use Postgres\",\"kind\":\"learned_fact\",\"summary\":\"We use Postgres\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Captured that.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("remember that we use Postgres")
            .await
            .expect("turn should pass");

        let staged =
            memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
                .expect("staged entries should list");
        assert_eq!(staged.len(), 1);

        let events = events.lock().unwrap();
        let text = events
            .iter()
            .find_map(|event| match event {
                KernelEvent::AssistantText(text) => Some(text.clone()),
                _ => None,
            })
            .expect("assistant text should be emitted");
        assert!(text.contains("I'd like to remember 1 thing"));
        assert!(text.contains(&staged[0].id));
        assert!(text.contains(&staged[0].summary));
        assert!(text.contains("allbert-cli memory staged show"));
        assert!(text.contains("allbert-cli memory staged list"));
    }

    #[tokio::test]
    async fn staged_notice_renders_entry_summaries_for_small_batches() {
        let temp = TempRoot::new();
        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            temp.paths(),
            Arc::new(TestFactory::new("anthropic", vec![], Some(test_pricing()))),
        )
        .await
        .expect("kernel should boot for tests");
        let mut state = AgentState::new("session-a".into());
        state.staged_entries_this_turn = 2;
        state.staged_notice_entries_this_turn = vec![
            StagedNoticeEntry {
                id: "stg_alpha".into(),
                summary: "Primary database is Postgres".into(),
            },
            StagedNoticeEntry {
                id: "stg_beta".into(),
                summary: "Deploy target is Fly.io".into(),
            },
        ];

        let text = kernel.finish_turn_output(&state, "Captured that.");
        assert!(text.contains("I'd like to remember 2 things"));
        assert!(text.contains("stg_alpha"));
        assert!(text.contains("Primary database is Postgres"));
        assert!(text.contains("stg_beta"));
        assert!(text.contains("Deploy target is Fly.io"));
    }

    #[tokio::test]
    async fn staged_notice_collapses_for_large_batches() {
        let temp = TempRoot::new();
        let kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            temp.paths(),
            Arc::new(TestFactory::new("anthropic", vec![], Some(test_pricing()))),
        )
        .await
        .expect("kernel should boot for tests");
        let mut state = AgentState::new("session-b".into());
        state.staged_entries_this_turn = 4;
        state.staged_notice_entries_this_turn = vec![
            StagedNoticeEntry {
                id: "stg_one".into(),
                summary: "One".into(),
            },
            StagedNoticeEntry {
                id: "stg_two".into(),
                summary: "Two".into(),
            },
            StagedNoticeEntry {
                id: "stg_three".into(),
                summary: "Three".into(),
            },
        ];

        let text = kernel.finish_turn_output(&state, "Captured that.");
        assert!(text.contains("I'd like to remember 4 things"));
        assert!(text.contains("allbert-cli memory staged list"));
        assert!(!text.contains("stg_one"));
        assert!(!text.contains("stg_two"));
        assert!(!text.contains("stg_three"));
    }

    #[tokio::test]
    async fn memory_routing_surfaces_memory_curator_without_activating_body_for_plain_chat() {
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
                    text: "hello".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("hello there")
            .await
            .expect("turn should pass");
        let request = requests.lock().unwrap();
        let system = request[0].system.as_deref().unwrap_or_default();
        assert!(system.contains("Always-eligible skill routing:"));
        assert!(system.contains("- memory-curator:"));
        assert!(
            !system.contains("### Skill: memory-curator"),
            "plain chat should not load the full memory-curator body"
        );
    }

    #[tokio::test]
    async fn memory_routing_auto_activates_memory_curator_on_memory_query() {
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
                    text: "I can help with memory.".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("what do you remember about Postgres?")
            .await
            .expect("turn should pass");
        assert_eq!(kernel.active_skills()[0].name, "memory-curator");
        let request = requests.lock().unwrap();
        let system = request[0].system.as_deref().unwrap_or_default();
        assert!(system.contains("### Skill: memory-curator"));
    }

    #[tokio::test]
    async fn memory_routing_auto_activates_memory_curator_on_configured_chat_cue() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let requests = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.memory.routing.auto_activate_intents.clear();
        config.memory.routing.auto_activate_cues = vec!["hello there".into()];
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![CompletionResponse {
                    text: "hello".into(),
                    usage: Usage::default(),
                }],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("hello there")
            .await
            .expect("turn should pass");
        assert_eq!(kernel.active_skills()[0].name, "memory-curator");
        let request = requests.lock().unwrap();
        let system = request[0].system.as_deref().unwrap_or_default();
        assert!(system.contains("### Skill: memory-curator"));
    }

    #[tokio::test]
    async fn memory_curator_review_and_batch_promotion_require_confirmation() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let first = memory::stage_memory(
            &paths,
            &MemoryConfig::default(),
            memory::StageMemoryRequest {
                session_id: "session-a".into(),
                turn_id: "turn-1".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "We use Postgres for primary storage.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Primary database is Postgres".into(),
                tags: vec!["database".into()],
                provenance: None,
                fingerprint_basis: None,
                facts: Vec::new(),
            },
        )
        .expect("first stage should succeed");
        let second = memory::stage_memory(
            &paths,
            &MemoryConfig::default(),
            memory::StageMemoryRequest {
                session_id: "session-a".into(),
                turn_id: "turn-2".into(),
                agent: "allbert/root".into(),
                source: "channel".into(),
                content: "We deploy with Fly.io.".into(),
                kind: StagedMemoryKind::LearnedFact,
                summary: "Deploy target is Fly.io".into(),
                tags: vec!["deploy".into()],
                provenance: None,
                fingerprint_basis: None,
                facts: Vec::new(),
            },
        )
        .expect("second stage should succeed");

        let requests = Arc::new(Mutex::new(Vec::new()));
        let confirm = Arc::new(QueueConfirm::new(vec![
            ConfirmDecision::AllowOnce,
            ConfirmDecision::AllowOnce,
        ]));
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter_with(Arc::new(Mutex::new(Vec::new())), confirm.clone(), Arc::new(NoopInput)),
            paths.clone(),
            Arc::new(TestFactory::with_requests(
                "anthropic",
                requests.clone(),
                vec![
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"invoke_skill\",\"input\":{\"name\":\"memory-curator\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"list_staged_memory\",\"input\":{\"limit\":10}}</tool_call>".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{{\"name\":\"promote_staged_memory\",\"input\":{{\"id\":\"{}\"}}}}</tool_call><tool_call>{{\"name\":\"promote_staged_memory\",\"input\":{{\"id\":\"{}\"}}}}</tool_call>",
                            first.id, second.id
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "Reviewed and promoted the staged memory.".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        let summary = kernel
            .run_turn("review what's staged")
            .await
            .expect("turn should pass");
        assert!(!summary.hit_turn_limit);

        let recorded_requests = requests.lock().unwrap();
        assert!(
            recorded_requests.iter().any(|request| request
                .system
                .as_deref()
                .unwrap_or_default()
                .contains("### Skill: memory-curator")),
            "memory-curator should be available as a shipped skill"
        );

        let confirms = confirm.seen();
        let seen = confirms.lock().unwrap();
        assert_eq!(seen.len(), 2, "each promotion should require confirmation");
        assert!(seen
            .iter()
            .all(|req| req.program == "promote_staged_memory"));

        let durable_hits = memory::search_memory(
            &paths,
            &MemoryConfig::default(),
            SearchMemoryInput {
                query: "Postgres Fly.io".into(),
                tier: MemoryTier::Durable,
                limit: Some(10),
                include_superseded: false,
            },
        )
        .expect("durable search should succeed");
        assert!(
            durable_hits
                .iter()
                .any(|hit| hit.path.contains("primary-database-is-postgres"))
                || durable_hits
                    .iter()
                    .any(|hit| hit.snippet.contains("Postgres"))
        );
        assert!(
            durable_hits
                .iter()
                .any(|hit| hit.path.contains("deploy-target-is-fly-io"))
                || durable_hits
                    .iter()
                    .any(|hit| hit.snippet.contains("Fly.io"))
        );
    }

    #[tokio::test]
    async fn memory_curator_extract_from_turn_records_cost_and_stages_curator_entry() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let mut kernel = Kernel::boot_with_parts(
            Config::default_template(),
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths.clone(),
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "spawn_subagent",
                                "input": {
                                    "name": "memory-curator/extract-from-turn",
                                    "prompt": "Look at this turn and suggest durable memory candidates."
                                }
                            })
                        ),
                        usage: Usage {
                            input_tokens: 12,
                            output_tokens: 2,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"We use Postgres for primary storage.\",\"kind\":\"curator_extraction\",\"summary\":\"Primary database is Postgres\"}}</tool_call>".into(),
                        usage: Usage {
                            input_tokens: 8,
                            output_tokens: 3,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "Staged one durable memory candidate.".into(),
                        usage: Usage {
                            input_tokens: 6,
                            output_tokens: 2,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    },
                    CompletionResponse {
                        text: "Done reviewing the turn.".into(),
                        usage: Usage {
                            input_tokens: 4,
                            output_tokens: 2,
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
            .run_turn("please extract durable memory from what we just covered")
            .await
            .expect("turn should pass");

        let staged =
            memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
                .expect("staged entries should list");
        assert_eq!(staged.len(), 1);
        assert_eq!(staged[0].kind, "curator_extraction");
        assert_eq!(staged[0].source, "subagent");
        assert_eq!(staged[0].agent, "memory-curator/extract-from-turn");

        let log = std::fs::read_to_string(paths.costs).expect("cost log should exist");
        let entries = log
            .lines()
            .map(|line| serde_json::from_str::<CostEntry>(line).expect("valid cost entry"))
            .collect::<Vec<_>>();
        assert!(
            entries
                .iter()
                .any(|entry| entry.agent_name == "memory-curator/extract-from-turn"),
            "curator extraction agent should appear in session cost logs"
        );
        assert!(kernel.session_cost_usd() > 0.0);
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
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"sh\",\"args\":[\"-c\",\"echo nope\"]}}</tool_call>".into(),
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
    fn curated_turn_memory_snapshot_respects_truncation_order() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::write(
            &paths.memory_index,
            format!("# MEMORY\n\n{}\n", "memory-head ".repeat(200)),
        )
        .unwrap();
        let today = time::OffsetDateTime::now_local()
            .unwrap_or_else(|_| time::OffsetDateTime::now_utc())
            .format(&time::macros::format_description!("[year]-[month]-[day]"))
            .unwrap();
        let yesterday = (time::OffsetDateTime::now_local()
            .unwrap_or_else(|_| time::OffsetDateTime::now_utc())
            - time::Duration::days(1))
        .format(&time::macros::format_description!("[year]-[month]-[day]"))
        .unwrap();
        fs::write(
            paths.memory_daily.join(format!("{today}.md")),
            format!("# Today\n\n{}\n", "today-head ".repeat(200)),
        )
        .unwrap();
        fs::write(
            paths.memory_daily.join(format!("{yesterday}.md")),
            format!("# Yesterday\n\n{}\n", "yesterday-tail ".repeat(120)),
        )
        .unwrap();

        let mut config = MemoryConfig::default();
        config.max_synopsis_bytes = 1024;
        config.max_memory_md_head_bytes = 1024;
        config.max_daily_head_bytes = 1024;
        config.max_daily_tail_bytes = 768;
        config.max_ephemeral_summary_bytes = 128;
        config.max_prefetch_snippets = 5;
        config.max_prefetch_snippet_bytes = 256;

        let snapshot = memory::build_turn_memory_snapshot(
            &paths,
            &config,
            &"ephemeral ".repeat(20),
            Some("memory"),
            5,
        )
        .unwrap();
        let joined = snapshot.sections.join("\n\n");
        assert!(joined.contains("## Session working memory"));
        assert!(!joined.contains("## Yesterday's daily note (tail)"));
        assert!(
            snapshot
                .trimmed_sources
                .first()
                .is_some_and(|value| value == "yesterday_tail"),
            "yesterday tail should be dropped before other sources"
        );
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

    #[tokio::test]
    async fn chat_turn_without_memory_cues_skips_prefetch() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        fs::write(
            paths.memory_notes.join("rust.md"),
            "# Rust\n\nWe prefer Rust for backend work.\n",
        )
        .unwrap();
        let _ = memory::reconcile_curated_memory(&paths, &MemoryConfig::default()).unwrap();

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
                        text: "chat".into(),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "CHAT_OK".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("hello there").await.unwrap();

        let requests = requests.lock().unwrap();
        let system = requests.last().unwrap().system.as_ref().unwrap();
        assert!(!system.contains("## Retrieved memory"));
    }

    #[tokio::test]
    async fn task_turn_refreshes_memory_once_after_tool_evidence() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let workspace = paths.root.join("workspace");
        fs::create_dir_all(&workspace).unwrap();
        fs::write(
            paths.memory_notes.join("database.md"),
            "# Database\n\nWe use Postgres for production.\n",
        )
        .unwrap();
        fs::write(
            workspace.join("report.txt"),
            "Postgres is still configured.\n",
        )
        .unwrap();
        let _ = memory::reconcile_curated_memory(&paths, &MemoryConfig::default()).unwrap();

        let requests = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.security.fs_roots = vec![workspace.clone()];

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
                                "name": "read_file",
                                "input": {
                                    "path": workspace.join("report.txt").display().to_string()
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "DONE".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("check the report").await.unwrap();

        let requests = requests.lock().unwrap();
        assert_eq!(requests.len(), 2);
        let first_system = requests[0].system.as_ref().unwrap();
        let second_system = requests[1].system.as_ref().unwrap();
        assert!(!first_system.contains("We use Postgres for production."));
        assert!(second_system.contains("## Retrieved memory"));
        assert!(second_system.contains("We use Postgres for production."));
    }

    #[tokio::test]
    async fn memory_prefetch_hooks_fire_for_prefetch_and_refresh() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().unwrap();
        let workspace = paths.root.join("workspace");
        fs::create_dir_all(&workspace).unwrap();
        fs::write(
            paths.memory_notes.join("database.md"),
            "# Database\n\nWe use Postgres for production.\n",
        )
        .unwrap();
        fs::write(workspace.join("report.txt"), "Postgres evidence.\n").unwrap();
        let _ = memory::reconcile_curated_memory(&paths, &MemoryConfig::default()).unwrap();

        let seen = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.security.fs_roots = vec![workspace.clone()];
        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(Arc::new(Mutex::new(Vec::new()))),
            paths,
            Arc::new(TestFactory::new(
                "anthropic",
                vec![
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({
                                "name": "read_file",
                                "input": {
                                    "path": workspace.join("report.txt").display().to_string()
                                }
                            })
                        ),
                        usage: Usage::default(),
                    },
                    CompletionResponse {
                        text: "DONE".into(),
                        usage: Usage::default(),
                    },
                ],
                Some(test_pricing()),
            )),
        )
        .await
        .expect("kernel should boot");
        kernel.register_hook(
            HookPoint::BeforeMemoryPrefetch,
            Arc::new(MemoryRecordingHook {
                label: "before",
                seen: seen.clone(),
            }),
        );
        kernel.register_hook(
            HookPoint::AfterMemoryPrefetch,
            Arc::new(MemoryRecordingHook {
                label: "after",
                seen: seen.clone(),
            }),
        );

        kernel.run_turn("check the report").await.unwrap();

        let seen = seen.lock().unwrap().clone();
        assert_eq!(
            seen,
            vec![
                ("before".to_string(), false),
                ("after".to_string(), false),
                ("before".to_string(), true),
                ("after".to_string(), true),
            ]
        );
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
        supports_image_input: bool,
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
                supports_image_input: false,
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
                supports_image_input: false,
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
                supports_image_input: false,
            }
        }

        fn with_requests_and_image_support(
            provider_name: &'static str,
            requests: Arc<Mutex<Vec<CompletionRequest>>>,
            responses: Vec<CompletionResponse>,
            pricing: Option<Pricing>,
            supports_image_input: bool,
        ) -> Self {
            Self {
                provider_name,
                seen: Arc::new(Mutex::new(Vec::new())),
                requests,
                responses: Arc::new(Mutex::new(responses.into())),
                pricing,
                supports_image_input,
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
                supports_image_input: self.supports_image_input,
            }))
        }
    }

    struct TestProvider {
        provider_name: &'static str,
        requests: Arc<Mutex<Vec<CompletionRequest>>>,
        responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
        pricing: Option<Pricing>,
        supports_image_input: bool,
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

        fn supports_image_input(&self, _model: &str) -> bool {
            self.supports_image_input
        }
    }

    fn scripted_response(text: &str) -> CompletionResponse {
        CompletionResponse {
            text: text.into(),
            usage: Usage {
                input_tokens: 11,
                output_tokens: 7,
                cache_read: 0,
                cache_create: 0,
            },
        }
    }

    #[tokio::test]
    async fn kernel_tracing_persists_turn_chat_tool_and_finalize_spans() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths ensure");
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.trace.enabled = true;
        config.intent_classifier.enabled = false;
        config.memory.refresh_after_external_evidence = false;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(events),
            paths.clone(),
            Arc::new(TestFactory::new(
                "test",
                vec![
                    scripted_response(
                        "<tool_call>{\"name\":\"list_skills\",\"input\":{}}</tool_call>",
                    ),
                    scripted_response("done"),
                ],
                None,
            )),
        )
        .await
        .expect("kernel should boot");

        kernel
            .run_turn("use a tool")
            .await
            .expect("turn should run");
        let read = TraceReader::new(paths.clone())
            .read_session(kernel.session_id())
            .expect("trace should read");
        let names = read
            .spans
            .iter()
            .map(|span| span.name.as_str())
            .collect::<Vec<_>>();
        for expected in [
            "turn",
            "classify_intent",
            "route_skill",
            "prepare_context",
            "chat",
            "execute_tool",
            "finalize",
        ] {
            assert!(
                names.contains(&expected),
                "missing span `{expected}` from {names:?}"
            );
        }
        let tool_span = read
            .spans
            .iter()
            .find(|span| span.name == "execute_tool")
            .expect("tool span");
        assert!(tool_span.duration_ms.is_some());
        assert_eq!(
            tool_span.attributes.get("allbert.tool.name"),
            Some(&allbert_proto::AttributeValue::String("list_skills".into()))
        );
    }

    #[tokio::test]
    async fn kernel_tracing_nests_subagent_turn_under_invoke_agent() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths ensure");
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.trace.enabled = true;
        config.intent_classifier.enabled = false;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(events),
            paths.clone(),
            Arc::new(TestFactory::new(
                "test",
                vec![
                    scripted_response("<tool_call>{\"name\":\"spawn_subagent\",\"input\":{\"name\":\"helper\",\"prompt\":\"help\"}}</tool_call>"),
                    scripted_response("child done"),
                    scripted_response("parent done"),
                ],
                None,
            )),
        )
        .await
        .expect("kernel should boot");

        kernel.run_turn("delegate").await.expect("turn should run");
        let read = TraceReader::new(paths.clone())
            .read_session(kernel.session_id())
            .expect("trace should read");
        let invoke = read
            .spans
            .iter()
            .find(|span| span.name == "invoke_agent")
            .expect("invoke_agent span");
        let child_turn = read
            .spans
            .iter()
            .find(|span| span.name == "turn" && span.parent_id.as_deref() == Some(&invoke.id))
            .expect("child turn should be parented by invoke_agent");
        assert_eq!(child_turn.trace_id, invoke.trace_id);
    }

    #[tokio::test]
    async fn kernel_tracing_records_provider_error_as_chat_retry_event() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths ensure");
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut config = Config::default_template();
        config.trace.enabled = true;
        config.intent_classifier.enabled = false;

        let mut kernel = Kernel::boot_with_parts(
            config,
            test_adapter(events),
            paths.clone(),
            Arc::new(TestFactory::new("test", Vec::new(), None)),
        )
        .await
        .expect("kernel should boot");

        let err = kernel
            .run_turn("this will fail")
            .await
            .expect_err("missing scripted response should fail");
        assert!(err.to_string().contains("no scripted response left"));
        let read = TraceReader::new(paths.clone())
            .read_session(kernel.session_id())
            .expect("trace should read");
        let chat = read
            .spans
            .iter()
            .find(|span| span.name == "chat")
            .expect("chat span");
        assert!(matches!(
            chat.status,
            allbert_proto::SpanStatus::Error { .. }
        ));
        assert!(chat.events.iter().any(|event| event.name == "retry"));
    }

    fn repo_root() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../..")
            .canonicalize()
            .expect("repo root should resolve")
    }

    fn copy_dir_recursive(source: &Path, destination: &Path) {
        fs::create_dir_all(destination).expect("destination should exist");
        for entry in fs::read_dir(source)
            .expect("source directory should be readable")
            .flatten()
        {
            let path = entry.path();
            let target = destination.join(entry.file_name());
            if path.is_dir() {
                copy_dir_recursive(&path, &target);
            } else {
                fs::copy(&path, &target).expect("file should copy");
            }
        }
    }

    fn install_example_skill(paths: &AllbertPaths) {
        let source = repo_root().join("examples/skills/note-taker");
        let target_dir = paths.skills_installed.join("note-taker");
        copy_dir_recursive(&source, &target_dir);
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
        let placeholder = AgentState::new(kernel.state.session_id.clone());
        let mut state = std::mem::replace(&mut kernel.state, placeholder);
        let mut tool_hook_ctx = HookCtx::before_tool(
            &state.session_id,
            state.agent_name(),
            None,
            invocation.clone(),
            kernel.skills.allowed_tool_union(&state.active_skills),
        );
        let output = match kernel
            .hooks
            .run(HookPoint::BeforeTool, &mut tool_hook_ctx)
            .await
        {
            HookOutcome::Continue => {
                kernel
                    .dispatch_tool_for_state(&mut state, None, invocation)
                    .await
            }
            HookOutcome::Abort(message) => ToolOutput {
                content: message,
                ok: false,
            },
        };
        kernel.state = state;
        output
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

    #[tokio::test]
    async fn turn_budget_override_merges_dimensions_and_is_consumed_once() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let config = Config::default_template();

        let mut kernel = Kernel::boot_with_parts(
            config.clone(),
            test_adapter(events),
            paths,
            Arc::new(TestFactory::new("test", Vec::new(), None)),
        )
        .await
        .expect("kernel should boot");

        kernel
            .set_turn_budget_override(Some(0.12), None)
            .expect("usd override should arm");
        kernel
            .set_turn_budget_override(None, Some(9))
            .expect("time override should arm");

        let placeholder = AgentState::new(kernel.state.session_id.clone());
        let state = std::mem::replace(&mut kernel.state, placeholder);
        let overridden = kernel
            .effective_root_turn_budget(&state, false)
            .expect("override should resolve");
        assert!((overridden.usd - 0.12).abs() < f64::EPSILON);
        assert_eq!(overridden.seconds, 9);

        let default_budget = kernel
            .effective_root_turn_budget(&state, false)
            .expect("override should be consumed");
        assert!((default_budget.usd - config.limits.max_turn_usd).abs() < f64::EPSILON);
        assert_eq!(default_budget.seconds, config.limits.max_turn_s);

        kernel.state = state;
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
        config.trace.enabled = true;
        config.setup.version = 1;
        config.model.provider = start_provider;
        config.model.model_id = start_model_id.into();
        config.model.api_key_env = Some(start_api_key_env.into());
        config.model.base_url = None;
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
                api_key_env: Some(switch_api_key_env.into()),
                base_url: None,
                max_tokens: 64,
                context_window_tokens: 0,
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

    async fn run_live_ollama_release_smoke() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));
        let workspace_root = repo_root();

        let mut config = Config::default_template();
        config.trace.enabled = true;
        config.setup.version = 1;
        config.model.provider = Provider::Ollama;
        config.model.model_id = "gemma4".into();
        config.model.api_key_env = None;
        config.model.base_url = std::env::var("OLLAMA_BASE_URL")
            .ok()
            .or_else(|| Provider::Ollama.default_base_url().map(str::to_string));
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
        .expect("live Ollama kernel should boot");

        kernel
            .run_turn(
                "If the runtime context says the preferred name is Spuri, reply with exactly PROFILE_OK and nothing else.",
            )
            .await
            .expect("Ollama profile prompt should succeed");
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

        kernel
            .set_model(ModelConfig {
                provider: Provider::Ollama,
                model_id: "gemma4".into(),
                api_key_env: None,
                base_url: std::env::var("OLLAMA_BASE_URL")
                    .ok()
                    .or_else(|| Provider::Ollama.default_base_url().map(str::to_string)),
                max_tokens: 64,
                context_window_tokens: 0,
            })
            .await
            .expect("Ollama model refresh should succeed");
        kernel
            .run_turn("Reply with exactly SWITCH_OK and nothing else.")
            .await
            .expect("Ollama switched-provider prompt should succeed");
        assert_eq!(latest_assistant_text(&events).trim(), "SWITCH_OK");

        assert!(
            paths.costs.exists(),
            "cost log should exist after live Ollama turn"
        );
        assert!(trace_file_exists(&paths), "trace file should exist");
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

    #[tokio::test]
    #[ignore = "live smoke requires OPENAI_API_KEY"]
    async fn openai_release_smoke() {
        run_live_release_smoke(
            Provider::Openai,
            "gpt-5.4-mini",
            "OPENAI_API_KEY",
            Provider::Openai,
            "gpt-5.4-mini",
            "OPENAI_API_KEY",
        )
        .await;
    }

    #[tokio::test]
    #[ignore = "live smoke requires GEMINI_API_KEY"]
    async fn gemini_release_smoke() {
        run_live_release_smoke(
            Provider::Gemini,
            "gemini-2.5-flash",
            "GEMINI_API_KEY",
            Provider::Gemini,
            "gemini-2.5-flash",
            "GEMINI_API_KEY",
        )
        .await;
    }

    #[tokio::test]
    #[ignore = "live smoke requires local Ollama with gemma4"]
    async fn ollama_release_smoke() {
        run_live_ollama_release_smoke().await;
    }
}
