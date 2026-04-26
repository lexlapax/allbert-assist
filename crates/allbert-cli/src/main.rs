use std::collections::BTreeSet;
use std::path::Path;
use std::time::Duration;

use allbert_channels::ChannelCapabilities;
use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_jobs::JobsCommand;
use allbert_kernel_services::{refresh_agents_markdown, AllbertPaths, Config, ReplUiMode};
use allbert_proto::{
    ChannelKind, ChannelRuntimeStatusPayload, ClientKind, DaemonStatus,
    DiagnosisRemediationRequestPayload, DiagnosisRunRequest, UtilityEnableRequest,
};
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use serde::Serialize;

mod adapters_cli;
mod approvals;
mod diagnose_cli;
mod heartbeat_cli;
mod identity_cli;
mod memory_cli;
mod profile_cli;
mod repl;
mod self_improvement_cli;
mod settings_cli;
mod setup;
mod skills;
mod trace_cli;
mod tui;
mod utilities_cli;

use adapters_cli::AdaptersCommand;
use diagnose_cli::DiagnoseCommand;
use utilities_cli::UtilitiesCommand;

#[derive(Parser, Debug)]
#[command(
    author,
    version,
    about = "Allbert daemon-backed CLI",
    long_about = None,
    after_long_help = "EXAMPLES:\n  allbert-cli repl\n  allbert-cli activity\n  allbert-cli diagnose run\n  allbert-cli utilities discover --offline\n  allbert-cli adapters status\n  allbert-cli adapters training preview\n  allbert-cli trace show\n  allbert-cli settings list ui\n  allbert-cli memory staged list\n  allbert-cli skills show memory-curator\n  allbert-cli daemon status\n"
)]
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
    /// Manage local personalization adapters.
    Adapters {
        #[command(subcommand)]
        command: AdaptersCommand,
    },
    Learning {
        #[command(subcommand)]
        command: LearningCommand,
    },
    SelfImprovement {
        #[command(subcommand)]
        command: SelfImprovementCommand,
    },
    Skills {
        #[command(subcommand)]
        command: SkillsCommand,
    },
    /// Inspect and safely change supported profile settings.
    Settings {
        #[command(subcommand)]
        command: SettingsCommand,
    },
    /// Run or resume guided profile setup.
    Setup {
        /// Resume from saved setup state when present.
        #[arg(long)]
        resume: bool,
    },
    Identity {
        #[command(subcommand)]
        command: IdentityCommand,
    },
    Memory {
        #[command(subcommand)]
        command: MemoryCommand,
    },
    Config {
        #[command(subcommand)]
        command: ConfigCommand,
    },
    Approvals {
        #[command(subcommand)]
        command: ApprovalsCommand,
    },
    Inbox {
        #[command(subcommand)]
        command: InboxCommand,
    },
    /// Show the daemon-owned activity snapshot for the attached CLI session.
    Activity {
        /// Emit the raw JSON activity snapshot.
        #[arg(long)]
        json: bool,
    },
    /// Inspect, tail, export, and prune durable session traces.
    Trace {
        #[command(subcommand)]
        command: TraceCommand,
    },
    /// Create and inspect bounded self-diagnosis reports.
    Diagnose {
        #[command(subcommand)]
        command: DiagnoseCommand,
    },
    /// Discover and manage operator-enabled local utilities.
    Utilities {
        #[command(subcommand)]
        command: UtilitiesCommand,
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
    /// Start an interactive daemon-backed REPL.
    Repl {
        /// Use the classic line-oriented REPL for this launch.
        #[arg(long)]
        classic: bool,
        /// Use the responsive terminal UI for this launch.
        #[arg(long)]
        tui: bool,
        /// Persist the selected REPL mode to config.toml.
        #[arg(long)]
        save: bool,
    },
    Telemetry {
        #[arg(long)]
        json: bool,
    },
    /// Show the local Allbert home paths and daemon activity, if available.
    Home,
    /// Run a compact local readiness check.
    Doctor,
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
    /// Disable one installed skill without removing it from disk.
    Disable { name: String },
    /// Re-enable one installed skill.
    Enable { name: String },
    /// Scaffold a new strict AgentSkills-format skill in the current directory.
    Init { name: String },
}

#[derive(Subcommand, Debug)]
enum ConfigCommand {
    /// Restore config.toml from the daemon's last known-good snapshot.
    RestoreLastGood,
}

#[derive(Subcommand, Debug)]
enum SettingsCommand {
    /// List supported settings, optionally scoped to one group.
    List { group: Option<String> },
    /// Show one setting with validation and safety details.
    Show { key: String },
    /// Persist one allowlisted setting using path-preserving TOML edits.
    Set { key: String, value: Vec<String> },
    /// Remove an explicit override and fall back to the default.
    Reset { key: String },
    /// Explain a settings group and common examples.
    Explain { group: String },
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
    /// Show indexed durable, staged, episode, and fact memory counts.
    Stats,
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
    /// Show or update memory routing policy.
    Routing {
        #[command(subcommand)]
        command: MemoryRoutingCommand,
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
    /// Move a rejected staged-memory entry back into staging.
    Reconsider { id: String },
    /// Forget one or more durable memory entries.
    Forget {
        target: String,
        #[arg(long)]
        confirm: bool,
    },
    /// Restore a forgotten durable-memory entry from trash.
    Restore { id: String },
    /// Remove expired memory trash and rejected staged entries.
    RecoveryGc,
    /// Rebuild the curated-memory index.
    RebuildIndex {
        #[arg(long)]
        force: bool,
    },
}

#[derive(Subcommand, Debug)]
enum LearningCommand {
    /// Preview or run the reviewed personality digest job.
    Digest {
        #[arg(long, conflicts_with = "run")]
        preview: bool,
        #[arg(long)]
        run: bool,
        #[arg(long)]
        accept: bool,
        #[arg(long = "consent-hosted-provider")]
        consent_hosted_provider: bool,
    },
}

#[derive(Subcommand, Debug)]
enum SelfImprovementCommand {
    Config {
        #[command(subcommand)]
        command: SelfImprovementConfigCommand,
    },
    Diff {
        approval_id: String,
    },
    Install {
        approval_id: String,
        #[arg(long)]
        allow_needs_review: bool,
    },
    Gc {
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(Subcommand, Debug)]
enum SelfImprovementConfigCommand {
    Show,
    Set {
        #[arg(long = "source-checkout")]
        source_checkout: String,
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
enum MemoryRoutingCommand {
    /// Show memory routing policy.
    Show,
    /// Update memory routing policy.
    Set {
        #[arg(long)]
        mode: Option<String>,
        #[arg(long = "skill")]
        skills: Vec<String>,
        #[arg(long = "auto-activate-intent")]
        auto_activate_intents: Vec<String>,
        #[arg(long = "auto-activate-cue")]
        auto_activate_cues: Vec<String>,
    },
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
        include_adapters: bool,
        #[arg(long)]
        dry_run: bool,
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
#[command(
    after_long_help = "EXAMPLES:\n  allbert-cli trace list\n  allbert-cli trace show\n  allbert-cli trace show repl-primary\n  allbert-cli trace show-span 1111111111111111 --session repl-primary\n  allbert-cli trace tail repl-primary\n  allbert-cli trace export repl-primary --format otlp-json\n  allbert-cli trace gc --dry-run\n"
)]
enum TraceCommand {
    /// Render the span tree for a session, or the latest traced session.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace show\n  allbert-cli trace show repl-primary\n"
    )]
    Show {
        /// Session id to inspect. Defaults to the latest traced session.
        session: Option<String>,
    },
    /// Subscribe to completed-span broadcasts from a running daemon.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace tail\n  allbert-cli trace tail repl-primary\n"
    )]
    Tail {
        /// Session id to tail. Defaults to the daemon's active/latest traced session.
        session: Option<String>,
    },
    /// List sessions that have trace artifacts.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace list\n  allbert-cli trace list --limit 5\n"
    )]
    List {
        #[arg(long, default_value_t = 20)]
        limit: usize,
    },
    /// Render one span with attributes and events.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace show-span 1111111111111111\n  allbert-cli trace show-span 1111111111111111 --session repl-primary\n"
    )]
    ShowSpan {
        span_id: String,
        #[arg(long)]
        session: Option<String>,
    },
    /// Export one session as file-based OTLP-JSON.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace export repl-primary\n  allbert-cli trace export repl-primary --format otlp-json --out exports/traces/repl-primary.json\n"
    )]
    Export {
        session: String,
        #[arg(long, default_value = "otlp-json")]
        format: String,
        #[arg(long)]
        out: Option<String>,
    },
    /// Apply trace retention and disk-cap cleanup.
    #[command(
        after_long_help = "EXAMPLES:\n  allbert-cli trace gc --dry-run\n  allbert-cli trace gc\n"
    )]
    Gc {
        #[arg(long)]
        dry_run: bool,
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
async fn main() {
    if let Err(error) = run_cli().await {
        eprintln!("{}", render_cli_error(&error));
        std::process::exit(1);
    }
}

fn render_cli_error(error: &anyhow::Error) -> String {
    allbert_kernel_services::append_error_hint(&error.to_string())
}

async fn run_cli() -> Result<()> {
    let args = Args::parse();
    if let Some(Command::Skills {
        command: SkillsCommand::Validate { ref path },
    }) = args.command.as_ref()
    {
        return run_skills_command(None, None, SkillsCommand::Validate { path: path.clone() })
            .await;
    }

    let paths = AllbertPaths::from_home()?;
    if matches!(
        args.command.as_ref(),
        Some(Command::Config {
            command: ConfigCommand::RestoreLastGood
        })
    ) {
        return run_config_command(&paths, ConfigCommand::RestoreLastGood);
    }
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
            run_repl(&paths, &config, args.trace, args.yes, None).await
        }
        Some(Command::InternalDaemonHost) => run_internal_daemon_host().await,
        Some(Command::Skills { command }) => {
            run_skills_command(Some(&paths), Some(&config), command).await
        }
        Some(Command::Settings { command }) => run_settings_command(&paths, &config, command),
        Some(Command::Setup { resume }) => {
            match setup::run_setup_wizard_with_resume(&paths, &config, resume)? {
                Some(updated) => {
                    updated.persist(&paths)?;
                    println!(
                        "Setup saved. Change these choices later with `allbert-cli settings`."
                    );
                }
                None => println!("Setup cancelled."),
            }
            Ok(())
        }
        Some(Command::Identity { command }) => run_identity_command(&paths, command),
        Some(Command::Memory { command }) => run_memory_command(&paths, &config, command).await,
        Some(Command::Config { command }) => run_config_command(&paths, command),
        Some(Command::Approvals { command }) => run_approvals_command(&paths, command),
        Some(Command::Inbox { command }) => run_inbox_command(&paths, &config, command).await,
        Some(Command::Activity { json }) => run_activity_command(&paths, &config, json).await,
        Some(Command::Trace { command }) => run_trace_command(&paths, &config, command).await,
        Some(Command::Diagnose { command }) => run_diagnose_command(&paths, &config, command).await,
        Some(Command::Utilities { command }) => {
            run_utilities_command(&paths, &config, command).await
        }
        Some(Command::Adapters { command }) => adapters_cli::run(&paths, &config, command),
        Some(Command::Profile { command }) => run_profile_command(&paths, &config, command),
        Some(Command::Heartbeat { command }) => run_heartbeat_command(&paths, command),
        Some(Command::Sessions { command }) => run_sessions_command(&paths, &config, command).await,
        Some(Command::Repl { classic, tui, save }) => {
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
            let mode = repl_mode_from_flags(classic, tui)?;
            let mut effective = config.clone();
            if save {
                if let Some(mode) = mode {
                    effective.repl.ui = mode;
                    effective.persist(&paths)?;
                }
            }
            run_repl(&paths, &effective, args.trace, args.yes, mode).await
        }
        Some(Command::Telemetry { json }) => run_telemetry_command(&paths, &config, json).await,
        Some(Command::Home) => run_home_command(&paths, &config).await,
        Some(Command::Doctor) => run_doctor_command(&paths, &config).await,
        Some(Command::Learning { command }) => run_learning_command(&paths, &config, command),
        Some(Command::SelfImprovement { command }) => {
            run_self_improvement_command(&paths, &config, command)
        }
        Some(Command::Jobs { command }) => {
            if !matches!(command, JobsCommand::Template { .. })
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
        MemoryCommand::Stats => {
            println!("{}", memory_cli::stats(paths, config)?);
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
        MemoryCommand::Routing { command } => match command {
            MemoryRoutingCommand::Show => {
                println!("{}", memory_cli::routing_show(config));
                Ok(())
            }
            MemoryRoutingCommand::Set {
                mode,
                skills,
                auto_activate_intents,
                auto_activate_cues,
            } => {
                let mut updated = config.clone();
                let rendered = memory_cli::routing_set(
                    &mut updated,
                    mode.as_deref(),
                    &skills,
                    &auto_activate_intents,
                    &auto_activate_cues,
                )?;
                updated.persist(paths)?;
                refresh_agents_markdown(paths)?;
                if let Ok(mut client) = DaemonClient::connect(paths, ClientKind::Cli).await {
                    client.attach(ChannelKind::Cli, None).await?;
                    client.reload_session_config().await?;
                }
                println!("{rendered}");
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
        MemoryCommand::Reconsider { id } => {
            println!("{}", memory_cli::reconsider(paths, config, &id)?);
            Ok(())
        }
        MemoryCommand::Forget { target, confirm } => {
            println!("{}", memory_cli::forget(paths, config, &target, confirm)?);
            Ok(())
        }
        MemoryCommand::Restore { id } => {
            println!("{}", memory_cli::restore(paths, config, &id)?);
            Ok(())
        }
        MemoryCommand::RecoveryGc => {
            println!("{}", memory_cli::recovery_gc(paths, config)?);
            Ok(())
        }
        MemoryCommand::RebuildIndex { force } => {
            println!("{}", memory_cli::rebuild_index(paths, config, force)?);
            Ok(())
        }
    }
}

fn run_config_command(paths: &AllbertPaths, command: ConfigCommand) -> Result<()> {
    match command {
        ConfigCommand::RestoreLastGood => {
            let backup = allbert_kernel_services::restore_last_good_config(paths)?;
            println!(
                "restored config.toml from last-good snapshot\nprevious config backup: {}",
                backup.display()
            );
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

fn run_learning_command(
    paths: &AllbertPaths,
    config: &Config,
    command: LearningCommand,
) -> Result<()> {
    match command {
        LearningCommand::Digest {
            preview,
            run,
            accept,
            consent_hosted_provider,
        } => {
            if preview || !run {
                let preview = allbert_kernel_services::preview_personality_digest(paths, config)?;
                println!("{}", preview.render());
                return Ok(());
            }
            let report = allbert_kernel_services::run_personality_digest(
                paths,
                config,
                accept,
                consent_hosted_provider,
            )?;
            println!("{}", serde_json::to_string_pretty(&report)?);
            Ok(())
        }
    }
}

fn run_self_improvement_command(
    paths: &AllbertPaths,
    config: &Config,
    command: SelfImprovementCommand,
) -> Result<()> {
    match command {
        SelfImprovementCommand::Config { command } => match command {
            SelfImprovementConfigCommand::Show => {
                println!("{}", self_improvement_cli::config_show(paths, config)?);
                Ok(())
            }
            SelfImprovementConfigCommand::Set { source_checkout } => {
                println!(
                    "{}",
                    self_improvement_cli::config_set_source_checkout(
                        paths,
                        config,
                        &source_checkout
                    )?
                );
                Ok(())
            }
        },
        SelfImprovementCommand::Gc { dry_run } => {
            println!("{}", self_improvement_cli::gc(paths, config, dry_run)?);
            Ok(())
        }
        SelfImprovementCommand::Diff { approval_id } => {
            print!("{}", self_improvement_cli::diff(paths, &approval_id)?);
            Ok(())
        }
        SelfImprovementCommand::Install {
            approval_id,
            allow_needs_review,
        } => {
            println!(
                "{}",
                self_improvement_cli::install(paths, config, &approval_id, allow_needs_review)?
            );
            Ok(())
        }
    }
}

async fn run_inbox_command(
    paths: &AllbertPaths,
    config: &Config,
    command: InboxCommand,
) -> Result<()> {
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
                    approvals::resolve(paths, config, &approval_id, true, reason.as_deref())?
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
                    approvals::resolve(paths, config, &approval_id, false, reason.as_deref())?
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
            include_adapters,
            dry_run,
            identity,
        } => {
            let rendered = profile_cli::export_profile(
                paths,
                Path::new(&path),
                include_secrets,
                include_adapters,
                dry_run,
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
        SkillsCommand::Disable { name } => {
            let paths = paths.context("disable requires an initialized Allbert home")?;
            println!("{}", skills::set_skill_enabled(paths, &name, false)?);
            Ok(())
        }
        SkillsCommand::Enable { name } => {
            let paths = paths.context("enable requires an initialized Allbert home")?;
            println!("{}", skills::set_skill_enabled(paths, &name, true)?);
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

fn run_settings_command(
    paths: &AllbertPaths,
    config: &Config,
    command: SettingsCommand,
) -> Result<()> {
    let rendered = match command {
        SettingsCommand::List { group } => settings_cli::list(config, group.as_deref())?,
        SettingsCommand::Show { key } => settings_cli::show(config, &key)?,
        SettingsCommand::Set { key, value } => {
            if value.is_empty() {
                anyhow::bail!("usage: allbert-cli settings set <key> <value>");
            }
            settings_cli::set(paths, &key, &value.join(" "))?
        }
        SettingsCommand::Reset { key } => settings_cli::reset(paths, &key)?,
        SettingsCommand::Explain { group } => settings_cli::explain(&group)?,
    };
    println!("{rendered}");
    Ok(())
}

async fn run_repl(
    paths: &AllbertPaths,
    config: &Config,
    trace: bool,
    yes: bool,
    requested_mode: Option<ReplUiMode>,
) -> Result<()> {
    let mut effective = config.clone();
    if trace {
        effective.trace.enabled = true;
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

    let mode = requested_mode.unwrap_or(effective.repl.ui);
    tracing::info!(
        session = attached.session_id,
        ui = mode.label(),
        "REPL attached"
    );
    if mode == ReplUiMode::Tui {
        match tui::run_loop(&mut client, paths, &attached.session_id, &effective).await {
            Ok(()) => return Ok(()),
            Err(err) => {
                eprintln!("TUI unavailable ({err}); falling back to classic REPL.");
            }
        }
    }

    let notifications = spawn_notification_task(paths, attached.session_id.clone()).await;
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

async fn run_telemetry_command(paths: &AllbertPaths, config: &Config, json: bool) -> Result<()> {
    let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
    attach_latest_or_default(paths, &mut client).await?;
    let telemetry = client.session_telemetry().await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&telemetry)?);
    } else {
        println!("{}", render_telemetry_summary(&telemetry));
    }
    Ok(())
}

async fn run_activity_command(paths: &AllbertPaths, config: &Config, json: bool) -> Result<()> {
    let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
    attach_latest_or_default(paths, &mut client).await?;
    let activity = client.activity_snapshot().await?;
    if json {
        println!("{}", serde_json::to_string_pretty(&activity)?);
    } else {
        println!("{}", repl::render_activity_snapshot(&activity));
    }
    Ok(())
}

async fn run_trace_command(
    paths: &AllbertPaths,
    config: &Config,
    command: TraceCommand,
) -> Result<()> {
    match command {
        TraceCommand::Show { session } => {
            println!("{}", trace_cli::show(paths, session.as_deref())?);
        }
        TraceCommand::Tail { session } => {
            trace_cli::tail(paths, session).await?;
        }
        TraceCommand::List { limit } => {
            println!("{}", trace_cli::list(paths, limit)?);
        }
        TraceCommand::ShowSpan { span_id, session } => {
            println!(
                "{}",
                trace_cli::show_span(paths, session.as_deref(), &span_id)?
            );
        }
        TraceCommand::Export {
            session,
            format,
            out,
        } => {
            let out = trace_cli::output_path(out);
            println!(
                "{}",
                trace_cli::export(paths, config, &session, &format, out.as_deref())?
            );
        }
        TraceCommand::Gc { dry_run } => {
            println!("{}", trace_cli::gc(paths, config, dry_run)?);
        }
    }
    Ok(())
}

async fn run_diagnose_command(
    paths: &AllbertPaths,
    config: &Config,
    command: DiagnoseCommand,
) -> Result<()> {
    match command {
        DiagnoseCommand::Run {
            session,
            lookback_days,
            remediate,
            reason,
            json,
        } => {
            let remediation = match (remediate, reason) {
                (Some(kind), Some(reason)) if !reason.trim().is_empty() => {
                    Some(DiagnosisRemediationRequestPayload {
                        kind: diagnose_remediation_label(kind).into(),
                        reason,
                    })
                }
                (Some(_), _) => anyhow::bail!("diagnosis remediation requires --reason <text>"),
                (None, Some(reason)) if !reason.trim().is_empty() => {
                    anyhow::bail!("--reason requires --remediate <code|skill|memory>")
                }
                _ => None,
            };
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            attach_latest_or_default(paths, &mut client).await?;
            let summary = client
                .diagnose_run(DiagnosisRunRequest {
                    session_id: session,
                    lookback_days,
                    remediation,
                })
                .await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&summary)?);
            } else {
                println!("{}", diagnose_cli::render_run_summary_payload(&summary));
            }
        }
        DiagnoseCommand::List {
            session,
            offline,
            json,
        } if offline => diagnose_cli::run(
            paths,
            config,
            DiagnoseCommand::List {
                session,
                offline,
                json,
            },
        )?,
        DiagnoseCommand::List {
            session,
            offline: _,
            json,
        } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            attach_latest_or_default(paths, &mut client).await?;
            let summaries = client.diagnose_list(session).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&summaries)?);
            } else {
                println!("{}", diagnose_cli::render_report_list_payload(&summaries));
            }
        }
        DiagnoseCommand::Show {
            diagnosis_id,
            offline,
            json,
        } if offline => diagnose_cli::run(
            paths,
            config,
            DiagnoseCommand::Show {
                diagnosis_id,
                offline,
                json,
            },
        )?,
        DiagnoseCommand::Show {
            diagnosis_id,
            offline: _,
            json,
        } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            attach_latest_or_default(paths, &mut client).await?;
            let report = client.diagnose_show(diagnosis_id).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report.summary)?);
            } else {
                println!("{}", diagnose_cli::render_report_payload(&report, false));
            }
        }
    }
    Ok(())
}

async fn run_utilities_command(
    paths: &AllbertPaths,
    config: &Config,
    command: UtilitiesCommand,
) -> Result<()> {
    match command {
        UtilitiesCommand::Discover { offline, json } if offline => {
            utilities_cli::run(paths, config, UtilitiesCommand::Discover { offline, json })?
        }
        UtilitiesCommand::Discover { offline: _, json } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            let entries = client.utilities_discover().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&entries)?);
            } else {
                println!("{}", utilities_cli::render_discovery_payload(&entries));
            }
        }
        UtilitiesCommand::List { offline, json } if offline => {
            utilities_cli::run(paths, config, UtilitiesCommand::List { offline, json })?
        }
        UtilitiesCommand::List { offline: _, json } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            let entries = client.utilities_list().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&entries)?);
            } else {
                println!("{}", utilities_cli::render_enabled_payload(&entries));
            }
        }
        UtilitiesCommand::Show {
            utility_id,
            offline,
            json,
        } if offline => utilities_cli::run(
            paths,
            config,
            UtilitiesCommand::Show {
                utility_id,
                offline,
                json,
            },
        )?,
        UtilitiesCommand::Show {
            utility_id,
            offline: _,
            json,
        } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            let entry = client.utilities_show(utility_id).await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&entry)?);
            } else {
                println!("{}", utilities_cli::render_show_payload(&entry));
            }
        }
        UtilitiesCommand::Enable { utility_id, path } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            let entry = client
                .utilities_enable(UtilityEnableRequest {
                    utility_id,
                    path: path.map(|path| path.display().to_string()),
                })
                .await?;
            println!("{}", utilities_cli::render_enable_payload(&entry));
        }
        UtilitiesCommand::Disable { utility_id } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            client.utilities_disable(utility_id.clone()).await?;
            println!("disabled utility {utility_id}");
        }
        UtilitiesCommand::Doctor { json } => {
            let mut client = connect_for_use(paths, config, ClientKind::Cli).await?;
            let report = client.utilities_doctor().await?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                println!("{}", utilities_cli::render_doctor_payload(&report));
            }
        }
    }
    Ok(())
}

fn diagnose_remediation_label(kind: diagnose_cli::DiagnoseRemediationArg) -> &'static str {
    match kind {
        diagnose_cli::DiagnoseRemediationArg::Code => "code",
        diagnose_cli::DiagnoseRemediationArg::Skill => "skill",
        diagnose_cli::DiagnoseRemediationArg::Memory => "memory",
    }
}

async fn run_home_command(paths: &AllbertPaths, _config: &Config) -> Result<()> {
    println!(
        "{}",
        render_home(paths, optional_active_activity(paths).await)
    );
    Ok(())
}

async fn run_doctor_command(paths: &AllbertPaths, config: &Config) -> Result<()> {
    let warnings = setup::build_startup_warnings(config);
    println!(
        "{}",
        render_doctor(
            paths,
            config,
            &warnings,
            optional_active_activity(paths).await
        )
    );
    Ok(())
}

fn render_home(paths: &AllbertPaths, activity: Option<allbert_proto::ActivitySnapshot>) -> String {
    let mut lines = vec![
        format!("home:      {}", paths.root.display()),
        format!("config:    {}", paths.config.display()),
        format!("sessions:  {}", paths.sessions.display()),
        format!("logs:      {}", paths.logs.display()),
    ];
    if let Some(activity) = activity.as_ref() {
        lines.push(format!(
            "activity:  {}",
            repl::render_activity_compact(activity)
        ));
    }
    lines.join("\n")
}

fn render_doctor(
    paths: &AllbertPaths,
    config: &Config,
    warnings: &[String],
    activity: Option<allbert_proto::ActivitySnapshot>,
) -> String {
    let mut lines = vec![
        format!(
            "doctor:    {}",
            if warnings.is_empty() {
                "ok"
            } else {
                "warnings"
            }
        ),
        format!("home:      {}", paths.root.display()),
        format!("setup:     v{}", config.setup.version),
        format!("daemon:    auto-spawn {}", yes_no(config.daemon.auto_spawn)),
    ];
    if let Some(activity) = activity.as_ref() {
        lines.push(format!(
            "activity:  {}",
            repl::render_activity_compact(activity)
        ));
    }
    if !warnings.is_empty() {
        lines.push("warnings:".into());
        for warning in warnings {
            lines.push(format!("- {warning}"));
        }
    }
    lines.join("\n")
}

async fn optional_active_activity(paths: &AllbertPaths) -> Option<allbert_proto::ActivitySnapshot> {
    let mut client = DaemonClient::connect(paths, ClientKind::Cli).await.ok()?;
    attach_latest_session(paths, &mut client)
        .await
        .ok()
        .flatten()?;
    client.activity_snapshot().await.ok()
}

async fn attach_latest_or_default(paths: &AllbertPaths, client: &mut DaemonClient) -> Result<()> {
    if attach_latest_session(paths, client).await?.is_none() {
        client.attach(ChannelKind::Cli, None).await?;
    }
    Ok(())
}

async fn attach_latest_session(
    paths: &AllbertPaths,
    client: &mut DaemonClient,
) -> Result<Option<()>> {
    let Some(target) = latest_session_target(paths)? else {
        return Ok(None);
    };
    client
        .attach(target.channel, Some(target.session_id))
        .await?;
    Ok(Some(()))
}

struct SessionActivityTarget {
    session_id: String,
    channel: ChannelKind,
}

fn latest_session_target(paths: &AllbertPaths) -> Result<Option<SessionActivityTarget>> {
    let sessions = collect_sessions(paths)?;
    let Some(session) = sessions.first() else {
        return Ok(None);
    };
    let meta = load_session_meta(paths, &session.session_id)?;
    Ok(Some(SessionActivityTarget {
        session_id: session.session_id.clone(),
        channel: meta.channel,
    }))
}

fn render_telemetry_summary(snapshot: &allbert_proto::TelemetrySnapshot) -> String {
    let ctx = match (snapshot.context_used_tokens, snapshot.context_percent) {
        (Some(tokens), Some(percent)) => format!("{tokens} tokens ({percent:.1}%)"),
        (Some(tokens), None) => format!("{tokens} tokens (ctx ?)"),
        _ => "ctx ?".into(),
    };
    let last = snapshot
        .last_response_usage
        .as_ref()
        .map(|usage| format!("{} in / {} out", usage.input_tokens, usage.output_tokens))
        .unwrap_or_else(|| "(none yet)".into());
    let adapter = snapshot
        .adapter
        .as_ref()
        .map(|adapter| adapter.active_id.as_str())
        .unwrap_or("(none)");
    format!(
        "session:       {}\nchannel:       {:?}\nmodel:         {} ({})\nadapter:       {}\ncontext:       {}\nlast tokens:   {}\nsession tokens:{}\ncost:          session ${:.6}, today ${:.6}\nmemory:        durable {}, staged {}, episodes {}, facts {}\ninbox:         {}\nintent:        {}\ntrace:         {}",
        snapshot.session_id,
        snapshot.channel,
        snapshot.model.model_id,
        snapshot.provider,
        adapter,
        ctx,
        last,
        snapshot.session_usage.total_tokens,
        snapshot.session_cost_usd,
        snapshot.today_cost_usd,
        snapshot.memory.durable_count,
        snapshot.memory.staged_count,
        snapshot.memory.episode_count,
        snapshot.memory.fact_count,
        snapshot.inbox_count,
        snapshot
            .last_resolved_intent
            .as_deref()
            .unwrap_or("(none yet)"),
        yes_no(snapshot.trace_enabled),
    )
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
    let api_key_state = if status.model_api_key_env.is_none() {
        "not required".to_string()
    } else {
        yes_no(status.model_api_key_visible).to_string()
    };

    format!(
        "daemon:            running\npid:               {}\ndaemon id:         {}\nstarted at:        {}\nsocket:            {}\nsessions:          {}\ntrace enabled:     {}\nlock owner:        {}\nmodel api_key_env: {}\nmodel base_url:    {}\napi key visible:   {}\nauto-spawn:        {}\njobs enabled:      {}\njobs timezone:     {}",
        status.pid,
        status.daemon_id,
        status.started_at,
        status.socket_path,
        status.session_count,
        yes_no(status.trace_enabled),
        lock_owner,
        status.model_api_key_env.as_deref().unwrap_or("not required"),
        status.model_base_url.as_deref().unwrap_or("(default)"),
        api_key_state,
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

fn repl_mode_from_flags(classic: bool, tui: bool) -> Result<Option<ReplUiMode>> {
    match (classic, tui) {
        (true, true) => anyhow::bail!("choose only one of --classic or --tui"),
        (true, false) => Ok(Some(ReplUiMode::Classic)),
        (false, true) => Ok(Some(ReplUiMode::Tui)),
        (false, false) => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;
    use clap::CommandFactory;

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

    #[test]
    fn cli_help_has_high_value_command_descriptions() {
        let help = Args::command().render_long_help().to_string();
        for expected in [
            "EXAMPLES:",
            "allbert-cli trace show",
            "allbert-cli settings list ui",
            "allbert-cli memory staged list",
            "Inspect, tail, export, and prune durable session traces",
            "settings",
            "Run or resume guided profile setup",
            "Inspect and safely change supported profile settings",
            "Show the daemon-owned activity snapshot",
            "repl",
            "daemon",
        ] {
            assert!(help.contains(expected), "missing help text: {expected}");
        }
    }

    #[test]
    fn cli_error_renderer_appends_remediation_hint() {
        let error = anyhow::anyhow!("failed to connect to the daemon");
        let rendered = render_cli_error(&error);
        assert!(rendered.contains("hint:"));
        assert!(rendered.contains("daemon status"));
    }

    #[test]
    fn home_and_doctor_render_compact_activity_when_present() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let config = Config::default_template();
        let activity = allbert_proto::ActivitySnapshot {
            phase: allbert_proto::ActivityPhase::CallingTool,
            label: "running validation".into(),
            started_at: "2026-04-20T00:00:00Z".into(),
            elapsed_ms: 42_000,
            session_id: "repl-primary".into(),
            channel: ChannelKind::Repl,
            tool_name: Some("cargo".into()),
            tool_summary: Some("test".into()),
            skill_name: None,
            approval_id: None,
            last_progress_at: None,
            stuck_hint: Some("validation is still running".into()),
            next_actions: vec!["wait".into()],
        };

        let home = render_home(&paths, Some(activity.clone()));
        assert!(home.contains("activity:"));
        assert!(home.contains("calling_tool"));
        assert!(home.contains("validation is still running"));

        let doctor = render_doctor(&paths, &config, &[], Some(activity));
        assert!(doctor.contains("doctor:    ok"));
        assert!(doctor.contains("activity:"));
    }

    #[test]
    fn home_and_doctor_omit_activity_without_daemon_snapshot() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        let config = Config::default_template();

        let home = render_home(&paths, None);
        let doctor = render_doctor(&paths, &config, &[], None);

        assert!(!home.contains("activity:"));
        assert!(!doctor.contains("activity:"));
    }
}
