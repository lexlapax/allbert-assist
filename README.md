# Allbert Assist

Allbert Assist is a local, Jido-centered personal assistant runtime built as a
Phoenix umbrella app. It is designed around supervised Elixir/OTP processes,
signals, registered Jido actions, Security Central, durable confirmations,
Settings Central, Allbert Home, markdown memory, and inspectable traces.

Phoenix LiveView and Mix tasks are operator surfaces over the runtime. They are
not the architecture center.

## Current Status

v0.12 is implemented through its M6 closeout and tagged as `v0.12` on
2026-05-13 for operator manual verification. It adds canonical local string
`user_id`, preserves `operator_id` as a compatibility alias, persists SQLite
conversation threads/messages, passes bounded recent thread context to the
intent agent, and exposes CLI thread inspection through `mix allbert.threads`.
Version metadata is now `0.12.0`.

v0.11 was released and tagged as `v0.11` on 2026-05-13. It remains the
execution-aware intent, operation-scoped Resource Access, and Approval Handoff
substrate that v0.12 now records in thread history.

v0.10 was released and tagged as `v0.10` on 2026-05-04. It remains the
substrate for confirmed shell, skill script, external service, package, online
skill, direct skill URL, and local skill directory actions that v0.11 now wraps
with intent decisions and handoff metadata.

Release details live in `CHANGELOG.md`.

## What Allbert Can Do Today

- Accept user input through CLI and Phoenix LiveView.
- Route runtime work through `AllbertAssist.Runtime.submit_user_input/1`,
  Jido agents, registered actions, and `AllbertAssist.Actions.Runner.run/3`.
- Persist local SQLite conversation threads and ordered user/assistant
  messages with string `user_id` and `thread_id`.
- Continue the user's recent general thread by default, create a fresh thread
  with `mix allbert.ask --new-thread`, and inspect history with
  `mix allbert.threads`.
- Preserve Alice/Bob style local user isolation for thread continuation and
  thread inspection without adding hosted accounts or roles.
- Pass bounded recent thread context to the intent agent as structured
  `thread_context`.
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
- Attach an inert `AllbertAssist.Intent.Decision` to runtime turns, including
  selected action, permission, confirmation, resource posture, reserved
  `user_id`/`thread_id` context, and trace metadata.
- Render Approval Handoff data in CLI and LiveView for pending confirmations
  without giving channels direct approval or execution authority.
- Route URL summary and remote document inspection prompts to pending
  `external_network_request` confirmations with `summarize_url` or
  `inspect_document` operation classes. Approved fetches report the missing
  summarizer or extractor clearly rather than inventing a downstream consumer.
- Represent generic local file inspection as inert `file://...` posture with an
  explicit no-shell-fallback unavailable state.
- Keep MCP/agent resource calls, broad crawling/research, and future
  channel-native approval handoff as explicit unsupported workflows until later
  adapter plans add security and approval semantics.
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

v0.12 does not add hosted auth, roles, a LiveView thread sidebar, session
scratchpad, app routing, semantic retrieval, vector search, browser/crawler
behavior, MCP execution, `agent://` delegation, or generic local file reading.
Every effect still flows through registered actions, Security Central, Settings
Central policy, durable confirmations, redaction, traces, and audits.

## Start Here

- Operator onboarding: `docs/operator/onboarding.md`
- Changelog and release notes: `CHANGELOG.md`
- Development guide: `DEVELOPMENT.md`
- Roadmap: `docs/plans/roadmap.md`
- Vision: `docs/plans/allbert-jido-vision.md`
- v0.12 implementation plan: `docs/plans/v0.12-plan.md`
- v0.12 request flow and manual verification: `docs/plans/v0.12-request-flow.md`
- Next milestone plan: `docs/plans/v0.13-plan.md`
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
mix allbert.ask --user alice --new-thread "hello"
mix allbert.threads --user alice
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
- v0.11 intent decisions and Approval Handoff are descriptive metadata, not
  authorization. Approval still resumes only the stored target action through
  `approve_confirmation`.
- v0.12 conversation history is local SQLite context, not an auth boundary.
  `user_id` scopes local thread UX but does not replace Security Central or
  hosted authorization.
- Imported skills are not trusted, enabled, activated, or executed by import.
- Remote network content consumers are operation-scoped. A `summarize_url` or
  `inspect_document` approval must not authorize skill import, package install,
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
- `docs/plans/v0.12-request-flow.md` for the v0.12 manual verification matrix.
- `docs/plans/v0.12-plan.md` for milestone-specific verification.
- `CHANGELOG.md` for release status, verification summary, and tag readiness.
