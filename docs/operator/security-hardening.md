# Security Hardening Operator Notes

v0.28 adds executable security evals and an operator review surface for the
runtime boundaries that now exist. This document is operational guidance; ADRs
and milestone plans remain the design authority.

## Review Loop

Use the read-only review surface before enabling risky capabilities or after a
failed run:

```sh
mix allbert.security status
mix allbert.security review --recent
mix allbert.security review --recent --limit 25
```

The review output summarizes recent confirmations, denials, imports, external
calls, redaction-applied records, and emergency switch state. It is intended to
answer "what risky thing almost or actually happened?" without exposing raw
secrets.

## Emergency Switches

These Settings Central keys can hard-disable risky boundaries without code
changes:

| Key | Disabled value | Boundary |
|---|---:|---|
| `external_services.enabled` | `false` | Confirmed Req-backed external HTTP calls. |
| `stocksage.bridge_enabled` | `false` | StockSage Python bridge Port creation. |
| `plugins.registration_enabled` | `false` | New plugin contribution registration. |
| `app_registry.registration_enabled` | `false` | New app contract registration. |
| `workspace.fragment.emission_enabled` | `false` | Workspace fragment emission and receiver persistence. |
| `sandbox.elixir.enabled` | `false` | v0.36 Elixir/OTP sandbox and gate runner. |
| `dynamic_codegen.enabled` | `false` | v0.37 advisory dynamic draft generation. |
| `dynamic_codegen.live_loader_enabled` | `false` | v0.37 operator-confirmed live dynamic integration. |
| `templates.create.enabled` | `false` | v0.38 operator `workspace:create` template gallery / live-integration surface. |

Example:

```sh
mix allbert.settings set external_services.enabled false
mix allbert.settings set workspace.fragment.emission_enabled false
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set dynamic_codegen.enabled false
mix allbert.settings set dynamic_codegen.live_loader_enabled false
mix allbert.settings set templates.create.enabled false
mix allbert.settings set permissions.sandbox_trial denied
```

## Deployment Posture

- Keep `ALLBERT_HOME` on a local filesystem controlled by the operator.
- Run tests and smoke flows with disposable `ALLBERT_HOME` paths; never point
  evals at a real operator home.
- Keep `external_services.enabled=false` until a specific adapter profile,
  host allowlist, method, redirect policy, and response cap are configured.
- Keep package installs, online skill import, and skill script execution behind
  confirmation. Plugin manifests and skill metadata never grant execution
  authority by themselves.
- Treat OTP processes and Ports as cooperative runtime boundaries, not OS
  sandboxes. Security decisions happen at registered action boundaries.
- Treat the v0.36 Elixir/OTP sandbox as report-only OS isolation for generated
  draft trials. It stays disabled by default, never pulls images during a run,
  uses `sandbox.elixir.network=none`, and must not mount the real Allbert Home.
  Prepare images only through the explicit `mix allbert.sandbox image build`
  and `mix allbert.sandbox image verify` setup path. Inspect bounded sandbox
  audit entries under `<ALLBERT_HOME>/sandbox/audit` alongside report files.
- Treat v0.37 dynamic code as two separately disabled capabilities:
  `dynamic_codegen.enabled` controls advisory draft generation, while
  `dynamic_codegen.live_loader_enabled` controls operator-confirmed live
  registration. A green sandbox gate remains evidence only. Generated actions
  cannot shadow static/plugin/app actions, cannot replace core modules, cannot
  be resumable, and cannot exceed the generated-permission ceiling validated by
  the loader.
- Treat v0.38 templated creation as a separate default-off operator surface:
  `templates.create.enabled=false` keeps the `workspace:create` gallery and
  `CreateFromTemplate` action denied. Templates and their parameters grant no
  authority, and developer Mix-task scaffolds remain inert source under
  `./plugins/<name>/` by default, or under
  `<ALLBERT_HOME>/template-smoke/<name>/` for disposable smoke validation when
  `--smoke` or `ALLBERT_TEMPLATE_SMOKE=1` is set. Runtime settings do not grant
  authority to either output. `CreateFromTemplate` creates only a v0.37 draft;
  sandbox trial, gate, trusted validation, and confirmed integration remain
  separate v0.36/v0.37 steps. Operator live
  integration of a templated artifact is available only for the LLM-tool
  (action) pattern in v0.38 because the
  v0.37.5 loader still rejects generated apps, panels, settings fragments,
  memory namespaces, objective wiring, jobs, and route pages as live targets.
  Existing project roots cannot be overwritten without explicit `--force` plus
  preview/diff, existing dynamic draft roots are denied rather than
  overwritten, and the Telegram/email/cross-channel approval-surface exclusion
  (`dynamic_codegen.integration_approval_surfaces`) applies unchanged.

## Implemented And Planned v1.0 Threat Surfaces

The v0.39-to-v1.0 roadmap promotes several capability classes. Implemented
items below have executable eval coverage; later milestones remain planned
eval surfaces until their capability work lands.

- First-run onboarding and provider doctor (v0.39, executable eval coverage):
  credential redaction in doctor output, doctor-no-leak (no raw error bodies,
  no full URLs, no credential fragments — per ADR 0047),
  onboarding-action-boundary, safe-keys-only writes during onboarding,
  `endpoint_kind` derivation and override behavior, default local model is real
  and missing-model diagnostics are fixed/cataloged, local-model-present doctor
  pass after the operator explicitly pulls the shipped default, identity-slot
  preview step writes nothing (v0.39b adds the write path).
- Identity slot and Active Memory (v0.39b, executable eval coverage):
  identity-namespace not app-owned isolation, identity-memory inert (never
  grants authority), Active Memory read-only, no automatic promotion from
  retrieved chunks, kept-only retrieval, no cross-namespace leak,
  deterministic replay (same query + same state -> same chunks),
  neutral/core-context retrieval excludes app-tagged chunks for non-active
  apps, the intent classifier never receives raw Active Memory chunks,
  `## Active Memory` trace section placement is deterministic, snapshot rule
  (concurrent v0.21 writes during scoring land on the next turn).
- MCP client (v0.40, executable eval coverage): schema-not-authority (tool
  schema/description cannot grant authority), valid confirmed tool-call
  execution, tool/resource confusion (a resource-read grant cannot call a tool;
  server A's grant cannot reach server B), prompt injection in tool/resource
  results, server impersonation, secret-env/header redaction, stdio process
  startup policy (explicit argv, secret-ref env, stderr separated from stdout,
  ADR 0009 bounds), and doctor redacted-envelope. MCP server mode is a separate
  later surface (v0.50b).
- Tool discovery (v0.42, planned eval surface): discovery search egress stays
  within `External.HttpPolicy` (SSRF, private/link-local IP block, bounded
  timeout/body, redirect denial) and degrades to local-only when a registry is
  unreachable; server `server.json` metadata and tool descriptions are never
  authority (schema-not-authority parity with v0.40); a discovered server
  connects only through the confirmation-gated `mcp_server_connect` consent
  showing the exact untruncated command/URL (consent-before-connect); dangerous
  run-command patterns are flagged; a tool-definition baseline hash detects
  rug-pulls on reconnect; the background scan is opt-in / paused-by-default
  (`mcp.discovery.enabled=false`) and writes only to a passive surface (no
  unprompted messaging, no auto-connect). Planned eval rows:
  `mcp-discovery-ssrf-001`, `-tool-poisoning-inert-001`,
  `-rug-pull-detection-001`, `-supply-chain-command-flag-001`,
  `-server-impersonation-001`, `-consent-before-connect-001`,
  `-registry-unavailable-degrades-001`, `-schema-not-authority-001`.
- Browser session state, navigation grants, screenshots, downloads, cookies,
  and page-content prompt injection.
- Discord, Slack, WhatsApp, Signal, iMessage, and Matrix identity mapping,
  replay, pairing, group leakage, and callback ownership.
- Voice, image, screenshot, and generated media resource retention, redaction,
  provider cost, and cloud-upload policy.
- Marketplace-lite provenance, disabled/untrusted defaults, and denial of
  code-bearing remote plugin install.
- API, ACP, MCP-server, and AG-UI/A2UI public protocol auth, rate limits,
  CSP reconciliation, redaction, and confirmation ownership.
- Operator-supervised self-improvement suggestion authority, disabled/untrusted
  draft defaults, repeated-use non-grants, reviewed memory/workflow draft
  facades, and v0.36/v0.37/v0.38 gate handoff.

Remaining future bullets are planned eval areas only; they do not imply those
capabilities exist in the current release.

## Channel Pairing

- CLI and LiveView are local operator channels.
- Remote channels such as email and Telegram must preserve external channel
  identity in the trusted top-level runtime context. Nested request metadata is
  fallback only.
- Confirmation approval should stay on a local/operator-controlled channel
  unless a later plan explicitly hardens remote approval.

## Exposed Services

- Use `Req` through registered actions for HTTP. Do not add another HTTP
  client or call external services from private helpers.
- External request approvals are operation-scoped. A generic
  `external_service_request` grant does not authorize StockSage market-data
  evidence or financial analysis.
- StockSage Python bridge calls are explicit only. Native/Python parity runs do
  not create an automatic fallback path.

## File Permissions

- Secrets are stored by reference and must remain redacted in CLI output,
  LiveView, traces, logs, audits, and confirmation records.
- Workspace fragment signing secrets are runtime-owned files under Allbert
  Home. Do not move them into plugin, skill, or user-editable folders.
- Memory and trace markdown are inspectable durable data; automated promotion
  of advisory output into markdown memory remains blocked unless an operator
  explicitly confirms a write path.

## Sandbox Gate Runner

Use [sandbox-gate-runner.md](sandbox-gate-runner.md) when testing generated
Elixir/OTP drafts or future dynamic code paths. Emergency posture is:

```sh
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set permissions.sandbox_trial denied
mix allbert.sandbox doctor
mix allbert.security review --recent --limit 25
```

The sandbox result is evidence only. It never grants live runtime authority.

## Dynamic Capability Integration

Use [dynamic-capability-integration.md](dynamic-capability-integration.md) when
reviewing v0.37 generated drafts. Emergency posture is:

```sh
mix allbert.settings set dynamic_codegen.live_loader_enabled false
mix allbert.settings set dynamic_codegen.enabled false
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.security review --recent --limit 25
```

Live dynamic integration is denied unless the draft is `:gate_passed`, source
hashes match the gated bytes, trusted validation passes, and Security Central
records an approval from an allowed high-trust operator surface. Telegram,
email, and cross-channel approval are excluded for integration and rollback.
