use allbert_daemon::DaemonClient;
use allbert_kernel::{Provider, StatusLineItem};
use allbert_proto::{
    ClientMessage, ConfirmDecisionPayload, InputResponsePayload, KernelEventPayload,
    ModelConfigPayload, ProviderKind, ServerMessage,
};
use anyhow::Result;
use reedline::{DefaultPrompt, DefaultPromptSegment, Reedline, Signal};
use std::io::{self, Write};

use crate::setup::{self, StatusSnapshot};

pub const HELP_TEXT: &str = "\
commands:
  /h        show this help
  /cost     show session cost, today's recorded total, and cap state
  /cost --turn-budget <usd>
            set the next turn's usd budget
  /cost --turn-time <s>
            set the next turn's time budget in seconds
  /cost --override <reason>
            allow the next turn to bypass the daily cap once
  /help     show this help
  /agents   show the generated AGENTS.md routing summary
  /context  show context-window usage and pressure
  /memory routing
            show memory routing policy
  /memory stats
            show durable, staged, episode, and fact counts
  /memory show staged
            list staged memory candidates
  /memory show today
            list staged memory candidates from the last day
  /model    show or change the active model
  /s        show provider, intent, agent, setup, roots, and trace state
  /skills [list|show <name>|search <substring>]
            inspect installed skills and routing metadata
  /setup    rerun guided setup and reload config for this session
  /settings list [group]
            inspect or safely change supported profile settings
  /status   show provider, current agent context, setup, roots, and trace state
  /statusline [show|enable|disable|toggle <item>|add <item>|remove <item>]
            inspect or change TUI status-line items
  /telemetry
            show live model, token, cost, memory, skill, inbox, and trace telemetry
  /exit     leave the REPL
  /quit     leave the REPL
  operator inspection:
    - allbert-cli sessions list
    - allbert-cli sessions show <id>
    - allbert-cli sessions resume <id>
    - allbert-cli sessions forget <id>
    - allbert-cli daemon channels list
    - allbert-cli daemon channels status telegram
    - allbert-cli daemon channels add telegram
    - allbert-cli daemon channels remove telegram
    - allbert-cli approvals list
    - allbert-cli approvals show <approval-id>
    - allbert-cli agents list
    - allbert-cli skills list
    - allbert-cli skills show memory-curator
    - allbert-cli skills show <name>
    - allbert-cli memory status
    - allbert-cli memory verify
    - allbert-cli memory search \"postgres\"
    - allbert-cli memory staged list
    - allbert-cli memory staged show <id>
    - allbert-cli memory promote <id> --confirm
    - allbert-cli memory reject <id> --reason \"not durable\"
    - allbert-cli memory forget <path-or-query> --confirm
    - cat ~/.allbert/AGENTS.md
  memory review flow:
    - \"remember that we use Postgres\"
    - \"review what's staged\"
    - \"promote that\" / \"reject that\"
    - \"what do you remember about Postgres?\"
  ask naturally for recurring work:
    - \"what jobs do I have?\"
    - \"schedule a daily review at 07:00\"
    - \"why did that job fail?\"
    - \"pause it\" / \"resume it\" / \"delete it\"
  common schedule forms:
    - @daily at HH:MM
    - @weekly on monday at HH:MM
    - every 2h
    - once at 2026-04-20T16:00:00Z
  unknown slash commands are rejected locally
  anything else is sent to the daemon-backed kernel session";

pub enum LocalCommand<'a> {
    Exit,
    Help,
    Agents,
    Context,
    Cost(&'a str),
    Memory(&'a str),
    Model(&'a str),
    Setup,
    Skills(&'a str),
    Settings(&'a str),
    Status,
    StatusLine(&'a str),
    Telemetry,
    UnknownSlash(&'a str),
    Turn(&'a str),
}

pub async fn run_loop(
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
) -> Result<()> {
    let mut line_editor = Reedline::create();
    let prompt = DefaultPrompt::new(
        DefaultPromptSegment::Basic("allbert".into()),
        DefaultPromptSegment::Empty,
    );

    loop {
        match line_editor.read_line(&prompt)? {
            Signal::Success(buf) => {
                let trimmed = buf.trim();
                if trimmed.is_empty() {
                    continue;
                }
                match parse_local_command(trimmed) {
                    LocalCommand::Exit => break,
                    LocalCommand::Help => println!("{HELP_TEXT}"),
                    LocalCommand::Agents => {
                        println!("{}", handle_agents_command(paths)?);
                    }
                    LocalCommand::Context => {
                        println!("{}", handle_context_command(client).await?);
                    }
                    LocalCommand::Cost(command) => {
                        handle_cost_command(client, paths, command).await?;
                    }
                    LocalCommand::Memory(command) => {
                        println!("{}", handle_memory_command(paths, command)?);
                    }
                    LocalCommand::Model(command) => {
                        handle_model_command(client, command).await?;
                    }
                    LocalCommand::Setup => {
                        handle_setup_command(client, paths).await?;
                    }
                    LocalCommand::Skills(command) => {
                        println!("{}", handle_skills_command(paths, command)?);
                    }
                    LocalCommand::Settings(command) => {
                        println!("{}", crate::settings_cli::handle_command(paths, command)?);
                    }
                    LocalCommand::Status => {
                        let status = client.session_status().await?;
                        let config = allbert_kernel::Config::load_or_create(paths)?;
                        println!(
                            "{}",
                            setup::render_status(&snapshot_from_proto(&status, &config))
                        );
                    }
                    LocalCommand::StatusLine(command) => {
                        println!("{}", handle_statusline_command(paths, command)?);
                    }
                    LocalCommand::Telemetry => {
                        println!("{}", handle_telemetry_command(client).await?);
                    }
                    LocalCommand::UnknownSlash(command) => {
                        eprintln!(
                            "unknown command: {command}\nuse /help to see supported REPL commands"
                        );
                    }
                    LocalCommand::Turn(command) => {
                        run_turn(client, command).await?;
                    }
                }
            }
            Signal::CtrlC => eprintln!("(ctrl-c) type /exit to leave"),
            Signal::CtrlD => break,
        }
        for message in client.take_pending_events() {
            render_async_server_message(message);
        }
    }
    Ok(())
}

pub fn parse_local_command(input: &str) -> LocalCommand<'_> {
    match input {
        "/exit" | "/quit" => LocalCommand::Exit,
        "/help" | "/h" => LocalCommand::Help,
        "/agents" => LocalCommand::Agents,
        "/context" => LocalCommand::Context,
        command if command.starts_with("/cost") => LocalCommand::Cost(command),
        command if command.starts_with("/memory") => LocalCommand::Memory(command),
        "/setup" => LocalCommand::Setup,
        command if command.starts_with("/skills") => LocalCommand::Skills(command),
        command if command.starts_with("/settings") => LocalCommand::Settings(command),
        "/status" | "/s" => LocalCommand::Status,
        command if command.starts_with("/statusline") => LocalCommand::StatusLine(command),
        "/telemetry" => LocalCommand::Telemetry,
        command if command.starts_with("/model") => LocalCommand::Model(command),
        command if command.starts_with('/') => LocalCommand::UnknownSlash(command),
        other => LocalCommand::Turn(other),
    }
}

async fn run_turn(client: &mut DaemonClient, input: &str) -> Result<()> {
    client.start_turn(input.to_string()).await?;
    loop {
        match client.recv().await? {
            ServerMessage::Event(event) => render_event(event),
            ServerMessage::ActivityUpdate(activity) => render_activity_update(&activity),
            ServerMessage::ConfirmRequest(request) => {
                let decision = prompt_confirm(&request.program, &request.rendered)?;
                client
                    .send(&ClientMessage::ConfirmReply(
                        allbert_proto::ConfirmReplyPayload {
                            request_id: request.request_id,
                            decision,
                        },
                    ))
                    .await?;
            }
            ServerMessage::InputRequest(request) => {
                let response = prompt_input(&request.prompt, request.allow_empty)?;
                client
                    .send(&ClientMessage::InputReply(
                        allbert_proto::InputReplyPayload {
                            request_id: request.request_id,
                            response,
                        },
                    ))
                    .await?;
            }
            ServerMessage::TurnResult(result) => {
                if result.hit_turn_limit {
                    eprintln!("[kernel reported max-turns limit hit]");
                }
                return Ok(());
            }
            ServerMessage::Error(error) => anyhow::bail!(error.message),
            other => {
                anyhow::bail!("unexpected server message during turn: {:?}", other);
            }
        }
    }
}

async fn handle_model_command(client: &mut DaemonClient, command: &str) -> Result<()> {
    let parts: Vec<_> = command.split_whitespace().collect();
    if parts.len() == 1 {
        let model = client.get_model().await?;
        println!(
            "provider: {}\nmodel:    {}\napi key:  {}\nmax toks: {}",
            provider_label(model.provider),
            model.model_id,
            model.api_key_env.as_deref().unwrap_or("not required"),
            model.max_tokens
        );
        return Ok(());
    }

    if parts.len() < 3 {
        println!(
            "usage: /model <anthropic|openrouter|openai|gemini|ollama> <model_id> [api_key_env]"
        );
        return Ok(());
    }

    let provider = match parse_provider(parts[1]) {
        Some(provider) => provider,
        None => {
            println!("unknown provider: {}", parts[1]);
            return Ok(());
        }
    };

    let current = client.get_model().await?;
    let api_key_env = parts
        .get(3)
        .map(|value| (*value).to_string())
        .or_else(|| default_api_key_env(provider, &current));
    let base_url = default_base_url(provider, &current);

    let active = client
        .set_model(ModelConfigPayload {
            provider,
            model_id: parts[2].to_string(),
            api_key_env,
            base_url,
            max_tokens: current.max_tokens,
            context_window_tokens: current.context_window_tokens,
        })
        .await?;

    println!(
        "active model: {} / {}",
        provider_label(active.provider),
        active.model_id
    );
    Ok(())
}

async fn handle_cost_command(
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
    command: &str,
) -> Result<()> {
    let parts: Vec<_> = command.split_whitespace().collect();
    if parts.len() == 1 {
        let status = client.session_status().await?;
        let config = allbert_kernel::Config::load_or_create(paths)?;
        let cap = config
            .limits
            .daily_usd_cap
            .map(|value| format!("${value:.2}"))
            .unwrap_or_else(|| "(disabled)".into());
        println!(
            "session: ${:.6}\ntoday:   ${:.6}\ncap:     {}\nturn budget default: ${:.2}\nturn time default:   {}s",
            status.session_cost_usd, status.today_cost_usd, cap
            , config.limits.max_turn_usd,
            config.limits.max_turn_s
        );
        return Ok(());
    }

    if parts.len() >= 3 && parts[1] == "--override" {
        let reason = command
            .split_once("--override")
            .map(|(_, value)| value.trim())
            .unwrap_or_default();
        if reason.is_empty() {
            println!("usage: /cost --override <reason>");
            return Ok(());
        }
        client.set_cost_override(reason.to_string()).await?;
        println!("daily cost override armed for the next turn");
        return Ok(());
    }

    let mut usd = None;
    let mut seconds = None;
    let mut idx = 1usize;
    while idx < parts.len() {
        match parts[idx] {
            "--turn-budget" => {
                let Some(value) = parts.get(idx + 1) else {
                    println!("usage: /cost --turn-budget <usd>");
                    return Ok(());
                };
                match value.parse::<f64>() {
                    Ok(parsed) if parsed > 0.0 => usd = Some(parsed),
                    _ => {
                        println!("turn budget must be a positive number");
                        return Ok(());
                    }
                }
                idx += 2;
            }
            "--turn-time" => {
                let Some(value) = parts.get(idx + 1) else {
                    println!("usage: /cost --turn-time <seconds>");
                    return Ok(());
                };
                match value.parse::<u64>() {
                    Ok(parsed) if parsed > 0 => seconds = Some(parsed),
                    _ => {
                        println!("turn time must be a positive integer number of seconds");
                        return Ok(());
                    }
                }
                idx += 2;
            }
            _ => {
                println!(
                    "usage: /cost | /cost --override <reason> | /cost --turn-budget <usd> [--turn-time <seconds>]"
                );
                return Ok(());
            }
        }
    }

    if usd.is_some() || seconds.is_some() {
        client.set_turn_budget_override(usd, seconds).await?;
        match (usd, seconds) {
            (Some(usd), Some(seconds)) => {
                println!("next-turn budget armed: ${usd:.2}, {seconds}s");
            }
            (Some(usd), None) => {
                println!("next-turn usd budget armed: ${usd:.2}");
            }
            (None, Some(seconds)) => {
                println!("next-turn time budget armed: {seconds}s");
            }
            (None, None) => {}
        }
        return Ok(());
    }

    println!(
        "usage: /cost | /cost --override <reason> | /cost --turn-budget <usd> [--turn-time <seconds>]"
    );
    Ok(())
}

async fn handle_setup_command(
    client: &mut DaemonClient,
    paths: &allbert_kernel::AllbertPaths,
) -> Result<()> {
    let current = allbert_kernel::Config::load_or_create(paths)?;
    let updated = match setup::run_setup_wizard(paths, &current)? {
        Some(config) => config,
        None => {
            println!("Setup cancelled.");
            return Ok(());
        }
    };

    let warnings = setup::build_startup_warnings(&updated);
    client.reload_session_config().await?;
    println!("Setup updated for this session.");
    for warning in warnings {
        eprintln!("{warning}");
    }
    Ok(())
}

pub async fn handle_telemetry_command(client: &mut DaemonClient) -> Result<String> {
    let telemetry = client.session_telemetry().await?;
    Ok(render_telemetry_summary(&telemetry))
}

pub async fn handle_context_command(client: &mut DaemonClient) -> Result<String> {
    let telemetry = client.session_telemetry().await?;
    let context = match (telemetry.context_used_tokens, telemetry.context_percent) {
        (Some(tokens), Some(percent)) => format!(
            "{} tokens used ({percent:.1}%, {}) of {} configured tokens",
            tokens,
            context_band(percent),
            telemetry.context_window_tokens
        ),
        (Some(tokens), None) => {
            format!("{tokens} tokens used; context window capacity is unknown")
        }
        _ => "context usage is not available yet; run a turn first".into(),
    };
    let recommendation = match telemetry.context_percent {
        Some(percent) if percent >= 95.0 => {
            "recommendation: start a fresh session or reduce context before the next large turn"
        }
        Some(percent) if percent >= 75.0 => {
            "recommendation: continue, but expect less room for long tool output"
        }
        Some(_) => "recommendation: context pressure is healthy",
        None => "recommendation: set model.context_window_tokens for better pressure labels",
    };
    Ok(format!(
        "context\nusage: {context}\nsynopsis bytes: {}\nephemeral bytes: {}\nlast provider tokens: {}\n{recommendation}",
        telemetry.memory.synopsis_bytes,
        telemetry.memory.ephemeral_bytes,
        telemetry
            .last_response_usage
            .as_ref()
            .map(|usage| usage.total_tokens)
            .unwrap_or_default()
    ))
}

pub fn handle_agents_command(paths: &allbert_kernel::AllbertPaths) -> Result<String> {
    Ok(allbert_kernel::refresh_agents_markdown(paths)?)
}

pub fn handle_skills_command(
    paths: &allbert_kernel::AllbertPaths,
    command: &str,
) -> Result<String> {
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/skills"] | ["/skills", "list"] => crate::skills::list_installed_skills(paths),
        ["/skills", "show", name] => crate::skills::show_installed_skill(paths, name),
        ["/skills", "search", query] => crate::skills::search_installed_skills(paths, query),
        _ => Ok("usage: /skills [list|show <name>|search <substring>]".into()),
    }
}

pub fn handle_memory_command(
    paths: &allbert_kernel::AllbertPaths,
    command: &str,
) -> Result<String> {
    let config = allbert_kernel::Config::load_or_create(paths)?;
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/memory", "stats"] => crate::memory_cli::stats(paths, &config),
        ["/memory", "show", "staged"] | ["/memory", "staged", "list"] => {
            crate::memory_cli::staged_list(paths, &config, None, None, Some(10), "text")
        }
        ["/memory", "show", "today"] => {
            crate::memory_cli::staged_list(paths, &config, None, Some("1d"), Some(10), "text")
        }
        ["/memory", "routing"] | ["/memory", "routing", "show"] => {
            Ok(crate::memory_cli::routing_show(&config))
        }
        _ => Ok(
            "usage: /memory stats | /memory show staged | /memory show today | /memory routing [show]"
                .into(),
        ),
    }
}

pub fn handle_statusline_command(
    paths: &allbert_kernel::AllbertPaths,
    command: &str,
) -> Result<String> {
    let mut config = allbert_kernel::Config::load_or_create(paths)?;
    let args = command.split_whitespace().collect::<Vec<_>>();
    let mut changed = false;
    let rendered = match args.as_slice() {
        ["/statusline"] | ["/statusline", "show"] => render_statusline_config(&config),
        ["/statusline", "enable"] => {
            config.repl.tui.status_line.enabled = true;
            changed = true;
            render_statusline_config(&config)
        }
        ["/statusline", "disable"] => {
            config.repl.tui.status_line.enabled = false;
            changed = true;
            render_statusline_config(&config)
        }
        ["/statusline", "toggle", item] => {
            let item = parse_statusline_item(item)?;
            if config.repl.tui.status_line.items.contains(&item) {
                config
                    .repl
                    .tui
                    .status_line
                    .items
                    .retain(|value| *value != item);
            } else {
                config.repl.tui.status_line.items.push(item);
            }
            if config.repl.tui.status_line.items.is_empty() {
                config
                    .repl
                    .tui
                    .status_line
                    .items
                    .push(StatusLineItem::Model);
            }
            changed = true;
            render_statusline_config(&config)
        }
        ["/statusline", "add", item] => {
            let item = parse_statusline_item(item)?;
            if !config.repl.tui.status_line.items.contains(&item) {
                config.repl.tui.status_line.items.push(item);
                changed = true;
            }
            render_statusline_config(&config)
        }
        ["/statusline", "remove", item] => {
            let item = parse_statusline_item(item)?;
            config
                .repl
                .tui
                .status_line
                .items
                .retain(|value| *value != item);
            if config.repl.tui.status_line.items.is_empty() {
                config
                    .repl
                    .tui
                    .status_line
                    .items
                    .push(StatusLineItem::Model);
            }
            changed = true;
            render_statusline_config(&config)
        }
        _ => {
            "usage: /statusline [show|enable|disable|toggle <item>|add <item>|remove <item>]".into()
        }
    };
    if changed {
        config.persist(paths)?;
    }
    Ok(rendered)
}

fn render_statusline_config(config: &allbert_kernel::Config) -> String {
    format!(
        "status line: {}\nitems: {}\ncatalog: {}",
        if config.repl.tui.status_line.enabled {
            "enabled"
        } else {
            "disabled"
        },
        config
            .repl
            .tui
            .status_line
            .items
            .iter()
            .map(|item| item.label())
            .collect::<Vec<_>>()
            .join(", "),
        StatusLineItem::CATALOG
            .iter()
            .map(|item| item.label())
            .collect::<Vec<_>>()
            .join(", ")
    )
}

fn parse_statusline_item(raw: &str) -> Result<StatusLineItem> {
    StatusLineItem::CATALOG
        .into_iter()
        .find(|item| item.label() == raw.trim())
        .ok_or_else(|| anyhow::anyhow!("unknown status-line item `{raw}`"))
}

fn render_telemetry_summary(snapshot: &allbert_proto::TelemetrySnapshot) -> String {
    format!(
        "telemetry\nsession: {}\nchannel: {:?}\nmodel: {} / {}\ncontext: {}\ntokens: last={} session={}\ncost: session=${:.6} today=${:.6}\nmemory: durable={} staged={} episode={} fact={}\nskills: {}\ninbox: {}\ntrace: {}",
        snapshot.session_id,
        snapshot.channel,
        snapshot.provider,
        snapshot.model.model_id,
        match (snapshot.context_used_tokens, snapshot.context_percent) {
            (Some(tokens), Some(percent)) => {
                format!("{tokens} ({percent:.1}%, {})", context_band(percent))
            }
            (Some(tokens), None) => format!("{tokens} (cap unknown)"),
            _ => "cap unknown".into(),
        },
        snapshot
            .last_response_usage
            .as_ref()
            .map(|usage| usage.total_tokens)
            .unwrap_or_default(),
        snapshot.session_usage.total_tokens,
        snapshot.session_cost_usd,
        snapshot.today_cost_usd,
        snapshot.memory.durable_count,
        snapshot.memory.staged_count,
        snapshot.memory.episode_count,
        snapshot.memory.fact_count,
        if snapshot.active_skills.is_empty() {
            "(none)".into()
        } else {
            snapshot.active_skills.join(", ")
        },
        snapshot.inbox_count,
        if snapshot.trace_enabled { "on" } else { "off" },
    )
}

fn context_band(percent: f64) -> &'static str {
    if percent >= 95.0 {
        "full"
    } else if percent >= 75.0 {
        "heavy"
    } else if percent >= 40.0 {
        "moderate"
    } else {
        "light"
    }
}

fn prompt_confirm(program: &str, rendered: &str) -> Result<ConfirmDecisionPayload> {
    let durable_job_change = matches!(
        program,
        "upsert_job" | "pause_job" | "resume_job" | "remove_job" | "promote_staged_memory"
    );
    if durable_job_change {
        print!("Allbert wants to make this durable scheduling change:\n{rendered}\n[y/N] ");
    } else {
        print!("Allbert wants your confirmation:\n{rendered}\n[y/N/always] ");
    }
    io::stdout().flush()?;

    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    let choice = buf.trim().to_ascii_lowercase();
    Ok(if durable_job_change {
        match choice.as_str() {
            "y" | "yes" => ConfirmDecisionPayload::AllowOnce,
            _ => ConfirmDecisionPayload::Deny,
        }
    } else {
        match choice.as_str() {
            "y" | "yes" => ConfirmDecisionPayload::AllowOnce,
            "always" | "a" => ConfirmDecisionPayload::AllowSession,
            _ => ConfirmDecisionPayload::Deny,
        }
    })
}

fn prompt_input(prompt: &str, allow_empty: bool) -> Result<InputResponsePayload> {
    println!("{prompt}");
    print!("> ");
    io::stdout().flush()?;

    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    let value = buf.trim_end_matches(['\r', '\n']).to_string();
    if !allow_empty && value.trim().is_empty() {
        Ok(InputResponsePayload::Cancelled)
    } else {
        Ok(InputResponsePayload::Submitted(value))
    }
}

fn render_event(event: KernelEventPayload) {
    match event {
        KernelEventPayload::SkillTier1Surfaced { .. } => {}
        KernelEventPayload::SkillTier2Activated { .. } => {}
        KernelEventPayload::SkillTier3Referenced { .. } => {}
        KernelEventPayload::AssistantText(text) => println!("{text}"),
        KernelEventPayload::JobFailed {
            job_name,
            run_id,
            ended_at,
            stop_reason,
        } => {
            eprintln!(
                "[job failure] {} run {} at {}{}",
                job_name,
                run_id,
                ended_at,
                stop_reason
                    .map(|value| format!(": {value}"))
                    .unwrap_or_default()
            );
        }
        KernelEventPayload::ToolCall { name, .. } => eprintln!("[tool call: {name}]"),
        KernelEventPayload::ToolResult { name, ok, .. } => {
            let tag = if ok { "ok" } else { "err" };
            eprintln!("[tool result: {name} ({tag})]");
        }
        KernelEventPayload::Cost { usd_estimate: _ } => {}
        KernelEventPayload::TurnDone { hit_turn_limit } => {
            if hit_turn_limit {
                eprintln!("[turn hit max-turns limit]");
            }
        }
    }
}

pub fn render_async_server_message(message: ServerMessage) {
    match message {
        ServerMessage::Event(event) => render_event(event),
        ServerMessage::ActivityUpdate(activity) => render_activity_update(&activity),
        _ => {}
    }
}

fn render_activity_update(activity: &allbert_proto::ActivitySnapshot) {
    if matches!(activity.phase, allbert_proto::ActivityPhase::Idle) {
        return;
    }
    eprintln!("[activity] {}", activity.label);
}

fn parse_provider(raw: &str) -> Option<ProviderKind> {
    Provider::parse(raw).map(Provider::to_proto_kind)
}

fn provider_label(provider: ProviderKind) -> &'static str {
    Provider::from_proto_kind(provider).label()
}

fn default_api_key_env(provider: ProviderKind, current: &ModelConfigPayload) -> Option<String> {
    if current.provider == provider {
        current.api_key_env.clone()
    } else {
        Provider::from_proto_kind(provider)
            .default_api_key_env()
            .map(str::to_string)
    }
}

fn default_base_url(provider: ProviderKind, current: &ModelConfigPayload) -> Option<String> {
    if current.provider == provider {
        current.base_url.clone()
    } else {
        Provider::from_proto_kind(provider)
            .default_base_url()
            .map(str::to_string)
    }
}

fn snapshot_from_proto(
    status: &allbert_proto::SessionStatus,
    config: &allbert_kernel::Config,
) -> StatusSnapshot {
    StatusSnapshot {
        provider: status.provider.clone(),
        model_id: status.model.model_id.clone(),
        api_key_env: status.model.api_key_env.clone(),
        api_key_present: status.api_key_present,
        setup_version: status.setup_version,
        bootstrap_pending: status.bootstrap_pending,
        trusted_roots: status.trusted_roots.iter().map(Into::into).collect(),
        skill_count: status.skill_count,
        trace_enabled: status.trace_enabled,
        daemon_auto_spawn: config.daemon.auto_spawn,
        jobs_enabled: config.jobs.enabled,
        jobs_default_timezone: config.jobs.default_timezone.clone(),
        root_agent_name: status.root_agent_name.clone(),
        last_agent_stack: status.last_agent_stack.clone(),
        last_resolved_intent: status.last_resolved_intent.clone(),
        repl_ui: config.repl.ui.label().into(),
        memory_routing: config.memory.routing.mode.label().into(),
        status_line_items: if config.repl.tui.status_line.enabled {
            config
                .repl
                .tui
                .status_line
                .items
                .iter()
                .map(|item| item.label().into())
                .collect()
        } else {
            Vec::new()
        },
    }
}

#[cfg(test)]
mod tests {
    use super::{parse_local_command, LocalCommand};

    #[test]
    fn short_help_alias_is_local() {
        assert!(matches!(parse_local_command("/h"), LocalCommand::Help));
    }

    #[test]
    fn short_status_alias_is_local() {
        assert!(matches!(parse_local_command("/s"), LocalCommand::Status));
    }

    #[test]
    fn cost_override_is_local() {
        assert!(matches!(
            parse_local_command("/cost --override release smoke"),
            LocalCommand::Cost("/cost --override release smoke")
        ));
    }

    #[test]
    fn v0_11_public_slash_commands_are_local() {
        assert!(matches!(
            parse_local_command("/telemetry"),
            LocalCommand::Telemetry
        ));
        assert!(matches!(
            parse_local_command("/statusline toggle memory"),
            LocalCommand::StatusLine("/statusline toggle memory")
        ));
        assert!(matches!(
            parse_local_command("/memory stats"),
            LocalCommand::Memory("/memory stats")
        ));
        assert!(matches!(
            parse_local_command("/memory routing"),
            LocalCommand::Memory("/memory routing")
        ));
    }

    #[test]
    fn v0_12_1_operator_legibility_slash_commands_are_local() {
        assert!(matches!(
            parse_local_command("/agents"),
            LocalCommand::Agents
        ));
        assert!(matches!(
            parse_local_command("/context"),
            LocalCommand::Context
        ));
        assert!(matches!(
            parse_local_command("/skills search memory"),
            LocalCommand::Skills("/skills search memory")
        ));
        assert!(matches!(
            parse_local_command("/settings list ui"),
            LocalCommand::Settings("/settings list ui")
        ));
        assert!(matches!(
            parse_local_command("/memory show staged"),
            LocalCommand::Memory("/memory show staged")
        ));
        assert!(matches!(
            parse_local_command("/memory show today"),
            LocalCommand::Memory("/memory show today")
        ));
    }

    #[test]
    fn unknown_slash_command_does_not_fall_through_to_model() {
        assert!(matches!(
            parse_local_command("/not-a-command"),
            LocalCommand::UnknownSlash("/not-a-command")
        ));
    }
}
