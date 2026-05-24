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

Example:

```sh
mix allbert.settings set external_services.enabled false
mix allbert.settings set workspace.fragment.emission_enabled false
mix allbert.settings set sandbox.elixir.enabled false
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
