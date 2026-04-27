# Personalization operator guide

Personalization in the current v0.14.2 release is review-first local adapter training. It does not retrain a foundation model, does not send training data to hosted providers, and does not auto-activate trained weights.

Start with the [v0.14.2 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## Posture

- Training defaults to disabled.
- Training requires a local base model plus a local trainer backend.
- A backend must pass both gates: `learning.adapter_training.allowed_backends` and `security.exec_allow`.
- Hosted providers ignore active adapters and show one notice per session.
- Accepting an adapter approval installs the adapter; activation is a separate explicit command.
- Only one adapter can be active at a time.
- Active adapters are pinned to the base model they were trained against.

## Corpus

The training corpus can include:

- `SOUL.md` as baseline persona and constraints
- accepted `PERSONALITY.md` as reviewed learned adaptation
- approved durable memory notes
- approved fact frontmatter
- bounded episode summaries
- optional redacted v0.12.2 trace excerpts

Staged memory is never included. Trace excerpts are opt-in with:

```bash
cargo run -p allbert-cli -- settings set learning.adapter_training.capture_traces true
```

To opt out again:

```bash
cargo run -p allbert-cli -- settings set learning.adapter_training.capture_traces false
```

Trace material is redacted when traces are written and again when the adapter corpus is built.

## Settings

Inspect the full personalization settings group:

```bash
cargo run -p allbert-cli -- settings show learning.adapter_training
```

The daily local-training compute cap is separate from hosted-provider spend caps:

```bash
cargo run -p allbert-cli -- settings show learning.compute_cap_wall_seconds
cargo run -p allbert-cli -- settings set learning.compute_cap_wall_seconds 7200
```

`0` disables the compute cap.

## Commands

Preview the corpus:

```bash
cargo run -p allbert-cli -- adapters training preview
```

Start a training run:

```bash
cargo run -p allbert-cli -- adapters training start
```

Review pending approvals:

```bash
cargo run -p allbert-cli -- inbox list --kind adapter-approval
cargo run -p allbert-cli -- inbox show <approval-id>
```

Accepting installs but does not activate:

```bash
cargo run -p allbert-cli -- inbox accept <approval-id> --reason "looks good"
cargo run -p allbert-cli -- adapters list
cargo run -p allbert-cli -- adapters activate <adapter-id>
```

Other useful commands:

```bash
cargo run -p allbert-cli -- adapters status
cargo run -p allbert-cli -- adapters show <adapter-id>
cargo run -p allbert-cli -- adapters eval <adapter-id>
cargo run -p allbert-cli -- adapters loss <adapter-id>
cargo run -p allbert-cli -- adapters deactivate
cargo run -p allbert-cli -- adapters remove <adapter-id>
cargo run -p allbert-cli -- adapters history
cargo run -p allbert-cli -- adapters gc
```

The REPL and TUI also support `/adapters status`, `/adapters list`, and `/adapters history`. Telegram supports `/adapter status` and `/adapter approvals`.

## Safe Smoke Paths

Provider-free preview is the default contributor check:

```bash
cargo run -p allbert-cli -- adapters training preview
```

If training is disabled or no backend is configured, production `adapters training start` fails clearly. It must not silently fall back to fake training.

For an end-to-end contributor smoke, use a temporary profile and configure the explicit fake backend only for that profile:

```bash
tmpdir=$(mktemp -d /tmp/allbert-adapter-smoke.XXXXXX)
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- settings set learning.adapter_training.enabled true
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- settings set learning.adapter_training.allowed_backends '["fake"]'
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- settings set learning.adapter_training.default_backend fake
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- settings set security.exec_allow '["fake-adapter-trainer"]'
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- adapters training preview
```

Real training is an operator-credentialed local-hardware check. Enable it only after selecting a trainer backend, installing the backend binary, allowlisting the backend in `learning.adapter_training.allowed_backends`, allowing the executable in `security.exec_allow`, and choosing a compute cap.

## Evals and review

Each adapter approval points to local artifacts:

- eval summary
- ASCII loss curve
- behavioral diff
- manifest and weights paths

`needs-attention` adapters do not activate unless the operator supplies an override reason.

## Profile export

Adapter artifacts are derived and host-specific. Profile export excludes `adapters/` by default. To include installed adapters plus the active pointer:

```bash
cargo run -p allbert-cli -- profile export profile.tgz --include-adapters
```

This does not include runs, incoming adapters, runtime caches, or history.

## Rollback

Use `adapters deactivate` to stop using the active adapter. Use `adapters remove <id>` to remove an installed adapter. If a model switch makes the active adapter incompatible, Allbert deactivates it and requires explicit reactivation.

## Related Docs

- [v0.14.2 operator playbook](../onboarding-and-operations.md)
- [Personality digest guide](personality-digest.md)
- [Telemetry operator guide](telemetry.md)
- [Cost-cap posture](cost-caps.md)
- [v0.13 upgrade notes](../notes/v0.13-upgrade-2026-04-26.md)
