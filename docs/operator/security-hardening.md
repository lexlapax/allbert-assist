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

Example:

```sh
mix allbert.settings set external_services.enabled false
mix allbert.settings set workspace.fragment.emission_enabled false
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set dynamic_codegen.enabled false
mix allbert.settings set dynamic_codegen.live_loader_enabled false
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

## Planned v1.0 Threat Surfaces

The v0.39-to-v1.0 roadmap promotes several future capability classes that are
not implemented yet. When those milestones land, the security review and eval
surface must expand to cover:

- MCP client and server tool/resource confusion, prompt injection, server
  impersonation, and secret/env leakage.
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
  draft defaults, repeated-use non-grants, and v0.36/v0.37/v0.38 gate handoff.

These are planned eval areas only; they do not imply the capabilities exist in
the current release.

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
