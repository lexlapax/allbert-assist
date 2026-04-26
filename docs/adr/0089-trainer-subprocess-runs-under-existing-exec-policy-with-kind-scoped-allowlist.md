# ADR 0089: Trainer subprocess runs under existing exec policy with a kind-scoped allowlist

Date: 2026-04-25
Status: Accepted

## Context

ADR 0084 chose an owned `AdapterTrainer` trait with three concrete implementations: `MlxLoraTrainer`, `LlamaCppLoraTrainer`, and a deterministic `FakeAdapterTrainer`. The first two invoke external executables (`mlx_lm.lora`, `llama-cpp-finetune`, etc.). v0.13 must decide how those subprocess invocations interact with the existing exec policy.

The current exec policy (`security.exec_allow` / `security.exec_deny`) is the universal gate for skill scripts, tools, and the v0.12 Lua scripting opt-in. Carving out a separate trainer-only bypass is exactly the kind of "privileged shortcut" the cross-cutting security envelope rejects. But trainer invocation is also semantically different from a skill script call: it is long-running, machine-specific, and consumes the v0.13 compute cap rather than the v0.12 turn cost cap.

The right shape mirrors ADR 0034 (skill scripts run under the same exec policy as tools): one shared exec policy, with an additional kind-scoped allowlist that scopes "this binary is permitted to act as a trainer" without weakening or duplicating the universal gate.

## Decision

Trainer subprocesses run under the existing `security.exec_allow` / `security.exec_deny` policy. No bypass and no new privileged path. v0.13 adds a kind-scoped allowlist that names which binaries may be invoked specifically as adapter trainers:

```toml
[learning.adapter_training]
allowed_backends = ["mlx-lm-lora", "llama-cpp-finetune", "fake"]   # kind-scoped allowlist
default_backend = "mlx-lm-lora"
```

The kernel resolves a trainer invocation in two steps:

1. **Kind allowlist check.** The configured backend identifier (e.g. `mlx-lm-lora`) must appear in `learning.adapter_training.allowed_backends`. The identifier is the `AdapterTrainer.name()` value, not a binary path.
2. **Exec policy check.** The binary the resolved backend would spawn (e.g. the `mlx_lm.lora` Python script entry point or the `llama-cpp-finetune` binary) must satisfy the existing `security.exec_allow` / `security.exec_deny` rules. Each backend declares its required interpreter or binary name; the kernel queries the existing policy with that name.

Both gates are required. A binary in `security.exec_allow` but not in `learning.adapter_training.allowed_backends` cannot be used as a trainer. A backend in the kind allowlist whose binary is denied by `security.exec_deny` is refused with a clear remediation hint pointing at both keys. Operators receive a single error that names exactly what to add and where:

```
Trainer 'mlx-lm-lora' refused: binary 'mlx_lm.lora' is not allowlisted.
Add 'mlx_lm.lora' to config.security.exec_allow and 'mlx-lm-lora' to config.learning.adapter_training.allowed_backends.
```

The default `security.exec_allow` does NOT include trainer binaries; the v0.13 setup wizard surfaces the trainer step explicitly so the operator opts in deliberately.

### Why two gates

- The exec policy stays the universal gate. Every binary the kernel spawns goes through it. v0.13 does not introduce a parallel exec path.
- The kind allowlist is intent-scoped. An operator who allowlists Python in `security.exec_allow` for a skill script does not want Python to be invoked as a trainer until they explicitly opt in. The kind allowlist captures "this is permitted as a trainer" separately from "this binary may be spawned at all."
- Future kind-scoped intents (e.g. evaluator backends, embedding-model backends) can follow the same shape without re-amending the exec policy.

### Argument validation

Trainer arguments are kernel-built, not operator-supplied. The kernel constructs the full command line from the `TrainingPlan` (corpus path, hyperparameters, output directory, seed) using a per-backend builder. Operators cannot inject free-form trainer arguments; they choose hyperparameters through `learning.adapter_training.*` keys that map to validated argument shapes. This keeps argument injection inside the kernel where it can be audited.

### Working directory and environment

Each trainer runs in a per-run working directory (`~/.allbert/adapters/runs/<run_id>/`). The kernel sets a minimal environment containing only what the trainer needs:

- `PATH` is inherited.
- `HOME` and `TMPDIR` are inherited.
- `ALLBERT_HOME` is set so the trainer's helper scripts (if any) can locate the corpus snapshot.
- All other Allbert internal env vars are stripped before spawn.

This matches v0.12's Lua sandbox posture (ADR 0070) at the env level: minimal surface, allowlist-shaped.

### Cancellation

The kernel sends SIGTERM on cancellation, then SIGKILL after a 30-second grace period if the trainer has not exited. Output past cancellation is captured up to the configured log size cap and the run manifest records `cancelled_at` plus `cancel_reason`.

### Output capture

stdout and stderr are captured to per-run log files under `~/.allbert/adapters/runs/<run_id>/{stdout.log, stderr.log}`. Log files are bounded at `learning.adapter_training.max_log_bytes` (default 16 MB per stream); excess is truncated with a marker line. The structured loss curve is parsed from a backend-specific output channel (mlx writes JSON-lines, llama.cpp writes a known stderr format) and written to `loss-curve.txt` and `loss-curve.json`.

## Consequences

**Positive**

- Operators have one universal exec gate plus one intent-scoped opt-in. No parallel pipeline.
- Trainer argument shape stays kernel-controlled, eliminating argument-injection foot guns.
- The pattern generalises to future kind-scoped backends.

**Negative**

- Operators have to opt in twice: exec_allow plus allowed_backends. Acceptable: the error message names both keys.
- Adding a new trainer backend requires both a Rust implementation and a config update. Acceptable: this is the same shape as adding an `LlmProvider`.

**Neutral**

- The `FakeAdapterTrainer` does not invoke any subprocess; the kind allowlist still gates it for consistency, but the exec policy is a no-op for this backend.
- The 30-second SIGKILL grace period is a configuration default and can be tuned via `learning.adapter_training.cancel_grace_seconds` if needed.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0070](0070-embedded-script-sandbox-policy.md)
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0087](0087-adapter-compute-cap-is-a-wall-clock-daily-gate.md)
