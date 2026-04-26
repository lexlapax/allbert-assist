use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use allbert_proto::{
    ActivityPhase, AdapterHyperparameters, AdapterManifest, AdapterOverallStatus, AttributeValue,
    BaseModelRef, ProviderKind, SpanKind,
};
use chrono::{Duration as ChronoDuration, Utc};
use serde_json::json;

use crate::adapters::corpus::{build_adapter_corpus, AdapterCorpusConfig, AdapterCorpusSnapshot};
use crate::adapters::eval::run_fixed_evals;
use crate::adapters::manifest::{write_adapter_manifest, MANIFEST_FILE};
use crate::adapters::trainer::{AdapterTrainer, CancellationToken, TrainerHooks, TrainingPlan};
use crate::adapters::trainer_fake::FakeAdapterTrainer;
use crate::events::{ActivityTransition, KernelEvent};
use crate::learning::{
    LearningCorpus, LearningCorpusItem, LearningCorpusSummary, LearningJob, LearningJobContext,
    LearningJobReport, LearningOutputArtifact,
};
use crate::replay::{new_trace_id, ActiveTraceSpan};
use crate::{
    atomic_write, Config, JsonlTraceWriter, KernelError, Provider, TraceCapturePolicy,
    TraceStorageLimits, TracingHooks,
};

pub const PERSONALITY_ADAPTER_JOB_NAME: &str = "personality-adapter";
pub const PERSONALITY_ADAPTER_SESSION_ID: &str = "learning-adapter";
pub const DEFAULT_ADAPTER_COMPUTE_CAP_WALL_SECONDS: u64 = 7_200;
pub const DEFAULT_MIN_GOLDEN_PASS_RATE: f64 = 0.85;

#[derive(Clone)]
pub struct PersonalityAdapterJob {
    trainer: Arc<dyn AdapterTrainer>,
    trace_hooks: Option<Arc<dyn TracingHooks>>,
    on_event: Option<Arc<dyn Fn(KernelEvent) + Send + Sync>>,
}

impl PersonalityAdapterJob {
    pub fn fake() -> Self {
        Self {
            trainer: Arc::new(FakeAdapterTrainer::new()),
            trace_hooks: None,
            on_event: None,
        }
    }

    pub fn with_trainer(trainer: Arc<dyn AdapterTrainer>) -> Self {
        Self {
            trainer,
            trace_hooks: None,
            on_event: None,
        }
    }

    pub fn with_trace_hooks(mut self, trace_hooks: Arc<dyn TracingHooks>) -> Self {
        self.trace_hooks = Some(trace_hooks);
        self
    }

    pub fn with_event_sink(mut self, on_event: Arc<dyn Fn(KernelEvent) + Send + Sync>) -> Self {
        self.on_event = Some(on_event);
        self
    }

    pub fn run_with_session(
        &self,
        ctx: &LearningJobContext<'_>,
        session_id: &str,
    ) -> Result<LearningJobReport, KernelError> {
        run_personality_adapter_job(self, ctx, session_id)
    }
}

impl Default for PersonalityAdapterJob {
    fn default() -> Self {
        Self::fake()
    }
}

impl LearningJob for PersonalityAdapterJob {
    fn name(&self) -> &'static str {
        PERSONALITY_ADAPTER_JOB_NAME
    }

    fn describe_corpus(&self, ctx: &LearningJobContext<'_>) -> Result<LearningCorpus, KernelError> {
        let config = adapter_corpus_config(ctx.config);
        let snapshot = build_adapter_corpus(ctx.paths, &config)?;
        Ok(corpus_summary_for_snapshot(ctx, &snapshot, &config))
    }

    fn run(&self, ctx: &LearningJobContext<'_>) -> Result<LearningJobReport, KernelError> {
        self.run_with_session(ctx, PERSONALITY_ADAPTER_SESSION_ID)
    }
}

pub fn preview_personality_adapter_training(
    paths: &crate::AllbertPaths,
    config: &Config,
) -> Result<LearningCorpus, KernelError> {
    let job = PersonalityAdapterJob::fake();
    let ctx = LearningJobContext {
        paths,
        config,
        accept_output: false,
        consent_hosted_provider: false,
    };
    job.describe_corpus(&ctx)
}

pub fn run_personality_adapter_training(
    paths: &crate::AllbertPaths,
    config: &Config,
) -> Result<LearningJobReport, KernelError> {
    run_personality_adapter_training_with_session(paths, config, PERSONALITY_ADAPTER_SESSION_ID)
}

pub fn run_personality_adapter_training_with_session(
    paths: &crate::AllbertPaths,
    config: &Config,
    session_id: &str,
) -> Result<LearningJobReport, KernelError> {
    let job = PersonalityAdapterJob::fake();
    let ctx = LearningJobContext {
        paths,
        config,
        accept_output: false,
        consent_hosted_provider: false,
    };
    job.run_with_session(&ctx, session_id)
}

fn run_personality_adapter_job(
    job: &PersonalityAdapterJob,
    ctx: &LearningJobContext<'_>,
    session_id: &str,
) -> Result<LearningJobReport, KernelError> {
    ctx.paths.ensure()?;
    let trace_hooks = match job.trace_hooks.clone() {
        Some(hooks) => Some(hooks),
        None => build_trace_hooks(ctx.paths, ctx.config, session_id).transpose()?,
    };
    emit_training_activity(job, None);

    let trace_id = new_trace_id();
    let mut root = ActiveTraceSpan::new(
        trace_hooks.clone(),
        session_id,
        &trace_id,
        None,
        "run_training",
        SpanKind::Internal,
    );
    root.set_attribute(
        "gen_ai.operation.name",
        AttributeValue::String("train".into()),
    );

    let corpus_config = adapter_corpus_config(ctx.config);
    let mut corpus_span = ActiveTraceSpan::new(
        trace_hooks.clone(),
        session_id,
        &trace_id,
        Some(root.id().to_string()),
        "corpus_assembly",
        SpanKind::Internal,
    );
    let corpus = match build_adapter_corpus(ctx.paths, &corpus_config) {
        Ok(corpus) => {
            corpus_span.set_attribute(
                "allbert.adapter.corpus_digest",
                AttributeValue::String(corpus.corpus_digest.clone()),
            );
            corpus_span.finish_ok();
            corpus
        }
        Err(err) => {
            corpus_span.finish_error(err.to_string());
            root.finish_error(err.to_string());
            return Err(err);
        }
    };

    let run_id = new_training_run_id();
    root.set_attribute(
        "allbert.adapter.run_id",
        AttributeValue::String(run_id.clone()),
    );
    let run_dir = ctx.paths.adapters_runs.join(&run_id);
    let plan = training_plan(
        ctx,
        &run_id,
        &run_dir,
        corpus.clone(),
        job.trainer.backend_id(),
    );

    let mut trainer_span = ActiveTraceSpan::new(
        trace_hooks.clone(),
        session_id,
        &trace_id,
        Some(root.id().to_string()),
        "trainer_invocation",
        SpanKind::Internal,
    );
    trainer_span.set_attribute(
        "allbert.adapter.trainer_backend",
        AttributeValue::String(job.trainer.backend_id().into()),
    );
    let hooks = TrainerHooks::with_progress_callback(Arc::new({
        let on_event = job.on_event.clone();
        let session_id = session_id.to_string();
        move |progress| {
            if let Some(on_event) = &on_event {
                on_event(KernelEvent::Activity(ActivityTransition {
                    phase: ActivityPhase::Training,
                    label: format!(
                        "adapter training step {}/{}",
                        progress.step, progress.total_steps
                    ),
                    tool_name: None,
                    tool_summary: None,
                    skill_name: None,
                    approval_id: None,
                    next_actions: vec![format!("session {session_id} is training an adapter")],
                }));
            }
            Ok(())
        }
    }));
    let outcome = match job.trainer.train(&plan, &hooks, &CancellationToken::new()) {
        Ok(outcome) => {
            trainer_span.finish_ok();
            outcome
        }
        Err(err) => {
            trainer_span.finish_error(err.to_string());
            root.finish_error(err.to_string());
            return Err(KernelError::Request(err.to_string()));
        }
    };

    let mut eval_span = ActiveTraceSpan::new(
        trace_hooks,
        session_id,
        &trace_id,
        Some(root.id().to_string()),
        "eval_run",
        SpanKind::Internal,
    );
    let eval = match run_fixed_evals(
        &ctx.paths.adapters_evals,
        &run_dir,
        &corpus,
        &outcome.progress,
    ) {
        Ok(eval) => {
            eval_span.set_attribute(
                "allbert.adapter.golden_pass_rate",
                AttributeValue::Float(eval.summary.golden_pass_rate),
            );
            eval_span.finish_ok();
            eval
        }
        Err(err) => {
            eval_span.finish_error(err.to_string());
            root.finish_error(err.to_string());
            return Err(err);
        }
    };

    let mut manifest = outcome.manifest.clone();
    manifest.eval_summary = eval.summary.clone();
    manifest.overall = if eval.summary.golden_pass_rate >= min_golden_pass_rate(ctx.config) {
        AdapterOverallStatus::ReadyForReview
    } else {
        AdapterOverallStatus::NeedsAttention
    };
    write_adapter_manifest(&run_dir.join(MANIFEST_FILE), &manifest)?;
    let approval_id = write_adapter_approval(ctx.paths, session_id, &manifest, &run_dir)?;
    let approval_path = approval_path_for(ctx.paths, session_id, &approval_id);
    let report = learning_report(
        &run_id,
        &approval_id,
        &approval_path,
        &manifest,
        &run_dir,
        &outcome,
        &corpus,
    )?;
    atomic_write(
        &run_dir.join("report.json"),
        &serde_json::to_vec_pretty(&report)
            .map_err(|err| KernelError::InitFailed(format!("serialize report: {err}")))?,
    )
    .map_err(|err| KernelError::InitFailed(format!("write report: {err}")))?;

    root.finish_ok();
    emit_training_activity(job, Some(&approval_id));
    Ok(report)
}

fn build_trace_hooks(
    paths: &crate::AllbertPaths,
    config: &Config,
    session_id: &str,
) -> Option<Result<Arc<dyn TracingHooks>, KernelError>> {
    if !config.trace.enabled {
        return None;
    }
    Some(
        JsonlTraceWriter::with_policy(
            paths,
            session_id,
            TraceStorageLimits::from_session_cap_mb(config.trace.session_disk_cap_mb.into()),
            TraceCapturePolicy::from(config.trace.clone()),
        )
        .map(|writer| Arc::new(writer) as Arc<dyn TracingHooks>)
        .map_err(|err| KernelError::Trace(err.to_string())),
    )
}

fn training_plan(
    ctx: &LearningJobContext<'_>,
    run_id: &str,
    run_dir: &Path,
    corpus: AdapterCorpusSnapshot,
    trainer_backend: &str,
) -> TrainingPlan {
    TrainingPlan {
        run_id: run_id.into(),
        run_dir: run_dir.to_path_buf(),
        trainer_backend: trainer_backend.into(),
        base_model: BaseModelRef {
            provider: provider_kind(ctx.config.model.provider),
            model_id: ctx.config.model.model_id.clone(),
            model_digest: "unknown".into(),
        },
        corpus,
        hyperparameters: AdapterHyperparameters {
            rank: ctx.config.learning.adapter_training.default_lora_rank,
            alpha: ctx.config.learning.adapter_training.default_alpha,
            learning_rate: ctx
                .config
                .learning
                .adapter_training
                .default_learning_rate
                .parse()
                .unwrap_or(0.0001),
            max_steps: ctx.config.learning.adapter_training.default_max_steps,
            batch_size: ctx.config.learning.adapter_training.default_batch_size,
            seed: ctx.config.learning.adapter_training.default_seed,
        },
        compute_used_today_seconds: 0,
        compute_cap_wall_seconds: ctx.config.learning.compute_cap_wall_seconds,
        total_steps: ctx.config.learning.adapter_training.default_max_steps,
        estimated_peak_resident_mb: 256,
        max_log_bytes: ctx.config.learning.adapter_training.max_log_bytes,
        cancel_grace_seconds: ctx.config.learning.adapter_training.cancel_grace_seconds,
    }
}

fn learning_report(
    run_id: &str,
    approval_id: &str,
    approval_path: &Path,
    manifest: &AdapterManifest,
    run_dir: &Path,
    outcome: &crate::TrainingOutcome,
    corpus: &AdapterCorpusSnapshot,
) -> Result<LearningJobReport, KernelError> {
    Ok(LearningJobReport {
        job_name: PERSONALITY_ADAPTER_JOB_NAME.into(),
        inputs: json!({
            "corpus_digest": corpus.corpus_digest,
            "corpus_item_count": corpus.items.len(),
            "corpus_bytes": corpus.total_bytes,
            "base_model": manifest.base_model,
        }),
        execution: json!({
            "run_id": run_id,
            "trainer_backend": manifest.trainer_backend,
            "adapter_id": manifest.adapter_id,
            "approval_id": approval_id,
            "overall": manifest.overall,
        }),
        resource_cost: json!({
            "usd": manifest.resource_cost.usd,
            "compute_wall_seconds": manifest.resource_cost.compute_wall_seconds,
            "peak_resident_mb": manifest.resource_cost.peak_resident_mb,
        }),
        output_artifacts: vec![
            artifact(run_dir.join(MANIFEST_FILE), "adapter_manifest", false),
            artifact(&outcome.weights_path, "adapter_weights", false),
            artifact(&outcome.loss_curve_path, "loss_curve_json", false),
            artifact(&manifest.eval_summary.loss_curve_path, "loss_curve", false),
            artifact(
                &manifest.eval_summary.behavioral_diff_path,
                "behavioral_diff",
                false,
            ),
            artifact(run_dir.join("eval-summary.json"), "eval_summary", false),
            artifact(approval_path, "adapter_approval", false),
        ],
        staged_candidates: Vec::new(),
    })
}

fn artifact(path: impl AsRef<Path>, kind: &str, installed: bool) -> LearningOutputArtifact {
    LearningOutputArtifact {
        path: path.as_ref().to_string_lossy().into_owned(),
        kind: kind.into(),
        installed,
    }
}

fn write_adapter_approval(
    paths: &crate::AllbertPaths,
    session_id: &str,
    manifest: &AdapterManifest,
    run_dir: &Path,
) -> Result<String, KernelError> {
    let approval_id = format!("approval-{}", uuid::Uuid::new_v4().simple());
    let path = approval_path_for(paths, session_id, &approval_id);
    let now = Utc::now();
    let expires = now + ChronoDuration::days(14);
    let rendered = render_adapter_approval(
        &approval_id,
        session_id,
        &now.to_rfc3339(),
        &expires.to_rfc3339(),
        manifest,
        run_dir,
    );
    atomic_write(&path, rendered.as_bytes()).map_err(|err| {
        KernelError::InitFailed(format!("write adapter approval {}: {err}", path.display()))
    })?;
    Ok(approval_id)
}

fn approval_path_for(paths: &crate::AllbertPaths, session_id: &str, approval_id: &str) -> PathBuf {
    paths
        .sessions
        .join(session_id)
        .join("approvals")
        .join(format!("{approval_id}.md"))
}

fn render_adapter_approval(
    approval_id: &str,
    session_id: &str,
    requested_at: &str,
    expires_at: &str,
    manifest: &AdapterManifest,
    run_dir: &Path,
) -> String {
    format!(
        r#"---
id: {approval_id}
session_id: {session_id}
channel: jobs
sender: local
agent: allbert/learning
tool: personality-adapter
request_id: 0
kind: adapter-approval
requested_at: {requested_at}
expires_at: {expires_at}
status: pending
adapter_id: {adapter_id}
provenance: {provenance}
trainer_backend: {trainer_backend}
base_model:
  provider: {provider}
  model_id: {model_id}
  model_digest: {model_digest}
training_run_id: {training_run_id}
corpus_digest: {corpus_digest}
artifact_root: {artifact_root}
weights_path: {weights_path}
weights_format: {weights_format}
weights_size_bytes: {weights_size_bytes}
hyperparameters:
  rank: {rank}
  alpha: {alpha}
  learning_rate: {learning_rate}
  max_steps: {max_steps}
  batch_size: {batch_size}
  seed: {seed}
resource_cost:
  compute_wall_seconds: {compute_wall_seconds}
  peak_resident_mb: {peak_resident_mb}
  usd: {usd}
eval_summary:
  golden_pass_rate: {golden_pass_rate}
  loss_final: {loss_final}
  loss_curve_path: {loss_curve_path}
  behavioral_diff_path: {behavioral_diff_path}
overall: {overall}
---

# Adapter Approval

Adapter `{adapter_id}` completed training from corpus `{corpus_digest}`.

- Base model: {provider} / {model_id}
- Trainer: {trainer_backend}
- Compute: {compute_wall_seconds}s wall, peak {peak_resident_mb} MB
- Eval: golden {golden_percent}%, final loss {loss_final}

Accepting this approval records review only. Activation remains a separate `adapters activate {adapter_id}` action.
"#,
        adapter_id = manifest.adapter_id,
        provenance = provenance_label(manifest.provenance),
        trainer_backend = manifest.trainer_backend,
        provider = provider_label(manifest.base_model.provider),
        model_id = manifest.base_model.model_id,
        model_digest = manifest.base_model.model_digest,
        training_run_id = manifest.training_run_id,
        corpus_digest = manifest.corpus_digest,
        artifact_root = run_dir.to_string_lossy(),
        weights_path = run_dir.join("adapter.safetensors").to_string_lossy(),
        weights_format = weights_format_label(manifest.weights_format),
        weights_size_bytes = manifest.weights_size_bytes,
        rank = manifest.hyperparameters.rank,
        alpha = manifest.hyperparameters.alpha,
        learning_rate = manifest.hyperparameters.learning_rate,
        max_steps = manifest.hyperparameters.max_steps,
        batch_size = manifest.hyperparameters.batch_size,
        seed = manifest.hyperparameters.seed,
        compute_wall_seconds = manifest.resource_cost.compute_wall_seconds,
        peak_resident_mb = manifest.resource_cost.peak_resident_mb,
        usd = manifest.resource_cost.usd,
        golden_pass_rate = manifest.eval_summary.golden_pass_rate,
        loss_final = manifest.eval_summary.loss_final,
        loss_curve_path = manifest.eval_summary.loss_curve_path,
        behavioral_diff_path = manifest.eval_summary.behavioral_diff_path,
        overall = overall_label(manifest.overall),
        golden_percent = (manifest.eval_summary.golden_pass_rate * 100.0).round(),
    )
}

fn corpus_summary_for_snapshot(
    ctx: &LearningJobContext<'_>,
    snapshot: &AdapterCorpusSnapshot,
    corpus_config: &AdapterCorpusConfig,
) -> LearningCorpus {
    let source_tiers = snapshot
        .items
        .iter()
        .map(|item| item.tier.clone())
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect::<Vec<_>>();
    LearningCorpus {
        summary: LearningCorpusSummary {
            source_tiers,
            item_count: snapshot.items.len(),
            byte_count: snapshot.total_bytes,
            max_input_bytes: corpus_config.max_input_bytes,
            output_path: ctx.paths.adapters_runs.to_string_lossy().into_owned(),
            hosted_provider_required: false,
            hosted_provider_consent: false,
            provider: ctx.config.model.provider.label().into(),
            model: ctx.config.model.model_id.clone(),
        },
        items: snapshot
            .items
            .iter()
            .map(|item| LearningCorpusItem {
                tier: item.tier.clone(),
                source: item.source.clone(),
                bytes: item.bytes,
                text: item.content.clone(),
            })
            .collect(),
    }
}

fn adapter_corpus_config(config: &Config) -> AdapterCorpusConfig {
    AdapterCorpusConfig {
        max_input_bytes: config.learning.adapter_training.max_input_bytes,
        max_episode_summaries: config.learning.adapter_training.max_episode_summaries,
        capture_traces: config.learning.adapter_training.capture_traces,
        include_tiers: config.learning.adapter_training.include_tiers.clone(),
        include_episodes: config.learning.adapter_training.include_episodes,
        ..AdapterCorpusConfig::default()
    }
}

fn min_golden_pass_rate(config: &Config) -> f64 {
    config
        .learning
        .adapter_training
        .min_golden_pass_rate
        .parse()
        .unwrap_or(DEFAULT_MIN_GOLDEN_PASS_RATE)
}

fn emit_training_activity(job: &PersonalityAdapterJob, approval_id: Option<&str>) {
    if let Some(on_event) = &job.on_event {
        on_event(KernelEvent::Activity(ActivityTransition {
            phase: ActivityPhase::Training,
            label: match approval_id {
                Some(id) => format!("adapter training completed; approval {id} is pending"),
                None => "adapter training started".into(),
            },
            tool_name: None,
            tool_summary: None,
            skill_name: None,
            approval_id: approval_id.map(ToOwned::to_owned),
            next_actions: match approval_id {
                Some(id) => vec![format!("review adapter approval {id}")],
                None => Vec::new(),
            },
        }));
    }
}

fn new_training_run_id() -> String {
    format!(
        "{}-personality-adapter",
        Utc::now().format("%Y%m%dT%H%M%SZ")
    )
}

fn provider_kind(provider: Provider) -> ProviderKind {
    provider.to_proto_kind()
}

fn provider_label(provider: ProviderKind) -> &'static str {
    match provider {
        ProviderKind::Anthropic => "anthropic",
        ProviderKind::Openrouter => "openrouter",
        ProviderKind::Openai => "openai",
        ProviderKind::Gemini => "gemini",
        ProviderKind::Ollama => "ollama",
    }
}

fn provenance_label(value: allbert_proto::AdapterProvenance) -> &'static str {
    match value {
        allbert_proto::AdapterProvenance::SelfTrained => "self-trained",
        allbert_proto::AdapterProvenance::External => "external",
    }
}

fn weights_format_label(value: allbert_proto::AdapterWeightsFormat) -> &'static str {
    match value {
        allbert_proto::AdapterWeightsFormat::SafetensorsLora => "safetensors-lora",
        allbert_proto::AdapterWeightsFormat::GgufLora => "gguf-lora",
    }
}

fn overall_label(value: AdapterOverallStatus) -> &'static str {
    match value {
        AdapterOverallStatus::ReadyForReview => "ready-for-review",
        AdapterOverallStatus::NeedsAttention => "needs-attention",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_proto::{Span, SpanStatus};
    use std::sync::Mutex;

    #[derive(Default)]
    struct RecordingHooks {
        ended: Mutex<Vec<Span>>,
    }

    impl TracingHooks for RecordingHooks {
        fn begin_span(&self, _span: &Span) -> Result<(), crate::TraceStoreError> {
            Ok(())
        }

        fn end_span(&self, span: &Span) -> Result<(), crate::TraceStoreError> {
            self.ended.lock().expect("spans").push(span.clone());
            Ok(())
        }
    }

    fn config() -> Config {
        let mut config = Config::default_template();
        config.model.provider = Provider::Ollama;
        config.model.model_id = "gemma4".into();
        config.learning.adapter_training.default_max_steps = 4;
        config.learning.adapter_training.default_batch_size = 1;
        config.learning.adapter_training.default_learning_rate = "0.0002".into();
        config
    }

    #[test]
    fn personality_adapter_job_writes_run_report_and_approval() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = crate::AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        crate::atomic_write(&paths.soul, b"# SOUL\n\nSteady.\n").expect("soul");
        crate::atomic_write(&paths.personality, b"# PERSONALITY\n\nConcise.\n")
            .expect("personality");
        let config = config();
        let ctx = LearningJobContext {
            paths: &paths,
            config: &config,
            accept_output: false,
            consent_hosted_provider: false,
        };

        let report = PersonalityAdapterJob::fake()
            .run_with_session(&ctx, "adapter-job-test")
            .expect("job");

        let run_id = report.execution["run_id"].as_str().expect("run id");
        let approval_id = report.execution["approval_id"]
            .as_str()
            .expect("approval id");
        let run_dir = paths.adapters_runs.join(run_id);
        assert!(run_dir.join("report.json").exists());
        assert!(run_dir.join(MANIFEST_FILE).exists());
        assert!(run_dir.join("loss-curve.txt").exists());
        assert!(run_dir.join("behavioral-diff.md").exists());
        assert!(approval_path_for(&paths, "adapter-job-test", approval_id).exists());
        assert_eq!(
            report.resource_cost["compute_wall_seconds"]
                .as_u64()
                .expect("compute"),
            4
        );
        assert_eq!(
            report.resource_cost["peak_resident_mb"]
                .as_u64()
                .expect("peak"),
            256
        );
    }

    #[test]
    fn adapter_training_emits_expected_span_tree() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = crate::AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let config = config();
        let hooks = Arc::new(RecordingHooks::default());
        let ctx = LearningJobContext {
            paths: &paths,
            config: &config,
            accept_output: false,
            consent_hosted_provider: false,
        };

        PersonalityAdapterJob::fake()
            .with_trace_hooks(hooks.clone())
            .run_with_session(&ctx, "adapter-job-trace")
            .expect("job");

        let spans = hooks.ended.lock().expect("spans");
        let names = spans
            .iter()
            .map(|span| span.name.as_str())
            .collect::<Vec<_>>();
        assert!(names.contains(&"run_training"));
        assert!(names.contains(&"corpus_assembly"));
        assert!(names.contains(&"trainer_invocation"));
        assert!(names.contains(&"eval_run"));
        assert!(spans
            .iter()
            .all(|span| matches!(span.status, SpanStatus::Ok)));

        let root = spans
            .iter()
            .find(|span| span.name == "run_training")
            .expect("root");
        for child_name in ["corpus_assembly", "trainer_invocation", "eval_run"] {
            let child = spans
                .iter()
                .find(|span| span.name == child_name)
                .expect("child");
            assert_eq!(child.parent_id.as_deref(), Some(root.id.as_str()));
        }
    }
}
