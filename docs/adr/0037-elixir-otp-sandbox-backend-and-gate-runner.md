# ADR 0037: Elixir/OTP Sandbox Backend And Gate Runner

## Status

Proposed for v0.36 Elixir/OTP Sandbox And Gate Runner
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
- Apple's `container` / Containerization stack is promising on Apple silicon
  but currently macOS-version-specific and should remain a future adapter.

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

The allowed command surface is a structured executable plus argv for `mix`,
`elixir`, and `erl` gate profiles. There is no shell-string command execution,
no `sh -c`, no chaining, no redirection, no glob expansion, no PTY, no daemon
control, and no broad shell automation.

### 2. Backend contract is container-first

The first supported backends are:

- Docker;
- rootless Podman where available;
- optional Docker + `runsc` / gVisor when configured.

Every backend must enforce the same Allbert policy: no network by default, no
host Docker socket, no privileged mode, no host PID/user/network namespace, no
real Allbert Home mount, no secrets, dropped capabilities, resource limits,
output limits, cleanup, and typed audit metadata.

If no backend is configured or available, sandbox actions fail closed. There is
no fallback to BEAM processes, hidden nodes, ports, or host execution for
untrusted generated code.

### 3. Copy-in/copy-out is mandatory

The sandbox receives a disposable bundle containing only allow-listed project,
draft, and test inputs plus a disposable `ALLBERT_HOME`. Reports are copied out
as bounded structured data. The sandbox never receives the operator's real
settings, secrets, database, memory files, caches, or arbitrary host paths.

### 4. Gate reports are evidence, not trust

A successful sandbox gate report does not load modules, register actions, alter
routes, grant permissions, enable skills, or set routing context. v0.37 may use
the report as one prerequisite for an operator-confirmed trust grant, but v0.36
itself grants nothing.

### 5. Settings Central owns operator policy

All enablement, backend selection, image selection, and resource bounds are
Settings Central keys with audit records. Raw reports and draft files are local
Allbert Home data, surfaced read-only.

## Consequences

- v0.36 becomes implementation-ready and independently verifiable before the
  higher-risk v0.37 live-loader work starts.
- v0.37 and v0.38 can consume one concrete sandbox/gate-runner interface instead
  of inventing sandbox behavior inside code-gen agents or UI flows.
- gVisor can be adopted opportunistically without making it a hard requirement
  for every developer machine.
- Broader untrusted execution, package-manager execution, remote builders,
  Firecracker, Apple Container, and multi-language targets remain future work.

## Non-Goals

- No LLM code generation agents.
- No live in-core hot-loading.
- No package-manager/dependency installation, migrations, NIFs, or unrestricted
  network.
- No remote sandbox or microVM backend.
- No broad shell automation outside explicit Elixir/OTP gate CommandSpecs.

## Relates To

- Amends: ADR 0009 (v0.36 graduates a narrow Level-3 container backend).
- Enables: ADR 0032, ADR 0033, ADR 0035 (v0.37 dynamic generation and gated
  live integration).
- Constrained by: ADR 0006 (Security Central), ADR 0012 (Resource Access),
  ADR 0026-0031 (shared runtime facades), and the AGENTS/DEVELOPMENT
  non-negotiables.
