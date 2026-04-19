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
  /cost     show session cost and today's recorded total
  /help     show this help
  /model    show or change the active model
  /setup    rerun guided setup and reload config for this session
  /status   show provider, setup, roots, and trace state
  /exit     leave the REPL
  anything else is sent to the daemon-backed kernel session";

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
                match trimmed {
                    "/exit" | "/quit" => break,
                    "/help" => println!("{HELP_TEXT}"),
                    "/cost" => {
                        let status = client.session_status().await?;
                        println!(
                            "session: ${:.6}\ntoday:   ${:.6}",
                            status.session_cost_usd, status.today_cost_usd
                        );
                    }
                    command if command.starts_with("/model") => {
                        handle_model_command(client, command).await?;
                    }
                    "/setup" => {
                        handle_setup_command(client, paths).await?;
                    }
                    "/status" => {
                        let status = client.session_status().await?;
                        println!("{}", setup::render_status(&snapshot_from_proto(&status)));
                    }
                    _ => {
                        run_turn(client, trimmed).await?;
                    }
                }
            }
            Signal::CtrlC => eprintln!("(ctrl-c) type /exit to leave"),
            Signal::CtrlD => break,
        }
    }
    Ok(())
}

async fn run_turn(client: &mut DaemonClient, input: &str) -> Result<()> {
    client.start_turn(input.to_string()).await?;
    loop {
        match client.recv().await? {
            ServerMessage::Event(event) => render_event(event),
            ServerMessage::ConfirmRequest(request) => {
                let decision = prompt_confirm(&request.rendered)?;
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

fn prompt_confirm(rendered: &str) -> Result<ConfirmDecisionPayload> {
    print!("Allbert wants to run: {rendered}\n[y/N/always] ");
    io::stdout().flush()?;

    let mut buf = String::new();
    io::stdin().read_line(&mut buf)?;
    Ok(match buf.trim().to_ascii_lowercase().as_str() {
        "y" | "yes" => ConfirmDecisionPayload::AllowOnce,
        "always" | "a" => ConfirmDecisionPayload::AllowSession,
        _ => ConfirmDecisionPayload::Deny,
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
        KernelEventPayload::AssistantText(text) => println!("{text}"),
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

fn snapshot_from_proto(status: &allbert_proto::SessionStatus) -> StatusSnapshot {
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
    }
}
