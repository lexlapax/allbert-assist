use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use allbert_daemon::{spawn, DaemonClient, RunningDaemon};
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{ChannelKind, ClientKind};
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
