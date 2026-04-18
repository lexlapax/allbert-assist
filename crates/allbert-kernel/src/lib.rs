pub mod adapter;
pub mod agent;
mod bootstrap;
pub mod config;
pub mod cost;
pub mod error;
pub mod events;
pub mod hooks;
pub mod llm;
pub mod memory;
pub mod paths;
pub mod security;
pub mod skills;
pub mod tools;
pub mod trace;

use std::sync::Arc;

pub use adapter::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, FrontendAdapter, InputPrompter, InputRequest,
    InputResponse,
};
pub use agent::AgentState;
pub use config::{Config, LimitsConfig, ModelConfig, Provider, SecurityConfig, WebSecurityConfig};
pub use cost::CostEntry;
pub use error::{ConfigError, KernelError, SkillError, ToolError};
pub use events::KernelEvent;
pub use hooks::{
    BootstrapContextHook, CostHook, Hook, HookCtx, HookOutcome, HookPoint, MemoryIndexHook,
};
pub use llm::{ChatMessage, ChatRole};
pub use paths::AllbertPaths;
pub use security::SecurityHook;
pub use skills::{ActiveSkill, Skill, SkillStore};
pub use tools::{ToolCtx, ToolInvocation, ToolOutput, ToolRegistry};
pub use trace::TraceHandles;

use hooks::HookRegistry;
use llm::{CompletionRequest, DefaultProviderFactory, LlmProvider, ProviderFactory};

pub struct TurnSummary {
    pub hit_turn_limit: bool,
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

    async fn boot_with_parts(
        config: Config,
        adapter: FrontendAdapter,
        paths: AllbertPaths,
        provider_factory: Arc<dyn ProviderFactory>,
    ) -> Result<Self, KernelError> {
        paths.ensure()?;

        let session_id = uuid::Uuid::new_v4().to_string();
        let trace = trace::init_tracing(config.trace, &paths, &session_id)?;
        let llm = provider_factory.build(&config.model).await?;
        let mut hooks = HookRegistry::default();
        hooks.register(
            HookPoint::BeforeTool,
            Arc::new(SecurityHook::new(
                config.security.clone(),
                paths.clone(),
                adapter.confirm.clone(),
            )),
        );
        hooks.register(HookPoint::BeforePrompt, Arc::new(BootstrapContextHook));
        hooks.register(HookPoint::BeforePrompt, Arc::new(MemoryIndexHook));
        hooks.register(HookPoint::OnModelResponse, Arc::new(CostHook));

        tracing::info!(session = %session_id, "kernel boot");

        Ok(Self {
            config,
            paths,
            adapter,
            hooks,
            skills: SkillStore::new(),
            state: AgentState::new(session_id),
            provider_factory,
            llm,
            tools: ToolRegistry::builtins(),
            trace,
        })
    }

    pub async fn run_turn(&mut self, user_input: &str) -> Result<TurnSummary, KernelError> {
        self.state.turn_count = self.state.turn_count.saturating_add(1);
        self.state.messages.push(ChatMessage {
            role: ChatRole::User,
            content: user_input.into(),
        });

        let mut tool_calls_used = 0usize;
        let mut tool_output_total = 0usize;

        for _round in 0..self.config.limits.max_turns {
            let mut prompt_ctx =
                HookCtx::before_prompt(&self.state.session_id, &self.paths, &self.config.limits);
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
                    system: Some(self.system_prompt(&prompt_ctx.prompt_sections)),
                    messages: self.state.messages.clone(),
                    model: self.config.model.model_id.clone(),
                    max_tokens: self.config.model.max_tokens,
                })
                .await?;

            let mut hook_ctx = HookCtx::on_model_response(
                &self.state.session_id,
                self.llm.provider_name(),
                &self.config.model.model_id,
                response.usage.clone(),
                self.llm.pricing(&self.config.model.model_id),
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
                self.state.cost_total_usd += entry.usd_estimate;
            }

            self.state.messages.push(ChatMessage {
                role: ChatRole::Assistant,
                content: response.text.clone(),
            });

            for event in hook_ctx.pending_events {
                (self.adapter.on_event)(&event);
            }

            let tool_calls = parse_tool_calls(&response.text);
            if tool_calls.is_empty() {
                (self.adapter.on_event)(&KernelEvent::AssistantText(response.text));
                (self.adapter.on_event)(&KernelEvent::TurnDone {
                    hit_turn_limit: false,
                });
                return Ok(TurnSummary {
                    hit_turn_limit: false,
                });
            }

            for invocation in tool_calls {
                if tool_calls_used >= self.config.limits.max_tool_calls_per_turn as usize {
                    let content = "tool call budget exhausted".to_string();
                    self.state.messages.push(ChatMessage {
                        role: ChatRole::User,
                        content: format!("Tool result for limit (ok=false):\n{content}"),
                    });
                    (self.adapter.on_event)(&KernelEvent::ToolResult {
                        name: "tool_budget".into(),
                        ok: false,
                        content,
                    });
                    (self.adapter.on_event)(&KernelEvent::TurnDone {
                        hit_turn_limit: true,
                    });
                    return Ok(TurnSummary {
                        hit_turn_limit: true,
                    });
                }

                tool_calls_used += 1;
                (self.adapter.on_event)(&KernelEvent::ToolCall {
                    name: invocation.name.clone(),
                    input: invocation.input.clone(),
                });

                let mut tool_hook_ctx =
                    HookCtx::before_tool(&self.state.session_id, invocation.clone());
                let tool_output = match self
                    .hooks
                    .run(HookPoint::BeforeTool, &mut tool_hook_ctx)
                    .await
                {
                    HookOutcome::Continue => {
                        let ctx = ToolCtx {
                            input: self.adapter.input.clone(),
                            security: self.config.security.clone(),
                            web_client: reqwest::Client::new(),
                        };
                        match self.tools.dispatch(invocation.clone(), &ctx).await {
                            Ok(output) => output,
                            Err(err) => ToolOutput {
                                content: err.to_string(),
                                ok: false,
                            },
                        }
                    }
                    HookOutcome::Abort(message) => ToolOutput {
                        content: message,
                        ok: false,
                    },
                };

                let remaining = self
                    .config
                    .limits
                    .max_tool_output_bytes_total
                    .saturating_sub(tool_output_total);
                if remaining == 0 {
                    (self.adapter.on_event)(&KernelEvent::TurnDone {
                        hit_turn_limit: true,
                    });
                    return Ok(TurnSummary {
                        hit_turn_limit: true,
                    });
                }

                let per_call_limit = self
                    .config
                    .limits
                    .max_tool_output_bytes_per_call
                    .min(remaining);
                let content = truncate_to_bytes(&tool_output.content, per_call_limit);
                tool_output_total += content.as_bytes().len();

                (self.adapter.on_event)(&KernelEvent::ToolResult {
                    name: invocation.name.clone(),
                    ok: tool_output.ok,
                    content: content.clone(),
                });

                self.state.messages.push(ChatMessage {
                    role: ChatRole::User,
                    content: format!(
                        "Tool result for {} (ok={}):\n{}",
                        invocation.name, tool_output.ok, content
                    ),
                });
            }
        }

        (self.adapter.on_event)(&KernelEvent::TurnDone {
            hit_turn_limit: true,
        });
        Ok(TurnSummary {
            hit_turn_limit: true,
        })
    }

    pub fn register_hook(&mut self, point: HookPoint, hook: Arc<dyn Hook>) {
        self.hooks.register(point, hook);
    }

    pub fn list_skills(&self) -> &[Skill] {
        self.skills.all()
    }

    pub fn active_skills(&self) -> &[ActiveSkill] {
        &self.state.active_skills
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

    pub fn today_cost_usd(&self) -> Result<f64, KernelError> {
        cost::sum_costs_for_today(&self.paths.costs)
    }

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn paths(&self) -> &AllbertPaths {
        &self.paths
    }

    fn system_prompt(&self, prompt_sections: &[String]) -> String {
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

        prompt.push_str(&self.tools.prompt_catalog());

        for section in prompt_sections {
            prompt.push_str("\n\n");
            prompt.push_str(section);
        }

        prompt
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
}
