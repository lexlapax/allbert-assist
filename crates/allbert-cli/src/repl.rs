use allbert_kernel::{
    ConfirmDecision, ConfirmPrompter, ConfirmRequest, InputPrompter, InputRequest, InputResponse,
    Kernel, ModelConfig, Provider,
};
use anyhow::Result;
use async_trait::async_trait;
use reedline::{DefaultPrompt, DefaultPromptSegment, Reedline, Signal};
use std::io::{self, Write};

use crate::setup;

pub struct TerminalConfirm;

#[async_trait]
impl ConfirmPrompter for TerminalConfirm {
    async fn confirm(&self, req: ConfirmRequest) -> ConfirmDecision {
        print!("Allbert wants to run: {}\n[y/N/always] ", req.rendered);
        let _ = io::stdout().flush();

        let mut buf = String::new();
        if io::stdin().read_line(&mut buf).is_err() {
            return ConfirmDecision::Deny;
        }

        match buf.trim().to_ascii_lowercase().as_str() {
            "y" | "yes" => ConfirmDecision::AllowOnce,
            "always" | "a" => ConfirmDecision::AllowSession,
            _ => ConfirmDecision::Deny,
        }
    }
}

pub struct TerminalInput;

#[async_trait]
impl InputPrompter for TerminalInput {
    async fn request_input(&self, req: InputRequest) -> InputResponse {
        println!("{}", req.prompt);
        print!("> ");
        let _ = io::stdout().flush();

        let mut buf = String::new();
        if io::stdin().read_line(&mut buf).is_err() {
            return InputResponse::Cancelled;
        }

        let value = buf.trim_end_matches(['\r', '\n']).to_string();
        if !req.allow_empty && value.trim().is_empty() {
            InputResponse::Cancelled
        } else {
            InputResponse::Submitted(value)
        }
    }
}

const HELP_TEXT: &str = "\
commands:
  /cost     show session cost and today's recorded total
  /help     show this help
  /model    show or change the active model
  /setup    rerun guided setup and refresh config for this session
  /status   show provider, setup, roots, and trace state
  /exit     leave the REPL
  anything else is sent to the kernel as a user turn";

pub async fn run_loop(kernel: &mut Kernel) -> Result<()> {
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
                    "/help" => {
                        println!("{HELP_TEXT}");
                    }
                    "/cost" => {
                        let today = kernel.today_cost_usd()?;
                        println!(
                            "session: ${:.6}\ntoday:   ${:.6}",
                            kernel.session_cost_usd(),
                            today
                        );
                    }
                    command if command.starts_with("/model") => {
                        handle_model_command(kernel, command).await?;
                    }
                    "/setup" => {
                        handle_setup_command(kernel).await?;
                    }
                    "/status" => {
                        println!(
                            "{}",
                            setup::render_status(&setup::snapshot_from_kernel(kernel))
                        );
                    }
                    _ => {
                        let summary = kernel.run_turn(trimmed).await?;
                        if summary.hit_turn_limit {
                            eprintln!("[kernel reported max-turns limit hit]");
                        }
                    }
                }
            }
            Signal::CtrlC => {
                eprintln!("(ctrl-c) type /exit to leave");
            }
            Signal::CtrlD => break,
        }
    }
    Ok(())
}

async fn handle_model_command(kernel: &mut Kernel, command: &str) -> Result<()> {
    let parts: Vec<_> = command.split_whitespace().collect();
    if parts.len() == 1 {
        let model = kernel.model();
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

    let current = kernel.model().clone();
    let api_key_env = parts
        .get(3)
        .map(|value| (*value).to_string())
        .unwrap_or_else(|| default_api_key_env(provider, &current));

    kernel
        .set_model(ModelConfig {
            provider,
            model_id: parts[2].to_string(),
            api_key_env,
            max_tokens: current.max_tokens,
        })
        .await?;

    let active = kernel.model();
    println!(
        "active model: {} / {}",
        provider_label(active.provider),
        active.model_id
    );
    Ok(())
}

async fn handle_setup_command(kernel: &mut Kernel) -> Result<()> {
    let updated = match setup::run_setup_wizard(kernel.paths(), kernel.config())? {
        Some(config) => config,
        None => {
            println!("Setup cancelled.");
            return Ok(());
        }
    };

    let warnings = setup::build_startup_warnings(&updated);
    kernel.apply_config(updated).await?;
    println!("Setup updated for this session.");
    for warning in warnings {
        eprintln!("{warning}");
    }
    Ok(())
}

fn parse_provider(raw: &str) -> Option<Provider> {
    match raw {
        "anthropic" => Some(Provider::Anthropic),
        "openrouter" => Some(Provider::Openrouter),
        _ => None,
    }
}

fn provider_label(provider: Provider) -> &'static str {
    match provider {
        Provider::Anthropic => "anthropic",
        Provider::Openrouter => "openrouter",
    }
}

fn default_api_key_env(provider: Provider, current: &ModelConfig) -> String {
    match provider {
        Provider::Anthropic => {
            if current.provider == Provider::Anthropic {
                current.api_key_env.clone()
            } else {
                "ANTHROPIC_API_KEY".into()
            }
        }
        Provider::Openrouter => {
            if current.provider == Provider::Openrouter {
                current.api_key_env.clone()
            } else {
                "OPENROUTER_API_KEY".into()
            }
        }
    }
}
