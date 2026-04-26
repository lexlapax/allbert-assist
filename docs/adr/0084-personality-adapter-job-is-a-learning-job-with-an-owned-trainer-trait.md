# ADR 0084: PersonalityAdapterJob is a LearningJob with an owned trainer trait

Date: 2026-04-25
Status: Accepted

## Context

v0.11 shipped the `LearningJob` trait, the `LearningJobReport` shape, and `PersonalityDigestJob` as the first concrete implementation. v0.13 ships the second implementation: a local LoRA/adapter training job that consumes the same approved-durable + approved-fact + bounded-episode-summary corpus contract, plus `SOUL.md` baseline persona/constraints and accepted `PERSONALITY.md` learned adaptation input.

Two framework choices are tempting and both are wrong for v0.13:

1. **Adopt a Rust ML framework** (`candle`, `burn`, `tch`). These are useful for inference but immature for end-to-end LoRA training across the toolchains operators actually use (mlx on Apple Silicon, llama.cpp on x86 with optional CUDA/Metal/Vulkan). Pulling in a training framework would commit Allbert to one ecosystem and reproduce the same trade-off ADR 0066 rejected for inference.
2. **Bake training into the kernel.** Inline subprocess management plus tokenizer/format-specific hand-coding bloats the kernel and re-implements work the trainer toolchain already does well.

The right move mirrors ADR 0066's choice for `LlmProvider`: keep a narrow owned trait, vetted external implementations, and a deterministic provider-free fake for tests/CI.

## Decision

v0.13 introduces `PersonalityAdapterJob` as a second `LearningJob` implementation alongside `PersonalityDigestJob`. Behind it sits an `AdapterTrainer` trait that the kernel owns:

```rust
#[async_trait]
pub trait AdapterTrainer: Send + Sync {
    fn name(&self) -> &'static str;
    fn supported_base_providers(&self) -> &'static [Provider];
    fn supported_formats(&self) -> &'static [AdapterFormat];
    fn describe_capabilities(&self) -> AdapterTrainerCapabilities;
    async fn train(
        &self,
        plan: &TrainingPlan,
        progress: &dyn TrainerProgress,
        cancel: &CancellationToken,
    ) -> Result<TrainingArtifacts, AdapterTrainerError>;
}
```

`TrainingPlan` carries the corpus snapshot, base-model identity, hyperparameters, output staging directory, deterministic seed, and per-run compute budget. `TrainerProgress` mirrors the v0.12.1 activity hook so live progress events flow through the same daemon-owned surface as any other long-running runtime work. `CancellationToken` propagates SIGTERM. `TrainingArtifacts` enumerates the on-disk outputs (adapter weights, manifest, logs) under `~/.allbert/adapters/runs/<run_id>/`.

v0.13 ships three concrete implementations:

- **`MlxLoraTrainer`** — invokes the `mlx_lm.lora` executable on Apple Silicon. Outputs safetensors LoRA weights.
- **`LlamaCppLoraTrainer`** — invokes `llama-cpp-finetune` (or `convert-lora-to-gguf` for export). Outputs GGUF LoRA weights.
- **`FakeAdapterTrainer`** — deterministic provider-free fake. Generates a fixture-shaped artifact tree without running real training. Used by Tier A validation, Codex Web CI, and any environment without GPU/Apple Silicon hardware. The fake's `train()` writes a tiny zero-rank placeholder manifest plus a deterministic loss-curve fixture so downstream eval rendering is exercised end-to-end.

Each external trainer is invoked through the existing exec-policy pipeline; the trainer binary name must appear in `security.exec_allow` and in `learning.adapter_training.allowed_backends`. See [ADR 0089](0089-trainer-subprocess-runs-under-existing-exec-policy-with-kind-scoped-allowlist.md).

## Constraints on `LearningJob` reuse

`PersonalityAdapterJob.run(ctx)` must populate `LearningJobReport` per v0.11's contract:

- `inputs` — corpus tier counts, byte totals, episode lookback bounds, and `corpus_digest` (sha256 over the canonicalised corpus). The corpus digest is the linkage between the artifact and its training data; identical corpora produce identical digests so reviewers can confirm provenance.
- `execution` — trainer backend identity, base-model `{provider, model_id, model_digest}`, hyperparameters (rank, alpha, learning rate, max steps, batch size, seed), training started/ended timestamps, and a compact ASCII loss curve.
- `resource_cost` — `{usd: 0.0, compute_wall_seconds, peak_resident_mb}` for local training. Hosted training (out of scope for v0.13) would also report `usd`.
- `output_artifacts` — the adapter manifest, the weights file, the loss curve, and the eval report under `~/.allbert/adapters/runs/<run_id>/`. `installed = false` until the operator accepts via `adapter-approval`.
- `staged_candidates` — empty for v0.13. Adapter training does not stage memory candidates.

`LearningJobContext` gains additive fields without renaming or removing existing ones, per the v0.11 "additive only" rule:

- `compute_cap_remaining_seconds: Option<u64>` — populated by the kernel from today's adapter-training spend against `learning.compute_cap_wall_seconds`.
- `cancel: Option<CancellationToken>` — populated for long-running runs that the operator may cancel mid-flight.

These fields default to `None` for `PersonalityDigestJob`, which does not consume them.

## Why an owned trait, not Rig / candle / burn

- The training surface is narrow: train one LoRA against one base model with a fixed corpus, write outputs to a staging directory, report progress and final artifacts. Three implementations and a fake fit in well under 1k lines per backend.
- Trainer toolchains move quickly. Adopting a framework couples Allbert's release cadence to that framework's release cadence. Owning the trait lets v0.13 update mlx/llama.cpp invocation flags as those projects evolve without coordinating an upstream change.
- Provider-free testability matters. `FakeAdapterTrainer` lets every test in the v0.13 plan run on contributor laptops, Codex Web, and CI without GPUs.
- The owned-trait shape keeps cost logging, compute-cap enforcement, exec policy, and trace emission in the kernel where ADR 0066's reasoning already located them.

## Consequences

**Positive**

- v0.13 ships review-first local personalization without adopting a heavy ML framework dependency.
- Future trainers (PEFT sidecar, GGUF-native trainers, hosted training) can plug into the same trait without reshaping the kernel.
- Tests run anywhere the rest of Allbert tests run.

**Negative**

- Per-backend invocation glue is hand-written. Acceptable: each backend is small.
- Adding a new backend requires writing a Rust module and a test fixture. Acceptable: this is the same trade-off ADR 0066 made for inference providers.

**Neutral**

- The `LearningJob` trait shape is unchanged; growth happens through `LearningJobContext` additive fields and `LearningJobReport` additive sub-fields.
- Hosted training is explicitly deferred and would land as a fourth `AdapterTrainer` implementation behind the same v0.11 hosted-provider consent gate (ADR 0079).

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0066](0066-owned-provider-seam-over-rig-for-v0-10.md)
- [ADR 0079](0079-personality-digest-is-a-review-first-learningjob-not-hidden-memory-or-training.md)
- [ADR 0080](0080-self-change-artifacts-share-approval-provenance-and-rollback-envelope.md)
- [ADR 0085](0085-adapter-activation-is-local-only-and-base-model-pinned.md)
- [ADR 0086](0086-adapter-approval-is-a-new-inbox-kind.md)
- [ADR 0087](0087-adapter-compute-cap-is-a-wall-clock-daily-gate.md)
- [ADR 0089](0089-trainer-subprocess-runs-under-existing-exec-policy-with-kind-scoped-allowlist.md)
