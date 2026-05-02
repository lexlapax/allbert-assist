# Allbert Roadmap

This roadmap is the running planning index for Allbert. The long-term vision is
captured in `docs/plans/allbert-jido-vision.md`; implementation-ready milestone
plans live alongside this file. Identified but unassigned future work lives in
`docs/plans/future-features.md`.

## Vision

Allbert is a personal assistant runtime that grows with its user. The core
direction is Elixir/OTP plus Jido: supervised processes, signal-driven
coordination, Jido agents for intent and delegation, Jido actions for validated
capabilities, and markdown-first memory that remains inspectable and portable.

Status: vision drafted.

## v0.01: First Local Assistant Loop

Plan: `docs/plans/v0.01-plan.md`
Request flow: `docs/plans/v0.01-request-flow.md`

Status: complete. Milestones 1 and 2 are complete and tested; Milestone 3 is
complete, tested, and operator-verified; Milestone 4 is complete, tested, and
operator-verified; Milestones 5, 5.1, 6, and 7 are complete and tested.

Summary:

- Clean the formatter/precommit baseline. Complete.
- Introduce a signal-first runtime boundary. Complete.
- Add the first primary intent agent. Complete.
- Add explicit Jido actions and a permission gate. Complete.
- Add markdown memory v0. Complete.
- Add deterministic personal preference heuristics. Complete.
- Record traces and basic cost/diagnostic metadata. Complete.
- Expose the same loop through CLI/REPL and Phoenix LiveView. Complete.

Current operator loop:

- `AllbertAssist.Runtime.submit_user_input/1` accepts local user input and
  emits `allbert.input.received` / `allbert.agent.responded` log signals.
- The default runtime path uses `AllbertAssist.Agents.IntentAgent` with a
  deterministic v0.01 action surface for direct answers, memory intent
  selection, skill inspection, and inert shell-command planning.
- `AllbertAssist.Security.PermissionGate` records explicit permission decisions
  for read-only work, memory-write intent, command planning, blocked command
  execution, and external network confirmation.
- `AllbertAssist.Memory` stores explicit memories as user-readable markdown.
  v0.01 used `ALLBERT_MEMORY_ROOT` or `var/allbert/memory`; v0.02 supersedes
  that default with `<ALLBERT_HOME>/memory` while preserving temp root
  overrides for tests and operator escape hatches.
- Basic identity and preference statements, such as "my name is Sandeep" and
  "I prefer short updates", flow through the same markdown memory path with
  conservative heuristics.
- When tracing is enabled, runtime turns write inspectable markdown traces under
  the memory `traces` category and return the trace path in `response.trace_id`.
- `mix allbert.ask` provides the first terminal entrypoint over the same runtime
  core.
- The `/agent` LiveView uses the same runtime boundary and displays the
  response, status, signal id, and trace path when available.

Exit signal: Allbert can remember something, recall recent memory, explain or
select a safe action, and leave an inspectable trace from both CLI and web UI.

Next milestone: v0.02 Allbert Home, Settings Central, Secrets, And Operator
Profile.

## Dependency Reassessment After v0.01

The origin and vision both point at the same growth path: a small kernel first,
then operator settings, inspectable skills and actions, confirmations, jobs,
channels, memory curation, and only later richer intent or more autonomous
execution.

v0.01 completed the first kernel slice. The important remaining foundation is
not more UI, embeddings, or command execution. The next missing layer is a
canonical Allbert home, a settings engine, and then skills compatibility plus
durable capability contracts:

- where durable local runtime data lives
- which settings exist, who changed them, and which layer supplied them
- which user-supplied provider credentials are configured, without exposing
  raw secret values
- which provider/model profiles exist
- which skills exist
- where they came from and whether the source is trusted
- what `SKILL.md` instructions and bundled resources they expose
- which Allbert/Jido actions they are allowed to invoke, if any
- which permissions those actions require
- which confirmations are needed
- what memory and trace effects they produce
- how those capabilities appear to the intent agent, CLI, LiveView, jobs, and
  future channels

That contract should come before scheduled jobs, richer automation, external
network access, shell execution, or autonomous skill creation. Otherwise those
features will each invent their own private capability rules.

Dependency order from here:

1. Allbert Home plus Settings Central, secrets, provider/model profiles, and
   operator profile.
2. Agent Skills-compatible parsing, discovery, trust, and activation.
3. Jido Runtime Convergence so internal runtime/domain operations share
   signals, agents, action boundaries, and lifecycle metadata.
4. Security Central as the shared policy, risk, redaction, audit, and trust
   boundary evaluator.
5. Action-backed Allbert skills and capability translation.
6. Confirmation workflow for sensitive capabilities.
7. Local execution sandbox and confirmed shell execution.
8. Trusted skill script execution through the same sandbox.
9. External service, package-install, and online skill import adapters.
10. Execution-aware intent decisions over real risky capabilities.
11. Scheduled jobs that emit signals into the same runtime.
12. Additional channels that translate messages into the same runtime.
13. Memory review, summarization, and retrieval improvements.
14. Cross-surface intent enrichment over real skills, actions, permissions,
    confirmations, jobs, channels, and memory behavior.
15. Security hardening and evals after real execution, import, channel, job,
    memory, and intent behavior exists.

`config.exs` remains deployment and boot configuration. It should not become
the user/operator settings surface. `ALLBERT_HOME` is bootstrap configuration:
the local root for settings, encrypted secrets, memory, database files, user
skills, caches, and temporary runtime data. Allbert needs a domain settings
engine that can be read and changed through CLI, LiveView, future channels, and
traces. The current runtime dependency set is almost enough, but direct YAML
parse/write dependencies are reasonable v0.02 dependencies if settings use
YAML; v0.03 will need YAML parsing for Agent Skills frontmatter anyway. Jido
remains the right substrate, `Req` remains the preferred HTTP client for
external adapters, and scripting should enter only as confirmed action-backed
execution, not as ambient authority from a skill declaration.

## v0.02: Allbert Home, Settings Central, Secrets, And Operator Profile

Plan: `docs/plans/v0.02-plan.md`
Request flow: `docs/plans/v0.02-request-flow.md`

Status: complete.

Expected direction:

- Add `AllbertAssist.Paths` and make `ALLBERT_HOME` the canonical local root,
  defaulting to `~/.allbert` with `ALLBERT_HOME_DIR` as an accepted alias.
- Store settings, encrypted secrets, memory, local database, user skills,
  imported caches, and temporary runtime data under Allbert Home by default.
- Add a typed, file-backed settings subsystem for user/operator domain
  settings.
- Keep deployment config in `config.exs` and environment variables.
- Store user-supplied API keys through the Settings Central secret store,
  encrypted at rest and redacted everywhere they are displayed.
- Add layered settings resolution: defaults, deployment overrides, operator,
  project, channel, and request/session.
- Add settings namespaces for operator profile, runtime, providers, model
  profiles, skills, permissions, channels, jobs, and memory policy.
- Expose settings through runtime actions plus CLI and LiveView surfaces.
- Validate and audit settings writes.

Exit signal: Allbert has one local home directory and one operator-facing
settings center that can be used by CLI, LiveView, future channels, skill
trust, confirmation policy, jobs, and memory review without scattering paths or
settings across subsystems.

## v0.03: Agent Skills Substrate

Plan: `docs/plans/v0.03-plan.md`
Request flow: `docs/plans/v0.03-request-flow.md`

Status: released as v0.03. Milestones 1 through 6 are complete and tested.
v0.04, Jido Runtime Convergence Refactor, has since been released.

Expected direction:

- Adopt the open Agent Skills `SKILL.md` folder format as Allbert's external
  and native skill authoring format.
- Add the substrate that parses standard skills into internal skill records,
  activation context, trust state, resource inventories, and diagnostics.
- Load built-in, project, user, and imported skills from predictable
  Agent-Skills-compatible directories.
- Route list/read/activate skill behavior through the registry instead of the
  current static in-code list.
- Use a dedicated `activate_skill` action/tool so Allbert can enforce trust,
  wrap instructions, list resources, and trace activation.
- Keep bundled scripts and external package installation non-executable in
  v0.03; they may be inspected, planned, and traced, but not run.
- Parse Allbert-specific metadata as inert contract data, but do not yet use it
  to drive action execution.

Current implementation:

- `AllbertAssist.Skills.Parser` parses standard Agent Skill directories with
  `SKILL.md` YAML frontmatter and markdown bodies.
- `AllbertAssist.Skills.AgentSkillSpec` stores parsed manifests, optional
  metadata, body text, external fields, diagnostics, and inert resource
  inventory.
- `AllbertAssist.Skills.Resource` inventories files under `scripts/`,
  `references/`, and `assets/` without execution.
- Parser tests cover valid standard skills, Allbert metadata, invalid YAML,
  missing required fields, duplicate names, resources, and scripts.
- `AllbertAssist.Skills.Registry` discovers bounded skill directories, applies
  trust and enablement policy, resolves duplicates, reserves built-in names,
  and reports skipped declarations through diagnostics.
- `AllbertAssist.Skills.Skill` and
  `AllbertAssist.Skills.CapabilityContract` represent normalized skill records
  and inert Allbert metadata contracts.
- Settings Central now validates and writes `skills.scan_paths`,
  `skills.trusted_project_roots`, `skills.enabled`, `skills.disabled`, and
  `skills.imported_cache_policy`.
- `list_skills` and `read_skill` use the registry.
- Built-in skill wrappers now live under `apps/allbert_assist/priv/skills/`
  as standard `SKILL.md` declarations with inert Allbert metadata. The
  temporary `:built_in_legacy` bridge remains only as a defensive fallback when
  no built-in declarations are packaged.
- `activate_skill` loads trusted skill instructions through progressive
  disclosure, returns resource inventory metadata, preserves inert capability
  contracts, and refuses missing or hidden skills with a structured not-found
  response.
- Traces now render selected skill metadata explicitly in the runtime turn
  header and in a dedicated `## Skill Metadata` section.
- CLI and LiveView operator tests cover registry-backed skill list/read and
  activation through the shared runtime boundary.

Exit signal: Allbert can discover standard Agent Skills, activate their
instructions through progressive disclosure, show source/trust/diagnostics, and
trace skill activation without granting any new unsafe capability.

Exit status: complete.

## v0.04: Jido Runtime Convergence Refactor

Plan: `docs/plans/v0.04-plan.md`
Request flow: `docs/plans/v0.04-request-flow.md`
ADR: `docs/adr/0007-jido-native-internal-runtime-boundaries.md`

Status: released as v0.04.

Implemented direction:

- Adopt Boundary Actions as the runtime rule: externally invoked, effectful,
  security-relevant, or observable domain operations enter through signals,
  internal agents or runtime routers, and registered Jido actions.
- Keep pure parsing, schema, validation, formatting, and storage helpers as
  plain Elixir behind action boundaries.
- Add the shared action runner that emits consistent
  `allbert.action.requested` and `allbert.action.completed` metadata.
- Remove direct-call debt in `IntentAgent`, Settings LiveView,
  `mix allbert.settings`, and runtime trace recording.
- Add action-backed settings/model/provider surfaces and an internal
  `record_trace` action while keeping pure modules plain.
- Add no new execution powers.

Exit signal: Allbert's docs and implementation plan make the Jido boundary
mandatory for runtime-facing domain behavior without wrapping pure helper
modules in unnecessary agents.

Closeout signal: v0.04 kept user-visible behavior stable while routing
intent actions, settings surfaces, provider credentials, and trace recording
through registered actions and shared runner lifecycle metadata. v0.05
Security Central can consume this boundary without reopening the v0.04
architecture decision.

## v0.05: Security Central Foundation

Plan: `docs/plans/v0.05-plan.md`
Request flow: `docs/plans/v0.05-request-flow.md`
ADR: `docs/adr/0006-security-central.md`

Status: released as v0.05.

Implemented scope:

- Added Security Central as the shared security evaluation surface.
- Consumed the v0.04 action/runtime boundary instead of creating private
  security policy paths in CLI, LiveView, jobs, or channels.
- Kept Settings Central as policy and secret storage; Security Central reads
  settings, skill trust, secret status, and runtime context.
- Defined security context, decisions, policy resolution, risk tiers, redaction,
  audit event shape, trust/provenance summary, and operator-visible security
  status.
- Kept `AllbertAssist.Security.PermissionGate.authorize/2` as a compatibility
  entrypoint that delegates to Security Central while preserving current
  fields and behavior.
- Preserved v0.04's existing action runner and lifecycle signals; v0.05 widens
  decision metadata rather than replacing the runner.
- Added built-in safety floors so Settings Central can tighten policy but cannot
  prematurely grant shell, script, package-install, network, online-import, raw
  secret-read, unknown-action, or unknown-permission authority.
- Added Security & Permissions status to `/settings`: permission settings remain
  editable through Settings Central actions, while effective Security Central
  decisions, safety floors, trust, secret status, and redaction posture are
  displayed read-only.
- Added no new execution powers.

Exit signal: Allbert can make and explain structured security decisions with
permission, risk, confirmation, redaction, audit, trace, actor/channel/session,
selected skill/action, and trust boundary metadata.

v0.06 handoff: action-backed skills should consume the implemented
`AllbertAssist.Security` decision shape, selected skill trust/provenance
context, registered action metadata, known permission classes, and safety-floor
capped Settings Central policy. Skill metadata still never grants permission by
itself.

## v0.06: Action-Backed Allbert Skills

Plan: `docs/plans/v0.06-plan.md`
Request flow: `docs/plans/v0.06-request-flow.md`

Status: released as v0.06 on 2026-05-02. Milestones 1 through 6 are complete
and tested.

Release tag: `v0.06`.

Expected direction:

- Promote trusted Allbert metadata overlays from inert capability contracts
  into validated action bindings.
- Map capability skills only to registered Jido actions and known Security
  Central permission classes.
- Treat built-in Allbert skills as standard `SKILL.md` wrappers around
  registered Elixir/Jido actions; do not auto-convert skill files or scripts
  into executable modules.
- Use the existing v0.04 action lifecycle runner that emits
  `allbert.action.requested` and `allbert.action.completed`.
- Wire action-backed built-in skills through the current conservative intent
  routing while preserving v0.01 safety behavior.
- Keep trusted non-built-in capability candidates validation-first unless an
  explicit deterministic router binding exists for their action and parameter
  shape.
- Keep `activate_skill` as progressive-disclosure context loading; activation
  does not execute the activated skill's declared action.
- Add the first Allbert skill creation/validation workflow for standard
  `SKILL.md` directories that reference only existing registered action names
  and known permission classes. Complete for local operator helpers through
  `mix allbert.skills`, registered helper actions, and the `:skill_write`
  Settings Central/Security Central policy surface.

Current implementation:

- Action capability metadata and contract validation are implemented through
  `AllbertAssist.Actions.Registry`, `AllbertAssist.Actions.Capability`, and
  `AllbertAssist.Skills.CapabilityContract`.
- Registry list/read/activation output surfaces contract validation and keeps
  invalid contracts inspectable but non-executable.
- Deterministic built-in routes validate selected skill/action contracts before
  invoking `Actions.Runner.run/3`.
- Runner, signal, trace, and Security Central metadata include selected skill,
  contract validation, action capability, permission decision, risk, and
  outcome context.
- `validate_skill` and `create_skill` are registered operator helper actions;
  they are intentionally excluded from the intent-agent tool surface.
- Local skill scaffolds write only standard `SKILL.md` files and do not create
  scripts, modules, package manifests, network adapters, online imports, or
  trust escalation.

Exit signal: Allbert can explain, activate, and run action-backed built-in
skills through registered Jido actions with Security Central decisions and
trace metadata, while still refusing or deferring unsafe execution.

v0.07 handoff: confirmation workflow should consume the v0.06 action
capability metadata, selected skill contract summaries, `:skill_write`
permission policy, and existing external-network confirmation requirement
without moving shell, script, package-install, network, or import execution
forward prematurely.

Closeout signal: v0.06 passed focused milestone tests, closeout `rg`
architecture checks, operator smoke against a disposable Allbert home,
`mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix credo --strict`, `mix dialyzer`, and `mix precommit`.

## v0.07: Confirmation Workflow

Plan: `docs/plans/v0.07-plan.md`
Request flow: `docs/plans/v0.07-request-flow.md`
ADR: `docs/adr/0008-durable-confirmation-requests.md`

Status: released and tagged as `v0.07` on 2026-05-02.

Expected direction:

- Add durable pending capability requests for registered actions that receive a
  Security Central `:needs_confirmation` decision.
- Store confirmation records under Allbert Home with redacted params, selected
  skill/action/capability metadata, Security Central decisions, runner/signal
  context, origin channel, resolver channel, trace ids, and audit links.
- Add Settings Central confirmation preferences for TTL, expiration, display,
  and enabled approval surfaces.
- Let CLI and LiveView list, show, approve, deny, and expire the same pending
  requests through registered Jido actions and `Actions.Runner.run/3`.
- Re-check Security Central on approval and resume only the original eligible
  registered target action. Approval of unavailable adapters records
  `adapter_unavailable` and performs no target side effect.
- Treat CLI and LiveView as the first two channels in a channel-aware workflow:
  requests remember where they originated, resolutions remember where they
  happened, and future channels consume the same queue.
- Persist requested, approved, denied, expired, and adapter-unavailable
  outcomes in traces and human-inspectable audit records.
- Keep command execution, skill scripts, package installs, online imports, and
  real external network calls inert.

Milestones:

- M1: complete. Confirmation domain, Allbert Home paths, store, Settings
  Central keys, and ADR alignment.
- M2: complete. Registered confirmation actions and
  `mix allbert.confirmations` CLI.
- M3: complete. Pending creation from confirmation-needed actions, starting
  with `external_network_request`.
- M4: complete. Approval resume semantics, target policy re-check, and
  adapter-unavailable behavior.
- M5: complete. LiveView confirmation surface over the same action boundary.
- M6: complete. Trace, audit, cleanup, release docs, version metadata, and
  release gate.

Exit signal: Allbert can pause sensitive registered actions as durable pending
requests, let the operator approve or deny them from CLI or LiveView, record
the result in traces/audit, and still avoid any new risky execution adapter.

Closeout signal: v0.07 passed focused milestone tests, full warning gates,
precommit, diff checks, and disposable-home operator smoke. The app versions
are bumped to `0.7.0`. External-network approvals resolve as
`adapter_unavailable` with operator-facing output that explains the approval
was recorded but no adapter ran; v0.08 should replace that baseline only for a
registered confirmed shell adapter with sandbox policy.

## v0.08: Local Execution Sandbox And Shell Adapter

Plan: `docs/plans/v0.08-plan.md`
Request flow: `docs/plans/v0.08-request-flow.md`
ADR: `docs/adr/0009-local-execution-sandbox-levels.md`

Status: implementation-ready after v0.07 release/tag on 2026-05-02.

Expected direction:

- Add the first real local execution boundary for confirmed shell commands:
  Level 1 local policy sandboxing, not OS/container isolation.
- Represent shell execution as registered Jido actions, not as skill metadata
  or arbitrary model authority.
- Restrict executable/argv, working roots, environment access, timeout, output
  capture, and destructive ambiguity through Security Central and Settings
  Central policy.
- Cover local shell execution as a general command framework: conservative
  default read-only commands plus explicitly operator-profiled local developer
  commands, all still confirmed and policy checked.
- Require the v0.07 confirmation flow for command execution and record redacted
  stdout/stderr, security decisions, and sandbox metadata in traces.
- Add a local runner adapter boundary so later Docker, Podman, Mac/Linux
  container, remote, or microVM backends can be introduced without changing the
  action, confirmation, Security Central, Settings Central, trace, or audit
  contracts.

Milestones:

- M1: Sandbox ADR, Settings Central execution policy, command spec, and
  conservative classification.
- M2: Level 1 local process runner with explicit executable/argv, cwd, env
  allowlist, timeout, output cap, and redaction.
- M3: Registered `run_shell_command` action and v0.07 confirmation resume.
  Complete in implementation: shell approvals now resume only the shell target
  after Security Central re-check and record target result metadata.
- M4: CLI and `/settings` operator surfaces over the same action boundary.
  Complete in implementation: `mix allbert.exec`, prompt routing,
  confirmation display, and `/settings` now expose shell command/result
  metadata without bypassing actions.
- M5: Trace, audit, release docs, version metadata, focused tests, and final
  warning gates.

Exit signal: Allbert can execute an explicitly confirmed shell command through
a registered action, inside a bounded Level 1 local policy sandbox, with denial
defaults, redacted output, and inspectable trace/audit records. It does not
claim Docker/Podman/container/microVM isolation in this release.

## v0.09: Skill Script Runner

Plan: `docs/plans/v0.09-plan.md`

Status: placeholder.

Expected direction:

- Add a confirmed `run_skill_script` path for trusted, enabled, inventoried
  Agent Skill scripts.
- Resolve script paths only from the selected skill's v0.03 resource inventory.
- Run scripts through the v0.08 Level 1 local execution sandbox and v0.07
  confirmation workflow, adding skill provenance, resource digest, script path,
  and capability-contract checks before execution.
- Continue to forbid runtime module loading, package installs, network calls,
  and non-inventoried script execution unless a later registered action adds
  that capability.
- Reassess whether any script profiles need Level 2 project/process sandboxing
  before enabling broader script classes.

Exit signal: Allbert can run a bundled skill script only when the skill is
trusted, enabled, selected, inventoried, confirmed, sandboxed, and traced.

## v0.10: External Services, Package Installs, And Online Skill Import

Plan: `docs/plans/v0.10-plan.md`

Status: placeholder.

Expected direction:

- Add confirmed `Req`-based external service actions with Settings Central
  credentials, allow/block policy, redaction, rate/cost visibility, and traces.
- Add package-install actions with stricter confirmation and sandbox policy than
  ordinary shell execution; reassess whether package installs require Level 2
  execution profiles or Level 3 container isolation before enabling broad
  install workflows.
- Add skills.sh or remote-source search, detail, audit, and import support.
- Write imported skills only under `<ALLBERT_HOME>/cache/skills`; keep them
  disabled and pending until parsed, validated, audited, enabled, and trusted.

Exit signal: Allbert can search, audit, and import online skills and call
approved external services through confirmed registered actions without making
imports or package manifests executable by themselves.

## v0.11: Execution-Aware Intent Contract

Plan: `docs/plans/v0.11-plan.md`

Status: placeholder.

Expected direction:

- Introduce a structured intent decision contract with selected intent,
  confidence, candidate skills/actions, permission class, confirmation need,
  risk summary, execution mode, alternatives, and diagnostics.
- Cover shell, skill script, package install, external service, and online skill
  import flows first.
- Validate every decision against known skills, registered actions, known
  permissions, confirmation state, Security Central, and Settings Central
  policy.
- Keep execution behind the existing action runner and Security Central.

Exit signal: Allbert can explain why it selected, confirmed, denied, or refused
a risky local or external capability before jobs and channels consume those
capabilities.

## v0.12: Scheduled Jobs

Plan: `docs/plans/v0.12-plan.md`

Status: placeholder.

Expected direction:

- Add cron-like jobs that emit signals into the same runtime.
- Start with registry health checks, trace summaries, and low-risk daily
  briefs.
- Use settings for timezone, active/paused state, and schedule policy.
- Keep scheduled jobs observable through traces and registered skills/actions.
- Pause risky job actions for confirmation instead of running invisibly.

## v0.13: Additional Channels

Plan: `docs/plans/v0.13-plan.md`

Status: placeholder.

Expected direction:

- Add channel adapters after CLI, LiveView, Security Central, confirmations,
  execution, jobs, and intent metadata share the same runtime core.
- Candidate channels include email, SMS, Discord/Telegram-style chat, browser
  capture, and native UI surfaces.
- Channels translate external messages to signals and render responses; they do
  not own agent logic.
- Channels read and update shared settings through the settings action/signal
  boundary.

## v0.14: Memory Review And Retrieval

Plan: `docs/plans/v0.14-plan.md`

Status: placeholder.

Expected direction:

- Add memory review, correction, promotion, and pruning workflows.
- Add summaries and compiled runtime views over markdown memory.
- Introduce embeddings or retrieval only after the markdown source of truth and
  review path are stable across CLI, LiveView, execution, imports, scheduled
  jobs, and additional channels.
- Use settings for memory review cadence, sensitivity policy, and promotion
  preferences.

## v0.15: Cross-Surface Intent Enrichment

Plan: `docs/plans/v0.15-plan.md`

Status: placeholder.

Expected direction:

- Move beyond one-off route predicates into a hybrid deterministic and
  model-assisted intent engine that remains testable.
- Use settings, skill registry, action-backed skill contracts, confirmation
  history, Security Central decisions, execution traces, jobs, channels, and
  memory review signals as routing inputs.
- Add intent traces and eval fixtures for activation, non-activation,
  permission, execution, channel, job, memory, and refusal cases.
- Keep execution behind the existing action runner and Security Central.

Exit signal: Allbert can explain why it selected a skill/action/job/channel
path or declined to select one, expose alternatives and confidence, and produce
stable intent traces across real runtime surfaces without adding new side
effects.

## v0.16: Security Hardening And Evals

Plan: `docs/plans/v0.16-plan.md`

Status: placeholder.

Expected direction:

- Add security eval fixtures for prompt injection, tool argument injection,
  untrusted skill activation, malicious imports, command approval bypass,
  credential leakage, cross-session data access, channel spoofing, and unsafe
  background execution.
- Add operator-visible security review workflows for recent denials,
  confirmations, imports, external calls, and redaction incidents.
- Reassess sandbox, allowlist, safe-bin, external content, and supply-chain
  policies against real traces.

Exit signal: Security Central has been tested against real execution, import,
channel, job, memory, and intent behavior, and the roadmap has a fresh risk
assessment for v0.17+.

## Future: Distillation And Self-Improvement

Status: research.

Expected direction:

- Explore small-model memory/personality distillation after memory and traces
  are trustworthy.
- Explore scripting or self-modification only after the action permission model
  is robust.
- Keep all self-improvement paths reviewable, reversible, and traceable.
