use std::collections::BTreeSet;
use std::path::Path;
use std::time::Duration;

use allbert_channels::ChannelCapabilities;
use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_jobs::JobsCommand;
use allbert_kernel::{refresh_agents_markdown, AllbertPaths, Config};
use allbert_proto::{ChannelKind, ChannelRuntimeStatusPayload, ClientKind, DaemonStatus};
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde::Serialize;

mod approvals;
mod heartbeat_cli;
mod identity_cli;
mod memory_cli;
mod profile_cli;
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
    Identity {
        #[command(subcommand)]
        command: IdentityCommand,
    },
    Memory {
        #[command(subcommand)]
        command: MemoryCommand,
    },
    Approvals {
        #[command(subcommand)]
        command: ApprovalsCommand,
    },
    Inbox {
        #[command(subcommand)]
        command: InboxCommand,
    },
    Profile {
        #[command(subcommand)]
        command: ProfileCommand,
    },
    Heartbeat {
        #[command(subcommand)]
        command: HeartbeatCommand,
    },
    Sessions {
        #[command(subcommand)]
        command: SessionsCommand,
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
    Channels {
        #[command(subcommand)]
        command: DaemonChannelsCommand,
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
enum IdentityCommand {
    Show,
    AddChannel { kind: String, sender: String },
    RemoveChannel { kind: String, sender: String },
    Rename { new_name: String },
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

#[derive(Subcommand, Debug)]
enum ApprovalsCommand {
    List {
        #[arg(long)]
        json: bool,
    },
    Show {
        approval_id: String,
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand, Debug)]
enum InboxCommand {
    List {
        #[arg(long)]
        json: bool,
        #[arg(long)]
        identity: Option<String>,
        #[arg(long)]
        kind: Option<String>,
        #[arg(long)]
        include_resolved: bool,
    },
    Show {
        approval_id: String,
        #[arg(long)]
        json: bool,
    },
    Accept {
        approval_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
    Reject {
        approval_id: String,
        #[arg(long)]
        reason: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum ProfileCommand {
    Export {
        path: String,
        #[arg(long)]
        include_secrets: bool,
        #[arg(long)]
        identity: Option<String>,
    },
    Import {
        path: String,
        #[arg(long)]
        overlay: bool,
        #[arg(long)]
        replace: bool,
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Subcommand, Debug)]
enum HeartbeatCommand {
    Show,
    Edit,
    Suggest {
        #[arg(long)]
        channel: Option<String>,
    },
}

#[derive(Subcommand, Debug)]
enum SessionsCommand {
    List {
        #[arg(long)]
        identity: Option<String>,
        #[arg(long)]
        channel: Option<String>,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long)]
        json: bool,
    },
    Show {
        session_id: String,
    },
    Resume {
        session_id: String,
    },
    Forget {
        session_id: String,
    },
}

#[derive(Subcommand, Debug)]
enum DaemonChannelsCommand {
    List {
        #[arg(long)]
        json: bool,
    },
    Status {
        kind: Option<String>,
        #[arg(long)]
        json: bool,
    },
    Add {
        kind: String,
        #[arg(long)]
        json: bool,
    },
    Remove {
        kind: String,
        #[arg(long)]
        json: bool,
    },
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
        Some(Command::Identity { command }) => run_identity_command(&paths, command),
        Some(Command::Memory { command }) => run_memory_command(&paths, &config, command).await,
        Some(Command::Approvals { command }) => run_approvals_command(&paths, command),
        Some(Command::Inbox { command }) => run_inbox_command(&paths, command).await,
        Some(Command::Profile { command }) => run_profile_command(&paths, &config, command),
        Some(Command::Heartbeat { command }) => run_heartbeat_command(&paths, command),
        Some(Command::Sessions { command }) => run_sessions_command(&paths, &config, command).await,
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

#[derive(Debug, Clone, Serialize)]
struct SessionListEntry {
    session_id: String,
    identity_id: Option<String>,
    channels: Vec<String>,
    started_at: String,
    last_activity_at: String,
    turn_count: u32,
    pending_approvals: usize,
}

#[derive(Debug, serde::Deserialize)]
struct SessionMetaView {
    session_id: String,
    channel: ChannelKind,
    identity_id: Option<String>,
    started_at: String,
    last_activity_at: String,
    turn_count: u32,
    pending_approvals: Option<Vec<String>>,
    pending_approval: Option<String>,
}

fn load_session_meta(paths: &AllbertPaths, session_id: &str) -> Result<SessionMetaView> {
    let path = paths.sessions.join(session_id).join("meta.json");
    let raw = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_slice(&raw).with_context(|| format!("parse {}", path.display()))
}

fn session_channels(paths: &AllbertPaths, session_id: &str, fallback: ChannelKind) -> Vec<String> {
    let turns_path = paths.sessions.join(session_id).join("turns.md");
    let Ok(raw) = std::fs::read_to_string(turns_path) else {
        return vec![channel_kind_label(fallback).to_string()];
    };
    let mut channels = BTreeSet::new();
    for line in raw.lines() {
        if let Some(rest) = line.strip_prefix("- channel: ") {
            channels.insert(rest.trim().to_string());
        }
    }
    if channels.is_empty() {
        vec![channel_kind_label(fallback).to_string()]
    } else {
        channels.into_iter().collect()
    }
}

fn collect_sessions(paths: &AllbertPaths) -> Result<Vec<SessionListEntry>> {
    let mut sessions = Vec::new();
    if !paths.sessions.exists() {
        return Ok(sessions);
    }
    for entry in std::fs::read_dir(&paths.sessions)
        .with_context(|| format!("read {}", paths.sessions.display()))?
    {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let name = entry.file_name();
        if name.to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = name.to_string_lossy().to_string();
        let meta = match load_session_meta(paths, &session_id) {
            Ok(meta) => meta,
            Err(_) => continue,
        };
        let pending_approvals = meta.pending_approvals.unwrap_or_default();
        let pending_count = if pending_approvals.is_empty() {
            usize::from(meta.pending_approval.is_some())
        } else {
            pending_approvals.len()
        };
        sessions.push(SessionListEntry {
            session_id: meta.session_id.clone(),
            identity_id: meta.identity_id.clone(),
            channels: session_channels(paths, &meta.session_id, meta.channel),
            started_at: meta.started_at,
            last_activity_at: meta.last_activity_at,
            turn_count: meta.turn_count,
            pending_approvals: pending_count,
        });
    }
    sessions.sort_by(|a, b| b.last_activity_at.cmp(&a.last_activity_at));
    Ok(sessions)
}

fn render_session_list(entries: &[SessionListEntry]) -> String {
    if entries.is_empty() {
        return "no sessions".into();
    }
    let mut lines = vec!["sessions:".to_string()];
    for entry in entries {
        let identity = entry.identity_id.as_deref().unwrap_or("(none)");
        lines.push(format!(
            "- {}  identity={}  channels={}  last_active={}  turns={}  pending_approvals={}",
            entry.session_id,
            identity,
            entry.channels.join(","),
            entry.last_activity_at,
            entry.turn_count,
            entry.pending_approvals
        ));
    }
    lines.join("\n")
}

async fn run_sessions_command(
    paths: &AllbertPaths,
    config: &Config,
    command: SessionsCommand,
) -> Result<()> {
    match command {
        SessionsCommand::List {
            identity,
            channel,
            limit,
            json,
        } => {
            let mut entries = collect_sessions(paths)?;
            if let Some(identity_id) = identity {
                entries.retain(|entry| entry.identity_id.as_deref() == Some(identity_id.as_str()));
            }
            if let Some(raw_channel) = channel {
                let parsed = parse_channel_kind(&raw_channel)?;
                let wanted = channel_kind_label(parsed);
                entries.retain(|entry| entry.channels.iter().any(|channel| channel == wanted));
            }
            if let Some(limit) = limit {
                entries.truncate(limit);
            }
            if json {
                println!("{}", serde_json::to_string_pretty(&entries)?);
            } else {
                println!("{}", render_session_list(&entries));
            }
            Ok(())
        }
        SessionsCommand::Show { session_id } => {
            let path = paths.sessions.join(&session_id).join("turns.md");
            if !path.exists() {
                anyhow::bail!("session not found: {session_id}");
            }
            println!(
                "{}",
                std::fs::read_to_string(&path)
                    .with_context(|| format!("read {}", path.display()))?
            );
            Ok(())
        }
        SessionsCommand::Resume { session_id } => {
            let spawn = default_spawn_config(paths, config)?;
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            let attached = client
                .attach(ChannelKind::Repl, Some(session_id.clone()))
                .await?;
            println!("resumed session {}", attached.session_id);
            repl::run_loop(&mut client, paths).await
        }
        SessionsCommand::Forget { session_id } => {
            let spawn = default_spawn_config(paths, config)?;
            let mut client = DaemonClient::connect_or_spawn(paths, ClientKind::Cli, &spawn).await?;
            client.forget_session(&session_id).await?;
            println!("forgot session {session_id}");
            Ok(())
        }
    }
}

fn run_heartbeat_command(paths: &AllbertPaths, command: HeartbeatCommand) -> Result<()> {
    match command {
        HeartbeatCommand::Show => {
            println!("{}", heartbeat_cli::show(paths)?);
            Ok(())
        }
        HeartbeatCommand::Edit => {
            println!("{}", heartbeat_cli::edit(paths)?);
            Ok(())
        }
        HeartbeatCommand::Suggest { channel } => {
            let parsed = channel.as_deref().map(parse_channel_kind).transpose()?;
            println!("{}", heartbeat_cli::suggest(paths, parsed)?);
            Ok(())
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

fn run_approvals_command(paths: &AllbertPaths, command: ApprovalsCommand) -> Result<()> {
    match command {
        ApprovalsCommand::List { json } => {
            println!("{}", approvals::list(paths, json)?);
            Ok(())
        }
        ApprovalsCommand::Show { approval_id, json } => {
            println!("{}", approvals::show(paths, &approval_id, json)?);
            Ok(())
        }
    }
}

async fn run_inbox_command(paths: &AllbertPaths, command: InboxCommand) -> Result<()> {
    match command {
        InboxCommand::List {
            json,
            identity,
            kind,
            include_resolved,
        } => {
            if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
                let approvals = client
                    .list_inbox(identity, kind, include_resolved)
                    .await?
                    .into_iter()
                    .map(approvals::ApprovalView::from)
                    .collect::<Vec<_>>();
                println!("{}", approvals::render_list_entries(&approvals, json)?);
                return Ok(());
            }
            if identity.is_some() || kind.is_some() || include_resolved {
                return Err(anyhow::anyhow!(
                    "inbox filters require a running daemon; start the daemon or retry without filters"
                ));
            }
            println!("{}", approvals::list(paths, json)?);
            Ok(())
        }
        InboxCommand::Show { approval_id, json } => {
            if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
                let approval = client.show_inbox_approval(&approval_id).await?;
                println!(
                    "{}",
                    approvals::render_show_entry(&approvals::ApprovalView::from(approval), json)?
                );
            } else {
                println!("{}", approvals::show(paths, &approval_id, json)?);
            }
            Ok(())
        }
        InboxCommand::Accept {
            approval_id,
            reason,
        } => {
            if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
                let resolved = client
                    .resolve_inbox_approval(&approval_id, true, reason.clone())
                    .await?;
                println!("{}", approvals::render_resolution(&resolved));
            } else {
                println!(
                    "{}\n(note) daemon not running; recorded the resolution on disk but could not wake a suspended turn.",
                    approvals::resolve(paths, &approval_id, true, reason.as_deref())?
                );
            }
            Ok(())
        }
        InboxCommand::Reject {
            approval_id,
            reason,
        } => {
            if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
                let resolved = client
                    .resolve_inbox_approval(&approval_id, false, reason.clone())
                    .await?;
                println!("{}", approvals::render_resolution(&resolved));
            } else {
                println!(
                    "{}\n(note) daemon not running; recorded the resolution on disk but could not wake a suspended turn.",
                    approvals::resolve(paths, &approval_id, false, reason.as_deref())?
                );
            }
            Ok(())
        }
    }
}

fn run_identity_command(paths: &AllbertPaths, command: IdentityCommand) -> Result<()> {
    match command {
        IdentityCommand::Show => {
            println!("{}", identity_cli::show(paths)?);
            Ok(())
        }
        IdentityCommand::AddChannel { kind, sender } => {
            println!(
                "{}",
                identity_cli::add_channel(paths, parse_channel_kind(&kind)?, &sender)?
            );
            Ok(())
        }
        IdentityCommand::RemoveChannel { kind, sender } => {
            println!(
                "{}",
                identity_cli::remove_channel(paths, parse_channel_kind(&kind)?, &sender)?
            );
            Ok(())
        }
        IdentityCommand::Rename { new_name } => {
            println!("{}", identity_cli::rename(paths, &new_name)?);
            Ok(())
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct ChannelStatusView {
    kind: String,
    enabled: bool,
    configuration_state: String,
    running: bool,
    queue_depth: Option<usize>,
    last_error: Option<String>,
    detail: Option<String>,
    capabilities: ChannelCapabilities,
}

#[derive(Debug, Clone, Serialize)]
struct ChannelMutationResult {
    action: String,
    channel: ChannelStatusView,
    daemon_restart_recommended: bool,
}

#[derive(Debug, Clone)]
enum TelegramSetupState {
    Ready { allowlisted_chats: usize },
    NeedsSetup(String),
    Misconfigured(String),
}

async fn run_daemon_channels_command(
    paths: &AllbertPaths,
    config: &Config,
    command: DaemonChannelsCommand,
) -> Result<()> {
    match command {
        DaemonChannelsCommand::List { json } => {
            let views = collect_channel_statuses(paths, config).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&views)?);
            } else {
                println!("{}", render_channel_status_list(&views));
            }
            Ok(())
        }
        DaemonChannelsCommand::Status { kind, json } => {
            let views = collect_channel_statuses(paths, config).await?;
            match kind {
                Some(raw_kind) => {
                    let kind = parse_channel_kind(&raw_kind)?;
                    let view = views
                        .into_iter()
                        .find(|view| view.kind == channel_kind_label(kind))
                        .ok_or_else(|| anyhow::anyhow!("channel not found: {raw_kind}"))?;
                    if json {
                        println!("{}", serde_json::to_string_pretty(&view)?);
                    } else {
                        println!("{}", render_single_channel_status(&view));
                    }
                }
                None => {
                    if json {
                        println!("{}", serde_json::to_string_pretty(&views)?);
                    } else {
                        println!("{}", render_channel_status_list(&views));
                    }
                }
            }
            Ok(())
        }
        DaemonChannelsCommand::Add { kind, json } => {
            let kind = parse_channel_kind(&kind)?;
            if kind != ChannelKind::Telegram {
                anyhow::bail!(
                    "v0.7 only supports `daemon channels add telegram`; builtin {0} is always available",
                    channel_kind_label(kind)
                );
            }
            let mut updated = Config::load_or_create(paths)?;
            updated.channels.telegram.enabled = true;
            updated.persist(paths)?;
            paths.ensure()?;

            let daemon_running = DaemonClient::connect(paths, ClientKind::Cli).await.is_ok();
            let channel = collect_channel_statuses(paths, &updated)
                .await?
                .into_iter()
                .find(|view| view.kind == "telegram")
                .ok_or_else(|| anyhow::anyhow!("telegram status missing after enable"))?;
            let result = ChannelMutationResult {
                action: "add".into(),
                channel,
                daemon_restart_recommended: daemon_running,
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&result)?);
            } else {
                println!(
                    "enabled channel telegram\n{}{}",
                    render_single_channel_status(&result.channel),
                    if result.daemon_restart_recommended {
                        "\n\nnote: restart the daemon to apply this change to the running process"
                    } else {
                        ""
                    }
                );
            }
            Ok(())
        }
        DaemonChannelsCommand::Remove { kind, json } => {
            let kind = parse_channel_kind(&kind)?;
            if kind != ChannelKind::Telegram {
                anyhow::bail!(
                    "v0.7 only supports `daemon channels remove telegram`; builtin {0} is not removable",
                    channel_kind_label(kind)
                );
            }
            let mut updated = Config::load_or_create(paths)?;
            updated.channels.telegram.enabled = false;
            updated.persist(paths)?;

            let daemon_running = DaemonClient::connect(paths, ClientKind::Cli).await.is_ok();
            let channel = collect_channel_statuses(paths, &updated)
                .await?
                .into_iter()
                .find(|view| view.kind == "telegram")
                .ok_or_else(|| anyhow::anyhow!("telegram status missing after disable"))?;
            let result = ChannelMutationResult {
                action: "remove".into(),
                channel,
                daemon_restart_recommended: daemon_running,
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&result)?);
            } else {
                println!(
                    "disabled channel telegram\n{}{}",
                    render_single_channel_status(&result.channel),
                    if result.daemon_restart_recommended {
                        "\n\nnote: restart the daemon to apply this change to the running process"
                    } else {
                        ""
                    }
                );
            }
            Ok(())
        }
    }
}

async fn collect_channel_statuses(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<Vec<ChannelStatusView>> {
    let runtime = fetch_channel_runtime_statuses(paths).await;
    let mut views = Vec::new();
    for kind in [
        ChannelKind::Cli,
        ChannelKind::Repl,
        ChannelKind::Jobs,
        ChannelKind::Telegram,
    ] {
        let runtime_status = runtime.get(&kind);
        views.push(build_channel_status_view(
            paths,
            config,
            kind,
            runtime_status,
        )?);
    }
    Ok(views)
}

async fn fetch_channel_runtime_statuses(
    paths: &AllbertPaths,
) -> std::collections::HashMap<ChannelKind, ChannelRuntimeStatusPayload> {
    let mut statuses = std::collections::HashMap::new();
    if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
        if let Ok(runtime_statuses) = client.list_channel_runtimes().await {
            for status in runtime_statuses {
                statuses.insert(status.kind, status);
            }
        }
    }
    statuses
}

fn build_channel_status_view(
    paths: &AllbertPaths,
    config: &Config,
    kind: ChannelKind,
    runtime: Option<&ChannelRuntimeStatusPayload>,
) -> Result<ChannelStatusView> {
    let capabilities = ChannelCapabilities::for_builtin(kind);
    let mut detail = None;
    let enabled = match kind {
        ChannelKind::Cli | ChannelKind::Repl => true,
        ChannelKind::Jobs => config.jobs.enabled,
        ChannelKind::Telegram => config.channels.telegram.enabled,
    };
    let configuration_state = match kind {
        ChannelKind::Cli | ChannelKind::Repl => "configured".to_string(),
        ChannelKind::Jobs => {
            if enabled {
                "configured".to_string()
            } else {
                detail = Some("jobs.enabled = false".into());
                "disabled".to_string()
            }
        }
        ChannelKind::Telegram => {
            if !enabled {
                "disabled".to_string()
            } else {
                match inspect_telegram_setup(paths) {
                    TelegramSetupState::Ready { allowlisted_chats } => {
                        detail = Some(format!(
                            "allowlisted chats: {} | token file: {}",
                            allowlisted_chats,
                            paths.telegram_bot_token.display()
                        ));
                        if runtime
                            .and_then(|status| status.last_error.as_ref())
                            .is_some()
                            && !runtime.map(|status| status.running).unwrap_or(false)
                        {
                            "misconfigured".to_string()
                        } else {
                            "configured".to_string()
                        }
                    }
                    TelegramSetupState::NeedsSetup(message) => {
                        detail = Some(message);
                        "needs_setup".to_string()
                    }
                    TelegramSetupState::Misconfigured(message) => {
                        detail = Some(message);
                        "misconfigured".to_string()
                    }
                }
            }
        }
    };
    let running = if enabled {
        runtime.map(|status| status.running).unwrap_or(false)
    } else {
        false
    };
    let queue_depth = runtime.and_then(|status| status.queue_depth);
    let last_error = runtime.and_then(|status| status.last_error.clone());
    Ok(ChannelStatusView {
        kind: channel_kind_label(kind).into(),
        enabled,
        configuration_state,
        running,
        queue_depth,
        last_error,
        detail,
        capabilities,
    })
}

fn inspect_telegram_setup(paths: &AllbertPaths) -> TelegramSetupState {
    let token_present = std::fs::read_to_string(&paths.telegram_bot_token)
        .map(|raw| !raw.trim().is_empty())
        .unwrap_or(false);
    if !token_present {
        return TelegramSetupState::NeedsSetup(format!(
            "missing bot token at {}",
            paths.telegram_bot_token.display()
        ));
    }

    let allowlisted = match load_telegram_allowlisted_chat_count(&paths.telegram_allowed_chats) {
        Ok(value) => value,
        Err(err) => return TelegramSetupState::Misconfigured(err.to_string()),
    };
    if allowlisted == 0 {
        return TelegramSetupState::NeedsSetup(format!(
            "no allowlisted Telegram chats in {}",
            paths.telegram_allowed_chats.display()
        ));
    }

    TelegramSetupState::Ready {
        allowlisted_chats: allowlisted,
    }
}

fn run_profile_command(
    paths: &AllbertPaths,
    config: &Config,
    command: ProfileCommand,
) -> Result<()> {
    match command {
        ProfileCommand::Export {
            path,
            include_secrets,
            identity,
        } => {
            let rendered = profile_cli::export_profile(
                paths,
                Path::new(&path),
                include_secrets,
                identity.as_deref(),
            )?;
            println!("{rendered}");
            Ok(())
        }
        ProfileCommand::Import {
            path,
            overlay,
            replace,
            yes,
        } => {
            if overlay && replace {
                anyhow::bail!("choose either --overlay or --replace, not both");
            }
            let mode = if replace {
                profile_cli::ImportMode::Replace
            } else {
                profile_cli::ImportMode::Overlay
            };
            let rendered = profile_cli::import_profile(paths, config, Path::new(&path), mode, yes)?;
            println!("{rendered}");
            Ok(())
        }
    }
}

fn load_telegram_allowlisted_chat_count(path: &Path) -> Result<usize> {
    if !path.exists() {
        return Ok(0);
    }
    let raw = std::fs::read_to_string(path)?;
    let mut count = 0usize;
    for (idx, line) in raw.lines().enumerate() {
        let stripped = line.split('#').next().unwrap_or_default().trim();
        if stripped.is_empty() {
            continue;
        }
        stripped.parse::<i64>().map_err(|err| {
            anyhow::anyhow!(
                "parse Telegram allowlisted chat on line {} in {}: {err}",
                idx + 1,
                path.display()
            )
        })?;
        count += 1;
    }
    Ok(count)
}

fn render_channel_status_list(views: &[ChannelStatusView]) -> String {
    let mut lines = vec!["channels:".to_string()];
    for view in views {
        lines.push(format!(
            "- {}  enabled={}  state={}  running={}  queue_depth={}  capabilities={}",
            view.kind,
            yes_no(view.enabled),
            view.configuration_state,
            yes_no(view.running),
            view.queue_depth
                .map(|value| value.to_string())
                .unwrap_or_else(|| "n/a".into()),
            render_channel_capabilities(&view.capabilities)
        ));
        if let Some(detail) = view.detail.as_deref() {
            lines.push(format!("  detail={detail}"));
        }
        if let Some(last_error) = view.last_error.as_deref() {
            lines.push(format!("  last_error={last_error}"));
        }
    }
    lines.join("\n")
}

fn render_single_channel_status(view: &ChannelStatusView) -> String {
    format!(
        "channel:           {}\nenabled:           {}\nstate:             {}\nrunning:           {}\nqueue depth:       {}\nlast error:        {}\ncapabilities:      {}\ndetail:            {}",
        view.kind,
        yes_no(view.enabled),
        view.configuration_state,
        yes_no(view.running),
        view.queue_depth
            .map(|value| value.to_string())
            .unwrap_or_else(|| "n/a".into()),
        view.last_error.as_deref().unwrap_or("(none)"),
        render_channel_capabilities(&view.capabilities),
        view.detail.as_deref().unwrap_or("(none)"),
    )
}

fn render_channel_capabilities(capabilities: &ChannelCapabilities) -> String {
    let mut parts: Vec<String> = Vec::new();
    if capabilities.supports_inline_confirm {
        parts.push("inline_confirm".into());
    }
    if capabilities.supports_async_confirm {
        parts.push("async_confirm".into());
    }
    if capabilities.supports_rich_output {
        parts.push("rich_output".into());
    }
    if capabilities.supports_file_attach {
        parts.push("file_attach".into());
    }
    if capabilities.supports_image_input {
        parts.push("image_input".into());
    }
    if capabilities.supports_image_output {
        parts.push("image_output".into());
    }
    if capabilities.supports_voice_input {
        parts.push("voice_input".into());
    }
    if capabilities.supports_voice_output {
        parts.push("voice_output".into());
    }
    if capabilities.supports_audio_attach {
        parts.push("audio_attach".into());
    }
    parts.push(match capabilities.latency_class {
        allbert_channels::LatencyClass::Synchronous => "latency=synchronous".into(),
        allbert_channels::LatencyClass::Asynchronous => "latency=asynchronous".into(),
        allbert_channels::LatencyClass::Batch => "latency=batch".into(),
    });
    parts.push(if capabilities.max_message_size == usize::MAX {
        "max_message_size=unbounded".into()
    } else {
        format!("max_message_size={}", capabilities.max_message_size)
    });
    parts.join(", ")
}

fn parse_channel_kind(raw: &str) -> Result<ChannelKind> {
    match raw {
        "cli" => Ok(ChannelKind::Cli),
        "repl" => Ok(ChannelKind::Repl),
        "jobs" => Ok(ChannelKind::Jobs),
        "telegram" => Ok(ChannelKind::Telegram),
        _ => anyhow::bail!("unknown channel kind: {raw}"),
    }
}

fn channel_kind_label(kind: ChannelKind) -> &'static str {
    match kind {
        ChannelKind::Cli => "cli",
        ChannelKind::Repl => "repl",
        ChannelKind::Jobs => "jobs",
        ChannelKind::Telegram => "telegram",
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
    maybe_print_repl_inbox_attach_summary(paths, config, &attached.session_id)?;
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

fn maybe_print_repl_inbox_attach_summary(
    paths: &AllbertPaths,
    config: &Config,
    session_id: &str,
) -> Result<()> {
    if !config.repl.show_inbox_on_attach {
        return Ok(());
    }
    let session_meta = match load_session_meta(paths, session_id) {
        Ok(meta) => meta,
        Err(_) => return Ok(()),
    };
    let Some(identity_id) = session_meta.identity_id else {
        return Ok(());
    };
    if let Some(summary) = approvals::pending_summary_for_identity(paths, &identity_id)? {
        println!("{}", approvals::render_repl_attach_inbox_summary(&summary));
    }
    Ok(())
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
        DaemonCommand::Channels { command } => {
            run_daemon_channels_command(paths, config, command).await
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
        while let Ok(message) = client.recv().await {
            repl::render_async_server_message(message);
        }
    }))
}

fn render_running_daemon_status(config: &Config, status: &DaemonStatus) -> String {
    let lock_owner = status
        .lock_owner
        .as_ref()
        .map(|lock| {
            format!(
                "pid={} host={} started_at={}",
                lock.pid, lock.host, lock.started_at
            )
        })
        .unwrap_or_else(|| "(missing)".into());
    format!(
        "daemon:            running\npid:               {}\ndaemon id:         {}\nstarted at:        {}\nsocket:            {}\nsessions:          {}\ntrace enabled:     {}\nlock owner:        {}\nmodel api_key_env: {}\napi key visible:   {}\nauto-spawn:        {}\njobs enabled:      {}\njobs timezone:     {}",
        status.pid,
        status.daemon_id,
        status.started_at,
        status.socket_path,
        status.session_count,
        yes_no(status.trace_enabled),
        lock_owner,
        status.model_api_key_env,
        yes_no(status.model_api_key_visible),
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

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "allbert-cli-main-{}-{}",
                std::process::id(),
                TEMP_COUNTER.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).expect("temp root should create");
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

    #[test]
    fn telegram_allowlist_parser_ignores_comments_and_blank_lines() {
        let temp = TempRoot::new();
        let allowlist = temp.paths().telegram_allowed_chats;
        if let Some(parent) = allowlist.parent() {
            std::fs::create_dir_all(parent).expect("allowlist parent should create");
        }
        std::fs::write(&allowlist, "12345\n# comment\n\n67890 # inline\n")
            .expect("allowlist should write");

        let count =
            load_telegram_allowlisted_chat_count(&allowlist).expect("allowlist should parse");
        assert_eq!(count, 2);
    }

    #[test]
    fn telegram_status_reports_needs_setup_without_token() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should ensure");
        let mut config = Config::default_template();
        config.channels.telegram.enabled = true;

        let view =
            build_channel_status_view(&paths, &config, ChannelKind::Telegram, None).expect("view");
        assert_eq!(view.configuration_state, "needs_setup");
        assert!(view
            .detail
            .unwrap_or_default()
            .contains("missing bot token"));
    }
}
