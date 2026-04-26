use std::collections::HashSet;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::process::Command;

use allbert_kernel::{
    atomic_write, AllbertPaths, Config, Provider, ReplUiMode, StatusLineItem, CURRENT_SETUP_VERSION,
};
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

const PLACEHOLDER_UNKNOWN: &str = "Unknown";
const PLACEHOLDER_BOOTSTRAP: &str = "Fill this in during bootstrap.";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetupAnswers {
    pub provider: Provider,
    pub model_id: String,
    pub api_key_env: Option<String>,
    pub base_url: Option<String>,
    pub ui_mode: ReplUiMode,
    pub preferred_name: String,
    pub timezone: String,
    pub working_style: String,
    pub current_priorities: String,
    pub assistant_name: Option<String>,
    pub assistant_role: Option<String>,
    pub assistant_style: Option<String>,
    pub trusted_roots: Vec<PathBuf>,
    pub daemon_auto_spawn: bool,
    pub daily_usd_cap: Option<String>,
    pub jobs_enabled: bool,
    pub jobs_default_timezone: Option<String>,
    pub enabled_bundled_jobs: Vec<String>,
    pub trace_enabled: bool,
    pub trace_capture_messages: bool,
    pub trace_session_disk_cap_mb: u16,
    pub trace_total_disk_cap_mb: u32,
    pub trace_retention_days: u16,
    pub adapter_training: AdapterTrainingSetupAnswers,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AdapterTrainingSetupAnswers {
    pub enabled: bool,
    pub allowed_backends: Vec<String>,
    pub default_backend: Option<String>,
    pub exec_allow: Vec<String>,
    pub compute_cap_wall_seconds: Option<u64>,
    pub capture_traces: bool,
}

impl Default for AdapterTrainingSetupAnswers {
    fn default() -> Self {
        Self {
            enabled: false,
            allowed_backends: Vec::new(),
            default_backend: None,
            exec_allow: Vec::new(),
            compute_cap_wall_seconds: Some(7_200),
            capture_traces: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SetupState {
    schema_version: u8,
    current_step: String,
    #[serde(default)]
    answers: Option<SetupAnswers>,
    #[serde(default)]
    adapter_training: Option<AdapterTrainingSetupAnswers>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusSnapshot {
    pub provider: String,
    pub model_id: String,
    pub api_key_env: Option<String>,
    pub api_key_present: bool,
    pub setup_version: u8,
    pub bootstrap_pending: bool,
    pub trusted_roots: Vec<PathBuf>,
    pub skill_count: usize,
    pub trace_enabled: bool,
    pub daemon_auto_spawn: bool,
    pub jobs_enabled: bool,
    pub jobs_default_timezone: Option<String>,
    pub root_agent_name: String,
    pub last_agent_stack: Vec<String>,
    pub last_resolved_intent: Option<String>,
    pub repl_ui: String,
    pub memory_routing: String,
    pub status_line_items: Vec<String>,
}

pub fn needs_setup(config: &Config, paths: &AllbertPaths) -> bool {
    config.setup.version < 1 || paths.bootstrap.exists()
}

pub fn run_setup_wizard(paths: &AllbertPaths, config: &Config) -> Result<Option<Config>> {
    run_setup_wizard_with_resume(paths, config, false)
}

pub fn run_setup_wizard_with_resume(
    paths: &AllbertPaths,
    config: &Config,
    resume: bool,
) -> Result<Option<Config>> {
    println!("Allbert setup");
    println!("Type /cancel at any prompt to stop setup.\n");

    if resume {
        if let Some(state) = load_setup_state(paths, config)? {
            if state.current_step == "adapter_training" {
                if let Some(mut answers) = state.answers {
                    println!("Resuming setup at local personalization.");
                    answers.adapter_training = match prompt_adapter_training(paths, config)? {
                        Some(value) => value,
                        None => return Ok(None),
                    };
                    persist_setup_state(paths, config, "complete", Some(&answers), None)?;
                    let mut updated = config.clone();
                    apply_setup_answers(paths, &mut updated, &answers)?;
                    println!("\nSetup saved. Inspect personalization later with `/settings show learning.adapter_training` or `allbert-cli adapters --help`.\n");
                    return Ok(Some(updated));
                }
            }
        }
    }

    let user_raw = read_file_or_empty(&paths.user);
    let identity_raw = read_file_or_empty(&paths.identity);
    let cwd = std::env::current_dir().context("resolve current working directory")?;

    let preferred_name =
        match prompt_required("Your preferred name", suggested_preferred_name(&user_raw))? {
            Some(value) => value,
            None => return Ok(None),
        };
    let timezone = match prompt_required("Your timezone", suggested_timezone(&user_raw))? {
        Some(value) => value,
        None => return Ok(None),
    };
    let working_style = match prompt_required(
        "How should Allbert usually work with you?",
        suggested_working_style(&user_raw),
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let current_priorities = match prompt_required(
        "Your current priorities",
        suggested_current_priorities(&user_raw),
    )? {
        Some(value) => value,
        None => return Ok(None),
    };

    println!("\nThe next questions are about Allbert's own identity.");
    let customize_identity = match prompt_yes_no("Customize Allbert's own identity now?", false)? {
        Some(value) => value,
        None => return Ok(None),
    };

    let (assistant_name, assistant_role, assistant_style) = if customize_identity {
        let current_name = extract_section_value(&identity_raw, "Name");
        let current_role = extract_section_value(&identity_raw, "Role");
        let current_style = extract_section_value(&identity_raw, "Style");

        let assistant_name = match prompt_optional("Allbert's name", current_name.as_deref())? {
            Some(value) => value,
            None => return Ok(None),
        };
        let assistant_role = match prompt_optional("Allbert's role", current_role.as_deref())? {
            Some(value) => value,
            None => return Ok(None),
        };
        let assistant_style = match prompt_optional("Allbert's style", current_style.as_deref())? {
            Some(value) => value,
            None => return Ok(None),
        };
        (assistant_name, assistant_role, assistant_style)
    } else {
        (None, None, None)
    };

    println!("\nThe next question chooses Allbert's interactive terminal surface.");
    println!(
        "Status-line items available in the TUI: {}.",
        status_line_catalog().join(", ")
    );
    println!(
        "Memory routing default: `memory-curator` is always eligible, and fully activates only for memory-shaped turns such as `memory_query`."
    );
    let ui_mode = match prompt_ui_mode(config.repl.ui)? {
        Some(value) => value,
        None => return Ok(None),
    };

    println!("\nThe next questions choose Allbert's default model.");
    let provider = match prompt_provider(config.model.provider)? {
        Some(value) => value,
        None => return Ok(None),
    };
    let model_id = match prompt_required(
        "Default model id",
        Some(default_model_id_for_setup(config, provider)),
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let api_key_env = if provider.api_key_required() {
        match prompt_optional(
            "API key environment variable",
            config
                .model
                .api_key_env
                .as_deref()
                .or_else(|| provider.default_api_key_env()),
        )? {
            Some(value) => value.or_else(|| provider.default_api_key_env().map(str::to_string)),
            None => return Ok(None),
        }
    } else {
        None
    };
    let base_url = if provider == Provider::Ollama {
        match prompt_optional(
            "Ollama base URL",
            config
                .model
                .base_url
                .as_deref()
                .or_else(|| provider.default_base_url()),
        )? {
            Some(value) => value.or_else(|| provider.default_base_url().map(str::to_string)),
            None => return Ok(None),
        }
    } else {
        None
    };

    let trusted_roots = match prompt_trusted_roots(&cwd, &config.security.fs_roots)? {
        Some(roots) => roots,
        None => return Ok(None),
    };
    let daemon_auto_spawn = match prompt_yes_no(
        "Automatically start the Allbert daemon when the CLI needs it?",
        config.daemon.auto_spawn,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let daily_usd_cap = match prompt_optional(
        "Daily cost cap in USD (blank to disable)",
        config
            .limits
            .daily_usd_cap
            .map(|value| format!("{value:.2}"))
            .as_deref(),
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let jobs_enabled = match prompt_yes_no(
        "Enable recurring jobs in this Allbert profile?",
        config.jobs.enabled,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let jobs_default_timezone = if jobs_enabled {
        match prompt_required(
            "Scheduled jobs timezone",
            config
                .jobs
                .default_timezone
                .clone()
                .or_else(|| Some(timezone.clone())),
        )? {
            Some(value) => Some(value),
            None => return Ok(None),
        }
    } else {
        config
            .jobs
            .default_timezone
            .clone()
            .or_else(|| Some(timezone.clone()))
    };
    let enabled_bundled_jobs = if jobs_enabled {
        let prefer_safe_defaults = config.setup.version == 0;
        match prompt_bundled_jobs(paths, prefer_safe_defaults)? {
            Some(value) => value,
            None => return Ok(None),
        }
    } else {
        Vec::new()
    };

    println!("\nTrace and replay records spans for decisions, routing, tool calls, model calls, and durations. It is after-the-fact history; live activity remains the daemon-owned current-state surface.");
    let trace_enabled = match prompt_yes_no(
        "Enable durable trace and replay for this profile?",
        config.trace.enabled,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let trace_capture_messages = if trace_enabled {
        println!("Trace capture defaults to full prompts, responses, tool args, and tool results because it makes replay useful. Secrets are always redacted before write/export, retention is bounded, and you can lower fidelity later with `/settings show trace`.");
        match prompt_yes_no(
            "Capture full prompt and response text in traces?",
            config.trace.capture_messages,
        )? {
            Some(value) => value,
            None => return Ok(None),
        }
    } else {
        config.trace.capture_messages
    };
    let trace_session_disk_cap_mb = match prompt_u16(
        "Per-session trace disk cap in MiB",
        config.trace.session_disk_cap_mb,
        5,
        500,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let trace_total_disk_cap_mb = match prompt_u32(
        "Total trace disk cap in MiB",
        config.trace.total_disk_cap_mb,
        100,
        51_200,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    let trace_retention_days = match prompt_u16(
        "Trace retention in days",
        config.trace.retention_days,
        1,
        365,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    println!(
        "Trace artifacts live under {}. Inspect later with `/settings show trace` or `allbert-cli trace --help`.",
        paths.sessions.display()
    );

    let mut answers = SetupAnswers {
        provider,
        model_id,
        api_key_env,
        base_url,
        ui_mode,
        preferred_name,
        timezone,
        working_style,
        current_priorities,
        assistant_name,
        assistant_role,
        assistant_style,
        trusted_roots,
        daemon_auto_spawn,
        daily_usd_cap,
        jobs_enabled,
        jobs_default_timezone,
        enabled_bundled_jobs,
        trace_enabled,
        trace_capture_messages,
        trace_session_disk_cap_mb,
        trace_total_disk_cap_mb,
        trace_retention_days,
        adapter_training: AdapterTrainingSetupAnswers::default(),
    };
    persist_setup_state(paths, config, "adapter_training", Some(&answers), None)?;
    answers.adapter_training = match prompt_adapter_training(paths, config)? {
        Some(value) => value,
        None => return Ok(None),
    };
    persist_setup_state(paths, config, "complete", Some(&answers), None)?;

    let mut updated = config.clone();
    apply_setup_answers(paths, &mut updated, &answers)?;
    println!("\nSetup saved. Inspect trace settings later with `/settings show trace` or `allbert-cli trace --help`. Inspect personalization with `/settings show learning.adapter_training` or `allbert-cli adapters --help`.\n");
    Ok(Some(updated))
}

pub fn apply_setup_answers(
    paths: &AllbertPaths,
    config: &mut Config,
    answers: &SetupAnswers,
) -> Result<()> {
    let user_raw = read_file_or_empty(&paths.user);
    let updated_user = update_user_file(&user_raw, answers);
    atomic_write(&paths.user, updated_user.as_bytes())
        .with_context(|| format!("write {}", paths.user.display()))?;

    let identity_raw = read_file_or_empty(&paths.identity);
    let updated_identity = update_identity_file(&identity_raw, answers);
    atomic_write(&paths.identity, updated_identity.as_bytes())
        .with_context(|| format!("write {}", paths.identity.display()))?;

    config.security.fs_roots = answers.trusted_roots.clone();
    config.model.provider = answers.provider;
    config.model.model_id = answers.model_id.clone();
    config.model.api_key_env = answers.api_key_env.clone();
    config.model.base_url = answers.base_url.clone();
    config.repl.ui = answers.ui_mode;
    config.daemon.auto_spawn = answers.daemon_auto_spawn;
    config.limits.daily_usd_cap = match answers.daily_usd_cap.as_deref() {
        Some(raw) => Some(
            raw.parse::<f64>()
                .with_context(|| format!("parse daily cost cap `{raw}`"))?,
        ),
        None => None,
    };
    config.jobs.enabled = answers.jobs_enabled;
    config.jobs.default_timezone = answers.jobs_default_timezone.clone();
    config.trace.enabled = answers.trace_enabled;
    config.trace.capture_messages = answers.trace_capture_messages;
    config.trace.session_disk_cap_mb = answers.trace_session_disk_cap_mb;
    config.trace.total_disk_cap_mb = answers.trace_total_disk_cap_mb;
    config.trace.retention_days = answers.trace_retention_days;
    config.learning.adapter_training.enabled = answers.adapter_training.enabled;
    config.learning.adapter_training.allowed_backends =
        answers.adapter_training.allowed_backends.clone();
    config.learning.adapter_training.default_backend =
        answers.adapter_training.default_backend.clone();
    config.learning.compute_cap_wall_seconds = answers.adapter_training.compute_cap_wall_seconds;
    config.learning.adapter_training.capture_traces = answers.adapter_training.capture_traces;
    for program in &answers.adapter_training.exec_allow {
        if !config
            .security
            .exec_allow
            .iter()
            .any(|allowed| allowed == program)
        {
            config.security.exec_allow.push(program.clone());
        }
    }
    config.setup.version = CURRENT_SETUP_VERSION;
    config.persist(paths)?;
    enable_bundled_jobs(paths, &answers.enabled_bundled_jobs)?;

    if paths.bootstrap.exists() {
        fs::remove_file(&paths.bootstrap)
            .with_context(|| format!("remove {}", paths.bootstrap.display()))?;
    }

    Ok(())
}

pub fn build_startup_warnings(config: &Config) -> Vec<String> {
    build_startup_warnings_with(config, |key| std::env::var_os(key).is_some())
}

fn build_startup_warnings_with<F>(config: &Config, mut env_has_value: F) -> Vec<String>
where
    F: FnMut(&str) -> bool,
{
    let mut warnings = Vec::new();
    if let Some(api_key_env) = config
        .model
        .api_key_env
        .as_deref()
        .or_else(|| config.model.provider.default_api_key_env())
    {
        if !env_has_value(api_key_env) {
            warnings.push(format!(
                "warning: {} is not set. Export it before your first live turn:\n  export {}=...",
                api_key_env, api_key_env
            ));
        }
    }
    if config.security.fs_roots.is_empty() {
        warnings.push(
            "warning: no trusted filesystem roots are configured. File tools stay disabled until setup or config adds at least one root."
                .into(),
        );
    }
    warnings
}

pub fn print_startup_warnings(config: &Config) {
    for warning in build_startup_warnings(config) {
        eprintln!("{warning}");
    }
}

pub fn render_status(snapshot: &StatusSnapshot) -> String {
    let roots = if snapshot.trusted_roots.is_empty() {
        "(none)".into()
    } else {
        snapshot
            .trusted_roots
            .iter()
            .map(|path| path.display().to_string())
            .collect::<Vec<_>>()
            .join("\n  - ")
    };

    format!(
        "provider:           {}\nmodel:              {}\napi key env:        {} ({})\nsetup version:      {}\nbootstrap pending:  {}\nrepl ui:            {}\nstatus line items:  {}\nmemory routing:     {}\nroot agent:         {}\nlast agent stack:   {}\nlast intent:        {}\ntrusted roots:      {}\nskills installed:   {}\ntrace enabled:      {}\ndaemon auto-spawn:  {}\njobs enabled:       {}\njobs timezone:      {}",
        snapshot.provider,
        snapshot.model_id,
        snapshot
            .api_key_env
            .as_deref()
            .unwrap_or("not required"),
        if snapshot.api_key_env.is_none() {
            "not required"
        } else if snapshot.api_key_present {
            "set"
        } else {
            "missing"
        },
        snapshot.setup_version,
        if snapshot.bootstrap_pending { "yes" } else { "no" },
        snapshot.repl_ui,
        if snapshot.status_line_items.is_empty() {
            "(disabled)".into()
        } else {
            snapshot.status_line_items.join(", ")
        },
        snapshot.memory_routing,
        snapshot.root_agent_name,
        if snapshot.last_agent_stack.is_empty() {
            "(none yet)".into()
        } else {
            snapshot.last_agent_stack.join(" -> ")
        },
        snapshot
            .last_resolved_intent
            .as_deref()
            .unwrap_or("(none yet)"),
        if snapshot.trusted_roots.is_empty() {
            roots
        } else {
            format!("\n  - {roots}")
        },
        snapshot.skill_count,
        if snapshot.trace_enabled { "yes" } else { "no" },
        if snapshot.daemon_auto_spawn { "yes" } else { "no" },
        if snapshot.jobs_enabled { "yes" } else { "no" },
        snapshot
            .jobs_default_timezone
            .as_deref()
            .unwrap_or("(system local)")
    )
}

fn prompt_required(label: &str, default: Option<String>) -> Result<Option<String>> {
    loop {
        match prompt_line(label, default.as_deref())? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) if !value.trim().is_empty() => return Ok(Some(value)),
            PromptLine::Submitted(_) => {
                println!("{label} is required.");
            }
        }
    }
}

fn prompt_provider(default: Provider) -> Result<Option<Provider>> {
    loop {
        match prompt_line(
            "Default provider (anthropic/openrouter/openai/gemini/ollama)",
            Some(default.label()),
        )? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => match Provider::parse(value.trim()) {
                Some(provider) => return Ok(Some(provider)),
                None => {
                    println!(
                        "Provider must be one of: anthropic, openrouter, openai, gemini, ollama."
                    );
                }
            },
        }
    }
}

fn prompt_ui_mode(default: ReplUiMode) -> Result<Option<ReplUiMode>> {
    loop {
        match prompt_line("Interactive UI (tui/classic)", Some(default.label()))? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => match ReplUiMode::parse(value.trim()) {
                Some(mode) => return Ok(Some(mode)),
                None => {
                    println!("Interactive UI must be one of: tui, classic.");
                }
            },
        }
    }
}

fn status_line_catalog() -> Vec<&'static str> {
    StatusLineItem::CATALOG
        .iter()
        .map(|item| item.label())
        .collect()
}

fn default_model_id_for_setup(config: &Config, provider: Provider) -> String {
    if config.model.provider == provider {
        config.model.model_id.clone()
    } else {
        provider.default_model_id().into()
    }
}

fn prompt_optional(label: &str, default: Option<&str>) -> Result<Option<Option<String>>> {
    match prompt_line(label, default)? {
        PromptLine::Cancelled => Ok(None),
        PromptLine::Submitted(value) => {
            if value.trim().is_empty() {
                Ok(Some(None))
            } else {
                Ok(Some(Some(value)))
            }
        }
    }
}

fn prompt_yes_no(label: &str, default: bool) -> Result<Option<bool>> {
    loop {
        let suffix = if default { "[Y/n]" } else { "[y/N]" };
        print!("{label} {suffix} ");
        io::stdout().flush().context("flush setup prompt")?;

        let Some(raw) = read_stdin_line()? else {
            return Ok(None);
        };
        let trimmed = raw.trim().to_ascii_lowercase();
        if trimmed.is_empty() {
            return Ok(Some(default));
        }
        match trimmed.as_str() {
            "y" | "yes" => return Ok(Some(true)),
            "n" | "no" => return Ok(Some(false)),
            _ => println!("Please answer yes or no."),
        }
    }
}

fn prompt_u16(label: &str, default: u16, min: u16, max: u16) -> Result<Option<u16>> {
    loop {
        let raw = match prompt_line(label, Some(&default.to_string()))? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => value,
        };
        match raw.parse::<u16>() {
            Ok(value) if (min..=max).contains(&value) => return Ok(Some(value)),
            _ => println!("{label} must be between {min} and {max}."),
        }
    }
}

fn prompt_u32(label: &str, default: u32, min: u32, max: u32) -> Result<Option<u32>> {
    loop {
        let raw = match prompt_line(label, Some(&default.to_string()))? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => value,
        };
        match raw.parse::<u32>() {
            Ok(value) if (min..=max).contains(&value) => return Ok(Some(value)),
            _ => println!("{label} must be between {min} and {max}."),
        }
    }
}

fn prompt_u64_optional_zero_disables(
    label: &str,
    default: u64,
    min: u64,
    max: u64,
) -> Result<Option<Option<u64>>> {
    loop {
        let raw = match prompt_line(label, Some(&default.to_string()))? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => value,
        };
        match raw.parse::<u64>() {
            Ok(0) => return Ok(Some(None)),
            Ok(value) if (min..=max).contains(&value) => return Ok(Some(Some(value))),
            _ => println!("{label} must be 0 or between {min} and {max}."),
        }
    }
}

fn prompt_trusted_roots(cwd: &Path, current_roots: &[PathBuf]) -> Result<Option<Vec<PathBuf>>> {
    println!("\nTrusted roots control which directories Allbert's file tools may read and write.");
    if current_roots.is_empty() {
        println!(
            "No trusted roots are configured yet. If you skip this, file tools stay disabled."
        );
    } else {
        println!(
            "Current trusted roots:\n  - {}",
            current_roots
                .iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>()
                .join("\n  - ")
        );
    }

    let replace_roots = if current_roots.is_empty() {
        true
    } else {
        match prompt_yes_no("Change your trusted filesystem roots now?", false)? {
            Some(value) => value,
            None => return Ok(None),
        }
    };

    if !replace_roots {
        return Ok(Some(current_roots.to_vec()));
    }

    loop {
        let mut roots = Vec::new();
        let add_cwd = match prompt_yes_no(
            &format!(
                "Trust the current project directory for file tools? ({})",
                cwd.display()
            ),
            true,
        )? {
            Some(value) => value,
            None => return Ok(None),
        };
        if add_cwd {
            roots.push(
                cwd.canonicalize()
                    .with_context(|| format!("canonicalize {}", cwd.display()))?,
            );
        }

        println!("More trusted directories (comma-separated paths, blank for none):");
        let extras = match prompt_line("More trusted directories", None)? {
            PromptLine::Cancelled => return Ok(None),
            PromptLine::Submitted(value) => value,
        };

        match parse_additional_roots(&extras, cwd) {
            Ok(mut parsed) => roots.append(&mut parsed),
            Err(err) => {
                println!("{err}");
                continue;
            }
        }

        dedupe_paths(&mut roots);

        if roots.is_empty() {
            let confirm_empty = match prompt_yes_no(
                "Continue with no trusted roots? File read/write tools will stay disabled.",
                false,
            )? {
                Some(value) => value,
                None => return Ok(None),
            };
            if confirm_empty {
                return Ok(Some(Vec::new()));
            }
            continue;
        }

        return Ok(Some(roots));
    }
}

fn prompt_bundled_jobs(
    paths: &AllbertPaths,
    prefer_safe_defaults: bool,
) -> Result<Option<Vec<String>>> {
    let available = list_job_templates(&paths.jobs_templates)?;
    if available.is_empty() {
        return Ok(Some(Vec::new()));
    }
    let existing = list_job_templates(&paths.jobs_definitions)?
        .into_iter()
        .collect::<HashSet<_>>();
    println!("\nBundled recurring job templates are available but remain disabled by default.");
    println!("Enable only the ones you want Allbert to schedule for this profile.");
    if prefer_safe_defaults && !existing.contains("memory-compile") {
        println!("For fresh profiles that opt into jobs, `memory-compile` is preselected because it stages memory candidates instead of writing durable notes directly.");
    }
    let mut selected = Vec::new();
    for name in available {
        let default = bundled_job_default_enabled(&name, &existing, prefer_safe_defaults);
        let prompt = format!("Enable bundled job template `{name}` now?");
        match prompt_yes_no(&prompt, default)? {
            Some(true) => selected.push(name),
            Some(false) => {}
            None => return Ok(None),
        }
    }
    Ok(Some(selected))
}

fn bundled_job_default_enabled(
    name: &str,
    existing: &HashSet<String>,
    prefer_safe_defaults: bool,
) -> bool {
    existing.contains(name)
        || (prefer_safe_defaults && name == "memory-compile" && !existing.contains(name))
}

fn enable_bundled_jobs(paths: &AllbertPaths, selected: &[String]) -> Result<()> {
    for name in selected {
        let source = paths.jobs_templates.join(format!("{name}.md"));
        if !source.exists() {
            continue;
        }
        let destination = paths.jobs_definitions.join(format!("{name}.md"));
        if destination.exists() {
            continue;
        }
        let raw =
            fs::read_to_string(&source).with_context(|| format!("read {}", source.display()))?;
        let enabled = raw.replacen("enabled: false", "enabled: true", 1);
        atomic_write(&destination, enabled.as_bytes())
            .with_context(|| format!("write {}", destination.display()))?;
    }
    Ok(())
}

fn prompt_adapter_training(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<Option<AdapterTrainingSetupAnswers>> {
    println!(
        "\nLocal personalization is optional and trains review-first adapters on this machine."
    );
    println!(
        "Hosted providers ignore active adapters. Local training requires both `learning.adapter_training.allowed_backends` and `security.exec_allow`."
    );
    let enabled = match prompt_yes_no(
        "Enable local adapter training for this profile?",
        config.learning.adapter_training.enabled,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };

    let mut answers = AdapterTrainingSetupAnswers {
        enabled,
        compute_cap_wall_seconds: config.learning.compute_cap_wall_seconds,
        capture_traces: config.learning.adapter_training.capture_traces,
        ..AdapterTrainingSetupAnswers::default()
    };

    if enabled {
        let detected = detect_adapter_training_backends();
        if detected.is_empty() {
            println!(
                "No supported real trainer backend was detected on PATH. Adapter training will stay disabled until you allowlist one with settings."
            );
            answers.enabled = false;
        } else {
            println!(
                "Detected trainer backends:\n  - {}",
                detected
                    .iter()
                    .map(|backend| format!("{} ({})", backend.id, backend.exec_allow))
                    .collect::<Vec<_>>()
                    .join("\n  - ")
            );
            let default_backend = config
                .learning
                .adapter_training
                .default_backend
                .as_deref()
                .filter(|backend| detected.iter().any(|candidate| candidate.id == *backend))
                .unwrap_or(detected[0].id);
            let selected = loop {
                match prompt_optional("Adapter trainer backend", Some(default_backend))? {
                    Some(Some(value)) => {
                        if let Some(backend) = detected.iter().find(|backend| backend.id == value) {
                            break *backend;
                        }
                        println!(
                            "Backend must be one of: {}.",
                            detected
                                .iter()
                                .map(|backend| backend.id)
                                .collect::<Vec<_>>()
                                .join(", ")
                        );
                    }
                    Some(None) => {
                        answers.enabled = false;
                        break DetectedAdapterBackend {
                            id: "",
                            exec_allow: "",
                        };
                    }
                    None => return Ok(None),
                }
            };
            if answers.enabled {
                answers.allowed_backends = vec![selected.id.to_string()];
                answers.default_backend = Some(selected.id.to_string());
                answers.exec_allow = vec![selected.exec_allow.to_string()];
            }
        }
    }

    answers.compute_cap_wall_seconds = match prompt_u64_optional_zero_disables(
        "Daily local-training compute cap in seconds",
        config.learning.compute_cap_wall_seconds.unwrap_or(7_200),
        60,
        86_400,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    answers.capture_traces = match prompt_yes_no(
        "Include redacted trace excerpts in adapter training corpus?",
        config.learning.adapter_training.capture_traces,
    )? {
        Some(value) => value,
        None => return Ok(None),
    };
    println!(
        "Personalization summary: enabled={}, backends={}, capture_traces={}. Inspect later with `/settings show learning.adapter_training`, `allbert-cli adapters --help`, or `allbert-cli adapters training preview`.",
        if answers.enabled { "yes" } else { "no" },
        if answers.allowed_backends.is_empty() {
            "(none)".into()
        } else {
            answers.allowed_backends.join(", ")
        },
        if answers.capture_traces { "yes" } else { "no" }
    );
    persist_setup_state(paths, config, "adapter_training", None, Some(&answers))?;
    Ok(Some(answers))
}

#[derive(Clone, Copy)]
struct DetectedAdapterBackend {
    id: &'static str,
    exec_allow: &'static str,
}

fn detect_adapter_training_backends() -> Vec<DetectedAdapterBackend> {
    let mut detected = Vec::new();
    if python_has_mlx_lm() {
        detected.push(DetectedAdapterBackend {
            id: "mlx-lm-lora",
            exec_allow: "python3",
        });
    }
    if command_on_path("llama-cpp-finetune") {
        detected.push(DetectedAdapterBackend {
            id: "llama-cpp-finetune",
            exec_allow: "llama-cpp-finetune",
        });
    }
    if std::env::var_os("ALLBERT_DEV_FAKE_ADAPTER_TRAINER").is_some() {
        detected.push(DetectedAdapterBackend {
            id: "fake",
            exec_allow: "fake-adapter-trainer",
        });
    }
    detected
}

fn python_has_mlx_lm() -> bool {
    if !command_on_path("python3") {
        return false;
    }
    Command::new("python3")
        .args(["-c", "import mlx_lm"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn command_on_path(command: &str) -> bool {
    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| {
        let candidate = dir.join(command);
        candidate.is_file()
    })
}

fn list_job_templates(root: &Path) -> Result<Vec<String>> {
    let mut names = Vec::new();
    let Ok(entries) = fs::read_dir(root) else {
        return Ok(names);
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("md") {
            continue;
        }
        if let Some(stem) = path.file_stem().and_then(|stem| stem.to_str()) {
            names.push(stem.to_string());
        }
    }
    names.sort();
    names.dedup();
    Ok(names)
}

fn prompt_line(label: &str, default: Option<&str>) -> Result<PromptLine> {
    match default {
        Some(value) => print!("{label} [{value}]: "),
        None => print!("{label}: "),
    }
    io::stdout().flush().context("flush setup prompt")?;

    let Some(raw) = read_stdin_line()? else {
        return Ok(PromptLine::Cancelled);
    };

    let trimmed = raw.trim_end_matches(['\r', '\n']).trim();
    if trimmed.eq_ignore_ascii_case("/cancel") {
        return Ok(PromptLine::Cancelled);
    }

    if trimmed.is_empty() {
        return Ok(PromptLine::Submitted(
            default.map(str::to_string).unwrap_or_default(),
        ));
    }

    Ok(PromptLine::Submitted(trimmed.to_string()))
}

fn read_stdin_line() -> Result<Option<String>> {
    let mut buf = String::new();
    if io::stdin()
        .read_line(&mut buf)
        .context("read setup input")?
        == 0
    {
        return Ok(None);
    }
    Ok(Some(buf))
}

fn parse_additional_roots(raw: &str, cwd: &Path) -> Result<Vec<PathBuf>> {
    let mut roots = Vec::new();
    for part in raw.split(',') {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            continue;
        }
        roots.push(normalize_root_choice(trimmed, cwd)?);
    }
    Ok(roots)
}

fn normalize_root_choice(raw: &str, cwd: &Path) -> Result<PathBuf> {
    let candidate = PathBuf::from(raw);
    let absolute = if candidate.is_absolute() {
        candidate
    } else {
        cwd.join(candidate)
    };

    let metadata = fs::metadata(&absolute)
        .with_context(|| format!("trusted root does not exist: {}", absolute.display()))?;
    if !metadata.is_dir() {
        anyhow::bail!("trusted root must be a directory: {}", absolute.display());
    }

    absolute
        .canonicalize()
        .with_context(|| format!("canonicalize {}", absolute.display()))
}

fn dedupe_paths(paths: &mut Vec<PathBuf>) {
    let mut seen = std::collections::HashSet::new();
    paths.retain(|path| seen.insert(path.clone()));
}

fn update_user_file(raw: &str, answers: &SetupAnswers) -> String {
    let mut content = raw.to_string();
    content = set_section_lines(
        &content,
        "Preferred name",
        &[format!("- {}", answers.preferred_name)],
    );
    content = set_section_lines(&content, "Timezone", &[format!("- {}", answers.timezone)]);
    content = set_section_lines(
        &content,
        "Working style",
        &[format!("- {}", answers.working_style)],
    );
    set_section_lines(
        &content,
        "Current priorities",
        &[format!("- {}", answers.current_priorities)],
    )
}

fn update_identity_file(raw: &str, answers: &SetupAnswers) -> String {
    let mut content = raw.to_string();
    if let Some(name) = &answers.assistant_name {
        content = set_section_lines(&content, "Name", std::slice::from_ref(name));
    }
    if let Some(role) = &answers.assistant_role {
        content = set_section_lines(&content, "Role", std::slice::from_ref(role));
    }
    if let Some(style) = &answers.assistant_style {
        content = set_section_lines(&content, "Style", std::slice::from_ref(style));
    }
    content
}

fn set_section_lines(content: &str, heading: &str, new_lines: &[String]) -> String {
    let header = format!("## {heading}");
    let mut lines = content
        .lines()
        .map(|line| line.to_string())
        .collect::<Vec<_>>();

    if let Some(start) = lines.iter().position(|line| line.trim() == header) {
        let mut end = start + 1;
        while end < lines.len() && !lines[end].trim_start().starts_with("## ") {
            end += 1;
        }

        let mut replacement = Vec::with_capacity(new_lines.len() + 2);
        replacement.push(String::new());
        replacement.extend(new_lines.iter().cloned());
        replacement.push(String::new());
        lines.splice(start + 1..end, replacement);
    } else {
        if !lines.is_empty() && !lines.last().is_some_and(|line| line.trim().is_empty()) {
            lines.push(String::new());
        }
        lines.push(header);
        lines.push(String::new());
        lines.extend(new_lines.iter().cloned());
        lines.push(String::new());
    }

    while lines.last().is_some_and(|line| line.trim().is_empty()) {
        lines.pop();
    }

    if lines.is_empty() {
        String::new()
    } else {
        format!("{}\n", lines.join("\n"))
    }
}

fn read_file_or_empty(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

fn setup_state_path(paths: &AllbertPaths, config: &Config) -> PathBuf {
    paths.root.join(&config.setup.state_path)
}

fn load_setup_state(paths: &AllbertPaths, config: &Config) -> Result<Option<SetupState>> {
    let path = setup_state_path(paths, config);
    if !path.exists() {
        return Ok(None);
    }
    let raw = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    let state =
        toml::from_str::<SetupState>(&raw).with_context(|| format!("parse {}", path.display()))?;
    Ok(Some(state))
}

fn persist_setup_state(
    paths: &AllbertPaths,
    config: &Config,
    current_step: &str,
    answers: Option<&SetupAnswers>,
    adapter_training: Option<&AdapterTrainingSetupAnswers>,
) -> Result<()> {
    let path = setup_state_path(paths, config);
    let mut state = load_setup_state(paths, config)?.unwrap_or(SetupState {
        schema_version: 1,
        current_step: current_step.into(),
        answers: None,
        adapter_training: None,
    });
    state.schema_version = 1;
    state.current_step = current_step.into();
    if let Some(answers) = answers {
        state.answers = Some(answers.clone());
    }
    if let Some(adapter_training) = adapter_training {
        state.adapter_training = Some(adapter_training.clone());
    }
    let rendered = toml::to_string_pretty(&state).context("serialize setup state")?;
    atomic_write(&path, rendered.as_bytes()).with_context(|| format!("write {}", path.display()))
}

fn extract_section_value(content: &str, heading: &str) -> Option<String> {
    let header = format!("## {heading}");
    let lines = content.lines().collect::<Vec<_>>();
    let start = lines.iter().position(|line| line.trim() == header)?;
    let mut idx = start + 1;
    while idx < lines.len() {
        let trimmed = lines[idx].trim();
        if trimmed.starts_with("## ") {
            break;
        }
        if !trimmed.is_empty() {
            return Some(trimmed.trim_start_matches("- ").trim().to_string());
        }
        idx += 1;
    }
    None
}

fn suggested_preferred_name(user_raw: &str) -> Option<String> {
    choose_preferred_name_default(
        non_placeholder_user_value(extract_section_value(user_raw, "Preferred name")),
        std::env::var("USER").ok(),
    )
}

fn choose_preferred_name_default(
    saved_value: Option<String>,
    login_name: Option<String>,
) -> Option<String> {
    saved_value.or_else(|| login_name.and_then(|value| prettify_login_name(&value)))
}

fn suggested_timezone(user_raw: &str) -> Option<String> {
    choose_timezone_default(
        non_placeholder_user_value(extract_section_value(user_raw, "Timezone")),
        std::env::var("TZ").ok(),
        iana_time_zone::get_timezone().ok(),
    )
}

fn suggested_working_style(user_raw: &str) -> Option<String> {
    non_placeholder_user_value(extract_section_value(user_raw, "Working style"))
        .or_else(|| Some("Short updates and concrete next steps.".into()))
}

fn suggested_current_priorities(user_raw: &str) -> Option<String> {
    non_placeholder_user_value(extract_section_value(user_raw, "Current priorities"))
        .or_else(|| Some("No durable priorities yet.".into()))
}

fn choose_timezone_default(
    saved_value: Option<String>,
    tz_env: Option<String>,
    system_guess: Option<String>,
) -> Option<String> {
    saved_value.or(tz_env).or(system_guess)
}

fn prettify_login_name(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let words = trimmed
        .split(['.', '_', '-'])
        .filter(|part| !part.is_empty())
        .map(|part| {
            let mut chars = part.chars();
            match chars.next() {
                Some(first) => {
                    let mut word = first.to_uppercase().collect::<String>();
                    word.push_str(chars.as_str());
                    word
                }
                None => String::new(),
            }
        })
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();

    if words.is_empty() {
        None
    } else {
        Some(words.join(" "))
    }
}

fn non_placeholder_user_value(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        if value == PLACEHOLDER_UNKNOWN || value == PLACEHOLDER_BOOTSTRAP {
            None
        } else {
            Some(value)
        }
    })
}

enum PromptLine {
    Cancelled,
    Submitted(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static TEMP_COUNTER: AtomicUsize = AtomicUsize::new(0);

    struct TempRoot {
        path: PathBuf,
    }

    impl TempRoot {
        fn new() -> Self {
            let counter = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
            let unique = format!(
                "allbert-cli-setup-test-{}-{}-{}",
                std::process::id(),
                counter,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("time should be available")
                    .as_nanos()
            );
            let path = std::env::temp_dir().join(unique);
            fs::create_dir_all(&path).expect("temp root should be created");
            Self { path }
        }

        fn paths(&self) -> AllbertPaths {
            AllbertPaths::under(self.path.clone())
        }
    }

    impl Drop for TempRoot {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn sample_answers(root: &Path) -> SetupAnswers {
        SetupAnswers {
            provider: Provider::Ollama,
            model_id: "gemma4".into(),
            api_key_env: None,
            base_url: Some("http://127.0.0.1:11434".into()),
            ui_mode: ReplUiMode::Tui,
            preferred_name: "Spuri".into(),
            timezone: "America/Los_Angeles".into(),
            working_style: "Short updates and concrete next steps.".into(),
            current_priorities: "Close out v0.1 cleanly.".into(),
            assistant_name: Some("Allbert".into()),
            assistant_role: Some("A local assistant for Spuri.".into()),
            assistant_style: Some("Warm, concise, and practical.".into()),
            trusted_roots: vec![root.to_path_buf()],
            daemon_auto_spawn: true,
            daily_usd_cap: Some("5.00".into()),
            jobs_enabled: true,
            jobs_default_timezone: Some("America/Los_Angeles".into()),
            enabled_bundled_jobs: vec!["daily-brief".into()],
            trace_enabled: true,
            trace_capture_messages: false,
            trace_session_disk_cap_mb: 25,
            trace_total_disk_cap_mb: 1024,
            trace_retention_days: 14,
            adapter_training: AdapterTrainingSetupAnswers {
                enabled: true,
                allowed_backends: vec!["fake".into()],
                default_backend: Some("fake".into()),
                exec_allow: vec!["fake-adapter-trainer".into()],
                compute_cap_wall_seconds: Some(3_600),
                capture_traces: true,
            },
        }
    }

    #[test]
    fn apply_setup_answers_writes_config_and_bootstrap_state() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let workspace = temp.path.join("workspace");
        fs::create_dir_all(&workspace).expect("workspace should exist");

        let mut config = Config::default_template();
        let answers = sample_answers(&workspace);
        apply_setup_answers(&paths, &mut config, &answers).expect("setup should succeed");

        assert_eq!(config.setup.version, CURRENT_SETUP_VERSION);
        assert_eq!(config.model.provider, Provider::Ollama);
        assert_eq!(config.model.model_id, "gemma4");
        assert_eq!(config.model.api_key_env, None);
        assert!(config.trace.enabled);
        assert!(!config.trace.capture_messages);
        assert_eq!(config.trace.session_disk_cap_mb, 25);
        assert_eq!(config.trace.total_disk_cap_mb, 1024);
        assert!(config.learning.adapter_training.enabled);
        assert_eq!(
            config.learning.adapter_training.allowed_backends,
            vec!["fake"]
        );
        assert_eq!(
            config.learning.adapter_training.default_backend.as_deref(),
            Some("fake")
        );
        assert_eq!(config.learning.compute_cap_wall_seconds, Some(3_600));
        assert!(config.learning.adapter_training.capture_traces);
        assert!(config
            .security
            .exec_allow
            .iter()
            .any(|entry| entry == "fake-adapter-trainer"));
        assert_eq!(config.trace.retention_days, 14);
        assert_eq!(
            config.model.base_url.as_deref(),
            Some("http://127.0.0.1:11434")
        );
        assert_eq!(config.security.fs_roots, vec![workspace.clone()]);
        assert_eq!(config.repl.ui, ReplUiMode::Tui);
        assert!(config.daemon.auto_spawn);
        assert!(config.jobs.enabled);
        assert_eq!(
            config.jobs.default_timezone.as_deref(),
            Some("America/Los_Angeles")
        );
        assert!(!paths.bootstrap.exists());
        assert!(paths.jobs_definitions.join("daily-brief.md").exists());

        let user = fs::read_to_string(&paths.user).expect("USER.md should be readable");
        assert!(user.contains("Spuri"));
        assert!(user.contains("America/Los_Angeles"));

        let identity = fs::read_to_string(&paths.identity).expect("IDENTITY.md should be readable");
        assert!(identity.contains("Warm, concise, and practical."));

        let loaded = Config::load_or_create(&paths).expect("persisted config should load");
        assert_eq!(loaded.setup.version, CURRENT_SETUP_VERSION);
        assert_eq!(loaded.security.fs_roots, vec![workspace]);
        assert_eq!(loaded.repl.ui, ReplUiMode::Tui);
        assert!(loaded.daemon.auto_spawn);
        assert!(loaded.jobs.enabled);
    }

    #[test]
    fn setup_state_persists_adapter_training_resume_block() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");
        let config = Config::default_template();
        let workspace = temp.path.join("workspace");
        fs::create_dir_all(&workspace).expect("workspace should exist");
        let answers = sample_answers(&workspace);

        persist_setup_state(
            &paths,
            &config,
            "adapter_training",
            Some(&answers),
            Some(&answers.adapter_training),
        )
        .expect("setup state should write");
        let loaded = load_setup_state(&paths, &config)
            .expect("state should read")
            .expect("state should exist");

        assert_eq!(loaded.current_step, "adapter_training");
        assert!(loaded.answers.is_some());
        assert_eq!(
            loaded
                .adapter_training
                .expect("adapter block")
                .default_backend,
            Some("fake".into())
        );
    }

    #[test]
    fn zero_root_setup_is_allowed() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let mut config = Config::default_template();
        let mut answers = sample_answers(&temp.path);
        answers.trusted_roots.clear();

        apply_setup_answers(&paths, &mut config, &answers).expect("setup should succeed");
        assert_eq!(config.setup.version, CURRENT_SETUP_VERSION);
        assert!(config.security.fs_roots.is_empty());
        assert!(!paths.bootstrap.exists());
    }

    #[test]
    fn status_render_reports_missing_key_and_empty_roots() {
        let rendered = render_status(&StatusSnapshot {
            provider: "anthropic".into(),
            model_id: "claude-sonnet-4-5".into(),
            api_key_env: Some("ANTHROPIC_API_KEY".into()),
            api_key_present: false,
            setup_version: 2,
            bootstrap_pending: false,
            trusted_roots: Vec::new(),
            skill_count: 2,
            trace_enabled: true,
            daemon_auto_spawn: true,
            jobs_enabled: true,
            jobs_default_timezone: Some("America/Los_Angeles".into()),
            root_agent_name: "allbert/root".into(),
            last_agent_stack: vec!["allbert/root".into()],
            last_resolved_intent: Some("task".into()),
            repl_ui: "tui".into(),
            memory_routing: "always_eligible".into(),
            status_line_items: vec!["model".into(), "context".into()],
        });

        assert!(rendered.contains("ANTHROPIC_API_KEY (missing)"));
        assert!(rendered.contains("trusted roots:      (none)"));
        assert!(rendered.contains("trace enabled:      yes"));
        assert!(rendered.contains("daemon auto-spawn:  yes"));
        assert!(rendered.contains("jobs timezone:      America/Los_Angeles"));
        assert!(rendered.contains("repl ui:            tui"));
        assert!(rendered.contains("status line items:  model, context"));
        assert!(rendered.contains("memory routing:     always_eligible"));
        assert!(rendered.contains("root agent:         allbert/root"));
        assert!(rendered.contains("last agent stack:   allbert/root"));
        assert!(rendered.contains("last intent:        task"));
    }

    #[test]
    fn status_render_reports_keyless_provider_as_not_required() {
        let rendered = render_status(&StatusSnapshot {
            provider: "ollama".into(),
            model_id: "gemma4".into(),
            api_key_env: None,
            api_key_present: true,
            setup_version: 2,
            bootstrap_pending: false,
            trusted_roots: Vec::new(),
            skill_count: 0,
            trace_enabled: false,
            daemon_auto_spawn: true,
            jobs_enabled: false,
            jobs_default_timezone: None,
            root_agent_name: "allbert/root".into(),
            last_agent_stack: Vec::new(),
            last_resolved_intent: None,
            repl_ui: "classic".into(),
            memory_routing: "always_eligible".into(),
            status_line_items: Vec::new(),
        });

        assert!(rendered.contains("api key env:        not required (not required)"));
    }

    #[test]
    fn startup_warnings_skip_api_key_for_default_ollama() {
        let warnings = build_startup_warnings_with(&Config::default_template(), |_| false);
        assert_eq!(warnings.len(), 1);
        assert!(warnings[0].contains("trusted filesystem roots"));
    }

    #[test]
    fn startup_warnings_flag_missing_hosted_api_key_and_roots() {
        let mut config = Config::default_template();
        config.model.provider = Provider::Anthropic;
        config.model.model_id = "claude-sonnet-4-5".into();
        config.model.api_key_env = Some("ANTHROPIC_API_KEY".into());
        config.model.base_url = None;
        let warnings = build_startup_warnings_with(&config, |_| false);
        assert_eq!(warnings.len(), 2);
        assert!(warnings[0].contains("ANTHROPIC_API_KEY"));
        assert!(warnings[1].contains("trusted filesystem roots"));
    }

    #[test]
    fn timezone_default_prefers_saved_then_env_then_system_guess() {
        assert_eq!(
            choose_timezone_default(
                Some("America/New_York".into()),
                Some("Europe/Berlin".into()),
                Some("America/Los_Angeles".into())
            ),
            Some("America/New_York".into())
        );
        assert_eq!(
            choose_timezone_default(
                None,
                Some("Europe/Berlin".into()),
                Some("America/Los_Angeles".into())
            ),
            Some("Europe/Berlin".into())
        );
        assert_eq!(
            choose_timezone_default(None, None, Some("America/Los_Angeles".into())),
            Some("America/Los_Angeles".into())
        );
    }

    #[test]
    fn preferred_name_default_prefers_saved_then_login_name() {
        assert_eq!(
            choose_preferred_name_default(Some("Spuri".into()), Some("lex_lapax".into())),
            Some("Spuri".into())
        );
        assert_eq!(
            choose_preferred_name_default(None, Some("lex_lapax".into())),
            Some("Lex Lapax".into())
        );
    }

    #[test]
    fn working_style_and_priorities_have_sane_fallbacks() {
        assert_eq!(
            suggested_working_style(""),
            Some("Short updates and concrete next steps.".into())
        );
        assert_eq!(
            suggested_current_priorities(""),
            Some("No durable priorities yet.".into())
        );
    }

    #[test]
    fn identity_fields_are_preserved_when_setup_skips_identity_changes() {
        let temp = TempRoot::new();
        let paths = temp.paths();
        paths.ensure().expect("paths should be created");

        let original_identity =
            fs::read_to_string(&paths.identity).expect("IDENTITY.md should be readable");
        let mut config = Config::default_template();
        let mut answers = sample_answers(&temp.path);
        answers.assistant_name = None;
        answers.assistant_role = None;
        answers.assistant_style = None;

        apply_setup_answers(&paths, &mut config, &answers).expect("setup should succeed");
        let updated_identity =
            fs::read_to_string(&paths.identity).expect("IDENTITY.md should be readable");
        assert_eq!(original_identity, updated_identity);
    }

    #[test]
    fn bundled_job_defaults_only_preselect_memory_compile_for_fresh_profiles() {
        let empty = HashSet::new();
        assert!(bundled_job_default_enabled("memory-compile", &empty, true));
        assert!(!bundled_job_default_enabled("daily-brief", &empty, true));
        assert!(!bundled_job_default_enabled("weekly-review", &empty, true));
        assert!(!bundled_job_default_enabled("trace-triage", &empty, true));
        assert!(!bundled_job_default_enabled(
            "system-health-check",
            &empty,
            true
        ));
        assert!(!bundled_job_default_enabled(
            "memory-compile",
            &empty,
            false
        ));
    }

    #[test]
    fn bundled_job_defaults_preserve_existing_state() {
        let existing = HashSet::from([String::from("daily-brief"), String::from("memory-compile")]);
        assert!(bundled_job_default_enabled("daily-brief", &existing, false));
        assert!(bundled_job_default_enabled(
            "memory-compile",
            &existing,
            false
        ));
        assert!(bundled_job_default_enabled(
            "memory-compile",
            &existing,
            true
        ));
    }
}
