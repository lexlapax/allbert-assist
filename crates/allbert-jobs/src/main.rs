use allbert_jobs::{run_command, JobsCommand};
use allbert_kernel::{AllbertPaths, Config};
use anyhow::Result;
use clap::Parser;

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert jobs client", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: JobsCommand,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let paths = AllbertPaths::from_home()?;
    let config = Config::load_or_create(&paths)?;
    run_command(&paths, &config, args.command).await
}
