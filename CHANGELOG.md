# Changelog

## v0.04 - Jido Runtime Convergence Refactor

Status: release-ready for user testing on 2026-05-02.

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
