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

- `executable`: one of `"mix"`, `"elixir"`, or `"erl"`;
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

Bundle ids and explicit bundle roots are confined under
`<ALLBERT_HOME>/sandbox/bundles`. `cleanup/1` only removes marked bundle roots:
the path must be a direct directory inside the sandbox bundle root and contain
`metadata.json`.

## SourcePolicy

`AllbertAssist.Sandbox.SourcePolicy` is defense in depth. It statically scans
draft and trial files before backend execution and denies known hostile
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
- `run/2`
- `cleanup/1`

They register with `AllbertAssist.Sandbox.Backend.Registry`. The registry is a
static module-owned registry in v0.36 unless future state is required; if a
state-bearing registry is introduced, its moduledoc must state why
Jido.Agent or GenServer was chosen.

All backends receive normalized bundle and command structs. Backends must use
explicit executable plus argv to invoke the container engine and must not call
a shell.

Docker-family backends must build their engine argv as data and preserve these
constraints: no image pull, no network, no host Docker socket, read-only root
filesystem, dropped capabilities, `no-new-privileges`, bounded CPU/memory/PID
limits, read-only project/draft/test mounts, writable bundle-local
`sandbox_home` and `reports` mounts, and `ALLBERT_HOME` set to the container
sandbox-home path. Docker+runsc is the same contract with `--runtime runsc`.
The implemented Docker path runs as UID/GID `65532:65532`; the rootless Podman
path uses `--userns=keep-id`. Both size the writable `/tmp` and `/run` tmpfs
mounts. v0.36 caps copied input, tmpfs, process, output, and wall-clock usage;
it does not claim a backend-wide disk quota for bind-mounted read-only inputs.

Image preparation is a separate v0.36 setup path. `mix allbert.sandbox image
build` may build the approved local Docker image, and `mix allbert.sandbox
image verify` may run a tiny local-only verification command. Backend `run/2`
and gate execution must still use local image inspection plus `--pull=never`;
they do not build, pull, or repair images.

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

## Fixture Expectations

Tests should cover unavailable backends without requiring Docker, Podman,
gVisor, or Apple `container` on CI. Backend command assembly should be tested
as data. Real engine smoke tests belong in manual verification or explicitly
tagged local-only tests.
