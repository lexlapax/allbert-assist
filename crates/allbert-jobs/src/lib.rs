use std::fs;

use allbert_daemon::{default_spawn_config, DaemonClient, DaemonError};
use allbert_kernel::{AllbertPaths, Config, Provider};
use allbert_proto::{
    ActivityPhase, ActivitySnapshot, ChannelKind, ClientKind, JobBudgetPayload,
    JobDefinitionPayload, JobReportPolicyPayload, JobRunRecordPayload, JobStatusPayload,
    ProviderKind,
};
use anyhow::{Context, Result};
use clap::Subcommand;
use gray_matter::engine::YAML;
use gray_matter::Matter;
use serde::Deserialize;

#[derive(Subcommand, Debug, Clone)]
pub enum JobsCommand {
    List,
    Status {
        name: String,
    },
    Template {
        #[command(subcommand)]
        command: JobTemplateCommand,
    },
    Upsert {
        path: String,
    },
    Pause {
        name: String,
    },
    Resume {
        name: String,
    },
    Run {
        name: String,
    },
    Remove {
        name: String,
    },
}

#[derive(Subcommand, Debug, Clone)]
pub enum JobTemplateCommand {
    Enable { name: String },
    Disable { name: String },
}

pub async fn run_command(
    paths: &AllbertPaths,
    config: &Config,
    command: JobsCommand,
) -> Result<()> {
    if let JobsCommand::Template { command } = command {
        println!("{}", run_template_command(paths, command)?);
        return Ok(());
    }

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
        JobsCommand::Template { .. } => unreachable!("handled before daemon connection"),
    }

    Ok(())
}

fn run_template_command(paths: &AllbertPaths, command: JobTemplateCommand) -> Result<String> {
    match command {
        JobTemplateCommand::Enable { name } => {
            let source = paths.jobs_templates.join(format!("{name}.md"));
            let dest = paths.jobs_definitions.join(format!("{name}.md"));
            let raw = fs::read_to_string(&source)
                .with_context(|| format!("read job template {}", source.display()))?;
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("create {}", parent.display()))?;
            }
            let enabled = set_job_enabled(&raw, true);
            allbert_kernel::atomic_write(&dest, enabled.as_bytes())
                .with_context(|| format!("write {}", dest.display()))?;
            Ok(format!(
                "enabled job template {name}\ndefinition: {}",
                dest.display()
            ))
        }
        JobTemplateCommand::Disable { name } => {
            let dest = paths.jobs_definitions.join(format!("{name}.md"));
            if !dest.exists() {
                return Ok(format!("job template {name} is not enabled"));
            }
            let raw = fs::read_to_string(&dest)
                .with_context(|| format!("read job definition {}", dest.display()))?;
            let disabled = set_job_enabled(&raw, false);
            allbert_kernel::atomic_write(&dest, disabled.as_bytes())
                .with_context(|| format!("write {}", dest.display()))?;
            Ok(format!(
                "disabled job template {name}\ndefinition: {}",
                dest.display()
            ))
        }
    }
}

fn set_job_enabled(raw: &str, enabled: bool) -> String {
    let replacement = format!("enabled: {}", if enabled { "true" } else { "false" });
    let mut replaced = false;
    let mut rendered = Vec::new();
    for line in raw.lines() {
        if !replaced && line.trim_start().starts_with("enabled:") {
            rendered.push(replacement.clone());
            replaced = true;
        } else {
            rendered.push(line.to_string());
        }
    }
    if replaced {
        rendered.join("\n") + "\n"
    } else {
        raw.to_string()
    }
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
        .map(render_model_override)
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
    let mut rendered = format!(
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
    );
    if let Some(activity) = run.last_activity.as_ref() {
        rendered.push_str(&format!(
            "\nactivity:    {}",
            render_compact_activity(activity)
        ));
    }
    rendered
}

fn render_compact_activity(activity: &ActivitySnapshot) -> String {
    let mut parts = vec![
        activity_phase_label(activity.phase).to_string(),
        activity.label.clone(),
    ];
    if let Some(tool_name) = activity.tool_name.as_deref() {
        parts.push(format!("tool={tool_name}"));
    }
    if let Some(hint) = activity.stuck_hint.as_deref() {
        parts.push(format!("hint={hint}"));
    }
    parts.join(" | ")
}

fn activity_phase_label(phase: ActivityPhase) -> &'static str {
    match phase {
        ActivityPhase::Idle => "idle",
        ActivityPhase::Queued => "queued",
        ActivityPhase::PreparingContext => "preparing_context",
        ActivityPhase::ClassifyingIntent => "classifying_intent",
        ActivityPhase::CallingModel => "calling_model",
        ActivityPhase::StreamingResponse => "streaming_response",
        ActivityPhase::CallingTool => "calling_tool",
        ActivityPhase::WaitingForApproval => "waiting_for_approval",
        ActivityPhase::WaitingForInput => "waiting_for_input",
        ActivityPhase::RunningValidation => "running_validation",
        ActivityPhase::RunningScript => "running_script",
        ActivityPhase::Training => "training",
        ActivityPhase::Diagnosing => "diagnosing",
        ActivityPhase::Finalizing => "finalizing",
        ActivityPhase::Error => "error",
        ActivityPhase::Unknown => "unknown",
    }
}

fn report_label(report: JobReportPolicyPayload) -> &'static str {
    match report {
        JobReportPolicyPayload::Always => "always",
        JobReportPolicyPayload::OnFailure => "on_failure",
        JobReportPolicyPayload::OnAnomaly => "on_anomaly",
    }
}

fn render_model_override(model: &allbert_proto::ModelConfigPayload) -> String {
    format!(
        "{} / {}",
        Provider::from_proto_kind(model.provider).label(),
        model.model_id
    )
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
    #[serde(default)]
    api_key_env: Option<String>,
    #[serde(default)]
    base_url: Option<String>,
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
            base_url: model.base_url,
            max_tokens: model.max_tokens,
            context_window_tokens: 0,
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

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_proto::{ActivitySnapshot, ChannelKind, JobStatePayload, ModelConfigPayload};
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_job_file(contents: &str) -> std::path::PathBuf {
        let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
        let path =
            std::env::temp_dir().join(format!("allbert-jobs-{}-{counter}.md", std::process::id()));
        std::fs::write(&path, contents).expect("temp job should write");
        path
    }

    #[test]
    fn parse_job_definition_accepts_keyless_ollama_base_url() {
        let path = temp_job_file(
            r#"---
name: local-brief
description: Local brief
enabled: true
schedule: "@daily"
model:
  provider: ollama
  model_id: gemma4
  base_url: http://127.0.0.1:11434
  max_tokens: 2048
---

Summarize the day locally.
"#,
        );

        let parsed = parse_job_definition(path.to_str().expect("temp path should be utf-8"))
            .expect("job definition should parse");
        let model = parsed.model.expect("model override should parse");
        assert_eq!(model.provider, ProviderKind::Ollama);
        assert_eq!(model.model_id, "gemma4");
        assert_eq!(model.api_key_env, None);
        assert_eq!(model.base_url.as_deref(), Some("http://127.0.0.1:11434"));
        assert_eq!(model.max_tokens, 2048);

        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn render_job_status_uses_provider_metadata_label() {
        let job = JobStatusPayload {
            definition: JobDefinitionPayload {
                name: "local-brief".into(),
                description: "Local brief".into(),
                enabled: true,
                schedule: "@daily".into(),
                skills: Vec::new(),
                timezone: None,
                model: Some(ModelConfigPayload {
                    provider: ProviderKind::Ollama,
                    model_id: "gemma4".into(),
                    api_key_env: None,
                    base_url: Some("http://127.0.0.1:11434".into()),
                    max_tokens: 2048,
                    context_window_tokens: 0,
                }),
                allowed_tools: Vec::new(),
                timeout_s: None,
                report: None,
                max_turns: None,
                budget: None,
                session_name: None,
                memory_prefetch: None,
                prompt: "Summarize locally.".into(),
            },
            state: JobStatePayload {
                paused: false,
                last_run_at: None,
                next_due_at: None,
                failure_streak: 0,
                running: false,
                last_run_id: None,
                last_outcome: None,
                last_stop_reason: None,
            },
        };

        let rendered = render_job_status(&job);
        assert!(rendered.contains("model override:    ollama / gemma4"));
    }

    #[test]
    fn render_job_run_includes_last_activity_when_present() {
        let run = JobRunRecordPayload {
            run_id: "run-1".into(),
            job_name: "daily-brief".into(),
            session_id: "job-daily-brief".into(),
            started_at: "2026-04-20T00:00:00Z".into(),
            ended_at: "2026-04-20T00:01:00Z".into(),
            outcome: "failure".into(),
            cost_usd: 0.0,
            skills_attached: Vec::new(),
            stop_reason: Some("provider timeout".into()),
            last_activity: Some(ActivitySnapshot {
                phase: ActivityPhase::CallingModel,
                label: "calling model".into(),
                started_at: "2026-04-20T00:00:30Z".into(),
                elapsed_ms: 30_000,
                session_id: "job-daily-brief".into(),
                channel: ChannelKind::Jobs,
                tool_name: None,
                tool_summary: None,
                skill_name: None,
                approval_id: None,
                last_progress_at: None,
                stuck_hint: Some("provider has not returned yet".into()),
                next_actions: Vec::new(),
            }),
        };

        let rendered = render_job_run(&run);
        assert!(rendered.contains("activity:"));
        assert!(rendered.contains("calling_model"));
        assert!(rendered.contains("provider has not returned yet"));
    }
}
