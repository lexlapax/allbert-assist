# ADR 0098: Adapter trainer factory selects the effective backend from config and request override

Date: 2026-04-26
Status: Accepted
Amends: [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md), [ADR 0089](0089-trainer-subprocess-runs-under-existing-exec-policy-with-kind-scoped-allowlist.md)

## Context

v0.13 introduced three [`AdapterTrainer`](../../crates/allbert-kernel/src/adapters/trainer.rs) implementations: `MlxLoraTrainer`, `LlamaCppLoraTrainer`, and `FakeAdapterTrainer`. The setup wizard collects `learning.adapter_training.default_backend`, the validator at [`config.rs:2119`](../../crates/allbert-kernel/src/config.rs) enforces that it must be in `allowed_backends` when training is enabled, and setup adds the corresponding binary to `security.exec_allow`.

Despite that, production call sites construct the fake trainer directly:

- `PersonalityAdapterJob::default()` at [`adapters/job.rs:84`](../../crates/allbert-kernel/src/adapters/job.rs) returns `Self::fake()`.
- `preview_personality_adapter_training` at line 110 hard-codes `PersonalityAdapterJob::fake()`.
- `run_personality_adapter_training_with_override` at line 154 uses the same fake job.
- `allbert-cli/src/adapters_cli.rs:182` and `:191` invoke fake-backed paths directly.

`default_backend` is therefore observable in setup state but does not reliably affect training. An operator who selects `mlx-lm-lora` can still get fake-trainer artifacts. That makes v0.13 partial as of v0.14 and tracked by v0.14.1.

Protocol v5 also already exposes per-run trainer selection through
`AdapterTrainingStartRequest { backend: Option<String>, override_reason:
Option<String> }`. v0.14.1 must therefore define how request-level backend
overrides interact with `default_backend`; leaving the field ignored would make
the protocol misleading.

## Decision

A production trainer factory selects the effective backend from config and an
optional per-run request override:

```rust
pub fn build_trainer(
    paths: &AllbertPaths,
    config: &Config,
    requested_backend: Option<&str>,
) -> Result<Arc<dyn AdapterTrainer>, KernelError>;
```

Production selection rules:

- `learning.adapter_training.enabled = false` refuses training with a remediation hint; it never returns fake.
- The effective backend is `requested_backend` when present, otherwise `learning.adapter_training.default_backend`.
- CLI and scheduled adapter training normally pass `None`.
- Daemon `AdaptersTrainingStart` passes `req.backend.as_deref()` from protocol v5. If a daemon request supplies a backend override, `req.override_reason` is required and is recorded in run metadata.
- empty effective backend refuses training and names `learning.adapter_training.default_backend`.
- unknown effective backend refuses training and names `learning.adapter_training.allowed_backends` and the request-level `backend` when present.
- request-level overrides do not bypass gates. They must be in `learning.adapter_training.allowed_backends`, must pass the trainer-binary and exec-policy gates, and must fail closed when unknown or disallowed instead of falling back to `default_backend`.
- `effective_backend = "mlx-lm-lora"` returns `MlxLoraTrainer` after the trainer-binary and exec-policy gates pass.
- `effective_backend = "llama-cpp-finetune"` returns `LlamaCppLoraTrainer` after the same gates pass.
- `effective_backend = "fake"` returns `FakeAdapterTrainer` only because fake was explicitly configured or explicitly requested and `fake` is allowed.

Every non-preview production call site is updated to call the factory:

- `PersonalityAdapterJob::production(paths, config, requested_backend)` calls `build_trainer`.
- CLI `adapters training start` goes through `PersonalityAdapterJob::production`.
- daemon `AdaptersTrainingStart` goes through `PersonalityAdapterJob::production` with the protocol request's backend override, if any.
- scheduled adapter training goes through `PersonalityAdapterJob::production`.

Preview and test paths stay fake but are explicit:

- `PersonalityAdapterJob::default()` and `PersonalityAdapterJob::fake()` remain test-friendly constructors.
- `adapters training preview` never invokes a real trainer. It renders corpus size, source tiers, hyperparameters, configured backend name, estimated run location, and whether production training would currently be enabled. It may use fake metadata for deterministic display, but it must label itself as preview-only and non-training.

The factory does not bypass existing gates. Real backends still require:

- `security.exec_allow` containing the trainer binary;
- `learning.adapter_training.allowed_backends` containing the backend identifier;
- `learning.adapter_training.enabled = true`;
- the daily compute cap ([ADR 0087](0087-adapter-compute-cap-is-a-wall-clock-daily-gate.md)).

If any gate refuses, the factory surfaces a clear error naming all relevant keys before any trainer is constructed.

The factory is the only production place where a backend name becomes an
`AdapterTrainer`. Callers may pass an override request, but they may not
pre-construct a fake or real trainer outside the factory for production starts.

## Consequences

- An operator who enables a real backend gets that backend at training time, or a clear refusal explaining what is missing.
- Fake training stops being the silent production fallback.
- Tests and provider-free validation continue to call explicit fake constructors.
- The "v0.13 real backend training" claim becomes true only after v0.14.1 lands; until then it remains partial as of v0.14 and tracked by v0.14.1.
- Future trainer backends plug into the factory by adding one arm; production call sites do not change beyond optionally passing a request override.

## Alternatives considered

- **Keep disabled training as fake.** Rejected because it repeats the drift this ADR fixes. Disabled production training should refuse clearly.
- **Pass `Box<dyn AdapterTrainer>` through every call site.** Rejected because every call site would need to know how to construct trainers, duplicating factory logic.
- **Store trainer instances in a kernel-level registry.** Rejected because trainers are cheap to construct per run and a registry adds lifetime complexity.
- **Make `default_backend` a runtime tool registration.** Rejected because trainer selection should be config-driven and reviewable, not derived from active tool catalogs.
