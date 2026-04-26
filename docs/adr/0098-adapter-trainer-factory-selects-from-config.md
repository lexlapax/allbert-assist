# ADR 0098: Adapter trainer factory selects backend from `default_backend`

Date: 2026-04-26
Status: Accepted

## Context

v0.13 introduced three [`AdapterTrainer`](../../crates/allbert-kernel/src/adapters/trainer.rs) implementations: `MlxLoraTrainer`, `LlamaCppLoraTrainer`, and `FakeAdapterTrainer`. The setup wizard collects `learning.adapter_training.default_backend`, the validator at [`config.rs:2119`](../../crates/allbert-kernel/src/config.rs) enforces that it must be in `allowed_backends` when training is enabled, and the wizard adds the corresponding binary to `security.exec_allow`.

Despite that, every production call site constructs the fake trainer directly:

- `PersonalityAdapterJob::default()` at [`adapters/job.rs:84`](../../crates/allbert-kernel/src/adapters/job.rs) returns `Self::fake()`.
- `preview_personality_adapter_training` at line 110 hard-codes `PersonalityAdapterJob::fake()`.
- `run_personality_adapter_training_with_override` at line 154 uses the same fake job.
- `allbert-cli/src/adapters_cli.rs:182` and `:191` invoke the fake job directly.

`default_backend` is therefore observable in setup state but does not affect what runs at training time. An operator who completes the wizard with `mlx-lm-lora` selected and starts a training run still gets fake-trainer artifacts.

## Decision

A new `crates/allbert-kernel/src/adapters/factory.rs` exposes:

```rust
pub fn build_trainer(
    paths: &AllbertPaths,
    config: &Config,
) -> Result<Arc<dyn AdapterTrainer>, KernelError>;
```

The factory inspects `config.learning.adapter_training`:

- `enabled = false` → returns `Arc<FakeAdapterTrainer>` and records "training disabled" in trainer-side metadata. (Useful for `preview` paths.)
- `default_backend = "mlx-lm-lora"` → returns `Arc<MlxLoraTrainer>` initialized with `paths` and the trainer config.
- `default_backend = "llama-cpp-finetune"` → returns `Arc<LlamaCppLoraTrainer>` initialized similarly.
- `default_backend = "fake"` → returns `Arc<FakeAdapterTrainer>` explicitly.
- Empty or unknown `default_backend` → returns `KernelError::Request` with a remediation hint naming `learning.adapter_training.default_backend`, `learning.adapter_training.allowed_backends`, and `security.exec_allow`.

Every production call site is updated to call `build_trainer`:

- `PersonalityAdapterJob::default()` keeps returning fake (test-friendly default).
- `PersonalityAdapterJob::production(paths, config)` is added as the production constructor that calls `build_trainer`.
- `preview_personality_adapter_training` calls `build_trainer` with a preview-only flag that always falls back to fake (preview never actually invokes a real trainer).
- `run_personality_adapter_training_with_override` calls `build_trainer`.
- The CLI `adapters training start` and the daemon `AdaptersTrainingStart` handler ([ADR 0097](0097-daemon-adapter-handlers-bridge-local-store.md)) both go through `PersonalityAdapterJob::production`.

The factory does not bypass any existing gate. Real backends still require:

- `security.exec_allow` containing the trainer binary (universal exec policy, [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md));
- `learning.adapter_training.allowed_backends` containing the backend identifier (kind-scoped allowlist, [ADR 0089](0089-trainer-subprocess-runs-under-existing-exec-policy-with-kind-scoped-allowlist.md));
- `learning.adapter_training.enabled = true` for non-preview paths;
- the daily compute cap ([ADR 0087](0087-adapter-compute-cap-is-a-wall-clock-daily-gate.md)).

If any gate refuses, the factory surfaces a clear error naming all relevant keys before any trainer is constructed.

## Consequences

- An operator who runs setup with a real backend gets that backend at training time.
- Tests that want fake training continue to call `PersonalityAdapterJob::fake()` or `::default()` and are unaffected.
- The "v0.13 real backend training shipped" claim becomes accurate after v0.14.1.
- Future trainer backends (e.g. CUDA-based, hosted-sidecar) plug into the factory by adding a new arm; no other call site changes.

## Alternatives considered

- **Pass `Box<dyn AdapterTrainer>` through every call site.** Rejected because every call site would need to know how to construct a trainer, duplicating factory logic.
- **Store trainer instances in a kernel-level registry.** Rejected because trainers are stateless once constructed and per-run construction is cheap. A registry adds lifetime complexity for no benefit.
- **Make `default_backend` a runtime tool registration.** Rejected because trainer selection should be config-driven and reviewable, not derived from runtime tool catalogs.
