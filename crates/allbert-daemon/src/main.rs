use allbert_daemon::spawn;
use allbert_kernel::{AllbertPaths, Config};
use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert daemon host", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand, Debug)]
enum Command {
    Run,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args = Args::parse();
    match args.command.unwrap_or(Command::Run) {
        Command::Run => run().await?,
    }
    Ok(())
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    let paths = AllbertPaths::from_home()?;
    let config = Config::load_or_create(&paths)?;
    let daemon = spawn(config, paths).await?;
    let shutdown = daemon.shutdown_handle();
    tokio::spawn(async move {
        if tokio::signal::ctrl_c().await.is_ok() {
            shutdown.cancel();
        }
    });
    daemon.wait().await?;
    Ok(())
}
