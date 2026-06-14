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
  later surface (v0.51).
- Tool discovery and MCP-first integrations (v0.42, implemented eval surface):
  discovery search egress stays
  within `External.HttpPolicy` (SSRF, private/link-local IP block, bounded
  timeout/body, redirect denial) and degrades to local-only when a registry is
  unreachable; optional keyed subregistries such as PulseMCP are skipped when
  their secret refs are missing; server `server.json` metadata and tool
  descriptions are never authority (schema-not-authority parity with v0.40); a
  discovered server
  connects only through the confirmation-gated `mcp_server_connect` consent
  showing the exact untruncated command/URL (consent-before-connect); dangerous
  run-command patterns are flagged; a tool-definition baseline hash detects
  rug-pulls on reconnect; the background scan is opt-in / paused-by-default
  (`mcp.discovery.enabled=false`) and writes only to a passive surface (no
  unprompted messaging, no auto-connect). The first integration pack keeps
  Calendar/Mail/GitHub MCP-configured and denies provider-specific core SDK
  dependencies; credentials stay scoped to the configured server, remembered
  `mcp://` grants do not cross server ids, notes/files writes require
  `:notes_file_write` confirmation, and integration output does not auto-promote
  into markdown memory. Implemented eval rows:
  `mcp-discovery-ssrf-001`, `-tool-poisoning-inert-001`,
  `-permission-boundary-001`, `-rug-pull-detection-001`,
  `-rug-pull-no-false-positive-001`, `-supply-chain-command-flag-001`,
  `-server-impersonation-001`, `-consent-before-connect-001`,
  `-registry-unavailable-degrades-001`, `-schema-not-authority-001`,
  `integration-core-dependency-deny-001`, `integration-credential-scope-001`,
  `integration-resource-grant-001`, `integration-memory-no-auto-promote-001`,
  `integration-mcp-native-boundary-001`,
  `notes-files-reference-plugin-action-boundary-001`, and
  `notes-files-namespace-isolation-001`.
- Browser session state and web research (v0.43 implemented surface): browser
  navigation grants remain per-domain/per-operation on target URLs, the
  session URI is not grant authority, form-fill/download default denied with
  confirmation floors, screenshots require credential-input redaction,
  page/PDF content is evidence only, and driver/PDF-parser availability is
  doctor-gated before sessions start. Browser traces and audits redact cookies,
  Authorization, URL userinfo, and credential-shaped query values; artifacts
  live under `<ALLBERT_HOME>/cache/browser/<session_id>/`. Implemented eval
  rows: `browser-prompt-injection-001`,
  `browser-cross-domain-grant-001`,
  `browser-cookie-session-redaction-001`,
  `browser-screenshot-sensitive-data-001`, `browser-form-fill-deny-001`,
  `browser-document-extract-bound-001`,
  `browser-redirect-chain-escape-001`,
  `browser-subresource-policy-001`,
  `browser-prompt-injection-via-pdf-001`,
  `browser-prompt-injection-via-comment-001`,
  `browser-extraction-byte-cap-enforced-001`,
  `browser-pdf-page-cap-enforced-001`,
  `browser-screenshot-input-field-redaction-001`,
  `browser-session-isolation-001`, `browser-cookie-not-persisted-001`,
  `browser-download-denied-by-default-001`,
  `browser-malformed-pdf-fails-closed-001`,
  `browser-grant-cross-operation-deny-001`, and
  `browser-supply-chain-driver-binary-001`.
- Plan/Build and operator workflow YAML (v0.44 implemented surface):
  workflow YAML is inert declarative data under
  `<ALLBERT_HOME>/workflows/`; schema shape, ids, step count, per-step
  param size, expressions, and action names are validated before a run.
  `workflow://` and `plan://` ids are trace/audit identities only, never
  grants. YAML `confirm: true` may raise friction but cannot lower a
  registered action floor. The plan-start gate remains
  `:workflow_run_start` with a `:needs_confirmation` floor, and
  per-step action permissions still apply during execution. Plan preview,
  confirmation metadata, traces, CLI output, and run-progress summaries
  must redact secret-shaped operator inputs and params.
  Implemented eval rows: `workflow-yaml-unknown-key-001`,
  `workflow-yaml-script-deny-001`,
  `workflow-yaml-dynamic-action-name-deny-001`,
  `workflow-yaml-secret-substitution-deny-001`,
  `workflow-yaml-env-substitution-deny-001`,
  `workflow-yaml-cycle-reject-001`,
  `workflow-yaml-forward-ref-reject-001`,
  `plan-preview-not-authority-001`,
  `plan-run-start-confirmation-required-001`,
  `plan-step-permission-not-downgradable-001`,
  `plan-cancel-cooperative-001`,
  `subagent-delegation-permission-boundary-001`,
  `delegate-agent-authority-boundary-001`,
  `workflow-expand-rejects-bad-yaml-001`,
  `workflow-step-cap-enforced-001`, and
  `workflow-param-bytes-cap-enforced-001`.
- Marketplace Lite (v0.45 implemented surface): the shipped catalog is local
  reviewed metadata under `priv/marketplace/`; installs verify hashes before
  writing, write only under configured Allbert Home-rooted marketplace targets,
  and remain disabled/untrusted. `marketplace.enabled=false` disables all
  marketplace actions; `permissions.marketplace_install=denied` is the narrower
  install/rollback lock. `plugin_index` is browse-only, templates are
  `metadata_only`, workflow YAML is never installed, operator-modified mirrors
  are advisory, and `marketplace_doctor` detects index parse errors, hash
  mismatch, orphan installs, installed tamper, and schema-version drift.
  Implemented eval rows:
  `marketplace-install-creates-disabled-state-001`,
  `marketplace-install-grants-no-permission-001`,
  `marketplace-skill-disabled-default-001`,
  `marketplace-hash-mismatch-rejects-install-001`,
  `marketplace-unknown-schema-version-rejects-001`,
  `marketplace-index-unknown-key-rejects-001`,
  `marketplace-bundle-manifest-missing-required-field-rejects-001`,
  `marketplace-bundle-path-traversal-rejects-001`,
  `marketplace-install-target-outside-allbert-home-rejects-001`,
  `marketplace-workflow-yaml-never-installed-001`,
  `marketplace-code-plugin-deny-001`,
  `marketplace-template-metadata-no-execute-001`,
  `marketplace-permission-grant-deny-001`,
  `marketplace-provenance-hash-001`,
  `marketplace-rollback-removes-install-001`,
  `marketplace-installed-bundle-survives-upgrade-001`,
  `marketplace-operator-modified-mirror-is-advisory-001`,
  `marketplace-disabled-skill-cannot-execute-001`,
  `marketplace-doctor-detects-orphan-install-001`, and
  `marketplace-doctor-detects-tampered-bundle-001`.
- Delegation hardening and research specialist (v0.46 implemented surface):
  `research.specialist` is a delegated objective agent, not a new browser
  authority. It registers only `research` and `summarize_url` commands,
  dispatches through the existing `delegate_agent` action, and orchestrates
  v0.43 browser navigate/extract actions through `Actions.Runner.run/3`.
  Browser navigation still confirms or uses a v0.43 remembered URL-prefix
  grant; research output is advisory, never auto-promotes to memory, and
  browser sessions are closed after completed, failed, and pending research
  command paths. Implemented eval rows:
  `delegation-does-not-widen-authority-001`,
  `research-navigation-still-confirms-001`,
  `research-output-advisory-not-authority-001`,
  `research-no-memory-autopromote-001`,
  `research-max-sources-cap-001`,
  `research-inherits-browser-grant-scope-001`,
  `research-session-always-closed-001`,
  `delegate-agent-isolation-001`, and
  `delegate-command-allowlist-enforced-via-objective-001`.
- Operator-supervised self-improvement (v0.47 implemented surface):
  discovery reads a redaction-inheriting trace index and writes only advisory
  suggestions; suggestion packets carry no authority; skill/workflow/memory
  drafts are inert until a separate confirmed promotion action writes through
  an existing live path; repeated use never grants permission. Implemented
  eval rows:
  `self-improvement-read-only-pattern-scan-001`,
  `self-improvement-suggestion-no-authority-001`,
  `self-improvement-draft-disabled-untrusted-001`,
  `self-improvement-memory-workflow-draft-only-001`,
  `self-improvement-repeated-use-no-permission-grant-001`,
  `self-improvement-trace-index-redaction-001`, and
  `self-improvement-promotion-requires-confirmation-001`.
- Operator-supervised self-improvement handoff drafts (v0.47b implemented
  surface): template-backed and capability-gap drafts create only inert v0.37
  dynamic drafts until the existing sandbox/gate/integration path runs;
  marketplace metadata is descriptive only; delegate-plugin drafts register no
  agent; objective drafts frame only through confirmed objective promotion; and
  marketplace actions remain separately confirmation-gated. Implemented eval
  rows:
  `self-improvement-marketplace-metadata-no-authority-001`,
  `self-improvement-template-backed-draft-inert-001`,
  `self-improvement-delegate-plugin-draft-inert-001`,
  `self-improvement-code-draft-gate-required-001`,
  `self-improvement-integrate-requires-confirmation-001`,
  `self-improvement-unsafe-capability-request-denied-001`, and
  `self-improvement-marketplace-publish-confirmation-001`.
- Channel Pack 1 (v0.52 implemented surface): Discord and Slack use the shared
  channel adapter boundary, ADR 0016 approval primitives, ADR 0056
  `:channel_message_inbound` floor, and ADR 0057 cross-channel threading.
  Post-audit remediation added live WebSockex-backed Discord Gateway and Slack
  Socket Mode transport processes while keeping release evidence redacted.
  External provider ids, callback ids, Slack `thread_ts`, Discord message ids,
  `owner_scope`, and `receiver_account_ref` are not permission authority.
  Allowlists and identity mapping gate runtime submission, callback clickers are
  re-resolved per interaction, bot tokens are Settings Central secret refs, and
  `permissions.channel_message_inbound=denied` rejects mapped messages before
  runtime or callback resolution.
  `ChannelThread` records outbound refs only for reply placement and echo-loop
  suppression. Implemented eval rows:
  `discord-slack-spoofing-001`,
  `team-channel-replay-001`,
  `group-leakage-001`,
  `reply-body-command-injection-001`,
  `callback-scope-leakage-001`,
  `dm-vs-workspace-auth-001`,
  `discord-interactions-signature-verification-001`,
  `slack-request-signing-verification-001`,
  `discord-guild-allowlist-001`,
  `slack-workspace-allowlist-001`,
  `slack-channel-allowlist-001`,
  `approval-primitive-honor-discord-001`,
  `approval-primitive-honor-slack-001`,
  `approval-primitive-honor-telegram-001`,
  `approval-primitive-honor-email-001`,
  `channel-descriptor-missing-primitives-rejected-001`,
  `bot-token-secret-redaction-discord-001`,
  `bot-token-secret-redaction-slack-001`,
  `channel-inbound-permission-floor-001`,
  `channel-inbound-permission-enforcement-001`,
  `callback-clicker-authorization-001`,
  `provider-thread-not-authority-001`,
  `owner-account-thread-key-isolation-001`,
  `echo-loop-suppression-001`,
  `cross-channel-resume-same-user-001`,
  `threading-capability-missing-rejected-001`,
  `identity-link-no-auto-merge-001`, and
  `unified-view-redaction-001`.
- v0.53 opens by retro-validating the older Telegram and email channels against
  real providers before new mobile adapters land: provider doctors, outbound and
  inbound external smokes, operator guides, live manual checks, evidence capture,
  and raw-token/credential leak scans are release-blocking M5 scope.
- v0.53 adds Matrix, WhatsApp Cloud API, and Signal `signal-cli` scope:
  identity mapping, replay, pairing, group leakage, callback ownership,
  KeyCustody leak/audit checks, signal-cli local-control endpoint/key-file
  permissions, trust-class unified-view/resume gating, WhatsApp raw-body signature
  denial before parse, phone-number redaction, reply-key/quote-TTL behavior, and
  mandatory `:list` approval fallback coverage remain v0.53 scope.
- Voice, image, screenshot, and generated media resource retention, redaction,
  provider cost, and cloud-upload policy. v0.48 narrows the voice portion:
  microphone capture and credentialed remote STT/TTS stay confirmation-gated,
  raw audio is excluded from traces by default, audio retention is default-off,
  and STT/TTS cost or usage metadata is display-only. v0.49 narrows the
  vision/image portion: `image://capture/<id>` and `screen://capture/<id>` are
  operator-supplied inert identifiers, remote image generation stays
  confirmation-gated, raw image bytes and generated resource paths are redacted
  from traces/action metadata, image retention is default-off, and image
  generation usage/cost metadata is display-only. Profile metadata such as
  audio/video input support, realtime transport, accepted formats, or
  local/bundled/remote deployment mode is diagnostic routing data only; it does
  not authorize cloud upload, always-on microphone capture, autonomous OS screen
  capture, arbitrary media fetches, or video ingestion. The v0.48 transcode
  helper is bounded to configured local inputs and fixed output formats, with
  source/output paths redacted from traces; v0.49 image normalization is bounded
  constrain-and-reject without a resize/transcode dependency, and generated
  image outputs use sniffed returned bytes rather than provider-declared MIME as
  metadata authority.
- Artifacts Central (v0.50 implemented surface): content-addressed artifact
  identities are immutable and inert; raw bytes and local paths are redacted
  from traces/logs/metadata; `artifact://sha256/<hex>` does not grant read
  authority; delete requires confirmation; retention is default-off; ingest
  bounds are enforced before write; the supervised Jido ingestion sensor is
  advisory only and has no private writer; thread links are provenance only.
  Implemented eval rows: `artifact-content-address-immutable-001`,
  `artifact-bytes-trace-redaction-001`,
  `artifact-identity-no-authority-001`,
  `artifact-delete-confirmation-001`,
  `artifact-retention-default-off-001`,
  `artifact-ingest-bounds-001`,
  `artifact-sensor-advisory-only-001`, and
  `artifact-thread-link-no-authority-001`.
- v0.51 public protocol auth, rate limits, redaction, confirmation ownership,
  and text-first content denial across MCP server, OpenAI-compatible API, and
  ACP server. HTTP bearer tokens prove redaction, revocation denial, and
  rate-limit-before-runtime behavior; replay prevention is not claimed unless a
  nonce/signature/token-binding/idempotency mechanism is added. OpenAI/ACP
  image, audio, resource, filesystem-root, and client-supplied MCP-server
  payloads do not grant media, filesystem, or MCP authority. Public AG-UI/A2UI
  and MCP Apps iframe evals remain parked post-1.0.
- Future self-improvement hardening beyond v0.47b remains limited to later
  capability surfaces, such as channel-derived trace sources and export/import
  preservation of reviewed drafts.

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
