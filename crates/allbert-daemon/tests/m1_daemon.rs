#![allow(
    clippy::await_holding_lock,
    clippy::useless_concat,
    clippy::useless_format
)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use allbert_daemon::{spawn, spawn_with_factory, DaemonClient, DaemonError, RunningDaemon};
use allbert_kernel::error::LlmError;
use allbert_kernel::llm::{
    CompletionRequest, CompletionResponse, LlmProvider, ProviderFactory, Usage,
};
use allbert_kernel::{
    add_identity_channel, ensure_identity_record, load_identity_record, memory, AllbertPaths,
    Config, ModelConfig,
};
use allbert_proto::{
    ChannelKind, ClientKind, ClientMessage, ConfirmDecisionPayload, InputReplyPayload,
    InputResponsePayload, JobBudgetPayload, JobDefinitionPayload, KernelEventPayload,
    ModelConfigPayload, ProviderKind, ServerMessage,
};
use async_trait::async_trait;
use chrono::{Duration as ChronoDuration, NaiveTime, TimeZone, Utc};
use chrono_tz::Tz;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;
use std::collections::VecDeque;
use tokio::time::{sleep, timeout};

static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

struct TempHome {
    root: PathBuf,
}

impl TempHome {
    fn new() -> Self {
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let unique = format!("abd-{}-{}", std::process::id(), counter);
        let root = PathBuf::from("/tmp").join(unique);
        std::fs::create_dir_all(&root).expect("temp home should be created");
        Self { root }
    }

    fn paths(&self) -> AllbertPaths {
        AllbertPaths::under(self.root.clone())
    }
}

impl Drop for TempHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn sample_config() -> Config {
    let mut config = Config::default_template();
    config.setup.version = 2;
    config
}

fn jobs_test_config() -> Config {
    let mut config = sample_config();
    config.jobs.enabled = false;
    config.jobs.max_concurrent_runs = 2;
    config.jobs.default_timezone = Some("America/Los_Angeles".into());
    config
}

#[tokio::test]
async fn daemon_boot_seeds_identity_record() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![])),
    )
    .await
    .expect("daemon should start");

    assert!(
        paths.identity_user.exists(),
        "identity record should be seeded"
    );
    let record = load_identity_record(&paths).expect("identity record should parse");
    assert!(record.id.starts_with("usr_"));
    assert_eq!(record.name, "primary");
    assert!(record
        .channels
        .iter()
        .any(|binding| binding.kind == ChannelKind::Repl && binding.sender == "local"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn repl_attach_reuses_identity_mru_session_across_channels() {
    let home = TempHome::new();
    let paths = home.paths();
    let identity = ensure_identity_record(&paths).expect("identity should seed");
    add_identity_channel(&paths, ChannelKind::Telegram, "telegram:12345:9")
        .expect("telegram binding should add");
    seed_session_meta(
        &paths,
        "shared-identity",
        ChannelKind::Telegram,
        Some("telegram:12345:9"),
        Some(&identity.id),
        "2026-04-21T17:00:00Z",
    );

    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("cross-channel reply")])),
    )
    .await
    .expect("daemon should start");

    let mut client = wait_for_client(&paths).await;
    let attached = client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    assert_eq!(attached.session_id, "shared-identity");
    assert_eq!(attached.channel, ChannelKind::Repl);

    let messages = run_turn_collect_messages(&mut client, "continue from repl").await;
    assert!(messages
        .iter()
        .any(|message| matches!(message, ServerMessage::TurnResult(_))));

    let journal = std::fs::read_to_string(paths.sessions.join("shared-identity").join("turns.md"))
        .expect("journal should read");
    assert!(journal.contains("- channel: repl"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn legacy_repl_session_writes_identity_id_on_next_mutation() {
    let home = TempHome::new();
    let paths = home.paths();
    let identity = ensure_identity_record(&paths).expect("identity should seed");
    seed_session_meta(
        &paths,
        "repl-primary",
        ChannelKind::Repl,
        Some("local"),
        None,
        "2026-04-21T17:00:00Z",
    );

    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("identity upgraded")])),
    )
    .await
    .expect("daemon should start");

    let mut client = wait_for_client(&paths).await;
    let attached = client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    assert_eq!(attached.session_id, "repl-primary");

    let _ = run_turn_collect_messages(&mut client, "upgrade legacy session").await;
    let meta = read_session_meta_identity(&paths, "repl-primary");
    assert_eq!(meta.identity_id.as_deref(), Some(identity.id.as_str()));

    shutdown_daemon(handle, &paths).await;
}

async fn wait_for_client(paths: &AllbertPaths) -> DaemonClient {
    timeout(Duration::from_secs(5), async {
        loop {
            match DaemonClient::connect(paths, ClientKind::Test).await {
                Ok(client) => return client,
                Err(_) => sleep(Duration::from_millis(50)).await,
            }
        }
    })
    .await
    .expect("daemon should become available")
}

async fn shutdown_daemon(handle: RunningDaemon, paths: &AllbertPaths) {
    let mut client = DaemonClient::connect(paths, ClientKind::Test)
        .await
        .expect("client should connect for shutdown");
    client.shutdown().await.expect("shutdown should succeed");
    handle.wait().await.expect("daemon should stop cleanly");
}

async fn run_turn_collect_messages(client: &mut DaemonClient, input: &str) -> Vec<ServerMessage> {
    client
        .start_turn(input.into())
        .await
        .expect("turn should start");
    let mut messages = Vec::new();
    loop {
        let message = client.recv().await.expect("daemon should respond");
        let done = matches!(message, ServerMessage::TurnResult(_));
        match &message {
            ServerMessage::ConfirmRequest(_) => panic!("unexpected confirm request"),
            ServerMessage::InputRequest(_) => panic!("unexpected input request"),
            _ => {}
        }
        messages.push(message);
        if done {
            break;
        }
    }
    messages
}

async fn run_turn_expect_error(client: &mut DaemonClient, input: &str) -> String {
    client
        .start_turn(input.into())
        .await
        .expect("turn should start");
    loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::Error(error) => return error.message,
            ServerMessage::Event(_) => {}
            other => panic!("expected turn error, got {other:?}"),
        }
    }
}

async fn wait_for_job_rerun(
    client: &mut DaemonClient,
    name: &str,
    previous_run_id: &str,
) -> allbert_proto::JobStatusPayload {
    timeout(Duration::from_secs(5), async {
        loop {
            let status = client.get_job(name).await.expect("job status should load");
            if status
                .state
                .last_run_id
                .as_deref()
                .is_some_and(|run_id| run_id != previous_run_id)
            {
                return status;
            }
            sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("job rerun should settle")
}

async fn wait_for_job_running(
    client: &mut DaemonClient,
    name: &str,
) -> allbert_proto::JobStatusPayload {
    timeout(Duration::from_secs(5), async {
        loop {
            let status = client.get_job(name).await.expect("job status should load");
            if status.state.running {
                return status;
            }
            sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("job should become running")
}

async fn run_turn_with_confirms(
    client: &mut DaemonClient,
    input: &str,
    decision: ConfirmDecisionPayload,
) -> (
    Vec<ServerMessage>,
    Vec<allbert_proto::ConfirmRequestPayload>,
) {
    client
        .start_turn(input.into())
        .await
        .expect("turn should start");
    let mut messages = Vec::new();
    let mut confirms = Vec::new();
    loop {
        let message = client.recv().await.expect("daemon should respond");
        match &message {
            ServerMessage::ConfirmRequest(request) => {
                confirms.push(request.clone());
                client
                    .send(&ClientMessage::ConfirmReply(
                        allbert_proto::ConfirmReplyPayload {
                            request_id: request.request_id,
                            decision,
                        },
                    ))
                    .await
                    .expect("confirm reply should send");
            }
            ServerMessage::InputRequest(_) => panic!("unexpected input request"),
            _ => {}
        }
        let done = matches!(message, ServerMessage::TurnResult(_));
        messages.push(message);
        if done {
            break;
        }
    }
    (messages, confirms)
}

#[derive(Clone)]
struct TestFactory {
    responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
    failing_prompts: Arc<Vec<String>>,
    requests: Arc<Mutex<Vec<CompletionRequest>>>,
}

impl TestFactory {
    fn new(responses: Vec<CompletionResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
            failing_prompts: Arc::new(Vec::new()),
            requests: Arc::new(Mutex::new(Vec::new())),
        }
    }

    fn with_requests(
        responses: Vec<CompletionResponse>,
        requests: Arc<Mutex<Vec<CompletionRequest>>>,
    ) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
            failing_prompts: Arc::new(Vec::new()),
            requests,
        }
    }

    fn with_failing_prompts(
        responses: Vec<CompletionResponse>,
        failing_prompts: Vec<&str>,
    ) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
            failing_prompts: Arc::new(
                failing_prompts
                    .into_iter()
                    .map(|value| value.to_string())
                    .collect(),
            ),
            requests: Arc::new(Mutex::new(Vec::new())),
        }
    }
}

#[async_trait]
impl ProviderFactory for TestFactory {
    async fn build(&self, _model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
        Ok(Box::new(TestProvider {
            responses: Arc::clone(&self.responses),
            failing_prompts: Arc::clone(&self.failing_prompts),
            requests: Arc::clone(&self.requests),
        }))
    }
}

struct TestProvider {
    responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
    failing_prompts: Arc<Vec<String>>,
    requests: Arc<Mutex<Vec<CompletionRequest>>>,
}

#[async_trait]
impl LlmProvider for TestProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        self.requests.lock().unwrap().push(req.clone());
        if let Some(message) = req.messages.last() {
            if self
                .failing_prompts
                .iter()
                .any(|prompt| prompt == &message.content)
            {
                return Err(LlmError::Response(format!(
                    "simulated failure for prompt: {}",
                    message.content
                )));
            }
        }
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| LlmError::Response("no scripted response left".into()))
    }

    fn pricing(&self, _model: &str) -> Option<allbert_kernel::llm::Pricing> {
        None
    }

    fn provider_name(&self) -> &'static str {
        "test"
    }
}

fn scripted(text: &str) -> CompletionResponse {
    CompletionResponse {
        text: text.into(),
        usage: Usage::default(),
    }
}

fn tool_call_names(messages: &[ServerMessage]) -> Vec<String> {
    messages
        .iter()
        .filter_map(|message| match message {
            ServerMessage::Event(KernelEventPayload::ToolCall { name, .. }) => Some(name.clone()),
            _ => None,
        })
        .collect()
}

fn sample_job(name: &str, schedule: &str, prompt: &str) -> JobDefinitionPayload {
    JobDefinitionPayload {
        name: name.into(),
        description: format!("{name} description"),
        enabled: true,
        schedule: schedule.into(),
        skills: Vec::new(),
        timezone: None,
        model: None,
        allowed_tools: Vec::new(),
        timeout_s: None,
        report: None,
        max_turns: None,
        budget: None,
        session_name: None,
        memory_prefetch: None,
        prompt: prompt.into(),
    }
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct TemplateFrontmatter {
    name: String,
    description: String,
    enabled: bool,
    schedule: String,
    #[serde(default)]
    skills: Vec<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    report: Option<allbert_proto::JobReportPolicyPayload>,
}

fn parse_template_job(path: &std::path::Path) -> JobDefinitionPayload {
    let raw = std::fs::read_to_string(path).expect("template should be readable");
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<TemplateFrontmatter>(&raw)
        .expect("template should parse");
    let data = parsed.data.expect("template frontmatter should exist");
    JobDefinitionPayload {
        name: data.name,
        description: data.description,
        enabled: data.enabled,
        schedule: data.schedule,
        skills: data.skills,
        timezone: data.timezone,
        model: None,
        allowed_tools: Vec::new(),
        timeout_s: None,
        report: data.report,
        max_turns: None,
        budget: None,
        session_name: None,
        memory_prefetch: None,
        prompt: parsed.content.trim().to_string(),
    }
}

#[derive(Debug, Deserialize)]
struct ApprovalFrontmatter {
    id: String,
    request_id: u64,
    expires_at: String,
    #[serde(default)]
    kind: Option<String>,
    status: String,
    #[serde(default)]
    resolver: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SessionMetaApprovalView {
    #[serde(default)]
    pending_approvals: Vec<String>,
}

#[derive(Debug, Deserialize)]
struct SessionMetaIdentityView {
    #[serde(default)]
    identity_id: Option<String>,
}

fn write_heartbeat(paths: &AllbertPaths, body: &str) {
    std::fs::write(&paths.heartbeat, body).expect("heartbeat should write");
}

#[test]
fn continuity_bearing_modules_do_not_use_raw_fs_write() {
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(|path| path.parent())
        .expect("repo root should exist")
        .to_path_buf();
    for (relative, forbidden) in [
        (
            "crates/allbert-kernel/src/config.rs",
            vec!["std::fs::write(&paths.config, rendered)"],
        ),
        (
            "crates/allbert-kernel/src/paths.rs",
            vec!["std::fs::write(path, content)"],
        ),
        (
            "crates/allbert-daemon/src/jobs.rs",
            vec!["fs::write(path, encoded)?", "fs::write(path, frontmatter)?"],
        ),
        (
            "crates/allbert-cli/src/approvals.rs",
            vec!["std::fs::write(path, rendered)"],
        ),
        (
            "crates/allbert-cli/src/setup.rs",
            vec![
                "fs::write(&paths.user, updated_user)",
                "fs::write(&paths.identity, updated_identity)",
                "fs::write(&destination, enabled)",
            ],
        ),
        (
            "crates/allbert-cli/src/skills.rs",
            vec![
                "fs::write(path, rendered).with_context(|| format!(\"write {}\", path.display()))",
            ],
        ),
        (
            "crates/allbert-kernel/src/lib.rs",
            vec![
                "std::fs::write(&paths.agents_notes, &rendered)",
                "std::fs::write(&paths.agents_notes, rendered_agents)",
                "std::fs::write(&self.paths.agents_notes, rendered)",
            ],
        ),
        (
            "crates/allbert-kernel/src/memory/mod.rs",
            vec![
                "std::fs::write(&paths.memory_index, \"# MEMORY\\n\\n\")",
                "WriteMemoryMode::Write => std::fs::write(&target, input.content.as_bytes())",
                "std::fs::write(&target, current.as_bytes())",
                "std::fs::write(&path, current)",
                "std::fs::write(&paths.memory_index, index)",
            ],
        ),
        (
            "crates/allbert-kernel/src/memory/curated.rs",
            vec![
                "fs::write(&paths.memory_index, \"# MEMORY\\n\\n\")",
                "fs::write(path, contents)",
                "fs::write(&report_path, rendered)",
            ],
        ),
        (
            "crates/allbert-kernel/src/skills/mod.rs",
            vec![
                "fs::write(&skill_path, frontmatter)",
                "fs::write(&paths.agents_notes, &rendered)",
            ],
        ),
    ] {
        let raw =
            std::fs::read_to_string(repo_root.join(relative)).expect("source file should read");
        for needle in forbidden {
            assert!(
                !raw.contains(needle),
                "{relative} should not contain direct continuity write `{needle}`"
            );
        }
    }
}

fn read_session_meta_approval(paths: &AllbertPaths, session_id: &str) -> SessionMetaApprovalView {
    let raw = std::fs::read_to_string(paths.sessions.join(session_id).join("meta.json"))
        .expect("session meta should be readable");
    serde_json::from_str(&raw).expect("session meta should parse")
}

fn read_session_meta_identity(paths: &AllbertPaths, session_id: &str) -> SessionMetaIdentityView {
    let raw = std::fs::read_to_string(paths.sessions.join(session_id).join("meta.json"))
        .expect("session meta should be readable");
    serde_json::from_str(&raw).expect("session meta should parse")
}

fn seed_session_meta(
    paths: &AllbertPaths,
    session_id: &str,
    channel: ChannelKind,
    sender_id: Option<&str>,
    identity_id: Option<&str>,
    last_activity_at: &str,
) {
    let session_dir = paths.sessions.join(session_id);
    std::fs::create_dir_all(&session_dir).expect("session dir should exist");
    let meta = serde_json::json!({
        "session_id": session_id,
        "channel": channel,
        "sender_id": sender_id,
        "identity_id": identity_id,
        "started_at": "2026-04-20T00:00:00Z",
        "last_activity_at": last_activity_at,
        "root_agent_name": "allbert/root",
        "last_agent_stack": ["allbert/root"],
        "last_resolved_intent": "task",
        "intent_history": ["task"],
        "active_skills": [],
        "ephemeral_memory": [],
        "model": ModelConfigPayload {
            provider: ProviderKind::Anthropic,
            model_id: "claude-sonnet-4-5".into(),
            api_key_env: Some("ANTHROPIC_API_KEY".into()),
            base_url: None,
            max_tokens: 4096,
            context_window_tokens: 0,
        },
        "turn_count": 1,
        "cost_total_usd": 0.0,
        "messages": [],
        "pending_approvals": []
    });
    std::fs::write(
        session_dir.join("meta.json"),
        serde_json::to_vec_pretty(&meta).expect("meta should serialize"),
    )
    .expect("meta should write");
    std::fs::write(
        session_dir.join("turns.md"),
        format!(
            "# Session {session_id}\n\n- channel: {}\n- started_at: 2026-04-20T00:00:00Z\n\n",
            match channel {
                ChannelKind::Cli => "cli",
                ChannelKind::Repl => "repl",
                ChannelKind::Jobs => "jobs",
                ChannelKind::Telegram => "telegram",
            }
        ),
    )
    .expect("turns should write");
}

fn parse_pending_approval(
    paths: &AllbertPaths,
    session_id: &str,
    approval_id: &str,
) -> ApprovalFrontmatter {
    let raw = std::fs::read_to_string(
        paths
            .sessions
            .join(session_id)
            .join("approvals")
            .join(format!("{approval_id}.md")),
    )
    .expect("approval file should be readable");
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<ApprovalFrontmatter>(&raw)
        .expect("approval should parse");
    parsed.data.expect("approval frontmatter should exist")
}

fn next_daily_due(
    now: chrono::DateTime<Utc>,
    timezone: &str,
    hour: u32,
    minute: u32,
) -> chrono::DateTime<Utc> {
    let tz: Tz = timezone.parse().expect("timezone should parse");
    let local = now.with_timezone(&tz);
    let time = NaiveTime::from_hms_opt(hour, minute, 0).expect("time should be valid");
    let date = local.date_naive();
    let candidate = tz
        .from_local_datetime(&date.and_time(time))
        .single()
        .expect("daily candidate should be unambiguous");
    let next = if candidate > local {
        candidate
    } else {
        tz.from_local_datetime(&((date + ChronoDuration::days(1)).and_time(time)))
            .single()
            .expect("next daily candidate should be unambiguous")
    };
    next.with_timezone(&Utc)
}

#[derive(Clone)]
struct ProbeFactory {
    delay_ms: u64,
    response_text: String,
    active: Arc<AtomicUsize>,
    max_seen: Arc<AtomicUsize>,
}

impl ProbeFactory {
    fn new(delay_ms: u64, response_text: &str) -> Self {
        Self {
            delay_ms,
            response_text: response_text.into(),
            active: Arc::new(AtomicUsize::new(0)),
            max_seen: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn max_seen(&self) -> usize {
        self.max_seen.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl ProviderFactory for ProbeFactory {
    async fn build(&self, _model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
        Ok(Box::new(ProbeProvider {
            delay_ms: self.delay_ms,
            response_text: self.response_text.clone(),
            active: self.active.clone(),
            max_seen: self.max_seen.clone(),
        }))
    }
}

struct ProbeProvider {
    delay_ms: u64,
    response_text: String,
    active: Arc<AtomicUsize>,
    max_seen: Arc<AtomicUsize>,
}

#[async_trait]
impl LlmProvider for ProbeProvider {
    async fn complete(&self, _req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
        let active = self.active.fetch_add(1, Ordering::SeqCst) + 1;
        let mut seen = self.max_seen.load(Ordering::SeqCst);
        while active > seen {
            match self
                .max_seen
                .compare_exchange(seen, active, Ordering::SeqCst, Ordering::SeqCst)
            {
                Ok(_) => break,
                Err(current) => seen = current,
            }
        }

        sleep(Duration::from_millis(self.delay_ms)).await;
        self.active.fetch_sub(1, Ordering::SeqCst);
        Ok(scripted(&self.response_text))
    }

    fn pricing(&self, _model: &str) -> Option<allbert_kernel::llm::Pricing> {
        None
    }

    fn provider_name(&self) -> &'static str {
        "probe"
    }
}

#[tokio::test]
async fn daemon_boots_and_accepts_attach_and_status() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    let attached = client
        .attach(ChannelKind::Cli, None)
        .await
        .expect("attach should succeed");
    assert_eq!(attached.channel, ChannelKind::Cli);
    assert!(attached.session_id.starts_with("cli-"));

    let status = client.status().await.expect("status should succeed");
    assert_eq!(status.pid, std::process::id());
    assert_eq!(
        status.socket_path,
        handle.socket_path().display().to_string()
    );

    client.shutdown().await.expect("shutdown should succeed");
    handle.wait().await.expect("daemon should exit");
}

#[tokio::test]
async fn handshake_rejects_protocol_mismatch() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should boot");
    wait_for_client(&paths).await;

    let err = match DaemonClient::connect_with_version(&paths, ClientKind::Test, 999).await {
        Ok(_) => panic!("mismatched protocol should fail"),
        Err(err) => err,
    };
    assert!(
        err.to_string().contains("protocol version mismatch"),
        "unexpected error: {err}"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn second_daemon_spawn_is_rejected() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should boot");
    wait_for_client(&paths).await;

    let err = match spawn(sample_config(), paths.clone()).await {
        Ok(_) => panic!("second daemon should be rejected"),
        Err(err) => err,
    };
    assert!(
        err.to_string()
            .contains("daemon lock is held by live process"),
        "unexpected error: {err}"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn client_auto_spawn_fallback_starts_daemon() {
    let home = TempHome::new();
    let paths = home.paths();
    let config = sample_config();
    let handle_slot = Arc::new(Mutex::new(None::<RunningDaemon>));
    let handle_slot_for_spawn = handle_slot.clone();
    let spawn_paths = paths.clone();

    let mut client = DaemonClient::connect_or_spawn_with(
        &paths,
        ClientKind::Test,
        Duration::from_secs(5),
        move || {
            let paths = spawn_paths.clone();
            let config = config.clone();
            async move {
                let handle = spawn(config, paths).await?;
                *handle_slot_for_spawn
                    .lock()
                    .expect("handle lock should succeed") = Some(handle);
                Ok(())
            }
        },
    )
    .await
    .expect("client should auto-spawn daemon");

    let attached = client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    assert_eq!(attached.session_id, "repl-primary");

    client.shutdown().await.expect("shutdown should succeed");
    let handle = handle_slot
        .lock()
        .expect("handle lock should succeed")
        .take()
        .expect("spawned daemon handle should be stored");
    handle.wait().await.expect("daemon should exit");
}

#[tokio::test]
async fn request_input_round_trip_flows_over_channel() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"favorite color?\",\"allow_empty\":false}}</tool_call>",
            ),
            scripted("thanks for the answer"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    client
        .start_turn("hello".into())
        .await
        .expect("turn should start");

    let mut assistant_text = Vec::new();
    loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::InputRequest(request) => {
                assert_eq!(request.prompt, "favorite color?");
                client
                    .send(&ClientMessage::InputReply(InputReplyPayload {
                        request_id: request.request_id,
                        response: InputResponsePayload::Submitted("blue".into()),
                    }))
                    .await
                    .expect("input reply should send");
            }
            ServerMessage::Event(KernelEventPayload::AssistantText(text)) => {
                assistant_text.push(text);
            }
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }

    assert!(assistant_text
        .iter()
        .any(|text| text == "thanks for the answer"));
    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn confirm_round_trip_flows_over_channel() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"hello\"]}}</tool_call>",
            ),
            scripted("confirmed"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    client
        .start_turn("run".into())
        .await
        .expect("turn should start");

    let mut saw_done = false;
    loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::ConfirmRequest(request) => {
                assert!(request.rendered.contains("/bin/echo"));
                client
                    .send(&ClientMessage::ConfirmReply(
                        allbert_proto::ConfirmReplyPayload {
                            request_id: request.request_id,
                            decision: ConfirmDecisionPayload::AllowOnce,
                        },
                    ))
                    .await
                    .expect("confirm reply should send");
            }
            ServerMessage::Event(KernelEventPayload::AssistantText(text)) => {
                if text == "confirmed" {
                    saw_done = true;
                }
            }
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }

    assert!(saw_done);
    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn client_disconnect_during_prompt_does_not_poison_session() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"still there?\",\"allow_empty\":false}}</tool_call>",
            ),
            scripted("cancel handled"),
            scripted("second turn works"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client
        .start_turn("first".into())
        .await
        .expect("turn should start");

    loop {
        match client.recv().await.expect("daemon should prompt") {
            ServerMessage::InputRequest(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }
    drop(client);

    sleep(Duration::from_millis(200)).await;

    let mut reattached = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("reattach client should connect");
    reattached
        .attach(ChannelKind::Repl, Some("repl-primary".into()))
        .await
        .expect("reattach should succeed");
    reattached
        .start_turn("second".into())
        .await
        .expect("second turn should start");

    let mut saw_second = false;
    loop {
        match reattached.recv().await.expect("daemon should respond") {
            ServerMessage::Event(KernelEventPayload::AssistantText(text)) => {
                if text == "second turn works" {
                    saw_second = true;
                }
            }
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }

    assert!(saw_second);
    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn session_local_model_changes_do_not_leak_across_sessions() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut repl = wait_for_client(&paths).await;
    repl.attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    let updated = repl
        .set_model(ModelConfigPayload {
            provider: ProviderKind::Openrouter,
            model_id: "openrouter/test-model".into(),
            api_key_env: Some("OPENROUTER_API_KEY".into()),
            base_url: None,
            max_tokens: 4096,
            context_window_tokens: 0,
        })
        .await
        .expect("set model should succeed");
    assert_eq!(updated.provider, ProviderKind::Openrouter);
    drop(repl);

    let mut same_session = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("same session client should connect");
    same_session
        .attach(ChannelKind::Repl, Some("repl-primary".into()))
        .await
        .expect("reattach should succeed");
    let repl_model = same_session.get_model().await.expect("model should read");
    assert_eq!(repl_model.provider, ProviderKind::Openrouter);

    let mut other_session = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("other session client should connect");
    other_session
        .attach(ChannelKind::Cli, None)
        .await
        .expect("cli attach should succeed");
    let cli_model = other_session.get_model().await.expect("model should read");
    assert_eq!(cli_model.provider, ProviderKind::Ollama);

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn expanded_provider_models_roundtrip_through_daemon_session_status() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    let daemon_status = client.status().await.expect("daemon status should load");
    assert_eq!(daemon_status.model_api_key_env, None);
    assert_eq!(
        daemon_status.model_base_url.as_deref(),
        Some("http://127.0.0.1:11434")
    );
    assert!(
        daemon_status.model_api_key_visible,
        "keyless daemon default should be treated as usable"
    );

    let cases = [
        ModelConfigPayload {
            provider: ProviderKind::Openrouter,
            model_id: "openrouter/test-model".into(),
            api_key_env: Some("__ALLBERT_TEST_MISSING_OPENROUTER_KEY".into()),
            base_url: None,
            max_tokens: 2048,
            context_window_tokens: 0,
        },
        ModelConfigPayload {
            provider: ProviderKind::Openai,
            model_id: "gpt-5.4-mini".into(),
            api_key_env: Some("__ALLBERT_TEST_MISSING_OPENAI_KEY".into()),
            base_url: Some("https://api.openai.test/v1".into()),
            max_tokens: 4096,
            context_window_tokens: 0,
        },
        ModelConfigPayload {
            provider: ProviderKind::Gemini,
            model_id: "gemini-2.5-flash".into(),
            api_key_env: Some("__ALLBERT_TEST_MISSING_GEMINI_KEY".into()),
            base_url: Some("https://generativelanguage.test/v1beta".into()),
            max_tokens: 3072,
            context_window_tokens: 0,
        },
        ModelConfigPayload {
            provider: ProviderKind::Ollama,
            model_id: "gemma4".into(),
            api_key_env: None,
            base_url: Some("http://127.0.0.1:11434".into()),
            max_tokens: 2048,
            context_window_tokens: 0,
        },
    ];

    for expected in cases {
        let updated = client
            .set_model(expected.clone())
            .await
            .expect("set model should succeed");
        assert_eq!(updated, expected);

        let read_back = client.get_model().await.expect("model should read back");
        assert_eq!(read_back, expected);

        let status = client
            .session_status()
            .await
            .expect("session status should load");
        assert_eq!(status.model, expected);
        assert_eq!(status.api_key_present, expected.api_key_env.is_none());
    }

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn session_auto_confirm_skips_confirm_prompt() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"hello\"]}}</tool_call>",
            ),
            scripted("auto confirmed"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client
        .set_auto_confirm(true)
        .await
        .expect("auto confirm should enable");
    client
        .start_turn("run".into())
        .await
        .expect("turn should start");

    let mut saw_assistant = false;
    loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::ConfirmRequest(_) => panic!("confirm should have been skipped"),
            ServerMessage::Event(KernelEventPayload::AssistantText(text)) => {
                if text == "auto confirmed" {
                    saw_assistant = true;
                }
            }
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }

    assert!(saw_assistant);
    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn trace_toggle_updates_status_and_debug_log() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("noop reply")])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client.set_trace(true).await.expect("trace should enable");

    let status = client.session_status().await.expect("status should load");
    assert!(status.trace_enabled);

    client
        .start_turn("noop".into())
        .await
        .expect("turn should start");
    loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message: {:?}", other),
        }
    }

    let debug_log =
        std::fs::read_to_string(&paths.daemon_debug_log).expect("debug log should exist");
    assert!(debug_log.contains("trace=true"));
    assert!(debug_log.contains("run_turn session=repl-primary"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn session_status_reports_last_intent_and_agent_stack() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(concat!(
                "<tool_call>{\"name\":\"spawn_subagent\",\"input\":",
                "{\"name\":\"research/reader\",\"prompt\":\"Summarize the note.\"}}",
                "</tool_call>"
            )),
            scripted("child summary"),
            scripted("delegated successfully"),
        ])),
    )
    .await
    .expect("daemon should boot");

    std::fs::create_dir_all(paths.skills.join("research")).expect("skill dir should exist");
    std::fs::write(
        paths.skills.join("research/SKILL.md"),
        r#"---
name: research
description: Research helpers.
intents: [task]
agents:
  - path: agents/reader.md
---

# Research

Use the reader agent for focused reading tasks.
"#,
    )
    .expect("skill should write");
    std::fs::create_dir_all(paths.skills.join("research/agents")).expect("agents dir should exist");
    std::fs::write(
        paths.skills.join("research/agents/reader.md"),
        r#"---
name: reader
description: Focused reader.
allowed-tools: read_file
---

# Reader

Read carefully and summarize clearly.
"#,
    )
    .expect("agent should write");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    let messages = run_turn_collect_messages(&mut client, "please review this note").await;
    assert!(messages.iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::AssistantText(text))
        if text == "delegated successfully"
    )));

    let status = client.session_status().await.expect("status should load");
    assert_eq!(status.root_agent_name, "allbert/root");
    assert_eq!(status.last_resolved_intent.as_deref(), Some("task"));
    assert_eq!(
        status.last_agent_stack,
        vec!["allbert/root".to_string(), "research/reader".to_string()]
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn ephemeral_memory_is_isolated_per_session_and_survives_reattach() {
    let home = TempHome::new();
    let paths = home.paths();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![
                scripted("FIRST_REPLY"),
                scripted("SECOND_REPLY"),
                scripted("THIRD_REPLY"),
            ],
            requests.clone(),
        )),
    )
    .await
    .expect("daemon should boot");

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("memory-a".into()))
            .await
            .expect("attach should succeed");
        let _ = run_turn_collect_messages(&mut client, "remember alpha context").await;
    }

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("memory-a".into()))
            .await
            .expect("reattach should succeed");
        let _ = run_turn_collect_messages(&mut client, "continue alpha").await;
    }

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("memory-b".into()))
            .await
            .expect("attach should succeed");
        let _ = run_turn_collect_messages(&mut client, "beta only").await;
    }

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, Some("memory-a".into()))
        .await
        .expect("status attach should succeed");
    let status = client.session_status().await.expect("status should load");
    assert_eq!(status.session_id, "memory-a");

    let recorded = requests.lock().unwrap();
    assert_eq!(recorded.len(), 3);
    let second_system = recorded[1].system.as_deref().unwrap_or_default();
    assert!(
        second_system.contains("remember alpha context"),
        "reattached session should keep prior ephemeral memory"
    );
    let third_system = recorded[2].system.as_deref().unwrap_or_default();
    assert!(
        !third_system.contains("remember alpha context"),
        "separate session should not inherit another session's ephemeral memory"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn daemon_restart_rehydrates_session_journal_and_ephemeral_memory() {
    let home = TempHome::new();
    let paths = home.paths();
    let first_requests = Arc::new(Mutex::new(Vec::new()));
    let first_handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![scripted("FIRST_PASS")],
            first_requests,
        )),
    )
    .await
    .expect("daemon should boot");

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("memory-restart".into()))
            .await
            .expect("attach should succeed");
        let _ = run_turn_collect_messages(&mut client, "remember before restart").await;
    }

    shutdown_daemon(first_handle, &paths).await;

    let second_requests = Arc::new(Mutex::new(Vec::new()));
    let second_handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![scripted("SECOND_PASS")],
            second_requests.clone(),
        )),
    )
    .await
    .expect("daemon should reboot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, Some("memory-restart".into()))
        .await
        .expect("attach should succeed");
    let _ = run_turn_collect_messages(&mut client, "after restart").await;

    let recorded = second_requests.lock().unwrap();
    assert_eq!(recorded.len(), 1);
    let system = recorded[0].system.as_deref().unwrap_or_default();
    assert!(
        system.contains("remember before restart"),
        "daemon restart should restore journal-backed ephemeral memory"
    );
    let meta_path = paths.sessions.join("memory-restart").join("meta.json");
    let turns_path = paths.sessions.join("memory-restart").join("turns.md");
    assert!(meta_path.exists(), "session meta should be persisted");
    assert!(
        turns_path.exists(),
        "session turns journal should be persisted"
    );
    let turns = std::fs::read_to_string(turns_path).expect("turns journal should load");
    assert!(
        turns.contains("remember before restart"),
        "journal should contain the completed pre-restart turn"
    );

    shutdown_daemon(second_handle, &paths).await;
}

#[tokio::test]
async fn telegram_async_confirm_persists_pending_approval_and_clears_on_reply() {
    let home = TempHome::new();
    let paths = home.paths();
    let skill_dir = paths.skills_installed.join("existing-skill");
    std::fs::create_dir_all(&skill_dir).expect("skill dir should exist");
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: existing-skill\ndescription: Existing skill\nallowed-tools: [read_reference]\n---\n\nBody\n",
    )
    .expect("existing skill should be writable");

    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"create_skill\",\"input\":{\"name\":\"existing-skill\",\"description\":\"Updated skill\",\"allowed_tools\":[\"read_reference\"],\"body\":\"Updated body\"}}</tool_call>",
            ),
            scripted("updated"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    let attached = client
        .attach(ChannelKind::Telegram, Some("telegram-approval".into()))
        .await
        .expect("attach should succeed");
    assert_eq!(attached.channel, ChannelKind::Telegram);

    client
        .start_turn("update the skill".into())
        .await
        .expect("turn should start");

    let request = loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::ConfirmRequest(request) => break request,
            ServerMessage::Event(_) => {}
            other => panic!("expected confirm request, got {other:?}"),
        }
    };

    let approval_id = request
        .approval_id
        .clone()
        .expect("async confirm should expose approval id");
    assert!(
        request.expires_at.is_some(),
        "async confirm should expose expiry"
    );
    let approval = parse_pending_approval(&paths, "telegram-approval", &approval_id);
    assert_eq!(approval.id, approval_id);
    assert_eq!(approval.request_id, request.request_id);
    assert_eq!(approval.status, "pending");
    assert!(
        !approval.expires_at.is_empty(),
        "approval should persist expiry"
    );
    let meta = read_session_meta_approval(&paths, "telegram-approval");
    assert_eq!(meta.pending_approvals, vec![approval_id.clone()]);

    client
        .send(&ClientMessage::ConfirmReply(
            allbert_proto::ConfirmReplyPayload {
                request_id: request.request_id,
                decision: ConfirmDecisionPayload::AllowOnce,
            },
        ))
        .await
        .expect("confirm reply should send");

    let mut saw_turn_result = false;
    while !saw_turn_result {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::TurnResult(_) => saw_turn_result = true,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message after confirm: {other:?}"),
        }
    }

    let resolved = parse_pending_approval(&paths, "telegram-approval", &approval_id);
    assert_eq!(resolved.status, "accepted");
    let meta = read_session_meta_approval(&paths, "telegram-approval");
    assert!(
        meta.pending_approvals.is_empty(),
        "resolved approval should clear pending meta"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn telegram_async_confirm_timeout_marks_approval_and_restart_reconciles_meta() {
    let home = TempHome::new();
    let paths = home.paths();
    let skill_dir = paths.skills_installed.join("existing-skill");
    std::fs::create_dir_all(&skill_dir).expect("skill dir should exist");
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: existing-skill\ndescription: Existing skill\nallowed-tools: [read_reference]\n---\n\nBody\n",
    )
    .expect("existing skill should be writable");

    let mut config = sample_config();
    config.channels.approval_timeout_s = 1;

    let handle = spawn_with_factory(
        config.clone(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"create_skill\",\"input\":{\"name\":\"existing-skill\",\"description\":\"Updated skill\",\"allowed_tools\":[\"read_reference\"],\"body\":\"Updated body\"}}</tool_call>",
            ),
            scripted("timed out"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Telegram, Some("telegram-timeout".into()))
        .await
        .expect("attach should succeed");
    client
        .start_turn("update the skill".into())
        .await
        .expect("turn should start");

    let request = loop {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::ConfirmRequest(request) => break request,
            ServerMessage::Event(_) => {}
            other => panic!("expected confirm request, got {other:?}"),
        }
    };
    let approval_id = request
        .approval_id
        .clone()
        .expect("async confirm should expose approval id");

    let mut saw_timeout = false;
    let mut saw_turn_result = false;
    while !saw_turn_result {
        match client.recv().await.expect("daemon should respond") {
            ServerMessage::Event(KernelEventPayload::ToolResult { content, .. }) => {
                if content.contains("confirm-timeout") {
                    saw_timeout = true;
                }
            }
            ServerMessage::Event(_) => {}
            ServerMessage::TurnResult(_) => saw_turn_result = true,
            other => panic!("unexpected message after timeout: {other:?}"),
        }
    }
    assert!(
        saw_timeout,
        "timed-out approval should surface confirm-timeout"
    );

    let resolved = parse_pending_approval(&paths, "telegram-timeout", &approval_id);
    assert_eq!(resolved.status, "timeout");
    let meta = read_session_meta_approval(&paths, "telegram-timeout");
    assert!(
        meta.pending_approvals.is_empty(),
        "timeout should clear pending approval meta"
    );

    shutdown_daemon(handle, &paths).await;

    let second_handle =
        spawn_with_factory(config, paths.clone(), Arc::new(TestFactory::new(vec![])))
            .await
            .expect("daemon should restart");
    let resolved_after_restart = parse_pending_approval(&paths, "telegram-timeout", &approval_id);
    assert_eq!(resolved_after_restart.status, "timeout");
    let meta_after_restart = read_session_meta_approval(&paths, "telegram-timeout");
    assert!(meta_after_restart.pending_approvals.is_empty());

    shutdown_daemon(second_handle, &paths).await;
}

#[tokio::test]
async fn daemon_restart_resume_preserves_working_state_and_retrieves_promoted_memory() {
    let home = TempHome::new();
    let paths = home.paths();
    let config = sample_config();
    let first_handle = spawn_with_factory(
        config.clone(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted("okay, I will keep that in mind"),
            scripted(
                "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"We use Postgres for primary storage.\",\"kind\":\"learned_fact\",\"summary\":\"Primary database is Postgres\",\"tags\":[\"postgres\",\"database\"]}}</tool_call>",
            ),
            scripted("staged it for review"),
        ])),
    )
    .await
    .expect("daemon should boot");

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("m6-e2e".into()))
            .await
            .expect("attach should succeed");
        let _ =
            run_turn_collect_messages(&mut client, "keep alpha workspace context in mind").await;
        let _ = run_turn_collect_messages(&mut client, "stage the primary database fact").await;
    }

    let staged = memory::list_staged_memory(&paths, &config.memory, None, None, Some(10))
        .expect("staged memory should list");
    assert_eq!(staged.len(), 1, "one staged entry should exist");
    let preview = memory::preview_promote_staged_memory(
        &paths,
        &config.memory,
        &staged[0].id,
        Some("notes/projects/primary-database.md"),
        None,
    )
    .expect("promotion preview should build");
    let promoted = memory::promote_staged_memory(&paths, &config.memory, &preview)
        .expect("promotion should succeed");
    assert_eq!(promoted, "notes/projects/primary-database.md");

    shutdown_daemon(first_handle, &paths).await;

    let second_requests = Arc::new(Mutex::new(Vec::new()));
    let second_handle = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![
                scripted(
                    "<tool_call>{\"name\":\"search_memory\",\"input\":{\"query\":\"primary database postgres\",\"tier\":\"durable\",\"limit\":5}}</tool_call>",
                ),
                scripted("I found the durable memory"),
            ],
            second_requests.clone(),
        )),
    )
    .await
    .expect("daemon should reboot");

    let mut client = wait_for_client(&paths).await;
    let resumable = client.list_sessions().await.expect("sessions should list");
    assert!(
        resumable.iter().any(|entry| entry.session_id == "m6-e2e"),
        "resumed session should be discoverable after restart"
    );
    client
        .attach(ChannelKind::Repl, Some("m6-e2e".into()))
        .await
        .expect("attach should resume same session");
    let messages = run_turn_collect_messages(
        &mut client,
        "what do you remember about the primary database?",
    )
    .await;

    let recorded = second_requests.lock().unwrap();
    assert_eq!(
        recorded.len(),
        2,
        "retrieval turn should require tool round-trip"
    );
    let system = recorded[0].system.as_deref().unwrap_or_default();
    assert!(
        system.contains("keep alpha workspace context in mind"),
        "resumed session should restore journal-backed working state"
    );
    assert!(messages.iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "search_memory"
                && content.contains("notes/projects/primary-database.md")
                && content.contains("Primary database is Postgres")
    )));

    shutdown_daemon(second_handle, &paths).await;
}

#[tokio::test]
async fn sessions_can_be_listed_and_forgotten() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("FIRST_PASS")])),
    )
    .await
    .expect("daemon should boot");

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("forget-me".into()))
            .await
            .expect("attach should succeed");
        let _ = run_turn_collect_messages(&mut client, "remember this session").await;
    }

    shutdown_daemon(handle, &paths).await;

    let restarted = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should restart");
    let mut client = wait_for_client(&paths).await;
    let sessions = client.list_sessions().await.expect("sessions should list");
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].session_id, "forget-me");

    client
        .forget_session("forget-me")
        .await
        .expect("forget should succeed");
    assert!(
        paths.sessions_trash.join("forget-me").exists(),
        "forgotten session should move to trash"
    );
    let sessions = client
        .list_sessions()
        .await
        .expect("sessions should relist");
    assert!(sessions.is_empty(), "forgotten session should disappear");

    shutdown_daemon(restarted, &paths).await;
}

#[tokio::test]
async fn cli_inbox_accept_resumes_live_telegram_tool_approval() {
    let home = TempHome::new();
    let paths = home.paths();
    let identity = ensure_identity_record(&paths).expect("identity should seed");
    add_identity_channel(&paths, ChannelKind::Telegram, "telegram:12345:9")
        .expect("telegram binding should add");
    seed_session_meta(
        &paths,
        "telegram-cross",
        ChannelKind::Telegram,
        Some("telegram:12345:9"),
        Some(&identity.id),
        "2026-04-21T17:00:00Z",
    );

    let skill_dir = paths.skills_installed.join("existing-skill");
    std::fs::create_dir_all(&skill_dir).expect("skill dir should exist");
    std::fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: existing-skill\ndescription: Existing skill\nallowed-tools: [read_reference]\n---\n\nBody\n",
    )
    .expect("existing skill should be writable");

    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"create_skill\",\"input\":{\"name\":\"existing-skill\",\"description\":\"Updated skill\",\"allowed_tools\":[\"read_reference\"],\"body\":\"Updated body\"}}</tool_call>",
            ),
            scripted("approved via inbox"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut telegram = wait_for_client(&paths).await;
    telegram
        .attach(ChannelKind::Telegram, Some("telegram-cross".into()))
        .await
        .expect("attach should succeed");
    telegram
        .start_turn("update the skill".into())
        .await
        .expect("turn should start");

    let request = loop {
        match telegram.recv().await.expect("daemon should respond") {
            ServerMessage::ConfirmRequest(request) => break request,
            ServerMessage::Event(_) => {}
            other => panic!("expected confirm request, got {other:?}"),
        }
    };
    let approval_id = request
        .approval_id
        .clone()
        .expect("async confirm should expose approval id");

    let mut cli = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("cli should connect");
    let resolved = cli
        .resolve_inbox_approval(&approval_id, true, Some("cli accepted".into()))
        .await
        .expect("inbox resolve should succeed");
    assert!(resolved.resumed_live_turn);

    let mut saw_assistant = false;
    loop {
        match telegram.recv().await.expect("daemon should continue turn") {
            ServerMessage::Event(KernelEventPayload::AssistantText(text)) => {
                if text == "approved via inbox" {
                    saw_assistant = true;
                }
            }
            ServerMessage::TurnResult(_) => break,
            ServerMessage::Event(_) => {}
            other => panic!("unexpected message after inbox accept: {other:?}"),
        }
    }
    assert!(
        saw_assistant,
        "accepted approval should resume the blocked turn"
    );

    let approval = parse_pending_approval(&paths, "telegram-cross", &approval_id);
    assert_eq!(approval.status, "accepted");
    assert_eq!(approval.kind.as_deref(), Some("tool-approval"));
    assert_eq!(approval.resolver.as_deref(), Some("cli:local"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn telegram_cost_cap_inbox_accept_arms_next_turn() {
    let home = TempHome::new();
    let paths = home.paths();
    let identity = ensure_identity_record(&paths).expect("identity should seed");
    add_identity_channel(&paths, ChannelKind::Telegram, "telegram:12345:9")
        .expect("telegram binding should add");
    seed_session_meta(
        &paths,
        "telegram-cap",
        ChannelKind::Telegram,
        Some("telegram:12345:9"),
        Some(&identity.id),
        "2026-04-21T17:00:00Z",
    );

    let mut config = sample_config();
    config.limits.daily_usd_cap = Some(0.0);
    let requests = Arc::new(Mutex::new(Vec::new()));
    let handle = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![scripted("override worked")],
            requests.clone(),
        )),
    )
    .await
    .expect("daemon should boot");

    let mut telegram = wait_for_client(&paths).await;
    telegram
        .attach(ChannelKind::Telegram, Some("telegram-cap".into()))
        .await
        .expect("attach should succeed");

    let blocked = run_turn_expect_error(&mut telegram, "blocked by cap").await;
    assert!(
        blocked.contains("allbert-cli inbox accept"),
        "cost cap refusal should point to the inbox flow"
    );

    let mut cli = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("cli should connect");
    let approvals = cli
        .list_inbox(None, Some("cost-cap-override".into()), false)
        .await
        .expect("inbox list should load");
    assert_eq!(approvals.len(), 1);
    let approval_id = approvals[0].id.clone();

    let resolved = cli
        .resolve_inbox_approval(&approval_id, true, Some("release smoke".into()))
        .await
        .expect("cost-cap approval should resolve");
    assert!(!resolved.resumed_live_turn);
    assert!(resolved
        .note
        .as_deref()
        .unwrap_or_default()
        .contains("armed"));

    let _ = run_turn_collect_messages(&mut telegram, "override turn").await;
    assert_eq!(
        requests.lock().unwrap().len(),
        1,
        "inbox acceptance should arm the next telegram turn exactly once"
    );

    let blocked_again = run_turn_expect_error(&mut telegram, "blocked again").await;
    assert!(
        blocked_again.contains("Daily cost cap of $0.00 reached"),
        "override should be consumed after one turn"
    );

    let approval = parse_pending_approval(&paths, "telegram-cap", &approval_id);
    assert_eq!(approval.status, "accepted");
    assert_eq!(approval.kind.as_deref(), Some("cost-cap-override"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn job_confirm_creates_inbox_item_and_accept_retries_job() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                "<tool_call>{\"name\":\"process_exec\",\"input\":{\"program\":\"/bin/echo\",\"args\":[\"hello\"]}}</tool_call>",
            ),
            scripted("first run adapted"),
            scripted("job recovered"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut jobs = wait_for_client(&paths).await;
    jobs.attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    jobs.upsert_job(sample_job("approval-job", "every 1h", "run it"))
        .await
        .expect("job should upsert");

    let first_run = jobs
        .run_job("approval-job")
        .await
        .expect("initial job run should complete");

    let mut cli = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("cli should connect");
    let approvals = cli
        .list_inbox(None, Some("job-approval".into()), false)
        .await
        .expect("job approvals should load");
    assert_eq!(approvals.len(), 1);
    let approval_id = approvals[0].id.clone();
    let approval_session = approvals[0].session_id.clone();
    assert_eq!(approvals[0].sender, "approval-job");

    let resolved = cli
        .resolve_inbox_approval(&approval_id, true, Some("retry it".into()))
        .await
        .expect("job approval should resolve");
    assert!(resolved.resumed_live_turn);

    let status = wait_for_job_rerun(&mut jobs, "approval-job", &first_run.run_id).await;
    assert_eq!(status.state.last_outcome.as_deref(), Some("success"));

    let approval = parse_pending_approval(&paths, &approval_session, &approval_id);
    assert_eq!(approval.status, "accepted");
    assert_eq!(approval.kind.as_deref(), Some("job-approval"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn active_session_cannot_be_forgotten() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should boot");

    let mut active = wait_for_client(&paths).await;
    active
        .attach(ChannelKind::Repl, Some("active-session".into()))
        .await
        .expect("attach should succeed");

    let mut other = wait_for_client(&paths).await;
    let err = other
        .forget_session("active-session")
        .await
        .expect_err("active session forget should fail");
    assert!(
        err.to_string().contains("cannot forget active session"),
        "unexpected error: {err}"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn old_sessions_are_archived_when_daemon_starts() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("FIRST_PASS")])),
    )
    .await
    .expect("daemon should boot");

    {
        let mut client = wait_for_client(&paths).await;
        client
            .attach(ChannelKind::Repl, Some("archive-me".into()))
            .await
            .expect("attach should succeed");
        let _ = run_turn_collect_messages(&mut client, "archive this session").await;
    }

    shutdown_daemon(handle, &paths).await;

    let meta_path = paths.sessions.join("archive-me").join("meta.json");
    let mut meta: serde_json::Value =
        serde_json::from_slice(&std::fs::read(&meta_path).expect("session meta should exist"))
            .expect("meta should parse");
    meta["last_activity_at"] = serde_json::Value::String("2000-01-01T00:00:00Z".into());
    std::fs::write(
        &meta_path,
        serde_json::to_vec_pretty(&meta).expect("meta should serialize"),
    )
    .expect("old meta should be written");

    let restarted = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should restart");

    assert!(
        paths.sessions_archive.join("archive-me").exists(),
        "expired session should move to archive"
    );
    assert!(
        !paths.sessions.join("archive-me").exists(),
        "expired session should leave the active sessions directory"
    );

    shutdown_daemon(restarted, &paths).await;
}

#[tokio::test]
async fn daily_cost_cap_blocks_turns_and_override_allows_next_turn_once() {
    let home = TempHome::new();
    let paths = home.paths();
    let mut config = sample_config();
    config.limits.daily_usd_cap = Some(0.0);
    let requests = Arc::new(Mutex::new(Vec::new()));
    let handle = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![scripted("OVERRIDE_OK")],
            requests.clone(),
        )),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, Some("cap-session".into()))
        .await
        .expect("attach should succeed");

    let blocked = run_turn_expect_error(&mut client, "first blocked turn").await;
    assert!(
        blocked.contains("Daily cost cap of $0.00 reached"),
        "unexpected refusal: {blocked}"
    );
    assert_eq!(
        requests.lock().unwrap().len(),
        0,
        "blocked turn should not reach the model"
    );

    client
        .set_cost_override("release smoke".into())
        .await
        .expect("override should arm");
    let _messages = run_turn_collect_messages(&mut client, "override turn").await;
    assert_eq!(
        requests.lock().unwrap().len(),
        1,
        "override should allow exactly one turn through"
    );

    let blocked_again = run_turn_expect_error(&mut client, "blocked again").await;
    assert!(
        blocked_again.contains("Daily cost cap of $0.00 reached"),
        "unexpected refusal: {blocked_again}"
    );
    assert_eq!(
        requests.lock().unwrap().len(),
        1,
        "override should be consumed after one turn"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn channel_runtime_statuses_report_builtin_and_telegram_state() {
    let home = TempHome::new();
    let paths = home.paths();
    let mut config = sample_config();
    config.channels.telegram.enabled = true;
    let handle = spawn(config, paths.clone())
        .await
        .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    sleep(Duration::from_millis(100)).await;
    let statuses = client
        .list_channel_runtimes()
        .await
        .expect("channel runtimes should load");

    let repl = statuses
        .iter()
        .find(|status| status.kind == ChannelKind::Repl)
        .expect("repl runtime should exist");
    assert!(repl.running);
    assert_eq!(repl.queue_depth, None);
    assert_eq!(repl.last_error, None);

    let telegram = statuses
        .iter()
        .find(|status| status.kind == ChannelKind::Telegram)
        .expect("telegram runtime should exist");
    assert!(!telegram.running);
    assert_eq!(telegram.queue_depth, Some(0));
    assert!(
        telegram
            .last_error
            .as_deref()
            .unwrap_or_default()
            .contains("missing Telegram bot token"),
        "unexpected telegram runtime status: {:?}",
        telegram.last_error
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn jobs_report_cap_reached_when_daily_cost_cap_blocks_execution() {
    let home = TempHome::new();
    let paths = home.paths();
    let mut config = jobs_test_config();
    config.limits.daily_usd_cap = Some(0.0);
    let handle = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("UNUSED")])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    let _ = client
        .upsert_job(sample_job(
            "daily-cap-test",
            "@daily at 09:00",
            "run the job",
        ))
        .await
        .expect("job should upsert");
    let run = client
        .run_job("daily-cap-test")
        .await
        .expect("job run should return a record");
    assert_eq!(run.outcome, "cap-reached");
    assert!(run
        .stop_reason
        .as_deref()
        .unwrap_or_default()
        .contains("Daily cost cap of $0.00 reached"));

    let status = client
        .get_job("daily-cap-test")
        .await
        .expect("job status should load");
    assert_eq!(status.state.last_outcome.as_deref(), Some("cap-reached"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn job_budget_frontmatter_persists_and_time_budget_limits_run() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(ProbeFactory::new(
            1100,
            "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"Slow run summary\",\"kind\":\"job_summary\",\"summary\":\"Slow summary\"}}</tool_call>",
        )),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    let mut definition = sample_job("budgeted-job", "every 1h", "do a slow staged summary");
    definition.budget = Some(JobBudgetPayload {
        max_turn_usd: Some(0.25),
        max_turn_s: Some(1),
    });
    client
        .upsert_job(definition)
        .await
        .expect("job should upsert");

    let persisted = std::fs::read_to_string(paths.jobs_definitions.join("budgeted-job.md"))
        .expect("definition should persist");
    assert!(persisted.contains("budget:"));
    assert!(persisted.contains("max_turn_usd: 0.250000"));
    assert!(persisted.contains("max_turn_s: 1"));

    let run = client
        .run_job("budgeted-job")
        .await
        .expect("job run should return a record");
    assert_eq!(run.outcome, "limit");
    assert_eq!(
        run.stop_reason.as_deref(),
        Some("budget-exhausted: turn time budget exhausted")
    );

    let status = client
        .get_job("budgeted-job")
        .await
        .expect("job status should load");
    assert_eq!(status.state.last_outcome.as_deref(), Some("limit"));
    assert_eq!(
        status.state.last_stop_reason.as_deref(),
        Some("budget-exhausted: turn time budget exhausted")
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn job_session_name_shares_ephemeral_and_stages_job_summaries() {
    let home = TempHome::new();
    let paths = home.paths();
    std::fs::create_dir_all(&paths.memory_notes).expect("notes dir should exist");
    std::fs::write(
        paths.memory_notes.join("ops.md"),
        "# Ops\n\nDurableClueAlpha belongs to durable memory.\n",
    )
    .expect("note should write");

    let requests = Arc::new(Mutex::new(Vec::new()));
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::with_requests(
            vec![
                scripted(concat!(
                    "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"Run one summary\",\"kind\":\"job_summary\",\"summary\":\"Job summary one\"}}</tool_call>"
                )),
                scripted("JOB_DONE_1"),
                scripted(concat!(
                    "<tool_call>{\"name\":\"stage_memory\",\"input\":{\"content\":\"Run two summary\",\"kind\":\"job_summary\",\"summary\":\"Job summary two\"}}</tool_call>"
                )),
                scripted("JOB_DONE_2"),
            ],
            requests.clone(),
        )),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    let mut definition = sample_job(
        "shared-memory-job",
        "every 1h",
        "review DurableClueAlpha and summarize the run",
    );
    definition.session_name = Some("shared-nightly".into());
    definition.memory_prefetch = Some(false);
    client
        .upsert_job(definition)
        .await
        .expect("job should upsert");

    client
        .run_job("shared-memory-job")
        .await
        .expect("first run should succeed");
    client
        .run_job("shared-memory-job")
        .await
        .expect("second run should succeed");

    let staged = allbert_kernel::memory::list_staged_memory(
        &paths,
        &allbert_kernel::MemoryConfig::default(),
        Some("job_summary"),
        None,
        Some(10),
    )
    .expect("staged entries should list");
    assert_eq!(staged.len(), 2);
    assert!(staged.iter().all(|entry| entry.kind == "job_summary"));
    assert!(staged.iter().all(|entry| entry.source == "job"));

    let recorded = requests.lock().unwrap();
    assert!(recorded.len() >= 3);
    assert!(
        !recorded[0]
            .system
            .as_deref()
            .unwrap_or_default()
            .contains("## Retrieved memory"),
        "job memory.prefetch=false should suppress automatic durable prefetch"
    );
    assert!(
        recorded[2]
            .system
            .as_deref()
            .unwrap_or_default()
            .contains("JOB_DONE_1"),
        "shared job session should carry ephemeral memory into the next run"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn interactive_session_can_upsert_and_inspect_jobs_via_prompt_tools() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                concat!(
                    "<tool_call>{\"name\":\"upsert_job\",\"input\":",
                    "{\"name\":\"prompt-daily-review\",\"description\":\"Prompt-created daily review\",",
                    "\"schedule\":\"@daily at 07:00\",\"timezone\":\"America/Los_Angeles\",",
                    "\"allowed_tools\":[\"read_memory\"],\"prompt\":\"Review yesterday and suggest next steps.\"}}",
                    "</tool_call>",
                    "<tool_call>{\"name\":\"get_job\",\"input\":{\"name\":\"prompt-daily-review\"}}</tool_call>"
                ),
            ),
            scripted("saved and inspected"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    let (messages, confirms) = run_turn_with_confirms(
        &mut client,
        "schedule a daily review",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(
        confirms.len(),
        1,
        "upsert should require exactly one confirm"
    );
    assert_eq!(confirms[0].program, "upsert_job");
    assert!(confirms[0].rendered.contains("durable job change preview"));
    assert!(confirms[0]
        .rendered
        .contains("action:            create recurring job"));
    assert!(confirms[0]
        .rendered
        .contains("name:              prompt-daily-review"));
    assert!(confirms[0]
        .rendered
        .contains("schedule:          @daily at 07:00"));
    assert!(confirms[0]
        .rendered
        .contains("Review yesterday and suggest next steps."));
    let mut saw_upsert = false;
    let mut saw_get = false;
    for message in messages {
        if let ServerMessage::Event(KernelEventPayload::ToolResult { name, ok, content }) = message
        {
            if name == "upsert_job" {
                assert!(ok, "upsert_job should succeed: {content}");
                assert!(content.contains("\"name\": \"prompt-daily-review\""));
                saw_upsert = true;
            }
            if name == "get_job" {
                assert!(ok, "get_job should succeed: {content}");
                assert!(content.contains("\"schedule\": \"@daily at 07:00\""));
                saw_get = true;
            }
        }
    }
    assert!(saw_upsert);
    assert!(saw_get);

    let status = client
        .get_job("prompt-daily-review")
        .await
        .expect("job should exist");
    assert_eq!(status.definition.name, "prompt-daily-review");
    assert_eq!(
        status.definition.timezone.as_deref(),
        Some("America/Los_Angeles")
    );
    assert_eq!(status.definition.allowed_tools, vec!["read_memory"]);

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn interactive_session_can_list_pause_resume_and_remove_jobs_via_prompt_tools() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted("<tool_call>{\"name\":\"list_jobs\",\"input\":{}}</tool_call>"),
            scripted("listed"),
            scripted("<tool_call>{\"name\":\"pause_job\",\"input\":{\"name\":\"weekly-review\"}}</tool_call>"),
            scripted("paused"),
            scripted("<tool_call>{\"name\":\"resume_job\",\"input\":{\"name\":\"weekly-review\"}}</tool_call>"),
            scripted("resumed"),
            scripted("<tool_call>{\"name\":\"remove_job\",\"input\":{\"name\":\"weekly-review\"}}</tool_call>"),
            scripted("removed"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client
        .upsert_job(sample_job(
            "weekly-review",
            "every 1h",
            "review weekly work",
        ))
        .await
        .expect("job should upsert");

    let list_messages = run_turn_collect_messages(&mut client, "what jobs do I have?").await;
    assert!(list_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "list_jobs" && content.contains("weekly-review")
    )));

    let (pause_messages, pause_confirms) = run_turn_with_confirms(
        &mut client,
        "pause weekly review",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(pause_confirms.len(), 1, "pause should require confirm");
    assert_eq!(pause_confirms[0].program, "pause_job");
    assert!(pause_confirms[0]
        .rendered
        .contains("action:            pause recurring job"));
    assert!(pause_confirms[0]
        .rendered
        .contains("name:              weekly-review"));
    assert!(pause_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, .. })
            if name == "pause_job"
    )));
    let paused = client
        .get_job("weekly-review")
        .await
        .expect("paused job should exist");
    assert!(paused.state.paused);

    let (resume_messages, resume_confirms) = run_turn_with_confirms(
        &mut client,
        "resume weekly review",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(resume_confirms.len(), 1, "resume should require confirm");
    assert_eq!(resume_confirms[0].program, "resume_job");
    assert!(resume_confirms[0]
        .rendered
        .contains("action:            resume recurring job"));
    assert!(resume_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, .. })
            if name == "resume_job"
    )));
    let resumed = client
        .get_job("weekly-review")
        .await
        .expect("resumed job should exist");
    assert!(!resumed.state.paused);

    let (remove_messages, remove_confirms) = run_turn_with_confirms(
        &mut client,
        "remove weekly review",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(remove_confirms.len(), 1, "remove should require confirm");
    assert_eq!(remove_confirms[0].program, "remove_job");
    assert!(remove_confirms[0]
        .rendered
        .contains("action:            remove recurring job"));
    assert!(remove_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "remove_job" && content.contains("\"removed\": \"weekly-review\"")
    )));
    let err = client
        .get_job("weekly-review")
        .await
        .expect_err("removed job should no longer exist");
    assert!(matches!(err, DaemonError::Protocol(_)));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn interactive_session_can_run_jobs_and_inspect_recent_runs_via_prompt_tools() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                concat!(
                    "<tool_call>{\"name\":\"run_job\",\"input\":{\"name\":\"manual-check\"}}</tool_call>",
                    "<tool_call>{\"name\":\"list_job_runs\",\"input\":{\"name\":\"manual-check\",\"limit\":5}}</tool_call>"
                ),
            ),
            scripted("job body completed"),
            scripted("ran and inspected"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client
        .upsert_job(sample_job(
            "manual-check",
            "every 1h",
            "perform manual check",
        ))
        .await
        .expect("job should upsert");

    let messages = run_turn_collect_messages(&mut client, "run the manual check job now").await;
    let mut saw_run = false;
    let mut saw_history = false;
    for message in messages {
        if let ServerMessage::Event(KernelEventPayload::ToolResult { name, ok, content }) = message
        {
            if name == "run_job" {
                assert!(ok, "run_job should succeed: {content}");
                assert!(content.contains("\"job_name\": \"manual-check\""));
                saw_run = true;
            }
            if name == "list_job_runs" {
                assert!(ok, "list_job_runs should succeed: {content}");
                assert!(content.contains("\"job_name\": \"manual-check\""));
                saw_history = true;
            }
        }
    }
    assert!(saw_run);
    assert!(saw_history);

    let status = client
        .get_job("manual-check")
        .await
        .expect("job should still exist");
    assert_eq!(status.state.last_outcome.as_deref(), Some("success"));
    assert!(status.state.last_run_id.is_some());

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn conversational_job_management_smoke_stays_within_prompt_and_job_tools() {
    let home = TempHome::new();
    let paths = home.paths();
    let failing_prompt = "Run the daily review and intentionally fail for smoke coverage.";
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::with_failing_prompts(
            vec![
                scripted(
                    concat!(
                        "<tool_call>{\"name\":\"upsert_job\",\"input\":",
                        "{\"name\":\"daily-review\",\"description\":\"Daily review job\",",
                        "\"schedule\":\"@daily at 07:00\",\"timezone\":\"America/Los_Angeles\",",
                        "\"allowed_tools\":[\"read_memory\"],",
                        "\"prompt\":\"Run the daily review and intentionally fail for smoke coverage.\"}}",
                        "</tool_call>"
                    ),
                ),
                scripted("Scheduled the daily review."),
                scripted("<tool_call>{\"name\":\"list_jobs\",\"input\":{}}</tool_call>"),
                scripted("You have one recurring job."),
                scripted("<tool_call>{\"name\":\"run_job\",\"input\":{\"name\":\"daily-review\"}}</tool_call>"),
                scripted("I ran it and it failed."),
                scripted(
                    concat!(
                        "<tool_call>{\"name\":\"get_job\",\"input\":{\"name\":\"daily-review\"}}</tool_call>",
                        "<tool_call>{\"name\":\"list_job_runs\",\"input\":{\"name\":\"daily-review\",\"only_failures\":true,\"limit\":5}}</tool_call>"
                    ),
                ),
                scripted("It failed because the scheduled run hit a simulated provider failure."),
                scripted("<tool_call>{\"name\":\"pause_job\",\"input\":{\"name\":\"daily-review\"}}</tool_call>"),
                scripted("Paused it."),
                scripted("<tool_call>{\"name\":\"resume_job\",\"input\":{\"name\":\"daily-review\"}}</tool_call>"),
                scripted("Resumed it."),
                scripted("<tool_call>{\"name\":\"remove_job\",\"input\":{\"name\":\"daily-review\"}}</tool_call>"),
                scripted("Removed it."),
            ],
            vec![failing_prompt],
        )),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    let (schedule_messages, schedule_confirms) = run_turn_with_confirms(
        &mut client,
        "schedule a daily review at 07:00",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(schedule_confirms.len(), 1);
    assert_eq!(schedule_confirms[0].program, "upsert_job");
    assert!(schedule_confirms[0]
        .rendered
        .contains("schedule:          @daily at 07:00"));
    let schedule_tools = tool_call_names(&schedule_messages);
    assert_eq!(schedule_tools, vec!["upsert_job".to_string()]);

    let list_messages = run_turn_collect_messages(&mut client, "what jobs do I have?").await;
    let list_tools = tool_call_names(&list_messages);
    assert_eq!(list_tools, vec!["list_jobs".to_string()]);
    assert!(list_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "list_jobs" && content.contains("daily-review")
    )));

    let run_messages = run_turn_collect_messages(&mut client, "run it now").await;
    let run_tools = tool_call_names(&run_messages);
    assert_eq!(run_tools, vec!["run_job".to_string()]);
    assert!(run_messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "run_job" && content.contains("\"job_name\": \"daily-review\"")
    )));
    let failed_status = client
        .get_job("daily-review")
        .await
        .expect("job should exist after failed run");
    assert_eq!(failed_status.state.last_outcome.as_deref(), Some("failure"));
    assert!(failed_status
        .state
        .last_stop_reason
        .as_deref()
        .unwrap_or_default()
        .contains("simulated failure"));

    let why_messages = run_turn_collect_messages(&mut client, "why did that job fail?").await;
    let why_tools = tool_call_names(&why_messages);
    assert_eq!(
        why_tools,
        vec!["get_job".to_string(), "list_job_runs".to_string()]
    );
    assert!(why_messages.iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "get_job"
                && content.contains("\"last_outcome\": \"failure\"")
                && content.contains("simulated failure")
    )));
    assert!(why_messages.iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "list_job_runs"
                && content.contains("\"job_name\": \"daily-review\"")
                && content.contains("simulated failure")
    )));

    let (pause_messages, pause_confirms) =
        run_turn_with_confirms(&mut client, "pause it", ConfirmDecisionPayload::AllowOnce).await;
    assert_eq!(pause_confirms.len(), 1);
    assert_eq!(pause_confirms[0].program, "pause_job");
    assert_eq!(
        tool_call_names(&pause_messages),
        vec!["pause_job".to_string()]
    );
    assert!(
        client
            .get_job("daily-review")
            .await
            .expect("paused job should exist")
            .state
            .paused
    );

    let (resume_messages, resume_confirms) =
        run_turn_with_confirms(&mut client, "resume it", ConfirmDecisionPayload::AllowOnce).await;
    assert_eq!(resume_confirms.len(), 1);
    assert_eq!(resume_confirms[0].program, "resume_job");
    assert_eq!(
        tool_call_names(&resume_messages),
        vec!["resume_job".to_string()]
    );
    assert!(
        !client
            .get_job("daily-review")
            .await
            .expect("resumed job should exist")
            .state
            .paused
    );

    let (remove_messages, remove_confirms) =
        run_turn_with_confirms(&mut client, "delete it", ConfirmDecisionPayload::AllowOnce).await;
    assert_eq!(remove_confirms.len(), 1);
    assert_eq!(remove_confirms[0].program, "remove_job");
    assert_eq!(
        tool_call_names(&remove_messages),
        vec!["remove_job".to_string()]
    );
    let err = client
        .get_job("daily-review")
        .await
        .expect_err("removed job should no longer exist");
    assert!(matches!(err, DaemonError::Protocol(_)));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn interactive_job_mutation_denial_does_not_persist() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(concat!(
                "<tool_call>{\"name\":\"upsert_job\",\"input\":",
                "{\"name\":\"denied-daily-review\",\"description\":\"Denied review\",",
                "\"schedule\":\"@daily at 08:00\",\"timezone\":\"America/Los_Angeles\",",
                "\"prompt\":\"Do not persist this.\"}}",
                "</tool_call>"
            )),
            scripted("okay, I did not save it"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");

    let (messages, confirms) = run_turn_with_confirms(
        &mut client,
        "schedule something but deny it",
        ConfirmDecisionPayload::Deny,
    )
    .await;
    assert_eq!(confirms.len(), 1, "denied mutation should still prompt");
    assert_eq!(confirms[0].program, "upsert_job");
    assert!(messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: false, content })
            if name == "upsert_job" && content.contains("job mutation denied by user")
    )));

    let err = client
        .get_job("denied-daily-review")
        .await
        .expect_err("denied job should not exist");
    assert!(matches!(err, DaemonError::Protocol(_)));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn durable_job_mutations_still_prompt_when_session_auto_confirm_is_enabled() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(
                concat!(
                    "<tool_call>{\"name\":\"upsert_job\",\"input\":",
                    "{\"name\":\"auto-confirm-job\",\"description\":\"Auto confirm should not bypass\",",
                    "\"schedule\":\"every 2h\",\"timezone\":\"America/Los_Angeles\",",
                    "\"prompt\":\"Verify durable confirmation.\"}}",
                    "</tool_call>"
                ),
            ),
            scripted("saved after explicit confirm"),
        ])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Repl, None)
        .await
        .expect("attach should succeed");
    client
        .set_auto_confirm(true)
        .await
        .expect("auto confirm should enable");

    let (messages, confirms) = run_turn_with_confirms(
        &mut client,
        "schedule with auto confirm still on",
        ConfirmDecisionPayload::AllowOnce,
    )
    .await;
    assert_eq!(confirms.len(), 1, "durable mutation should still prompt");
    assert_eq!(confirms[0].program, "upsert_job");
    assert!(messages.into_iter().any(|message| matches!(
        message,
        ServerMessage::Event(KernelEventPayload::ToolResult { name, ok: true, content })
            if name == "upsert_job" && content.contains("\"name\": \"auto-confirm-job\"")
    )));

    let persisted = client
        .get_job("auto-confirm-job")
        .await
        .expect("job should persist after explicit confirm");
    assert_eq!(persisted.definition.schedule, "every 2h");

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn jobs_can_be_upserted_updated_and_swept_when_due() {
    let home = TempHome::new();
    let paths = home.paths();
    write_heartbeat(
        &paths,
        "---\nversion: 1\ntimezone: UTC\nprimary_channel: telegram\nquiet_hours: []\ncheck_ins:\n  daily_brief:\n    enabled: true\n    time: \"09:00\"\n    channel: telegram\n  weekly_review:\n    enabled: false\ninbox_nag:\n  enabled: false\n  cadence: off\n  channel: telegram\n---\n\n# HEARTBEAT\n",
    );
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("job completed")])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    let created = client
        .upsert_job(sample_job(
            "daily-brief",
            "once at 2026-04-19T10:00:00Z",
            "summarize",
        ))
        .await
        .expect("job should upsert");
    assert_eq!(created.definition.name, "daily-brief");

    let mut updated_job = sample_job(
        "daily-brief",
        "once at 2026-04-19T11:00:00Z",
        "summarize again",
    );
    updated_job.description = "updated description".into();
    let updated = client
        .upsert_job(updated_job)
        .await
        .expect("job should update");
    assert_eq!(updated.definition.description, "updated description");
    assert_eq!(updated.definition.schedule, "once at 2026-04-19T11:00:00Z");

    let before_due = client
        .sweep_jobs(Some("2026-04-19T10:30:00Z".into()))
        .await
        .expect("early sweep should succeed");
    assert!(before_due.is_empty());

    let runs = client
        .sweep_jobs(Some("2026-04-19T11:05:00Z".into()))
        .await
        .expect("due sweep should succeed");
    assert_eq!(runs.len(), 1);
    assert_eq!(runs[0].job_name, "daily-brief");
    assert_eq!(runs[0].outcome, "success");

    let status = client
        .get_job("daily-brief")
        .await
        .expect("job status should load");
    assert!(
        status.state.paused,
        "one-shot jobs should pause after running"
    );
    assert!(status.state.last_run_at.is_some());
    assert!(status.state.next_due_at.is_none());

    let run_log_date = &runs[0].started_at[..10];
    let run_log = std::fs::read_to_string(paths.jobs_runs.join(format!("{run_log_date}.jsonl")))
        .expect("job run log should be written");
    assert!(run_log.contains("\"job_name\":\"daily-brief\""));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn scheduled_daily_brief_is_skipped_without_heartbeat_opt_in() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("unused")])),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    client
        .upsert_job(sample_job(
            "daily-brief",
            "once at 2026-04-19T11:00:00Z",
            "summarize",
        ))
        .await
        .expect("job should upsert");

    let runs = client
        .sweep_jobs(Some("2026-04-19T11:05:00Z".into()))
        .await
        .expect("due sweep should succeed");
    assert!(
        runs.is_empty(),
        "daily-brief should stay gated until HEARTBEAT.md opts it in"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn paused_jobs_persist_across_daemon_restart_and_can_resume() {
    let home = TempHome::new();
    let paths = home.paths();
    let config = jobs_test_config();
    let handle = spawn_with_factory(
        config.clone(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    client
        .upsert_job(sample_job("weekly-review", "every 1h", "review work"))
        .await
        .expect("job should upsert");
    let paused = client
        .pause_job("weekly-review")
        .await
        .expect("pause should succeed");
    assert!(paused.state.paused);

    shutdown_daemon(handle, &paths).await;

    let restarted = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should restart");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    let reloaded = client
        .get_job("weekly-review")
        .await
        .expect("job should reload after restart");
    assert!(reloaded.state.paused);
    assert_eq!(reloaded.definition.prompt, "review work");

    let resumed = client
        .resume_job("weekly-review")
        .await
        .expect("resume should succeed");
    assert!(!resumed.state.paused);
    assert!(resumed.state.next_due_at.is_some());

    shutdown_daemon(restarted, &paths).await;
}

#[tokio::test]
async fn timezone_resolution_prefers_job_override_then_default_timezone() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    let now = Utc::now();

    let mut east = sample_job("east-coast-brief", "@daily at 09:00", "brief");
    east.timezone = Some("America/New_York".into());
    let east = client.upsert_job(east).await.expect("job should upsert");
    let east_due = chrono::DateTime::parse_from_rfc3339(
        east.state
            .next_due_at
            .as_deref()
            .expect("next due should exist"),
    )
    .expect("next due should parse")
    .with_timezone(&Utc);
    let expected_east = next_daily_due(now, "America/New_York", 9, 0);
    assert!(
        (east_due - expected_east).num_seconds().abs() <= 5,
        "east due mismatch: got {east_due}, expected {expected_east}"
    );

    let west = client
        .upsert_job(sample_job("default-zone-brief", "@daily at 09:00", "brief"))
        .await
        .expect("job should upsert");
    let west_due = chrono::DateTime::parse_from_rfc3339(
        west.state
            .next_due_at
            .as_deref()
            .expect("next due should exist"),
    )
    .expect("next due should parse")
    .with_timezone(&Utc);
    let expected_west = next_daily_due(now, "America/Los_Angeles", 9, 0);
    assert!(
        (west_due - expected_west).num_seconds().abs() <= 5,
        "west due mismatch: got {west_due}, expected {expected_west}"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn missed_intervals_coalesce_into_one_catch_up_run() {
    let home = TempHome::new();
    let paths = home.paths();
    let config = jobs_test_config();
    let handle = spawn_with_factory(
        config.clone(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    client
        .upsert_job(sample_job("memory-compile", "every 1h", "compile memory"))
        .await
        .expect("job should upsert");

    std::fs::write(
        paths.jobs_state.join("memory-compile.json"),
        r#"{
  "paused": false,
  "last_run_at": "2026-04-19T09:00:00Z",
  "next_due_at": "2026-04-19T10:00:00Z",
  "failure_streak": 0
}"#,
    )
    .expect("state file should be writable");

    shutdown_daemon(handle, &paths).await;

    let restarted = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted("compiled")])),
    )
    .await
    .expect("daemon should restart");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    let runs = client
        .sweep_jobs(Some("2026-04-19T13:05:00Z".into()))
        .await
        .expect("catch-up sweep should succeed");
    assert_eq!(
        runs.len(),
        1,
        "missed intervals should coalesce into one run"
    );
    assert_eq!(runs[0].job_name, "memory-compile");

    let status = client
        .get_job("memory-compile")
        .await
        .expect("job should still exist");
    let next_due = chrono::DateTime::parse_from_rfc3339(
        status
            .state
            .next_due_at
            .as_deref()
            .expect("next due should exist"),
    )
    .expect("next due should parse")
    .with_timezone(&Utc);
    assert!(
        next_due > Utc::now(),
        "next due should advance into the future"
    );

    shutdown_daemon(restarted, &paths).await;
}

#[tokio::test]
async fn due_jobs_run_concurrently_up_to_limit_and_defer_excess() {
    let home = TempHome::new();
    let paths = home.paths();
    let probe = ProbeFactory::new(150, "scheduler done");
    let handle = spawn_with_factory(jobs_test_config(), paths.clone(), Arc::new(probe.clone()))
        .await
        .expect("daemon should boot");

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");

    for name in ["alpha", "bravo", "charlie"] {
        client
            .upsert_job(sample_job(name, "once at 2026-04-19T10:00:00Z", "run it"))
            .await
            .expect("job should upsert");
    }

    let first_batch = client
        .sweep_jobs(Some("2026-04-19T10:05:00Z".into()))
        .await
        .expect("first sweep should succeed");
    assert_eq!(
        first_batch.len(),
        2,
        "only two jobs should run in the first batch"
    );
    assert_eq!(
        probe.max_seen(),
        2,
        "scheduler should honor max_concurrent_runs"
    );

    let second_batch = client
        .sweep_jobs(Some("2026-04-19T10:05:00Z".into()))
        .await
        .expect("second sweep should succeed");
    assert_eq!(
        second_batch.len(),
        1,
        "deferred due job should run on the next sweep"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn running_job_is_not_reentered_while_it_is_still_active() {
    let home = TempHome::new();
    let paths = home.paths();
    let probe = ProbeFactory::new(250, "still running");
    let handle = spawn_with_factory(jobs_test_config(), paths.clone(), Arc::new(probe))
        .await
        .expect("daemon should boot");

    let mut setup_client = wait_for_client(&paths).await;
    setup_client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    setup_client
        .upsert_job(sample_job("repeat-job", "every 1s", "repeat"))
        .await
        .expect("job should upsert");
    drop(setup_client);

    let paths_for_run = paths.clone();
    let runner = tokio::spawn(async move {
        let mut client = DaemonClient::connect(&paths_for_run, ClientKind::Test)
            .await
            .expect("runner should connect");
        client
            .attach(ChannelKind::Jobs, None)
            .await
            .expect("runner should attach");
        client
            .run_job("repeat-job")
            .await
            .expect("manual run should succeed")
    });

    let mut observer = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("observer should connect");
    observer
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("observer should attach");

    let running_status = wait_for_job_running(&mut observer, "repeat-job").await;
    let sweep_at = Utc::now() + ChronoDuration::seconds(2);

    let skipped = observer
        .sweep_jobs(Some(sweep_at.to_rfc3339()))
        .await
        .expect("overlap sweep should succeed");
    assert!(
        skipped.is_empty(),
        "same job should not be reentered while running"
    );

    assert!(
        running_status.state.running,
        "job should still be marked running"
    );
    let status = observer
        .get_job("repeat-job")
        .await
        .expect("job status should load");
    let next_due = chrono::DateTime::parse_from_rfc3339(
        status
            .state
            .next_due_at
            .as_deref()
            .expect("next due should exist"),
    )
    .expect("next due should parse")
    .with_timezone(&Utc);
    assert!(
        next_due > sweep_at,
        "skip-if-running should advance next_due_at into the future"
    );

    runner.await.expect("runner task should join");
    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn bundled_templates_seed_disabled_and_can_produce_expected_output() {
    let home = TempHome::new();
    let paths = home.paths();
    let config = jobs_test_config();
    let target_report = paths.memory.join("projects").join("daily-brief.md");
    let scripted_write = format!(
        "<tool_call>{{\"name\":\"write_memory\",\"input\":{{\"path\":\"projects/daily-brief.md\",\"content\":\"# Daily Brief\\n\\n- One thing to do next.\",\"mode\":\"write\",\"summary\":\"Daily brief report\"}}}}</tool_call>"
    );
    let handle = spawn_with_factory(
        config,
        paths.clone(),
        Arc::new(TestFactory::new(vec![
            scripted(&scripted_write),
            scripted("brief written"),
        ])),
    )
    .await
    .expect("daemon should boot");

    for template_name in [
        "daily-brief.md",
        "weekly-review.md",
        "memory-compile.md",
        "trace-triage.md",
        "system-health-check.md",
    ] {
        let raw = std::fs::read_to_string(paths.jobs_templates.join(template_name))
            .expect("bundled template should exist");
        assert!(
            raw.contains("enabled: false"),
            "{template_name} should ship disabled"
        );
    }

    let trace_triage =
        std::fs::read_to_string(paths.jobs_templates.join("trace-triage.md")).expect("template");
    let system_health =
        std::fs::read_to_string(paths.jobs_templates.join("system-health-check.md"))
            .expect("template");
    let memory_compile =
        std::fs::read_to_string(paths.jobs_templates.join("memory-compile.md")).expect("template");
    assert!(trace_triage.contains("report: on_anomaly"));
    assert!(system_health.contains("report: on_anomaly"));
    assert!(memory_compile.contains("Use stage_memory for candidate durable facts"));
    assert!(!memory_compile.contains("Prefer write_memory for stable facts"));

    let mut daily = parse_template_job(&paths.jobs_templates.join("daily-brief.md"));
    daily.enabled = true;

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    client
        .upsert_job(daily)
        .await
        .expect("template job should upsert");
    drop(client);

    let mut run_client = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("run client should connect");
    run_client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("run client should attach");

    let run = run_client
        .run_job("daily-brief")
        .await
        .expect("template run should succeed");
    assert_eq!(run.outcome, "success");

    let report = std::fs::read_to_string(&target_report).expect("report file should be written");
    assert!(report.contains("# Daily Brief"));

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn bundled_jobs_fail_closed_when_interactive_input_is_required() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(TestFactory::new(vec![scripted(
            "<tool_call>{\"name\":\"request_input\",\"input\":{\"prompt\":\"Need a human\",\"allow_empty\":false}}</tool_call>",
        )])),
    )
    .await
    .expect("daemon should boot");

    let mut job = parse_template_job(&paths.jobs_templates.join("system-health-check.md"));
    job.enabled = true;

    let mut client = wait_for_client(&paths).await;
    client
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    client
        .upsert_job(job)
        .await
        .expect("template job should upsert");
    let run = client
        .run_job("system-health-check")
        .await
        .expect("job run should return a record");
    assert_eq!(run.outcome, "failure");
    assert!(
        run.stop_reason
            .as_deref()
            .unwrap_or_default()
            .contains("no scripted response left"),
        "fail-closed scheduled job should record why it stopped"
    );

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn job_failures_are_broadcast_to_attached_repl_clients() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        sample_config(),
        paths.clone(),
        Arc::new(TestFactory::new(Vec::new())),
    )
    .await
    .expect("daemon should boot");

    let mut repl = wait_for_client(&paths).await;
    repl.attach(ChannelKind::Repl, None)
        .await
        .expect("repl attach should succeed");

    let mut jobs = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("jobs client should connect");
    jobs.attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    jobs.upsert_job(sample_job("failing-job", "every 1h", "trigger a failure"))
        .await
        .expect("job should upsert");

    let run = jobs
        .run_job("failing-job")
        .await
        .expect("manual run should return a record");
    assert_eq!(run.outcome, "failure");

    let notice = timeout(Duration::from_secs(2), repl.recv())
        .await
        .expect("repl should receive a failure notice")
        .expect("repl receive should succeed");
    match notice {
        ServerMessage::Event(KernelEventPayload::JobFailed {
            job_name,
            run_id,
            stop_reason,
            ..
        }) => {
            assert_eq!(job_name, "failing-job");
            assert_eq!(run_id, run.run_id);
            assert!(stop_reason
                .unwrap_or_default()
                .contains("no scripted response left"));
        }
        other => panic!("unexpected notice: {:?}", other),
    }

    shutdown_daemon(handle, &paths).await;
}

#[tokio::test]
async fn daemon_shutdown_interrupts_running_jobs_and_records_them() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn_with_factory(
        jobs_test_config(),
        paths.clone(),
        Arc::new(ProbeFactory::new(1_500, "finished too late")),
    )
    .await
    .expect("daemon should boot");

    let mut jobs = wait_for_client(&paths).await;
    jobs.attach(ChannelKind::Jobs, None)
        .await
        .expect("jobs attach should succeed");
    jobs.upsert_job(sample_job("slow-job", "every 1h", "slow run"))
        .await
        .expect("slow job should upsert");

    let run_task = tokio::spawn(async move { jobs.run_job("slow-job").await });
    sleep(Duration::from_millis(150)).await;

    let mut shutdown_client = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("shutdown client should connect");
    shutdown_client
        .shutdown()
        .await
        .expect("shutdown should be acknowledged");

    let run = run_task
        .await
        .expect("run task should join")
        .expect("run should return a record");
    assert_eq!(run.outcome, "interrupted");
    assert_eq!(run.stop_reason.as_deref(), Some("daemon shutdown"));

    handle.wait().await.expect("daemon should exit");

    let date = &run.started_at[..10];
    let failures = std::fs::read_to_string(paths.jobs_failures.join(format!("{date}.jsonl")))
        .expect("failure log should exist");
    assert!(failures.contains("\"job_name\":\"slow-job\""));
    assert!(failures.contains("\"outcome\":\"interrupted\""));
}

#[tokio::test]
async fn daemon_tick_reconciles_memory_after_operator_note_edits() {
    let home = TempHome::new();
    let paths = home.paths();
    let handle = spawn(sample_config(), paths.clone())
        .await
        .expect("daemon should boot");

    std::fs::write(
        paths.memory_notes.join("postgres.md"),
        "# Postgres\n\nWe use Postgres in production.\n",
    )
    .expect("note should be written");

    timeout(Duration::from_secs(3), async {
        loop {
            let manifest = std::fs::read_to_string(&paths.memory_manifest).unwrap_or_default();
            if manifest.contains("notes/postgres.md") {
                break;
            }
            sleep(Duration::from_millis(100)).await;
        }
    })
    .await
    .expect("daemon tick should reconcile memory within 3s");

    shutdown_daemon(handle, &paths).await;
}
