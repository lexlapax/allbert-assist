# Allbert Future Features Parking Lot

This file tracks features that have been identified in plans, ADRs, or
discussion, but are not yet assigned to a concrete roadmap milestone with an
implementation-ready plan.

Use this as a parking lot, not a backlog commitment. When a feature graduates
into `docs/plans/roadmap.md` with a versioned plan, remove or update its entry
here.

## Already Planned Elsewhere

These are deferred from v0.03 or earlier planning but already have roadmap
homes:

- Jido Runtime Convergence Refactor: v0.04.
- Security Central foundation: v0.05.
- Action-backed Allbert skills: v0.06.
- Confirmation workflow: v0.07.
- Local execution sandbox and shell adapter: v0.08.
- Skill script runner: v0.09.
- External services, package installs, online skill import, and the first
  Resource Access Security Posture substrate: v0.10.
- Execution-aware intent contract, Approval Handoff, and resource access
  posture consumers: v0.11.
- Scheduled jobs: v0.12.
- Additional channels: v0.13.
- Memory review and retrieval: v0.14.
- Cross-surface intent enrichment: v0.15.
- Security hardening and evals: v0.16.

Do not duplicate those here unless the future feature is broader than the
existing plan.

## Unassigned Future Features

### Autonomous Skill Creation

Source: origin note, ADR 0003, v0.03 through v0.06 non-goals.

Allbert should eventually help create new skills from traces, repeated tasks,
corrections, or explicit user requests. v0.06 may add a developer-oriented
skill creation/validation helper, but autonomous creation is larger.

Needed before planning:

- stable skill registry and validator
- skill eval fixtures
- review and trust workflow
- trace-to-skill draft workflow
- explicit operator approval before enabling
- policy for generated code versus instruction-only skill drafts


### Dynamic Elixir Code Generation Or Module Loading

Source: v0.03/v0.06 execution-boundary clarification.

Allbert should not auto-generate, compile, or load Elixir modules from
arbitrary skill folders. A future developer tool may scaffold ordinary Elixir
action code, but runtime module loading from user skills is not planned.

Needed before planning:

- separate ADR for code-generation boundaries
- review/compile/test workflow
- explicit distinction between scaffolding code and enabling capability
- rollback and migration story

### Remote Secrets Manager

Source: v0.02 non-goals.

v0.02 uses an encrypted local Settings Central secret store. A future milestone
may add an adapter for an OS keychain, cloud secret manager, or enterprise
vault.

Needed before planning:

- local secret store stability
- provider abstraction for secret backends
- migration/export policy
- offline behavior
- redaction and audit consistency across backends

### Remote Sync And Profile Export/Import

Source: v0.02 non-goals and ADR 0005 consequences.

Allbert Home gives a clear local boundary for backup and migration, but there
is no remote sync or full profile import/export plan yet.

Needed before planning:

- stable Allbert Home layout
- schema/version metadata for settings, memory, skills, cache, and database
- encrypted secret migration policy
- conflict resolution policy
- operator-visible dry run and rollback

### Multi-User Authorization Model

Source: v0.02, v0.07, and v0.12 non-goals.

Allbert is currently a local single-operator assistant. A multi-user model may
matter for shared workspaces, team channels, or hosted deployments.

Needed before planning:

- identity model
- operator/user roles
- per-user Settings Central scope
- per-user memory and channel policy
- audit and confirmation ownership

### Full Settings UI Polish

Source: v0.02 non-goals.

The v0.02 settings LiveView is functional by design. A future product/UI
milestone may make Settings Central easier to browse, search, validate, and
operate.

Needed before planning:

- stable settings schema
- operator workflows from real usage
- grouping, search, validation, and audit navigation design
- secret entry UX
- accessibility and mobile behavior

### Browser/Search Capture

Source: origin note and v0.13 candidate channels.

The origin note describes capturing searches or browsing activity and turning
useful context into memory. v0.11 owns the Resource Access Security Posture for
approved URL/document consumers, and v0.13 gives browser/search capture a
possible channel-adapter home. Browser capture is still broader than approved
URL fetches: it may involve page state, user sessions, cookies, interactive
navigation, screenshots, or memory promotion, so it remains parked until
channel adapters and security hardening are ready.

Needed before planning:

- channel adapter foundation
- external network/browser permission policy
- v0.10 resource reference and remembered grant smoke coverage as the baseline
  for URL/document consumers
- memory review workflow
- sensitive-data detection and confirmation
- traceable extraction path

### Deep Remote Document Extraction

Source: v0.11 Resource Access Security Posture planning.

v0.11 should let the system represent and approve requests like "check this
URL and summarize it" through resource access posture. That does not mean every
local or remote document type is deeply parsed in the same release. Broad
document handling may need a later focused milestone once the first approved
read/fetch/extract/summarizer handoff is boring.

Needed before planning:

- stable resource access reference and approval scope records
- v0.10 M7/M8 resource references and remembered grants accepted through the
  M9 release-readiness baseline
- bounded content cache/digest policy
- extractor contracts for HTML, markdown, plain text, PDF, office documents,
  archives, and unknown binary content
- prompt-injection and data-exfiltration posture for fetched content sent to
  summarizers
- unsupported-format and partial-extraction UX
- tests for size caps, content-type mismatches, malformed files, redirects,
  private-network targets, and redacted traces

### Small-Model Memory Or Personality Distillation

Source: origin note and roadmap future research.

The origin note imagines compiled memory, nightly distillation, or a small
personal model. This remains research until memory review, trace quality, and
retrieval are stable.

Needed before planning:

- reviewed markdown memory corpus
- rebuildable derived artifacts
- evals for personality and recall quality
- privacy and deletion policy
- training cost and reproducibility policy

### Native UI Surface

Source: origin note and v0.13 candidate channels.

Native UI is listed as a possible channel but has no dedicated plan. It should
not be planned before the channel adapter contract is stable.

Needed before planning:

- channel adapter contract
- Settings Central channel preferences
- authentication or local operator identity policy
- confirmation handoff behavior
- packaging/release approach


### Scripting Engine Interface

Source: origin note, v0.03 through v0.06 non-goals, and v0.09 boundaries.

The origin note leaves room for Lua, Python, JavaScript, or another scripting
interface. Elixir remains the runtime substrate for now; no scripting engine is
currently planned. v0.09 runs trusted, inventoried Agent Skill script
resources through `run_skill_script`; that does not graduate a general
scripting engine, dependency installer, or untrusted code runtime.
After v0.09, this boundary is tested capability rather than only planning:
trusted inventoried scripts may run after confirmation, but arbitrary language
runtime access, dependency bootstrap, and untrusted-code execution remain
future work.

Needed before planning:

- clear use cases that are not better served by Jido actions
- sandbox and dependency policy
- permission and confirmation integration
- trace and audit integration
- install/update story for runtime dependencies

### Container And Remote Execution Sandboxes

Source: v0.08 planning and ADR 0009.

v0.08 intentionally implements only Level 1 local policy sandboxing: confirmed
host process execution through registered actions, Settings Central execution
policy, Security Central decisions, output limits, redaction, and trace/audit.
That is useful for a first local shell adapter, but it is not OS isolation and
should not be described as protecting the host from hostile code.

Future work should add deeper execution backends when Allbert needs to run
untrusted scripts, package installs, broad coding workflows, online skill
bootstrap, multi-user workloads, or network-heavy adapters.

Candidate levels:

- Level 2 trusted project/process sandbox: still host execution, but with
  per-project execution profiles, stricter command/package-manager allowlists,
  scoped temp/work roots, and skill/action-specific env passthrough.
- Level 3 local container sandbox: Docker, Podman, Linux containers, Mac
  containers, or another local container backend with explicit bind mounts,
  non-root user policy, capability drops, resource limits, and network policy.
- Level 4 remote or microVM isolation: remote builders, cloud sandboxes, or
  microVM-backed execution for hostile code, untrusted imports, hosted
  deployments, or multi-user isolation.

Questions to resolve before graduation:

- which workflows require stronger isolation than Level 1
- whether the first container backend should be Docker, Podman, Mac containers,
  a Linux-only container adapter, or a remote sandbox
- how Allbert maps host paths to sandbox paths without over-mounting
  user-owned data
- whether workspace mounts are read-only, read-write, or copy-in/copy-out
- default network posture and how external service policy composes with it
- CPU, memory, process, disk, and wall-clock limits
- UID/GID, rootless mode, capabilities, seccomp/AppArmor availability, and
  macOS portability
- image provenance, update, vulnerability, and cache policy
- credential/env/file passthrough policy through Settings Central secrets
- how traces/audits represent host path, sandbox path, mount, image, backend,
  network, and resource-limit metadata
- cleanup, persistence, rollback, and recovery when a container or remote
  sandbox fails

v0.10 implementation clarifies the first split:

- bounded HTTP/service calls can proceed through `Req`, SSRF-style policy,
  confirmation, redaction, and audit without claiming OS isolation
- npm package installs can proceed only through registered package-manager
  actions, explicit argv, exact package specs, package-manager profiles, target
  roots, disabled lifecycle scripts, `--allow-git=none`, confirmation, and
  audit
- pip execution should remain preview/audit-only until strict hash, binary,
  pinned requirement, and target policy are implemented and tested
- imported online skills must remain disabled and untrusted; untrusted imported
  code execution remains a deeper sandbox problem, not a v0.10 capability
- CLI, `/settings`, traces, and audits now expose the v0.10 request/result
  metadata needed to decide which workflows need deeper sandboxing later
- v0.11 Resource Access Security Posture should decide whether a local or
  remote resource is being summarized, inspected, imported as a skill, used for
  package metadata, or executed as a trusted skill script before any downstream
  consumer acts
- v0.10 M9 preserves the current operator smoke baseline for deciding when a
  future workflow needs deeper sandboxing instead of only registered actions,
  policy, confirmation, redaction, and audit

This should become a versioned roadmap item only after v0.10's actual external,
package, and import traces show which workflows cannot be made acceptable with
registered actions, Settings Central policy, Security Central, confirmation,
Level 1/Level 2 host controls, redaction, and audit alone.

## Review Cadence

Review this file when:

- closing a roadmap release
- adding a new roadmap milestone
- converting a non-goal into planned work
- discovering a repeated operator request that does not fit the current
  roadmap
