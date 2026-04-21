use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_kernel::{AllbertPaths, Config};
use allbert_proto::{
    ChannelKind, ClientKind, JobBudgetPayload, JobDefinitionPayload, JobReportPolicyPayload,
    JobRunRecordPayload, JobStatusPayload, ProviderKind,
};
use anyhow::{Context, Result};
use clap::Subcommand;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;

#[derive(Subcommand, Debug, Clone)]
pub enum JobsCommand {
    List,
    Status { name: String },
    Upsert { path: String },
    Pause { name: String },
    Resume { name: String },
    Run { name: String },
    Remove { name: String },
}

pub async fn run_command(
    paths: &AllbertPaths,
    config: &Config,
    command: JobsCommand,
) -> Result<()> {
    let spawn = default_spawn_config(paths, config)?;
    let mut client = if config.daemon.auto_spawn {
        DaemonClient::connect_or_spawn(paths, ClientKind::Jobs, &spawn)
            .await
            .map_err(map_connect_error)?
    } else {
        DaemonClient::connect(paths, ClientKind::Jobs)
            .await
            .context("daemon is not running and auto-spawn is disabled; start it with `allbert-cli daemon start` or enable daemon.auto_spawn in config")?
    };
    client.attach(ChannelKind::Jobs, None).await?;

    match command {
        JobsCommand::List => {
            println!("{}", render_job_list(&client.list_jobs().await?));
        }
        JobsCommand::Status { name } => {
            println!("{}", render_job_status(&client.get_job(&name).await?));
        }
        JobsCommand::Upsert { path } => {
            let definition = parse_job_definition(&path)?;
            let job = client.upsert_job(definition).await?;
            println!(
                "upserted {}\n{}",
                job.definition.name,
                render_job_status(&job)
            );
        }
        JobsCommand::Pause { name } => {
            let job = client.pause_job(&name).await?;
            println!(
                "paused {}\n{}",
                job.definition.name,
                render_job_status(&job)
            );
        }
        JobsCommand::Resume { name } => {
            let job = client.resume_job(&name).await?;
            println!(
                "resumed {}\n{}",
                job.definition.name,
                render_job_status(&job)
            );
        }
        JobsCommand::Run { name } => {
            println!("{}", render_job_run(&client.run_job(&name).await?));
        }
        JobsCommand::Remove { name } => {
            client.remove_job(&name).await?;
            println!("removed {name}");
        }
    }

    Ok(())
}

fn map_connect_error(error: DaemonError) -> anyhow::Error {
    let message = match &error {
        DaemonError::Spawn(message) => format!(
            "failed to auto-spawn the daemon. Make sure the `allbert-daemon` binary exists next to the CLI binaries.\nunderlying error: {message}"
        ),
        DaemonError::Timeout("daemon auto-spawn") => "daemon auto-spawn timed out. Check for a stale socket, a hung daemon start, or permission drift under ~/.allbert/run.".into(),
        _ => format!("failed to connect to the daemon: {error}"),
    };
    anyhow::anyhow!(message)
}

pub fn render_job_list(jobs: &[JobStatusPayload]) -> String {
    if jobs.is_empty() {
        return "no jobs defined".into();
    }
    jobs.iter()
        .map(|job| {
            format!(
                "{}\tenabled={}\tpaused={}\trunning={}\tnext_due={}\tlast_outcome={}",
                job.definition.name,
                job.definition.enabled,
                job.state.paused,
                job.state.running,
                job.state
                    .next_due_at
                    .clone()
                    .unwrap_or_else(|| "(none)".into()),
                job.state
                    .last_outcome
                    .clone()
                    .unwrap_or_else(|| "(none)".into())
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn render_job_status(job: &JobStatusPayload) -> String {
    let definition = &job.definition;
    let state = &job.state;
    let skills = if definition.skills.is_empty() {
        "(none)".into()
    } else {
        definition.skills.join(", ")
    };
    let tools = if definition.allowed_tools.is_empty() {
        "(none)".into()
    } else {
        definition.allowed_tools.join(", ")
    };
    let model = definition
        .model
        .as_ref()
        .map(|model| format!("{:?} / {}", model.provider, model.model_id))
        .unwrap_or_else(|| "(daemon default)".into());
    let report = definition.report.map(report_label).unwrap_or("(default)");
    let last_failure = match (&state.last_outcome, &state.last_stop_reason) {
        (Some(outcome), Some(reason)) if outcome != "success" => reason.clone(),
        _ => "(none)".into(),
    };

    format!(
        "name:              {}\ndescription:       {}\nenabled:           {}\npaused:            {}\nrunning:           {}\nschedule:          {}\ntimezone:          {}\nmodel override:    {}\nreport policy:     {}\nallowed tools:     {}\nskills:            {}\nnext due:          {}\nlast run:          {}\nlast run id:       {}\nlast outcome:      {}\nlast stop reason:  {}\nfailure streak:    {}",
        definition.name,
        definition.description,
        definition.enabled,
        state.paused,
        state.running,
        definition.schedule,
        definition.timezone.as_deref().unwrap_or("(default)"),
        model,
        report,
        tools,
        skills,
        state.next_due_at.as_deref().unwrap_or("(none)"),
        state.last_run_at.as_deref().unwrap_or("(none)"),
        state.last_run_id.as_deref().unwrap_or("(none)"),
        state.last_outcome.as_deref().unwrap_or("(none)"),
        last_failure,
        state.failure_streak,
    )
}

pub fn render_job_run(run: &JobRunRecordPayload) -> String {
    format!(
        "job:         {}\nrun id:      {}\nsession id:  {}\nstarted:     {}\nended:       {}\noutcome:     {}\nstop reason: {}\ncost usd:    {:.6}\nskills:      {}",
        run.job_name,
        run.run_id,
        run.session_id,
        run.started_at,
        run.ended_at,
        run.outcome,
        run.stop_reason.as_deref().unwrap_or("(none)"),
        run.cost_usd,
        if run.skills_attached.is_empty() {
            "(none)".into()
        } else {
            run.skills_attached.join(", ")
        }
    )
}

fn report_label(report: JobReportPolicyPayload) -> &'static str {
    match report {
        JobReportPolicyPayload::Always => "always",
        JobReportPolicyPayload::OnFailure => "on_failure",
        JobReportPolicyPayload::OnAnomaly => "on_anomaly",
    }
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
    #[serde(default)]
    budget: Option<BudgetFrontmatter>,
    #[serde(default)]
    session_name: Option<String>,
    #[serde(default)]
    memory: Option<MemoryFrontmatter>,
}

#[derive(Debug, Deserialize)]
struct ModelFrontmatter {
    provider: ProviderKind,
    model_id: String,
    api_key_env: String,
    #[serde(default = "default_max_tokens")]
    max_tokens: u32,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct MemoryFrontmatter {
    #[serde(default)]
    prefetch: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct BudgetFrontmatter {
    #[serde(default)]
    max_turn_usd: Option<f64>,
    #[serde(default)]
    max_turn_s: Option<u64>,
}

fn default_max_tokens() -> u32 {
    4096
}

pub fn parse_job_definition(path: &str) -> Result<JobDefinitionPayload> {
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
        budget: data.budget.map(|budget| JobBudgetPayload {
            max_turn_usd: budget.max_turn_usd,
            max_turn_s: budget.max_turn_s,
        }),
        session_name: data.session_name,
        memory_prefetch: data.memory.and_then(|memory| memory.prefetch),
        prompt: parsed.content.trim().to_string(),
    })
}
