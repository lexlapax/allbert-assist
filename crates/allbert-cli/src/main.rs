use std::sync::Arc;

use allbert_kernel::{AllbertPaths, Config, FrontendAdapter, Kernel, KernelEvent};
use anyhow::Result;
use clap::Parser;

mod repl;

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert v0.1 REPL frontend", long_about = None)]
struct Args {
    /// Enable DEBUG file-layer tracing to ~/.allbert/traces/<session>-<ts>.log.
    #[arg(long)]
    trace: bool,
    /// Auto-confirm risky actions (sets security.auto_confirm for this session).
    #[arg(short, long)]
    yes: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let paths = AllbertPaths::from_home()?;
    let mut config = Config::load_or_create(&paths)?;
    if args.trace {
        config.trace = true;
    }
    if args.yes {
        config.security.auto_confirm = true;
    }

    let adapter = FrontendAdapter {
        on_event: Box::new(|event: &KernelEvent| match event {
            KernelEvent::AssistantText(text) => println!("{text}"),
            KernelEvent::ToolCall { name, .. } => {
                eprintln!("[tool call: {name}]");
            }
            KernelEvent::ToolResult { name, ok, .. } => {
                let tag = if *ok { "ok" } else { "err" };
                eprintln!("[tool result: {name} ({tag})]");
            }
            KernelEvent::Cost(_) => {}
            KernelEvent::TurnDone { hit_turn_limit } => {
                if *hit_turn_limit {
                    eprintln!("[turn hit max-turns limit]");
                }
            }
        }),
        confirm: Arc::new(repl::TerminalConfirm),
        input: Arc::new(repl::TerminalInput),
    };

    let mut kernel = Kernel::boot(config, adapter).await?;
    tracing::info!(session = kernel.session_id(), "REPL starting");
    repl::run_loop(&mut kernel).await?;
    Ok(())
}
