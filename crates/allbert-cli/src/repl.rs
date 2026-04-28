use allbert_daemon::DaemonClient;
use allbert_kernel_services::{Provider, StatusLineItem};
use allbert_proto::{
    ActivityPhase, ActivitySnapshot, ApprovalContext, ClientMessage, ConfirmDecisionPayload,
    DiagnosisRunRequest, InputResponsePayload, KernelEventPayload, ModelConfigPayload,
    ProviderKind, ServerMessage,
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
  /adapters [status|list|history]
            inspect local personalization adapter state
  /activity show what the daemon says Allbert is doing right now
  /context  show context-window usage and pressure
  /diagnose [run|list|show <id>]
            create and inspect bounded daemon-owned self-diagnosis reports
  /inbox [list|show <id>|accept <id>|reject <id>]
            review and resolve approval inbox items
  /memory routing
            show memory routing policy
  /memory stats
            show durable, staged, episode, and fact counts
  /memory show staged
            list staged memory candidates
  /memory show today
            list staged memory candidates from the last day
  /memory staged show <id>
            show one staged memory candidate
  /model    show or change the active model
  /rag [status|search <query>|rebuild [--stale-only] [--vectors]|gc [--dry-run]]
            inspect and maintain daemon-owned RAG retrieval state
  /self-improvement config show
            inspect self-improvement source, worktree, and install policy
  /self-improvement diff <approval-id>
            show the patch artifact for a reviewed self-improvement approval
  /self-improvement install <approval-id>
            install an accepted self-improvement patch through the reviewed path
  /self-improvement gc [--dry-run]
            clean stale self-improvement worktrees
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
  /trace [show|show-span|tail|export|settings]
            inspect durable spans, tail completed spans, export OTLP-JSON, or open trace settings
  /utilities [discover|list|show <id>|enable <id>|disable <id>|doctor]
            inspect and manage operator-enabled local utility state
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

const SUPPORTED_SLASH_COMMANDS: &[&str] = &[
    "/activity",
    "/adapters",
    "/agents",
    "/context",
    "/cost",
    "/diagnose",
    "/exit",
    "/h",
    "/help",
    "/inbox",
    "/memory",
    "/model",
    "/quit",
    "/rag",
    "/s",
    "/self-improvement",
    "/settings",
    "/setup",
    "/skills",
    "/status",
    "/statusline",
    "/telemetry",
    "/trace",
    "/utilities",
];

pub enum LocalCommand<'a> {
    Exit,
    Help,
    Agents,
    Activity,
    Adapters(&'a str),
    Context,
    Cost(&'a str),
    Diagnose(&'a str),
    Inbox(&'a str),
    Memory(&'a str),
    Model(&'a str),
    Rag(&'a str),
    SelfImprovement(&'a str),
    Setup,
    Skills(&'a str),
    Settings(&'a str),
    Status,
    StatusLine(&'a str),
    Telemetry,
    Trace(&'a str),
    Utilities(&'a str),
    UnknownSlash(&'a str),
    Turn(&'a str),
}

pub async fn run_loop(
    client: &mut DaemonClient,
    paths: &allbert_kernel_services::AllbertPaths,
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
                if let Some(hint) = slash_argument_hint(trimmed) {
                    println!("{hint}");
                    continue;
                }
                match parse_local_command(trimmed) {
                    LocalCommand::Exit => break,
                    LocalCommand::Help => println!("{HELP_TEXT}"),
                    LocalCommand::Agents => {
                        println!("{}", handle_agents_command(paths)?);
                    }
                    LocalCommand::Adapters(command) => {
                        println!("{}", handle_adapters_command(paths, command)?);
                    }
                    LocalCommand::Activity => {
                        println!("{}", handle_activity_command(client).await?);
                    }
                    LocalCommand::Context => {
                        println!("{}", handle_context_command(client).await?);
                    }
                    LocalCommand::Cost(command) => {
                        handle_cost_command(client, paths, command).await?;
                    }
                    LocalCommand::Diagnose(command) => {
                        println!("{}", handle_diagnose_command(client, command).await?);
                    }
                    LocalCommand::Inbox(command) => {
                        println!("{}", handle_inbox_command(client, command).await?);
                    }
                    LocalCommand::Memory(command) => {
                        println!("{}", handle_memory_command(paths, command)?);
                    }
                    LocalCommand::Model(command) => {
                        handle_model_command(client, command).await?;
                    }
                    LocalCommand::Rag(command) => {
                        println!("{}", handle_rag_command(client, command).await?);
                    }
                    LocalCommand::SelfImprovement(command) => {
                        let config = allbert_kernel_services::Config::load_or_create(paths)?;
                        println!(
                            "{}",
                            handle_self_improvement_command(paths, &config, command)?
                        );
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
                        let config = allbert_kernel_services::Config::load_or_create(paths)?;
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
                    LocalCommand::Trace(command) => {
                        println!("{}", handle_trace_command(client, paths, command).await?);
                    }
                    LocalCommand::Utilities(command) => {
                        println!("{}", handle_utilities_command(client, command).await?);
                    }
                    LocalCommand::UnknownSlash(command) => {
                        eprintln!("{}", unknown_slash_guidance(command));
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

pub fn unknown_slash_guidance(command: &str) -> String {
    let command_name = slash_command_name(command);
    let mut rendered = format!("unknown command: {command_name}");
    if let Some(suggestion) = nearest_slash_command(command_name) {
        rendered.push_str(&format!("\ndid you mean `{suggestion}`?"));
    }
    rendered.push_str("\nuse /help to see supported REPL commands");
    rendered
}

pub fn slash_argument_hint(input: &str) -> Option<&'static str> {
    if !input.trim_end().ends_with("--") {
        return None;
    }
    match slash_command_name(input) {
        "/cost" => Some("hint: /cost --turn-budget <usd> | --turn-time <seconds> | --override <reason>"),
        "/diagnose" => Some("hint: /diagnose run | list | show <id>"),
        "/inbox" => Some("hint: /inbox list --include-resolved | accept <id> --reason <text> | reject <id> --reason <text>"),
        "/memory" => Some("hint: /memory staged list | staged show <id> | show staged | show today | routing show"),
        "/self-improvement" => Some("hint: /self-improvement install <approval-id> --allow-needs-review | gc --dry-run"),
        "/settings" => Some("hint: /settings list <group> | show <key> | set <key> <value> | reset <key>"),
        "/adapters" => Some("hint: /adapters status | list | history"),
        "/trace" => Some("hint: /trace show [session] | show-span <id> [--session <session>] | tail [session] | export [session] | settings"),
        "/utilities" => Some("hint: /utilities discover | list | show <id> | enable <id> | disable <id> | doctor"),
        _ => None,
    }
}

fn slash_command_name(input: &str) -> &str {
    input.split_whitespace().next().unwrap_or(input)
}

fn nearest_slash_command(command: &str) -> Option<&'static str> {
    SUPPORTED_SLASH_COMMANDS
        .iter()
        .copied()
        .filter_map(|candidate| {
            let distance = edit_distance(command, candidate);
            (distance <= 2).then_some((candidate, distance))
        })
        .min_by_key(|(candidate, distance)| (*distance, *candidate))
        .map(|(candidate, _)| candidate)
}

fn edit_distance(left: &str, right: &str) -> usize {
    let left = left.chars().collect::<Vec<_>>();
    let right = right.chars().collect::<Vec<_>>();
    let mut previous = (0..=right.len()).collect::<Vec<_>>();
    let mut current = vec![0; right.len() + 1];
    for (i, left_ch) in left.iter().enumerate() {
        current[0] = i + 1;
        for (j, right_ch) in right.iter().enumerate() {
            let substitution = previous[j] + usize::from(left_ch != right_ch);
            let insertion = current[j] + 1;
            let deletion = previous[j + 1] + 1;
            current[j + 1] = substitution.min(insertion).min(deletion);
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[right.len()]
}

pub fn parse_local_command(input: &str) -> LocalCommand<'_> {
    match input {
        "/exit" | "/quit" => LocalCommand::Exit,
        "/help" | "/h" => LocalCommand::Help,
        "/agents" => LocalCommand::Agents,
        command if command.starts_with("/adapters") => LocalCommand::Adapters(command),
        "/activity" => LocalCommand::Activity,
        "/context" => LocalCommand::Context,
        command if command.starts_with("/cost") => LocalCommand::Cost(command),
        command if command.starts_with("/diagnose") => LocalCommand::Diagnose(command),
        command if command.starts_with("/inbox") => LocalCommand::Inbox(command),
        command if command.starts_with("/memory") => LocalCommand::Memory(command),
        command if command.starts_with("/self-improvement") => {
            LocalCommand::SelfImprovement(command)
        }
        command if command.starts_with("/rag") => LocalCommand::Rag(command),
        "/setup" => LocalCommand::Setup,
        command if command.starts_with("/skills") => LocalCommand::Skills(command),
        command if command.starts_with("/settings") => LocalCommand::Settings(command),
        "/status" | "/s" => LocalCommand::Status,
        command if command.starts_with("/statusline") => LocalCommand::StatusLine(command),
        "/telemetry" => LocalCommand::Telemetry,
        command if command.starts_with("/trace") => LocalCommand::Trace(command),
        command if command.starts_with("/utilities") => LocalCommand::Utilities(command),
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
            ServerMessage::TraceSpan(span) => {
                eprintln!("[trace] {}", crate::trace_cli::render_span_compact(&span));
            }
            ServerMessage::ConfirmRequest(request) => {
                let decision = prompt_confirm(
                    &request.program,
                    request.context.as_ref(),
                    &request.rendered,
                )?;
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
            ServerMessage::Error(error) => {
                anyhow::bail!(allbert_kernel_services::append_error_hint(&error.message))
            }
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

pub async fn handle_rag_command(client: &mut DaemonClient, command: &str) -> Result<String> {
    let trimmed = command.trim();
    if trimmed == "/rag" || trimmed == "/rag status" {
        let status = client.rag_status(false).await?;
        let mut lines = vec![
            format!(
                "rag: {}",
                if status.enabled {
                    "enabled"
                } else {
                    "disabled"
                }
            ),
            format!("mode: {}", status.mode),
            format!("sources: {}", status.source_count),
            format!("chunks: {}", status.chunk_count),
            format!(
                "vectors: {} ({})",
                status.vector_count, status.vector_posture
            ),
        ];
        if let Some(reason) = status.degraded_reason {
            lines.push(format!("note: {reason}"));
        }
        return Ok(lines.join("\n"));
    }

    if let Some(query) = trimmed.strip_prefix("/rag search ") {
        let query = query.trim();
        if query.is_empty() {
            return Ok("usage: /rag search <query>".into());
        }
        let response = client
            .rag_search(
                query.to_string(),
                Vec::new(),
                None,
                Vec::new(),
                None,
                Some(5),
                false,
            )
            .await?;
        if response.results.is_empty() {
            let mut rendered = "no RAG results".to_string();
            if let Some(reason) = response.degraded_reason {
                rendered.push_str(&format!("\nnote: {reason}"));
            }
            return Ok(rendered);
        }
        let mut lines = vec![format!(
            "rag search: {} result(s), mode={}, vectors={}",
            response.results.len(),
            response.mode,
            response.vector_posture
        )];
        for (idx, result) in response.results.iter().enumerate() {
            lines.push(format!(
                "{}. [{}] {} ({})\n{}",
                idx + 1,
                result.source_kind,
                result.title,
                result.source_id,
                result.snippet
            ));
        }
        if let Some(reason) = response.degraded_reason {
            lines.push(format!("note: {reason}"));
        }
        return Ok(lines.join("\n"));
    }

    if trimmed.starts_with("/rag rebuild") {
        let parts: Vec<_> = trimmed.split_whitespace().collect();
        let stale_only = parts.contains(&"--stale-only");
        let include_vectors = parts.contains(&"--vectors") && !parts.contains(&"--no-vectors");
        let summary = client
            .rag_rebuild_start(stale_only, Vec::new(), None, Vec::new(), include_vectors)
            .await?;
        return Ok(format!(
            "rag rebuild: {}\nrun: {}\nsources: {}\nchunks: {}\nvectors: {}\nelapsed_ms: {}\n{}",
            summary.status,
            summary.run_id,
            summary.source_count,
            summary.chunk_count,
            summary.vector_count,
            summary.elapsed_ms,
            summary.message
        ));
    }

    if trimmed.starts_with("/rag gc") {
        let dry_run = trimmed.split_whitespace().any(|part| part == "--dry-run");
        let summary = client.rag_gc(dry_run).await?;
        return Ok(format!(
            "rag gc: {}\norphans: {}\nvacuumed: {}",
            if summary.dry_run {
                "dry-run"
            } else {
                "applied"
            },
            summary.orphan_chunks,
            if summary.vacuumed { "yes" } else { "no" }
        ));
    }

    Ok(
        "usage: /rag [status|search <query>|rebuild [--stale-only] [--vectors]|gc [--dry-run]]"
            .into(),
    )
}

async fn handle_cost_command(
    client: &mut DaemonClient,
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<()> {
    if let Some(hint) = slash_argument_hint(command) {
        println!("{hint}");
        return Ok(());
    }
    let parts: Vec<_> = command.split_whitespace().collect();
    if parts.len() == 1 {
        let status = client.session_status().await?;
        let config = allbert_kernel_services::Config::load_or_create(paths)?;
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
    paths: &allbert_kernel_services::AllbertPaths,
) -> Result<()> {
    let current = allbert_kernel_services::Config::load_or_create(paths)?;
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

pub async fn handle_activity_command(client: &mut DaemonClient) -> Result<String> {
    let activity = client.activity_snapshot().await?;
    Ok(render_activity_snapshot(&activity))
}

pub async fn handle_trace_command(
    client: &mut DaemonClient,
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/trace"] | ["/trace", "show"] => {
            let spans = client.trace_show(None).await?;
            let session = spans
                .first()
                .map(|span| span.session_id.as_str())
                .unwrap_or("(resolved)");
            Ok(crate::trace_cli::render_span_tree(session, &spans, 0))
        }
        ["/trace", "show", session] => {
            let spans = client.trace_show(Some((*session).to_string())).await?;
            Ok(crate::trace_cli::render_span_tree(session, &spans, 0))
        }
        ["/trace", "show-span", span_id] => {
            let span = client.trace_show_span(None, (*span_id).to_string()).await?;
            Ok(crate::trace_cli::render_span_detail(&span))
        }
        ["/trace", "show-span", span_id, "--session", session] => {
            let span = client
                .trace_show_span(Some((*session).to_string()), (*span_id).to_string())
                .await?;
            Ok(crate::trace_cli::render_span_detail(&span))
        }
        ["/trace", "tail"] => {
            let session = client.trace_subscribe(None).await?;
            Ok(format!("tailing trace session {session}; completed spans will appear inline"))
        }
        ["/trace", "tail", session] => {
            let session = client.trace_subscribe(Some((*session).to_string())).await?;
            Ok(format!("tailing trace session {session}; completed spans will appear inline"))
        }
        ["/trace", "export"] => {
            let telemetry = client.session_telemetry().await?;
            let config = allbert_kernel_services::Config::load_or_create(paths)?;
            crate::trace_cli::export(paths, &config, &telemetry.session_id, "otlp-json", None)
        }
        ["/trace", "export", session] => {
            let config = allbert_kernel_services::Config::load_or_create(paths)?;
            crate::trace_cli::export(paths, &config, session, "otlp-json", None)
        }
        ["/trace", "export", session, "--format", format] => {
            let config = allbert_kernel_services::Config::load_or_create(paths)?;
            crate::trace_cli::export(paths, &config, session, format, None)
        }
        ["/trace", "export", "--format", format] => {
            let telemetry = client.session_telemetry().await?;
            let config = allbert_kernel_services::Config::load_or_create(paths)?;
            crate::trace_cli::export(paths, &config, &telemetry.session_id, format, None)
        }
        ["/trace", "settings"] => crate::settings_cli::handle_command(paths, "/settings show trace"),
        _ => Ok("usage: /trace [show [session] | show-span <id> [--session <session>] | tail [session] | export [session] | settings]".into()),
    }
}

pub async fn handle_diagnose_command(client: &mut DaemonClient, command: &str) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/diagnose"] | ["/diagnose", "run"] => {
            let summary = client
                .diagnose_run(DiagnosisRunRequest {
                    session_id: None,
                    lookback_days: None,
                    remediation: None,
                })
                .await?;
            Ok(crate::diagnose_cli::render_run_summary_payload(&summary))
        }
        ["/diagnose", "list"] => {
            let summaries = client.diagnose_list(None).await?;
            Ok(crate::diagnose_cli::render_report_list_payload(&summaries))
        }
        ["/diagnose", "show", diagnosis_id] => {
            let report = client.diagnose_show((*diagnosis_id).to_string()).await?;
            Ok(crate::diagnose_cli::render_report_payload(&report, false))
        }
        _ => Ok("usage: /diagnose [run|list|show <id>]".into()),
    }
}

pub async fn handle_utilities_command(client: &mut DaemonClient, command: &str) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/utilities"] | ["/utilities", "list"] | ["/utilities", "status"] => {
            let entries = client.utilities_list().await?;
            Ok(crate::utilities_cli::render_enabled_payload(&entries))
        }
        ["/utilities", "discover"] => {
            let entries = client.utilities_discover().await?;
            Ok(crate::utilities_cli::render_discovery_payload(&entries))
        }
        ["/utilities", "show", utility_id] => {
            let entry = client.utilities_show((*utility_id).to_string()).await?;
            Ok(crate::utilities_cli::render_show_payload(&entry))
        }
        ["/utilities", "enable", utility_id] => {
            let entry = client
                .utilities_enable(allbert_proto::UtilityEnableRequest {
                    utility_id: (*utility_id).to_string(),
                    path: None,
                })
                .await?;
            Ok(crate::utilities_cli::render_enable_payload(&entry))
        }
        ["/utilities", "disable", utility_id] => {
            client.utilities_disable((*utility_id).to_string()).await?;
            Ok(format!("disabled utility {utility_id}"))
        }
        ["/utilities", "doctor"] => {
            let report = client.utilities_doctor().await?;
            Ok(crate::utilities_cli::render_doctor_payload(&report))
        }
        _ => Ok(
            "usage: /utilities [discover|list|show <id>|enable <id>|disable <id>|doctor]".into(),
        ),
    }
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

pub fn handle_agents_command(paths: &allbert_kernel_services::AllbertPaths) -> Result<String> {
    Ok(allbert_kernel_services::refresh_agents_markdown(paths)?)
}

pub fn handle_adapters_command(
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let store = allbert_kernel_services::AdapterStore::new(paths.clone());
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/adapters"] | ["/adapters", "status"] => Ok(match store.active()? {
            Some(active) => format!(
                "active adapter: {} ({})",
                active.adapter_id, active.base_model.model_id
            ),
            None => "active adapter: none".into(),
        }),
        ["/adapters", "list"] => {
            let rows = store
                .list()?
                .into_iter()
                .map(|manifest| format!("{}\t{:?}", manifest.adapter_id, manifest.overall))
                .collect::<Vec<_>>();
            Ok(if rows.is_empty() {
                "no installed adapters".into()
            } else {
                rows.join("\n")
            })
        }
        ["/adapters", "history"] => {
            let rows = store
                .history(Some(10))?
                .into_iter()
                .map(|entry| format!("{}\t{}\t{}", entry.at, entry.action, entry.adapter_id))
                .collect::<Vec<_>>();
            Ok(if rows.is_empty() {
                "no adapter history".into()
            } else {
                rows.join("\n")
            })
        }
        _ => Ok("usage: /adapters [status|list|history]".into()),
    }
}

pub fn handle_skills_command(
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/skills"] | ["/skills", "list"] => crate::skills::list_installed_skills(paths),
        ["/skills", "show", name] => crate::skills::show_installed_skill(paths, name),
        ["/skills", "search", query] => crate::skills::search_installed_skills(paths, query),
        _ => Ok("usage: /skills [list|show <name>|search <substring>]".into()),
    }
}

pub fn handle_memory_command(
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let config = allbert_kernel_services::Config::load_or_create(paths)?;
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/memory", "stats"] => crate::memory_cli::stats(paths, &config),
        ["/memory", "show", "staged"] | ["/memory", "staged", "list"] => {
            crate::memory_cli::staged_list(paths, &config, None, None, Some(10), "text")
        }
        ["/memory", "show", "today"] => {
            crate::memory_cli::staged_list(paths, &config, None, Some("1d"), Some(10), "text")
        }
        ["/memory", "staged", "show", id] => crate::memory_cli::staged_show(paths, &config, id),
        ["/memory", "routing"] | ["/memory", "routing", "show"] => {
            Ok(crate::memory_cli::routing_show(&config))
        }
        _ => Ok(
            "usage: /memory stats | /memory show staged | /memory show today | /memory staged list|show <id> | /memory routing [show]"
                .into(),
        ),
    }
}

pub async fn handle_inbox_command(client: &mut DaemonClient, command: &str) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/inbox"] | ["/inbox", "list"] => {
            let approvals = client
                .list_inbox(None, None, false)
                .await?
                .into_iter()
                .map(crate::approvals::ApprovalView::from)
                .collect::<Vec<_>>();
            crate::approvals::render_list_entries(&approvals, false)
        }
        ["/inbox", "list", "--include-resolved"] => {
            let approvals = client
                .list_inbox(None, None, true)
                .await?
                .into_iter()
                .map(crate::approvals::ApprovalView::from)
                .collect::<Vec<_>>();
            crate::approvals::render_list_entries(&approvals, false)
        }
        ["/inbox", "show", approval_id] => {
            let approval = client.show_inbox_approval(approval_id).await?;
            crate::approvals::render_show_entry(
                &crate::approvals::ApprovalView::from(approval),
                false,
            )
        }
        ["/inbox", "accept", approval_id, ..] => {
            let reason = parse_reason_tail(command);
            let result = client
                .resolve_inbox_approval(approval_id, true, reason)
                .await?;
            Ok(crate::approvals::render_resolution(&result))
        }
        ["/inbox", "reject", approval_id, ..] => {
            let reason = parse_reason_tail(command);
            let result = client
                .resolve_inbox_approval(approval_id, false, reason)
                .await?;
            Ok(crate::approvals::render_resolution(&result))
        }
        _ => Ok("usage: /inbox list [--include-resolved] | /inbox show <id> | /inbox accept <id> [--reason <text>] | /inbox reject <id> [--reason <text>]".into()),
    }
}

fn parse_reason_tail(command: &str) -> Option<String> {
    command
        .split_once("--reason")
        .map(|(_, reason)| reason.trim().to_string())
        .filter(|reason| !reason.is_empty())
}

pub fn handle_self_improvement_command(
    paths: &allbert_kernel_services::AllbertPaths,
    config: &allbert_kernel_services::Config,
    command: &str,
) -> Result<String> {
    if let Some(hint) = slash_argument_hint(command) {
        return Ok(hint.into());
    }
    let args = command.split_whitespace().collect::<Vec<_>>();
    match args.as_slice() {
        ["/self-improvement", "config", "show"] => {
            crate::self_improvement_cli::config_show(paths, config)
        }
        ["/self-improvement", "config", "set", "--source-checkout", source_checkout] => {
            crate::self_improvement_cli::config_set_source_checkout(paths, config, source_checkout)
        }
        ["/self-improvement", "diff", approval_id] => {
            crate::self_improvement_cli::diff(paths, approval_id)
        }
        ["/self-improvement", "install", approval_id] => {
            crate::self_improvement_cli::install(paths, config, approval_id, false)
        }
        ["/self-improvement", "install", approval_id, "--allow-needs-review"] => {
            crate::self_improvement_cli::install(paths, config, approval_id, true)
        }
        ["/self-improvement", "gc"] => crate::self_improvement_cli::gc(paths, config, false),
        ["/self-improvement", "gc", "--dry-run"] => {
            crate::self_improvement_cli::gc(paths, config, true)
        }
        _ => Ok("usage: /self-improvement config show|set --source-checkout <path> | /self-improvement diff <approval-id> | /self-improvement install <approval-id> [--allow-needs-review] | /self-improvement gc [--dry-run]".into()),
    }
}

pub fn handle_statusline_command(
    paths: &allbert_kernel_services::AllbertPaths,
    command: &str,
) -> Result<String> {
    let mut config = allbert_kernel_services::Config::load_or_create(paths)?;
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

fn render_statusline_config(config: &allbert_kernel_services::Config) -> String {
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

fn prompt_confirm(
    program: &str,
    context: Option<&ApprovalContext>,
    rendered: &str,
) -> Result<ConfirmDecisionPayload> {
    let durable_job_change = matches!(
        program,
        "upsert_job" | "pause_job" | "resume_job" | "remove_job" | "promote_staged_memory"
    );
    let context = context
        .map(crate::approvals::render_approval_context)
        .unwrap_or_default();
    if durable_job_change {
        print!(
            "Allbert wants to make this durable scheduling change:\n{context}{rendered}\n[y/N] "
        );
    } else {
        print!("Allbert wants your confirmation:\n{context}{rendered}\n[y/N/always] ");
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
        ServerMessage::TraceSpan(span) => {
            eprintln!("[trace] {}", crate::trace_cli::render_span_compact(&span));
        }
        _ => {}
    }
}

fn render_activity_update(activity: &allbert_proto::ActivitySnapshot) {
    if matches!(activity.phase, allbert_proto::ActivityPhase::Idle) {
        return;
    }
    eprintln!("[activity] {}", activity.label);
}

pub fn render_activity_snapshot(activity: &ActivitySnapshot) -> String {
    let mut lines = vec![
        "activity".to_string(),
        format!("phase:       {}", activity_phase_label(activity.phase)),
        format!("label:       {}", activity.label),
        format!("elapsed:     {:.1}s", activity.elapsed_ms as f64 / 1000.0),
        format!("session:     {}", activity.session_id),
        format!("channel:     {:?}", activity.channel),
    ];
    if let Some(tool_name) = activity.tool_name.as_deref() {
        lines.push(format!("tool:        {tool_name}"));
    }
    if let Some(tool_summary) = activity.tool_summary.as_deref() {
        lines.push(format!("tool input:  {tool_summary}"));
    }
    if let Some(skill_name) = activity.skill_name.as_deref() {
        lines.push(format!("skill:       {skill_name}"));
    }
    if let Some(approval_id) = activity.approval_id.as_deref() {
        lines.push(format!("approval:    {approval_id}"));
    }
    if let Some(stuck_hint) = activity.stuck_hint.as_deref() {
        lines.push(format!("hint:        {stuck_hint}"));
    }
    if !activity.next_actions.is_empty() {
        lines.push(format!("next:        {}", activity.next_actions.join("; ")));
    }
    lines.join("\n")
}

pub fn render_activity_compact(activity: &ActivitySnapshot) -> String {
    let mut parts = vec![
        activity_phase_label(activity.phase).to_string(),
        activity.label.clone(),
        format!("{:.1}s", activity.elapsed_ms as f64 / 1000.0),
    ];
    if let Some(tool_name) = activity.tool_name.as_deref() {
        parts.push(format!("tool={tool_name}"));
    }
    if let Some(stuck_hint) = activity.stuck_hint.as_deref() {
        parts.push(format!("hint={stuck_hint}"));
    }
    if !activity.next_actions.is_empty() {
        parts.push(format!("next={}", activity.next_actions.join("; ")));
    }
    parts.join(" | ")
}

fn activity_phase_label(phase: ActivityPhase) -> &'static str {
    match phase {
        ActivityPhase::Idle => "idle",
        ActivityPhase::Queued => "queued",
        ActivityPhase::PreparingContext => "preparing_context",
        ActivityPhase::ClassifyingIntent => "classifying_intent",
        ActivityPhase::CallingModel => "calling_model",
        ActivityPhase::StreamingResponse => "streaming_response",
        ActivityPhase::CallingTool => "calling_tool",
        ActivityPhase::WaitingForApproval => "waiting_for_approval",
        ActivityPhase::WaitingForInput => "waiting_for_input",
        ActivityPhase::RunningValidation => "running_validation",
        ActivityPhase::RunningScript => "running_script",
        ActivityPhase::Training => "training",
        ActivityPhase::Diagnosing => "diagnosing",
        ActivityPhase::Finalizing => "finalizing",
        ActivityPhase::Error => "error",
        ActivityPhase::Unknown => "unknown",
    }
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
    config: &allbert_kernel_services::Config,
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
    use super::{parse_local_command, slash_argument_hint, unknown_slash_guidance, LocalCommand};

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
            parse_local_command("/rag status"),
            LocalCommand::Rag("/rag status")
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
            parse_local_command("/activity"),
            LocalCommand::Activity
        ));
        assert!(matches!(
            parse_local_command("/inbox list"),
            LocalCommand::Inbox("/inbox list")
        ));
        assert!(matches!(
            parse_local_command("/inbox show approval-123"),
            LocalCommand::Inbox("/inbox show approval-123")
        ));
        assert!(matches!(
            parse_local_command("/inbox accept approval-123"),
            LocalCommand::Inbox("/inbox accept approval-123")
        ));
        assert!(matches!(
            parse_local_command("/inbox reject approval-123"),
            LocalCommand::Inbox("/inbox reject approval-123")
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
        assert!(matches!(
            parse_local_command("/memory staged show staged-123"),
            LocalCommand::Memory("/memory staged show staged-123")
        ));
        assert!(matches!(
            parse_local_command("/self-improvement config show"),
            LocalCommand::SelfImprovement("/self-improvement config show")
        ));
        assert!(matches!(
            parse_local_command("/self-improvement diff approval-123"),
            LocalCommand::SelfImprovement("/self-improvement diff approval-123")
        ));
        assert!(matches!(
            parse_local_command("/self-improvement install approval-123"),
            LocalCommand::SelfImprovement("/self-improvement install approval-123")
        ));
        assert!(matches!(
            parse_local_command("/self-improvement gc --dry-run"),
            LocalCommand::SelfImprovement("/self-improvement gc --dry-run")
        ));
    }

    #[test]
    fn v0_12_2_trace_slash_commands_are_local() {
        assert!(matches!(
            parse_local_command("/trace"),
            LocalCommand::Trace("/trace")
        ));
        assert!(matches!(
            parse_local_command("/trace show repl-primary"),
            LocalCommand::Trace("/trace show repl-primary")
        ));
        assert_eq!(
            slash_argument_hint("/trace --"),
            Some("hint: /trace show [session] | show-span <id> [--session <session>] | tail [session] | export [session] | settings")
        );
    }

    #[test]
    fn v0_14_diagnosis_and_utility_slash_commands_are_local() {
        assert!(matches!(
            parse_local_command("/diagnose run"),
            LocalCommand::Diagnose("/diagnose run")
        ));
        assert!(matches!(
            parse_local_command("/diagnose show diag_20260426T000000Z_12345678"),
            LocalCommand::Diagnose("/diagnose show diag_20260426T000000Z_12345678")
        ));
        assert!(matches!(
            parse_local_command("/utilities status"),
            LocalCommand::Utilities("/utilities status")
        ));
        assert!(matches!(
            parse_local_command("/utilities doctor"),
            LocalCommand::Utilities("/utilities doctor")
        ));
        assert_eq!(
            slash_argument_hint("/diagnose --"),
            Some("hint: /diagnose run | list | show <id>")
        );
        assert_eq!(
            slash_argument_hint("/utilities --"),
            Some("hint: /utilities discover | list | show <id> | enable <id> | disable <id> | doctor")
        );
    }

    #[test]
    fn unknown_slash_command_does_not_fall_through_to_model() {
        assert!(matches!(
            parse_local_command("/not-a-command"),
            LocalCommand::UnknownSlash("/not-a-command")
        ));
    }

    #[test]
    fn unknown_slash_command_suggests_close_match_only() {
        let close = unknown_slash_guidance("/stats");
        assert!(close.contains("did you mean `/status`?"));

        let far = unknown_slash_guidance("/definitely-not-close");
        assert!(!far.contains("did you mean"));
        assert!(far.contains("use /help"));
    }

    #[test]
    fn slash_argument_hint_renders_for_partial_flag_entry() {
        assert_eq!(
            slash_argument_hint("/cost --"),
            Some("hint: /cost --turn-budget <usd> | --turn-time <seconds> | --override <reason>")
        );
        assert!(slash_argument_hint("/memory staged list").is_none());
        assert!(slash_argument_hint("/unknown --").is_none());
    }
}
