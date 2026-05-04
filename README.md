# Allbert Assist

Allbert Assist is a local, Jido-centered personal assistant runtime built as a
Phoenix umbrella app. It is designed around supervised Elixir/OTP processes,
signals, registered Jido actions, Security Central, durable confirmations,
Settings Central, Allbert Home, markdown memory, and inspectable traces.

Phoenix LiveView and Mix tasks are operator surfaces over the runtime. They are
not the architecture center.

## Current Status

v0.10 is implemented through M14 after the reopened M6-M9 sequence.
The original M5 release-readiness gate was reopened for online skill approval
clarity/search fixes and Resource Access Security Posture planning; M9 has now
closed that line with refreshed docs, smoke steps, and final gate results.
M10 has now hardened resource identity and scope matching so canonical
resource authority stays separate from redacted display metadata. M11 has now
added operator-visible remembered grant list/show/revoke behavior,
approve-with-remember options, and grant reuse for existing v0.10 actions. The
M12 URI-first resource identity refactor is now implemented through
`AllbertAssist.Resources.ResourceURI`; remembered grants require
`resource_uri` authority. M13 has added direct HTTPS skill URL import and
local skill directory import as disabled/untrusted URI-backed consumers. M14
has added explicit unsupported/deferred UX for v0.11-owned URL/document,
MCP/agent, broad browsing/crawling, and future channel-native approval flows.
v0.10 is ready for operator/user testing. Expected release tag after operator
acceptance remains `v0.10`; no v0.10 tag has been created or pushed yet.

Release details live in `CHANGELOG.md`.

## What Allbert Can Do Today

- Accept user input through CLI and Phoenix LiveView.
- Route runtime work through `AllbertAssist.Runtime.submit_user_input/1`,
  Jido agents, registered actions, and `AllbertAssist.Actions.Runner.run/3`.
- Store operator settings, provider profiles, encrypted local secrets, memory,
  confirmations, cache files, and audit artifacts under Allbert Home.
- Persist explicit markdown memory and optional markdown traces.
- Parse, list, read, activate, validate, and scaffold standard `SKILL.md`
  Agent Skills without granting unplanned execution authority.
- Run confirmed local shell commands through Level 1 host policy controls.
- Run confirmed trusted skill script resources through `run_skill_script`.
- Run confirmed `Req` external service requests through
  `external_network_request`.
- Plan and run confirmed npm package installs through package-manager
  profiles; pip remains preview-only in v0.10.
- Search, show, audit, and import online skills through confirmed registered
  actions. Imported skills remain disabled, untrusted, and cached under
  `<ALLBERT_HOME>/cache/skills`.
- Import direct HTTPS skill URLs and local skill directories through confirmed
  registered actions and `mix allbert.skills import-url/import-local`.
  Imported candidates remain disabled, untrusted, inactive, and non-executable.
- Explain unsupported v0.11-owned resource workflows through the inert
  `unsupported_resource_workflow` action. URL/document summarization, document
  extraction, MCP/agent resource calls, broad crawling/research, and future
  channel-native approval handoff do not create fetch/read/execute requests in
  v0.10.
- Emit shared resource reference metadata for local shell cwd/path operands,
  trusted skill script resources, external requests, online skill sources, and
  package-install targets without changing permission behavior.
- Store and match operation-scoped remembered resource grants in Settings
  Central as generic local/remote resource approval memory. The matcher
  requires the caller to pass the current action permission before use.
- List, inspect, and revoke remembered resource grants through registered
  actions, `mix allbert.resources grants ...`, and the thin `/settings`
  operator surface.
- Approve existing confirmations with remembered exact-resource choices and
  reuse grants for external requests, online skill source reads/imports, and
  package installs when every current resource ref still matches.
- Keep canonical resource identity separate from rendered display metadata for
  external URLs, local paths, source profiles, and confirmation resume
  decisions.
- Treat resource identity as URI-first. v0.10 M12 adds canonical
  `resource_uri` refs/grants; pre-M12 remembered grant records without
  `resource_uri` should be re-created through the current approval/resource
  grant UX.

v0.10 also implements the first Resource Access Security Posture substrate.
It does not implement arbitrary URL/document summarization, channel-native
Approval Handoff UX, a browser, crawler, MCP execution path, or `agent://`
delegation. Those prompts receive an explicit unsupported/deferred response
instead of a partial fetch or execution path. v0.11 consumes the final
URI-based posture through execution-aware intent and channel-native Approval
Handoff UX.

## Start Here

- Operator onboarding: `docs/operator/onboarding.md`
- Changelog and release notes: `CHANGELOG.md`
- Development guide: `DEVELOPMENT.md`
- Roadmap: `docs/plans/roadmap.md`
- Vision: `docs/plans/allbert-jido-vision.md`
- Active v0.10 plan: `docs/plans/v0.10-plan.md`
- Active v0.10 request flow: `docs/plans/v0.10-request-flow.md`
- v0.11 implementation plan: `docs/plans/v0.11-plan.md`
- Architecture decisions: `docs/adr/`

## Local Development

Install dependencies and set up the umbrella app:

```sh
mix setup
```

Run the project gate:

```sh
mix precommit
```

Start Phoenix:

```sh
mix phx.server
```

Operator surfaces:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

CLI entrypoints:

```sh
mix allbert.ask "hello"
mix allbert.security status
mix allbert.confirmations list
mix allbert.skills validate apps/allbert_assist/priv/skills/append-memory
```

## Runtime Configuration

- `ALLBERT_HOME`: root for Allbert runtime data; defaults to `~/.allbert`
- `ALLBERT_HOME_DIR`: compatibility alias for `ALLBERT_HOME`
- `ALLBERT_SETTINGS_ROOT`: specific override for Settings Central
- `ALLBERT_SETTINGS_MASTER_KEY`: base64-encoded 32-byte secret-store key
- `ALLBERT_MEMORY_ROOT`: root for markdown memory and traces
- `ALLBERT_TRACE_ENABLED=true`: enable trace recording
- `OLLAMA_BASE_URL`: OpenAI-compatible Ollama base URL

The optional `:local` model alias is configured for an OpenAI-compatible
Ollama endpoint. Override the endpoint with:

```sh
export OLLAMA_BASE_URL=http://localhost:11434/v1
```

## Safety Boundaries

Allbert remains local and conservative:

- Runtime-facing side effects go through registered Jido actions, the shared
  action runner, Security Central, Settings Central policy, durable
  confirmation when required, redaction, trace, and audit records.
- v0.08 shell execution is Level 1 host policy control, not OS isolation.
- v0.09 skill scripts run only when trusted, enabled, inventoried,
  digest-verified, confirmed, bounded, audited, and traced.
- v0.10 external services, package installs, and online skill import run only
  through confirmed registered actions and target-specific policy re-checks.
- Imported skills are not trusted, enabled, activated, or executed by import.
- Remote network content consumers must be operation-scoped. A future approval
  for URL summarization must not authorize skill import, package install,
  activation, or script execution.
- Future URI schemes such as `mcp://`, `agent://`, and `agent+https://` may be
  represented only as inert metadata until a later release adds explicit
  action, policy, confirmation, adapter, trace, audit, and tests.
- All user-supplied secrets belong in Settings Central secrets and must be
  redacted in output, traces, audits, logs, and tests.
- All tests and smoke flows should use temporary Allbert homes, never a real
  user's `~/.allbert`.

## Verification Pointers

README is intentionally not the testing plan. Use:

- `docs/operator/onboarding.md` for first-run operator guidance.
- `docs/plans/v0.10-request-flow.md` for the v0.10 smoke matrix.
- `docs/plans/v0.10-plan.md` for milestone-specific verification.
- `CHANGELOG.md` for release status, verification summary, and tag readiness.
