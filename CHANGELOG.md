# Changelog

## v0.10 - External Capability Adapters

Status: in progress. M1-M4 are implemented and focused-test verified. No
release commit or release tag exists yet.

### Added

- Security Central and Settings Central scaffolding for external services,
  package installs, and online skill import.
- Confirmed `Req` external service adapter for allowlisted
  `external_network_request` approvals.
- Package install planning and confirmed npm execution through
  `plan_package_install`, `run_package_install`, `approve_confirmation`, and
  `mix allbert.packages`.
- Package install audit records under
  `<ALLBERT_HOME>/execution/package-installs/audit`.
- Confirmed online skill search, detail, audit, and disabled import through
  `search_online_skills`, `show_online_skill`, `audit_online_skill`,
  `import_online_skill`, and `mix allbert.skills ...-online`.
- Source manifests for imported online skills under
  `<ALLBERT_HOME>/cache/skills/_sources`.

### Safety

- npm package installs require exact package specs, an allowed target root,
  durable confirmation, explicit argv, disabled lifecycle scripts,
  `--allow-git=none`, timeout/output caps, and package audit.
- URL, tarball, git, file/path, global, shell-metacharacter, and unpinned
  package specs are denied by default.
- pip remains preview-only and cannot execute in v0.10 without future strict
  hash, binary, pinned requirement, and target policy.
- Online skill search/detail/audit are confirmed external reads. Import creates
  a confirmation before fetching or writing, stores only under Allbert cache,
  and leaves imported skills disabled, untrusted, and non-executable.

## v0.09 - Skill Script Runner

Status: accepted for operator/user testing. Release tag is `v0.09`.

### Added

- `run_skill_script` as the only registered action for trusted Agent Skill
  script resources.
- Security Central `:skill_script_execute` permission, high risk tier, and
  confirmation safety floor.
- Settings Central `execution.skill_scripts.*` policy and interpreter-profile
  validation surface.
- Resource-gated `SkillScriptSpec` resolver for trusted/enabled skills,
  validated capability contracts, exact `AllbertAssist.Skills.Resource`
  inventory matching, SHA-256 digest re-checks, direct executable launch mode,
  cwd/path/env/timeout/output validation, and redacted summaries.
- Durable pending/resolved confirmation flow for skill scripts, including
  policy re-check and digest re-check on approval.
- Bounded skill script runner with explicit executable plus argv, per-run cwd
  handling, timeout, output caps, redacted output previews, and script audit
  records under `<ALLBERT_HOME>/execution/audit`.
- `mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS]
  [--max-output-bytes BYTES] -- [ARGS...]`.
- CLI and `/settings` rendering for pending/resolved skill script metadata:
  skill, script path, digest, cwd, timeout, output cap, result, exit status,
  timeout/truncation flags, and redacted output preview.
- Version metadata bumped to `0.9.0`.

### Changed

- Confirmation approval now resumes `run_skill_script` targets through the
  shared action runner, not direct store mutation or channel-owned execution.
- Security status marks the v0.09 skill script runner boundary as implemented.
- `activate_skill` remains progressive-disclosure-only; reading or activating a
  skill still never runs bundled scripts.
- v0.10 planning now consumes a real trusted script runner while retaining
  package-install, external-network, online-import, and deeper sandbox work as
  separate future capabilities.

### Safety

- v0.09 runs only trusted, enabled, inventoried skill script resources after
  durable operator confirmation.
- Script paths are resource identifiers, not arbitrary filesystem authority:
  absolute paths, traversal, hidden paths, missing resources, non-script
  resources, non-executable scripts, digest drift, out-of-root cwd/path-like
  args, disallowed env keys, and limit violations are denied before execution.
- v0.09 does not add package installs, external service calls, online skill
  import auto-enable, generic scripting engines, runtime Elixir module loading,
  persistent background scripts, or Docker/Podman/container/microVM isolation.
- Level 1 host execution is still not a hostile-code sandbox and does not
  claim network isolation.

### Verification

- Milestone focused suites passed for M1 through M5.
- Release-readiness gates for M5 passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 206 core tests and 16 web tests.
- Operator/user testing should use the disposable `ALLBERT_HOME` and temporary
  workspace smoke in `README.md` or `docs/plans/v0.09-plan.md`.
- Disposable CLI smoke passed for validate, run, list, approve, and
  list-resolved against a temporary trusted skill and workspace.

## v0.07 - Confirmation Workflow

Status: released and tagged as `v0.07` on 2026-05-02.

### Added

- Durable confirmation requests under `<ALLBERT_HOME>/confirmations`, with
  pending, resolved, and markdown audit records.
- Registered confirmation actions for list, show, approve, deny, and expire,
  plus `mix allbert.confirmations`.
- Settings Central confirmation policy for TTL, denial reasons, approval
  surfaces, and cross-channel approval.
- `external_network_request` pending confirmation creation when Security
  Central returns `:needs_confirmation`.
- `/settings` Confirmation Requests surface for the same shared queue used by
  CLI.
- First-class confirmation metadata in runtime traces and richer markdown audit
  entries.

### Changed

- Approval now re-reads the pending record, enforces approval-surface and
  cross-channel settings, re-checks Security Central with confirmation context,
  and records resolver channel metadata.
- Approved external-network requests resolve as `adapter_unavailable` in v0.07
  because no real network adapter exists yet.
- Operator-facing CLI and LiveView output explains `adapter_unavailable` as
  approved, recorded, and not executed because the v0.07 target has no adapter;
  external network execution is planned for v0.10.
- If target policy changes to denied before approval, the request resolves as
  `denied` and target work is not invoked.

### Safety

- v0.07 adds no shell execution, skill script execution, package installation,
  online import, or real external network calls.
- Approval is an operator decision for one pending request, not a generic
  permission grant, and it does not bypass Security Central safety floors.
- CLI and LiveView share one durable, channel-aware queue; neither surface owns
  storage, policy, or target resumption.

### Verification

- Focused milestone suites passed for M1 through M6.
- Final gates passed: `mix compile --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix precommit`,
  and `git diff --check`.
- `mix precommit` passed with 169 core tests and 14 web tests.
- Operator smoke used a disposable `ALLBERT_HOME` to create an external-network
  pending confirmation, inspect it with CLI, approve it to
  `adapter_unavailable`, list resolved records, and verify traces/audits.

## v0.08 - Local Execution Sandbox And Shell Adapter

Status: released and tagged as `v0.08` on 2026-05-02.

### Implemented So Far

- Level 1 local policy sandboxing for confirmed shell command execution.
- `run_shell_command` as the only registered command execution action.
- Settings Central `execution.local.*` policy for allowed roots, allowed
  commands, operator command profiles, path operands, blocked args, env
  allowlist, timeout, output caps, and confirmation.
- Security Central `:command_execute` decisions remain denied by default but can
  be capped to `:needs_confirmation` when the operator explicitly allows
  command execution.
- Durable v0.07 confirmation resume for approved command requests, with
  `target_resumed?: true` only after policy re-check and local runner success.
- CLI and `/settings` output over the same action/confirmation boundary.
- `mix allbert.exec` for deterministic local command-spec testing.
- `mix allbert.ask` prompt routing for command-shaped requests.
- Trace and audit metadata for sandbox level, executable/argv summary, cwd,
  env policy, timeout, output size, exit status, denial reason, and output
  preview.
- Execution markdown audit under `<ALLBERT_HOME>/execution/audit`.
- Version metadata bumped to `0.8.0`.

### Safety

- No autonomous shell execution.
- No unconfirmed command execution.
- No shell strings, PTY sessions, command chaining, redirection, inline
  interpreter eval, background processes, or long-running daemon management.
- No unprofiled mutating/destructive local commands and no out-of-root path
  operand access.
- No skill script execution; v0.09 owns that.
- No external network execution or package installs; v0.10 owns those.
- No Docker, Podman, Mac/Linux container, remote, or microVM backend in v0.08.
  Future deeper sandboxing is tracked in `docs/plans/future-features.md`.

### v0.09 Handoff

- v0.09 should add trusted, resource-gated skill script execution through
  `run_skill_script`, not a generic scripting engine.
- v0.09 must preserve the v0.08 Level 1 host execution caveat: trusted scripts
  can run with policy controls, but this is not container, remote, microVM, or
  network isolation.

## v0.06 - Action-Backed Allbert Skills

Status: released on 2026-05-02.

### Added

- Canonical action capability metadata through
  `AllbertAssist.Actions.Capability` and `AllbertAssist.Actions.Registry`.
- Executable contract validation in
  `AllbertAssist.Skills.CapabilityContract.validate/2` for registered action
  names, skill-backed eligibility, known permission classes, confirmation
  policy, and single-action v0.06 execution shape.
- Skill registry/list/read/activation output that reports contract validation
  status, diagnostics, and execution eligibility while keeping invalid
  contracts inspectable.
- `AllbertAssist.Skills.ActionPlan` for validating selected built-in
  skill/action pairs before invoking the shared action runner.
- Runner, lifecycle signal, trace, and Security Central metadata for selected
  skill, validated contract, selected action capability, permission decision,
  risk, policy, and outcome.
- Local skill helper actions `validate_skill` and `create_skill`, plus
  `mix allbert.skills validate PATH` and `mix allbert.skills create ...`.
- `:skill_write` permission with Settings Central key
  `permissions.skill_write`, default `allowed`, safety floor `allowed`, and
  medium risk tier.

### Changed

- Deterministic built-in routes now select the matching trusted built-in skill,
  validate its contract, and then execute through
  `AllbertAssist.Actions.Runner.run/3`.
- `direct-answer`, `append-memory`, `read-recent-memory`, `list-skills`,
  `read-skill`, `plan-shell-command`, and `external-network-request` are the
  initial action-backed skill surface.
- `activate_skill` remains progressive-disclosure-only and does not execute
  the activated skill's declared action.
- `validate_skill` and `create_skill` are registered helper actions but are
  intentionally excluded from the intent-agent tool surface.
- v0.07 planning now consumes v0.06 selected skill/action metadata and the
  `:skill_write` policy surface for confirmation workflow design.

### Safety

- v0.06 adds no shell execution, skill script execution, package installation,
  external network adapter calls, online import, module loading, autonomous
  skill creation, or confirmation queue.
- Skill metadata, YAML, markdown, `allowed-tools`, and bundled resources never
  grant permission or execute by themselves.
- Local skill scaffolding writes only standard `SKILL.md` wrappers for already
  skill-backed registered actions with matching known permission classes.
- Structurally valid local skills remain `execution_eligible?: false` until
  trusted and enabled through registry policy.

### Verification

- Milestone focused suites passed for M1 through M6.
- Closeout `rg` checks found no module loading, no direct intent action
  `run/2` calls, no private Security Central or Settings Central calls from
  operator surfaces, and only inert safety-text matches for execution-related
  phrases.
- Operator smoke passed in a disposable `ALLBERT_HOME`, covering skill list,
  memory write/read, skill read/activation, denied shell planning,
  external-network confirmation, local skill validation/scaffolding, security
  status, and trace metadata.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix
  credo --strict`, `mix dialyzer`, and `mix precommit` passed.
- `mix precommit` passed with 152 core tests and 12 web tests.

## v0.05 - Security Central Foundation

Status: released on 2026-05-02.

### Added

- `AllbertAssist.Security` as the shared Security Central facade for
  authorization and read-only operator status.
- Security modules for normalized context, policy resolution, canonical
  decisions, risk tiers, redaction, audit metadata, trust boundaries, and
  status summaries.
- Registered internal `security_status` action and `mix allbert.security
  status` for operator inspection.
- Settings Central permission keys for memory writes, command planning,
  command execution, external network requests, and settings writes.
- Security & Permissions section in `/settings`, with editable Settings
  Central permission defaults and read-only effective Security Central status.
- Compact `## Security Metadata` trace output for redacted decisions.

### Changed

- `AllbertAssist.Security.PermissionGate.authorize/2` now delegates to
  Security Central while preserving compatibility fields and helper behavior.
- `AllbertAssist.Actions.Runner.run/3` attaches selected action metadata and
  redacted permission decisions to runner metadata.
- Action lifecycle signals, trace rendering, and security status now use the
  central security redactor.
- v0.06 planning now consumes Security Central's decision shape, selected skill
  trust/provenance, known permission classes, and safety-floor capped policy.

### Safety

- v0.05 adds no new execution powers.
- Settings Central can tighten permission defaults, but built-in safety floors
  still deny or cap shell execution, skill scripts, package installs, external
  network execution, online skill imports, raw secret reads, unknown actions,
  and unknown permissions.
- Skill metadata, `allowed-tools`, and YAML declarations remain inert and never
  grant permission by themselves.
- Raw secrets are redacted from security status, traces, audits, runner
  metadata, signals, CLI, LiveView, logs, and tests.

### Verification

- Focused v0.05 integration suite passed with 85 core tests and 7 web tests.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix
  credo --strict`, `mix dialyzer`, and `git diff --check` passed.
- `mix precommit` passed with 139 core tests and 12 web tests.

## v0.04 - Jido Runtime Convergence Refactor

Status: released on 2026-05-02.

### Added

- `AllbertAssist.Actions.Registry` as the canonical registered action list.
- `AllbertAssist.Actions.Runner.run/3` with action-requested/completed Jido
  lifecycle signals and runner metadata.
- `AllbertAssist.Signals` helpers with recursive redaction, including struct
  redaction for trace-turn signal params.
- Settings model-profile action `list_model_profiles`.
- Internal trace action `record_trace` so runtime trace writes are observable
  action work.

### Changed

- `IntentAgent` routes all selected actions through the shared runner.
- `mix allbert.settings` uses settings actions through the runner for list,
  get, explain, set, provider list, and provider key writes.
- `/settings` uses settings actions through the runner for settings, provider,
  model, and provider credential flows.
- Runtime trace persistence uses the internal `record_trace` action instead of
  calling `Trace.record_turn/1` directly.
- Trace files now include runner metadata for representative user-facing
  actions.

### Safety

- No shell, script, package install, external service, online import, or
  action-backed skill execution capability was added.
- Unknown action names and unregistered modules are denied by the runner.
- Provider keys remain accepted only through explicit CLI/LiveView credential
  flows and are redacted from output, action metadata, traces, logs, and tests.

### Verification

- Focused v0.04 gate passed with 62 core tests and 6 web tests.
- `mix precommit` passed with 120 core tests and 11 web tests.
- `mix dialyzer` passed.
- Operator smoke passed in a disposable `ALLBERT_HOME`, covering traced direct
  answer, skill listing, denied command planning, settings list/write, provider
  listing, and trace metadata inspection.

## v0.03 - Agent Skills Substrate

Status: released on 2026-05-02.

### Added

- Standard Agent Skills `SKILL.md` parsing, validation, diagnostics, and
  resource inventory for `scripts/`, `references/`, and `assets/`.
- Registry-backed skill discovery across built-in, project, user,
  interoperable, imported-cache, and configured scan scopes.
- Trust, enablement, duplicate-name handling, source metadata, aliases, and
  inert Allbert capability contracts for discovered skills.
- Built-in Agent Skill wrappers for the current safe action surface:
  `direct-answer`, `append-memory`, `read-recent-memory`, `list-skills`,
  `read-skill`, `plan-shell-command`, and `external-network-request`.
- Dedicated `activate_skill` action for progressive disclosure of trusted
  skill instructions, diagnostics, resource inventory, and safety boundaries.
- Runtime traces with selected skill metadata, source scope, trust state,
  diagnostics, and resource inventory.
- CLI and LiveView tests for registry-backed skill list, read, alias read, and
  activation behavior.

### Changed

- `list_skills` and `read_skill` now use the registry instead of the old static
  in-code declarations.
- Settings Central can validate and write v0.03 skill trust and scan settings:
  `skills.scan_paths`, `skills.trusted_project_roots`, `skills.enabled`,
  `skills.disabled`, and `skills.imported_cache_policy`.
- Documentation now treats v0.04 action-backed skills as the next milestone and
  v0.03 as the completed compatibility/importability substrate.

### Safety

- Skill declarations, Allbert metadata, `allowed-tools`, bundled scripts,
  package instructions, and external catalogs remain non-executable.
- Activation is read-only context loading; it does not run scripts, shell
  commands, network calls, package installs, or Jido actions.
- Permission checks remain at the action boundary.

### Verification

- `mix precommit` passed with 119 tests, 0 failures, and Credo no issues.
- CLI closeout covered list, read, activate, missing-skill activation, and trace
  metadata in a disposable `ALLBERT_HOME`.
- LiveView operator tests covered the same runtime activation path.

## v0.02 - Allbert Home, Settings Central, Secrets, And Operator Profile

Status: released on 2026-05-01.

### Added

- Canonical Allbert Home under `ALLBERT_HOME`, with `ALLBERT_HOME_DIR` as an
  accepted alias and default root `~/.allbert`.
- Settings Central with typed YAML settings, layered resolution, write
  validation, and append-only audit markdown.
- Encrypted local secret store for provider API keys, with redacted CLI,
  LiveView, trace, audit, log, and test surfaces.
- Provider and model profile settings, operator profile settings, trace
  defaults, skill trust placeholders, and future channel/job/memory namespaces.
- Runtime settings actions plus `mix allbert.settings` and the `/settings`
  LiveView.

### Changed

- Durable memory now defaults under `<ALLBERT_HOME>/memory`, while
  `ALLBERT_MEMORY_ROOT` remains available as a specific override.
- Settings and secrets use one operator-facing control plane instead of
  scattering mutable user configuration through application config.

### Safety

- Raw provider credentials are accepted only through stdin or an interactive
  prompt and are never printed back.
- Tests and operator smokes use temporary Allbert homes rather than writing to a
  real user's `~/.allbert`.

## v0.01 - First Local Assistant Loop

Status: released on 2026-05-01.

### Added

- Signal-first runtime boundary with `AllbertAssist.Runtime.submit_user_input/1`.
- Primary Jido AI agent module with deterministic v0.01 action routing.
- Explicit Jido actions for direct answers, markdown memory, skill inspection,
  shell-command planning, and external-network request recognition.
- Central permission gate with allowed, denied, and confirmation-required
  decisions.
- Markdown-first memory store with `notes`, `preferences`, `traces`, and
  `skills` categories.
- Low-risk personal preference heuristics for identity, communication style,
  timezone, and working preferences.
- Markdown trace recording with `ALLBERT_TRACE_ENABLED=true` or app config.
- CLI entrypoint: `mix allbert.ask`.
- Phoenix LiveView runtime demo at `/agent`.
- Planning docs, request-flow docs, roadmap, and ADRs for the v0.01
  architecture.

### Changed

- The app now uses the primary intent agent instead of the earlier sample agent
  path.
- User recall excludes trace entries by default so diagnostic traces do not
  crowd out notes or preferences.
- Dialyzer is part of the project check path with narrow ignores for known
  `Jido.AI.Agent` macro-generated warnings.

### Safety

- Shell command execution remains unavailable and returns `:denied`.
- External network access is recognized but not performed; it returns
  `:needs_confirmation`.
- Trace write failures are reported as diagnostics and do not crash the
  user-facing response.

### Verification

- `mix precommit` passes.
- `MIX_ENV=test mix check` passes, including Dialyzer with zero stale ignores.
- CLI demo covers memory write, memory recall, denied command planning, and
  trace path output.
