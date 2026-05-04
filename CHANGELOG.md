# Changelog

## v0.10 - External Capability Adapters

Status: implemented through M13 after the reopened v0.10 M6-M9 sequence. The
original M5 release-readiness gate was reopened for online skill approval
clarity/search fixes and Resource Access Security Posture planning; M9 closed
the release-readiness refresh. A later zoom-out release audit reopened v0.10
for M10-M14 closeout milestones before operator acceptance. M10 landed
resource identity hardening; M11 has landed remembered-grant operator
UX/application for existing v0.10 actions. M12 has landed URI-first
`resource_uri` resource/grant authority through
`AllbertAssist.Resources.ResourceURI`. M13 has landed direct/local skill
import consumers on that URI substrate. M14 remains for final unsupported UX
and v0.11 handoff readiness. Expected release tag remains `v0.10`; no v0.10
tag has been created or pushed yet.

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
- Online skill search uses the current skills.sh JSON search endpoint
  `https://skills.sh/api/search` from the configured source API base.
- Source manifests for imported online skills under
  `<ALLBERT_HOME>/cache/skills/_sources`.
- `/settings`, `mix allbert.confirmations`, confirmation audits, and markdown
  traces now render v0.10 external request, package install, and online skill
  request/result metadata from the same durable records.
- Approved online skill source failures resolve as confirmation `approved`
  with `target_status=failed` and a rendered failure reason, rather than
  looking like the operator denied the request.
- Security status marks the v0.10 external adapters and imports boundary
  implemented and shows redacted policy summaries for external services,
  package installs, and online skill import.
- Shared resource reference metadata is emitted by shell command summaries,
  trusted skill script summaries, external request summaries, package install
  summaries, and online skill source actions. The metadata is plain data with
  origin kind, canonical id, operation class, access mode, scope, limits,
  downstream consumer, redaction, digest, and metadata fields; it does not
  approve, grant, fetch, import, install, summarize, or execute by itself.
- Remembered resource grants are stored under Settings Central key
  `resource_grants.remembered`. Grants are generic resource approval memory:
  canonical `resource_uri`, origin/scope metadata, operation class, access
  mode, downstream consumer, channels, expiry, revocation, audit path, and
  reason.
  `AllbertAssist.Resources.Grants.find_applicable/2` requires the caller to
  pass the current action permission for Security Central policy re-check.
- External request summaries now separate canonical URL authority from
  redacted display URL output. Remembered grant matching uses canonical URL
  scope; operator-facing resource metadata renders the redacted display URL
  when available.
- Resource grant matching resolves existing intermediate local symlink
  components before subtree comparison and rejects source-profile grants when
  same-id source endpoint fingerprints drift.
- Registered resource grant actions now list, show, revoke, and remember
  grants through `list_resource_grants`, `show_resource_grant`,
  `revoke_resource_grant`, and `remember_resource_grant`.
- `mix allbert.resources grants list/show/revoke` provides operator CLI
  controls for remembered resource grants.
- `mix allbert.confirmations approve` supports explicit remembered-grant
  options: `--remember`, `--resource-index`, `--remember-all`, and
  `--grant-expires-at`.
- `/settings` now lists active/revoked remembered resource grants, revokes
  them through the registered action boundary, and exposes
  approve-with-remember controls for pending resource-backed confirmations.
- Existing v0.10 actions apply matching remembered grants before creating new
  confirmations for `external_network_request`, online skill
  search/detail/audit/import, and `run_package_install`. Grant reuse is
  operation-scoped and requires all current action resource refs to match.
- Registered action capability metadata now marks which confirmation targets
  are resumable, and `approve_confirmation` checks that metadata before
  attempting target execution.
- ADR 0013 now records URI-first resource identity and permission matching.
  Refs and remembered grants carry canonical `resource_uri` authority while
  `origin_kind`, `canonical_id`, and scopes remain derived/descriptive
  metadata. Pre-M12 grant records without `resource_uri` are not matched
  through a legacy compatibility layer.
- Direct skill URL import is available through `import_remote_skill` and
  `mix allbert.skills import-url URL`. It creates confirmation before fetch,
  uses `https://... + import_skill` resource refs, requires
  `:online_skill_import` plus external service policy, supports remembered
  grants for the same operation boundary, and writes only disabled/untrusted
  imported candidates under `<ALLBERT_HOME>/cache/skills`.
- Local skill directory import is available through `import_local_skill` and
  `mix allbert.skills import-local PATH`. It creates confirmation before
  reading imported content, uses `file://... + import_local_skill` resource
  refs, denies unsafe paths/symlinks during import, and writes only
  disabled/untrusted imported candidates under `<ALLBERT_HOME>/cache/skills`.
- Version metadata bumped to `0.10.0`.

### Changed

- Planning docs now frame v0.10 as the first Resource Access Security Posture
  substrate, not a skills-only or network-only release. Online skill
  search/import is one remote-source consumer; M13 direct/local skill import
  is another. Future URL summarization, document inspection, and other
  local/remote consumers must use the same operation-scoped approval, trace,
  and audit posture.
- README now reads as a project overview and documentation index rather than a
  testing plan. First-run operator guidance lives in
  `docs/operator/onboarding.md`; the v0.10 smoke matrix remains in
  `docs/plans/v0.10-request-flow.md`.
- The reopened v0.10 plan has implemented the shared resource reference
  contract and remembered grant contract before release. v0.11 owns
  execution-aware Approval Handoff UX for consumers such as `summarize_url`,
  `inspect_document`, `import_skill`, and `import_local_skill`.
- M9 refreshed release docs, roadmap/future handoffs, operator onboarding
  pointers, and the v0.10 smoke matrix so operators can test the final M6-M8
  resource posture without treating skills.sh as the platform model.
- M10 resolved the resource identity and resume hardening debt discovered
  after M9: canonical resource identity is separated from redacted display
  data, local path scope matching handles intermediate symlink escape, source
  profile drift invalidates grants, and confirmation resume eligibility lives
  in registered action capability metadata.
- M11 turns remembered grants from tested substrate into operator behavior:
  list/show/revoke, approve-with-remember, `/settings` controls, and reuse for
  existing v0.10 network/source/package flows.
- M12 turns resource identity URI-first in code: `Resources.Ref` emits
  `resource_uri`, `Resources.Grants` stores and matches on `resource_uri`
  authority, Settings Central validates the required field, `mix
  allbert.resources` prints it, and inert `mcp://`, `agent://`, and
  `agent+https://` refs are representable without execution authority.
- M13 adds direct skill URL import and local skill directory import on the
  URI-first substrate. These are skill-import consumers of the generic resource
  posture, not a marketplace-only path. M14 owns final unsupported
  URL/document/MCP/agent messaging and v0.11 handoff readiness.

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
- Direct HTTPS skill URL import and local skill directory import follow the
  same disabled/untrusted import state. Neither path trusts, enables,
  activates, runs scripts, installs dependencies, loads Elixir modules, or
  executes package managers.
- Operator approval is recorded separately from target execution success:
  source HTTP/transport failures after approval are failed target outcomes, not
  Security Central or operator denials.
- v0.10 does not implement arbitrary URL/document summarization, MCP
  execution, `agent://` delegation, a browser, or a crawler. Those consumer UX
  flows still need the v0.11 intent and Approval Handoff contract over the
  v0.10 URI resource posture.

### Verification

- Focused M5 suites passed for `mix allbert.external`, `mix allbert.packages`,
  `mix allbert.skills`, `mix allbert.confirmations`, `/settings`, runtime
  external request tracing, trace action metadata, and Security Central status.
- Final gates for v0.10 M5 passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 248 core tests and 17 web tests.
- M9 reran the focused post-M5 online skill regressions, M7 resource reference
  tests, M8 remembered grant tests, and final release gates before restoring
  tag-readiness wording.
- M9 `mix precommit` passed with 270 core tests and 17 web tests.
- M7 focused resource reference tests pass for shell cwd/path operands, skill
  script resources, external request refs, online skill import refs, package
  install refs, local-vs-remote skill import grant separation, closed operation
  vocabulary, and resource metadata rendering.
- M7 adjacent suites pass for online skill actions, execution/request/package
  summary metadata, confirmation CLI rendering, trace rendering, and
  `/settings` confirmation display. M7 cleanup gates pass:
  `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, and `git diff --check`.
- M8 focused grant tests pass for exact local files, local directory subtrees,
  symlink/traversal escape denial, exact URLs, URL prefixes, redirect escape
  denial, source profiles, operation mismatch, local-vs-remote import
  separation, expired/revoked grants, explicit permission policy drift, and
  remember-option handoff data.
- M8 cleanup gates pass: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and
  `git diff --check`.
- M10 focused tests pass for canonical-vs-display URL refs, redacted URL grant
  authority denial, intermediate symlink directory escape denial,
  source-profile drift rejection, registry-driven resumable action metadata,
  and historical `adapter_unavailable` behavior.
- M11 focused tests pass for registered grant actions, confirmation
  approve-with-remember, CLI grant controls, `/settings` grant list/revoke,
  existing external request/online skill/package-install grant reuse, and the
  package all-refs rule that prevents target-root grants from authorizing
  package registry drift.
- M13 focused tests pass for direct remote URL import confirmation/approval,
  denied-no-fetch behavior, operation-scoped grant separation, local directory
  import confirmation/approval, symlink escape denial, existing online skill
  regressions, Mix task output, resource grants, and registry metadata.
- Operator/user testing should wait for the remaining M14 closeout, then
  start with `docs/operator/onboarding.md` and use the disposable v0.10 smoke
  flow in `docs/plans/v0.10-request-flow.md` or
  `docs/plans/v0.10-plan.md` before accepting and tagging `v0.10`.

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
  workspace smoke in `docs/operator/onboarding.md` or `docs/plans/v0.09-plan.md`.
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
