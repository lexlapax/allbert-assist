# ADR 0037: Elixir/OTP Sandbox Backend And Gate Runner

## Status

Accepted for v0.36 Elixir/OTP Sandbox And Gate Runner
(`docs/plans/v0.36-plan.md`). This ADR graduates a narrow ADR 0009 Level-3
container sandbox for generated Elixir/OTP drafts and explicit gate commands.
It is the prerequisite for v0.37 Dynamic Code & Config Generation and Live
Capability Integration.

## Context

Allbert has Level-1 local policy sandboxing for confirmed host shell execution,
but Level 1 is not an OS boundary. The upcoming self-extending-runtime work
needs a real isolation boundary before any generated Elixir/OTP code is
compiled, tested, or considered for integration.

The immediate need is narrower than a general coding-agent sandbox: Allbert only
needs to trial generated Elixir/OTP drafts and the explicit shell commands
required by the Elixir gate. Supporting arbitrary languages, online dependency
installation, package managers, broad shell automation, or remote builders would
expand both implementation and threat surface beyond the next milestone.

Research summary:

- Docker/Podman provide the implementable local baseline: namespaces, cgroups,
  explicit mounts, network policy, user/capability policy, and rootless options.
- gVisor's `runsc` adds a userspace application kernel and can be configured as
  a Docker runtime, but it is an optional hardened backend because it requires
  host setup and platform compatibility.
- Firecracker requires Linux KVM plus kernel/rootfs/jailer setup and is too
  heavy for the first local sandbox milestone.
- Apple's `container` / Containerization stack runs one lightweight VM per
  container, giving hypervisor-grade host isolation that is stronger than a
  shared-VM Docker Desktop on macOS and well suited to untrusted code. It is
  Apple-silicon-only, needs macOS 26 (Tahoe) for full support, is
  OCI-compatible, and is still pre-1.0 (breaking changes between minor
  versions). v0.36 therefore adopts it only as an optional doctor-gated macOS
  adapter, not as release-blocking scope or the cross-platform baseline.

References:

- ADR 0009: `docs/adr/0009-local-execution-sandbox-levels.md`
- Docker Engine security: `https://docs.docker.com/engine/security/`
- Docker rootless mode: `https://docs.docker.com/engine/security/rootless/`
- Docker Desktop container isolation FAQ:
  `https://docs.docker.com/security/faqs/containers/`
- Podman docs: `https://docs.podman.io/en/v4.3/markdown/podman.1.html`
- gVisor security model: `https://gvisor.dev/docs/architecture_guide/security/`
- gVisor Docker install/runtime docs:
  `https://gvisor.dev/docs/user_guide/install/`
- Firecracker getting started:
  `https://github.com/firecracker-microvm/firecracker/blob/main/docs/getting-started.md`
- Apple container: `https://github.com/apple/container`

## Decision

v0.36 adds a narrow, default-off OS sandbox runner for Elixir/OTP gate work.

### 1. Scope is Elixir/OTP plus explicit gate commands

The runtime gate command surface is a structured executable plus reviewed argv
for `mix` profiles only. `elixir --version` is used by the separate image
verification task, not by sandbox gate execution; `elixir` and `erl` are not
accepted gate executables in v0.36. There is no shell-string command
execution, no `sh -c`, no chaining, no redirection, no glob expansion, no PTY,
no daemon control, and no broad shell automation. The sandbox facade revalidates
`%CommandSpec{}` structs before execution; caller-controlled status fields are
never authority.

### 2. Backend contract is reviewed and inspectable

Backends implement a common `AllbertAssist.Sandbox.Backend` behaviour and are
listed in a static reviewed `AllbertAssist.Sandbox.Backend.Registry`. Future
engines require a reviewed registry/resolver update, but callers do not bypass
the facade or gate runner. The behaviour exposes `id/0`, `platforms/0`,
`available?/1`, `doctor/1`, `run/3`, and `cleanup/1`; `run/3` receives the
resolved `Sandbox.Policy` so validation, backend resolution, image choice, and
resource bounds share one policy snapshot.

v0.36 ships these backends:

- `apple_container` — optional Apple `container` on supported macOS
  (doctor-gated: Apple silicon + macOS 26+ + policy enforcement);
- `docker` — hardened Docker invocation (cross-platform fallback);
- `podman_rootless` — rootless Podman where available;
- `docker_runsc` — optional Docker + `runsc` / gVisor when configured, preferred
  over plain Docker whenever doctor-green.

Every backend must enforce the same Allbert policy: no network by default, no
host Docker socket, no privileged mode, no host PID/user/network namespace, no
real Allbert Home mount, no secrets, dropped capabilities, resource limits,
output limits, cleanup, and typed audit metadata. The implemented Docker path
runs as UID/GID `65532:65532`; the rootless Podman path uses
`--userns=keep-id`; Docker-family writable `/tmp` and `/run` mounts are sized
tmpfs mounts. Docker/Podman runs also get protected container-local Mix
home/build/cache environment and a generated container name for best-effort
timeout cleanup. v0.36 bounds copied input, tmpfs, process, output, and
wall-clock usage; it does not claim a backend-wide disk quota for read-only
bind-mounted inputs. A backend whose host cannot enforce the policy reports
unavailable through `doctor/1` and is never selected.

### 3. Backend selection is OS-aware and fails closed

`sandbox.elixir.backend` is stored as a string and defaults to `"auto"`. An
`AllbertAssist.Sandbox.Backend.Resolver` resolves `"auto"` through a
deterministic, doctor-checked fallback chain:

- macOS (Apple silicon, macOS 26+): `apple_container` when doctor-green →
  `docker_runsc` when Docker exposes `runsc` → `docker`;
- macOS (older or Intel): `docker_runsc` when Docker exposes `runsc` →
  `docker`;
- Linux: `podman_rootless` → `docker_runsc` when configured → `docker`.

Operators may pin an explicit backend instead of `"auto"`. `doctor` reports the
resolved backend and why each candidate passed or failed, so selection is
inspectable. If no on-platform backend is available, sandbox actions fail
closed. There is no fallback to BEAM processes, hidden nodes, ports, or host
execution for untrusted generated code. `"auto"` does not weaken the default-off
posture: nothing runs until `sandbox.elixir.enabled=true` and doctor is green.

### 4. Copy-in/copy-out is mandatory

The sandbox receives a disposable bundle containing only allow-listed project,
draft, and test inputs plus a disposable `ALLBERT_HOME`. Reports are copied out
as bounded structured data. The sandbox never receives the operator's real
settings, secrets, database, memory files, caches, or arbitrary host paths.
Bundle ids and explicit bundle roots are confined under
`<ALLBERT_HOME>/sandbox/bundles`. Cleanup only removes direct marked bundle
directories containing `metadata.json`; arbitrary host paths and unmarked
directories fail closed.

### 5. Image and source policy are mandatory

Sandbox runs never pull images. `sandbox.elixir.image` must resolve to an
approved local image reference or digest during doctor/bundle preparation, or
execution fails closed. v0.36 also owns the explicit local image-preparation
workflow for the default sandbox image. That workflow may build the approved
local image as an operator setup step, copies dependency manifests into the
build context, installs the minimal C/git toolchain needed by real Allbert
deps, prepares dependency cache/source with `mix deps.get --only test` and
`mix deps.compile`, pre-bakes Dialyzer PLT state when Dialyxir is present, and
normalizes baked artifact permissions for the non-root runtime user.
Runtime container commands use a fixed image-owned runner that seeds writable
bundle-local dependency, build, Mix, Hex, and Rebar paths from the baked image
state before execing reviewed `mix` argv. The same sandbox home owns the
writable `DATABASE_PATH` used by test DB setup, and seeded PLT/build copies are
writable only inside that disposable home. Root Dialyxir config must honor
`MIX_BUILD_PATH` so PLT state does not target the read-only project mount.
Sandbox command execution remains local-image-only, no-network, and uses
`--pull=never`.

Draft source and trial files are statically scanned in the sandbox facade
before backend resolution or execution. Known dangerous constructs
(`System.cmd`, `Port.open`, `:os.cmd`,
`Code.eval_*`, `Code.compile_*`, `Code.require_*`, `Mix.install`,
`:erlang.load_nif`, broad file traversal, and real-home access attempts) are
denied with bounded diagnostics. This is defense-in-depth; backend isolation is
still required.

Forward contract for v0.37 consumers: the v0.36 bundle mounts project, draft,
and test roots separately. The `drafts` and `tests` mounts are not automatically
on `/workspace/project`'s Elixir compile path when the gate runs `mix` from the
project tree. Dynamic-code consumers that need generated modules or tests to
compile must materialize those files into compile-visible paths inside a
disposable project-shaped staging tree and ensure `SourcePolicy` scans the same
generated bytes before backend resolution. v0.36 remains report-only; this
note does not grant any live loading authority.

### 6. Gate reports are evidence, not trust

A successful sandbox gate report does not load modules, register actions, alter
routes, grant permissions, enable skills, or set routing context. v0.37 may use
the report as one prerequisite for an operator-confirmed trust grant, but v0.36
itself grants nothing.

### 7. Settings Central owns operator policy

All enablement, backend selection, image selection, and resource bounds are
Settings Central keys with audit records. Facade-level sandbox lifecycle events
also append bounded durable records under `<ALLBERT_HOME>/sandbox/audit`.
Raw reports and draft files are local Allbert Home data, surfaced read-only.

## Consequences

- v0.36 becomes implementation-ready and independently verifiable before the
  higher-risk v0.37 live-loader work starts.
- v0.37 and v0.38 can consume one concrete sandbox/gate-runner interface instead
  of inventing sandbox behavior inside code-gen agents or UI flows.
- gVisor can be adopted opportunistically and, when configured, outranks plain
  Docker without becoming a hard requirement for every developer machine.
- The backend behaviour plus OS-aware resolver keep future engines (broader
  Apple Container support, Firecracker, remote/microVM) behind the facade and
  gate runner, but v0.36 intentionally uses a static reviewed registry/resolver
  rather than settings-driven dynamic backend discovery.
- Apple `container` gives macOS developers VM-per-container isolation when their
  host qualifies, but its pre-1.0 churn is contained behind the doctor gate and
  fallback candidates. Missing Apple support does not block v0.36 release.
- Broader untrusted execution, package-manager execution, remote builders,
  Firecracker, and multi-language targets remain future work.

## Non-Goals

- No LLM code generation agents.
- No live in-core hot-loading.
- No package-manager/dependency installation, implicit image pulls, migrations,
  NIFs, or unrestricted network.
- No remote sandbox or microVM backend.
- No broad shell automation outside explicit Elixir/OTP gate CommandSpecs.

## Relates To

- Amends: ADR 0009 (v0.36 graduates a narrow Level-3 container backend).
- Enables: ADR 0032, ADR 0033, ADR 0035 (v0.37 dynamic generation and gated
  live integration).
- Constrained by: ADR 0006 (Security Central), ADR 0012 (Resource Access),
  ADR 0026-0031 (shared runtime facades), and the AGENTS/DEVELOPMENT
  non-negotiables.
