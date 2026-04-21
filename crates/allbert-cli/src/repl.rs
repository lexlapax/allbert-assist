use allbert_daemon::DaemonClient;
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
    - allbert-cli daemon resume --list
    - allbert-cli daemon resume --session <id>
    - allbert-cli daemon forget <id>
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
            model.api_key_env,
            model.max_tokens
        );
        return Ok(());
    }

    if parts.len() < 3 {
        println!("usage: /model <anthropic|openrouter> <model_id> [api_key_env]");
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
        .unwrap_or_else(|| default_api_key_env(provider, &current));

    let active = client
        .set_model(ModelConfigPayload {
            provider,
            model_id: parts[2].to_string(),
            api_key_env,
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
            "session: ${:.6}\ntoday:   ${:.6}\ncap:     {}",
            status.session_cost_usd, status.today_cost_usd, cap
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

    println!("usage: /cost | /cost --override <reason>");
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
    match raw {
        "anthropic" => Some(ProviderKind::Anthropic),
        "openrouter" => Some(ProviderKind::Openrouter),
        _ => None,
    }
}

fn provider_label(provider: ProviderKind) -> &'static str {
    match provider {
        ProviderKind::Anthropic => "anthropic",
        ProviderKind::Openrouter => "openrouter",
    }
}

fn default_api_key_env(provider: ProviderKind, current: &ModelConfigPayload) -> String {
    match provider {
        ProviderKind::Anthropic => {
            if current.provider == ProviderKind::Anthropic {
                current.api_key_env.clone()
            } else {
                "ANTHROPIC_API_KEY".into()
            }
        }
        ProviderKind::Openrouter => {
            if current.provider == ProviderKind::Openrouter {
                current.api_key_env.clone()
            } else {
                "OPENROUTER_API_KEY".into()
            }
        }
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
