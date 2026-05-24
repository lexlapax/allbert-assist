# ADR 0009: Local Execution Sandbox Levels

## Status

Accepted.

## Context

Allbert is about to add its first local command execution capability. That
capability sits directly on the architecture boundary described by ADR 0001,
ADR 0006, ADR 0007, and ADR 0008: user intent enters through signals and
channels, agents select registered actions, Security Central evaluates policy,
durable confirmations pause sensitive work, and side effects happen only after
approval and re-check.

"Execution sandbox" can mean several different things:

- an application policy sandbox that decides which command may run
- an OTP-supervised process boundary for lifecycle and observability
- an operating-system isolation boundary, such as containers or microVMs
- a remote execution environment

These are not equivalent. BEAM processes, tasks, supervisors, ports, and
`System.cmd/3` are useful lifecycle tools, but they are not OS security
isolation. A host child process can still read and write according to the host
user's permissions unless Allbert prevents it at the command, path, env, and
adapter boundaries.

Elixir and Erlang documentation support a safer local-process shape:

- use explicit executable plus argv instead of shell interpolation
- set cwd on the command/port rather than changing global BEAM cwd
- pass only the intended environment
- capture output and exit status through command/port options

External agent harnesses show a similar ladder. Hermes documents defense in
depth with command approval, environment filtering, and optional container
backends for production or untrusted workloads. OpenClaw treats host exec as
policy plus allowlist plus optional approval, with fail-closed behavior when an
approval UI is unavailable. OpenHands defaults to Docker for a broad coding
agent, but its docs still make clear that a read-write mounted workspace is
modifiable by the agent.

Allbert needs the first rung now, without pretending it has the later rungs.

Research sources:

- Elixir `System.cmd/3` and `System.shell/2`:
  `https://hexdocs.pm/elixir/System.html`
- Erlang `open_port/2`:
  `https://www.erlang.org/docs/25/man/erlang`
- Hermes security:
  `https://hermes-agent.nousresearch.com/docs/user-guide/security/`
- OpenClaw exec approvals:
  `https://docs.openclaw.ai/tools/exec-approvals`
- OpenHands Docker sandbox:
  `https://docs.openhands.dev/openhands/usage/sandboxes/docker`

## Decision

Allbert will use explicit sandbox levels:

- Level 0, inert planning: no process execution.
- Level 1, local policy sandbox: host process execution is allowed only through
  a registered Jido action with explicit executable/args, allowed cwd roots,
  env allowlist, timeout, output limits, confirmation, redaction, and
  trace/audit records.
- Level 2, trusted project/process sandbox: host execution with stricter
  per-project, per-action, per-skill, and package-manager execution profiles.
- Level 3, container sandbox: Docker, Podman, Linux containers, Mac containers,
  or equivalent local container backend with explicit mounts, user/capability
  constraints, resource limits, and network policy.
- Level 4, remote or microVM isolation: remote builders, cloud sandboxes, or
  microVM-backed execution for hostile code, multi-user deployments, or
  untrusted online imports.

v0.08 implements Level 1 only.

The v0.08 command runner must not use shell strings by default. It must execute
an explicit executable plus argv list, with cwd/env/time/output policy applied
before execution. `sh -c`, `bash -c`, inline interpreter eval, shell chaining,
redirection, glob expansion, command substitution, PTY sessions, background
processes, and long-running daemon control are outside v0.08 unless future
plans introduce a stricter action and policy story.

Containers are intentionally deferred. Docker, Podman, Mac/Linux containers,
and remote sandboxes add useful isolation, but they also add installation,
daemon, image, mount, networking, and cross-platform semantics that would make
v0.08 too large. They can also create false confidence if Allbert bind-mounts
the project directory read-write and forwards credentials. v0.08 should add an
adapter boundary so a future container backend can replace or augment the local
process backend without changing the registered action, confirmation,
Security Central, Settings Central, trace, or audit contracts.

## Consequences

- v0.08 is a real execution release, but not an OS isolation release.
- Operator-facing docs must call this Level 1 local policy sandboxing.
- All execution policy belongs in Settings Central and Security Central, not
  scattered through CLI tasks, LiveViews, skill metadata, or model prompts.
- `run_shell_command` becomes the only shell execution entrypoint.
- `plan_shell_command` remains inert.
- v0.09 skill scripts may consume Level 1 runner primitives, but ADR 0010
  requires selected-skill provenance, resource-inventory matching, digest
  re-checks, confirmation, and script-specific trace/audit metadata.
- v0.10 package installs and external adapters may consume Level 1/Level 2
  policy only through ADR 0011's registered actions, package-manager profiles,
  confirmation, redaction, and audit. Workflows that require untrusted-code
  isolation should be denied or deferred to Level 3 or Level 4 sandbox work.
- Future container and remote sandbox work is tracked in
  `docs/plans/future-features.md`, not smuggled into v0.08.

## v0.36 Amendment: Narrow Level-3 Elixir/OTP Sandbox

v0.36 (`docs/plans/v0.36-plan.md`, ADR 0037) graduates the first Level-3
sandbox in a deliberately narrow form: generated Elixir/OTP drafts and the
explicit `mix` / `elixir` / `erl` argv commands needed to compile, test, and
gate them.

This does not create a broad coding-agent sandbox. v0.36 remains default-off and
selects a backend in an OS-aware way (`backend=auto`): optional doctor-gated
Apple `container` on supported macOS (Apple silicon, macOS 26+,
VM-per-container), rootless Podman where available, Docker `runsc` / gVisor
preferred over plain Docker when configured, and Docker as the fallback.
Backends register through a common behaviour/registry, and the runner fails
closed when no on-platform backend is available. Firecracker, remote builders,
broader/cross-version Apple Container features beyond the optional v0.36
adapter, package-manager execution, implicit image pulls, multi-language
targets, and untrusted script/package-install workflows remain future work.
v0.36 includes an explicit local image build/verify setup task for the default
approved Docker image; sandbox gate execution itself still never pulls images
and fails closed when the approved local image is missing or invalid.

The v0.36 sandbox produces bounded redacted reports only. It does not load
generated modules into the core node, register actions, grant permissions,
enable skills, run migrations, or install dependencies. v0.37 may consume those
reports as evidence for a separate operator-confirmed live integration gate.
