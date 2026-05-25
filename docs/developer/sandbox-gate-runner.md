# Elixir Sandbox And Gate Runner Developer Contract

Status: v0.36 implementation contract.

v0.36 adds a narrow sandbox substrate for generated Elixir/OTP drafts. It is
not a broad coding-agent shell, package installer, or live integration loader.
Future v0.37 and v0.38 code must call `AllbertAssist.Sandbox` or registered
sandbox actions; they must not construct container commands directly.

## Public Facade

The public context is `AllbertAssist.Sandbox`:

- `doctor/0`
- `build_bundle/1`
- `run_command/2`
- `run_gate/1`
- `cleanup/1`

Runtime-facing calls also have registered actions:

- `AllbertAssist.Actions.Sandbox.Doctor` (`sandbox_doctor`)
- `AllbertAssist.Actions.Sandbox.BuildBundle` (`build_sandbox_bundle`)
- `AllbertAssist.Actions.Sandbox.RunCommand` (`run_sandbox_command`)
- `AllbertAssist.Actions.Sandbox.RunGate` (`run_sandbox_gate`)
- `AllbertAssist.Actions.Sandbox.DiscardBundle` (`discard_sandbox_bundle`)

These actions produce report data only. No action may load generated code into
the core BEAM node or grant authority. They use the `:sandbox_trial` Security
Central permission and still require `sandbox.elixir.enabled=true` before any
backend command can run.

## CommandSpec

`AllbertAssist.Sandbox.CommandSpec` is a struct, not a shell string.

Required fields:

- `executable`: `"mix"` for v0.36 runtime gate profiles;
- `argv`: explicit list of binary args;
- `cwd`: path inside the sandbox bundle;
- `profile`: one of `:compile`, `:focused_tests`, `:credo`, `:dialyzer`,
  `:security_evals`, or `:precommit`;
- `timeout_ms` and `output_bytes`, capped by Settings Central;
- `env`, filtered to a bounded allow-list.

The `AllbertAssist.Sandbox` facade revalidates map input and `%CommandSpec{}`
input before backend execution. Caller-supplied struct fields such as
`status: :allowed` are never authority.

Reject before backend execution:

- shell strings, `sh -c`, chaining, pipes, redirects, glob expansion,
  substitutions, background jobs, PTY, and daemon control;
- `mix deps.get`, `mix archive.install`, migrations, package managers, Hex,
  npm, cargo, pip, git clone, curl/wget installers, NIF builds, ports, broad
  eval, and network setup;
- argv that tries to access host paths outside the bundle.

## Bundle Shape

`AllbertAssist.Sandbox.Bundle` owns copy-in/copy-out state:

```text
bundle_root/
  project/
  drafts/
  tests/
  sandbox_home/
  reports/
  metadata.json
```

The bundle builder may copy only bounded allow-listed Elixir project files,
draft files, and focused tests. It must exclude `.git`, the live Allbert Home,
settings, secrets, databases, caches, Docker socket paths, host temp roots, and
symlink/traversal escapes.

Default project bundles include the root Mix files, formatter/Credo/Dialyzer
config, root config, app source, and reviewed source-tree plugins needed by the
current umbrella compile and warning-gate path. They still exclude build,
dependency, VCS, generated static, and vendor directories.

Bundle ids and explicit bundle roots are confined under
`<ALLBERT_HOME>/sandbox/bundles`. `cleanup/1` only removes marked bundle roots:
the path must be a direct directory inside the sandbox bundle root and contain
`metadata.json`.

## SourcePolicy

`AllbertAssist.Sandbox.SourcePolicy` is defense in depth. It statically scans
draft and trial files in the `AllbertAssist.Sandbox` facade before backend
resolution/execution and denies known hostile
constructs including:

- `System.cmd`, `System.shell`, `Port.open`, and `:os.cmd`;
- `Code.eval_*`, `Code.compile_*`, and `Code.require_*`;
- `Mix.install`;
- `:erlang.load_nif`;
- broad file traversal or attempts to read real Allbert Home paths;
- attempts to load modules into the core node.

Backend isolation remains mandatory even when source policy passes.

## Backend Behaviour

Backends implement `AllbertAssist.Sandbox.Backend`:

- `id/0`
- `platforms/0`
- `available?/1`
- `doctor/1`
- `run/3`
- `cleanup/1`

They register with `AllbertAssist.Sandbox.Backend.Registry`. The registry is a
static module-owned registry in v0.36 unless future state is required; if a
state-bearing registry is introduced, its moduledoc must state why
Jido.Agent or GenServer was chosen.

All backends receive normalized bundle and command structs plus the resolved
`Sandbox.Policy`. Backends must use explicit executable plus argv to invoke the
container engine and must not call a shell. They must not reload Settings
Central mid-run for image, backend, CPU, memory, or timeout policy.

Docker-family backends must build their engine argv as data and preserve these
constraints: no image pull, no network, no host Docker socket, read-only root
filesystem, dropped capabilities, `no-new-privileges`, bounded CPU/memory/PID
limits, read-only project/draft/test mounts, writable bundle-local
`sandbox_home` and `reports` mounts, protected container-local Mix env
(`ALLBERT_HOME`, `HOME`, `MIX_BUILD_PATH`, `MIX_HOME`, `HEX_HOME`,
`REBAR_CACHE_DIR`, and `MIX_DEPS_PATH`), a protected writable `DATABASE_PATH`
for test DB creation, and `ALLBERT_HOME` set to the container sandbox-home
path. Docker+runsc is the same contract with `--runtime runsc`.
The implemented Docker path runs as UID/GID `65532:65532`; the rootless Podman
path uses `--userns=keep-id`. Both size the writable `/tmp` and `/run` tmpfs
mounts. v0.36 caps copied input, tmpfs, process, output, and wall-clock usage;
it does not claim a backend-wide disk quota for bind-mounted read-only inputs.
Docker/Podman argv includes a generated container name so timeout handling can
attempt best-effort `rm -f` cleanup after the BEAM-side timeout fires.

Image preparation is a separate v0.36 setup path. `mix allbert.sandbox image
build` may build the approved local Docker image, and `mix allbert.sandbox
image verify` may run a tiny local-only verification command. The build task
copies dependency manifests into the image context and prepares dependency
cache/source with `mix deps.get --only test` and `mix deps.compile`. The image
prep path installs the minimal C/git toolchain needed by real Allbert deps,
pre-bakes compiled dependency artifacts under `/opt/allbert/_build`, and
pre-bakes Dialyzer PLT state when Dialyxir is present. It then normalizes
artifact permissions so the non-root runtime user can read dependency source,
compiled artifacts, and PLTs. Backend `run/3` and gate execution must still use
local image inspection plus `--pull=never`; they do not build, pull, or repair
images.

Docker/Podman runtime argv invokes the fixed image-owned
`/opt/allbert/bin/allbert-sandbox-run` wrapper before the reviewed `mix`
command. That wrapper does not parse operator command text; it seeds writable
bundle-local deps, build, Mix, Hex, and Rebar paths from the baked image state,
creates the writable sandbox DB directory, and then `exec`s the argv it was
given. This preserves the explicit-argv contract while avoiding cold dependency
recompiles during every gate run, keeping dependency `priv` symlinks valid, and
letting Dialyxir validate or refresh PLT files inside the disposable sandbox
home.

The root Dialyxir config must keep honoring `MIX_BUILD_PATH`; hard-coded
project `_build` PLT paths will fail in the read-only sandbox project mount.

## Gate Profiles

`AllbertAssist.Sandbox.GateRunner` maps named profiles to data:

| Profile | Command |
|---|---|
| `:compile` | `mix compile --warnings-as-errors` |
| `:focused_tests` | configured `mix test` files |
| `:credo` | `mix credo --strict` |
| `:dialyzer` | `mix dialyzer` |
| `:security_evals` | configured security eval tests |
| `:precommit` | `mix precommit` |

Profiles are reviewed code, not operator-supplied command text.

## Report Contract

Reports include:

- status, exit status, duration, timeout flag, and output truncation flag;
- capped stdout/stderr;
- backend id and backend metadata;
- command summary and source-policy diagnostics;
- redaction diagnostics;
- report path.

Reports must redact secrets, real-home absolute paths, and oversized output.
`Report.to_map/1` is the redacted representation used for action responses and
persisted JSON. Reports are evidence for later operator review, not authority.
Backend runners write report JSON into the bundle report root for completed,
failed, denied, timed-out, and unavailable outcomes.

Facade-level sandbox lifecycle events also append bounded markdown audit
records under `<ALLBERT_HOME>/sandbox/audit`. Action-runner observability still
applies when callers invoke registered sandbox actions, but direct facade calls
must not rely on action audit alone.

## Fixture Expectations

Tests should cover unavailable backends without requiring Docker, Podman,
gVisor, or Apple `container` on CI. Backend command assembly should be tested
as data. Real engine smoke tests belong in manual verification or explicitly
tagged local-only tests. The v0.36 Docker-gated compile smoke is selected with:

```sh
ALLBERT_DOCKER_SANDBOX_TEST=1 mix test apps/allbert_assist/test/allbert_assist/sandbox_test.exs --only docker_sandbox
```

The smoke defaults to `allbert-elixir-otp:local` as its base image. Set
`ALLBERT_DOCKER_BASE_IMAGE=<image>` and `ALLBERT_DOCKER_PULL_BASE=1` only when
you intentionally want the smoke to pull or refresh a remote base image.

The real-project full gate is a separate opt-in smoke:

```sh
ALLBERT_DOCKER_FULL_GATE_TEST=1 mix test apps/allbert_assist/test/allbert_assist/sandbox_test.exs --only docker_full_gate
```

It builds a local image for the current umbrella and runs the default gate
profiles end to end. Keep it opt-in because it is host- and Docker-dependent,
but treat a passing run as required evidence before starting v0.37 trust-path
implementation.
