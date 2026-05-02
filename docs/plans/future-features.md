# Allbert Future Features Parking Lot

This file tracks features that have been identified in plans, ADRs, or
discussion, but are not yet assigned to a concrete roadmap milestone with an
implementation-ready plan.

Use this as a parking lot, not a backlog commitment. When a feature graduates
into `docs/plans/roadmap.md` with a versioned plan, remove or update its entry
here.

## Already Planned Elsewhere

These are deferred from v0.03 or v0.04 but already have roadmap homes:

- Confirmation workflow: v0.05.
- Scheduled jobs: v0.06.
- Additional channels: v0.07.
- Memory review and retrieval: v0.08.
- Intent engine enrichment: v0.09.
- Action-backed Allbert skills: v0.04.

Do not duplicate those here unless the future feature is broader than the
existing plan.

## Unassigned Future Features

### Sandboxed Skill Script Execution

Source: v0.03 and v0.04 non-goals.

Agent Skills can include `scripts/`, but v0.03 only inventories them and v0.04
still refuses script execution. A future milestone may add a sandboxed runner
for selected skill scripts.

Needed before planning:

- confirmation workflow is stable
- action lifecycle runner is stable
- trace format records script source, args, outputs, permissions, and failures
- sandbox policy is defined for filesystem, network, process, timeout, and
  environment access
- script execution is represented as a registered Allbert/Jido action, not as
  ambient model authority

### Shell Command Execution Adapter

Source: v0.01 through v0.06 non-goals and roadmap dependency notes.

Allbert can currently plan or refuse shell commands, but it cannot execute
them. A future milestone may add explicit shell execution for trusted,
confirmed, traceable commands.

Needed before planning:

- confirmation workflow
- command permission classes and policy settings
- sandbox or working-directory constraints
- stdout/stderr capture and redaction rules
- audit and trace records
- denial behavior for destructive or ambiguous commands

### External Network Execution Adapters

Source: v0.01, v0.03, v0.04, v0.05, and v0.06 non-goals.

Allbert currently recognizes network requests but does not make external calls
on behalf of the user. Future adapters may support HTTP/API calls, browser
capture, search, or provider-specific integrations.

Needed before planning:

- confirmation-aware network permission model
- Settings Central provider credentials and redaction rules
- request/response trace shape
- rate limit and cost visibility policy
- allowlist/blocklist policy
- `Req`-based adapter guidelines

### skills.sh Search, Audit, And Import Adapter

Source: v0.03 skills.sh import policy.

v0.03 should work from local skill directories and skills already installed by
other tools. A future milestone may add skills.sh search, detail, audit, and
import support.

Needed before planning:

- external network confirmation
- imported skill cache policy
- trust workflow for imported skills
- audit-risk display in CLI and LiveView
- install/update/rollback behavior
- decision on whether to call skills.sh APIs directly with `Req`, delegate to
  `npx skills`, or support both

### Autonomous Skill Creation

Source: origin note, ADR 0003, v0.03 and v0.04 non-goals.

Allbert should eventually help create new skills from traces, repeated tasks,
corrections, or explicit user requests. v0.04 may add a developer-oriented
skill creation/validation helper, but autonomous creation is larger.

Needed before planning:

- stable skill registry and validator
- skill eval fixtures
- review and trust workflow
- trace-to-skill draft workflow
- explicit operator approval before enabling
- policy for generated code versus instruction-only skill drafts


### Dynamic Elixir Code Generation Or Module Loading

Source: v0.03/v0.04 execution-boundary clarification.

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

Source: v0.02, v0.05, and v0.06 non-goals.

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

Source: origin note and v0.01 non-goals.

The origin note describes capturing searches or browsing activity and turning
useful context into memory. This is not yet assigned to a milestone.

Needed before planning:

- channel adapter foundation
- external network/browser permission policy
- memory review workflow
- sensitive-data detection and confirmation
- traceable extraction path

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

Source: origin note and v0.07 candidate channels.

Native UI is listed as a possible channel but has no dedicated plan. It should
not be planned before the channel adapter contract is stable.

Needed before planning:

- channel adapter contract
- Settings Central channel preferences
- authentication or local operator identity policy
- confirmation handoff behavior
- packaging/release approach


### Scripting Engine Interface

Source: origin note and v0.03/v0.04 non-goals.

The origin note leaves room for Lua, Python, JavaScript, or another scripting
interface. Elixir remains the runtime substrate for now; no scripting engine is
currently planned.

Needed before planning:

- clear use cases that are not better served by Jido actions
- sandbox and dependency policy
- permission and confirmation integration
- trace and audit integration
- install/update story for runtime dependencies

## Review Cadence

Review this file when:

- closing a roadmap release
- adding a new roadmap milestone
- converting a non-goal into planned work
- discovering a repeated operator request that does not fit the current
  roadmap
