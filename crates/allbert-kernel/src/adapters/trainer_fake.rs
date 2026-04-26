use std::fs;
use std::path::Path;
use std::time::Duration;

use allbert_proto::{
    AdapterEvalSummary, AdapterManifest, AdapterOverallStatus, AdapterProvenance,
    AdapterResourceCost, AdapterWeightsFormat,
};
use chrono::{DateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::adapters::manifest::{write_adapter_manifest, MANIFEST_FILE};
use crate::adapters::trainer::{
    AdapterTrainer, CancellationToken, TrainerError, TrainerHooks, TrainerProgress,
    TrainingOutcome, TrainingPlan,
};
use crate::atomic_write;

#[derive(Debug, Clone)]
pub struct FakeAdapterTrainer {
    checkpoint_delay: Duration,
}

impl FakeAdapterTrainer {
    pub fn new() -> Self {
        Self {
            checkpoint_delay: Duration::ZERO,
        }
    }

    pub fn with_checkpoint_delay(checkpoint_delay: Duration) -> Self {
        Self { checkpoint_delay }
    }
}

impl Default for FakeAdapterTrainer {
    fn default() -> Self {
        Self::new()
    }
}

impl AdapterTrainer for FakeAdapterTrainer {
    fn backend_id(&self) -> &'static str {
        "fake"
    }

    fn train(
        &self,
        plan: &TrainingPlan,
        hooks: &TrainerHooks,
        cancel: &CancellationToken,
    ) -> Result<TrainingOutcome, TrainerError> {
        hooks.check_dispatch(plan)?;
        validate_plan(plan)?;
        fs::create_dir_all(&plan.run_dir)
            .map_err(|source| TrainerError::io(&plan.run_dir, source))?;
        write_json(&plan.run_dir.join("corpus-snapshot.json"), &plan.corpus)?;

        let mut progress = Vec::new();
        for step in 1..=plan.total_steps {
            if cancel.is_cancelled() {
                write_cancelled_at(&plan.run_dir, plan)?;
                return Err(TrainerError::Cancelled {
                    run_id: plan.run_id.clone(),
                });
            }
            if !self.checkpoint_delay.is_zero() {
                std::thread::sleep(self.checkpoint_delay);
            }
            let progress_entry = fake_progress(plan, step);
            hooks
                .record_progress(plan, &progress_entry)
                .inspect_err(|err| {
                    let _ = write_failed_at(&plan.run_dir, plan, err);
                })?;
            progress.push(progress_entry);
        }

        if cancel.is_cancelled() {
            write_cancelled_at(&plan.run_dir, plan)?;
            return Err(TrainerError::Cancelled {
                run_id: plan.run_id.clone(),
            });
        }

        let weights_path = plan.run_dir.join("adapter.safetensors");
        let weights = fake_weights(&plan.corpus.corpus_digest);
        atomic_write(&weights_path, &weights)
            .map_err(|source| TrainerError::io(&weights_path, source))?;

        let loss_curve_path = plan.run_dir.join("loss-curve.json");
        let loss_curve = fake_loss_curve(&plan.corpus.corpus_digest, plan.total_steps);
        write_json(&loss_curve_path, &loss_curve)?;

        let eval_summary_path = plan.run_dir.join("eval-summary.json");
        let eval_summary = fake_eval_summary(&plan.corpus.corpus_digest);
        write_json(&eval_summary_path, &eval_summary)?;

        let manifest = AdapterManifest {
            schema_version: allbert_proto::ADAPTER_MANIFEST_SCHEMA_VERSION,
            adapter_id: fake_adapter_id(&plan.corpus.corpus_digest),
            provenance: AdapterProvenance::SelfTrained,
            trainer_backend: plan.trainer_backend.clone(),
            base_model: plan.base_model.clone(),
            training_run_id: plan.run_id.clone(),
            corpus_digest: plan.corpus.corpus_digest.clone(),
            weights_format: AdapterWeightsFormat::SafetensorsLora,
            weights_size_bytes: weights.len() as u64,
            hyperparameters: plan.hyperparameters.clone(),
            resource_cost: AdapterResourceCost {
                compute_wall_seconds: progress
                    .last()
                    .map(|entry| entry.elapsed_seconds)
                    .unwrap_or_default(),
                peak_resident_mb: plan.estimated_peak_resident_mb,
                usd: 0.0,
            },
            eval_summary,
            overall: AdapterOverallStatus::ReadyForReview,
            created_at: fake_created_at(&plan.corpus.corpus_digest),
            accepted_at: None,
        };
        write_adapter_manifest(&plan.run_dir.join(MANIFEST_FILE), &manifest)
            .map_err(|err| TrainerError::Backend(err.to_string()))?;
        atomic_write(&plan.run_dir.join("completed_at"), b"fake-complete\n")
            .map_err(|source| TrainerError::io(plan.run_dir.join("completed_at"), source))?;

        Ok(TrainingOutcome {
            manifest,
            run_dir: plan.run_dir.clone(),
            weights_path,
            loss_curve_path,
            eval_summary_path,
            progress,
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct LossPoint {
    step: u32,
    loss: f64,
}

fn validate_plan(plan: &TrainingPlan) -> Result<(), TrainerError> {
    if plan.run_id.trim().is_empty() {
        return Err(TrainerError::InvalidPlan("run_id must not be empty".into()));
    }
    if plan.trainer_backend != "fake" {
        return Err(TrainerError::InvalidPlan(format!(
            "fake trainer received backend {}",
            plan.trainer_backend
        )));
    }
    if plan.total_steps == 0 {
        return Err(TrainerError::InvalidPlan(
            "total_steps must be greater than zero".into(),
        ));
    }
    Ok(())
}

fn fake_progress(plan: &TrainingPlan, step: u32) -> TrainerProgress {
    let total = plan.total_steps.max(1);
    let loss = 1.0 - (step as f64 / total as f64) * 0.75;
    TrainerProgress {
        run_id: plan.run_id.clone(),
        phase: "training".into(),
        step,
        total_steps: plan.total_steps,
        elapsed_seconds: step as u64,
        peak_resident_mb: plan.estimated_peak_resident_mb,
        last_loss: Some(round4(loss)),
    }
}

fn fake_weights(corpus_digest: &str) -> Vec<u8> {
    let digest = Sha256::digest(format!("allbert-fake-adapter:{corpus_digest}").as_bytes());
    let mut bytes = b"ALLBERT_FAKE_SAFETENSORS\n".to_vec();
    bytes.extend_from_slice(format!("{digest:x}\n").as_bytes());
    bytes
}

fn fake_loss_curve(corpus_digest: &str, total_steps: u32) -> Vec<LossPoint> {
    let seed = stable_seed(corpus_digest) as f64 / u64::MAX as f64;
    (1..=total_steps)
        .map(|step| LossPoint {
            step,
            loss: round4(1.0 - (step as f64 / total_steps as f64) * (0.55 + seed * 0.2)),
        })
        .collect()
}

fn fake_eval_summary(corpus_digest: &str) -> AdapterEvalSummary {
    let seed = stable_seed(corpus_digest);
    let pass_rate = 0.82 + ((seed % 16) as f64 / 100.0);
    AdapterEvalSummary {
        golden_pass_rate: round4(pass_rate.min(1.0)),
        loss_final: fake_loss_curve(corpus_digest, 4)
            .last()
            .map(|point| point.loss)
            .unwrap_or(0.2),
        loss_curve_path: "loss-curve.json".into(),
        behavioral_diff_path: "behavioral-diff.md".into(),
        behavioral_samples: 0,
    }
}

fn fake_adapter_id(corpus_digest: &str) -> String {
    format!("fake-{}", hex_prefix(corpus_digest, 12))
}

fn fake_created_at(corpus_digest: &str) -> DateTime<Utc> {
    let seed = stable_seed(corpus_digest);
    let seconds = (seed % 31_536_000) as i64;
    Utc.timestamp_opt(seconds, 0)
        .single()
        .expect("seed-derived timestamp should be valid")
}

fn stable_seed(corpus_digest: &str) -> u64 {
    let digest = Sha256::digest(corpus_digest.as_bytes());
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&digest[..8]);
    u64::from_be_bytes(bytes)
}

fn hex_prefix(corpus_digest: &str, length: usize) -> String {
    let digest = Sha256::digest(corpus_digest.as_bytes());
    format!("{digest:x}").chars().take(length).collect()
}

fn round4(value: f64) -> f64 {
    (value * 10_000.0).round() / 10_000.0
}

fn write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), TrainerError> {
    let bytes = serde_json::to_vec_pretty(value).map_err(|source| {
        TrainerError::Backend(format!("serialize {}: {source}", path.display()))
    })?;
    atomic_write(path, &bytes).map_err(|source| TrainerError::io(path, source))
}

fn write_cancelled_at(run_dir: &Path, plan: &TrainingPlan) -> Result<(), TrainerError> {
    let path = run_dir.join("cancelled_at");
    atomic_write(&path, format!("{}\n", plan.run_id).as_bytes())
        .map_err(|source| TrainerError::io(path, source))
}

fn write_failed_at(
    run_dir: &Path,
    plan: &TrainingPlan,
    err: &TrainerError,
) -> Result<(), TrainerError> {
    let path = run_dir.join("failed_at");
    atomic_write(&path, format!("{}\n{}\n", plan.run_id, err).as_bytes())
        .map_err(|source| TrainerError::io(path, source))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adapters::{build_adapter_corpus, AdapterCorpusConfig};
    use allbert_proto::{AdapterHyperparameters, BaseModelRef, ProviderKind};
    use std::sync::{Arc, Mutex};

    fn test_plan(root: &Path, run_id: &str, compute_cap: Option<u64>) -> TrainingPlan {
        let paths = crate::AllbertPaths::under(root.join(".allbert"));
        paths.ensure().expect("paths");
        crate::atomic_write(&paths.soul, b"# SOUL\n\nWarm and concrete.\n").expect("soul");
        crate::atomic_write(&paths.personality, b"# PERSONALITY\n\nBrief updates.\n")
            .expect("personality");
        let corpus = build_adapter_corpus(&paths, &AdapterCorpusConfig::default()).expect("corpus");
        TrainingPlan {
            run_id: run_id.into(),
            run_dir: paths.adapters_runs.join(run_id),
            trainer_backend: "fake".into(),
            base_model: BaseModelRef {
                provider: ProviderKind::Ollama,
                model_id: "llama3.2".into(),
                model_digest: "sha256:base".into(),
            },
            corpus,
            hyperparameters: AdapterHyperparameters {
                rank: 8,
                alpha: 16,
                learning_rate: 0.0002,
                max_steps: 4,
                batch_size: 1,
                seed: 11,
            },
            compute_used_today_seconds: 0,
            compute_cap_wall_seconds: compute_cap,
            total_steps: 4,
            estimated_peak_resident_mb: 256,
        }
    }

    #[test]
    fn fake_trainer_produces_complete_run_directory_tree() {
        let temp = tempfile::tempdir().expect("tempdir");
        let plan = test_plan(temp.path(), "run-complete", Some(60));
        let progress = Arc::new(Mutex::new(Vec::new()));
        let hooks = TrainerHooks::with_progress_callback({
            let progress = Arc::clone(&progress);
            Arc::new(move |entry| {
                progress.lock().expect("progress").push(entry.clone());
                Ok(())
            })
        });

        let outcome = FakeAdapterTrainer::new()
            .train(&plan, &hooks, &CancellationToken::new())
            .expect("train");

        assert_eq!(
            outcome.manifest.adapter_id,
            fake_adapter_id(&plan.corpus.corpus_digest)
        );
        assert!(outcome.weights_path.exists());
        assert!(outcome.loss_curve_path.exists());
        assert!(outcome.eval_summary_path.exists());
        assert!(plan.run_dir.join("corpus-snapshot.json").exists());
        assert!(plan.run_dir.join(MANIFEST_FILE).exists());
        assert_eq!(progress.lock().expect("progress").len(), 4);
    }

    #[test]
    fn cancellation_token_aborts_fake_run_and_writes_marker() {
        let temp = tempfile::tempdir().expect("tempdir");
        let plan = test_plan(temp.path(), "run-cancel", Some(60));
        let token = CancellationToken::new();
        token.cancel();

        let err = FakeAdapterTrainer::new()
            .train(&plan, &TrainerHooks::new(), &token)
            .expect_err("cancelled");
        assert!(matches!(err, TrainerError::Cancelled { .. }));
        assert!(plan.run_dir.join("cancelled_at").exists());
        assert!(!plan.run_dir.join(MANIFEST_FILE).exists());
    }

    #[test]
    fn compute_cap_refuses_at_dispatch_and_checkpoint() {
        let temp = tempfile::tempdir().expect("tempdir");
        let mut dispatch_plan = test_plan(temp.path(), "run-dispatch", Some(0));
        dispatch_plan.compute_used_today_seconds = 0;
        let dispatch_err = FakeAdapterTrainer::new()
            .train(
                &dispatch_plan,
                &TrainerHooks::new(),
                &CancellationToken::new(),
            )
            .expect_err("dispatch cap");
        assert!(matches!(
            dispatch_err,
            TrainerError::ComputeCapExceeded { .. }
        ));

        let checkpoint_plan = test_plan(temp.path(), "run-checkpoint", Some(2));
        let checkpoint_err = FakeAdapterTrainer::new()
            .train(
                &checkpoint_plan,
                &TrainerHooks::new(),
                &CancellationToken::new(),
            )
            .expect_err("checkpoint cap");
        assert!(matches!(
            checkpoint_err,
            TrainerError::ComputeCapExceeded { .. }
        ));
        assert!(checkpoint_plan.run_dir.join("failed_at").exists());
    }

    #[test]
    fn same_corpus_digest_produces_identical_fake_artifacts() {
        let temp = tempfile::tempdir().expect("tempdir");
        let first = test_plan(temp.path(), "run-one", Some(60));
        let mut second = first.clone();
        second.run_id = "run-two".into();
        second.run_dir = first.run_dir.parent().expect("runs parent").join("run-two");

        let first_outcome = FakeAdapterTrainer::new()
            .train(&first, &TrainerHooks::new(), &CancellationToken::new())
            .expect("first");
        let second_outcome = FakeAdapterTrainer::new()
            .train(&second, &TrainerHooks::new(), &CancellationToken::new())
            .expect("second");

        let first_weights = fs::read(first_outcome.weights_path).expect("first weights");
        let second_weights = fs::read(second_outcome.weights_path).expect("second weights");
        assert_eq!(first_weights, second_weights);

        let first_eval = fs::read(first_outcome.eval_summary_path).expect("first eval");
        let second_eval = fs::read(second_outcome.eval_summary_path).expect("second eval");
        assert_eq!(first_eval, second_eval);
        assert_eq!(
            first_outcome.manifest.adapter_id,
            second_outcome.manifest.adapter_id
        );
    }
}
