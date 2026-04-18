pub mod adapter;
pub mod agent;
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
pub use hooks::{CostHook, Hook, HookCtx, HookOutcome, HookPoint, MemoryIndexHook, SecurityHook};
pub use llm::{ChatMessage, ChatRole};
pub use paths::AllbertPaths;
pub use skills::{ActiveSkill, Skill, SkillStore};
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
        hooks.register(HookPoint::BeforePrompt, Arc::new(MemoryIndexHook));
        hooks.register(HookPoint::OnModelResponse, Arc::new(CostHook));
        hooks.register(HookPoint::BeforeTool, Arc::new(SecurityHook));

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
            trace,
        })
    }

    pub async fn run_turn(&mut self, user_input: &str) -> Result<TurnSummary, KernelError> {
        self.state.turn_count = self.state.turn_count.saturating_add(1);
        self.state.messages.push(ChatMessage {
            role: ChatRole::User,
            content: user_input.into(),
        });

        let response = self
            .llm
            .complete(CompletionRequest {
                system: Some(self.system_prompt()),
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

        (self.adapter.on_event)(&KernelEvent::AssistantText(response.text));
        (self.adapter.on_event)(&KernelEvent::TurnDone {
            hit_turn_limit: false,
        });
        Ok(TurnSummary {
            hit_turn_limit: false,
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

    fn system_prompt(&self) -> String {
        "You are Allbert, a local personal assistant running inside a Rust kernel. Answer helpfully and concisely. Tools are not available in this milestone.".into()
    }
}

#[cfg(test)]
mod tests {
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;

    use super::*;
    use crate::error::LlmError;
    use crate::llm::{CompletionResponse, Pricing, Usage};

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
        FrontendAdapter {
            on_event: Box::new(move |event| {
                events.lock().unwrap().push(event.clone());
            }),
            confirm: Arc::new(NoopConfirm),
            input: Arc::new(NoopInput),
        }
    }

    #[test]
    fn load_or_create_writes_default_config() {
        let temp = TempRoot::new();
        let paths = temp.paths();

        let config = Config::load_or_create(&paths).expect("default config should be created");

        assert!(paths.config.exists(), "config file should exist");
        assert_eq!(config.model.provider, Provider::Anthropic);
        assert_eq!(config.model.api_key_env, "ANTHROPIC_API_KEY");
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
                responses: Arc::clone(&self.responses),
                pricing: self.pricing,
            }))
        }
    }

    struct TestProvider {
        provider_name: &'static str,
        responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
        pricing: Option<Pricing>,
    }

    #[async_trait]
    impl LlmProvider for TestProvider {
        async fn complete(&self, _req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
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
