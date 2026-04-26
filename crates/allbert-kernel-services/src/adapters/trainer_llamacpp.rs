use std::process::{Command, Stdio};

use allbert_proto::{
    AdapterEvalSummary, AdapterManifest, AdapterOverallStatus, AdapterProvenance,
    AdapterResourceCost, AdapterWeightsFormat,
};
use chrono::Utc;
use regex::Regex;

use crate::adapters::manifest::{write_adapter_manifest, MANIFEST_FILE};
use crate::adapters::trainer::{
    capture_trainer_output, ensure_trainer_allowed, minimal_trainer_env, AdapterTrainer,
    CancellationToken, TrainerCommand, TrainerError, TrainerHooks, TrainerProgress,
    TrainingOutcome, TrainingPlan,
};
use crate::{atomic_write, AllbertPaths, Config};

#[derive(Clone)]
pub struct LlamaCppLoraTrainer {
    paths: AllbertPaths,
    config: Config,
    program: String,
}

impl LlamaCppLoraTrainer {
    pub fn new(paths: AllbertPaths, config: Config) -> Self {
        Self {
            paths,
            config,
            program: "llama-cpp-finetune".into(),
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
                "--model-base".into(),
                plan.base_model.model_id.clone(),
                "--train-data".into(),
                plan.run_dir
                    .join("corpus-snapshot.json")
                    .to_string_lossy()
                    .into_owned(),
                "--lora-out".into(),
                plan.run_dir
                    .join("adapter.gguf")
                    .to_string_lossy()
                    .into_owned(),
                "--rank".into(),
                plan.hyperparameters.rank.to_string(),
                "--alpha".into(),
                plan.hyperparameters.alpha.to_string(),
                "--batch".into(),
                plan.hyperparameters.batch_size.to_string(),
                "--iters".into(),
                plan.hyperparameters.max_steps.to_string(),
                "--lr".into(),
                plan.hyperparameters.learning_rate.to_string(),
                "--seed".into(),
                plan.hyperparameters.seed.to_string(),
            ],
        }
    }
}

impl AdapterTrainer for LlamaCppLoraTrainer {
    fn backend_id(&self) -> &'static str {
        "llama-cpp-finetune"
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
        let output = run_command(&self.paths, &command, plan.max_log_bytes)?;
        write_captured_output(plan, &output)?;
        if output.status_success {
            materialize_manifest(plan, self.backend_id())
        } else {
            Err(TrainerError::Backend(format!(
                "llama.cpp trainer exited unsuccessfully; see {}",
                plan.run_dir.display()
            )))
        }
    }
}

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
    max_log_bytes: usize,
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
    let captured = capture_trainer_output(&output.stdout, &output.stderr, max_log_bytes);
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
) -> Result<TrainingOutcome, TrainerError> {
    let weights_path = plan.run_dir.join("adapter.gguf");
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
        weights_format: AdapterWeightsFormat::GgufLora,
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

pub fn parse_llama_cpp_progress_line(
    run_id: &str,
    total_steps: u32,
    line: &str,
) -> Option<TrainerProgress> {
    let pattern = Regex::new(r"iter(?:ation)?\s+(\d+).*(?:loss|train_loss)\s*[:=]\s*([0-9.]+)")
        .expect("progress regex should compile");
    let captures = pattern.captures(line)?;
    let step = captures.get(1)?.as_str().parse().ok()?;
    let loss = captures.get(2)?.as_str().parse().ok();
    Some(TrainerProgress {
        run_id: run_id.into(),
        phase: "training".into(),
        step,
        total_steps,
        elapsed_seconds: u64::from(step),
        peak_resident_mb: 0,
        last_loss: loss,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::trainer_fake::tests_support::test_training_plan;
    use crate::Config;

    #[test]
    fn llama_cpp_command_uses_argument_vector_without_operator_injection() {
        let temp = tempfile::tempdir().expect("tempdir");
        let plan = test_training_plan(temp.path(), "run-llama", Some(60));
        let paths = plan_paths(temp.path());
        let command =
            LlamaCppLoraTrainer::new(paths, Config::default_template()).command_for_plan(&plan);
        assert_eq!(command.program, "llama-cpp-finetune");
        assert!(command.args.contains(&"--model-base".into()));
        assert!(command.args.iter().all(|arg| !arg.contains(';')));
    }

    #[test]
    fn llama_cpp_progress_parses_stderr_lines() {
        let progress = parse_llama_cpp_progress_line("run", 20, "iteration 7 train_loss=0.333")
            .expect("progress");
        assert_eq!(progress.step, 7);
        assert_eq!(progress.last_loss, Some(0.333));
    }

    fn plan_paths(root: &std::path::Path) -> AllbertPaths {
        let paths = AllbertPaths::under(root.join(".allbert"));
        paths.ensure().expect("paths");
        paths
    }
}
