# Security Hardening Operator Notes

Operational security guidance for the Allbert runtime boundaries: the review loop,
emergency switches, deployment posture, the secret vault, and channel/service exposure.
ADRs and milestone plans remain the design authority; the executable eval coverage for
each threat class lives in the version request-flow docs.

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
| `marketplace.enabled` | `false` | v0.45 Marketplace Lite catalog browse/install surface. |
| `self_improvement.enabled` | `false` | v0.47 self-improvement discovery, suggestion, and draft surface. |
| `self_improvement.trace_index.enabled` | `false` | v0.47 trace-index reads for self-improvement discovery. |
| `artifacts.enabled` | `false` | v0.50 Artifacts Central action surface. |
| `artifacts.retention_enabled` | `false` | v0.50 durable artifact retention writes. |

Example:

```sh
mix allbert.settings set external_services.enabled false
mix allbert.settings set workspace.fragment.emission_enabled false
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.settings set dynamic_codegen.enabled false
mix allbert.settings set dynamic_codegen.live_loader_enabled false
mix allbert.settings set templates.create.enabled false
mix allbert.settings set marketplace.enabled false
mix allbert.settings set self_improvement.enabled false
mix allbert.settings set self_improvement.trace_index.enabled false
mix allbert.settings set artifacts.enabled false
mix allbert.settings set artifacts.retention_enabled false
mix allbert.settings set permissions.artifact_write denied
mix allbert.settings set permissions.artifact_delete needs_confirmation
mix allbert.settings set permissions.marketplace_install denied
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
- Treat v0.45 Marketplace Lite as a local reviewed catalog only:
  `marketplace.enabled=false` disables the operator surface and
  `permissions.marketplace_install=denied` blocks install/rollback. Catalog
  metadata, `marketplace://` URIs, template metadata, plugin_index entries,
  and mirrored cache files do not grant authority. Installed bundles stay
  `disabled_untrusted`; skill enablement, dynamic integration, plugin loading,
  workflow distribution, remote code fetch, and bundle signing are outside the
  v0.45 surface.
- Treat v0.47 operator-supervised self-improvement as a read-only discovery
  and inert draft surface. `self_improvement.enabled=false` disables the
  feature, and `self_improvement.trace_index.enabled=false` prevents trace
  index reads. Discovery suggestions are advisory and passive; drafts are
  disabled/untrusted or draft-only; live promotion to skills, workflows, or
  memory requires the existing registered action permission plus durable
  confirmation.
- Treat v0.50 Artifacts Central as durable local data, not permission
  authority. `artifacts.enabled=false` blocks the core artifact action surface;
  `artifacts.retention_enabled=false` blocks durable retention writes even when
  the store exists. `artifact://sha256/<hex>` ids, metadata sidecars,
  `artifact_thread_links`, and ingestion sensor signals are provenance and
  identity only. Reads/writes/deletes still require `:artifact_read`,
  `:artifact_write`, and confirmation-gated `:artifact_delete`. Raw bytes stay
  under `<ALLBERT_HOME>/artifacts/objects/`; traces, sidecars, LiveView,
  audits, CLI output, and release evidence carry redacted metadata only.

## Threat surfaces and eval coverage

Every runtime capability class Allbert ships — first-run onboarding + provider doctor,
intent routing, active memory, MCP integrations, channels, artifacts/media, the browser,
the public protocol, the packaged CLI/daemon, and the OS-vault credential model — has
executable eval coverage that runs in deterministic release gates. On 1.x, every
release runs `mix allbert.test release.v1` plus the active plan's point-release gate
(for example `release.v101`); both include the applicable security sweeps. The
invariants are the same
across surfaces: no authority is granted without an explicit, confirmation-gated,
durably-traced operator approval; secrets are never surfaced in output, logs, or traces;
and every action is scoped by Security Central. The per-surface eval-row catalog and its
evidence live in the version request-flow docs (`docs/plans/*-request-flow.md`), not in
this operator guide.

## Channel Pairing

- CLI and LiveView are local operator channels.
- Remote channels such as email and Telegram must preserve external channel
  identity in the trusted top-level runtime context. Nested request metadata is
  fallback only.
- Confirmation approval should stay on a local/operator-controlled channel
  unless a later plan explicitly hardens remote approval.

## Autonomous Channel Reports

Background report-back is a separate ADR 0084 authority, not a side effect of
starting a task or connecting a channel. It is OFF by default for every remote
channel. Opt in deliberately with Settings Central:

```sh
allbert admin settings set channels.telegram.autonomous_notify.enabled true
allbert admin settings set channels.telegram.autonomous_notify.level status_and_completion
allbert admin settings set channels.telegram.autonomous_notify.min_interval_seconds 30
```

Replace `telegram` with the configured channel. Allowed levels are
`completion` and `status_and_completion`; Email is completion-only regardless
of the requested level. Enabling delivery grants no tool, data, confirmation,
or cross-thread authority. Each send re-proves the local identity mapping and
the exact originating account/thread, redacts content, passes Security Central,
and records a durable delivery row. Uncertain provider acceptance is not
blindly retried.

The append-only operator audit is stored under
`<ALLBERT_HOME>/channels/notify/audit/YYYY-MM.md`; durable delivery state is in
the Allbert database and appears in the objective experience. If a delivery is
failed or uncertain, inspect the objective and audit entry, then use the normal
originating thread or next turn to recover. Do not delete ledger rows or resend
outside the registered channel boundary.

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

## Secret Vault (three-tier)

Settings Central always holds secret *references* (`secret://…`); where the
*values* live is resolved in tier order, and the resolution is always explicit —
never a silent choice:

1. **OS vault (tier 1)** — macOS Keychain (`security`) or Linux Secret Service
   (`secret-tool`). Used automatically when reachable. Values live in the OS
   keychain, outside Allbert Home. Storing a provider key here (e.g.
   `admin settings providers set-key openai`) needs **no**
   `ALLBERT_SETTINGS_MASTER_KEY` — that key is only for the tier-2 encrypted-file
   store. Setting a key writes the value to the vault, records the Settings-central
   `api_key_ref`, and is read back at runtime through the same tier (v0.63 M8.3).
2. **Encrypted file (tier 2)** — the existing `secrets.yml.enc` store, used as
   the documented fallback where no OS vault is reachable (e.g. a headless Linux
   daemon with no D-Bus session). The fallback is surfaced with a notice, not
   silent. This tier needs `ALLBERT_SETTINGS_MASTER_KEY` in a packaged prod
   release (no local `.settings_key` fallback there). A tier-1 read miss falls
   back here so keys written before the OS-vault routing landed stay readable.
3. **Env injection (tier 3)** — the five provider keys read from the environment
   for automation/CI. Read-only; surfaced in inspection as "env-provided" so it
   is never an invisible side channel.

Inspect and migrate:

```sh
allbert admin vault                 # resolved tier + why, OS-vault reachability, env-provided keys
allbert admin secrets migrate       # move encrypted-store secrets into the OS vault (confirmation-gated)
```

`allbert admin secrets migrate` is a confirmation-floored operation; run it with
`--dry-run` first to preview the reference set. It moves values only into a
reachable OS vault and never prints a raw secret. Override the resolved tier
with `ALLBERT_VAULT_BACKEND=os|encrypted_file|env` when you need to pin it.

Home export/import (see [export-import.md](export-import.md)) carries references
plus tier-2 material only; tier-1 OS-vault values are **not** in the archive —
re-provision or re-migrate them on the destination host.

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
