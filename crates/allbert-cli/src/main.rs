use std::path::Path;
use std::time::Duration;

use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_jobs::JobsCommand;
use allbert_kernel::{refresh_agents_markdown, AllbertPaths, Config};
use allbert_proto::{ChannelKind, ClientKind, DaemonStatus, SessionResumeEntry};
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

mod memory_cli;
mod repl;
mod setup;
mod skills;

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
    Agents {
        #[command(subcommand)]
        command: AgentsCommand,
    },
    Jobs {
        #[command(subcommand)]
        command: JobsCommand,
    },
    Skills {
        #[command(subcommand)]
        command: SkillsCommand,
    },
    Memory {
        #[command(subcommand)]
        command: MemoryCommand,
    },
    #[command(name = "internal-daemon-host", hide = true)]
    InternalDaemonHost,
}

#[derive(Subcommand, Debug)]
enum AgentsCommand {
    List,
}

#[derive(Subcommand, Debug)]
enum DaemonCommand {
    Status,
    Start,
    Stop,
    Restart,
    Resume {
        #[arg(long)]
        session: Option<String>,
        #[arg(long)]
        list: bool,
    },
    Forget {
        session_id: String,
    },
    Logs {
        #[arg(long)]
        debug: bool,
        #[arg(long)]
        follow: bool,
        #[arg(long, default_value_t = 40)]
        lines: usize,
    },
}

#[derive(Subcommand, Debug)]
enum SkillsCommand {
    /// List installed skills.
    List,
    /// Show one installed skill with its metadata and resources.
    Show { name: String },
    /// Validate a skill tree without installing it.
    Validate { path: String },
    /// Install a skill from a local path or git URL.
    Install { source: String },
    /// Re-fetch and reinstall an existing skill from its recorded source.
    Update { name: String },
    /// Remove one installed skill.
    Remove { name: String },
    /// Scaffold a new strict AgentSkills-format skill in the current directory.
    Init { name: String },
}

#[derive(Subcommand, Debug)]
enum MemoryCommand {
    /// Show curated-memory status for the current profile.
    Status,
    /// Verify manifest/index reconciliation for the current profile.
    Verify,
    /// Search curated memory.
    Search {
        query: String,
        #[arg(long, default_value = "durable")]
        tier: String,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long, default_value = "text")]
        format: String,
    },
    /// Inspect staged-memory entries.
    Staged {
        #[command(subcommand)]
        command: MemoryStagedCommand,
    },
    /// Promote a staged-memory entry into durable notes.
    Promote {
        id: String,
        #[arg(long)]
        path: Option<String>,
        #[arg(long)]
        summary: Option<String>,
        #[arg(long)]
        confirm: bool,
    },
    /// Reject a staged-memory entry.
    Reject {
        id: String,
        #[arg(long)]
        reason: Option<String>,
    },
    /// Forget one or more durable memory entries.
    Forget {
        target: String,
        #[arg(long)]
        confirm: bool,
    },
    /// Rebuild the curated-memory index.
    RebuildIndex {
        #[arg(long)]
        force: bool,
    },
}

#[derive(Subcommand, Debug)]
enum MemoryStagedCommand {
    /// List staged-memory entries.
    List {
        #[arg(long)]
        kind: Option<String>,
        #[arg(long)]
        since: Option<String>,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long, default_value = "text")]
        format: String,
    },
    /// Show one staged-memory entry by id.
    Show { id: String },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    if let Some(Command::Skills {
        command: SkillsCommand::Validate { ref path },
    }) = args.command.as_ref()
    {
        return run_skills_command(None, None, SkillsCommand::Validate { path: path.clone() })
            .await;
    }

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
        Some(Command::InternalDaemonHost) => run_internal_daemon_host().await,
        Some(Command::Skills { command }) => {
            run_skills_command(Some(&paths), Some(&config), command).await
        }
        Some(Command::Memory { command }) => run_memory_command(&paths, &config, command).await,
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
        Some(Command::Agents { command }) => run_agents_command(&paths, &config, command).await,
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

async fn run_memory_command(
    paths: &AllbertPaths,
    config: &Config,
    command: MemoryCommand,
) -> Result<()> {
    match command {
        MemoryCommand::Status => {
            let daemon_active = DaemonClient::connect(paths, ClientKind::Cli).await.is_ok();
            println!("{}", memory_cli::status(paths, config, daemon_active)?);
            Ok(())
        }
        MemoryCommand::Verify => {
            let (rendered, healthy) = memory_cli::verify(paths, config)?;
            println!("{rendered}");
            if !healthy {
                anyhow::bail!("memory verification found unresolved mismatch");
            }
            Ok(())
        }
        MemoryCommand::Search {
            query,
            tier,
            limit,
            format,
        } => {
            println!(
                "{}",
                memory_cli::search(paths, config, &query, &tier, limit, &format)?
            );
            Ok(())
        }
        MemoryCommand::Staged { command } => match command {
            MemoryStagedCommand::List {
                kind,
                since,
                limit,
                format,
            } => {
                println!(
                    "{}",
                    memory_cli::staged_list(
                        paths,
                        config,
                        kind.as_deref(),
                        since.as_deref(),
                        limit,
                        &format,
                    )?
                );
                Ok(())
            }
            MemoryStagedCommand::Show { id } => {
                println!("{}", memory_cli::staged_show(paths, config, &id)?);
                Ok(())
            }
        },
        MemoryCommand::Promote {
            id,
            path,
            summary,
            confirm,
        } => {
            println!(
                "{}",
                memory_cli::promote(
                    paths,
                    config,
                    &id,
                    path.as_deref(),
                    summary.as_deref(),
                    confirm
                )?
            );
            Ok(())
        }
        MemoryCommand::Reject { id, reason } => {
            println!(
                "{}",
                memory_cli::reject(paths, config, &id, reason.as_deref())?
            );
            Ok(())
        }
        MemoryCommand::Forget { target, confirm } => {
            println!("{}", memory_cli::forget(paths, config, &target, confirm)?);
            Ok(())
        }
        MemoryCommand::RebuildIndex { force } => {
            println!("{}", memory_cli::rebuild_index(paths, config, force)?);
            Ok(())
        }
    }
}

async fn run_internal_daemon_host() -> Result<()> {
    let paths = AllbertPaths::from_home()?;
    let config = Config::load_or_create(&paths)?;
    let daemon = allbert_daemon::spawn(config, paths).await?;
    let shutdown = daemon.shutdown_handle();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            shutdown.cancel();
        }
    });
    daemon.wait().await?;
    Ok(())
}

async fn run_agents_command(
    paths: &AllbertPaths,
    _config: &Config,
    command: AgentsCommand,
) -> Result<()> {
    match command {
        AgentsCommand::List => {
            let rendered = refresh_agents_markdown(paths)?;
            println!("{rendered}");
            Ok(())
        }
    }
}

async fn run_skills_command(
    paths: Option<&AllbertPaths>,
    config: Option<&Config>,
    command: SkillsCommand,
) -> Result<()> {
    match command {
        SkillsCommand::List => {
            let paths = paths.context("list requires an initialized Allbert home")?;
            println!("{}", skills::list_installed_skills(paths)?);
            Ok(())
        }
        SkillsCommand::Show { name } => {
            let paths = paths.context("show requires an initialized Allbert home")?;
            println!("{}", skills::show_installed_skill(paths, &name)?);
            Ok(())
        }
        SkillsCommand::Validate { path } => {
            let skill_path = std::path::PathBuf::from(path);
            println!("{}", skills::validate_skill(&skill_path)?);
            Ok(())
        }
        SkillsCommand::Install { source } => {
            let paths = paths.context("install requires an initialized Allbert home")?;
            let config = config.context("install requires loaded config")?;
            let result = skills::install_skill_source_interactive(paths, config, &source)?;
            println!(
                "installed skill {}\npath: {}\ntree sha256: {}\napproval reused: {}",
                result.name,
                result.installed_path.display(),
                result.tree_sha256,
                if result.approval_reused { "yes" } else { "no" }
            );
            Ok(())
        }
        SkillsCommand::Update { name } => {
            let paths = paths.context("update requires an initialized Allbert home")?;
            let config = config.context("update requires loaded config")?;
            let result = skills::update_skill_interactive(paths, config, &name)?;
            println!(
                "updated skill {}\npath: {}\ntree sha256: {}",
                result.name,
                result.installed_path.display(),
                result.tree_sha256,
            );
            Ok(())
        }
        SkillsCommand::Remove { name } => {
            let paths = paths.context("remove requires an initialized Allbert home")?;
            skills::remove_skill_interactive(paths, &name)?;
            println!("removed skill {name}");
            Ok(())
        }
        SkillsCommand::Init { name } => {
            let cwd = std::env::current_dir().context("resolve current directory")?;
            let created = skills::init_skill_interactive(&name, &cwd)?;
            println!("initialized skill scaffold at {}", created.display());
            Ok(())
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
            let spawn = default_spawn_config(paths, config)?;
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
            let spawn = default_spawn_config(paths, config)?;
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            println!(
                "{}",
                render_running_daemon_status(config, &client.status().await?)
            );
            Ok(())
        }
        DaemonCommand::Resume { session, list } => {
            let spawn = default_spawn_config(paths, config)?;
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            let sessions = client.list_sessions().await?;
            if list {
                if sessions.is_empty() {
                    println!("no resumable sessions");
                } else {
                    println!("{}", render_session_resume_list(&sessions));
                }
                return Ok(());
            }

            let target = match session {
                Some(id) => {
                    if sessions.iter().any(|entry| entry.session_id == id) {
                        id
                    } else {
                        anyhow::bail!("session not found: {id}");
                    }
                }
                None => sessions
                    .first()
                    .map(|entry| entry.session_id.clone())
                    .ok_or_else(|| anyhow::anyhow!("no resumable sessions"))?,
            };
            let attached = client
                .attach(ChannelKind::Repl, Some(target.clone()))
                .await?;
            println!("resumed session {}", attached.session_id);
            repl::run_loop(&mut client, paths).await
        }
        DaemonCommand::Forget { session_id } => {
            let spawn = default_spawn_config(paths, config)?;
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            client.forget_session(&session_id).await?;
            println!("forgot session {session_id}");
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

fn render_session_resume_list(entries: &[SessionResumeEntry]) -> String {
    let mut lines = Vec::with_capacity(entries.len() + 1);
    lines.push("resumable sessions:".to_string());
    for entry in entries {
        lines.push(format!(
            "- {}  channel={}  last_active={}  turns={}",
            entry.session_id,
            format!("{:?}", entry.channel).to_ascii_lowercase(),
            entry.last_activity_at,
            entry.turn_count
        ));
    }
    lines.join("\n")
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
