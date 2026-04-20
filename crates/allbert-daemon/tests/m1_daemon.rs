use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use allbert_daemon::{spawn, spawn_with_factory, DaemonClient, DaemonError, RunningDaemon};
use allbert_kernel::error::LlmError;
use allbert_kernel::llm::{
    CompletionRequest, CompletionResponse, LlmProvider, ProviderFactory, Usage,
};
use allbert_kernel::{AllbertPaths, Config, ModelConfig};
use allbert_proto::{
    ChannelKind, ClientKind, ClientMessage, ConfirmDecisionPayload, InputReplyPayload,
    InputResponsePayload, JobDefinitionPayload, KernelEventPayload, ModelConfigPayload,
    ProviderKind, ServerMessage,
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
}

impl TestFactory {
    fn new(responses: Vec<CompletionResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
            failing_prompts: Arc::new(Vec::new()),
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
        }
    }
}

#[async_trait]
impl ProviderFactory for TestFactory {
    async fn build(&self, _model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
        Ok(Box::new(TestProvider {
            responses: Arc::clone(&self.responses),
            failing_prompts: Arc::clone(&self.failing_prompts),
        }))
    }
}

struct TestProvider {
    responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
    failing_prompts: Arc<Vec<String>>,
}

#[async_trait]
impl LlmProvider for TestProvider {
    async fn complete(&self, req: CompletionRequest) -> Result<CompletionResponse, LlmError> {
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
        prompt: parsed.content.trim().to_string(),
    }
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
        err.to_string().contains("already running"),
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
            api_key_env: "OPENROUTER_API_KEY".into(),
            max_tokens: 4096,
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
    assert_eq!(cli_model.provider, ProviderKind::Anthropic);

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

    sleep(Duration::from_millis(50)).await;

    let mut observer = DaemonClient::connect(&paths, ClientKind::Test)
        .await
        .expect("observer should connect");
    observer
        .attach(ChannelKind::Jobs, None)
        .await
        .expect("observer should attach");

    let skipped = observer
        .sweep_jobs(Some("2026-04-19T12:00:00Z".into()))
        .await
        .expect("overlap sweep should succeed");
    assert!(
        skipped.is_empty(),
        "same job should not be reentered while running"
    );

    let status = observer
        .get_job("repeat-job")
        .await
        .expect("job status should load");
    assert!(status.state.running, "job should still be marked running");
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
    assert!(trace_triage.contains("report: on_anomaly"));
    assert!(system_health.contains("report: on_anomaly"));

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
