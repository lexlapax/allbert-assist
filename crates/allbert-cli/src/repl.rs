use allbert_daemon::DaemonClient;
use allbert_kernel::Provider;
use allbert_proto::{
    ClientMessage, ConfirmDecisionPayload, InputResponsePayload, KernelEventPayload,
    ModelConfigPayload, ProviderKind, ServerMessage,
};
use anyhow::Result;
use reedline::{DefaultPrompt, DefaultPromptSegment, Reedline, Signal};
use std::io::{self, Write};

use crate::setup::{self, StatusSnapshot};

const HELP_TEXT: &str = "\
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
  /model    show or change the active model
  /s        show provider, intent, agent, setup, roots, and trace state
  /setup    rerun guided setup and reload config for this session
  /status   show provider, current agent context, setup, roots, and trace state
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

enum LocalCommand<'a> {
    Exit,
    Help,
    Cost(&'a str),
    Model(&'a str),
    Setup,
    Status,
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
                    LocalCommand::Cost(command) => {
                        handle_cost_command(client, paths, command).await?;
                    }
                    LocalCommand::Model(command) => {
                        handle_model_command(client, command).await?;
                    }
                    LocalCommand::Setup => {
                        handle_setup_command(client, paths).await?;
                    }
                    LocalCommand::Status => {
                        let status = client.session_status().await?;
                        let config = allbert_kernel::Config::load_or_create(paths)?;
                        println!(
                            "{}",
                            setup::render_status(&snapshot_from_proto(&status, &config))
                        );
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

fn parse_local_command(input: &str) -> LocalCommand<'_> {
    match input {
        "/exit" | "/quit" => LocalCommand::Exit,
        "/help" | "/h" => LocalCommand::Help,
        command if command.starts_with("/cost") => LocalCommand::Cost(command),
        "/setup" => LocalCommand::Setup,
        "/status" | "/s" => LocalCommand::Status,
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
    if let ServerMessage::Event(event) = message {
        render_event(event);
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
    fn unknown_slash_command_does_not_fall_through_to_model() {
        assert!(matches!(
            parse_local_command("/not-a-command"),
            LocalCommand::UnknownSlash("/not-a-command")
        ));
    }
}
