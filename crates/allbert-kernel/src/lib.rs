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
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, FrontendAdapter, InputPrompter,
    InputRequest, InputResponse,
};
pub use agent::AgentState;
pub use config::{Config, LimitsConfig, ModelConfig, Provider, SecurityConfig, WebSecurityConfig};
pub use cost::CostEntry;
pub use error::{ConfigError, KernelError, SkillError, ToolError};
pub use events::KernelEvent;
pub use hooks::{Hook, HookCtx, HookOutcome, HookPoint};
pub use paths::AllbertPaths;
pub use skills::{ActiveSkill, Skill, SkillStore};
pub use trace::TraceHandles;

use hooks::HookRegistry;

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
    #[allow(dead_code)]
    trace: TraceHandles,
}

impl Kernel {
    pub async fn boot(
        config: Config,
        adapter: FrontendAdapter,
    ) -> Result<Self, KernelError> {
        let paths = AllbertPaths::from_home()?;
        Self::boot_with_paths(config, adapter, paths).await
    }

    async fn boot_with_paths(
        config: Config,
        adapter: FrontendAdapter,
        paths: AllbertPaths,
    ) -> Result<Self, KernelError> {
        paths.ensure()?;

        let session_id = uuid::Uuid::new_v4().to_string();
        let trace = trace::init_tracing(config.trace, &paths, &session_id)?;

        tracing::info!(session = %session_id, "kernel boot");

        Ok(Self {
            config,
            paths,
            adapter,
            hooks: HookRegistry::default(),
            skills: SkillStore::new(),
            state: AgentState::new(session_id),
            trace,
        })
    }

    pub async fn run_turn(&mut self, user_input: &str) -> Result<TurnSummary, KernelError> {
        self.state.turn_count = self.state.turn_count.saturating_add(1);
        // M1 stub: echo the user's input back through the event stream.
        let echo = format!("echo: {user_input}");
        (self.adapter.on_event)(&KernelEvent::AssistantText(echo));
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

    pub fn config(&self) -> &Config {
        &self.config
    }

    pub fn paths(&self) -> &AllbertPaths {
        &self.paths
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;

    use super::*;

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

        let kernel = Kernel::boot_with_paths(
            Config::default_template(),
            test_adapter(events),
            paths.clone(),
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
    async fn run_turn_emits_stub_events() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let events = Arc::new(Mutex::new(Vec::new()));

        let mut kernel = Kernel::boot_with_paths(
            Config::default_template(),
            test_adapter(Arc::clone(&events)),
            paths,
        )
        .await
        .expect("kernel should boot");

        let summary = kernel.run_turn("hello").await.expect("turn should succeed");
        let recorded = events.lock().unwrap();

        assert!(!summary.hit_turn_limit);
        assert_eq!(recorded.len(), 2, "stub turn should emit two events");

        match &recorded[0] {
            KernelEvent::AssistantText(text) => assert_eq!(text, "echo: hello"),
            other => panic!("expected AssistantText, got {other:?}"),
        }

        match &recorded[1] {
            KernelEvent::TurnDone { hit_turn_limit } => assert!(!hit_turn_limit),
            other => panic!("expected TurnDone, got {other:?}"),
        }
    }
}
