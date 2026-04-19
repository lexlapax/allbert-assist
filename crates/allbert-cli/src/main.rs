use allbert_daemon::{default_spawn_config, DaemonClient};
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::ClientKind;
use anyhow::Result;
use clap::Parser;

mod repl;
mod setup;

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert daemon-backed REPL client", long_about = None)]
struct Args {
    /// Enable daemon debug logging for the running daemon at ~/.allbert/logs/daemon.debug.log.
    #[arg(long)]
    trace: bool,
    /// Auto-confirm risky actions for the attached daemon-backed session.
    #[arg(short, long)]
    yes: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let paths = AllbertPaths::from_home()?;
    let mut config = Config::load_or_create(&paths)?;
    if setup::needs_setup(&config, &paths) {
        match setup::run_setup_wizard(&paths, &config)? {
            Some(updated) => config = updated,
            None => {
                eprintln!("Setup was cancelled. Rerun Allbert when you're ready to finish setup.");
                return Ok(());
            }
        }
    }
    if args.trace {
        config.trace = true;
    }
    if args.yes {
        config.security.auto_confirm = true;
    }
    setup::print_startup_warnings(&config);

    let spawn = default_spawn_config(&paths, &config)?;
    let mut client = DaemonClient::connect_or_spawn(&paths, ClientKind::Repl, &spawn).await?;
    let attached = client
        .attach(allbert_proto::ChannelKind::Repl, None)
        .await?;
    if args.trace {
        client.set_trace(true).await?;
    }
    if args.yes {
        client.set_auto_confirm(true).await?;
    }
    tracing::info!(session = attached.session_id, "REPL attached");
    repl::run_loop(&mut client, &paths).await?;
    Ok(())
}
