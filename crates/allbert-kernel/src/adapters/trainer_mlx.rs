use std::process::{Command, Stdio};

use allbert_proto::{
    AdapterEvalSummary, AdapterManifest, AdapterOverallStatus, AdapterProvenance,
    AdapterResourceCost, AdapterWeightsFormat,
};
use chrono::Utc;

use crate::adapters::manifest::{write_adapter_manifest, MANIFEST_FILE};
use crate::adapters::trainer::{
    capture_trainer_output, ensure_trainer_allowed, minimal_trainer_env, AdapterTrainer,
    CancellationToken, TrainerCommand, TrainerError, TrainerHooks, TrainerProgress,
    TrainingOutcome, TrainingPlan, TRAINER_STDIO_CAPTURE_BYTES,
};
use crate::{atomic_write, AllbertPaths, Config};

#[derive(Clone)]
pub struct MlxLoraTrainer {
    paths: AllbertPaths,
    config: Config,
    program: String,
}

impl MlxLoraTrainer {
    pub fn new(paths: AllbertPaths, config: Config) -> Self {
        Self {
            paths,
            config,
            program: "python3".into(),
        }
    }

    pub fn with_program(mut self, program: impl Into<String>) -> Self {
        self.program = program.into();
        self
    }

    pub fn command_for_plan(&self, plan: &TrainingPlan) -> TrainerCommand {
        TrainerCommand {
            program: self.program.clone(),
            cwd: Some(plan.run_dir.clone()),
            args: vec![
                "-m".into(),
                "mlx_lm.lora".into(),
                "--model".into(),
                plan.base_model.model_id.clone(),
                "--train".into(),
                "--adapter-path".into(),
                plan.run_dir.to_string_lossy().into_owned(),
                "--data".into(),
                plan.run_dir
                    .join("corpus-snapshot.json")
                    .to_string_lossy()
                    .into_owned(),
                "--iters".into(),
                plan.hyperparameters.max_steps.to_string(),
                "--batch-size".into(),
                plan.hyperparameters.batch_size.to_string(),
                "--lora-layers".into(),
                plan.hyperparameters.rank.to_string(),
                "--learning-rate".into(),
                plan.hyperparameters.learning_rate.to_string(),
                "--seed".into(),
                plan.hyperparameters.seed.to_string(),
            ],
        }
    }
}

impl AdapterTrainer for MlxLoraTrainer {
    fn backend_id(&self) -> &'static str {
        "mlx-lm-lora"
    }

    fn train(
        &self,
        plan: &TrainingPlan,
        hooks: &TrainerHooks,
        cancel: &CancellationToken,
    ) -> Result<TrainingOutcome, TrainerError> {
        hooks.check_dispatch(plan)?;
        if cancel.is_cancelled() {
            return Err(TrainerError::Cancelled {
                run_id: plan.run_id.clone(),
            });
        }
        std::fs::create_dir_all(&plan.run_dir)
            .map_err(|source| TrainerError::io(&plan.run_dir, source))?;
        let corpus_path = plan.run_dir.join("corpus-snapshot.json");
        atomic_write(
            &corpus_path,
            &serde_json::to_vec_pretty(&plan.corpus)
                .map_err(|source| TrainerError::Backend(format!("serialize corpus: {source}")))?,
        )
        .map_err(|source| TrainerError::io(&corpus_path, source))?;
        let command = self.command_for_plan(plan);
        ensure_trainer_allowed(&self.config, self.backend_id(), &command)?;
        let output = run_command(&self.paths, &command)?;
        write_captured_output(plan, &output)?;
        if output.status_success {
            materialize_manifest(
                plan,
                self.backend_id(),
                AdapterWeightsFormat::SafetensorsLora,
            )
        } else {
            Err(TrainerError::Backend(format!(
                "mlx trainer exited unsuccessfully; see {}",
                plan.run_dir.display()
            )))
        }
    }
}

#[derive(Debug)]
struct TrainerProcessOutput {
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    stdout_truncated: bool,
    stderr_truncated: bool,
    status_success: bool,
}

fn run_command(
    paths: &AllbertPaths,
    command: &TrainerCommand,
) -> Result<TrainerProcessOutput, TrainerError> {
    let mut process = Command::new(&command.program);
    process
        .args(&command.args)
        .env_clear()
        .envs(minimal_trainer_env(paths))
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = &command.cwd {
        process.current_dir(cwd);
    }
    let output = process
        .output()
        .map_err(|source| TrainerError::io(&command.program, source))?;
    let captured =
        capture_trainer_output(&output.stdout, &output.stderr, TRAINER_STDIO_CAPTURE_BYTES);
    Ok(TrainerProcessOutput {
        stdout: captured.stdout,
        stderr: captured.stderr,
        stdout_truncated: captured.stdout_truncated,
        stderr_truncated: captured.stderr_truncated,
        status_success: output.status.success(),
    })
}

fn write_captured_output(
    plan: &TrainingPlan,
    output: &TrainerProcessOutput,
) -> Result<(), TrainerError> {
    let stdout_path = plan.run_dir.join("trainer-stdout.log");
    let stderr_path = plan.run_dir.join("trainer-stderr.log");
    atomic_write(&stdout_path, &output.stdout)
        .map_err(|source| TrainerError::io(&stdout_path, source))?;
    atomic_write(&stderr_path, &output.stderr)
        .map_err(|source| TrainerError::io(&stderr_path, source))?;
    if output.stdout_truncated || output.stderr_truncated {
        let marker_path = plan.run_dir.join("trainer-output.truncated");
        atomic_write(&marker_path, b"trainer output exceeded capture cap\n")
            .map_err(|source| TrainerError::io(marker_path, source))?;
    }
    Ok(())
}

fn materialize_manifest(
    plan: &TrainingPlan,
    backend: &str,
    weights_format: AdapterWeightsFormat,
) -> Result<TrainingOutcome, TrainerError> {
    let weights_path = match weights_format {
        AdapterWeightsFormat::SafetensorsLora => plan.run_dir.join("adapter.safetensors"),
        AdapterWeightsFormat::GgufLora => plan.run_dir.join("adapter.gguf"),
    };
    if !weights_path.exists() {
        return Err(TrainerError::Backend(format!(
            "trainer did not produce expected weights file {}",
            weights_path.display()
        )));
    }
    let weights_size_bytes = std::fs::metadata(&weights_path)
        .map_err(|source| TrainerError::io(&weights_path, source))?
        .len();
    let progress = vec![TrainerProgress {
        run_id: plan.run_id.clone(),
        phase: "training".into(),
        step: plan.total_steps,
        total_steps: plan.total_steps,
        elapsed_seconds: 1,
        peak_resident_mb: plan.estimated_peak_resident_mb,
        last_loss: None,
    }];
    let manifest = AdapterManifest {
        schema_version: allbert_proto::ADAPTER_MANIFEST_SCHEMA_VERSION,
        adapter_id: format!("{}-{}", backend, plan.run_id),
        provenance: AdapterProvenance::SelfTrained,
        trainer_backend: backend.into(),
        base_model: plan.base_model.clone(),
        training_run_id: plan.run_id.clone(),
        corpus_digest: plan.corpus.corpus_digest.clone(),
        weights_format,
        weights_size_bytes,
        hyperparameters: plan.hyperparameters.clone(),
        resource_cost: AdapterResourceCost {
            compute_wall_seconds: 1,
            peak_resident_mb: plan.estimated_peak_resident_mb,
            usd: 0.0,
        },
        eval_summary: AdapterEvalSummary {
            golden_pass_rate: 0.0,
            loss_final: 0.0,
            loss_curve_path: "loss-curve.txt".into(),
            behavioral_diff_path: "behavioral-diff.md".into(),
            behavioral_samples: 0,
        },
        overall: AdapterOverallStatus::NeedsAttention,
        created_at: Utc::now(),
        accepted_at: None,
    };
    write_adapter_manifest(&plan.run_dir.join(MANIFEST_FILE), &manifest)
        .map_err(|err| TrainerError::Backend(err.to_string()))?;
    Ok(TrainingOutcome {
        manifest,
        run_dir: plan.run_dir.clone(),
        weights_path,
        loss_curve_path: plan.run_dir.join("loss-curve.txt"),
        eval_summary_path: plan.run_dir.join("eval-summary.json"),
        progress,
    })
}

pub fn parse_mlx_progress_line(
    run_id: &str,
    total_steps: u32,
    line: &str,
) -> Option<TrainerProgress> {
    let value = serde_json::from_str::<serde_json::Value>(line).ok()?;
    let step = value.get("iteration")?.as_u64()?.try_into().ok()?;
    let loss = value.get("train_loss").and_then(|value| value.as_f64());
    Some(TrainerProgress {
        run_id: run_id.into(),
        phase: "training".into(),
        step,
        total_steps,
        elapsed_seconds: step.into(),
        peak_resident_mb: 0,
        last_loss: loss,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::trainer::minimal_trainer_env;
    use crate::adapters::trainer_fake::tests_support::test_training_plan;
    use crate::Config;

    #[test]
    fn mlx_command_uses_argument_vector_without_operator_injection() {
        let temp = tempfile::tempdir().expect("tempdir");
        let plan = test_training_plan(temp.path(), "run-mlx", Some(60));
        let config = Config::default_template();
        let command = MlxLoraTrainer::new(plan_paths(temp.path()), config).command_for_plan(&plan);
        assert_eq!(command.program, "python3");
        assert!(command.args.contains(&"mlx_lm.lora".into()));
        assert!(command.args.iter().all(|arg| !arg.contains(';')));
    }

    #[test]
    fn trainer_environment_is_minimal() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = plan_paths(temp.path());
        let keys = minimal_trainer_env(&paths)
            .into_iter()
            .map(|(key, _)| key)
            .collect::<Vec<_>>();
        assert_eq!(keys, vec!["PATH", "HOME", "TMPDIR", "ALLBERT_HOME"]);
    }

    #[test]
    fn mlx_progress_parses_json_lines() {
        let progress = parse_mlx_progress_line("run", 10, r#"{"iteration":3,"train_loss":0.42}"#)
            .expect("progress");
        assert_eq!(progress.step, 3);
        assert_eq!(progress.last_loss, Some(0.42));
    }

    fn plan_paths(root: &std::path::Path) -> AllbertPaths {
        let paths = AllbertPaths::under(root.join(".allbert"));
        paths.ensure().expect("paths");
        paths
    }
}
