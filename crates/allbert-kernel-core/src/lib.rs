pub mod adapter;
pub mod agent;
pub mod atomic;
mod bootstrap;
pub mod command_catalog;
pub mod config;
pub mod cost;
pub mod error;
pub mod events;
pub mod hooks;
pub mod identity;
pub mod intent;
pub mod job_manager;
pub mod llm;
pub mod memory;
pub mod paths;
pub mod scripting;
pub mod security;
pub mod settings;
pub mod skills;
pub mod tool_call_parser;
pub mod tools;
pub mod trace;

pub use adapter::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, DynamicConfirmPrompter, FrontendAdapter,
    InputPrompter, InputRequest, InputResponse,
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
    IntentClassifierConfig, IntentRuntimeConfig, JobsConfig, LearningConfig, LimitsConfig,
    LocalUtilitiesConfig, MemoryConfig, MemoryEpisodesConfig, MemoryFactsConfig,
    MemoryRoutingConfig, MemoryRoutingMode, MemorySemanticConfig, ModelConfig, OperatorUxConfig,
    PersonalityDigestConfig, Provider, ReplConfig, ReplUiMode, ScriptingConfig,
    ScriptingEngineConfig, SecurityConfig, SelfDiagnosisConfig, SelfImprovementConfig,
    SelfImprovementInstallMode, SessionsConfig, SetupConfig, StatusLineConfig, StatusLineItem,
    TraceConfig, TraceDefaultsWriteResult, TraceFieldPolicy, TraceRedactionConfig, TuiConfig,
    TuiSpinnerStyle, WebSecurityConfig, CURRENT_SETUP_VERSION,
};
pub use cost::CostEntry;
pub use error::{
    append_error_hint, error_hint_for_message, ConfigError, KernelError, SkillError, ToolError,
};
pub use events::{ActivityTransition, KernelEvent};
pub use hooks::{
    BootstrapContextHook, CostHook, Hook, HookCtx, HookOutcome, HookPoint, MemoryIndexHook,
};
pub use identity::{
    add_identity_channel, ensure_identity_record, identity_inconsistencies, load_identity_record,
    remove_identity_channel, rename_identity, resolve_identity_id_for_sender, save_identity_record,
    IdentityChannelBinding, IdentityConsistency, IdentityRecord, LEGACY_SENTINEL_IDENTITY,
    LOCAL_REPL_SENDER,
};
pub use intent::{Intent, RouteAction, RouteConfidence, RouteDecision, RouteDecisionError};
pub use job_manager::{JobManager, ListJobRunsInput, NamedJobInput, UpsertJobInput};
pub use llm::{
    ChatAttachment, ChatAttachmentKind, ChatMessage, ChatRole, CompletionRequest,
    CompletionResponse, CompletionResponseFormat, LlmProvider, Pricing, ProviderFactory,
    ToolCallSpan, ToolDeclaration, Usage,
};
pub use memory::{
    MemoryFact, MemoryTier, ReadMemoryInput, SearchMemoryHit, SearchMemoryInput, StageMemoryInput,
    StageMemoryRequest, StagedMemoryKind, WriteMemoryInput, WriteMemoryMode,
};
pub use paths::AllbertPaths;
pub use scripting::{
    BudgetUsed, CapKind, LoadedScript, ScriptBudget, ScriptOutcome, ScriptingCapabilities,
    ScriptingEngine, ScriptingError, LUA_MAX_EXECUTION_MS_CEILING, LUA_MAX_MEMORY_KB_CEILING,
    LUA_MAX_OUTPUT_BYTES_CEILING,
};
pub use security::{exec_policy, NormalizedExec, PolicyDecision};
pub use settings::{
    find_setting, persist_setting_value, reset_setting_value, settings_catalog,
    settings_catalog_errors, settings_for_config, validate_setting_value, SettingDescriptor,
    SettingMutation, SettingPathPolicy, SettingPersistenceError, SettingRedactionPolicy,
    SettingRestartRequirement, SettingValidationError, SettingValueType, SettingView,
    SettingsGroup,
};
pub use skills::{ActiveSkill, ContributedAgent, CreateSkillInput, InvokeSkillInput};
pub use tool_call_parser::{
    corrective_retry_message, parse_and_resolve_tool_calls, parse_tool_call_blocks,
    resolve_tool_calls, ParsedToolCall, ToolParseError,
};
pub use tools::{ProcessExecInput, ToolInvocation, ToolOutput, ToolRegistry};
pub use trace::TraceHandles;
