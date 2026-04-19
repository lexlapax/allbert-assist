use allbert_daemon::{default_spawn_config, DaemonClient};
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{ClientKind, JobDefinitionPayload, JobReportPolicyPayload, ProviderKind};
use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;

#[derive(Parser, Debug)]
#[command(author, version, about = "Allbert jobs client", long_about = None)]
struct Args {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    List,
    Status { name: String },
    Upsert { path: String },
    Pause { name: String },
    Resume { name: String },
    Run { name: String },
    Remove { name: String },
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let paths = AllbertPaths::from_home()?;
    let config = Config::load_or_create(&paths)?;
    let spawn = default_spawn_config(&paths, &config)?;
    let mut client = DaemonClient::connect_or_spawn(&paths, ClientKind::Jobs, &spawn).await?;
    client
        .attach(allbert_proto::ChannelKind::Jobs, None)
        .await?;

    match args.command {
        Command::List => {
            for job in client.list_jobs().await? {
                println!(
                    "{}\tenabled={}\tpaused={}\tnext_due={}",
                    job.definition.name,
                    job.definition.enabled,
                    job.state.paused,
                    job.state.next_due_at.unwrap_or_else(|| "(none)".into())
                );
            }
        }
        Command::Status { name } => {
            let job = client.get_job(&name).await?;
            println!("{}", serde_json::to_string_pretty(&job)?);
        }
        Command::Upsert { path } => {
            let definition = parse_job_definition(&path)?;
            let job = client.upsert_job(definition).await?;
            println!("upserted {}", job.definition.name);
        }
        Command::Pause { name } => {
            let job = client.pause_job(&name).await?;
            println!("paused {}", job.definition.name);
        }
        Command::Resume { name } => {
            let job = client.resume_job(&name).await?;
            println!("resumed {}", job.definition.name);
        }
        Command::Run { name } => {
            let run = client.run_job(&name).await?;
            println!("{}", serde_json::to_string_pretty(&run)?);
        }
        Command::Remove { name } => {
            client.remove_job(&name).await?;
            println!("removed {name}");
        }
    }

    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Frontmatter {
    name: String,
    description: String,
    enabled: bool,
    schedule: String,
    #[serde(default)]
    skills: Vec<String>,
    #[serde(default)]
    timezone: Option<String>,
    #[serde(default)]
    model: Option<ModelFrontmatter>,
    #[serde(rename = "allowed-tools", default)]
    allowed_tools: Vec<String>,
    #[serde(default)]
    timeout_s: Option<u64>,
    #[serde(default)]
    report: Option<JobReportPolicyPayload>,
    #[serde(default)]
    max_turns: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct ModelFrontmatter {
    provider: ProviderKind,
    model_id: String,
    api_key_env: String,
    #[serde(default = "default_max_tokens")]
    max_tokens: u32,
}

fn default_max_tokens() -> u32 {
    4096
}

fn parse_job_definition(path: &str) -> Result<JobDefinitionPayload> {
    let raw = std::fs::read_to_string(path).with_context(|| format!("read {}", path))?;
    let matter = Matter::<YAML>::new();
    let parsed = matter
        .parse::<Frontmatter>(&raw)
        .with_context(|| format!("parse {}", path))?;
    let data = parsed.data.context("missing frontmatter")?;

    Ok(JobDefinitionPayload {
        name: data.name,
        description: data.description,
        enabled: data.enabled,
        schedule: data.schedule,
        skills: data.skills,
        timezone: data.timezone,
        model: data.model.map(|model| allbert_proto::ModelConfigPayload {
            provider: model.provider,
            model_id: model.model_id,
            api_key_env: model.api_key_env,
            max_tokens: model.max_tokens,
        }),
        allowed_tools: data.allowed_tools,
        timeout_s: data.timeout_s,
        report: data.report,
        max_turns: data.max_turns,
        prompt: parsed.content.trim().to_string(),
    })
}
