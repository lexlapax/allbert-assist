# Allbert Roadmap

This roadmap is the running planning index for Allbert. The long-term vision is
captured in `docs/plans/allbert-jido-vision.md`; implementation-ready milestone
plans live alongside this file. Identified but unassigned future work lives in
`docs/plans/future-features.md`.

`docs/plans/post-v0.10-implementation-tasks.md` and
`docs/plans/aiworkspace-plan.md` are superseded reference files retained only
for verification before deletion. This roadmap and the v0.xx plan files are
the canonical implementation sources.

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
9. External service, package-install, online skill import adapters, and the
   first resource access security posture substrate across local and remote
   resources.
10. Execution-aware intent decisions, Approval Handoff, and resource access
    consumers over real risky capabilities.
11. Local workspace identity and SQLite conversation history.
12. Scheduled jobs that emit signals into the same runtime.
13. Session scratchpad and minimal app registration.
14. Additional channels that translate messages into the same runtime.
15. StockSage as the first workspace app, proving the app contract.
16. Memory review, summarization, and retrieval improvements.
17. Cross-surface intent enrichment over real skills, actions, permissions,
    confirmations, jobs, channels, memory, and app context.
18. Security hardening and evals after real execution, import, channel, job,
    memory, intent, app, and financial-analysis behavior exists.
19. Full app/surface contract, workspace canvas, and app generator work only
    after the local runtime and security substrate are proven.

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

Status: released and tagged as `v0.08` on 2026-05-02.

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
  Complete in implementation: trace/audit metadata, version `0.8.0`, release
  docs, and gates are ready for release/tag.

Exit signal: Allbert can execute an explicitly confirmed shell command through
a registered action, inside a bounded Level 1 local policy sandbox, with denial
defaults, redacted output, and inspectable trace/audit records. It does not
claim Docker/Podman/container/microVM isolation in this release.

Status: v0.08 is released and tagged as `v0.08`.

## v0.09: Skill Script Runner

Plan: `docs/plans/v0.09-plan.md`
Request flow: `docs/plans/v0.09-request-flow.md`
ADR: `docs/adr/0010-resource-gated-skill-script-execution.md`

Status: accepted for operator/user testing. Release tag is `v0.09`.

Expected direction:

- Add a confirmed `run_skill_script` path for trusted, enabled, inventoried
  Agent Skill scripts.
- Add `:skill_script_execute` permission with a confirmation safety floor and
  `execution.skill_scripts.*` Settings Central policy.
- Resolve script paths only from the selected skill's v0.03 resource inventory,
  and re-check the resource digest before pending creation and before approved
  execution.
- Run scripts through v0.08 Level 1 host-process controls and v0.07
  confirmation workflow, adding skill provenance, script path, digest, cwd,
  env, timeout, output, and capability-contract checks before execution.
- Keep direct executable script resources as the first launch mode. Interpreter
  profiles must be explicit Settings Central policy, not broad file-extension
  authority.
- Keep `run_skill_script` separate from `run_shell_command`; it owns
  selected-skill, resource-inventory, digest, and script launch policy while
  reusing lower-level v0.08 timeout/output/redaction/audit helpers where useful.
- Continue to forbid runtime module loading, package installs, external service
  calls, generic scripting engines, imported-skill auto-enable, and
  non-inventoried script execution.
- Preserve the sandbox caveat: Level 1 host execution is not network,
  container, remote, or microVM isolation.

Milestones:

- M1: ADR, Security Central permission, Settings Central policy, capability
  metadata, and active-doc onboarding updates.
  Complete in implementation: M1 added the `:skill_script_execute` policy
  vocabulary, `execution.skill_scripts.*` settings, ADR 0010, and registered
  non-executing `run_skill_script` capability metadata.
- M2: Resource-gated script spec with skill trust, exact inventory match,
  path validation, digest re-check, cwd/env/limit validation, and redacted
  summaries.
  Complete in implementation: M2 added `AllbertAssist.Execution.SkillScriptSpec`
  and connected `run_skill_script` to the inert resolver, so valid trusted
  script requests now produce auditable metadata while disabled, untrusted,
  missing, non-script, hidden, path-escaping, digest-drifted, non-executable,
  cwd/env/limit, and path-like-arg violations are denied before confirmation.
- M3: Registered `run_skill_script` action with durable pending creation,
  confirmation resume, policy re-check, digest re-check, and idempotent
  resolution, consuming the M2 spec and stored expected digest instead of
  trusting client-supplied paths or summaries.
  Complete in implementation: M3 creates pending confirmations, resumes through
  `approve_confirmation` and the shared action runner, re-checks Security
  Central and script digests, denies policy/digest drift before execution, and
  established the resume contract that M4 now uses for actual process running.
- M4: Script runner, execution audit, CLI surface, `/settings` confirmation
  metadata, trace metadata, and activation-stays-inert coverage.
  Complete in implementation: M4 replaced the temporary `runner_pending`
  handoff with the bounded skill script runner, shared output buffering,
  script audit events, CLI request/show/approve rendering, and `/settings`
  pending/resolved metadata for completed, failed, timed-out, truncated, and
  redacted script output.
- M5: Docs, future milestone handoffs, pre-release smoke matrix, focused
  tests, final gates, and release/tag readiness.
  Complete in implementation: M5 updated release docs, bumped version metadata
  to `0.9.0`, marked the Security status boundary implemented, preserved
  v0.10/v0.11 handoffs, and documented exact user-testing commands and tag
  readiness.

Exit signal: Allbert can run a bundled skill script only when the skill is
trusted, enabled, selected, inventoried, digest-verified, confirmed, bounded
by Level 1 host-process controls, audited, and traced.

## v0.10: External Services, Package Installs, Online Skill Import, And URI-First Resource Access Posture

Plan: `docs/plans/v0.10-plan.md`
Request flow: `docs/plans/v0.10-request-flow.md`
ADR: `docs/adr/0011-confirmed-external-capability-adapters.md`
Identity ADR: `docs/adr/0013-uri-first-resource-identity.md`

Status: M1-M14 implemented and focused verified. v0.10 was reopened
after M5 because post-M5 commits added online skill approval clarity/search
fixes and Resource Access Security Posture planning. M6 reconciles that
history, M7 implements shared resource reference metadata, M8 implements
Settings-backed remembered resource grant storage and matching, and M9 closes
the first release-readiness/user-testing refresh. A later zoom-out release
audit reopened v0.10 for M10-M14 closeout before release. M10
finished canonical resource identity hardening, and M11 added
remembered-grant operator UX plus application to existing v0.10 flows.
M12 added URI-first resource identity through
`AllbertAssist.Resources.ResourceURI` and required `resource_uri` grant
authority. M13 has added direct/local skill import consumers. M14 has added
explicit unsupported/deferred UX for v0.11-owned URL/document, MCP/agent,
broad browsing/crawling, and future channel-native approval workflows. v0.10
was released and tagged as `v0.10` on 2026-05-04.

Expected direction:

- Replace new v0.10 `external_network_request` approvals with a real confirmed
  `Req` adapter instead of `adapter_unavailable`, while preserving historical
  pre-v0.10 records.
- Add external service policy under Settings Central: enabled flag, service
  profiles, allowed hosts/methods/paths, timeout, response cap, redirect/retry
  policy, redaction, and credential refs.
- Add `:package_install` and `:online_skill_import` permission classes with
  high-risk classification and confirmation safety floors.
- Add package install planning and confirmed package-manager execution through
  profiles, not shell strings. npm is the first executable profile; pip remains
  preview/audit-only unless strict hash, binary, pinned requirement, and target
  policy are implemented and tested.
- Add skills.sh or remote-source search, detail, audit, and import support
  through `Req`, source profiles, bounded downloads, source manifests, and the
  existing Agent Skills parser/registry.
- Treat `skills.sh` as one source profile and search convenience, not the
  platform model. v0.10's durable primitive is approved resource access with
  canonical `resource_uri`, derived origin kind/source/profile metadata,
  operation class, access mode, scope, limits, confirmation, audit, and trace
  metadata.
- Resource identity is URI-first before adding more consumers. Remembered
  grants require `resource_uri`; pre-M12 `canonical_scope` grant records are
  not matched through a legacy compatibility layer. Authority is
  `resource_uri + operation_class + access_mode + downstream_consumer` plus
  current Security Central permission.
- Implement direct/local skill import as `import_skill` and
  `import_local_skill` consumers, and keep future URL summarization and
  document inspection on `summarize_url`/`inspect_document` without sharing
  unsafe approval authority.
- Write imported skills only under `<ALLBERT_HOME>/cache/skills`; keep them
  disabled, untrusted, and non-executable until parsed, validated, audited,
  enabled, trusted, and separately confirmed for any script execution.
- Keep Docker, Podman, Mac/Linux containers, remote sandboxes, and microVMs out
  of v0.10. Deny or defer workflows that need deeper isolation.

Milestones:

- M1 (Milestone 1): Implemented. Policy, ADR, Settings Central schema,
  Allbert Home paths,
  and registered capability contracts for external, package, and online import
  actions.
- M2 (Milestone 2): Implemented. Confirmed `Req` external service adapter,
  SSRF/redirect/retry policy, confirmation resume, redacted trace/audit, and
  Req.Test coverage.
- M3 (Milestone 3): Implemented. Package install preview, confirmed npm adapter
  through package-manager profiles, exact package spec validation, package
  confirmation metadata, `mix allbert.packages`, and pip preview-only denial.
- M4 (Milestone 4): Implemented. Confirmed online skill search, detail, audit,
  and disabled imported-cache write through allowed source profiles, `Req`,
  source manifests, existing parser/registry validation, and CLI/confirmation
  metadata. Approved source failures resolve as `approved` confirmations with
  `target_status=failed` and rendered failure reasons.
- M5 (Milestone 5): Implemented. Release readiness, operator surfaces,
  trace/audit polish, docs, future milestone handoffs, focused tests, final
  gates, version metadata `0.10.0`, and release/tag readiness docs.
- M6 (Milestone 6): Implemented. Post-M5 reconciliation and Resource Access
  Security Posture rebaseline. Records the online approval clarity/search fix,
  README/operator onboarding cleanup, ADR 0012, and the decision to resume
  implementation at M7.
- M7 (Milestone 7): Implemented. Shared resource reference contract through
  `AllbertAssist.Resources.Ref`, `Scope`, `OperationClass`, inert `Grant`
  descriptors, and confirmation resource metadata rendering for local paths,
  local skill resources, Allbert Home resources, remote URLs, remote sources,
  and package registries, including skills special cases such as
  `import_local_skill`, `run_skill_script`, and `import_skill`.
- M8 (Milestone 8): Implemented. Resource-scoped remembered grants under
  `resource_grants.remembered`, with generic local/remote scope matching,
  explicit caller-supplied permission re-check, expiry/revocation, redirect
  escape denial, traversal/symlink escape denial, and no cross-use between
  local import, remote summary, skill import, package install, activation, or
  script execution.
- M9 (Milestone 9): Implemented. Release readiness and user testing refresh
  after M6-M8, including focused online skill regressions, resource
  reference/grant tests, full gates, docs, and tag-readiness wording.
- M10 (Milestone 10): Implemented. Resource identity and scope hardening
  before grants become user-facing: canonical-resource versus
  redacted-display separation for URL refs, intermediate local symlink escape
  denial, source profile drift checks, and registry-driven resumable-action
  metadata.
- M11 (Milestone 11): Implemented. Remembered grant operator UX and
  application for existing v0.10 actions: registered list/show/revoke/remember
  actions, `mix allbert.resources grants ...`, approval-time remember options,
  thin `/settings` list/revoke/approve-with-remember controls, and grant
  lookup before creating confirmations for external request, online skill
  source, and package install consumers.
- M12 (Milestone 12): Implemented. URI-first resource identity refactor through
  `AllbertAssist.Resources.ResourceURI`, required `resource_uri` grant
  authority, removal of the temporary `canonical_scope` grant shape, and inert
  future URI scheme representation for
  `mcp://`, `agent://`, and `agent+https://`.
- M13 (Milestone 13): Implemented. Direct skill URL import and local skill
  directory import as concrete URI-backed resource consumers that import only
  disabled/untrusted skill candidates and never trust, enable, execute, or
  install dependencies.
- M14 (Milestone 14): Implemented. Final closeout and v0.11 handoff
  readiness: explicit no-op/unsupported UX for URL summarization and document
  inspection, MCP resource/tool calls, and `agent://` delegation in v0.10,
  refreshed tests, docs, and release/tag readiness.

Exit signal: Allbert can search, audit, and import online skills, call approved
external services, and run the first confirmed npm package-manager profile
through registered actions without making imports, package manifests, or
package-manager metadata executable by themselves. CLI, `/settings`, traces,
audits, and Security Central render the same v0.10 metadata and policy
summaries, including the distinction between operator approval and target
execution failure. The docs and code also identify Resource Access Security
Posture as the common substrate for future local and remote consumers. The
reopened M6-M9 sequence, M10 hardening, M11 remembered-grant
operator/application work, M12 URI-first resource identity refactor, M13
direct/local skill import consumers, and M14 unsupported workflow handoff are
complete. v0.10 was released and tagged as `v0.10` on 2026-05-04.

## v0.11: Execution-Aware Intent, URI-Based Resource Access, And Approval Handoff

Plan: `docs/plans/v0.11-plan.md`
Request flow: `docs/plans/v0.11-request-flow.md`

Status: released and tagged as `v0.11` on 2026-05-13. Ready for operator manual
verification with the v0.11 request-flow matrix.

Implemented direction:

- Introduce the inert `AllbertAssist.Intent.Decision` contract with selected
  intent, candidate skills/actions, permission, risk, confirmation, execution
  mode, resource access posture, Approval Handoff, alternatives, diagnostics,
  trace metadata, and reserved `user_id`, `thread_id`, `session_id`, and
  `active_app` fields.
- Validate every decision against known skills, registered actions, known
  permissions, Security Central, Settings Central, and confirmation state.
- Represent URL summaries, document inspection, direct skill URL import, local
  skill directory import, shell execution, skill scripts, package installs,
  external services, online skill sources, and unsupported MCP/agent URI flows
  as resource-access consumers over the v0.08-v0.10 substrates.
- Produce Approval Handoff data for CLI and web approval UX without giving
  channels authority to approve, deny, fetch, import, execute, or grant.
- Keep conversation history out of v0.11; v0.12 plugs into the reserved
  identity/thread fields.

Exit signal: risky URL/document/import prompts produce inspectable decisions,
operation-scoped resource posture, and approval handoff without hidden
execution or new file/browser/crawler primitives.

Release handoff: v0.11 request-flow docs now carry the manual verification
matrix for CLI URL summary approval, LiveView approval/denial, approved fetch
with missing summarizer/extractor, direct/local skill import, unsupported
MCP/agent URI behavior, and operation-scoped grant negative checks.

## v0.12: Local Workspace Identity And Conversation History

Plan: `docs/plans/v0.12-plan.md`
Request flow: `docs/plans/v0.12-request-flow.md`
ADR: `docs/adr/0014-local-workspace-identity.md`

Status: released and tagged as `v0.12` on 2026-05-13. Ready for operator manual
verification with the v0.12 request-flow matrix. Formerly M-D1a.

Implemented direction:

- Add canonical string `user_id`, preserving `operator_id` as a compatibility
  alias and defaulting omitted identity to `"local"`.
- Add SQLite `Thread` and `Message` conversation history with user isolation,
  explicit `thread_id`, recent-thread selection, and `--new-thread` creation.
- Persist user messages before the agent runs and assistant messages after
  response and trace metadata are known.
- Pass bounded recent thread context to the intent agent, initially the last
  12 messages.
- Add `--user`, preserve `--operator`, fail fast if both differ, and add
  `mix allbert.threads`.
- Keep acceptance on CLI/runtime/signals/traces/tests. No AgentLive thread
  sidebar, no semantic retrieval, and no markdown-memory promotion.

Exit signal: `mix allbert.ask --user alice --new-thread ...`, follow-up calls,
`mix allbert.threads`, default `"local"` behavior, and alice/bob isolation
prove durable thread context without hosted accounts.

## v0.13: Scheduled Jobs

Plan: `docs/plans/v0.13-plan.md`
Request flow: `docs/plans/v0.13-request-flow.md`

Status: released and tagged as `v0.13` on 2026-05-14. Formerly v0.12.

Expected direction:

- Add local SQLite-backed scheduled jobs that emit signals into the same
  runtime or run registered actions through the action runner.
- Preserve originating `user_id`, `thread_id`, and `app_id` when available so
  traces and audits carry local ownership context without accounts tables.
- Pause risky job actions for durable confirmation and render the same
  resource posture/Approval Handoff metadata as CLI and web.
- Keep jobs observable through durable run records, lifecycle signals, traces
  when enabled, registered skills/actions, and Settings Central schedule
  policy.
- Keep the scheduler local and supervised; no distributed scheduler, remote
  workers, or new execution primitives.
- Instantiate initial low-risk job templates through explicit CLI commands,
  not seeded database rows or autonomous job creation.

## v0.14: Session Scratchpad And Active App Context

Plan: `docs/plans/v0.14-plan.md`
Request flow: `docs/plans/v0.14-request-flow.md`
ADR: `docs/adr/0014-local-workspace-identity.md`

Status: released and tagged as `v0.14` on 2026-05-14. Formerly M-D1b.

Expected direction:

- Add supervised volatile ETS scratchpad state keyed by `{user_id, session_id}`
  with TTL expiry, periodic sweep, and no restart persistence.
- Store `active_app` and bounded transient working memory for runtime/session
  use while keeping raw working-memory values out of traces/logs by default.
- Add a CLI sessions surface and `mix allbert.ask --session` so Phase 1
  acceptance can prove active-app propagation without adding workspace UI.
- Expose active-app session inspection/mutation through registered actions
  that reuse existing `:settings_write`/`:read_only` permissions and do not
  add new Security Central permission classes.
- Propagate `active_app` through runtime requests, signals, intent-agent
  context, decisions, traces, responses, and assistant message metadata.
- Treat scratchpad state as context only, not durable memory, app routing,
  authorization, or a security boundary.

## v0.15: Minimal App Registration Contract

Plan: `docs/plans/v0.15-plan.md`
ADR: `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

Status: planned. Formerly M-AppContract-Lite.

Expected direction:

- Add the lite `AllbertAssist.App` behaviour and registry for app identity,
  validation, child supervision, registered actions, skill paths, and nav
  surfaces.
- Tag registered actions with optional `app_id`.
- Keep permission, confirmation, security, traces, and execution authority at
  existing Allbert action boundaries.
- Do not add `AllbertAssist.Surface` or canvas work yet.

## v0.16: Additional Channels

Plan: `docs/plans/v0.16-plan.md`

Status: planned. Formerly v0.13.

Expected direction:

- Add one additional channel adapter that translates external messages into
  Allbert signals and renders responses without owning agent logic.
- Map external identities to local string `user_id` values through explicit
  Settings Central configuration; traces include both identities.
- Consume Approval Handoff and Resource Access Security Posture natively
  without channel-specific resource or approval rules.

## v0.17: StockSage Umbrella App And Domain

Plan: `docs/plans/v0.17-plan.md`

Status: planned. Formerly M-D2a.

Expected direction:

- Add `stocksage` and `stocksage_web` umbrella apps.
- Implement `StockSage.App` using the v0.15 app contract.
- Add SQLite-first StockSage domain records with string `user_id` and optional
  thread/request context.
- Add local StockSage skill pack paths and an import task for the frozen Python
  `stocksage.db` baseline.
- Keep PostgreSQL, Oban-as-hard-dependency, LiveViews, bridge execution, and
  native trading agents out of this slice.

## v0.18: Memory Review And Retrieval

Plan: `docs/plans/v0.18-plan.md`

Status: planned. Formerly v0.14.

Expected direction:

- Add operator review, correction, promotion, and pruning over markdown
  long-term memory.
- Generate summaries and compiled runtime views from markdown sources.
- Keep SQLite conversation history from v0.12 distinct from markdown memory;
  no automatic promotion of thread turns.
- Add retrieval only after review and source-of-truth semantics are stable.

## v0.19: StockSage Python Bridge

Plan: `docs/plans/v0.19-plan.md`

Status: planned. Formerly M-D2b.

Expected direction:

- Add a supervised bridge, likely JSON-over-stdio Port, around Python
  StockSage/TradingAgents.
- Add `StockSage.Actions.RunAnalysis` and a Mix smoke command that persists a
  real analysis.
- Route natural language analysis prompts through StockSage skill/action
  boundaries when app context and permission posture allow it.

## v0.20: Cross-Surface Intent Enrichment

Plan: `docs/plans/v0.20-plan.md`

Status: planned. Formerly v0.15.

Expected direction:

- Move from route predicates toward hybrid deterministic and model-assisted
  intent ranking over real runtime signals.
- Use settings, skills, actions, Security Central, confirmations, traces,
  jobs, channels, memory review, session scratchpad, and app registry context
  as routing inputs.
- Prioritize app-registered actions and skill paths only when `active_app`
  gives explicit session evidence.

## v0.21: Native Jido Trading Agents

Plan: `docs/plans/v0.21-plan.md`

Status: planned. Formerly M-D2c.

Expected direction:

- Implement the native Jido trading-agent topology behind StockSage actions.
- Keep the Python bridge selectable until golden fixtures and batch smoke tests
  prove native parity within documented variance.
- Make native analysis default only after acceptance passes.

## v0.22: StockSage LiveViews

Plan: `docs/plans/v0.22-plan.md`

Status: planned. Formerly M-D3a.

Expected direction:

- Add StockSage workspace, analysis, queue, and trends LiveViews as standard
  app surfaces.
- Use PubSub/streams for live progress and set `active_app: :stocksage` when
  the user is in StockSage context.
- Leave canvas registration out of this slice.

## v0.23: Security Hardening And Evals

Plan: `docs/plans/v0.23-plan.md`

Status: planned. Formerly v0.16.

Expected direction:

- Add evals for prompt/tool injection, SSRF, unsafe redirects, untrusted skill
  activation, malicious imports, package abuse, command bypass, resource-scope
  bypass, path traversal, credential leakage, channel spoofing, and unsafe
  background execution.
- Add cross-user/thread leakage, app-scoped action routing, Python bridge
  protocol/path/crash safety, and financial workflow authorization coverage.
- Require StockSage external market-data calls to flow through Resource Access
  Security Posture and confirmations.

## v0.24: Full App Contract And Surface DSL

Plan: `docs/plans/v0.24-plan.md`
ADR: `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

Status: planned. Formerly M-AppContract-Full.

Expected direction:

- Expand the app contract into identity/OTP, agents/actions/signals, skills,
  UI surface, and data/settings layers.
- Add `AllbertAssist.App.SurfaceProvider`, `AllbertAssist.Surface`, validation
  tooling, and optional future encoders.
- Keep AG-UI/A2UI as future adapters, not local hard dependencies.
- Prove the contract with StockSage before v0.26 consumes it.

## v0.25: StockSage Polish, Outcomes, And Trends

Plan: `docs/plans/v0.25-plan.md`

Status: planned. Formerly M-D3b.

Expected direction:

- Add outcome resolver, trend metrics, rating calibration, reruns, empty/error
  states, and responsive polish.
- Replicate Python StockSage 0.0.2 user-facing behavior in Elixir, with Python
  remaining only as explicit fallback until native parity closes.

## v0.26: Agentic Workspace Surface And Ephemeral UI Substrate

Plan: `docs/plans/v0.26-plan.md`

Status: planned. Formerly v0.17.

Prerequisite: v0.23 and v0.24 are complete.

Expected direction:

- Replace the rudimentary `/agent` concept with a signal-driven operator
  workspace while keeping LiveView thin.
- Use `AllbertAssist.App.Registry` for app navigation and
  `AllbertAssist.Surface` for canvas/task component validation.
- Define canvas persistence, ephemeral surface lifecycle, provenance,
  fallback text, redaction, and action-binding constraints.
- Leave AG-UI/A2UI/MCP Apps interoperability to later adapter work.

## v0.27: StockSage Canvas Integration

Plan: `docs/plans/v0.27-plan.md`

Status: planned. Formerly M-Canvas.

Expected direction:

- Register StockSage chart and analysis-card components with the v0.26 canvas
  catalog.
- Let StockSage analysis responses emit canvas operations for durable tiles.
- Add no new StockSage domain model or analysis behavior.

## v0.28: Allbert App Generator

Plan: `docs/plans/v0.28-plan.md`

Status: research (unstarted).

Prerequisite: StockSage proves the full v0.24 contract end to end after v0.25,
v0.26 canvas ships, and v0.27 proves the app/canvas path.

Expected direction:

- `mix allbert.gen.app MyApp` scaffolds all five app contract layers.
- Generated output includes an app module, app supervision wiring, sample Jido
  action, sample `SKILL.md`, sample surface provider or surface node, sample
  Ecto domain stub, and validation docs.
- `mix allbert.validate_app MyApp` passes on first run.
- Generated code is inert by default: no automatic trust, skill enablement,
  publishing, permission grants, or execution authority.
- Optionally add `mix allbert.publish_skills` for publishing app `SKILL.md`
  files to agentskills.io after the local app contract is proven.

Post-v0.28 candidates remain in `docs/plans/future-features.md` until
promoted.

## Future: Distillation And Self-Improvement

Status: research.

Expected direction:

- Explore small-model memory/personality distillation after memory and traces
  are trustworthy.
- Explore scripting or self-modification only after the action permission model
  is robust.
- Keep all self-improvement paths reviewable, reversible, and traceable.
