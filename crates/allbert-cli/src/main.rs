use std::path::Path;
use std::time::Duration;

use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_jobs::JobsCommand;
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{ChannelKind, ClientKind, DaemonStatus};
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

mod repl;
mod setup;

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert daemon-backed CLI", long_about = None)]
struct Args {
    /// Enable daemon debug logging for the running daemon at ~/.allbert/logs/daemon.debug.log.
    #[arg(long)]
    trace: bool,
    /// Auto-confirm risky actions for the attached daemon-backed session.
    #[arg(short, long)]
    yes: bool,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    Daemon {
        #[command(subcommand)]
        command: DaemonCommand,
    },
    Jobs {
        #[command(subcommand)]
        command: JobsCommand,
    },
}

#[derive(Subcommand, Debug)]
enum DaemonCommand {
    Status,
    Start,
    Stop,
    Restart,
    Logs {
        #[arg(long)]
        debug: bool,
        #[arg(long)]
        follow: bool,
        #[arg(long, default_value_t = 40)]
        lines: usize,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let paths = AllbertPaths::from_home()?;
    let mut config = Config::load_or_create(&paths)?;

    match args.command {
        None => {
            if setup::needs_setup(&config, &paths) {
                config = match setup::run_setup_wizard(&paths, &config)? {
                    Some(updated) => updated,
                    None => {
                        eprintln!(
                            "Setup was cancelled. Rerun Allbert when you're ready to finish setup."
                        );
                        return Ok(());
                    }
                };
            }
            run_repl(&paths, &config, args.trace, args.yes).await
        }
        Some(Command::Jobs { command }) => {
            if setup::needs_setup(&config, &paths) {
                config = match setup::run_setup_wizard(&paths, &config)? {
                    Some(updated) => updated,
                    None => {
                        eprintln!(
                            "Setup was cancelled. Rerun Allbert when you're ready to finish setup."
                        );
                        return Ok(());
                    }
                };
            }
            allbert_jobs::run_command(&paths, &config, command).await
        }
        Some(Command::Daemon { command }) => {
            if matches!(command, DaemonCommand::Start | DaemonCommand::Restart)
                && setup::needs_setup(&config, &paths)
            {
                config = match setup::run_setup_wizard(&paths, &config)? {
                    Some(updated) => updated,
                    None => {
                        eprintln!(
                            "Setup was cancelled. Rerun Allbert when you're ready to finish setup."
                        );
                        return Ok(());
                    }
                };
            }
            run_daemon_command(&paths, &config, command).await
        }
    }
}

async fn run_repl(paths: &AllbertPaths, config: &Config, trace: bool, yes: bool) -> Result<()> {
    let mut effective = config.clone();
    if trace {
        effective.trace = true;
    }
    if yes {
        effective.security.auto_confirm = true;
    }
    setup::print_startup_warnings(&effective);

    let mut client = connect_for_use(paths, config, ClientKind::Repl).await?;
    let attached = client.attach(ChannelKind::Repl, None).await?;
    if trace {
        client.set_trace(true).await?;
    }
    if yes {
        client.set_auto_confirm(true).await?;
    }

    let notifications = spawn_notification_task(paths, attached.session_id.clone()).await;
    tracing::info!(session = attached.session_id, "REPL attached");
    let result = repl::run_loop(&mut client, paths).await;
    if let Some(handle) = notifications {
        handle.abort();
    }
    result
}

async fn run_daemon_command(
    paths: &AllbertPaths,
    config: &Config,
    command: DaemonCommand,
) -> Result<()> {
    match command {
        DaemonCommand::Status => {
            match DaemonClient::connect(paths, ClientKind::Cli).await {
                Ok(mut client) => {
                    let status = client.status().await?;
                    println!("{}", render_running_daemon_status(config, &status));
                }
                Err(_) => {
                    println!("{}", render_stopped_daemon_status(config, paths));
                }
            }
            Ok(())
        }
        DaemonCommand::Start => {
            let mut spawn = default_spawn_config(paths, config)?;
            spawn.wait_timeout = Duration::from_secs(5);
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            println!(
                "{}",
                render_running_daemon_status(config, &client.status().await?)
            );
            Ok(())
        }
        DaemonCommand::Stop => stop_daemon(paths).await,
        DaemonCommand::Restart => {
            let _ = stop_daemon(paths).await;
            let mut spawn = default_spawn_config(paths, config)?;
            spawn.wait_timeout = Duration::from_secs(5);
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            println!(
                "{}",
                render_running_daemon_status(config, &client.status().await?)
            );
            Ok(())
        }
        DaemonCommand::Logs {
            debug,
            follow,
            lines,
        } => {
            let log_path = if debug {
                &paths.daemon_debug_log
            } else {
                &paths.daemon_log
            };
            if follow {
                follow_log(log_path, lines).await
            } else {
                println!(
                    "showing last {} line(s) from {}\n{}",
                    lines,
                    log_path.display(),
                    tail_lines(log_path, lines)?
                );
                Ok(())
            }
        }
    }
}

async fn stop_daemon(paths: &AllbertPaths) -> Result<()> {
    let mut client = match DaemonClient::connect(paths, ClientKind::Cli).await {
        Ok(client) => client,
        Err(_) => {
            println!("daemon is not running");
            return Ok(());
        }
    };
    client.shutdown().await?;
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(100)).await;
        if DaemonClient::connect(paths, ClientKind::Cli).await.is_err() {
            println!("daemon stopped");
            return Ok(());
        }
    }
    anyhow::bail!("daemon shutdown timed out waiting for the local IPC socket to close")
}

async fn connect_for_use(
    paths: &AllbertPaths,
    config: &Config,
    client_kind: ClientKind,
) -> Result<DaemonClient> {
    if config.daemon.auto_spawn {
        let spawn = default_spawn_config(paths, config)?;
        DaemonClient::connect_or_spawn(paths, client_kind, &spawn)
            .await
            .map_err(map_connect_error)
    } else {
        DaemonClient::connect(paths, client_kind)
            .await
            .map_err(|err| anyhow::anyhow!(
                "daemon is not running and auto-spawn is disabled. Start it with `allbert-cli daemon start` or enable daemon.auto_spawn in config.\nunderlying error: {err}"
            ))
    }
}

fn map_connect_error(error: DaemonError) -> anyhow::Error {
    let message = match &error {
        DaemonError::Spawn(message) => format!(
            "failed to auto-spawn the daemon. Make sure the `allbert-daemon` binary exists next to `allbert-cli`.\nunderlying error: {message}"
        ),
        DaemonError::Timeout("daemon auto-spawn") => "daemon auto-spawn timed out. Check for a stale socket, a hung daemon start, or permission drift under ~/.allbert/run.".into(),
        _ => format!("failed to connect to the daemon: {error}"),
    };
    anyhow::anyhow!(message)
}

async fn spawn_notification_task(
    paths: &AllbertPaths,
    session_id: String,
) -> Option<tokio::task::JoinHandle<()>> {
    let mut client = match DaemonClient::connect(paths, ClientKind::Cli).await {
        Ok(client) => client,
        Err(_) => return None,
    };
    if client
        .attach(ChannelKind::Repl, Some(session_id))
        .await
        .is_err()
    {
        return None;
    }
    Some(tokio::spawn(async move {
        loop {
            match client.recv().await {
                Ok(message) => repl::render_async_server_message(message),
                Err(_) => break,
            }
        }
    }))
}

fn render_running_daemon_status(config: &Config, status: &DaemonStatus) -> String {
    format!(
        "daemon:            running\npid:               {}\ndaemon id:         {}\nstarted at:        {}\nsocket:            {}\nsessions:          {}\ntrace enabled:     {}\nauto-spawn:        {}\njobs enabled:      {}\njobs timezone:     {}",
        status.pid,
        status.daemon_id,
        status.started_at,
        status.socket_path,
        status.session_count,
        yes_no(status.trace_enabled),
        yes_no(config.daemon.auto_spawn),
        yes_no(config.jobs.enabled),
        config.jobs.default_timezone.as_deref().unwrap_or("(system local)")
    )
}

fn render_stopped_daemon_status(config: &Config, paths: &AllbertPaths) -> String {
    format!(
        "daemon:            stopped\nsocket:            {}\nauto-spawn:        {}\njobs enabled:      {}\njobs timezone:     {}\nlog dir:           {}",
        paths.daemon_socket.display(),
        yes_no(config.daemon.auto_spawn),
        yes_no(config.jobs.enabled),
        config.jobs.default_timezone.as_deref().unwrap_or("(system local)"),
        paths.logs.display(),
    )
}

fn tail_lines(path: &Path, lines: usize) -> Result<String> {
    if !path.exists() {
        return Ok("(log file does not exist yet)".into());
    }
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let collected = raw
        .lines()
        .rev()
        .take(lines)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<Vec<_>>();
    if collected.is_empty() {
        Ok("(log file is empty)".into())
    } else {
        Ok(collected.join("\n"))
    }
}

async fn follow_log(path: &Path, lines: usize) -> Result<()> {
    println!(
        "following {} (showing last {} line(s) first; press Ctrl-C to stop)\n{}",
        path.display(),
        lines,
        tail_lines(path, lines)?
    );
    let mut last_len = std::fs::metadata(path).map(|meta| meta.len()).unwrap_or(0);
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => return Ok(()),
            _ = tokio::time::sleep(Duration::from_millis(500)) => {
                let Ok(raw) = std::fs::read_to_string(path) else {
                    continue;
                };
                let current_len = raw.len() as u64;
                if current_len <= last_len {
                    continue;
                }
                let start = usize::try_from(last_len).unwrap_or(0).min(raw.len());
                print!("{}", &raw[start..]);
                last_len = current_len;
            }
        }
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}
