# Elixir Sandbox And Gate Runner Operator Guide

Status: v0.36 implementation contract.

The v0.36 sandbox is a default-off local OS isolation boundary for generated
Elixir/OTP drafts and explicit gate commands. It produces bounded reports only.
A passing report does not load code, register actions, grant permissions,
enable skills, change routes, or set app routing context.

## Safety Defaults

- Keep `sandbox.elixir.enabled=false` unless actively testing generated
  Elixir/OTP drafts.
- Use a disposable `ALLBERT_HOME` for smoke testing and release verification.
- Do not point sandbox bundles at a real operator home, settings root, secrets,
  database, memory, or cache.
- Use only approved local images. The runner must never pull images from a
  registry during a sandbox run.
- Keep `sandbox.elixir.network=none`; v0.36 has no network-enabled profile.

## Settings

| Key | Default | Purpose |
|---|---:|---|
| `sandbox.elixir.enabled` | `false` | Master switch for v0.36 sandbox runs. |
| `sandbox.elixir.backend` | `auto` | OS-aware backend resolver or explicit backend pin. |
| `sandbox.elixir.image` | `allbert-elixir-otp:local` | Approved local Elixir/OTP image reference. |
| `sandbox.elixir.network` | `none` | Network policy. v0.36 accepts only `none`. |
| `sandbox.elixir.cpu_limit` | `1.0` | CPU quota passed to the backend within bounded limits. |
| `sandbox.elixir.memory_mb` | `1024` | Memory limit passed to the backend. |
| `sandbox.elixir.timeout_ms` | `120000` | Default wall-clock command timeout. |
| `sandbox.elixir.output_bytes` | `65536` | stdout/stderr report cap per command. |
| `permissions.sandbox_trial` | `allowed` | Security Central action boundary for report-only sandbox actions. |

Enable only in a disposable smoke home:

```sh
unset DATABASE_PATH
unset ALLBERT_HOME_DIR
export SMOKE_HOME="$(mktemp -d /tmp/allbert-v036-smoke.XXXXXX)"
export ALLBERT_HOME="$SMOKE_HOME"
mix allbert.settings set sandbox.elixir.enabled true
mix allbert.sandbox image build
mix allbert.sandbox image verify
mix allbert.sandbox doctor
```

Do not run an explicit migration command for this disposable-home
smoke. Dev/test configuration derives the SQLite path as
`$ALLBERT_HOME/db/allbert.sqlite3`, and the first `mix allbert.*`
task starts the repo plus the built-in `Ecto.Migrator` child when that
canonical database is missing or empty.

`image build` prepares the configured approved local image
(`allbert-elixir-otp:local` by default), including dependency cache/source from
the current project manifests. `image verify` checks the local image and runs a
small local-only container check. Sandbox gate runs still never pull images;
they use `--pull=never` and fail closed if the image is absent.

## Backend Selection

`sandbox.elixir.backend=auto` resolves through an OS-aware chain:

- macOS on Apple silicon with macOS 26 or newer: `apple_container` when doctor
  verifies the host and CLI policy support, then `docker_runsc`, then `docker`.
- macOS on older versions or Intel: `docker_runsc`, then `docker`.
- Linux: `podman_rootless`, then `docker_runsc`, then `docker`.

Operators may pin `apple_container`, `podman_rootless`, `docker_runsc`, or
`docker`. A pinned backend fails closed when unavailable or unable to enforce
v0.36 policy.

## Doctor

Run:

```sh
ALLBERT_HOME="$SMOKE_HOME" mix allbert.sandbox doctor
```

Expected output includes:

- whether the sandbox is enabled;
- the configured backend and resolved backend;
- each candidate considered and its availability reason;
- image-local status;
- network and resource limits;
- report and bundle roots;
- fail-closed diagnostics when no supported backend is available.

Doctor must not run untrusted draft code.

## Bundle And Reports

Allbert creates these roots under Allbert Home:

```text
<ALLBERT_HOME>/sandbox/bundles
<ALLBERT_HOME>/sandbox/reports
<ALLBERT_HOME>/sandbox/cache
<ALLBERT_HOME>/sandbox/audit
```

Each bundle receives a disposable sandbox home inside the bundle. The real
operator home is never mounted into the container. Reports are copied out to
the sandbox report root and surfaced read-only. Facade-level sandbox lifecycle
events append bounded audit entries under the sandbox audit root.

Bundle ids and explicit roots are confined to the sandbox bundle root. Bundle
discard only removes marked bundle directories that contain `metadata.json`;
arbitrary host paths, the bundle root itself, and unmarked directories fail
closed.

Registered internal runtime actions mirror the lifecycle:
`sandbox_doctor`, `build_sandbox_bundle`, `run_sandbox_command`,
`run_sandbox_gate`, and `discard_sandbox_bundle`. They return reports only and
do not grant integration authority.

## Failure States

Treat these as expected fail-closed results:

- sandbox disabled;
- no backend on the current OS can enforce policy;
- pinned backend unavailable;
- configured image is missing or not approved locally;
- image labels or local verification do not match v0.36 policy;
- malformed bundle id, bundle root traversal, explicit bundle root outside
  `<ALLBERT_HOME>/sandbox/bundles`, or cleanup pointed at an unmarked path;
- forged command specs with caller-set allowed status;
- command is not `mix`;
- argv shape requests package installs, migrations, shell syntax, eval,
  daemon control, network, NIFs, ports, or core-node loading;
- source policy finds forbidden Elixir constructs;
- output exceeds the configured cap or command exceeds timeout.

## Local Docker Compile Smoke

When Docker is available and the operator wants to prove the small compile
fixture green path, run:

```sh
ALLBERT_DOCKER_SANDBOX_TEST=1 mix test apps/allbert_assist/test/allbert_assist/sandbox_test.exs --only docker_sandbox
```

If the base Elixir image is not present locally and the host is allowed to pull
it, set `ALLBERT_DOCKER_BASE_IMAGE=<image>` and `ALLBERT_DOCKER_PULL_BASE=1`
for that smoke. By default the smoke uses the approved local
`allbert-elixir-otp:local` image as its base so it can verify the compile path
without requiring a registry pull. The resulting report must show a completed
`:compile` gate for a trivial fixture.

## Local Docker Full-Gate Smoke

The v0.37 trust precondition needs the real default gate, not just the trivial
fixture. When Docker is available, run:

```sh
ALLBERT_DOCKER_FULL_GATE_TEST=1 mix test apps/allbert_assist/test/allbert_assist/sandbox_test.exs --only docker_full_gate
```

This opt-in smoke builds an approved local image for the current umbrella,
including the build toolchain needed by C/NIF deps, compiled dependency
artifacts, and Dialyzer PLT state when Dialyxir is present. Runtime gate
containers seed writable dependency/build/cache paths and the writable test DB
directory from the baked image state, then run the full default gate: compile,
focused tests, Credo, Dialyzer, and security evals.
Passing this smoke is the local proof that the sandbox gate is ready to support
v0.37 trust decisions.

## Emergency Posture

Disable immediately with:

```sh
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set permissions.sandbox_trial denied
```

Then inspect:

```sh
mix allbert.sandbox doctor
mix allbert.security review --recent --limit 25
```

Sandbox reports are evidence. They are not trust grants.
