use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use allbert_daemon::{spawn, spawn_with_factory, DaemonClient, RunningDaemon};
use allbert_kernel::error::LlmError;
use allbert_kernel::llm::{
    CompletionRequest, CompletionResponse, LlmProvider, ProviderFactory, Usage,
};
use allbert_kernel::{AllbertPaths, Config, ModelConfig};
use allbert_proto::{
    ChannelKind, ClientKind, ClientMessage, ConfirmDecisionPayload, InputReplyPayload,
    InputResponsePayload, KernelEventPayload, ModelConfigPayload, ProviderKind, ServerMessage,
};
use async_trait::async_trait;
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

#[derive(Clone)]
struct TestFactory {
    responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
}

impl TestFactory {
    fn new(responses: Vec<CompletionResponse>) -> Self {
        Self {
            responses: Arc::new(Mutex::new(responses.into())),
        }
    }
}

#[async_trait]
impl ProviderFactory for TestFactory {
    async fn build(&self, _model_config: &ModelConfig) -> Result<Box<dyn LlmProvider>, LlmError> {
        Ok(Box::new(TestProvider {
            responses: Arc::clone(&self.responses),
        }))
    }
}

struct TestProvider {
    responses: Arc<Mutex<VecDeque<CompletionResponse>>>,
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
