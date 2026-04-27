use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use async_trait::async_trait;
use serde_json::json;

use super::*;
use crate::error::LlmError;
use crate::llm::{CompletionRequest, CompletionResponse, CompletionResponseFormat, Pricing, Usage};
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
    assert!(config.intent.tool_call_retry_enabled);
    assert_eq!(config.self_diagnosis.remediation_provider_max_tokens, 4096);
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
                tool_calls: Vec::new(),
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
            KernelEvent::Cost(entry) if entry.agent_name == "allbert/root" => Some(entry),
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
    assert!(recorded
        .iter()
        .any(|event| matches!(event, KernelEvent::TurnDone { hit_turn_limit } if !hit_turn_limit)));

    let log = std::fs::read_to_string(kernel.paths().costs.clone()).expect("cost log should exist");
    assert_eq!(
        log.lines()
            .filter(|line| line.contains(r#""agent_name":"allbert/root""#))
            .count(),
        1
    );
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
                tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "SUBAGENT_OK".into(),
                    usage: Usage {
                        input_tokens: 5,
                        output_tokens: 2,
                        cache_read: 0,
                        cache_create: 0,
                    },
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_OK".into(),
                    usage: Usage {
                        input_tokens: 7,
                        output_tokens: 1,
                        cache_read: 0,
                        cache_create: 0,
                    },
                    tool_calls: Vec::new(),
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
        .filter(|entry| entry.usd_estimate > 0.0)
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "SUBAGENT_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "SUBAGENT_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "NESTED_DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "SUBAGENT_DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "SUBAGENT_POLICY_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "ROOT_POLICY_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
async fn intent_rule_only_uses_legacy_schedule_rules_without_router_call() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut config = Config::default_template();
    config.intent_classifier.rule_only = true;

    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(Arc::new(Mutex::new(Vec::new()))),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            requests.clone(),
            vec![CompletionResponse {
                text: "SCHEDULE_OK".into(),
                usage: Usage::default(),
                tool_calls: Vec::new(),
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
        "legacy rule-only mode should avoid a router sub-call"
    );
    let system = requests[0]
        .system
        .as_ref()
        .expect("system prompt should exist");
    assert!(system.contains("Resolved intent: schedule"));
    assert!(system.contains("use daemon-backed job management"));
    assert!(system.contains("Preferred tool order: list_jobs, get_job, upsert_job"));
}

#[tokio::test]
async fn intent_router_uses_schema_request_and_records_costs() {
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
                    text: json!({
                        "intent": "chat",
                        "action": "none",
                        "confidence": "high",
                        "needs_clarification": false,
                        "clarifying_question": null,
                        "job_name": null,
                        "job_description": null,
                        "job_schedule": null,
                        "job_prompt": null,
                        "memory_summary": null,
                        "memory_content": null,
                        "reason": "Ambiguous small-talk style input."
                    })
                    .to_string(),
                    usage: Usage {
                        input_tokens: 2,
                        output_tokens: 1,
                        cache_read: 0,
                        cache_create: 0,
                    },
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "CHAT_OK".into(),
                    usage: Usage {
                        input_tokens: 3,
                        output_tokens: 1,
                        cache_read: 0,
                        cache_create: 0,
                    },
                    tool_calls: Vec::new(),
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
        "default routing should use a router sub-call"
    );
    assert!(
        matches!(
            &requests[0].response_format,
            CompletionResponseFormat::JsonSchema { name, strict: true, .. } if name == "route_decision"
        ),
        "first request should be the schema-bound router sub-call"
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
        log.contains("\"agent_name\":\"intent-router\""),
        "router call should be attributed separately in cost logs"
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
                tool_calls: Vec::new(),
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
            "Preferred tool order: read_file, search_rag, process_exec, request_input, spawn_subagent"
        ),
        "task intent should surface its preferred tool ordering"
    );
}

#[tokio::test]
async fn router_memory_action_stages_without_full_assistant_call() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let events = Arc::new(Mutex::new(Vec::new()));

    let mut kernel = Kernel::boot_with_parts(
        Config::default_template(),
        test_adapter(Arc::clone(&events)),
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            "anthropic",
            requests.clone(),
            vec![CompletionResponse {
                text: json!({
                    "intent": "memory_query",
                    "action": "memory_stage_explicit",
                    "confidence": "high",
                    "needs_clarification": false,
                    "clarifying_question": null,
                    "job_name": null,
                    "job_description": null,
                    "job_schedule": null,
                    "job_prompt": null,
                    "memory_summary": "Operator tests use temp profiles",
                    "memory_content": "Allbert operator tests use temporary ALLBERT_HOME profiles.",
                    "reason": "The user explicitly asked Allbert to remember a fact."
                })
                .to_string(),
                usage: Usage::default(),
                tool_calls: Vec::new(),
            }],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel
        .run_turn("remember that Allbert operator tests use temporary ALLBERT_HOME profiles")
        .await
        .expect("turn should succeed");

    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 1, "router action should be terminal");
    assert!(matches!(
        &requests[0].response_format,
        CompletionResponseFormat::JsonSchema { name, .. } if name == "route_decision"
    ));
    let staged = memory::list_staged_memory(
        &paths,
        &Config::default_template().memory,
        Some("explicit_request"),
        None,
        None,
    )
    .expect("staged memory should list");
    assert_eq!(staged.len(), 1);
    assert_eq!(staged[0].summary, "Operator tests use temp profiles");
    assert!(staged[0].body.contains("temporary ALLBERT_HOME profiles"));
    assert!(events.lock().unwrap().iter().any(|event| matches!(
        event,
        KernelEvent::AssistantText(text) if text.contains("I'd like to remember 1 thing")
    )));
}

#[tokio::test]
async fn router_explicit_memory_flow_remains_review_first() {
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
                    text: json!({
                        "intent": "memory_query",
                        "action": "memory_stage_explicit",
                        "confidence": "high",
                        "needs_clarification": false,
                        "clarifying_question": null,
                        "job_name": null,
                        "job_description": null,
                        "job_schedule": null,
                        "job_prompt": null,
                        "memory_summary": "Release smokes use temp profiles",
                        "memory_content": "Allbert release smokes use temporary ALLBERT_HOME profiles.",
                        "reason": "The user explicitly asked Allbert to remember a fact."
                    })
                    .to_string(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                scripted_response(
                    r#"<tool_call>{"name":"list_staged_memory","input":{"limit":10}}</tool_call>"#,
                ),
                scripted_response("Reviewed the staged memory."),
            ],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel
        .run_turn("please remember release smokes use temp profiles")
        .await
        .expect("memory stage should succeed");
    let staged = memory::list_staged_memory(
        &paths,
        &Config::default_template().memory,
        Some("explicit_request"),
        None,
        None,
    )
    .expect("staged memory should list");
    assert_eq!(staged.len(), 1);
    let staged_id = staged[0].id.clone();

    let durable_before = memory::search_memory(
        &paths,
        &Config::default_template().memory,
        SearchMemoryInput {
            query: "temporary ALLBERT_HOME profiles".into(),
            tier: MemoryTier::Durable,
            limit: Some(10),
            include_superseded: false,
        },
    )
    .expect("durable search should run");
    assert!(durable_before.is_empty());

    kernel
        .run_turn("review what's staged")
        .await
        .expect("review should succeed");
    assert!(events.lock().unwrap().iter().any(|event| matches!(
        event,
        KernelEvent::ToolResult { name, ok: true, content }
            if name == "list_staged_memory" && content.contains("Release smokes use temp profiles")
    )));

    let preview = memory::preview_promote_staged_memory(
        &paths,
        &Config::default_template().memory,
        &staged_id,
        None,
        None,
    )
    .expect("promotion preview should succeed");
    memory::promote_staged_memory(&paths, &Config::default_template().memory, &preview)
        .expect("promotion should succeed");
    let durable_after = memory::search_memory(
        &paths,
        &Config::default_template().memory,
        SearchMemoryInput {
            query: "temporary ALLBERT_HOME profiles".into(),
            tier: MemoryTier::Durable,
            limit: Some(10),
            include_superseded: false,
        },
    )
    .expect("durable search should run after promotion");
    assert!(!durable_after.is_empty());

    let reject_candidate = memory::stage_memory(
        &paths,
        &Config::default_template().memory,
        memory::StageMemoryRequest {
            session_id: "session-reject".into(),
            turn_id: "turn-1".into(),
            agent: "allbert/root".into(),
            source: "channel".into(),
            content: "Rejectable staged router memory.".into(),
            kind: StagedMemoryKind::ExplicitRequest,
            summary: "Rejectable router memory".into(),
            tags: Vec::new(),
            provenance: None,
            fingerprint_basis: None,
            facts: Vec::new(),
        },
    )
    .expect("reject candidate should stage");
    memory::reject_staged_memory(
        &paths,
        &Config::default_template().memory,
        &reject_candidate.id,
        Some("test rejection"),
    )
    .expect("reject should succeed");
    let remaining =
        memory::list_staged_memory(&paths, &Config::default_template().memory, None, None, None)
            .expect("remaining staged should list");
    assert!(remaining
        .iter()
        .all(|entry| entry.id != reject_candidate.id));

    let mut story_kernel = Kernel::boot_with_parts(
        Config::default_template(),
        test_adapter(Arc::new(Mutex::new(Vec::new()))),
        paths.clone(),
        Arc::new(TestFactory::new(
            "anthropic",
            vec![scripted_response("That sounds like a vivid memory.")],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("story kernel should boot");
    story_kernel
        .run_turn("I remember when daily notes were chaotic")
        .await
        .expect("story turn should succeed");
    let after_story =
        memory::list_staged_memory(&paths, &Config::default_template().memory, None, None, None)
            .expect("staged should list after story");
    assert!(after_story.is_empty());
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
                tool_calls: Vec::new(),
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
    assert!(system
        .contains("Preferred tool order: search_rag, request_input, read_memory, search_memory"));
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
                tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "second".into(),
                    usage: Usage {
                        input_tokens: 10,
                        output_tokens: 5,
                        cache_read: 0,
                        cache_create: 0,
                    },
                    tool_calls: Vec::new(),
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
    assert_eq!(
        log.lines()
            .map(|line| serde_json::from_str::<CostEntry>(line).expect("valid cost entry"))
            .filter(|entry| entry.usd_estimate > 0.0)
            .count(),
        2
    );
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "second".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Thanks, I noted blue.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
    assert!(recorded.iter().any(
        |event| matches!(event, KernelEvent::AssistantText(text) if text == "Thanks, I noted blue.")
    ));
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "No extra input arrived.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"two\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done one".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{}</tool_call>",
                            json!({"name":"process_exec","input":{"program":"/bin/echo","args":["hello"]}})
                        ),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done two".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Skill is active now.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Using the active skill.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Using the skill body only.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
    assert!(
        second_turn_system.contains("When needed, consult references/guide.md before answering.")
    );
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: concat!(
                            "<tool_call>{\"name\":\"read_reference\",\"input\":{\"skill\":\"research-assistant\",\"path\":\"references/guide.md\"}}</tool_call>",
                            "<tool_call>{\"name\":\"read_reference\",\"input\":{\"skill\":\"research-assistant\",\"path\":\"references/guide.md\"}}</tool_call>"
                        )
                        .into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done with the reference.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"script-runner\",\"script\":\"helper\",\"args\":[\"alpha\",\"beta\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"node-runner\",\"script\":\"helper\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"args\":[\"alpha\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"input\":{\"name\":\"Allbert\"}}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Activated.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"run_skill_script\",\"input\":{\"skill\":\"lua-runner\",\"script\":\"helper\",\"budget\":{\"max_execution_ms\":30001,\"max_memory_kb\":1024,\"max_output_bytes\":4096}}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "created".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
        fs::read_to_string(paths.skills_incoming.join("weather-note").join("SKILL.md")).unwrap();
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "done".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
        fs::read_to_string(paths.skills_incoming.join("overwrite-me").join("SKILL.md")).unwrap();
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "done".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "done".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Skill name?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Description?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Capability summary?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Interpreter?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Allowed tools?\",\"allow_empty\":false}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Draft is ready for install preview.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"blocked\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "SUBAGENT_DONE".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "ROOT_DONE".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "JOB_OK".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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

    let staged = memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Captured that.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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

    let staged = memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
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
                tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"list_staged_memory\",\"input\":{\"limit\":10}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: format!(
                            "<tool_call>{{\"name\":\"promote_staged_memory\",\"input\":{{\"id\":\"{}\"}}}}</tool_call><tool_call>{{\"name\":\"promote_staged_memory\",\"input\":{{\"id\":\"{}\"}}}}</tool_call>",
                            first.id, second.id
                        ),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Reviewed and promoted the staged memory.".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"We use Postgres for primary storage.\",\"kind\":\"curator_extraction\",\"summary\":\"Primary database is Postgres\"}}</tool_call>".into(),
                        usage: Usage {
                            input_tokens: 8,
                            output_tokens: 3,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Staged one durable memory candidate.".into(),
                        usage: Usage {
                            input_tokens: 6,
                            output_tokens: 2,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "Done reviewing the turn.".into(),
                        usage: Usage {
                            input_tokens: 4,
                            output_tokens: 2,
                            cache_read: 0,
                            cache_create: 0,
                        },
                    tool_calls: Vec::new(),
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

    let staged = memory::list_staged_memory(&paths, &MemoryConfig::default(), None, None, Some(10))
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"still allowed?\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"blocked\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"sh\",\"args\":[\"-c\",\"echo nope\"]}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "<tool_call>{\"name\":\"write_file\",\"input\":{\"path\":\"/tmp/outside.txt\",\"content\":\"oops\"}}</tool_call>".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
                    },
                    CompletionResponse {
                        text: "done".into(),
                        usage: Usage::default(),
                    tool_calls: Vec::new(),
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
                tool_calls: Vec::new(),
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "CHAT_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
    config.rag.enabled = false;
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
    config.rag.enabled = false;
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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

#[tokio::test]
async fn rag_owned_memory_suppresses_tantivy_prefetch_snippets() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    fs::write(
        paths.memory_notes.join("database.md"),
        "# Database\n\nWe use Postgres for production.\n",
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
            vec![CompletionResponse {
                text: "RAG-owned memory path.".into(),
                usage: Usage::default(),
                tool_calls: Vec::new(),
            }],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel
        .run_turn("what do you remember about production?")
        .await
        .unwrap();

    let requests = requests.lock().unwrap();
    let system = requests.last().unwrap().system.as_ref().unwrap();
    assert!(!system.contains("## Retrieved memory"));
    assert!(!system.contains("We use Postgres for production."));
}

#[tokio::test]
async fn router_prompt_gets_tiny_lexical_rag_hint() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    let config = Config::default_template();
    rebuild_rag_index(
        &paths,
        &config,
        RagRebuildRequest {
            stale_only: false,
            sources: vec![
                RagSourceKind::SettingsCatalog,
                RagSourceKind::CommandCatalog,
                RagSourceKind::SkillsMetadata,
            ],
            include_vectors: false,
            trigger: "test".into(),
        },
    )
    .unwrap();

    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(Arc::new(Mutex::new(Vec::new()))),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            requests.clone(),
            vec![
                CompletionResponse {
                    text: json!({
                        "intent": "meta",
                        "action": "none",
                        "confidence": "high",
                        "needs_clarification": false,
                        "clarifying_question": null,
                        "job_name": null,
                        "job_description": null,
                        "job_schedule": null,
                        "job_prompt": null,
                        "memory_summary": null,
                        "memory_content": null,
                        "reason": "Settings help request."
                    })
                    .to_string(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "META_OK".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
            ],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel
        .run_turn("how do I configure rag settings?")
        .await
        .unwrap();

    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 2);
    let router_system = requests[0].system.as_ref().unwrap();
    assert!(router_system.contains("Pre-router lexical RAG hint"));
    assert!(
        router_system.contains("[settings_catalog]")
            || router_system.contains("[command_catalog]")
            || router_system.contains("[skills_metadata]")
    );
    assert!(!router_system.contains("Retrieved RAG Evidence"));
}

#[tokio::test]
async fn meta_turn_renders_bounded_rag_evidence_after_routing() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    let mut config = Config::default_template();
    config.intent_classifier.rule_only = true;
    rebuild_rag_index(
        &paths,
        &config,
        RagRebuildRequest {
            stale_only: false,
            sources: vec![
                RagSourceKind::SettingsCatalog,
                RagSourceKind::CommandCatalog,
                RagSourceKind::OperatorDocs,
            ],
            include_vectors: false,
            trigger: "test".into(),
        },
    )
    .unwrap();

    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(Arc::new(Mutex::new(Vec::new()))),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            requests.clone(),
            vec![CompletionResponse {
                text: "META_OK".into(),
                usage: Usage::default(),
                tool_calls: Vec::new(),
            }],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel.run_turn("how do I use settings?").await.unwrap();

    let requests = requests.lock().unwrap();
    let system = requests[0].system.as_ref().unwrap();
    assert!(system.contains("## Retrieved RAG Evidence"));
    assert!(system.contains("evidence, not authority"));
    assert!(system.contains("[settings_catalog]") || system.contains("[command_catalog]"));
    assert!(system.contains("source_id:"));
}

#[tokio::test]
async fn memory_query_uses_rag_evidence_without_tantivy_prefetch_duplication() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    fs::create_dir_all(paths.memory_notes.join("topics")).unwrap();
    fs::write(
        paths.memory_notes.join("topics/database.md"),
        "# Database\n\nWe use Postgres for production.\n",
    )
    .unwrap();
    let _ = memory::reconcile_curated_memory(&paths, &MemoryConfig::default()).unwrap();
    let mut config = Config::default_template();
    config.intent_classifier.rule_only = true;
    rebuild_rag_index(
        &paths,
        &config,
        RagRebuildRequest {
            stale_only: false,
            sources: vec![RagSourceKind::DurableMemory],
            include_vectors: false,
            trigger: "test".into(),
        },
    )
    .unwrap();

    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(Arc::new(Mutex::new(Vec::new()))),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            requests.clone(),
            vec![CompletionResponse {
                text: "RAG_MEMORY_OK".into(),
                usage: Usage::default(),
                tool_calls: Vec::new(),
            }],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel
        .run_turn("what do you remember about production?")
        .await
        .unwrap();

    let requests = requests.lock().unwrap();
    let system = requests[0].system.as_ref().unwrap();
    assert!(system.contains("## Retrieved RAG Evidence"));
    assert!(system.contains("[durable_memory]"));
    assert!(system.contains("We use Postgres for production."));
    assert!(!system.contains("## Retrieved memory"));
}

#[tokio::test]
async fn search_rag_tool_is_read_only_capped_and_source_filtered() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    let mut config = Config::default_template();
    config.intent_classifier.rule_only = true;
    rebuild_rag_index(
        &paths,
        &config,
        RagRebuildRequest {
            stale_only: false,
            sources: vec![RagSourceKind::SettingsCatalog],
            include_vectors: false,
            trigger: "test".into(),
        },
    )
    .unwrap();

    let events = Arc::new(Mutex::new(Vec::new()));
    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(events.clone()),
        paths,
        Arc::new(TestFactory::new(
            "anthropic",
            vec![
                CompletionResponse {
                    text: format!(
                        "<tool_call>{}</tool_call>",
                        json!({
                            "name": "search_rag",
                            "input": {
                                "query": "rag vector enabled",
                                "sources": ["settings_catalog"],
                                "mode": "lexical",
                                "limit": 2
                            }
                        })
                    ),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
                },
            ],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    kernel.run_turn("how do I configure rag?").await.unwrap();

    let events = events.lock().unwrap();
    let content = events
        .iter()
        .find_map(|event| match event {
            KernelEvent::ToolResult { name, ok, content } if name == "search_rag" => {
                assert!(*ok);
                Some(content.clone())
            }
            _ => None,
        })
        .expect("search_rag tool result should be emitted");
    assert!(content.contains("\"source_kind\": \"settings_catalog\""));
    assert!(content.contains("rag.vector"));
}

#[tokio::test]
async fn search_rag_tool_blocks_review_only_sources_outside_review_intent() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
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

    let output = kernel.dispatch_search_rag(
        &kernel.state,
        json!({
            "query": "staged memory review",
            "sources": ["staged_memory_review"],
            "include_review_only": true
        }),
    );

    assert!(!output.ok);
    assert!(output.content.contains("review-only"));
}

#[tokio::test]
async fn tool_evidence_triggers_one_capped_rag_refresh() {
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
        "We use Postgres in the report.\n",
    )
    .unwrap();
    let mut config = Config::default_template();
    config.intent_classifier.rule_only = true;
    config.security.fs_roots = vec![workspace.clone()];
    rebuild_rag_index(
        &paths,
        &config,
        RagRebuildRequest {
            stale_only: false,
            sources: vec![RagSourceKind::DurableMemory],
            include_vectors: false,
            trigger: "test".into(),
        },
    )
    .unwrap();

    let requests = Arc::new(Mutex::new(Vec::new()));
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
                    tool_calls: Vec::new(),
                },
                CompletionResponse {
                    text: "DONE".into(),
                    usage: Usage::default(),
                    tool_calls: Vec::new(),
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
    assert!(!first_system.contains("## Retrieved RAG Evidence"));
    assert!(second_system.contains("## Retrieved RAG Evidence"));
    assert!(second_system.contains("refresh: after external tool evidence"));
    assert!(second_system.contains("We use Postgres for production."));
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
    async fn build(&self, model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
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
        if is_route_decision_request(&req) && !scripted_front_is_route_decision(&self.responses) {
            return Ok(synthetic_route_decision_response(&req));
        }
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

fn is_route_decision_request(req: &CompletionRequest) -> bool {
    matches!(
        &req.response_format,
        CompletionResponseFormat::JsonSchema { name, .. } if name == "route_decision"
    )
}

fn scripted_front_is_route_decision(responses: &Arc<Mutex<VecDeque<CompletionResponse>>>) -> bool {
    responses
        .lock()
        .unwrap()
        .front()
        .map(|response| {
            let trimmed = response.text.trim_start();
            trimmed.starts_with('{') && trimmed.contains("\"intent\"")
        })
        .unwrap_or(false)
}

fn synthetic_route_decision_response(req: &CompletionRequest) -> CompletionResponse {
    let user_input = req
        .messages
        .last()
        .map(|message| message.content.as_str())
        .unwrap_or_default();
    let intent = classify_by_rules(user_input).unwrap_or_else(|| default_intent(user_input));
    CompletionResponse {
        text: json!({
            "intent": intent.as_str(),
            "action": "none",
            "confidence": "low",
            "needs_clarification": false,
            "clarifying_question": null,
            "job_name": null,
            "job_description": null,
            "job_schedule": null,
            "job_prompt": null,
            "memory_summary": null,
            "memory_content": null,
            "reason": "synthetic test router fallback"
        })
        .to_string(),
        usage: Usage::default(),
        tool_calls: Vec::new(),
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
        tool_calls: Vec::new(),
    }
}

#[tokio::test]
async fn malformed_tool_call_retries_once_before_persisting_output() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let mut config = Config::default_template();
    config.security.exec_allow.push("/bin/echo".into());

    let mut kernel = Kernel::boot_with_parts(
        config,
        test_adapter(Arc::clone(&events)),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            Arc::clone(&requests),
            vec![
                scripted_response(r#"<tool_call>{"args":[]}</tool_call>"#),
                scripted_response(
                    r#"<tool_call>{"program":"/bin/echo","args":["echo","ok"]}</tool_call>"#,
                ),
                scripted_response("done"),
            ],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    let summary = kernel.run_turn("run echo").await.unwrap();
    assert!(!summary.hit_turn_limit);

    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 3);
    assert!(!requests[0].tools.is_empty());
    assert!(requests[1]
        .system
        .as_deref()
        .unwrap()
        .contains("invalid tool-call shape"));

    let assistant_texts = events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|event| match event {
            KernelEvent::AssistantText(text) => Some(text.clone()),
            _ => None,
        })
        .collect::<Vec<_>>();
    assert_eq!(assistant_texts, vec!["done"]);
}

#[tokio::test]
async fn schedule_prose_retry_uses_shared_single_retry_budget() {
    let temp = TempRoot::new();
    let paths = temp.paths();
    paths.ensure().unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let requests = Arc::new(Mutex::new(Vec::new()));

    let mut kernel = Kernel::boot_with_parts(
        Config::default_template(),
        test_adapter(Arc::clone(&events)),
        paths,
        Arc::new(TestFactory::with_requests(
            "anthropic",
            Arc::clone(&requests),
            vec![
                scripted_response(
                    r#"{"intent":"schedule","action":"schedule_upsert","confidence":"medium","needs_clarification":false,"clarifying_question":null,"job_name":"daily-review","job_description":"Daily review","job_schedule":"@daily at 07:00","job_prompt":"Run a concise daily review.","memory_summary":null,"memory_content":null,"reason":"The request appears to be a schedule mutation but needs main-turn help."}"#,
                ),
                scripted_response("I can set that up. Shall I proceed?"),
                scripted_response("Yes, I can proceed after you confirm."),
            ],
            Some(test_pricing()),
        )),
    )
    .await
    .expect("kernel should boot");

    let summary = kernel
        .run_turn("schedule a daily review at 07:00")
        .await
        .expect("turn should succeed");
    assert_eq!(
        summary.stop_reason.as_deref(),
        Some("schedule_tool_retry_failed")
    );
    let requests = requests.lock().unwrap();
    assert_eq!(requests.len(), 3, "router, first model, one retry");
    assert!(requests[2]
        .system
        .as_deref()
        .unwrap()
        .contains("plain prose confirmation"));
    assert!(events.lock().unwrap().iter().any(|event| matches!(
        event,
        KernelEvent::AssistantText(text)
            if text.contains("allbert-cli jobs upsert <job-definition.md>")
    )));
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
                scripted_response("<tool_call>{\"name\":\"list_skills\",\"input\":{}}</tool_call>"),
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
    config.model.max_tokens = live_smoke_max_tokens(start_provider);
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
    assert!(cargo_toml.content.contains("allbert-kernel-services"));

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
            max_tokens: live_smoke_max_tokens(switch_provider),
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

fn live_smoke_max_tokens(provider: Provider) -> u32 {
    match provider {
        Provider::Gemini => 512,
        _ => 64,
    }
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
    config.model.max_tokens = live_smoke_max_tokens(Provider::Ollama);
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
    assert!(cargo_toml.content.contains("allbert-kernel-services"));

    kernel
        .set_model(ModelConfig {
            provider: Provider::Ollama,
            model_id: "gemma4".into(),
            api_key_env: None,
            base_url: std::env::var("OLLAMA_BASE_URL")
                .ok()
                .or_else(|| Provider::Ollama.default_base_url().map(str::to_string)),
            max_tokens: live_smoke_max_tokens(Provider::Ollama),
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
        "gemini-2.5-flash-lite",
        "GEMINI_API_KEY",
        Provider::Gemini,
        "gemini-2.5-flash-lite",
        "GEMINI_API_KEY",
    )
    .await;
}

#[tokio::test]
#[ignore = "live smoke requires local Ollama with gemma4"]
async fn ollama_release_smoke() {
    run_live_ollama_release_smoke().await;
}
