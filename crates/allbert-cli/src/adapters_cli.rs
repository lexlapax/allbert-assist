use std::path::{Path, PathBuf};

use allbert_kernel::{
    activate_adapter, adapter_compute_used_today_seconds, cleanup_runtime_files,
    deactivate_adapter, preview_personality_adapter_training,
    run_personality_adapter_training_with_override, AdapterStore, AllbertPaths, Config,
};
use anyhow::{anyhow, Context, Result};
use clap::Subcommand;

#[derive(Subcommand, Debug)]
#[command(
    after_long_help = "EXAMPLES:\n  allbert-cli adapters list\n  allbert-cli adapters show fake-abc123\n  allbert-cli adapters activate fake-abc123\n  allbert-cli adapters training preview\n  allbert-cli adapters training start\n"
)]
pub enum AdaptersCommand {
    /// List installed adapters.
    List,
    /// Show one adapter manifest as JSON.
    Show { id: String },
    /// Activate one reviewed adapter.
    Activate {
        id: String,
        #[arg(
            long = "override",
            value_name = "REASON",
            help = "Activate a needs-attention adapter with a recorded reason"
        )]
        override_reason: Option<String>,
    },
    /// Clear the active adapter pointer.
    Deactivate,
    /// Remove an installed adapter.
    Remove {
        id: String,
        #[arg(long)]
        force: bool,
    },
    /// Show active adapter and compute-cap status.
    Status,
    /// Show adapter history newest first.
    History {
        #[arg(long)]
        limit: Option<usize>,
    },
    /// Remove derived runtime cache files.
    Gc,
    /// Show eval summary and artifact paths for an adapter.
    Eval { id: String },
    /// Print the ASCII loss curve for an adapter.
    Loss { id: String },
    /// Quarantine an external adapter directory.
    Install { path: String },
    /// Training commands.
    Training {
        #[command(subcommand)]
        command: AdapterTrainingCommand,
    },
}

#[derive(Subcommand, Debug)]
pub enum AdapterTrainingCommand {
    /// Run a dry preview of the training corpus.
    Preview,
    /// Start a local adapter training run.
    Start {
        #[arg(
            long = "override",
            value_name = "REASON",
            help = "Bypass the daily compute cap for this run with a recorded reason"
        )]
        override_reason: Option<String>,
    },
    /// Request cancellation of an active training run.
    Cancel,
}

pub fn run(paths: &AllbertPaths, config: &Config, command: AdaptersCommand) -> Result<()> {
    let store = AdapterStore::new(paths.clone());
    match command {
        AdaptersCommand::List => {
            for manifest in store.list()? {
                println!(
                    "{}\t{:?}\t{} / {}\t{}",
                    manifest.adapter_id,
                    manifest.overall,
                    provider_label(manifest.base_model.provider),
                    manifest.base_model.model_id,
                    manifest.created_at
                );
            }
        }
        AdaptersCommand::Show { id } => {
            let manifest = store
                .show(&id)?
                .ok_or_else(|| anyhow!("adapter not found: {id}"))?;
            println!("{}", serde_json::to_string_pretty(&manifest)?);
        }
        AdaptersCommand::Activate {
            id,
            override_reason,
        } => {
            let activation =
                activate_adapter(&store, &config.model, &id, override_reason.as_deref())?;
            println!("activated {}", activation.active.adapter_id);
            for warning in activation.warnings {
                println!("warning: {warning}");
            }
        }
        AdaptersCommand::Deactivate => {
            deactivate_adapter(&store, Some("cli deactivate"))?;
            println!("adapter deactivated");
        }
        AdaptersCommand::Remove { id, force } => {
            store.remove(&id, force)?;
            println!("removed {id}");
        }
        AdaptersCommand::Status => {
            let compute_used_today_seconds = adapter_compute_used_today_seconds(paths)?;
            match store.active()? {
                Some(active) => println!(
                    "active: {} on {}",
                    active.adapter_id, active.base_model.model_id
                ),
                None => println!("active: none"),
            }
            println!(
                "daily compute cap: {}",
                config
                    .learning
                    .compute_cap_wall_seconds
                    .map(|value| format!("{value}s"))
                    .unwrap_or_else(|| "disabled".into())
            );
            println!("today's adapter compute: {compute_used_today_seconds}s");
            if let Some(cap) = config.learning.compute_cap_wall_seconds {
                println!(
                    "remaining adapter compute: {}s",
                    cap.saturating_sub(compute_used_today_seconds)
                );
            }
        }
        AdaptersCommand::History { limit } => {
            for entry in store.history(limit)? {
                println!(
                    "{}\t{}\t{}{}",
                    entry.at,
                    entry.action,
                    entry.adapter_id,
                    entry
                        .reason
                        .as_ref()
                        .map(|reason| format!("\t{reason}"))
                        .unwrap_or_default()
                );
            }
        }
        AdaptersCommand::Gc => {
            cleanup_runtime_files(paths, None)?;
            println!("adapter runtime cache cleaned");
        }
        AdaptersCommand::Eval { id } => {
            let manifest = store
                .show(&id)?
                .ok_or_else(|| anyhow!("adapter not found: {id}"))?;
            println!("{}", serde_json::to_string_pretty(&manifest.eval_summary)?);
        }
        AdaptersCommand::Loss { id } => {
            let manifest = store
                .show(&id)?
                .ok_or_else(|| anyhow!("adapter not found: {id}"))?;
            let path = PathBuf::from(&manifest.eval_summary.loss_curve_path);
            let raw = std::fs::read_to_string(&path)
                .with_context(|| format!("read loss curve {}", path.display()))?;
            print!("{raw}");
        }
        AdaptersCommand::Install { path } => {
            let incoming = quarantine_external_adapter(paths, Path::new(&path))?;
            println!("quarantined external adapter at {}", incoming.display());
        }
        AdaptersCommand::Training { command } => match command {
            AdapterTrainingCommand::Preview => {
                let corpus = preview_personality_adapter_training(paths, config)?;
                println!("{}", serde_json::to_string_pretty(&corpus.summary)?);
            }
            AdapterTrainingCommand::Start { override_reason } => {
                let override_reason = override_reason
                    .as_deref()
                    .map(str::trim)
                    .filter(|reason| !reason.is_empty());
                let report =
                    run_personality_adapter_training_with_override(paths, config, override_reason)?;
                println!("{}", serde_json::to_string_pretty(&report)?);
            }
            AdapterTrainingCommand::Cancel => {
                println!("no active trainer process is tracked by this CLI invocation");
            }
        },
    }
    Ok(())
}

fn quarantine_external_adapter(paths: &AllbertPaths, source: &Path) -> Result<PathBuf> {
    let manifest = allbert_kernel::read_adapter_manifest(&source.join("manifest.json"))?;
    let destination = paths.adapters_incoming.join(&manifest.adapter_id);
    if destination.exists() {
        return Err(anyhow!(
            "incoming adapter already exists: {}",
            manifest.adapter_id
        ));
    }
    std::fs::create_dir_all(&destination)?;
    for entry in std::fs::read_dir(source)? {
        let entry = entry?;
        if entry.file_type()?.is_file() {
            std::fs::copy(entry.path(), destination.join(entry.file_name()))?;
        }
    }
    Ok(destination)
}

fn provider_label(provider: allbert_proto::ProviderKind) -> &'static str {
    match provider {
        allbert_proto::ProviderKind::Anthropic => "anthropic",
        allbert_proto::ProviderKind::Openrouter => "openrouter",
        allbert_proto::ProviderKind::Openai => "openai",
        allbert_proto::ProviderKind::Gemini => "gemini",
        allbert_proto::ProviderKind::Ollama => "ollama",
    }
}
