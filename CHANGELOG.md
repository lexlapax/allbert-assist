# Changelog

## How Agents Should Use This File

Use this changelog as shipped-history context. Search by version or subsystem
when a task touches released behavior. ADRs, active plans, tests, and code are
more authoritative for current design and implementation. Do not bulk-read old
plans unless the task requires historical detail.

Do not add AI-tool attribution, co-author trailers, or generated-by footers to
changelog entries or release notes.

## v0.52.0 - Channel Pack 1 And Cross-Channel Threading

Status: implemented as `0.52.0` on 2026-06-10 and ready for operator
real-provider smoke/manual validation before release tag. Current version
metadata is `0.52.0`.

Plan: `docs/plans/v0.52-plan.md`.
Request flow: `docs/plans/v0.52-request-flow.md`.
Operator docs: `docs/operator/discord-channel.md`,
`docs/operator/slack-channel.md`.
Developer docs: `docs/developer/channel-approval-primitives.md`,
`docs/developer/cross-channel-threading.md`.

### Added

- Discord and Slack source-tree channel plugins with adapters, parsers,
  renderers, redacted clients, provider doctors, Settings Central fragments,
  and `mix allbert.channels discord|slack` CLI surfaces.
- ADR 0016 channel approval primitives through
  `AllbertAssist.Approval.Handoff.render/2`; Discord, Slack, Telegram, email,
  web, and CLI descriptors now declare their supported primitive sets.
- ADR 0056 channel inbound trust tier:
  `:channel_message_inbound` has a `:needs_confirmation` floor, allowlist and
  identity checks run before runtime submission, and callback clickers are
  re-resolved per interaction.
- ADR 0057 cross-channel conversation threading:
  `thread_channel_refs`, `conversation_message_refs`, and
  `cross_channel_identity_links`; `Conversations.ChannelThread`; unified
  redacted history; explicit `resume_thread_on_channel`; and echo-loop
  suppression for Allbert's own outbound provider messages.
- `mix allbert.conversations show|resume` for operator inspection and explicit
  cross-channel resume.
- `mix allbert.test release.v052` deterministic release lane,
  `mix allbert.test external-smoke -- discord_slack` real outbound/threading
  smoke, and `mix allbert.test external-smoke -- messaging_channel_inbound`
  live messaging-channel inbound smoke.
- Post-audit remediation replaced the Discord Gateway and Slack Socket Mode
  deferred transport modules with WebSockex-backed real transport processes, wired
  adapter startup in configured live mode, and enforced
  `:channel_message_inbound` before runtime or callback resolution.
- M8R4 added the generic `messaging_channel_inbound` external smoke for live
  Discord Gateway `READY`, Slack Socket Mode `hello`, and mapped @mention
  delivery evidence. DM delivery, provider button approve/deny,
  unmapped/non-allowlisted click rejection, and reconnect/RESUME remain manual
  pre-tag evidence.
- 28 v0.52 `:channel_pack` security eval rows covering ingress spoofing,
  replay/dedupe, group leakage, callback scope, primitive selection, secret
  redaction, inbound permission floor/enforcement, provider-thread non-authority, explicit
  identity links, same-user resume, and unified-history redaction.

### Changed

- Telegram, email, web, and CLI channel surfaces now declare `threading:` and
  write through the shared cross-channel thread substrate without changing their
  existing operator-visible output.
- Version metadata now reports `0.52.0` across the umbrella, core app, web app,
  README, and `AllbertAssist.App.CoreApp.version/0`.
- Roadmap, vision, future-features, security-hardening, request-flow, and agent
  context docs now describe v0.52 as implemented substrate for v0.53 mobile
  channels.
- ADR 0016's v0.52 amendment, ADR 0056, and ADR 0057 are accepted for the
  implemented v0.52 surface.

### Security

- Provider thread ids, provider message ids, Slack `thread_ts`, Discord
  `message_reference`, callback ids, `owner_scope`, and
  `receiver_account_ref` are routing metadata only; they never grant permission
  or become Allbert `thread_id` authority.
- Discord and Slack token settings are secret refs; raw bot/app tokens are
  resolved only through Settings Central secrets in real client mode and are
  redacted from request-shape diagnostics, traces, audits, and release evidence.
- `permissions.channel_message_inbound=denied` rejects mapped Discord/Slack
  messages after allowlist + identity resolution and before runtime submission
  or callback resolution.
- Discord Interactions HTTP, Slack Events API HTTP, Discord sharding, Slack
  multi-workspace OAuth, and hosted channel fan-out remain parked.

### Verification

- `MIX_ENV=test mix compile --warnings-as-errors` passed after post-audit
  remediation.
- M8R focused suite passed after the live-inbound evidence lane was added:
  `44 tests, 0 failures, 1 skipped`.
- Focused post-audit channel/eval suite passed: `32 tests, 0 failures`.
- Focused inbound policy/permission gate passed: `25 tests, 0 failures`.
- `MIX_ENV=test mix allbert.test release.v052` passed with deterministic
  evidence at
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v052/p0-11013/home/release_evidence/v052/release-v052-1781154314.json`.
  Step counts: channel contracts 36 tests, Discord/Slack plugins 27 tests,
  cross-channel history/CLI 12 tests, workspace continuity web 69 tests,
  channel-pack security eval 18 tests; secret scan passed with no findings.
- Full `MIX_ENV=test mix allbert.test release` passed with evidence at
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-13251/home/release_evidence/gates/release-2026-06-11T05_26_39Z.json`.
  Phase counts: core 1724 tests, web 151 tests, StockSage 197 tests, channel
  plugins 19 tests, Dialyzer 0 errors; compile, dependency, format, Credo, and
  evidence noise scans passed.
- `mix allbert.test external-smoke -- discord_slack` and
  `mix allbert.test external-smoke -- messaging_channel_inbound` remain required
  before release tag with sandbox Discord/Slack credentials. Operator manual
  validation must also cover live DM delivery, button approval, unmapped-clicker
  rejection, and reconnect/RESUME before tag.
## v0.51.1 - Public Protocol Validation Remediation

Status: corrective validation record for v0.51 operator manual validation,
merged after mainline version metadata had advanced to `0.52.0`.

### Changed

- Backported the v0.51 public-protocol validation-harness fix so StockSage app
  registration seeds `StockSage.Plugin` before validating `StockSage.App`
  actions.
- Moved cleanup registration before risky setup assertions in the affected MCP
  and public-protocol test harnesses so failed setup cannot leak confirmation
  roots into later tests.
- Confirmation store tests now clear and restore the confirmations app config,
  matching the path/settings isolation they already applied.
- The corrective branch validated the v0.51 remediation at `0.51.1`; after
  merge to main, active version metadata remains `0.52.0`.

### Verification

- M9 focused harness backport test passed with 31 tests and 0 failures:
  `MIX_ENV=test mix test apps/allbert_assist/test/mix/tasks/allbert_mcp_server_test.exs apps/allbert_assist/test/allbert_assist/public_protocol/mcp_stdio_server_test.exs apps/allbert_assist/test/security/v051_public_protocol_eval_test.exs apps/allbert_assist/test/allbert_assist/confirmations/store_agent_test.exs apps/allbert_assist/test/allbert_assist/confirmations/store_golden_test.exs`.
- M11 isolation regression test passed with 24 tests and 0 failures:
  `MIX_ENV=test mix test apps/allbert_assist/test/mix/tasks/allbert_mcp_server_test.exs apps/allbert_assist/test/allbert_assist/public_protocol/mcp_stdio_server_test.exs apps/allbert_assist/test/security/v051_public_protocol_eval_test.exs apps/allbert_assist/test/allbert_assist/actions/voice_local_runtime_test.exs`.
- `MIX_ENV=test mix compile --warnings-as-errors` passed on corrective commit
  `6469784a`.
- `ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release.v051`
  passed on corrective commit `6469784a`. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-6851/home/release_evidence/v051/release-v051-1781207402.json`.
- `ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release` passed on
  corrective commit `6469784a` with static compile, deps-unused, format,
  Credo, core tests, web tests, StockSage tests, channel plugin tests, and
  Dialyzer all green. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-13250/home/release_evidence/gates/release-2026-06-11T19_52_39Z.json`.
- M11 evidence scans found no `database is locked`, `SQLITE_BUSY`,
  `Exqlite.Connection`, `DBConnection.ConnectionError`, `unknown_app_namespace`,
  `unknown_setting`, raw bearer-token, API-key, or `sk-*` leakage signatures in
  the fresh evidence files/logs.
- Test validation disables `tzdata` autoupdate in `MIX_ENV=test`, preventing the
  dependency release-updater process from adding crash noise to fresh
  release-gate evidence.
- M12 fresh worktree replay passed from
  `/private/tmp/allbert-v051-m12-replay-749fe18b` on corrective commit
  `749fe18b`.
- `ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release.v051`
  passed in the fresh worktree. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-362563/home/release_evidence/v051/release-v051-1781214030.json`.
- `ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release` passed in
  the fresh worktree with static compile, deps-unused, format, Credo, core
  tests, web tests, StockSage tests, channel plugin tests, and Dialyzer all
  green. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-8066/home/release_evidence/gates/release-2026-06-11T21_42_50Z.json`.
- M12 evidence scans found no `tzdata_release_updater`, `FunctionClauseError`,
  `database is locked`, `SQLITE_BUSY`, `Exqlite.Connection`,
  `DBConnection.ConnectionError`, `unknown_app_namespace`, `unknown_setting`,
  raw bearer-token, API-key, or `sk-*` leakage signatures in fresh evidence.
- Manual operator validation is ready to resume at
  `docs/plans/v0.51-request-flow.md` step 5.

## v0.51.0 - Public Protocol Surfaces

Status: released and tagged as `v0.51.0` on 2026-06-10. Current version
metadata is `0.51.0`.

Operator doc: `docs/operator/public-protocol-surfaces.md`.
Developer doc: `docs/developer/public-protocol-surfaces.md`.

### Added

- Public MCP server surface over the existing runtime/action boundary:
  `mix allbert.mcp_server status|tools list|resources list|stdio`, MCP stdio,
  and JSON-only MCP HTTP `POST /mcp`.
- OpenAI-compatible HTTP shim for `GET /v1/models` and
  `POST /v1/chat/completions`, bounded to text Chat Completions compatibility.
- ACP stdio server for the implemented text-session subset:
  `mix allbert.acp_server status|stdio`.
- Inbound public-surface trust tier from ADR 0055:
  `:public_surface_call_inbound`, Settings-Central client tokens, rate limiting,
  API secure headers, bounded body handling, and client-scoped poll-by-id result
  readback.
- `mix allbert.public_protocol token create|rotate|revoke|list` for HTTP
  client bearer tokens.
- `mix allbert.test release.v051`, including deterministic fixture coverage for
  public-surface foundations, MCP stdio/HTTP, OpenAI-compatible mapping/web,
  ACP stdio, v0.51 security evals, and secret scan evidence.
- 34 v0.51 public-protocol security eval rows under the `:public_protocol`
  surface.

### Changed

- Umbrella, core app, web app, and `AllbertAssist.App.CoreApp.version/0`
  metadata now report `0.51.0`.
- Action registry capability discovery now ensures modules are loaded before
  checking exported capability metadata, removing startup-order drift in web
  app phases.
- HTTP public-surface rate limiting now fails closed if the supervised limiter
  is unavailable, and auth error responses apply API secure headers directly.
- MCP stdio now uses an Allbert-owned JSON-RPC line adapter for the public
  transport while retaining Hermes schema/callback support. The real OS
  subprocess fixture asserts stdout contains only protocol frames.
- Result-readback expiry now has a supervised Settings-Central sweeper
  (`public_protocol.result_readback_sweep_interval_ms`) so expired rows are
  zeroed without relying on a later client poll.
- Roadmap, plan, request-flow, operator, and developer docs now describe v0.51
  as implemented with current release evidence and documented operator
  validation steps.

### Security

- Public surfaces are default-off and default-empty. Tool exposure requires both
  `exposure: :agent` eligibility and explicit Settings Central allowlisting
  after deny-before-allow filtering.
- External clients cannot self-approve confirmations. ACP permission responses
  are advisory only, and confirmation-pending public calls resolve through
  operator-owned approval plus client-scoped readback.
- HTTP surfaces require Settings-Central client entries and Settings Secrets
  token material; absent, invalid, revoked, or rate-limited requests fail before
  runtime work.
- v0.51 is text-first. OpenAI/ACP non-text content, client-supplied tools,
  filesystem roots, and client-supplied MCP servers are rejected before runtime
  work.
- v0.51 does not serve artifacts as MCP resources. Future artifact serving must
  route through Artifacts Central and `:artifact_read`; raw store paths and
  `artifact://` metadata are never permission authority.
- v0.51 eval coverage now mechanically binds inventory rows to substantive
  public-protocol assertion groups.

### Verification

- `MIX_ENV=test mix compile --warnings-as-errors` passed.
- Focused remediation suites for stdio stdout discipline, MCP/ACP subprocess
  fixtures, readback sweeping, settings schema, and MCP HTTP protocol-version
  headers passed before the release gates.
- `MIX_ENV=test mix allbert.test release.v051` passed. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-13252/home/release_evidence/v051/release-v051-1781069964.json`.
- `MIX_ENV=test mix allbert.test release` passed. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-7/home/release_evidence/gates/release-2026-06-10T04_50_39Z.json`.
- Evidence scans found no `public protocol result readback sweep failed`,
  `database is locked`, `SQLITE_BUSY`, `Exqlite.Connection`,
  `DBConnection.ConnectionError`, or `unknown_app_namespace` noise. The
  v0.51 milestone gate owns the v0.51 secret-scan evidence; the aggregate
  release gate is the full compile/test/Dialyzer handoff.

## v0.50.1 - Artifacts Browser

Status: released and tagged as `v0.50.1` on 2026-06-09. Current version
metadata is `0.50.1`.

Operator doc: `docs/operator/artifacts-browser.md`.
Developer doc: `docs/developer/artifacts-browser.md`.

### Added

- Artifacts Browser shipped plugin/app (`plugins/allbert.artifacts/`, plugin id
  `allbert.artifacts`, app id `:allbert_artifacts`) over the v0.50 Artifacts
  Central store.
- Workspace Artifacts panel contributed through the app/surface contract and
  hydrated by `workspace_panel_surfaces/1`.
- `/apps/artifacts/<sha>` detail page route, with plugin-owned LiveView module,
  host router registration, SHA validation before store reads, metadata,
  provenance, retention, and confirmation-gated remove control.
- `mix allbert.artifacts list|show|threads|doctor|rm` plus list filters for
  type, origin, thread, since date, retention, lifecycle, and limit.
- Four v0.50b artifact-browser security eval rows:
  `artifacts-browser-read-only-via-action-001`,
  `artifacts-browser-no-raw-bytes-rendered-001`,
  `artifacts-browser-grants-no-authority-001`, and
  `artifacts-browser-delete-confirmation-001`.
- `mix allbert.test release.v050b`, including deterministic browser fixture
  seeding through `scripts/v050b_artifacts_browser_smoke.exs --seed-only`.

### Changed

- Umbrella, core app, web app, and `AllbertAssist.App.CoreApp.version/0`
  metadata now report `0.50.1`.
- The Artifacts Browser CLI help now lists the M4 retention and lifecycle
  filters.

### Security

- The browser plugin grants no authority: no actions, channels, settings
  schema, memory namespace, store ownership, or direct object-store access.
- All reads go through core `:artifact_read` actions; delete goes through the
  core confirmation-gated `delete_artifact` action.
- Panel, page, and CLI render redacted metadata only. Raw bytes and local paths
  remain out of LiveView assigns and CLI output.

### Verification

- `MIX_ENV=test mix test apps/allbert_assist/test/security/v050b_artifacts_browser_eval_test.exs apps/allbert_assist/test/security/security_eval_case_test.exs apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs`
  passed with 17 tests and 0 failures.
- `MIX_ENV=test mix test ../../plugins/allbert.artifacts/test/allbert_artifacts/plugin_test.exs ../../plugins/allbert.artifacts/test/allbert_artifacts/app_panels_test.exs ../../plugins/allbert.artifacts/test/mix/tasks/allbert_artifacts_test.exs`
  passed with 13 tests and 0 failures from `apps/allbert_assist`.
- `MIX_ENV=test mix allbert.test release.v050b` passed. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v050b/p0-7/home/release_evidence/v050b/release-v050b-1780973533.json`.
- Post-implementation static-gate remediation passed the full release handoff:
  `mix allbert.test release` passed with compile, deps-unused, format, Credo,
  core tests, web tests, StockSage tests, channel plugin tests, and Dialyzer.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-13250/home/release_evidence/gates/release-2026-06-09T03_32_08Z.json`.
- The v0.50b evidence scan found no `database is locked`, `SQLITE_BUSY`,
  `Exqlite.Connection`, or `DBConnection.ConnectionError` noise.
- Release evidence records browser fixture SHA
  `c9a2b5ecd64bfc421d4aac9c308cf5d02d899b16b6d2f48d85bf482e6a8060b2` and
  thread id `thread-v050b-artifacts-browser-smoke`.
- Chrome extension validation passed on `http://localhost:4063`: workspace
  filters rendered the fixture row, the detail page rendered linked provenance,
  raw fixture bytes were absent, and neither page had horizontal overflow.
- Post-remediation Chrome extension revalidation passed on
  `http://localhost:4062` after a full Chrome restart cleared a wedged
  extension/native-host session. Chrome browser control verified the filtered
  workspace panel, release fixture detail route, metadata/provenance rendering,
  metadata-only redaction, unique `Workspace panel` return link, and zero
  detail-page console warnings/errors.

## v0.50.0 - Artifacts Central

Status: implemented as the v0.50 core release and superseded by the `v0.50.1`
Artifacts Browser sidecar tag on 2026-06-09. Version metadata at the core
closeout was `0.50.0`.

### Added

- Artifacts Central: a Home-rooted, type-agnostic content-addressable store
  under `<ALLBERT_HOME>/artifacts`, addressed by
  `artifact://sha256/<hex>` with sharded SHA-256 object files and
  markdown-first metadata sidecars.
- Artifact Resource Access identity, operation classes, permissions
  (`:artifact_read`, `:artifact_write`, `:artifact_delete`), and the
  `artifacts` redaction surface. Content addresses are inert and never grant
  permission.
- Core registered actions:
  `put_artifact`, `get_artifact`, `list_artifacts`, `artifact_threads`,
  `delete_artifact`, and `artifact_doctor`; delete is confirmation-gated.
- `artifacts.*` Settings Central fragment with default-off retention,
  byte/MIME/type bounds, root policy, and GC settings.
- `artifact_thread_links` SQLite provenance edges for created-by/referenced-by
  conversation links, with by-thread listing and reverse artifact-to-thread
  lookup.
- Retained-media backfill for v0.48 audio, v0.49 vision uploads, and v0.49
  generated images. New retained workspace voice, workspace image, and
  generated-image writes route through Artifacts Central while transient
  scratch remains scratch.
- The first supervised `Jido.Sensor` ingestion path:
  `IngestionSensor` under `Jido.Sensor.Runtime`, explicit
  `IngestionConsumer` dispatch target, redacted
  `allbert.artifact.ingest_requested` signals, and writes only through
  `put_artifact`.
- Eight v0.50 artifact-store security eval rows:
  `artifact-content-address-immutable-001`,
  `artifact-bytes-trace-redaction-001`,
  `artifact-identity-no-authority-001`,
  `artifact-delete-confirmation-001`,
  `artifact-retention-default-off-001`,
  `artifact-ingest-bounds-001`,
  `artifact-sensor-advisory-only-001`, and
  `artifact-thread-link-no-authority-001`.
- `mix allbert.test release.v050`, a deterministic local-fixture release lane
  covering core store identity/policy, artifact actions, provenance links, GC,
  retained-media backfill, supervised sensor ingestion, workspace retained
  media, eval inventory coverage, and a v0.50 artifact/media secret scan.

### Changed

- Retained generated-image, workspace voice, and workspace image flows no longer
  write durable bytes directly to legacy media roots. The legacy roots remain
  migration/backfill inputs.
- v0.49 image and v0.48 audio resource identifiers remain media-resource
  handles; durable retained bytes now gain canonical artifact identity only
  through Artifacts Central.
- Historical Browser cache files remain outside v0.50 backfill. The Artifacts
  Browser panel/page/CLI ships as the v0.50b plugin/app over core read actions.

### Verification

- `MIX_ENV=test mix test apps/allbert_assist/test/security/v050_artifact_store_eval_test.exs apps/allbert_assist/test/security/security_eval_case_test.exs apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs`
  passed with 18 tests and 0 failures.
- `MIX_ENV=test mix allbert.test release.v050` passed. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v050/p0-13250/home/release_evidence/v050/release-v050-1780973143.json`.
- Post-implementation static-gate remediation passed `mix dialyzer` with
  `Total errors: 0, Skipped: 0, Unnecessary Skips: 0`, and the full
  `mix allbert.test release` gate passed in the v0.50.1 closeout evidence cited
  above.
- The v0.50 evidence scan found no `database is locked`, `SQLITE_BUSY`,
  `Exqlite.Connection`, or `DBConnection.ConnectionError` noise.

## v0.49.0 - Vision And Image Generation

Status: implemented as the v0.49 release. Current version metadata is
`0.49.0`; ready for operator manual validation before the release tag.

### Added

- Vision/image model profiles and capability preferences for `vision_input` and
  `image_generation`, using the v0.48 provider capability substrate rather than
  a separate image-provider framework.
- Image and screenshot resource identity for `image://capture/<id>` and
  `screen://capture/<id>`, image permission and operation classes, server-side
  image bounds, image metadata parsing, and image metadata redaction.
- Workspace image paste/upload controls for vision input. Operator-supplied
  image metadata is bounded server-side, passed into the existing
  `direct_answer` text path as ReqLLM multimodal content, and cleaned up when
  transient.
- `generate_image`, an internal resumable registered action wrapping
  `ReqLLM.generate_image/3`, with remote-provider confirmation, fixture image
  generation, approved confirmation resume, one bounded retry to the next
  capable image profile, and display-only usage/cost metadata.
- Opt-in local Ollama profiles for v0.49 media validation:
  `vision_ollama` (`qwen3-vl:8b`) and `image_ollama`
  (`x/z-image-turbo`, with `x/z-image-turbo:latest` accepted as an installed
  doctor alias).
- Eight v0.49 vision-modality security eval rows:
  `vision-media-size-bound-001`, `vision-binary-trace-redaction-001`,
  `vision-provider-capability-check-001`,
  `vision-operator-supplied-only-no-autocapture-001`,
  `vision-browser-screenshot-analysis-001`,
  `image-generation-floor-confirmation-001`,
  `image-generation-cost-display-only-001`, and
  `media-render-no-generated-ui-code-001`.
- `mix allbert.test release.v049`, a deterministic vision/image release lane
  using fake vision/image providers, Req.Test provider fixtures, fixture image
  files, browser screenshot cache-ref analysis, workspace image upload
  coverage, eval inventory coverage, and a v0.49 media secret scan.

### Changed

- `vision_input` and `image_generation` are capability-specific media bridges.
  There is still no catch-all `multimodal` capability, no generic audio/video
  understanding path, no video ingestion, and no image-specific ProviderHTTP
  module.
- Image and screenshot resource identifiers are inert. They do not grant
  permission, start autonomous OS capture, authorize provider upload, or create
  a durable artifact-store record.
- Generated image outputs are bounded local files with redacted metadata.
  Content hashes remain integrity/provenance metadata only; v0.50 Artifacts
  Central owns the canonical content-addressed artifact store.
- Generated image metadata is derived from sniffed returned bytes, not from a
  provider's requested/declared output MIME. A provider returning JPEG bytes to
  a PNG request is stored and validated as a bounded JPEG output system-wide;
  unsupported or unparsable bytes still fail.
- Fake vision/image providers remain deterministic automated-test fixtures
  only. Operator-visible live provider validation targets configured OpenAI and
  Gemini profiles through ReqLLM, with Ollama local smokes available for
  operator-selected local profiles. Gemma 4 Ollama tags are valid local
  vision-input candidates but are not image-generation models.

### Verification

- `MIX_ENV=test mix compile --warnings-as-errors` passed.
- Focused M5 security/task suite passed with 17 tests and 0 failures:
  `MIX_ENV=test mix test apps/allbert_assist/test/security/v049_vision_modality_eval_test.exs apps/allbert_assist/test/security/security_eval_case_test.exs apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs`.
- `MIX_ENV=test mix allbert.test release.v049` passed with image policy/core
  (`99 tests, 0 failures`), vision input (`11 tests, 0 failures`), image
  browser screenshot bridge (`12 tests, 0 failures`), image generation action
  (`15 tests, 0 failures`), workspace image input (`65 tests, 0 failures`),
  vision security eval (`19 tests, 0 failures`), and a clean v0.49 media
  secret scan that includes `cache/browser`. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v049/p0-11013/home/release_evidence/v049/release-v049-1780886771.json`.
- Final `MIX_ENV=test mix allbert.test release` passed with static compile,
  deps, format, Credo strict, 1,525 core tests, 123 web tests, 197 StockSage
  tests, 12 channel-plugin tests, and Dialyzer. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-1218/home/release_evidence/gates/release-2026-06-08T03_08_24Z.json`.
- M10 real-provider remediation passed after Gemini billing/model access was
  fixed: OpenAI, Gemini, local Ollama (`qwen3-vl:8b` + `x/z-image-turbo`), and
  a Gemma 4 local vision-candidate override (`gemma4:e4b`) all completed the
  v0.49 live smoke with clean redaction evidence. Gemini returned JPEG bytes
  for image generation and passed through the system-level generated-output
  normalization path.

## v0.48.0 - Voice Modality And Provider Capabilities

Status: implemented through M8R real-provider remediation and M8R7 local
voice runtime remediation. Version metadata was `0.48.0` at v0.48 closeout.

### Added

- Capability-aware provider/model profiles and media metadata for
  `text_generation`, `speech_to_text`, `text_to_speech`, `vision_input`,
  `image_generation`, `video_input`, `token_streaming`, `embeddings`, and
  `tool_use`.
- Ranked operator model preferences for primary, task-specific, and
  capability-specific model/profile selection, with legacy `intent.*` settings
  preserved as compatibility aliases.
- `doctor_voice_provider`, using the ADR 0047 redacted doctor envelope plus
  voice-specific capability, deployment-mode, format, local-runtime, and
  usage-metadata fields.
- Audio resource/security substrate for `mic://capture/<id>`, voice operation
  classes, voice permission floors, audio metadata redaction, default-off audio
  retention, and bounded transcode specs.
- `transcribe_voice`, `mix allbert.ask --voice AUDIO_FILE`, `mix allbert.ask
  --voice AUDIO_FILE --speak`, and confirmation-gated workspace microphone
  capture.
- `synthesize_voice` with display-only provider/usage/cost metadata and real
  local OpenAI-compatible, OpenAI remote, and Gemini remote TTS execution.
- Executable Allbert-owned local voice runtime, OpenAI remote, and Gemini
  remote voice adapters for STT/TTS. The local runtime is a loopback
  OpenAI-compatible endpoint at `http://127.0.0.1:5050/v1`, configured through
  `voice.local_runtime.*`, managed through `permissions.voice_local_runtime_manage`,
  protected by a per-Allbert-Home local runtime token for STT/TTS requests, and
  started/doctored by `mix allbert.voice.local doctor|start`.
- Telegram voice-note ingestion through bounded Bot API `getFile`/download
  handling followed by the shared `transcribe_voice` action.
- Sixteen v0.48 security eval rows. The original voice-modality rows are:
  `voice-provider-capability-no-authority-001`,
  `voice-preference-fallback-capability-check-001`,
  `voice-cli-file-bounds-001`, `voice-mic-confirmation-001`,
  `voice-audio-retention-default-off-001`, `voice-trace-redaction-001`,
  `voice-cloud-upload-policy-001`,
  `voice-tts-cost-metadata-display-only-001`,
  `voice-channel-authority-boundary-001`, and
  `voice-transcode-bounded-001`. M8R adds
  `voice-local-endpoint-loopback-only-001`,
  `voice-remote-https-secret-only-001`,
  `voice-anthropic-not-stt-tts-001`,
  `voice-transcode-materialized-bound-001`,
  `voice-call-failure-fallback-bounded-001`, and
  `voice-listen-think-speak-routing-001`.
- `mix allbert.test release.v048`, a deterministic voice-modality release lane
  that exercises real adapter code paths through local HTTP provider fixtures
  plus fixture audio. Fake STT/TTS remains automated-test fixture support only.

### Changed

- Provider capability metadata is routing context only; catalog defaults and
  doctor output do not grant permission, supply secrets, or authorize provider
  upload.
- Voice uses the shared Settings Central, Security Central, action registry,
  traces, confirmations, and provider resolver instead of a parallel voice
  provider system.
- Voice STT/TTS now route through the explicit `ProviderAdapter` behaviour.
  Local-endpoint, OpenAI remote, and Gemini remote paths are executable;
  bundled-local remains fail-closed/deferred, and fake is fixture-only.
- v0.48 release scope is corrected: fake providers are fixture-only, while the
  Allbert-owned local voice runtime, OpenAI remote STT/TTS, Gemini remote
  STT/TTS, and the local Ollama text turn are executable and covered by
  deterministic release fixtures.
- Allbert local voice runtime validation now defaults the Ollama STT backend
  to `gemma4:e2b`, the validated Mac local transcription path. Operators with
  sufficient memory may choose `gemma4:e4b`; `gemma4:e2b-mlx` and
  `gemma3n:e2b` were not accepted as release-validation defaults because the
  former returned an empty transcript and the latter did not advertise
  multimodal support in local Ollama metadata during manual validation.
- The local runtime Bandit start path no longer passes unsupported server
  registration options, and the Ollama STT backend now accepts Ollama's
  `application/x-ndjson` transcription response body before extracting text.
- Gemini STT now uses the stable `models/{model}:generateContent` inline-audio
  request shape, and STT adapters share one transcript response normalizer for
  OpenAI-compatible, Gemini, and local Ollama response bodies.
- Anthropic/Claude remains a text-generation provider in the middle of the
  voice loop; it is not a native v0.48 STT/TTS provider.
- Fake TTS/STT usage and cost metadata now reports `%{source: :unavailable}`
  instead of Allbert-computed byte counts or zero-cost packets.
- Telegram Bot API voice fetches now preflight through `External.HttpPolicy`
  and enforce `min(20 MB, voice.audio.max_bytes)` at channel fetch time.
- Realtime audio sessions, generic audio/video understanding, video input,
  cost dashboards, budget enforcement, and Discord voice remain future scope.
- ADR 0051, ADR 0042, ADR 0047, ADR 0052, roadmap, vision, future-features,
  agent context map, security-hardening notes, README, operator guide, and
  developer guide now reflect the shipped v0.48 scope, the implemented M8R7
  local runtime, and the v0.49 vision handoff.

### Verification

- `MIX_ENV=test mix compile --warnings-as-errors` passed.
- Focused v0.48 remediation suite passed with 68 tests and 0 failures:
  provider catalog/preferences, provider adapters, transcode, STT/TTS actions,
  CLI voice, v0.48 security evals, coverage guard, and Telegram voice handling.
- Focused M8R7 local runtime suite passed with 97 tests and 0 failures:
  local runtime router/auth/backend tests, lifecycle actions, registry,
  Settings Central, Security Central, voice doctor, and v0.48 eval coverage.
- Existing STT/TTS action diagnostics passed with 10 tests and 0 failures.
- `mix allbert.test release.v048` passed with provider capability core
  (`65 tests, 0 failures`, including local runtime router/auth/backend and
  lifecycle-action tests), voice action/CLI/channel (`52 tests, 0 failures`),
  workspace voice (`64 tests, 0 failures`), voice security eval
  (`20 tests, 0 failures`), and a clean v0.48 voice secret scan. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v048/p0-13250/home/release_evidence/v048/release-v048-1780851953.json`.
- Post-M8R7 manual local smoke on 2026-06-07 passed with `gemma4:e2b`:
  direct Ollama `/v1/audio/transcriptions`, Allbert local runtime
  `/v1/models`, `/v1/doctor`, token-backed STT, token-backed TTS, and the
  full `scripts/v048_voice_live_smoke.exs` STT -> Ollama text -> TTS loop.
  `gemma4:e4b` also produced a valid direct local transcription.
- Post-M8R7 manual Gemini smoke on 2026-06-07 passed after the stable
  `generateContent` STT correction: Gemini doctor, Gemini STT, local Ollama
  text turn, Gemini TTS, and trace leak scan all completed.
- Post-M8R7 release-readiness audit on 2026-06-07 closed the remaining static
  and full-gate drift: Dialyzer dead defensive clauses were removed, Credo
  complexity/alias-order findings were fixed, first-run onboarding now uses a
  disposable Allbert Home in tests, and the focused remediation suite passed
  with 67 tests and 0 failures.
- Authoritative post-M8R7 `MIX_ENV=test mix allbert.test release` passed with
  static compile, unused-deps, format, Credo, core (`1489 tests, 0 failures,
  4 skipped`), web (`122 tests, 0 failures`), StockSage (`197 tests, 0
  failures`), channel plugin (`12 tests, 0 failures`), and Dialyzer (`Total
  errors: 0`) phases clean. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-13254/home/release_evidence/gates/release-2026-06-07T18_43_28Z.json`.

## v0.47.1 - Operator-Supervised Self-Improvement Handoff Drafts

Status: implemented as the v0.47b point release. Current version metadata is
`0.47.1`; ready for operator manual validation before the release tag.

### Added

- Handoff draft kinds in the unified reviewed-draft store:
  `template_backed`, `marketplace_backed`, `delegate_plugin_request`,
  `capability_gap`, and `objective`.
- `promote_template_draft`, which routes reviewed template-backed LLM-tool
  drafts into the shipped v0.38 `create_from_template` path and produces an
  inert v0.37 dynamic draft with `gate_status: "not_run"`.
- `promote_capability_gap_draft`, which routes a reviewed capability-gap draft
  into `DynamicPlugins.request_draft/2`; live integration remains blocked
  until the existing sandbox/gate path passes.
- `promote_objective_draft`, which frames a v0.24 objective only after durable
  operator confirmation.
- Seven v0.47b security eval rows:
  `self-improvement-marketplace-metadata-no-authority-001`,
  `self-improvement-template-backed-draft-inert-001`,
  `self-improvement-delegate-plugin-draft-inert-001`,
  `self-improvement-code-draft-gate-required-001`,
  `self-improvement-integrate-requires-confirmation-001`,
  `self-improvement-unsafe-capability-request-denied-001`, and
  `self-improvement-marketplace-publish-confirmation-001`.
- `mix allbert.test release.v047b`, a deterministic fixture gate for the
  v0.47b handoff draft surface.

### Changed

- `integrate_dynamic_draft` now checks for gate-passed dynamic draft evidence
  before creating an integration confirmation, so ungated code-bearing drafts
  cannot even request live-integration approval.
- Marketplace-backed drafts store `Marketplace.list_entries/1` metadata only;
  marketplace install/publish decisions remain separate existing action paths.
- Delegate-plugin request drafts store v0.38 plugin-template previews and
  v0.46 delegate metadata only; they do not scaffold a plugin directory or
  register an objective delegate agent.
- ADR 0045, roadmap, vision, future-features, agent context map, security
  hardening, and operator/developer guides now reflect the shipped v0.47b
  scope and the v0.48 handoff.

### Verification

- `mix allbert.test release.v047b` passed with 39 handoff core tests, 11
  dynamic gate/loader tests, 8 security-eval tests, and a clean v0.47b secret
  scan. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v047b/p0-6851/home/release_evidence/v047b/release-v047b-1780716256.json`.
- Full `mix allbert.test release` passed with compile, dependency, format,
  Credo, core (`1411 tests, 0 failures, 4 skipped`), web (`120 tests,
  0 failures`), StockSage (`197 tests, 0 failures`), channel plugin
  (`12 tests, 0 failures`), and Dialyzer (`Total errors: 0`) phases clean.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-11012/home/release_evidence/gates/release-2026-06-06T03_11_09Z.json`.

## v0.47.0 - Operator-Supervised Self-Improvement

Status: implemented as the v0.47 release and superseded by the `0.47.1`
handoff point release. Version metadata at this release closeout was
`0.47.0`.

### Added

- `AllbertAssist.SelfImprovement.TraceIndex`, a read-only compiled view over
  redacted trace markdown under `<ALLBERT_HOME>/memory/traces/` for repeated
  prompts, action chains, corrections, and failed intents.
- A generalized discovery suggestion surface for self-improvement suggestions:
  `trace_to_skill`, `trace_to_workflow`, `memory_promotion`, and
  `memory_update`, all with `provenance: "self_improvement"` and no MCP
  candidate authority.
- The internal `discover_patterns` action plus intent routing for
  self-improvement discovery prompts and the `mix allbert.self_improvement`
  list/inspect CLI.
- `AllbertAssist.Drafts.Store`, a unified reviewed-draft facade that preserves
  v0.37 dynamic-code draft compatibility while adding inert skill, workflow,
  memory-promotion, and memory-update drafts under `<ALLBERT_HOME>/drafts/`.
- Internal draft actions for `create_self_improvement_draft`,
  `discard_self_improvement_draft`, `promote_skill_draft`,
  `promote_workflow_draft`, and `promote_memory_draft`.
- Operator and developer guides for the shipped self-improvement surface.
- Seven v0.47 security eval rows:
  `self-improvement-read-only-pattern-scan-001`,
  `self-improvement-suggestion-no-authority-001`,
  `self-improvement-draft-disabled-untrusted-001`,
  `self-improvement-memory-workflow-draft-only-001`,
  `self-improvement-repeated-use-no-permission-grant-001`,
  `self-improvement-trace-index-redaction-001`, and
  `self-improvement-promotion-requires-confirmation-001`.
- `mix allbert.test release.v047`, a deterministic fixture gate for the
  v0.47 self-improvement surface.

### Changed

- The v0.42 `Tools.Discovery.Suggestion` schema now allows self-improvement
  suggestion kinds with nullable `candidate_id`, keeping MCP discovery and
  self-improvement in one passive queue and one workspace panel.
- Dynamic code drafts are now listed through the unified draft facade as
  `kind: "code"` while remaining in the existing
  `<ALLBERT_HOME>/dynamic_plugins/drafts/` compatibility root.
- Promotion of non-code self-improvement drafts is confirmation-gated and
  writes only through existing live paths: instruction-only local skill files,
  live workflow YAML, or markdown memory append/update.
- ADR 0045, ADR 0032, ADR 0048, ADR 0041, the roadmap, vision, agent context
  map, future-features parking lot, and security-hardening notes now reflect
  the shipped v0.47 scope and the v0.47b handoff.

### Verification

- M6 focused security eval suite passed with 8 tests and 0 failures.
- `mix allbert.test release.v047` passed with 24 self-improvement core tests,
  5 surface tests, 8 security-eval tests, and a clean v0.47 secret scan.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v047/p0-11012/home/release_evidence/v047/release-v047-1780711417.json`.
- Full `mix allbert.test release` passed with compile, dependency, format,
  Credo, core (`1395 tests, 0 failures, 4 skipped`), web (`120 tests,
  0 failures`), StockSage (`197 tests, 0 failures`), channel plugin
  (`12 tests, 0 failures`), and Dialyzer (`Total errors: 0`) phases clean.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-8644/home/release_evidence/gates/release-2026-06-06T02_04_09Z.json`.

## v0.46.0 - Delegation Hardening And Research Specialist

Status: implemented as the v0.46 release. Current version metadata is
`0.46.0`; ready for operator manual validation before the release tag.

### Added

- `./plugins/allbert.research/` as the second native consumer of the v0.24
  delegate-agent substrate, registered as `research.specialist` with
  `research` and `summarize_url` commands.
- `mix allbert.research "topic or URL" [--max-sources=N]`, which frames a
  delegated research objective, dispatches through the Objective Runtime, and
  prints completed advisory summaries or pending browser-navigation
  confirmations.
- Inert research intent descriptors for the locked v0.46 research phrase
  corpus, plus a v0.46 `research_delegate` Plan/Build workflow fixture and
  inline delegate rendering coverage.
- Nine v0.46 security eval rows:
  `delegation-does-not-widen-authority-001`,
  `research-navigation-still-confirms-001`,
  `research-output-advisory-not-authority-001`,
  `research-no-memory-autopromote-001`,
  `research-max-sources-cap-001`,
  `research-inherits-browser-grant-scope-001`,
  `research-session-always-closed-001`,
  `delegate-agent-isolation-001`, and
  `delegate-command-allowlist-enforced-via-objective-001`.
- `mix allbert.test release.v046` deterministic stub-driver release evidence
  and opt-in `mix allbert.test external-smoke -- browser_research_delegate`.

### Changed

- Objective delegate steps now thread `action_params.command` through the
  existing `delegate_agent` action instead of hard-coding `execute`; command
  names are validated against registered delegate metadata without dynamic atom
  creation.
- A delegated browser research command remains read-only and advisory: no new
  permission class, operation class, URI scheme, or registered action was
  added, and browser navigation still requires v0.43 confirmation or a scoped
  remembered grant.
- Delegated research closes browser sessions on completed, failed, and pending
  navigation-confirmation paths so blocked research commands do not leave
  sessions open.
- Delegated research now defensively handles unexpected browser action runner
  returns in session start, navigate, extract, and close paths while keeping
  the current completed, pending, and denied response shapes.
- `AllbertResearch.Plugin.settings_schema/0` delegates to the named
  `AllbertResearch.Settings.Fragment` owner for the `research.*` schema
  without changing Settings Central composition.
- `mix allbert.test release.v046` removes stale `release-v046-*.json` files
  from its owned disposable evidence directory before writing the current run's
  evidence JSON.
- The security eval inventory now includes `:research_delegate` in the
  required runtime surface list, matching the shipped v0.46 eval rows.
- `allbert.ecto.migrate` now prepares test-env migrations through a normal
  `DBConnection.ConnectionPool` and skips duplicate test migrations when a
  direct read-only `schema_migrations` inspection proves the disposable
  database is already current. This preserves the M2 `journal_mode: :delete`
  fix while avoiding SQL Sandbox ownership contention in version-specific
  release gates.
- `README.md` is back to a consolidated project orientation: specific
  release-by-release mechanics live in this changelog, with forward planning in
  `docs/plans/roadmap.md`.
- Browser handoff descriptors no longer own the v0.46 research phrase corpus;
  browser-specific page/render/extract prompts remain browser handoffs.

### Verification

- Focused M4 core suite passed with 18 tests, 0 failures, and the external
  smoke file compiling in its default skipped mode.
- Focused Plan/Build web regression passed with 5 tests, 0 failures.
- Combined v0.46/v0.43 security eval gate passed with 16 tests, 0 failures.
- `mix compile --warnings-as-errors` passed from the umbrella root.
- M5 focused remediation tests passed for research delegation, settings
  fragments, security eval inventory, and v0.46 research delegate evals.
- `mix allbert.test release.v046` passed twice after M5; the final run wrote
  deterministic evidence to
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v046/p0-9090/home/release_evidence/v046/release-v046-1780693284.json`,
  left only the current v0.46 JSON in its owned evidence directory, and had no
  DB-lock signature matches.
- Seeded web reproduction `mix test --seed 199649` from
  `apps/allbert_assist_web` passed with 120 tests, 0 failures, and no
  Exqlite/DBConnection log after the workspace editor test waited for its
  offline revision refresh.
- Full `mix allbert.test release` passed with static compile, dependency,
  format, Credo, and Dialyzer phases green; core tests passed with 1,364 tests
  and 4 skipped, web tests passed with 120 tests, StockSage plugin tests passed
  with 197 tests, and channel/notes-files plugin tests passed with 12 tests.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-8066/home/release_evidence/gates/release-2026-06-05T21_30_08Z.json`.
  The final release JSON and phase logs had no `database is locked`,
  `Database busy`, `SQLITE_BUSY`, `Exqlite.Connection`, or
  `DBConnection.ConnectionError` matches.

## v0.45.1 - Gate Transparency And Precommit Decomposition

Status: implemented as the v0.45.1 developer-tooling patch release. Current
version metadata is `0.45.1`.

### Added

- `mix allbert.test commit` as the fast commit-time gate and `mix allbert.test
  prepush` as the high-coverage local handoff gate.
- A Mix-native development gate phase runner that records phase ids, cwd,
  redacted command args, timing, status, summaries, and bounded redacted output
  tails.
- Release/prepush timing evidence under `release_evidence/gates/` when an
  evidence root is provided.
- Full redacted per-phase log artifacts for evidence gates and failed phases,
  with ExUnit seed capture plus `.mix_test_failures` snapshots for failed Mix
  test phases.

### Changed

- `mix allbert.test release` now runs explicit release phases directly instead
  of delegating to `mix precommit` and then Dialyzer.
- `mix precommit` is now a compatibility shortcut for `mix allbert.test
  commit`; it is commit-time feedback, not release evidence.
- Fresh Allbert Home startup now runs required migrations before the normal
  Repo pool and runtime supervisors start, avoiding first-run SQLite connection
  lock noise during clean `mix allbert.*` validation.
- `mix ecto.migrate.allbert` now routes through an Allbert-owned migration task,
  and plain umbrella/child `mix test` setup prepares the database once through
  that task instead of re-expanding Ecto migration paths through child aliases.
- ADR 0049, the test strategy, README, roadmap, and agent context map now
  separate commit, prepush, release, version-specific release, focused, docs,
  and external-smoke gates.

### Verification

- Focused gate task tests passed:
  `MIX_ENV=test mix test apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs`
  (6 tests, 0 failures).
- `MIX_ENV=test mix precommit` passed through the new commit gate in ~6s
  (compile, format, Credo; no release-evidence claim).
- `MIX_ENV=test mix allbert.test prepush` passed in 377s; the high-coverage
  partitioned fast-local phase passed in 370s.
- `MIX_ENV=test mix allbert.test release.v045` passed with deterministic v0.45
  marketplace evidence.
- Fresh-home workflow bootstrap regression smoke passed three clean disposable
  homes with no `database is locked` / `Exqlite.Connection` output, then listed
  the v0.44 `multi_step` fixture from a fourth fresh home.
- Umbrella-root and direct child-app focused `mix test` smokes for core and web
  passed with disposable homes/databases and no SQLite lock or duplicate
  migration output.
- Final `MIX_ENV=test mix allbert.test release` passed in 778s with 1,339 core
  tests (3 skipped), 119 web tests, 197 StockSage plugin tests, 12 channel /
  notes-files plugin tests, and release Dialyzer at 0 errors.
- Final hygiene gates passed: `git diff --check`,
  `MIX_ENV=test mix format --check-formatted`, and
  `MIX_ENV=test mix allbert.test docs`.

## v0.45.0 - Marketplace Lite

Status: implemented as the v0.45 release. Current version metadata is
`0.45.0`; superseded by the v0.45.1 developer-tooling patch.

### Added

- Marketplace Lite as a local reviewed catalog under `priv/marketplace/`, with
  Allbert-author seed bundles for skills, templates, and browse-only plugin
  index metadata.
- Seven registered marketplace actions, eight `mix allbert.marketplace`
  subcommands, `marketplace://entry/<author>/<name>` Resource Access identity,
  `:marketplace_install` permission class, marketplace operation classes, and a
  Marketplace Catalog workspace panel.
- SHA-256 recursive bundle verification, installed-state tracking in
  `<ALLBERT_HOME>/marketplace/installed.json`, rollback, verify, mirror, and an
  ADR 0047-style `marketplace_doctor`.
- `marketplace.*` Settings Central fragment with `schema_version: 1`, master
  `marketplace.enabled` switch, custom cache/install/state paths, and ADR 0046
  draft field-convention coverage.

### Changed

- Marketplace installs always write disabled/untrusted skill or template state;
  catalog metadata, marketplace URIs, template metadata, and plugin-index
  descriptors grant no execution authority.
- Custom `marketplace.catalog.cache_path`,
  `marketplace.install.target_dir_skills`, and
  `marketplace.install.target_dir_templates` settings are honored only when
  they remain rooted under Allbert Home.
- `marketplace.enabled=false` now disables every marketplace action before
  read/write work, and workflow `.yaml` / `.yml` files fail closed at bundle
  manifest validation.
- Umbrella, core app, web app, and `CoreApp.version/0` metadata now report
  `0.45.0`.

### Verification

- Post-implementation remediation focused gate passed:
  `mix allbert.test focused -- apps/allbert_assist/test/allbert_assist/marketplace/catalog_install_test.exs apps/allbert_assist/test/allbert_assist/marketplace_test.exs apps/allbert_assist/test/allbert_assist/marketplace/templates_test.exs apps/allbert_assist/test/mix/tasks/allbert_marketplace_test.exs apps/allbert_assist/test/security/v045_marketplace_eval_test.exs apps/allbert_assist/test/security/security_eval_case_test.exs`
  (38 tests, 0 failures).
- Closeout gates passed: `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix allbert.test release.v045`, and
  `mix allbert.test release`.
- Final `MIX_ENV=test mix allbert.test release` passed with 1,335 core
  tests (3 skipped), 119 web tests, 197 StockSage plugin tests, 12
  notes-files plugin tests, and release Dialyzer at 0 errors.

## v0.44.0 - Plan/Build Mode And Operator Workflow YAML

Status: implemented as the v0.44 release. Current version metadata is
`0.44.0`.

### Added

- Plan/Build as a pinnable workspace surface over the v0.24 Objective Runtime,
  with Preview and RunProgress panels, plan-run identities, and advisory
  Plan Preview Contract packets.
- Operator-authored workflow YAML under
  `<ALLBERT_HOME>/workflows/<workflow-id>.yaml`, with a v1 schema derived from
  the current action registry snapshot plus step kinds, closed expression
  substitution, unknown-key diagnostics, and workflow caps.
- Seven operator-facing Plan-Build actions (`list_workflows`,
  `inspect_workflow`, `expand_workflow`, `preview_plan`, `start_plan_run`,
  `cancel_plan_run`, `list_plan_runs`) plus the internal `plan_step_confirm`
  continuation target.
- Three Plan/Build permission classes, `workflow://<id>` and
  `plan://run/<objective_id>` Resource Access identities, workflow and plan
  settings fragments, Plan/Build intent routing, CLI workflow/plan commands,
  operator/developer guides, and the deterministic `release.v044` gate.

### Changed

- Approved `start_plan_run` confirmations now frame objectives, persist
  workflow-expanded steps, and hand execution to the existing Objective Runtime
  instead of stopping at preview/proposed-step persistence.
- Workflow step execution now enforces sequential order, per-step
  confirmation upgrades, `if:` skips, `on_error` behavior, cooperative cancel
  semantics, subagent delegation visibility, and runtime
  `${steps.<id>.<field>}` resolution from completed step output aliases.
- Plan previews, workflow YAML, intent descriptors, URI ids, and advisory
  packet fields remain non-authoritative; all effectful work still crosses
  `Actions.Runner.run/3`, Security Central, confirmations, traces, and audits.
- Umbrella, core app, web app, and `CoreApp.version/0` metadata now report
  `0.44.0`.

### Verification

- M6-M8 focused remediation tests passed:
  `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/workflows/expander_test.exs apps/allbert_assist/test/allbert_assist/actions/plan_build_actions_test.exs apps/allbert_assist/test/security/v044_plan_build_eval_test.exs`
  (18 tests, 0 failures).
- M9 deterministic release evidence passed:
  `MIX_ENV=test mix allbert.test release.v044` with 24 workflow/action/CLI
  tests, 4 intent/trace/workspace-panel tests, 7 Plan/Build LiveView tests, 11
  Plan/Build security eval tests, 0 failures, and a passing secret scan.
  Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v044/p0-13186/home/release_evidence/v044/release-v044-1780366009.json`.
- M10 closeout gates passed: `MIX_ENV=test mix compile --warnings-as-errors`,
  `MIX_ENV=test mix allbert.test release.v044`, and `git diff --check`.

## v0.43.0 - Browser And Web Research

Status: implemented as the v0.43 release. Current version metadata is
`0.43.0`.

### Added

- `./plugins/allbert.browser/` with browser settings, doctor, supervised
  ephemeral sessions, a real plugin-owned Playwright/Chromium bridge, the
  deterministic stub driver used by release tests, and registered `browser_*`
  actions for doctor, start, navigate, extract, screenshot, click, fill,
  download, session list/close, cache sweep, and research handoff.
- `browser://session/<id>` Resource Access identity, browser operation classes,
  seven `:browser_*` permission floors, per-domain navigation grants, and
  shared URL preflight via `External.HttpPolicy`.
- Bounded browser evidence extraction for HTML, markdown, plain text, and a
  local bounded PDF text layer parser, plus cache artifacts under
  `<ALLBERT_HOME>/cache/browser/<session_id>/`.
- Browser workspace results panel, named browser surface modules,
  operator/developer browser guides, `mix allbert.browser research <url>`, v0.43
  intent descriptors, and the `mix allbert.test release.v043` deterministic
  stub-driver gate with redacted evidence JSON.
- A true browser external smoke lane,
  `mix allbert.test external-smoke -- browser_research`, that drives local
  headless Chromium through Playwright against a local fixture.
- Nineteen v0.43 browser security eval rows covering prompt injection,
  cross-domain grants, cookie/session redaction, screenshot redaction, form
  fill/download deny defaults, extraction caps, redirect escape, subresource
  policy, malformed PDFs, cross-operation grants, session isolation, and
  unverified driver denial.

### Changed

- Redaction now covers browser cookies, `Set-Cookie`, bearer headers, URL
  userinfo, and credential-shaped query parameters before confirmation,
  diagnostics, and release evidence.
- Browser confirmations now include browser-specific resource metadata while
  preserving the channel primitive forward pin for typed commands, buttons,
  and links (renumbered to v0.50 in later v1.0 planning).
- Browser sessions now enforce max lifetime and idle timeout settings, browser
  cache writes enforce `browser.cache.max_bytes` with oldest-first eviction,
  the browser supervisor contributes the paused cache sweep job idempotently,
  and `browser.navigation.allowed_domains` is enforced when non-empty.
- Umbrella, core app, web app, and `CoreApp.version/0` metadata now report
  `0.43.0`.

### Verification

- R4 focused remediation tests passed:
  `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/tools/discovery_scan_test.exs apps/allbert_assist/test/allbert_assist/memory/review_cadence_test.exs`
  (6 tests, 0 failures).
- `MIX_ENV=test mix allbert.test external-smoke -- browser_research` passed
  against the real Playwright driver (1 test, 0 failures).
- `MIX_ENV=test mix allbert.test release.v043` passed with 104 browser
  action/extractor tests, 11 browser security eval/inventory tests, 0 failures,
  and a passing secret scan. Evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v043/p0-13189/home/release_evidence/v043/release-v043-1780326274.json`.
- Release warning gates passed: `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix credo --strict`, and `MIX_ENV=test mix dialyzer` with 0 errors.
- `MIX_ENV=test mix allbert.test release` passed Credo strict, 1,251 core
  tests, 112 web tests, 197 StockSage tests, 12 plugin tests, and Dialyzer
  with 0 errors.

## v0.42.2 - Integration Effects And Release Gate

Status: implemented as the v0.42 closeout release. Current version metadata is
`0.42.2`.

### Added

- Calendar, Mail, and GitHub MCP effect forms collect concrete operator
  arguments before Approval Handoff instead of submitting placeholder tool-call
  payloads.
- `mix allbert.test release.v042`, a deterministic no-external-network release
  smoke that writes redacted closeout evidence under
  `<ALLBERT_HOME>/release_evidence/v042/`.

### Changed

- Confirmation summaries for the first integration pack now include the
  submitted domain arguments for create-event, reply, and GitHub comment flows.
- v0.42 operator validation now points at the deterministic release-smoke gate
  instead of relying on the manual closeout command list.
- Umbrella, core app, web app, and `CoreApp.version/0` metadata now report
  `0.42.2`.

### Verification

- `mix allbert.test release.v042` passed with 59 core v0.42 tests, 10
  notes/files tests, 60 workspace LiveView tests, and 0 failures.
- `mix allbert.test release` passed Credo, 1,212 core tests, 112 web tests, 197
  StockSage tests, 12 plugin tests, and Dialyzer with 0 errors.

## v0.42.1 - Discovery Boundary, Live Trust Baseline, And CLI Reconciliation

Status: implemented as the v0.42 security and contract remediation release.

### Added

- A `mcp-discovery-permission-boundary-001` eval row covering unified
  `find_tools` when `permissions.tool_discovery=denied`.
- A `mcp-discovery-rug-pull-no-false-positive-001` eval row covering unchanged
  live servers whose registry manifests omit tool definitions.
- `mix allbert.mcp connect --candidate-id ID` as the explicit unambiguous
  connect form, plus safe unique-name resolution for bare connect input.

### Changed

- Unified `find_tools` now always keeps local action, skill, and configured-MCP
  discovery available under read-only permission, but only includes the remote
  MCP registry branch after the separate `:tool_discovery` permission allows it.
- Connected-server trust records now separate registry manifest metadata from
  the live `tools/list` baseline used by doctor/reconnect rug-pull checks.
- Notes/files reference skills use canonical `metadata.allbert.*` frontmatter,
  and local tool discovery degrades with a diagnostic if skill listing fails.
- Discovered HTTP/SSE endpoint URLs carrying credential-shaped userinfo or query
  parameters are rejected before settings are written.

## v0.42.0 - Tool Discovery + MCP-First Integration Pack 1

Status: implemented as the initial v0.42 base. It is superseded by the
`0.42.1` and `0.42.2` closeout releases; current version metadata is `0.42.2`.

Plan: `docs/plans/v0.42-plan.md`.
Request flow: `docs/plans/v0.42-request-flow.md`.
ADRs: `docs/adr/0048-tool-discovery-and-discovered-server-trust.md` and
`docs/adr/0039-mcp-first-native-plugin-second-integrations.md`.
Operator doc: `docs/operator/mcp-servers.md`.
Developer docs: `docs/developer/mcp-client.md` and
`docs/developer/how-to-create-an-allbert-app.md`.

### Added

- Unified `find_tools` discovery over local actions/skills/configured MCP tools
  and internet MCP registries.
- Remote MCP registry actions: `find_mcp_tools`, `mcp_fetch_server_manifest`,
  `mcp_evaluate_server`, and the confirmation-gated `mcp_server_connect`.
- Durable discovery store for candidates, evaluation reports, passive
  suggestions, and baseline trust records.
- Optional, paused-by-default background MCP discovery scan plus the passive
  Discovery Suggestions workspace panel.
- MCP-configured Calendar, Mail, and GitHub workspace panels driven only by
  registered v0.40 MCP actions.
- Integration intent descriptors and handoffs for Calendar, Mail, GitHub, and
  notes/files.
- `./plugins/allbert.notes_files/` as a native reference plugin with
  `search_notes`, `read_note`, confirmed `write_note`, workspace panels, skill
  paths, settings fragment, and a read-only memory namespace declaration.
- Executable v0.42 security eval rows for discovery SSRF, inert discovered
  metadata, rug-pull detection, dangerous command flagging, consent-before-
  connect, registry-degrade behavior, MCP-first integration boundaries,
  credential/grant scope, memory non-promotion, and notes/files namespace
  isolation.

### Changed

- Initial v0.42 metadata shipped as `0.42.0`; current release metadata is
  `0.42.2`.
- `CoreApp.version/0` contributes the integration panel intent descriptors and
  is now release-pinned to `0.42.2`.
- Operator/developer docs, roadmap, future-features, vision, agent-context-map,
  request-flow, and security-hardening now describe v0.42 as implemented and
  point the next milestone at v0.43.

### Security

- Discovered MCP servers remain inert descriptive metadata until
  `mcp_server_connect` is approved. The consent shows the exact command or URL
  before any `mcp.servers.<id>` setting is written.
- Discovery egress routes through `External.HttpPolicy`; private/link-local
  hosts, redirects, unallowlisted hosts/paths, and oversized responses remain
  denied or degraded.
- Server schemas, descriptions, registry metadata, and provenance signals are
  advisory only and cannot lower confirmation floors.
- Connected servers store a tool-definition baseline hash; doctor/reconnect
  detects changed tool definitions as rug-pulls.
- Calendar/Mail/GitHub panels use registered MCP actions instead of provider
  SDKs in core. Notes/files local writes require `:notes_file_write`
  confirmation and never auto-promote note bodies into markdown memory.

### Verification

- Focused v0.42 discovery/integration security evals passed.
- Release gate components passed: `mix precommit` and `mix dialyzer`. The final
  `mix precommit` run covered `1200` core tests, `112` web tests, `197`
  StockSage tests, and `11` Telegram/Email/Notes-files tests with `0 failures`;
  `mix dialyzer` reported `0` errors.
- Milestone tests and Chrome-extension UI validation passed during M1-M10 for
  discovery suggestions, integration panels, notes/files panels, and intent
  handoffs.

## v0.40.0 - MCP Client Integration

Status: implemented and ready for operator manual validation before release
tagging. Version metadata is `0.40.0`.

Plan: `docs/plans/v0.40-plan.md`.
Request flow: `docs/plans/v0.40-request-flow.md`.
ADR: `docs/adr/0038-mcp-client-trust-tier.md`.
Operator doc: `docs/operator/mcp-servers.md`.
Developer doc: `docs/developer/mcp-client.md`.

### Added

- Settings Central `mcp.servers.*` configuration, `mcp.stdio.allowed_launchers`,
  and encrypted `secret://mcp/<server-id>/<name>` refs.
- MCP permission and Resource Access vocabulary:
  `:mcp_tool_call`, `:mcp_resource_read`, `mcp://<server>/<encoded-uri>`,
  operation classes, access mode `:call`, and `mcp_server` / `mcp_tool` scope
  kinds.
- Hermes-backed MCP message codec plus Allbert-owned HTTP/SSE and stdio
  transports.
- Registered internal MCP actions: `mcp_doctor_server`, `mcp_list_tools`,
  `mcp_list_resources`, `mcp_read_resource`, and `mcp_call_tool`.
- `mix allbert.mcp doctor|tools|resources|read|call`.
- Executable v0.40 MCP security eval rows for schema-not-authority, valid
  confirmed tool calls, tool/resource confusion, prompt injection, server
  impersonation, secret redaction, stdio startup policy, and doctor redaction.

### Changed

- `mcp://` is now a supported Resource Access adapter; `agent://` and
  `agent+https://` remain unsupported.
- Intent routing now sends `mcp://` and explicit MCP list/read/call phrasing to
  the registered MCP actions instead of the unsupported-resource workflow.
- MCP stdio keeps stderr logs separate from stdout JSON-RPC and converts
  resolved env entries to the charlist format required by `Port.open/2`.
- Umbrella, core app, and web app version metadata are bumped to `0.40.0`.

### Security

- MCP schemas, descriptions, resource lists, and result bodies remain
  descriptive metadata only. They cannot grant permissions, create grants, or
  lower confirmation floors.
- MCP resource reads are grant-gated by Resource Access. MCP tool calls are
  confirmed per call and cannot be remembered or silently approved in v0.40.
- Approved real-server smoke validated the official GitHub MCP server in
  read-only stdio mode using the `.env` GitHub token through
  `secret://mcp/github/pat`; the token did not appear in action result or MCP
  audit output.

### Verification

- Focused MCP action, client, codec, intent, registry, and security eval
  coverage passed during M1-M6 implementation.
- M6 real-server smoke passed for official GitHub MCP over Docker stdio:
  doctor completed, 25 tools listed, `get_me` required confirmation, approval
  resumed the tool call, and the target completed with redacted result keys.

## v0.39.1 - Identity Slot And Active Memory

Status: implemented and ready for operator manual validation before release
tagging. Version metadata is `0.39.1`.

Plan: `docs/plans/v0.39b-plan.md`.
Request flow: `docs/plans/v0.39b-request-flow.md`.
Research note: `docs/research/active-memory-retrieval.md`.
Operator doc: `docs/operator/active-memory.md`.

### Added

- `identity` system memory namespace under `<ALLBERT_HOME>/memory/identity/`,
  declared outside app-id validation through
  `AllbertAssist.Memory.SystemNamespaces`.
- `:identity` as the 5th `AllbertAssist.Memory` category, plus
  `Memory.upsert_system_entry/1` for validated system-namespace writes.
- Registered read-only `retrieve_active_memory` action and deterministic
  Active Memory retrieval for direct-answer model turns over
  `review_status: :kept` chunks.
- Settings Central `active_memory.*` keys for enablement, top-K,
  chunk-size, recency half-life, thread/app/general affinity, and identity
  inclusion weights.
- `## Active Memory` trace section after `## Intent Candidates` and before
  `## Memory Review`, with body-free retrieved/excluded chunk metadata and
  score breakdowns.
- CLI inspection helpers:
  `mix allbert.memory list --namespace identity`,
  `mix allbert.memory list --category identity`, and
  `mix allbert.memory retrieve --query "..."`.
- Executable v0.39b security eval rows for identity inertness, read-only
  retrieval, no promotion/mutation, cross-namespace isolation, deterministic
  replay, identity namespace ownership, neutral app-leak exclusion, trace
  section placement, snapshot behavior, classifier exclusion, and kept-only
  retrieval.

### Changed

- Direct-answer model composition now invokes `retrieve_active_memory` after
  intent routing/classification and before answerer prompt composition.
  Retrieved chunks are advisory context only and do not affect routing,
  permission floors, confirmations, or authorization.
- Operator, developer, roadmap, future-feature, and security-hardening docs
  now describe v0.39b as implemented and keep embedding-backed retrieval,
  cross-thread/cross-app retrieval, pinning, and learned memory parked.
- Umbrella, core app, and web app version metadata are bumped to `0.39.1`.

### Security

- Identity memory is inert operator-authored markdown. Instruction-shaped
  identity content never grants authority, queues actions, executes tools, or
  bypasses Security Central.
- Active Memory is read-only and bounded by `active_memory.top_k` and
  `active_memory.chunk_max_bytes`; only `:kept` entries are candidates.
- Neutral/core retrieval excludes app-owned chunks for non-active apps, and
  identity-root files with conflicting app-owned metadata are excluded from
  Active Memory retrieval.
- The optional intent classifier receives bounded intent candidates only; raw
  Active Memory chunks are retrieved later and are not present in classifier
  inputs or decision trace metadata.

### Verification

- Focused v0.39b coverage passed for Active Memory, trace rendering,
  `mix allbert.memory`, and the security eval inventory.
- M5 release gate passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`. The precommit run covered core Allbert
  (1099 tests, 0 failures, 2 skipped), web (107 tests, 0 failures),
  StockSage/plugin (197 tests, 0 failures), and channel plugin
  (2 tests, 0 failures).

## v0.39.0 - First-Run Onboarding And Provider Control

Status: implemented and ready for operator manual validation before release
tagging. Version metadata is `0.39.0`.

Plan: `docs/plans/v0.39-plan.md`.
Request flow: `docs/plans/v0.39-request-flow.md`.
ADR: `docs/adr/0047-provider-doctor-contract.md`.

### Added

- Durable first-run onboarding objective framed from `mix allbert.onboard` and
  `/workspace?destination=workspace:onboard`, with resumable objective steps
  and progress recorded by the registered `onboarding_step_complete` action.
- Provider/model control commands: `mix allbert.model list`,
  `mix allbert.model use PROFILE [--enable-assist]`, and
  `mix allbert.model doctor PROFILE`.
- Registered `doctor_model_profile` and `set_active_model_profile` actions.
  The active-profile action writes only Settings Central safe keys:
  `intent.model_profile`, optional `intent.model_assist_enabled`, and the
  selected provider's `providers.<name>.enabled`.
- `providers.*.endpoint_kind`, with `local_ollama` defaulting to
  `local_endpoint` and credentialed providers defaulting to
  `credentialed_remote`.
- Workspace onboarding panel and Settings Central provider/model controls for
  doctor/use actions.
- Executable v0.39 security eval rows for onboarding redaction, doctor
  no-leak behavior, action-boundary enforcement, safe-key writes,
  identity-preview no-write behavior, provider doctor branch selection,
  redacted host output, and local-model missing/present states.

### Changed

- The shipped local model profile now defaults to `llama3.2:3b`, a real small
  Ollama model suitable for first-run local testing.
- Provider/model defaults are now seeded from
  `apps/allbert_assist/priv/provider_catalog/models.json`, with
  `anthropic_fast` using the canonical Claude Haiku 4.5 API ID
  `claude-haiku-4-5-20251001` and doctor alias comparison covering
  `claude-haiku-4-5`.
- Settings Central model profiles are now the only model-profile catalog
  surface: generated Jido aliases come from `model_profiles.*` and
  `model_profiles.*.aliases`; the shipped code-generation pair is `coding`
  for remote Gemini and `coding_local` for local Ollama `qwen2.5-coder:7b`.
- OpenAI model-profile `max_tokens` values are kept at or above the OpenAI
  Responses API minimum of `16`, and local Ollama base URL overrides no longer
  globally redirect the real OpenAI provider.
- ADR 0047 is accepted and pins the provider doctor redacted summary shape as a
  Tier-1 freeze candidate for v1.0.
- README, roadmap, operator onboarding, security-hardening, agent-context-map,
  and v0.39 plan/request-flow docs now describe v0.39 as implemented and keep
  identity slot plus Active Memory scoped to v0.39b.
- Umbrella, core app, and web app version metadata are bumped to `0.39.0`.

### Security

- Provider doctor accepts only configured model profile names; it derives the
  provider host from Settings Central, caps probe behavior, rejects unsafe
  host shapes per endpoint kind, disables redirects/retries, and returns only
  host-level redacted diagnostics.
- Credentialed-remote probes never return raw secrets, raw error bodies, full
  URLs, query strings, or credential fragments. Local-endpoint probes set
  `credential_ok: nil` and distinguish endpoint reachability from model
  availability without running `ollama pull`.
- The v0.39 identity-slot onboarding step is preview-only and writes nothing
  under `<ALLBERT_HOME>/memory/identity/`; v0.39b owns the write path.
- Dev, test, and release database config now derives the SQLite path from
  `ALLBERT_HOME` / `ALLBERT_HOME_DIR` as
  `<ALLBERT_HOME>/db/allbert.sqlite3` when `DATABASE_PATH` is not explicitly
  set. `DATABASE_PATH` remains an override for tests, migrations,
  compatibility, and operator escape hatches.
- Runtime-starting `mix allbert.*` tasks now use the application-level Ecto
  migrator for a missing or empty canonical Allbert Home database. A first
  operator run such as `mix allbert.onboard` no longer needs a preceding
  `mix ecto.create` or `mix ecto.migrate` command.

### Verification

- Focused onboarding, settings/action, Mix task, workspace, catalog/surface,
  and v0.39 security eval suites passed during M1-M4 implementation.
- M4 release gate passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.

## v0.38.1 - Templated Creation Release Polish

Status: released and tagged as `v0.38.1` on 2026-05-27 after operator manual
validation.

### Changed

- Centralized disposable template validation output in
  `AllbertAssist.Templates.Scaffold`: `ALLBERT_TEMPLATE_SMOKE=1` now redirects
  default developer scaffolds to `<ALLBERT_HOME>/template-smoke/<slug>/` for
  both Mix generator smoke runs and the `/workspace` Create developer-scaffold
  path. Explicit `--target` still wins for CLI generators.
- Updated operator and release docs with the accepted manual-validation path:
  disposable Allbert Home, Phoenix server startup, CLI generator checks,
  `/workspace` Create checks, live LLM-tool draft checks, and cleanup.
- Added dev-server bootstrap for fresh manual-validation homes: when
  `ALLBERT_HOME` or `ALLBERT_HOME_DIR` is set and `DATABASE_PATH` is not set,
  `mix phx.server` now creates and migrates a missing or empty dev SQLite
  database before Phoenix starts. `ALLBERT_DEV_AUTO_MIGRATE=1` also runs
  pending migrations for an existing dev database.
- Adjusted workspace LiveView form controls so text inputs, textareas, and
  selects use light blue/gray field surfaces with dark text across normal and
  dark workspace themes.
- Umbrella, core app, and web app version metadata are bumped to `0.38.1`.

### Verification

- Operator manual validation accepted the v0.38 CLI and web Create paths with
  disposable output under Allbert Home and no generated scaffold pollution in
  the repo `plugins/` tree.
- Fresh-home Phoenix startup was verified through `mix phx.server` without a
  separate operator migration command.
- Release gates passed after the disposable-scaffold and shared-writer updates:
  focused scaffold coverage, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, and `mix precommit`.

## v0.38.0 - Templated Creation

Status: initial `v0.38.0` implementation tagged on 2026-05-27, superseded by
the `v0.38.1` manual-validation polish release. The release ships
deterministic, reviewed template patterns for plugin, app, LLM-tool,
scheduled-flow, and objective-workflow scaffolds. Developer outputs are inert
source. Operator live creation writes only LLM-tool/action dynamic drafts and
then reuses the v0.36 sandbox gate and the v0.37 operator-confirmed live
loader.

Plan: `docs/plans/v0.38-plan.md`.
Request flow: `docs/plans/v0.38-request-flow.md`.
ADRs: `docs/adr/0036-templated-creation-and-pattern-registry.md`,
`docs/adr/0035-codegen-agents-and-live-integration-loader.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`,
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md`,
`docs/adr/0017-allbert-plugin-contract.md`.

### Added

- `AllbertAssist.Templates` facade, `TemplatePattern` behaviour, registry,
  parameter validation/normalization, safe relative-path checks, and
  deterministic reviewed-file rendering.
- Reviewed `plugin`, `app`, `llm_tool`, `flow`, and `objective` patterns with
  checked-in scaffold files under `apps/allbert_assist/priv/templates/v0_38`.
- Developer generator tasks:
  `mix allbert.gen.plugin`, `mix allbert.gen.app`, `mix allbert.gen.tool`, and
  `mix allbert.gen.flow`; generated app scaffolds validate through the existing
  `mix allbert.validate_app` task after compilation.
- `workspace:create` Canvas destination with template gallery, parameter form,
  preview tree, validation status, settings gates, and bounded diagnostics.
- Registered template actions:
  `render_template`, `validate_template`, `scaffold_template`, and
  `create_from_template`.
- Deterministic LLM-tool template live-draft creation through
  `AllbertAssist.Templates.LiveDraft`, storing `producer: "template_pattern"`
  and `template_pattern_id` in v0.37 draft metadata.
- `mix allbert.dynamic drafts list/show` producer and pattern labels for
  templated drafts beside `codegen_llm` drafts.
- Executable v0.38 security eval rows and
  `AllbertAssist.Security.TemplateCreationEvalTest` coverage for disabled
  creation, malicious params, path traversal, overwrite denial, authority
  bypass, integration-gate bypass, Canvas action-boundary denial,
  scheduled-flow escalation, and unsupported live targets.

### Changed

- Umbrella, core app, and web app version metadata are bumped to `0.38.0`.
- `docs/developer/how-to-create-an-allbert-app.md` now leads with
  generator-first app creation and links the pattern registry docs.
- Operator, security-hardening, onboarding, runtime-boundary, agent-context,
  roadmap, and future-features docs now describe v0.38 templated creation as
  implemented.
- `workspace:create` remains default-off behind `templates.create.enabled`;
  developer Mix-task scaffolds remain inert regardless of runtime settings.

### Security

- Templates and parameters grant no authority. Developer scaffolds never
  integrate live, do not alter compile paths, and cannot auto-enable jobs,
  routes, skills, providers, settings, or permissions.
- Existing scaffold roots require explicit `--force`; existing dynamic draft
  roots are denied rather than overwritten.
- Live integration is available only for the LLM-tool/action pattern because
  the v0.37.5 loader rejects plugin, app, panel, settings-fragment, memory,
  objective, job, route-page, and child-process artifact shapes.
- Templated live integration writes a draft only. Sandbox trial, sandbox gate,
  trusted validation, confirmation, live registration, and rollback remain the
  v0.36/v0.37 actions and approval surfaces.

### Verification

- Focused milestone coverage covered template rendering/scaffolding, generator
  tasks, registered template actions, dynamic draft inspection, Settings
  Central gates, workspace Create rendering, and the v0.38 security evals.
- Chrome extension browser control verified the `workspace:create` gallery,
  LLM-tool form, preview, enabled create action, templated draft output, and
  absence of browser console errors during M4/M5 UI closeout.
- Release closeout ran the project warning gate:
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`.

Manual verification instructions live in
`docs/operator/templated-creation.md`.

## v0.37.5 - Dynamic Code & Config Generation and Live Capability Integration

Status: released and tagged as `v0.37.5` on 2026-05-26. The v0.37 line was
first implemented as `0.37.0` on 2026-05-25, then reopened before the release
tag for v0.37.1 post-implementation audit hardening, v0.37.2 capability-first
generation, v0.37.3 delegated generated writes, v0.37.4 audit remediation, and
v0.37.5 fourth-audit closeout. The final release ships the full explicit
capability-gap loop: bounded model-backed planning/authoring/critique/repair,
v0.36 sandbox evidence, trusted validation, operator-confirmed live
integration, live action invocation, delegated memory/network effects through
reviewed facades, rollback, discard, lifecycle audit, and release docs.

Plan: `docs/plans/v0.37-plan.md`.
Request flow: `docs/plans/v0.37-request-flow.md`.
ADRs: `docs/adr/0032-dynamic-plugin-generation-and-sandboxed-loading.md`,
`docs/adr/0033-capability-gap-acquisition-and-trust-tiers.md`,
`docs/adr/0035-codegen-agents-and-live-integration-loader.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`.

### Added (v0.37.0)

- Default-off `dynamic_codegen.*` Settings Central policy, dynamic draft and
  integrated roots under Allbert Home, and `AllbertAssist.DynamicPlugins` as
  the public facade for file-backed dynamic draft metadata.
- Draft metadata structs and store helpers for tiers, source hashes, manifests,
  diagnostics, discard rules, read-only draft/integration inspection, and
  `mix allbert.dynamic drafts|integrations` status commands.
- Project-shaped staging and `AllbertAssist.DynamicPlugins.SandboxBridge` for
  v0.36 sandbox compile/trial/gate evidence, scanned-vs-compiled byte
  matching, report copy-back, and evidence tier transitions.
- Trusted AST/body validator, dynamic actions overlay, live loader,
  all-or-nothing integration unwind, boot reconciliation, rollback, emergency
  disablement, and high-trust integration/rollback confirmation resumption.
- Internal actions for draft requests, trial/gate runs, integration, rollback,
  disablement, and read-only status. Runtime-facing calls still resolve through
  `Actions.Registry` and execute through `Actions.Runner`.
- `Codegen.*` scaffold for explicit capability-gap draft requests:
  JidoBacked coordinator, producer-neutral gap vocabulary, provider-profile
  resolution, provider-call/usage budget checks, fail-closed diagnostics, and
  optional objective observation events.

### Added (v0.37.1 hardening)

- Executable v0.37 `codegen-*` security eval inventory rows covering untrusted
  load, sandbox bypass, gate skip, unconfirmed/advisory integration, trusted
  validator denials, action shadowing, rollback, emergency disablement, restart
  reconcile, redaction, generation budgets, and approval-surface denial.
- Dynamic lifecycle audit records under
  `<ALLBERT_HOME>/dynamic_plugins/audit/YYYY-MM.md` plus
  `allbert.dynamic_codegen.*` lifecycle signals for draft request, sandbox
  report consumption, tier transition, integration, rollback, disablement, and
  reconcile decisions.
- Bounded sandbox report history in draft `gate.reports`, preserving repeated
  report evidence and diagnostics instead of replacing all previous entries.

### Added (v0.37.2 generator)

- Source-bearing `codegen_llm` producer for explicit capability gaps. It calls
  the configured Jido.AI structured-generation profile, writes generated
  read-only action source and focused tests under the draft root, records source
  hashes/scan paths/compiled paths/manifest entries, and consumes provider-call
  and provider-usage budgets without granting live authority.
- Injectable `AllbertAssist.DynamicPlugins.Codegen.LLM` provider boundary,
  JSON-schema packet contract, deterministic action target naming/path helpers,
  and fake-provider test support for warning-gate-safe deterministic coverage.
- Trusted validator support for useful pure read-only action logic, including
  arithmetic, comparisons, string interpolation/concatenation, comprehensions,
  anonymous functions/captures, and curated pure standard-library calls while
  continuing to deny protected runtime, file, system, dynamic atom, and compile
  targets.

### Changed (v0.37.0)

- Umbrella, core app, and web app version metadata were initially bumped to
  `0.37.0` because v0.37 adds dynamic draft, sandbox bridge, live-loader,
  rollback, and request-scaffold actions to the core runtime boundary. The
  tagged release reports `0.37.5` after pre-tag audit remediation.
- The v0.37 shipped live loader integrates reviewed gate-passed action
  artifacts only: pure read-only actions plus delegated memory/network actions
  whose effects route through reviewed facades. Generated apps, panels,
  settings fragments, memory namespaces, objective wiring, route pages, and
  child processes remain rejected live targets until future validators exist.
- `Actions.Registry` now merges the dynamic action overlay across public
  registry seams while denying static/plugin/app/dynamic name collisions.
- Development, operator, runtime-boundary, agent-context, onboarding,
  security-hardening, roadmap, and dynamic-draft docs now describe the
  implemented v0.37 authority boundary and manual verification workflow.

### Changed (v0.37.1 hardening)

- Dynamic integration and rollback resume now verify the stored approved
  confirmation record, target action, dynamic-loader permission/execution mode,
  high-trust resolver surface, same-channel rule, and resuming target status
  instead of trusting caller-supplied context flags.
- Settings Central and the trusted validator are aligned to the shipped scope:
  `dynamic_codegen.allowed_targets == ["action"]` and
  `dynamic_codegen.allowed_action_permissions == ["read_only"]`.
- Failed mid-integration cleanup removes unstable integration roots and overlay
  entries from the attempted revision while preserving an existing live revision
  when a replacement is denied before compile.
- ADRs, roadmap, request-flow, operator guide, developer guide, and changelog
  now distinguish the shipped read-only action lifecycle plus inert codegen
  scaffold from deferred advisory provider authoring and broader generated
  app/config targets.

### Changed (v0.37.2 generator)

- Dynamic draft requests now produce source-bearing read-only action drafts
  when `dynamic_codegen.enabled`, `dynamic_codegen.provider_profile`, provider
  enablement, credentials, and budgets all pass. `codegen_scaffold` is now
  historical metadata; new generated drafts use `producer: codegen_llm`.
- The action-draft output schema now uses strict provider-compatible structured
  output semantics: every declared property is required, optional values use
  concrete empty defaults, and OpenRouter uses JSON Schema structured output
  mode.
- Remote provider smoke instructions source `.env` for keys and cover OpenAI,
  Anthropic, OpenRouter, and Gemini model profiles without printing secrets. The
  recommended remote code-generation profile is `coding`; the local Ollama
  fallback is consistently named `coding_local`. The Gemini preflight accepts
  either `GOOGLE_API_KEY` or `GEMINI_API_KEY`. OpenAI generation clamps and
  validates output-token limits to the provider minimum of `16`. The runtime
  also honors `.env` credentials as an operator-provided preflight source when
  Settings Central secret storage is not used for smoke testing.
- Operator, developer, ADR, plan, request-flow, runtime-boundary, and onboarding
  docs now describe source-bearing read-only action generation plus gated live
  integration.
- Research reconciliation now requires v0.37.2 to use separate model-backed
  Planner, Author, TrialAuthor, Critic, and invoked Repair packets with bounded
  repair over sandbox/gate evidence. The provider-call cap is a settable
  whole-workflow cap, not one fixed call per role. Critic output remains
  advisory; deterministic validators, sandbox tests/gates, and operator
  confirmation remain authority.
- The generated-action workflow now has an explicit
  `DynamicPlugins.request_draft_with_gate/3` facade that requests the draft,
  runs v0.36 trial/gate evidence, runs trusted validation, feeds failed
  sandbox or validator evidence into bounded Repair, and returns only evidence
  until the existing operator-confirmed integration flow is approved.

### Added (v0.37.3 delegated writes)

- `dynamic_codegen.allowed_facades` Settings Central policy, defaulting closed,
  with a hard ceiling of `append_memory` and `external_network_request`.
- `AllbertAssist.DynamicPlugins.Delegate.run/3`, a reviewed shim that resolves
  only operator-enabled facades through `Actions.Registry` and executes them
  through `Actions.Runner.run/3`.
- Trusted-validator enforcement for the generated action permission ceiling:
  `read_only`, `memory_write`, and `external_network`, defaulting closed
  through `dynamic_codegen.allowed_action_permissions`.
- Validator checks that non-read-only generated actions delegate through
  `AllbertAssist.DynamicPlugins.Delegate.run/3` to a literal reviewed facade
  name in `dynamic_codegen.allowed_facades`, and that source permission,
  response action metadata, and facade permission all match.
- Codegen prompts, deterministic fake provider support, and manifest permission
  derivation for pure read-only and delegated memory/network action drafts.

### Changed (v0.37.3 delegated writes)

- Generated actions remain `resumable?: false`; facade-owned confirmations keep
  the facade's existing Security Central approval and resume path. The
  `dynamic_codegen.integration_approval_surfaces` setting remains scoped to
  integration and rollback hot-load confirmations.

### Added (v0.37.4 audit remediation)

- Registered `discard_dynamic_draft` action and `mix allbert.dynamic drafts
  discard <slug>` command for terminal discard of non-integrated or rolled-back
  dynamic drafts.
- Dedicated `:dynamic_codegen_request` permission and
  `permissions.dynamic_codegen_request` Settings Central key, default
  `allowed`, so LLM-backed draft generation is audited separately from
  historical `:skill_write`.
- Security eval rows for discard, request-permission splitting, delegated
  memory/network allowance, facade allowlists, literal facade names,
  delegated-permission coherence, runtime facade disablement, delegated
  rollback authority removal, and direct-effect denial.

### Changed (v0.37.4 audit remediation)

- `request_dynamic_draft` now authorizes `:dynamic_codegen_request` instead of
  `:skill_write`; denying `permissions.skill_write` no longer blocks dynamic
  generation, while denying `permissions.dynamic_codegen_request` does.
- Trusted validation now treats delegated facade evidence and response action
  permission metadata as valid only inside generated `run/2`; helper-only
  delegation is denied so dead code cannot justify generated write permission.
- Generated `AllbertAssist.Action` capability options are pinned for
  permission, exposure, execution mode, confirmation, `skill_backed?`, and
  `resumable?`; literal `@spec`/`@type`/`@typep` attributes and `||` are
  allowed.
- Umbrella, core app, and web app version metadata are bumped to `0.37.4` for
  the pre-tag release candidate.

### Added (v0.37.5 fourth-audit closeout)

- Dedicated `:dynamic_codegen_discard` permission and
  `permissions.dynamic_codegen_discard` Settings Central key, default
  `allowed`, so terminal draft cleanup is audited separately from settings
  writes.
- Dynamic delegate provenance is now persisted in facade confirmation runner
  metadata when generated actions delegate to reviewed facades.
- Security eval coverage for normal facade approval policy on delegated network
  confirmations, dynamic delegate metadata, discard permission denial, and
  confirmation-free gate-passed discard.

### Changed (v0.37.5 fourth-audit closeout)

- `discard_dynamic_draft` now authorizes `:dynamic_codegen_discard` and uses
  execution mode `:dynamic_codegen_discard` instead of `:settings_write`.
- Operator/developer docs now state that
  `dynamic_codegen.integration_approval_surfaces` applies only to integration
  and rollback; delegated facade confirmations intentionally follow normal
  facade channel policy.
- Discard docs now explicitly state that `:gate_passed` drafts can be discarded
  without confirmation, which may remove gate evidence but never removes live
  authority.
- Umbrella, core app, and web app version metadata are bumped to `0.37.5` for
  the released v0.37 build.

### Verification (v0.37.0)

- M0-M4 were implemented, focused-tested, documented, and committed separately.
- Focused settings/path/metadata/action/CLI/staging/sandbox bridge/loader/
  confirmation/security/codegen suites passed during milestone work.
- M4 final gate passed `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `git diff --check`, and `mix precommit`.
- M5 release closeout passed `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `git diff --check`, and `mix precommit`.
- No workspace or LiveView UI behavior changed in v0.37, so Chrome extension
  browser verification was not required.
- Manual verification should use a disposable Allbert Home and follow
  `docs/plans/v0.37-request-flow.md#manual-release-verification`.

### Verification (v0.37.1 hardening)

- Focused dynamic plugin, settings, confirmation/security, and v0.37 security
  eval suites passed during hardening milestones.
- Final release gates passed `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `git diff --check`, and `mix precommit` after documentation reconciliation.

### Verification (v0.37.2 generator)

- Focused codegen, dynamic action, Mix task, security eval, loader, and settings
  suites passed during the initial generator work, before the model-backed
  committee correction. M10/M11 add model-backed role packets and evidence
  repair; later M16 closeout ran the final generator gates.
- M16 adds deterministic fake-backend coverage for the full generated action
  loop through draft, sandbox trial/gate, trusted validation, operator
  integration confirmation, live `Actions.Runner.run/3`, rollback confirmation,
  and registry removal, plus tighter validator eval denial assertions.
- M16 closeout passed focused codegen/security eval suites, the broader
  dynamic-plugin focused suite, real OpenAI `.env` draft-generation smoke,
  `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `git diff --check`, `mix credo --strict`, `mix dialyzer`, and
  `mix precommit`.
- `.env` contains remote provider credentials and the remote OpenAI, Anthropic,
  and OpenRouter smoke workflows are documented. The automated run from this
  agent session was blocked by external-provider transfer policy after sandbox
  retry; operator manual verification requires explicit approval to send the
  bounded generation prompt to the configured remote LLM.

### Verification (v0.37.3 delegated writes)

- Focused settings, delegate, trusted-validator, loader, codegen, dynamic
  actions, external-network confirmation, metadata, and sandbox bridge
  regression suites passed.
- A real `.env` OpenAI-backed LLM smoke produced a delegated `memory_write`
  draft that called
  `AllbertAssist.DynamicPlugins.Delegate.run("append_memory", ...)`, and trusted
  validation accepted the generated source after the validator allowed pipe
  syntax used by the model.
- Final gates passed `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `git diff --check`, `mix credo --strict`,
  `mix dialyzer`, and `mix precommit`.

### Verification (v0.37.4 audit remediation)

- M19-M22 each passed focused regression suites, warning gates, and a milestone
  commit/push. M21 and M22 also passed full `mix precommit` before push.
- M23 release closeout passed `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `git diff --check`, `mix credo --strict`,
  `mix dialyzer`, and `mix precommit`.

### Verification (v0.37.5 fourth-audit closeout)

- M24 docs-first plan update passed `git diff --check` and was committed/pushed.
- M25 passed focused settings, Security Central, PermissionGate, registry,
  dynamic-plugin action, and security-eval tests, then passed
  `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `git diff --check`, `mix credo --strict`, `mix dialyzer`, and
  `mix precommit`.
- M26 release-doc closeout reconciled README, CHANGELOG, roadmap,
  plan/request-flow, runtime-boundary, agent-context, and future-feature
  parking-lot wording for the `v0.37.5` tag. Docs-only verification passed
  `git diff --check`.

## v0.36.0 - Elixir/OTP Sandbox And Gate Runner

Status: released and tagged as `v0.36.0` on 2026-05-25. Local sandbox image
preparation and M10 full-gate remediation are included in the release scope.

Plan: `docs/plans/v0.36-plan.md`.
Request flow: `docs/plans/v0.36-request-flow.md`.
ADRs: `docs/adr/0009-local-execution-sandbox-levels.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`.

### Added (v0.36.0)

- Default-off `sandbox.elixir.*` Settings Central policy, sandbox roots under
  Allbert Home, typed doctor and command reports, and `mix allbert.sandbox
  doctor` for local readiness inspection.
- OS-aware sandbox backend registry and resolver with Docker, Docker+runsc,
  rootless Podman, and optional doctor-gated Apple `container` candidates.
- Copy-in/copy-out sandbox bundle builder with a disposable sandbox
  `ALLBERT_HOME`, bounded metadata, symlink/traversal denial, real-home
  exclusion, and report roots.
- Strict `CommandSpec` validation for explicit reviewed `mix` gate argv
  commands, plus `SourcePolicy` checks for dangerous Elixir/OTP constructs.
- Hardened Docker/Podman/runsc command builders that use approved local images,
  `--network none`, dropped capabilities, `no-new-privileges`, bounded
  resources, read-only project/draft/test mounts, and writable bundle-local
  sandbox-home/report mounts.
- Public `AllbertAssist.Sandbox` facade, reviewed gate profiles, sandbox
  lifecycle signals, internal sandbox actions, and bounded redacted report
  writing.
- `mix allbert.sandbox image build` and `mix allbert.sandbox image verify` for
  preparing the default approved local image before sandbox gate execution.
- Durable bounded sandbox lifecycle audit records under
  `<ALLBERT_HOME>/sandbox/audit`.
- v0.36 security eval rows for disabled/missing backends, backend resolver
  fail-closed behavior, no image pulls, source policy, shell denial, network
  denial, secret denial, home isolation, package-manager denial, NIF/port
  denial, forged command-spec struct revalidation, cleanup root confinement,
  core-load denial, and report redaction.

### Changed (v0.36.0)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, and child app
  metadata are bumped to `0.36.0` because v0.36 adds internal sandbox actions
  and sandbox lifecycle signals to the core runtime boundary.
- ADR 0037 is accepted for v0.36 and ADR 0009's Level-3 local container
  sandbox amendment is implemented for this narrow Elixir/OTP trial/gate scope.
- Operator, developer, roadmap, onboarding, security-hardening,
  runtime-boundary, agent-context, and future-feature docs now point at the
  implemented v0.36 sandbox contract and report-only authority boundary.
- Docker-family doctor checks now validate the local image labels and point to
  the image-preparation task when the image is missing or invalid.
- Post-audit hardening revalidates `%CommandSpec{}` structs at the sandbox
  facade, confines bundle ids, explicit bundle roots, and cleanup targets to
  marked sandbox bundle directories, returns redacted report maps from sandbox
  actions, and records Docker/Podman non-root/tmpfs backend argv expectations.
- M9 post-audit correction makes the gate green path executable by preparing
  dependency cache/source in the approved image, using writable
  container-local Mix build/home paths at runtime, keeping runtime gate
  executables to reviewed `mix` profiles, moving SourcePolicy to the sandbox
  facade, passing one resolved policy snapshot into backends, avoiding atom
  creation from backend setting strings, naming Docker/Podman containers for
  timeout cleanup, and adding a Docker-gated compile integration smoke.
- M10 full-gate readiness hardening installs the minimal build toolchain for
  C/NIF deps during image preparation, pre-bakes compiled deps and Dialyzer PLT
  state when available, normalizes baked artifact permissions for the non-root
  runtime user, seeds writable runtime dependency/build/cache paths and test DB
  roots through a fixed image-owned runner, makes seeded PLT/build copies
  writable inside the disposable sandbox home, teaches root Dialyxir config to
  honor `MIX_BUILD_PATH`, includes source-tree plugins and root warning-gate
  config in default bundles, warns on sandbox audit append failures, and adds an
  opt-in Docker full-default-gate smoke for the current umbrella.

### Verification (v0.36.0)

- M0-M5 were implemented, focused-tested, and committed separately.
- Focused sandbox, action registry, Settings Central, Security Central, backend
  runner, bundle, command-spec, source-policy, CLI doctor, and security-eval
  suites passed during milestone work.
- No UI/UX behavior changed in v0.36, so Chrome extension browser verification
  was not required for this release.
- Final release gate passed after the M7 image-preparation correction:
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Post-audit hardening passed focused sandbox/security/action/image tests plus
  `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, and `mix precommit`.
- M9 corrective pass passed focused sandbox/image/security/action tests, the
  Docker-gated compile smoke when available, and the final warning gate.
- M10 corrective pass passed focused sandbox/image/security/action tests, the
  Docker-gated full-default-gate smoke
  (`ALLBERT_DOCKER_FULL_GATE_TEST=1 mix test apps/allbert_assist/test/allbert_assist/sandbox_test.exs --only docker_full_gate`),
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Disposable-home manual smoke confirmed `mix allbert.sandbox image verify`
  writes an image verification report, Docker `28.5.1` is reachable outside the
  restricted execution sandbox, and enabled doctor resolves `backend=auto` to
  `docker` when `allbert-elixir-otp:local` has valid labels. `docker_runsc`
  remains unavailable when `runsc` is not configured, and Apple `container`
  remains unavailable until its policy-proof path is implemented.

## v0.35.0 - User Theming And Layout Overrides

Status: implemented and release-ready on 2026-05-24. Version metadata is
`0.35.0`; ready for operator manual verification before a release tag.

Plan: `docs/plans/v0.35-plan.md`.
Request flow: `docs/plans/v0.35-request-flow.md`.
ADR: `docs/adr/0025-user-theming-and-override-security.md`.

### Added (v0.35.0)

- Allbert Home appearance roots under `<ALLBERT_HOME>/themes`,
  `<ALLBERT_HOME>/themes/snippets`, and `<ALLBERT_HOME>/workspace`.
- Settings Central keys for `workspace.theme.mode`,
  `workspace.theme.active`, `workspace.theme.snippets_enabled`,
  `workspace.theme.enabled_snippets`, and
  `workspace.layout.override_enabled`, with audited gates/selections and
  read-only Settings Canvas status/diagnostics.
- Token YAML themes served through `/theme/user.css`, linked after app CSS, and
  scoped to presentational `#workspace-shell` `--allbert-*` variables.
- Opt-in sanitized CSS snippets served through `/theme/snippets.css` and
  `/theme/snippets/:name`, with traversal rejection and stripping of remote
  fetch/import/font constructs.
- Validated `<ALLBERT_HOME>/workspace/layout.yaml` for launcher destination
  order/hide, default Canvas destination, and panel pins without granting
  `active_app`, route, action, component, or permission authority.
- CSP and cache coverage for browser/theme routes, including ETag/304 behavior
  and the `theme-csp-regression-001` eval row.

### Changed (v0.35.0)

- The shipped scalar `workspace.theme` setting migrates to
  `workspace.theme.mode` with compatibility reads/writes for existing values.
- `/workspace` root layout loads local token CSS and snippet CSS after the
  compiled app stylesheet with versioned links derived from selected settings
  and local file fingerprints.
- The v0.34 launcher and Canvas destination registry are now reusable by the
  layout validator, while Output and Settings remain non-hideable and
  `app:allbert` remains invalid.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and affected StockSage skill
  metadata are bumped to `0.35.0`.

### Verification (v0.35.0)

- M1-M6 were implemented, focused-tested, Chrome-verified where UI/UX changed,
  and committed separately.
- Chrome extension verification covered token retinting, no-inline-script CSP
  behavior, sanitized snippet application, valid/invalid layout overrides,
  Settings/Output escape hatches, AppBar preservation, and clean console logs.
- Focused path/settings/theme/status/controller/LiveView/catalog/security-eval
  suites passed during milestone work.
- Final release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.

## v0.34.0 - Workspace UX Refresh

Status: released and tagged as `v0.34.0` on 2026-05-24. Version metadata is
`0.34.0`.

Plan: `docs/plans/v0.34-plan.md`.
Request flow: `docs/plans/v0.34-request-flow.md`.
ADR: `docs/adr/0024-app-ui-contribution-and-workspace-zones.md` (v0.34
revision).

### Added (v0.34.0)

- View-only workspace launcher destinations for Output, registered apps, and
  workspace tools.
- `canvas_destination` routing for Canvas presentation state, persisted through
  a view-only `destination` query param.
- v0.34 M7 security eval rows for launcher view-only selection, Canvas
  app-scope enforcement, Settings action gating, and stale URL/query handoff
  bypass.
- Passive top-bar context indicator with an exit-to-neutral affordance through
  the registered action path.
- Mobile launcher sheet with Chat/Canvas tabs and an in-flow bottom shellbar.

### Changed (v0.34.0)

- `/workspace` is now chat-primary with a single-destination Canvas instead of
  simultaneous app band, Canvas, and permanent Tools column regions.
- Launcher selection never sets `active_app`, grants permission, or runs an
  action; conversational handoff remains the only app-context setter.
- Settings, Jobs, Objectives, Confirmations, and Security render as Canvas
  destinations while keeping their writes behind registered actions.
- StockSage dashboard/recent/queue/trends panels render inside Canvas as the
  `app:stocksage` destination.
- Stale `app_id` / `active_app` URL params no longer set routing context.
- AppBar Objectives and Settings links now open workspace Canvas destinations
  instead of dead `/objectives` or root `/workspace` links.
- Desktop workspace root-grid CSS now has one effective four-column layout rule
  guarded by the responsive regression test.
- The retired `:utility_drawer` renderer is inert if mounted, so historical
  surface validation cannot resurrect the old Tools column links.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and affected StockSage skill
  metadata are bumped to `0.34.0`.

### Verification (v0.34.0)

- Milestones M0-M6 were implemented, focused-tested, and committed separately.
- Chrome extension verification covered desktop launcher/Canvas behavior,
  StockSage Canvas panels, and a 390px narrow frame for mobile launcher sheet,
  Chat/Canvas tabs, Settings destination, and bottom-shellbar non-overlap.
- Focused LiveView, workspace catalog, StockSage panel, and handoff/context
  tests passed during milestone work.
- Post-check focused suites passed for the extended security eval harness,
  Workspace LiveView destination links, and responsive root-grid CSS.
- Final validation cleanup passed for the inert UtilityDrawer renderer and
  request-flow deep-link clarification, followed by operator manual acceptance.
- Final release gate passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.

## v0.33.1 - Descriptorized Remaining StockSage Intent Actions

Status: released. Version metadata is `0.33.1`; release tag `v0.33.1` exists.

Plan: `docs/plans/v0.33-plan.md`.
Request flow: `docs/plans/v0.33-request-flow.md`.
ADR: `docs/adr/0034-conversational-app-intent-handoff-and-clarification.md`.

### Added (v0.33.1)

- Optional slots for inert app intent descriptors, allowing read-only
  descriptor routes such as StockSage trends to accept an optional ticker
  without making it required.
- StockSage descriptors for `get_trends` and `queue_analysis`, alongside the
  existing `run_analysis` descriptor.
- Regression coverage for neutral queue handoff, missing-symbol
  clarification, active-app trend filtering, and active-app queue writes.
- Regression coverage that repeated neutral handoff proposals for the same
  app/action/slot set render independently across workspace threads.

### Changed (v0.33.1)

- Active StockSage `show trends for AAPL` and `queue analysis for AAPL` now
  route through descriptor-extracted params.
- Neutral `queue analysis for AAPL` now proposes an inert StockSage handoff;
  neutral `queue analysis` asks for the missing symbol.
- Workspace handoff ephemeral surface ids are scoped by thread, while their
  source handoff id remains in metadata, so repeated handoffs do not collide
  across threads.
- Removed the remaining core StockSage symbol regex from
  `AllbertAssist.Agents.IntentAgent`; StockSage conversational slot extraction
  now lives behind app descriptors.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and affected StockSage skill
  metadata are bumped to `0.33.1`.

### Verification (v0.33.1)

- Focused intent tests passed for descriptor normalization, ranking, engine
  decisions, classifier summaries, and `IntentAgent` routing.
- Focused StockSage tests passed for action execution, descriptor-selected
  trends, descriptor-selected queue writes, neutral handoff, neutral
  clarification, and `run_analysis` regression coverage.
- Chrome extension verification covered neutral queue handoff, neutral
  queue handoff repeat across fresh threads, neutral missing-symbol
  clarification, active StockSage trend execution, and active StockSage queue
  execution.
- Final release gate passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.

## v0.33.0 - Conversational App Intent Handoff And Direct Answer Foundation

Status: released. Version metadata is `0.33.0`; release tag `v0.33.0` exists.

Plan: `docs/plans/v0.33-plan.md`.
Request flow: `docs/plans/v0.33-request-flow.md`.
ADR: `docs/adr/0034-conversational-app-intent-handoff-and-clarification.md`.

### Added (v0.33.0)

- Model-gated, side-effect-free direct answers with a deterministic bounded
  fallback when the configured answer profile is disabled or unavailable.
- App intent descriptors via `SurfaceProvider.intent_descriptors/0` and the
  extension registry, validated against registered agent-exposed actions.
- StockSage `run_analysis` descriptor support with conservative ticker slot
  extraction, explicit neutral handoff, missing-slot clarification, and
  stable workspace DOM handles for manual verification.
- Advisory classifier summaries that include bounded descriptor/handoff
  metadata and active-app context while accepting only already-collected
  candidates that meet confidence thresholds.

### Changed (v0.33.0)

- Neutral `analyze CIEN` now produces an inert app handoff proposal instead of
  falling through to a static echo or silently executing StockSage.
- Accepting the handoff sets active app context through the existing
  registered session action and then reaches the normal StockSage confirmation
  path; declining only dismisses the ephemeral proposal.
- In StockSage-selected context, `analyze CIEN` routes through the same generic
  descriptor path to `run_analysis`; the old core StockSage keyword ranker and
  run-analysis ticker/date parameter shortcut are retired.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and the StockSage `run-analysis`
  skill metadata are bumped to `0.33.0`.

### Verification (v0.33.0)

- M0-M5 were implemented, focused-tested, committed, and pushed as separate
  milestones.
- Security eval coverage proves neutral handoff cannot bypass app scope or
  create a StockSage confirmation before explicit acceptance, and runner
  app-scope denial remains intact for missing/mismatched active app context.
- Chrome extension verification passed for the workspace handoff/decline/
  re-offer/accept flow and missing-slot clarification handles.
- Final release gate passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.

## v0.32.0 - Workspace-Only App UI And Settings Central

Status: released. Version metadata is `0.32.0`; release tag `v0.32.0` exists.

Plan: `docs/plans/v0.32-plan.md`.
Request flow: `docs/plans/v0.32-request-flow.md`.

### Added (v0.32.0)

- `/workspace` as the canonical operator home with host-owned nav, chat,
  canvas/panel, and utility zones.
- Catalog-validated `:panel` surfaces with fixed zones:
  `:nav_apps`, `:context_rail`, `:canvas_panels`, `:utility_drawer`, and
  `:ephemeral`.
- Workspace app launcher selection that sets active app context through the
  registered session action boundary instead of manual URL editing.
- Settings Central inside the workspace utility drawer, preserving settings,
  provider-key, confirmation, remembered-grant, redaction, audit, and security
  action boundaries.
- CoreApp objective, jobs, confirmations, security/status, and Settings
  Central cards as panels through the same composition path used by app
  providers.
- StockSage dashboard, recent analyses, queue, and trends as hydrated
  workspace panels backed by existing StockSage read contexts.

### Changed (v0.32.0)

- `/agent`, `/settings`, and `/stocksage/*` operator routes are removed without
  redirects or compatibility pages.
- `StockSageWeb.WorkspaceLive`, `QueueLive`, and `TrendsLive` were removed;
  `StockSageWeb.AnalysisLive` remains at `/apps/stocksage/analyses/:id` for
  long-form detail flows and no longer renders private StockSage nav chrome.
- Durable StockSage canvas tiles continue to render through the v0.30 signed
  Fragment/canvas path and the real v0.27 StockSage card renderers.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and the StockSage `run-analysis`
  skill metadata are bumped to `0.32.0`.

### Verification (v0.32.0)

- M1-M6 were implemented, focused-tested, committed, and pushed as separate
  milestones.
- Security eval coverage includes panel catalog bypass, zone injection,
  settings action bypass, workspace direct-mutation denial, and app-scope
  preservation; web tests cover removed `/agent`, `/settings`, and
  `/stocksage/*` routes.
- Chrome extension verification passed for the workspace shell, app launcher,
  Settings Central drawer, CoreApp panels, and StockSage panels with no
  horizontal overflow or browser warnings/errors in the verified desktop
  view. The pass caught and fixed a StockSage dark-card title contrast
  regression.
- Final M7 gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.

## v0.31.0 - Runtime And UI-Substrate Consolidation

Status: implemented and ready for operator manual verification before the
release tag. Version metadata is `0.31.0`.

Plan: `docs/plans/v0.31-plan.md`.
Request flow: `docs/plans/v0.31-request-flow.md`.

### Added (v0.31.0)

- `AllbertAssist.Boundary` and `docs/developer/runtime-boundary-map.md` as the
  runtime/UI public-facade inventory.
- `AllbertAssist.Runtime.Paths`, `AllbertAssist.Runtime.Redactor`,
  `AllbertAssist.Runtime.Audit`, `AllbertAssist.Runtime.Persistence`, and
  `AllbertAssist.Runtime.Trace` as behavior-preserving runtime substrate
  facades.
- `AllbertAssist.Action` as the Allbert-facing wrapper for registered
  runtime capability actions, with capability metadata derived from action
  modules.
- `AllbertAssist.Runtime.Response` as the shared completed,
  confirmation-needed, denied, advisory, error, unsupported, and unavailable
  response helper.
- `AllbertAssist.Surface.Catalog`, `AllbertAssistWeb.Surface.Renderer`, and
  `AllbertAssist.Extensions.Registry` as the unified Surface catalog/renderer
  and app/plugin contribution discovery path.
- `AllbertAssist.Settings.Fragment` and `AllbertAssist.Settings.Fragments` as
  the settings schema-fragment contract and composition facade.

### Changed (v0.31.0)

- Registered core and StockSage actions now use `use AllbertAssist.Action`;
  private/test-only Jido command modules remain private and unregistered.
- Settings schema/default/safe-write assembly now flows through registered
  core/app/plugin fragments while `AllbertAssist.Settings.Schema` remains the
  public compatibility facade.
- Workspace and StockSage app-surface rendering now dispatch through the same
  catalog-backed renderer path. The v0.30 StockSage pass-through workspace card
  adapters and `StockSageWeb.Components.SurfaceRenderer` were removed.
- `AllbertAssist.Security.PermissionGate` remains a compatibility shim over
  Security Central for existing live callers; deletion is deferred to a future
  parity pass.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app
  metadata, `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and the `run-analysis` skill
  metadata are bumped to `0.31.0`.

### Verification (v0.31.0)

- M1-M8 were implemented, focused-tested, committed, and pushed as separate
  milestones.
- M7 full gate passed after the renderer/catalog consolidation: `mix format
  --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- M8 full gate passed after settings fragments: `mix format
  --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- M9 final release gate passed: focused identity-context eval regression,
  `mix format --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.

## v0.30.0 - App Canvas Contract - StockSage Canvas Integration

Status: released. Version metadata is `0.30.0`; release tag `v0.30.0` was
created after operator manual verification was accepted.

Plan: `docs/plans/v0.30-plan.md`.
Request flow: `docs/plans/v0.30-request-flow.md`.

### Added (v0.30.0)

- `/agent` workspace canvas rendering for the four StockSage card atoms already
  reserved in v0.26 and proven in v0.27: `:analysis_card`,
  `:agent_report_card`, `:parity_card`, and `:debate_round_card`.
- Thin workspace LiveComponent adapters that delegate those four atoms to the
  existing `StockSageWeb.Components.Cards` renderers, removing the v0.26 stub
  marker from durable StockSage canvas tiles.
- Durable StockSage canvas emission through
  `AllbertAssist.Workspace.Emitters.stocksage_signal/2`,
  `%AllbertAssist.Workspace.Fragment.Envelope{}`, and the existing
  `workspace_canvas_tiles` + YAML body store.
- Focused coverage proving approved `RunAnalysis` calls with `thread_id`
  create durable StockSage canvas tiles with encoded Surface bodies and
  provenance metadata.
- Fragment idempotency for same-semantic-body re-emission when only the
  volatile Fragment `emitted_at` value changes.

### Changed (v0.30.0)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app metadata,
  `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and the `run-analysis` skill
  metadata are bumped to `0.30.0`.
- StockSage canvas integration deliberately does not add `:stock_chart`, a new
  migration, a new workspace setting, new domain behavior, or a private
  StockSage canvas-write path.

### Verification (v0.30.0)

- M0 implementation preflight committed concrete API shapes for the existing
  emitter path, no-new-atom decision, module adapters, focused tests, and
  manual verification handles.
- M1 focused tests passed for workspace renderer dispatch and StockSage card
  rendering without v0.26 stub output.
- M2/M3 focused tests passed for workspace emitters, Fragment persistence,
  durable StockSage tile rows, encoded bodies, provenance metadata,
  no-context no-op behavior, and approved native `RunAnalysis` canvas
  emission.
- M4 focused LiveView tests passed for `/agent` durable StockSage tile rendering
  and independent `/stocksage/*` app-surface rendering.
- M4 Chrome extension verification passed against disposable
  `ALLBERT_HOME=/private/tmp/allbert-v030-chrome`: `/agent` rendered the
  seeded StockSage `analysis_card` tile with real
  `data-stocksage-component="analysis_card"` markup, tile menu controls, no
  v0.26 stub marker, and no horizontal overflow at the available desktop
  viewport.
- M4 narrow Chrome extension verification passed at a 430px viewport: the
  mobile Canvas tab opened, the StockSage tile was visible, tile menu controls
  remained reachable, and there was no horizontal overflow.
- M5 focused memory regressions passed after replacing an old fake StockSage
  registration test helper with the real `StockSage.App` registry contract.
- M5 full gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Operator manual verification was accepted for the release smoke in
  `docs/plans/v0.30-request-flow.md`.

## v0.29.0 - App Memory + Outcomes Contract - StockSage Polish

Status: released. Version metadata is `0.29.0`; release tag `v0.29.0` was
created after the full gate and operator smoke passed.

Plan: `docs/plans/v0.29-plan.md`.
Request flow: `docs/plans/v0.29-request-flow.md`.

### Added (v0.29.0)

- StockSage outcome resolver (`resolve_outcomes`) with idempotent fixture-backed
  post-holding-period returns, outcome provenance metadata, and resolver
  settings.
- StockSage trend calibration metrics: resolved-count accuracy, realized-return
  basis, rating calibration, symbol leaderboard, and raw outcome rendering.
- StockSage-local deterministic reflections through `generate_reflection`, with
  bounded/redacted content and analysis-detail rendering.
- Namespaced app-memory metadata on `AllbertAssist.Memory.Entry`:
  `app_id`, `namespace`, `kind`, `idempotency_key`, and `source_ref`.
- `AllbertAssist.Memory.upsert_app_entry/1`, validating writable app namespaces
  and idempotently updating matching app-memory entries.
- `sync_app_lesson`, a confirmation-required registered action that centrally
  stamps advisory context before initial memory-write authorization.
- `sync_app_lesson` lesson text is redacted and capped at 4000 characters
  before markdown memory write, with regression coverage for oversized input.
- StockSage analysis-detail `Sync lesson` control, which queues lesson-sync
  confirmation and writes no Allbert markdown memory until approval.
- StockSage analysis-detail rerun controls for native, Python comparison, and
  parity reruns, backed by the existing `run_analysis` confirmation flow.
- StockSage analysis-detail run-context affordances for native/Python/parity
  comparison state, plus bounded empty states for outcomes, reflections, and
  progress.

### Changed (v0.29.0)

- `StockSage.App.memory_namespace/0` is now `writable: true`; the only v0.29
  Allbert markdown write path remains explicit `sync_app_lesson` confirmation
  resume.
- StockSage reflections remain local advisory memory until an operator queues
  and approves lesson sync.
- `run_analysis` carries optional `source_analysis_id` through confirmations,
  resume params, action metadata, signals, and persisted analysis metadata so
  reruns are distinguishable from their source analysis.
- StockSage app shells now use consistent mobile-safe spacing, wrapped
  headings/navigation, table overflow guards, success-tone state panels, and
  icon-backed rerun buttons.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app metadata,
  `StockSage.App.version/0`, `StockSage.Plugin.version/0`,
  `plugins/stocksage/allbert_plugin.json`, and the `run-analysis` skill
  metadata are bumped to `0.29.0`.

### Verification (v0.29.0)

- M1 focused tests passed for `StockSage.Outcomes`, `resolve_outcomes`, plugin
  registration, and settings schema.
- M2 focused tests passed for trend/calibration domain and action coverage;
  Chrome verification passed for the trends UI sections.
- M3 focused tests passed for reflections, StockSage actions, StockSage memory,
  plugin registration, settings schema, and analysis-detail LiveView rendering;
  Chrome verification passed for generating a reflection.
- M4 focused tests passed for core memory metadata/upsert behavior, app lesson
  sync confirmation/resume, StockSage plugin registration, StockSage
  reflections/actions/memory, and the analysis-detail LiveView sync control.
- M4 Chrome verification passed against a disposable Allbert Home: StockSage
  analysis detail rendered a local reflection, `Sync lesson` queued
  confirmation, the reflection moved to `Allbert sync pending`, no sync error
  rendered, no StockSage console errors appeared, and no Allbert markdown
  memory file existed before approval.
- M5 focused tests passed for `run_analysis` source-analysis provenance and the
  StockSage analysis-detail rerun confirmation flow.
- M5 Chrome verification passed against a disposable Allbert Home: rerun
  controls rendered on an existing analysis, `Native` rerun queued a normal
  `run_analysis` confirmation, pending-confirmation links appeared on the
  source analysis page, no rerun error or StockSage console errors appeared,
  and the analysis list still contained only the source analysis before
  approval.
- M6 focused LiveView tests passed for comparison affordances, bounded empty
  states, rerun controls, and existing StockSage app-flow coverage.
- M6 Chrome extension verification passed against the disposable Allbert Home:
  `/stocksage`, `/stocksage/analyses`, `/stocksage/queue`, `/stocksage/trends`,
  and an analysis detail page rendered with zero page overflow at the available
  Chrome viewport; analysis detail exposed native/Python/parity
  `data-run-state` values, rerun buttons met the 40px hit target, and no
  console errors appeared.
- M7 release closeout passed `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`. Final `mix precommit` covered 795 core tests,
  97 web tests, 187 StockSage tests, and 2 channel-plugin tests with
  0 failures.
- README was reset to a concise project overview, and
  `docs/developer/agent-context-map.md` now routes v0.28 security and v0.29
  app-memory/outcomes work explicitly for future implementation agents.
- Release operator smoke passed against disposable
  `ALLBERT_HOME=/tmp/allbert-v029-release.LU9kUP`: Chrome generated a
  StockSage reflection, clicked `Sync lesson`, verified pending state and no
  Allbert markdown memory before approval, approved the confirmation through
  `mix allbert.confirmations approve`, reloaded the analysis detail page, and
  verified one namespaced lesson plus `promoted_to_allbert_memory=true`.

## v0.28.0 - Security Hardening And Evals

Status: released. Version metadata is `0.28.0`; release tag `v0.28.0` was
reconciled during the v0.29 release closeout.

Plan: `docs/plans/v0.28-plan.md`.
Request flow: `docs/plans/v0.28-request-flow.md`.
Operator hardening notes: `docs/operator/security-hardening.md`.

### Added (v0.28.0)

- Shared v0.28 security eval harness plus concrete adversarial eval modules for
  resource/execution, identity/context, plugin/app registry,
  surface/workspace/namespace, objective/financial/bridge, StockSage
  market-data authorization, and operator review flows.
- Pre-tag `app-scope-missing-001` eval coverage for direct Runner calls and
  registered-action jobs that attempt StockSage actions without explicit
  StockSage app scope.
- `mix allbert.security review --recent [--limit N]`, backed by the
  read-only `security_review` action, for recent confirmations, denials,
  imports, external calls, redaction-applied records, and emergency switch
  state.
- Settings Central emergency switches for plugin registration,
  app-registry registration, and workspace fragment emission:
  `plugins.registration_enabled`, `app_registry.registration_enabled`, and
  `workspace.fragment.emission_enabled`.
- Operator security hardening notes covering deployment posture, channel
  pairing, exposed services, file permissions, and emergency switches.

### Changed (v0.28.0)

- Security Central trusted context normalization now treats top-level runtime
  actor/channel/session metadata as authoritative over nested request metadata.
- App-owned actions with explicit mismatched `active_app` are denied before the
  action body can create confirmations or side effects.
- App-owned actions now also deny missing, nil, `"none"`, or `"general"`
  `active_app` scope; registered-action jobs and objective step execution pass
  trusted app scope explicitly when invoking app-owned actions.
- Disabled plugin entries remain inspectable by lookup but contribute no
  runtime apps/actions/channels/skills/children.
- App surface validation now enforces provider catalog ownership for
  non-primitive components, and workspace Fragment receivers check registered
  app catalogs before persistence.
- Memory namespace registration rejects exact and overlapping namespace claims
  before v0.29 adds namespace-consuming memory writes.
- Advisory-origin memory writes require confirmation, and `append_memory` no
  longer writes durable markdown when Security Central returns a non-allowed
  decision.
- StockSage bridge argument validation rejects invalid ticker/date/engine/config
  inputs before Port dispatch.
- Workspace fragment emission and receiver persistence can be disabled through
  `workspace.fragment.emission_enabled=false`.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app metadata,
  `StockSage.App.version/0`, `StockSage.Plugin.version/0`, and
  `plugins/stocksage/allbert_plugin.json` are bumped to `0.28.0`.

### Verification (v0.28.0)

- Milestone-focused tests passed after each checkpoint from M1 through M7.
- Full security eval suite through M7 passed:
  `mix do --app allbert_assist cmd mix test test/security ../../plugins/stocksage/test/security/stocksage_market_data_eval_test.exs`.
- Pre-tag final release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`. The final `mix precommit` run reported 790 core tests,
  94 web tests, 178 StockSage plugin tests, and 2 channel plugin tests, all
  with 0 failures.
- Disposable-home operator smoke passed on 2026-05-22:
  `mix ecto.migrate.allbert`, `mix allbert.security status`,
  `mix allbert.security review --recent`, emergency switch flip for
  `workspace.fragment.emission_enabled=false`, and a second security review
  showing `workspace_fragments` hard-disabled.

### Manual Verification (v0.28.0)

Use a disposable Allbert Home:

1. Run `ALLBERT_HOME="$SMOKE_HOME" mix ecto.migrate.allbert`.
2. Run `ALLBERT_HOME="$SMOKE_HOME" mix allbert.security status` and verify no
   raw `secret://` values are printed.
3. Seed or create at least one confirmation, then run
   `ALLBERT_HOME="$SMOKE_HOME" mix allbert.security review --recent` and verify
   recent confirmations, denials/imports/external calls when present, redaction
   incidents, and emergency switches render.
4. Flip one emergency switch, for example
   `ALLBERT_HOME="$SMOKE_HOME" mix allbert.settings set workspace.fragment.emission_enabled false`,
   then re-run `mix allbert.security review --recent` and verify the switch is
   shown as hard-disabled.

---

## v0.27.0 - App Surface Contract: StockSage LiveViews

Status: released. Version metadata is `0.27.0`; release tag `v0.27.0` exists.

Plan: `docs/plans/v0.27-plan.md`.
Request flow: `docs/plans/v0.27-request-flow.md`.

### Added (v0.27.0)

- StockSage-owned `/stocksage`, `/stocksage/analyses`,
  `/stocksage/analyses/:id`, `/stocksage/queue`, and `/stocksage/trends`
  LiveViews mounted through the host router and declared by
  `StockSage.App.surfaces/0`.
- Real StockSage renderers for the four v0.26-reserved app card atoms:
  `:analysis_card`, `:agent_report_card`, `:parity_card`, and
  `:debate_round_card`.
- `RunAnalysis` completed/failed responses now include validated
  `surface_nodes` for StockSage-owned app surfaces while preserving existing
  action fields and workspace fragment emission.
- StockSage memory namespace declaration/registration with `writable: false`;
  v0.27 claims ownership only and does not add memory sync or lesson
  promotion.
- Analysis detail pages render persisted cards, objective state, delegate
  steps, pending confirmation links, and cancel affordances.
- Bounded progress streaming via Phoenix.PubSub topic
  `stocksage_progress:<user_id>:<analysis_id>`, with reconnect catch-up from
  persisted objective/analysis state.
- Shared StockSage app navigation, empty/error/loading states, focus-visible
  affordances, and local workspace/queue/trends list rendering.

### Changed (v0.27.0)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app metadata,
  `StockSage.App.version/0`, `StockSage.Plugin.version/0`, and
  `plugins/stocksage/allbert_plugin.json` are bumped to `0.27.0`.
- Tailwind now scans `plugins/stocksage/lib/stocksage_web`, so plugin-owned
  LiveView modules receive generated responsive utility classes.
- `stocksage.web.enabled=false` keeps routes mounted but renders the bounded
  disabled state after Settings Central checks.

### Verification (v0.27.0)

- Milestone-focused tests passed after each implementation checkpoint:
  StockSage provider/settings tests, namespace registry tests, card renderer
  tests, `RunAnalysis` surface-node tests, objective/confirmation rendering
  tests, progress streaming tests, and StockSage LiveView app-flow tests.
- M7 Chrome extension verification covered `/stocksage`,
  `/stocksage/analyses`, `/stocksage/analyses/ana_missing`,
  `/stocksage/queue`, and `/stocksage/trends`; the pass caught and fixed the
  missing Tailwind plugin source path and a stale progress panel on missing
  analysis pages.
- Final release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`.
- M8 release-gate cleanup removed an unreachable generic error branch from
  `StockSage.SurfaceNodes.validate_nodes/1` and updated an intent-candidate
  test diagnostic to handle v0.27 surface candidates alongside action
  candidates.

### Manual Verification (v0.27.0)

Use a disposable Allbert Home:

1. Run `ALLBERT_HOME="$SMOKE_HOME" mix ecto.migrate.allbert`, then
   `ALLBERT_HOME="$SMOKE_HOME" mix phx.server`.
2. Browse `/stocksage`, `/stocksage/analyses`, `/stocksage/queue`, and
   `/stocksage/trends`; verify navigation, empty states, and disabled-state
   behavior by setting `stocksage.web.enabled=false`.
3. Run a fixture StockSage analysis, approve the confirmation, open
   `/stocksage/analyses/<analysis_id>`, and verify real cards, objective
   state, confirmation/cancel affordances, and progress rows.
4. Refresh the analysis detail page and verify persisted progress and final
   state catch up without relying on live PubSub history.

---

## v0.26.2 - Workspace UX Closeout

Status: released. Version metadata is `0.26.2`; release tag `v0.26.2` exists.

Plan: `docs/plans/v0.26c-ux-closeout-plan.md`.
Request flow: `docs/plans/v0.26c-request-flow.md`.

### Added (v0.26.2)

- Real workspace tile inspector modal for existing canvas tiles. The Inspect
  action opens a focus-trapped dialog with tile metadata, body content,
  provenance, optional trace affordance, and copy controls.
- AppBar thread switcher dropdown replacing the copy-only thread chip. The
  menu lists recent local-user threads, creates a new thread through
  `Conversations.resolve_thread/1`, switches back to prior threads, and keeps
  copy-thread-id available in the menu.

### Changed (v0.26.2)

- `CopyToClipboard` stops click propagation so copy actions inside click-away
  menus can complete without closing their parent menu first.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, and child app
  metadata bumped to `0.26.2`.

### Verification (v0.26.2)

- Focused tests passed:
  `agent_live_test.exs` (35 tests), `renderer_test.exs` (9 tests), and
  `tile_inspector_test.exs` (1 test).
- Release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`. The final `mix precommit` run reported 754 core tests,
  82 web tests, 168 StockSage plugin tests, and 2 channel plugin tests, all
  with 0 failures.
- Chrome browser smoke used two tabs on the same `/agent` thread. A pending
  approval ephemeral created in tab 1 appeared in tab 2 without reload; a
  StockSage objective canvas tile created in tab 1 appeared in tab 2 without
  reload; the inspector opened/closed on that real tile; the thread switcher
  copied the id, created a new thread, and switched back; Chrome console errors
  were empty.

### Manual Verification (v0.26.2)

Use a disposable Allbert Home, run migrations, start Phoenix, then open
`/agent` in Chrome:

1. Create a canvas tile, open the tile kebab, choose Inspect, verify focus
   enters `#workspace-tile-inspector`, provenance/body/copy controls render,
   and Escape closes it.
2. Open the thread switcher, copy the thread id, create a new thread, and
   switch back to the original thread.
3. Open the same thread in a second tab and confirm tile plus ephemeral updates
   converge without reload.

---

## v0.26.1 - Workspace UX/UI + Backend Runtime Closeout

Status: released and tagged as `v0.26.1` on 2026-05-22. This release
combines the v0.26a workspace UX/UI substrate pass with the v0.26b backend
runtime bugfix pass. Version metadata is `0.26.1`.

Plans:

- `docs/plans/v0.26a-ui-plan.md`
- `docs/plans/v0.26b-backend-plan.md`

### Fixed (v0.26b)

- Runtime intent fallback now recognizes generic safe setting-shaped prompts
  such as `set workspace.theme to dark` and routes them through
  `update_setting` even when no LLM key is configured.
- Secret-shaped, unsafe, and read-only setting prompts do not leak raw values;
  the existing Settings Central schema/action boundary owns validation and
  refusal.
- Native StockSage LLM preflight failures now surface bounded
  `native_llm_unavailable: ...` reasons through the native analysis failure
  path, persisted analysis metadata, action result, signal payload, and
  workspace fragment metadata.
- Disabling `stocksage.native_llm_enabled` still preserves deterministic
  fixture/smoke paths; v0.26b does not add automatic Python fallback.
- Fresh `/agent` composer state starts empty and uses neutral placeholder copy
  (`"Ask Allbert anything…"`).

### Verification (v0.26.1)

- `mix precommit` on merged `main`: 754 core tests, 79 web tests, 168
  StockSage plugin tests, and 2 channel plugin tests, all 0 failures.
- `mix credo --strict`, `mix compile --warnings-as-errors`, and formatter
  checks passed as part of the precommit gate.

---

## v0.26a - Workspace UX/UI Substrate Pass

Status: implemented through M35 closeout on 2026-05-21. Version metadata is
`0.26.1`. Fast-follow visual + interaction layer on top of the v0.26
workspace substrate; the substrate itself (catalog, schema, signals,
settings, permission classes, fragment validation, AGUI bridge, offline
editor) is unchanged.

Plan: `docs/plans/v0.26a-ui-plan.md`.

### Added (v0.26a)

- Live chat history accumulates without navigation. `handle_async(:ask, ok)`
  refreshes `conversation_messages`, `canvas_tiles`, and
  `ephemeral_surfaces` so prior turns stay visible as new turns land (M28).
- Composer clears on submit; Enter submits and Shift+Enter newlines via a
  new `ComposerEnter` JS hook that respects IME composition and modifier
  keys. Character counter mirrored from
  `workspace.canvas.tile_body_max_bytes` flips to a warn color at 90% of
  cap (M29).
- `ChatAutoScroll` JS hook pins the chat timeline to the bottom on append
  unless the operator has scrolled away.
- `CopyToClipboard` JS hook reused across the AppBar thread chip, runtime
  signal / trace ids, the approval modal confirmation id, every card
  footer's external-id chip, and the tile kebab "Copy tile id" entry.
- Sticky AppBar plus independently scrolling chat / canvas panes — the
  workspace shell is now a `100dvh` flex column rather than a normal-flow
  page (M30).
- Mobile tab strip stays sticky just below the AppBar at `< 768px` so the
  toggle is reachable while reading long chat history. Pane heights
  retightened to `calc(100dvh - 9rem)` to suit the sticky chrome (M31).
- Approval handoff renders as a centered modal overlay with a translucent
  backdrop scrim, dark-mode and reduce-motion variants, and a copy chip
  on the confirmation id. Authority is unchanged (approve / deny still
  route through registered actions) (M32).
- Every catalog card derived from `Base.render_simple/1` renders a status
  pill driven by `prop(:status)` / `prop(:lifecycle_kind)` / `prop(:state)`
  using `workspace-status-success` / `-info` / `-warn` / `-danger` /
  `-neutral` variants. Card footers carry an external-id chip
  (objective / confirmation / analysis / tile) that copies to clipboard
  on click (M33).
- AppBar overflow `…` is no longer disabled. Clicking opens a popup menu
  with the theme cycle, Workspace settings, Scheduled jobs, and Objectives
  links; uses LiveView state, no JS hook required.
- AppBar chips now navigate: thread chip copies the full thread id;
  objective chip links to `/objectives`; tile chip jumps to the canvas
  anchor; ephemeral chip jumps to the ephemeral anchor.
- 3-state theme cycle (system → dark → light → system) with the icon and
  label updating per state (M34).

### Changed (v0.26a)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, and child app
  metadata bumped to `0.26.1`.
- `Workspace.Fragment.emit/1` now logs the exception struct + message when
  the persistence rescue trips, so the bounded `:exception` drop reason
  becomes actionable. (The previous lack of detail made a test-suite
  sandbox connection-ownership leak look identical to a production bug.)
- Composer placeholder rewritten from `"Ask the agent something..."` to
  `"Ask Allbert anything…"`.
- Timeline timestamps render as relative time
  (`just now / 2m ago / Mar 04 14:32`) with full ISO retained on the
  `<time datetime>` attribute for accessibility.

### Verification (v0.26a)

- `mix test apps/allbert_assist_web/`: 79 tests, 0 failures (includes the
  new responsive + agent_live + composer assertions).
- `mix format --check-formatted`, `mix credo --strict`,
  `mix compile --warnings-as-errors`: all clean on commit.
- Browser-driven smoke confirmed the pre-M28 audit
  findings reproduced cleanly under the old code and that M28–M34 fixes
  resolved them. The v0.26.1 closeout records the final merged-main gate.

### Bugs flagged for separate triage (resolved by v0.26b)

- H1 (runtime): the intent agent falls through to `direct_answer` for
  clearly setting-shaped prompts (`"Set workspace.theme to dark"`) when
  no LLM API key is configured. The deterministic fallback should
  pattern-match `set <key> to <value>` and route to `update_setting`.
  Resolved in v0.26b.
- H2 (stocksage): native StockSage analysis transitions silently to
  `:failed` when no LLM key is configured. The failure reason should
  surface in the chat or via an ephemeral. Resolved in v0.26b through the
  native failure/action/signal/workspace-fragment path.
- H3 (runtime): the default LiveView prompt placeholder used to be content
  copy; M28 moved it into the empty-state callout, but CLI surfaces
  should follow. Resolved in v0.26b for the `/agent` composer state and
  placeholder.

---

## v0.26 - Agentic Workspace Surface And Ephemeral UI Substrate

Status: implemented through M30 UI release closeout on 2026-05-19 and
superseded by the accepted `v0.26.1` closeout. Version metadata was `0.26.0`
for the base workspace release and moved to `0.26.1` in the v0.26a/v0.26b
follow-up.

### Added (v0.26)

- `/agent` is now the Allbert workspace: a `CoreApp` Surface tree rendered by
  catalog-dispatched LiveComponents rather than a prompt-only page.
- Per-thread canvas tiles and per-thread ephemeral surfaces backed by SQLite
  metadata plus YAML bodies under Allbert Home.
- Runtime Fragment emission through signed, strictly validated
  `Workspace.Fragment.Envelope` payloads and `allbert.workspace.fragment.**`
  SignalBus topics.
- A 42-component workspace catalog: v0.18 carryover components, workspace
  structural nodes, Allbert-domain cards, app cards, and reserved StockSage
  card stubs for v0.27 rendering work.
- Workspace Mix tasks for inspect, canvas list/show/pin/unpin/restore/purge,
  ephemeral list, and signing-secret rotation.
- Dark/light workspace theme toggle, high-contrast and reduced-motion support,
  WCAG-oriented structural coverage, mobile tabs, and responsive two-pane
  layout. The mobile breakpoint is fixed at 768px and read-only in v0.26.
- Allbert-owned `/agent` chrome: AppBar identity, thread/active-app/status
  chips, slate-blue workspace tokens, soft stale-thread recovery notices, and
  a client-side-only chat/canvas split bar with pointer and keyboard support.
- Workspace-scoped service worker, offline shell fallback, browser-side Yjs +
  IndexedDB text/markdown tile editing, bounded reconnect sync, server-side
  revision snapshots, conflict banner, and `revert_tile_revision`.
- Internal `AllbertAssist.Workspace.AGUI.Bridge` mappings from curated Allbert
  signals to AG-UI event shapes for test-only semantic validation.

### Changed (v0.26)

- `AllbertAssist.App.CoreApp.version/0`, umbrella app metadata, and child app
  metadata are release-pinned to `0.26.0`.
- `AllbertAssist.App.CoreApp.surfaces/0` now declares the workspace shell at
  `/agent`; sibling routes remain available for deep links.
- Trace output includes workspace sections and fragment/tile activity where a
  runtime turn touches workspace state.
- ADR 0023 is Accepted and records the shipped workspace canvas and ephemeral
  surface substrate; ADR 0015's v0.26 catalog amendment is confirmed.
- M21-M26 post-review remediation bound `/agent` to real conversation
  threads, emitted runtime/objective Fragments, moved Fragment persistence out
  of LiveView, routed workspace writes through registered actions, synced
  ephemeral lifecycle events across tabs, enforced tile body limits, made
  reduced-motion effective, and made the unsupported dynamic mobile breakpoint
  read-only.
- M28-M29 replaced Phoenix scaffold leftovers and placeholder/debug-card
  renderers with Allbert Assist chrome, operator chat/canvas panes, polished
  tile shells, hidden empty badge/ephemeral regions, useful catalog cards,
  accessible tabs, and the browser-local split separator. This is visual
  polish over the existing v0.26 substrate; it does not add security authority.

### Safety (v0.26)

- Workspace effects still route through registered actions, `Actions.Runner`,
  Security Central, confirmations where required, and audit/traces. Surface
  metadata, fragments, apps, plugins, and generated files do not grant
  permission.
- Fragment validation enforces envelope shape, HMAC signature, catalog
  membership, emitter allow-list, per-emitter rate limit, and payload size
  before anything renders.
- Offline tile editing accepts only text/markdown tiles, bounds payload size,
  enforces canvas tile-body limits for snapshots, stores browser Yjs payloads
  opaquely, keeps readable server snapshots, and preserves rejected/corrupt
  local drafts for fallback-shell recovery instead of silently deleting them.
- No public AG-UI/A2UI/MCP Apps bridge ships in v0.26.

### Verification (v0.26)

- Milestone-focused suites covered workspace catalog, canvas/ephemeral
  persistence, Fragment validation/signing, AG-UI bridge mappings, trace
  integration, CLI tasks, theme/accessibility/responsive behavior, offline
  editor hooks, reconciliation, and revert action behavior.
- Disposable-home browser smokes covered the rendered workspace, component
  catalog, fragment flow, multi-tab sync, theme/a11y/mobile behavior,
  service-worker offline shell, IndexedDB draft restore, and stale-base
  conflict/revert behavior.
- Final gates passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- Final M30 `mix precommit` passed with 746 core tests, 71 web tests,
  165 StockSage plugin tests, and 2 channel plugin tests.
- Post-review fixes added the registered
  `workspace.fragment.receiver_rate_limit_per_second` setting, a short
  previous-secret verification overlap for workspace Fragment signing-key
  rotation, explicit release-gate wording that `mix precommit` includes
  plugin tests while bare `mix test` does not, and removed vestigial
  min/max bounds from the read-only `workspace.mobile.breakpoint_px` schema.
- M30 adds manual UI validation instructions for desktop, mobile, theme,
  stale-thread recovery, StockSage active-app routing, canvas/tile states,
  ephemeral overlays, offline behavior, resize behavior, accessibility, and
  cross-browser smoke. The v0.26.1 closeout is the accepted release tag.

## v0.25 - Native Financial Specialist Agents

Status: released. Implemented through M6 closeout on 2026-05-17. Version
metadata is `0.25.0`; release tag `v0.25.0` was reconciled during the
v0.29 release closeout.

### Added (v0.25)

- StockSage native financial specialist-agent graph: 11 supervised
  LLM-capable `Jido.AI` specialists, 1 deterministic quality gate, and the
  `StockSage.Agents.NativeCoordinator` JidoBacked orchestrator under
  the StockSage plugin supervisor.
- Explicit research-manager and trader-plan handoffs in the native graph,
  preserving the Python TradingAgents research/trader/portfolio-manager
  sequence more closely than the earlier collapsed synthesizer shape.
- Native analysis is now the default `run_analysis` engine. Explicit
  Python comparison remains available only by request (`--engine python`,
  `--engine both`, or `--compare-python`) and is gated by
  `stocksage.python_comparison_enabled`.
- Five action-backed evidence providers under `StockSage.Actions.Evidence.*`
  with fixture mode, Resource Access posture, and the
  `:stocksage_evidence_fetch` permission class.
- Multi-round bull/bear/risk debate with Settings-bounded caps and one
  durable `objective_steps` row per specialist turn.
- `--engine both` parity runs that fan out native + Python comparison,
  compute 5-point rating agreement plus confidence delta, and persist
  `parity_diff` JSON on the analysis row.
- A bounded committee-context ledger for the final decision synthesizer,
  including ordered specialist stances, rating counts, risk-committee
  summaries, and cautious-report excerpts.
- Core `mix allbert.delegate <agent_id>` task, proving any registered
  objective delegate agent can be invoked through the shared action
  boundary outside StockSage.

### Changed (v0.25)

- `StockSage.Actions.RunAnalysis` creates native objectives, persists
  native/parity details, labels explicit Python comparison clearly, and
  never falls back from native to Python automatically.
- StockSage agent prompts and prompt provenance live under
  `plugins/stocksage/priv/prompts/native_agents/` with v0.25 prompt
  version metadata.
- `stocksage.native_llm_enabled` controls whether non-quality native
  specialists call Jido.AI or use deterministic advisory packets for
  tests/operator smoke.
- Native/Python parity tuning is improved but not finished: v0.25 avoids
  ticker-specific correction logic and deterministic rating floors, and
  leaves deeper evidence-source and prompt/agent calibration as future work.
- StockSage plugin, app, manifest, CoreApp, and umbrella app versions
  are release-pinned to `0.25.0`.
- ADR 0022 is Accepted and records the shipped topology, coordinator
  loop, parity metric, evidence-action posture, and delegate CLI proof.

### Verification (v0.25)

- Focused suites passed for prompt inventory, specialist registry,
  evidence actions, native coordinator single and multi-round analysis,
  parity scoring/persistence, `mix allbert.delegate`, and StockSage CLI
  smoke paths.
- Final gates passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix dialyzer`, `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 683 core tests, 27 web tests, 165
  StockSage plugin tests, and 2 delegate task smoke tests.

## v0.24 - Objective Runtime Foundation

Status: released and tagged as `v0.24` on 2026-05-17 after post-audit
hardening and release verification. Version metadata is `0.24.0`.

### Added (v0.24)

- Durable objective runtime tables: `objectives`, `objective_steps`, and
  `objective_events`, plus nullable `objective_id` / `step_id` links on
  confirmations, scheduled jobs, StockSage queue rows, and StockSage analyses.
- `AllbertAssist.Objectives.Engine.Agent`, a JidoBacked seven-stage
  coordinator backed by 10 real private command modules for receiving a turn,
  framing/resuming an objective, proposing and evaluating steps, authorizing
  through the existing action boundary, executing, observing, advancing,
  continuing, cancelling, and pruning stale objectives.
- Registered objective actions:
  `list_objectives`, `show_objective`, `continue_objective`, and
  `cancel_objective`, surfaced through `mix allbert.objectives`.
- `:objective_write` permission class and objective runtime settings for the
  master switch, loop caps, stale abandonment window, and max steps per turn.
- Deterministic acceptance evaluator, durable hybrid proposer hints, and the
  first app proposer (`StockSage.Proposer`) proving a one-step analysis and a
  two-step "analyze AAPL and compare to MSFT" flow.
- Minimal `:delegate_agent` step contract and monitored
  `AllbertAssist.Objectives.AgentRegistry` as the v0.25 handoff for
  specialist agents; dead delegate-agent entries are evicted automatically.
- Objective lifecycle signals, canonical runtime turn signal aliases, and the
  web-side `AllbertAssistWeb.SignalBridge` that fans objective signals into
  per-user Phoenix.PubSub topics.
- `/agent` active-objective badges and `/objectives/:id` inspection/cancel
  surface. LiveViews remain thin consumers of registered actions.

### Changed (v0.24)

- StockSage `RunAnalysis` and queue/analysis rows now preserve
  `objective_id` and `step_id` context when invoked from an objective.
- Confirmation renderers for CLI, SettingsLive, Telegram, and email now show
  objective title/status context and a stale-warning note when the linked
  objective has moved since confirmation creation.
- `Intent.Engine.collect_candidates/2` now accepts objective context and ADR
  0019 registers `:objective` as a proposal-only candidate kind.
- Trace rendering now includes inline objective context and a bounded
  `## Objective Steps` section for turns that touch objective work.
- `AllbertAssist.Objectives` now exposes the public lifecycle facade
  (`list/2`, `get/2`, `frame/2`, `advance/2`, `cancel/3`, `continue/2`) while
  retaining lower-level store helpers for the engine.
- `mix allbert.objectives` now enforces documented OS exit codes for usage,
  not-found, identity mismatch, and unexpected action/security failures via a
  test-injectable halt function.
- `AllbertAssist.App.CoreApp.version/0`, umbrella app metadata, and
  StockSage plugin/app metadata are release-pinned to `0.24.0`.

### Safety (v0.24)

- `objective_id`, `step_id`, and `active_app` are never permission. Every
  effectful objective step still executes through `Actions.Runner.run/3`,
  Security Central, resource posture, and durable confirmations.
- The objective engine never writes confirmation YAML directly and never
  calls app internals for effectful work.
- Private objective command modules remain internal Jido engine commands and
  are not registered in `AllbertAssist.Actions.Registry`.
- Cancellation is cooperative only. Pending/proposed/selected/blocked steps
  can be cancelled; already approved in-flight work is not interrupted.
- Advisory provider, world-model, diffusion, market-allocation, and
  capability-inventory vocabulary remains reserved only. v0.24 ships no
  external advisory provider calls, no parallel execution, no dynamic
  planner, and no authority transfer to model output.

### Verification (v0.24)

- Milestone suites passed for objective schemas/migrations/settings,
  JidoBacked engine setup, all 10 private command modules, framing/resume,
  StockSage proposer integration, confirmation threading, continuation,
  delegation, cancellation, channel rendering, LiveView surfaces, and
  SignalBridge behavior.
- Hardening tests now cover directive-returning command paths, objective
  facade identity scoping, delegate-agent dead-entry cleanup, real CLI exit
  codes, migration up/down reversal, inline trace placement, Telegram/email
  plugin objective rendering, ObjectiveLive terminal/cross-user/PubSub paths,
  SignalBridge subscription failure, evaluator matrix cases, and engine
  proposer-hint rehydration.
- M5 focused suite passed with allbert_assist 42 tests and
  allbert_assist_web 7 tests, 0 failures.
- Closeout gates passed: `git diff --check`, `mix format
  --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer` (0 unskipped errors),
  `mix test` (`allbert_assist` 673 tests and `allbert_assist_web`
  27 tests), StockSage plugin tests (123 tests), Telegram/email plugin
  renderer tests (2 tests), and `mix precommit`.
- Operator smoke steps live in `docs/plans/v0.24-request-flow.md`.
- Release tag: `v0.24`.

## v0.23 - Jido State-Machine Convergence

Status: implemented and ready for operator manual verification. Version
metadata is `0.23.0`; the release tag is pending operator acceptance.

### Added (v0.23)

- `AllbertAssist.JidoBacked` shared substrate for internal state-machine
  coordinators that are implemented as `Jido.Agent` instances but keep their
  existing durable stores as the source of truth.
- `AllbertAssist.JidoBacked.Supervisor` under the core application
  supervision tree, currently hosting `Confirmations.Store.Agent` and
  `Jobs.Scheduler.Agent`.
- Jido-backed `AllbertAssist.Confirmations.Store.Agent` with private
  `Jido.Action` command modules for create/read/list/resolve/expire/rebuild.
  Confirmation YAML and audit markdown under Allbert Home remain authoritative.
- Jido-backed `AllbertAssist.Jobs.Scheduler.Agent` with private scheduler
  commands for run-once, stale-run cleanup, tick, and scheduled next tick.
  SQLite `scheduled_jobs` and `scheduled_job_runs` rows remain authoritative.
- `allbert.jido.debug_trace` Settings Central key, default `false`. When
  enabled alongside trace recording, trace markdown includes a bounded
  `## Jido Debug` section for the converted coordinators.
- `docs/developer/jido-agent-pattern.md` and updated development/agent context
  docs describing the pragmatic rule for choosing `Jido.Agent` vs plain
  `GenServer`.

### Changed (v0.23)

- `AllbertAssist.Confirmations.Store` and `AllbertAssist.Jobs.Scheduler` are
  now public facades over Jido-backed agents. Their public API, CLI behavior,
  action behavior, audit shapes, and durable storage locations are preserved.
- `AllbertAssist.Application` starts scheduler coordination through
  `AllbertAssist.JidoBacked.Supervisor` rather than a separate scheduler child.
- Transitional compatibility modules used during parity testing were removed
  before release closeout.

### Safety (v0.23)

- Private command actions are not registered capabilities, not intent
  candidates, and not operator-callable actions. All effectful public behavior
  still goes through the existing registered action runner and Security
  Central boundaries.
- `Jido.Agent` is not treated as a security boundary. Durable confirmations
  remain file-backed; scheduled jobs remain SQLite-backed; permissions and
  confirmations remain enforced at the public action boundary.
- Default operator traces remain unchanged. Jido debug details appear only
  after explicitly enabling `allbert.jido.debug_trace`, and the emitted
  metadata is bounded and redacted.

### Verification (v0.23)

- Focused suites passed for JidoBacked helpers/supervision, confirmation-store
  agent parity, confirmation public actions/CLI, scheduler agent behavior,
  jobs public API/CLI/LiveView consumers, convergence integration flows,
  channel simulation flows, memory confirmation actions, and StockSage
  `RunAnalysis` confirmation behavior.
- Retained v0.23 fixture snapshots cover canonical confirmation audit output
  and scheduler summary output under
  `apps/allbert_assist/test/fixtures/v0.23/`; `StoreGoldenTest` and
  `SchedulerGoldenTest` read those fixtures as release regression coverage.
- Closeout gates passed: focused v0.23 M1-M4 suites, full `mix test`,
  plugin `RunAnalysis` regression, `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, deleted-module grep gate, and `git diff --check`.
- Operator smoke steps live in `docs/plans/v0.23-request-flow.md`.

## v0.22 - StockSage Python Bridge

Status: released and tagged as `v0.22` on 2026-05-16 after M5 closeout,
operator audit closeout, and post-implementation gap fixes. Version metadata
is `0.22.0`.

### Added (v0.22)

- `StockSage.Bridge.Protocol` and `./plugins/stocksage/priv/python/bridge.py`
  implement the ADR 0020 JSON-over-stdio envelope for the supervised Python
  bridge. The bridge supports `ping` and `run_analysis` actions and bounds
  responses with `stocksage.bridge_max_output_bytes`.
- `StockSage.TraderBridge` GenServer owns a long-lived Erlang `Port` to
  `bridge.py`, isolates Port crashes with `{:error, :bridge_crashed}`, and
  honours `stocksage.bridge_enabled`, `stocksage.bridge_timeout_ms`, and
  `stocksage.python_path` from Settings Central. The bridge runs under
  `StockSage.Supervisor` as a plugin-owned child contributed via
  `StockSage.Plugin.child_spec/1`.
- `StockSage.Actions.RunAnalysis` registered through
  `StockSage.Plugin.actions/0` as a `resumable?: true` Jido action gated by
  the new `:stocksage_analyze` permission. The action validates ticker (regex,
  ≤10 chars) and ISO-8601 analysis date, creates a durable confirmation
  record on the first call, and runs the bridge on the approved resume path
  through `AllbertAssist.Actions.Confirmations.ApproveConfirmation`. Bridge
  success persists `stocksage_analyses` (+ `stocksage_analysis_details`)
  rows; bridge errors persist a `status: failed` analysis row.
- `:stocksage_analyze` permission class added to `AllbertAssist.Security.Policy`
  and `AllbertAssist.Security.Risk` with default `needs_confirmation`, safety
  floor `needs_confirmation` (cannot be lowered to `allowed` via settings),
  and risk tier `high`.
- `permissions.stocksage_analyze` setting registered in the core schema with
  `allowed_values: ["needs_confirmation", "denied"]`. Five new
  `stocksage.bridge_*` and `stocksage.analysis_engine` settings added to the
  StockSage plugin settings schema.
- `mix stocksage.analyze TICKER ANALYSIS_DATE [--user] [--engine] [--queue-id]`
  CLI prints the confirmation id on first call and completed analysis
  metadata after approval. `--queue-id` links a queue entry to the run.
- `AllbertAssist.Trace` renders a new `## StockSage Analysis` section with
  bounded action metadata (action, status, ticker, analysis date, engine,
  analysis id, bridge duration, truncated, summary ≤ 200 chars).
- New `run-analysis` skill declares the `run_analysis` action,
  `:stocksage_analyze` permission, confirmation requirement, and example
  prompts. The skill is discoverable via the v0.19 engine when
  `active_app: :stocksage`.

### Safety (v0.22)

- Bridge execution requires confirmation by default. The `:stocksage_analyze`
  safety floor is `:needs_confirmation` and cannot be lowered via settings.
- TradingAgents external market-data API calls are included in the operator's
  approval scope and disclosed in the confirmation record. Per-source
  Resource Access Security Posture for those calls is deferred to v0.28
  (formerly v0.26 before the project-direction rethink renumber).
- Raw bridge output is bounded by `stocksage.bridge_max_output_bytes` and
  never appears in traces, CLI list summaries, or signals. Only bounded
  summaries (≤500 chars in `stocksage_analyses.summary`, ≤200 chars in
  trace `## StockSage Analysis`) are surfaced. `show_analysis` returns only
  the vetted detail payload fields (`engine`, `stub`, `truncated`) and never
  exposes arbitrary imported `payload_json`.
- Bridge crashes and timeouts do not propagate to Allbert core supervision;
  callers receive bounded `{:error, :bridge_crashed}` / `{:error, :timeout}`.
- Setting `stocksage.bridge_enabled = false` short-circuits RunAnalysis before
  any confirmation record is created.
- All bridge code lives under `./plugins/stocksage/`. Allbert core does not
  import bridge internals; the only core touchpoints are
  `AllbertAssist.Actions.Runner`, `AllbertAssist.Security`,
  `AllbertAssist.Actions.Registry`, and `AllbertAssist.Repo`.

### Verification (v0.22)

- Focused suites passed for `StockSage.Bridge.ProtocolTest`,
  `StockSage.TraderBridgeTest` (tagged `:bridge`), `StockSage.SupervisorTest`,
  `StockSage.Actions.RunAnalysisTest` (including the
  `approve_confirmation` end-to-end loop and bounded confirmation CLI target
  summary),
  `Mix.Tasks.Stocksage.AnalyzeTest`, the StockSage `ActionsTest` intent
  routing additions, `StockSage.TraceTest`, and the
  `AllbertAssist.Security.PermissionGateTest` additions for
  `:stocksage_analyze`.
- Closeout gates: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Operator smoke confirmed (`mix stocksage.analyze AAPL 2026-05-01 --user
  local` → confirmation id → `mix allbert.confirmations approve <id>` →
  `stocksage_analyses` and `stocksage_analysis_details` rows persisted with
  bounded summary, confirmation resolved as approved).

## v0.21 - Memory Review And Retrieval

Status: implemented through M6 closeout and post-implementation gap fixes on
2026-05-15. Version metadata is `0.21.0`; the operator manual verification
matrix remains the release gate. Release tag is pending operator acceptance.

### Added

- Review-aware markdown memory entries with explicit `review_status`,
  reviewer, review timestamp, and correction notes.
- `mix allbert.memory` commands for listing, showing, searching, reviewing,
  updating, deleting, pruning, promoting conversation turns, compiling the
  memory index, and summarizing categories.
- Registered memory actions for review/correction/pruning/promotion, all
  routed through `Actions.Runner.run/3` and Security Central.
- Rebuildable derived memory artifacts: `.index.json` and category
  `.summary.md` files under the markdown memory root.
- Metadata-only `:memory` intent candidates from the compiled index, with
  trace rendering for bounded candidate metadata.
- `memory-index-rebuild` as a CLI-instantiated scheduled job template and as
  the managed job synchronized from `memory.review_cadence`.
- `memory.prune_requires_confirmation` to control bulk prune confirmation
  independently from single-entry delete confirmation.

### Safety

- Markdown memory remains the source of truth; SQLite conversation history is
  never auto-promoted.
- Delete, prune, and promote flows use durable confirmations by default, and
  deleted/pruned entries are archived under `memory/deleted/YYYY-MM/` rather
  than hard-deleted.
- Memory candidates are proposal data only. They do not grant permissions,
  authorize actions, or include entry bodies in intent traces. Candidate scores
  are capped at 0.5.
- Flagged and prune-nominated entries are excluded from search/index intent
  candidates.

### Verification

- Focused suites passed for memory entry parsing, review status round-trips,
  memory actions, promotion ownership checks, index/search/summary artifacts,
  trace rendering, intent memory candidates, job templates, and Mix tasks.
- Post-implementation focused suites added compiler edge-case tests, cadence
  job synchronization tests, prune-confirmation separation coverage, and the
  memory candidate score cap assertion.
- Final v0.21 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- Manual verification steps live in `docs/plans/v0.21-request-flow.md`.

## v0.20 - StockSage Plugin App And Domain

Status: implemented through M5 closeout fixes on 2026-05-15. Version metadata
is `0.20.0`; the operator manual verification matrix remains the release gate.
Release tag is pending operator acceptance.

### Added

- `./plugins/stocksage` as the first real shipped plugin app package with
  `StockSage.Plugin`, `StockSage.App`, skill roots, settings schema entries,
  and registered action contributions.
- Plugin-owned StockSage domain, action, import, CLI, and test modules under
  `./plugins/stocksage`; no `apps/stocksage` or `apps/stocksage_web` umbrella
  apps.
- Shared SQLite `stocksage_*` domain tables through `AllbertAssist.Repo`:
  analyses, analysis details, outcomes, queue entries, queue runs, and
  StockSage-local memory entries.
- `StockSage.Import.SqliteImporter` and `mix stocksage.import_sqlite` for
  read-only, idempotent import of the representative legacy SQLite fixture.
- Safe local actions `list_analyses`, `show_analysis`, `get_trends`, and
  `queue_analysis`, all contributed through `StockSage.Plugin.actions/0`.
- Operator CLIs `mix stocksage.analyses list/show` and
  `mix stocksage.queue create/list`.
- `mix allbert.skills list` for operator inspection of discovered skill
  manifests, including StockSage plugin provenance.
- `mix allbert.ask --active-app APP_ID` for one-turn CLI app context, used
  alongside volatile running-node session scratchpad context.
- `:stocksage_write` as a low-risk local domain write permission for queue and
  domain writes only.

### Safety

- StockSage uses the existing `AllbertAssist.Repo`; no `StockSage.Repo` or
  second database boundary was introduced.
- Every domain row carries `user_id`, and read-by-id paths require `user_id`;
  another user's durable id returns not-found.
- v0.20 does not execute Python, call market-data APIs, mount StockSage
  LiveViews, start native trading agents, or emit canvas components.
- `queue_analysis` creates only a durable local queue row. It does not start a
  worker or external process.
- Engine-selected registry actions from direct-answer fallbacks now execute
  through `Actions.Runner`; app affinity still does not grant permission.
- StockSage memory entries are SQLite domain records and are not automatically
  promoted into markdown Allbert memory.

### Verification

- Focused suites passed for plugin/app registration, domain schemas and
  contexts, legacy import, actions through `Actions.Runner`, settings schema
  merge, Security Central, and StockSage Mix tasks.
- Final v0.20 closeout gates passed: `mix test`,
  `mix test ../../plugins/stocksage/test/stocksage ../../plugins/stocksage/test/mix`
  from the host app, `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.20-request-flow.md`.

## v0.19 - Cross-Surface Intent Enrichment

Status: implemented through M6 closeout on 2026-05-15. Version metadata is
`0.19.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Registry-aware intent candidates for actions, skills, and registered app
  surfaces, with bounded selected/rejected candidate metadata in decisions.
- Active-app affinity and inert registered-surface navigation decisions for
  prompts such as opening the Allbert chat surface.
- Optional `AllbertAssist.Intent.Classifier` model-assist hook, disabled by
  default, with fake classifier tests and candidate-set validation.
- `explain_intent` and `list_intent_candidates` read-only internal actions for
  operator inspection.
- `## Intent Candidates` trace rendering with selected candidate, rejected
  candidates, app context, classifier diagnostics, and surface target metadata.

### Safety

- v0.11-v0.13 resource, confirmation, Approval Handoff, job, and channel
  behavior remains unchanged; risky prompts still route through their existing
  registered actions and resource posture before any surface fallback.
- `active_app`, plugin provenance, surface metadata, and model output are
  ranking/explainability inputs only. They do not grant authority or bypass
  Security Central.
- Model assistance cannot invent candidates, is off by default, and records no
  raw prompt or raw model completion in traces.

### Verification

- Focused suites passed for candidate validation, ranking, classifier fallback,
  runtime risky-route preservation, trace rendering, and intent-inspection
  actions.
- Final v0.19 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.19-request-flow.md`.

## v0.18 - Full App Contract And Surface DSL

Status: implemented through M6 closeout on 2026-05-15. Version metadata is
`0.18.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Full `AllbertAssist.App` contract callbacks for agents, signals, and
  settings schema metadata while preserving v0.15 minimal app compatibility.
- `AllbertAssist.App.SurfaceProvider` and the validated
  `AllbertAssist.Surface` DSL with nodes, action bindings, catalog validation,
  and the initial twelve-component catalog.
- `AllbertAssist.Surface.Encoder.to_a2ui/1` as a typed future adapter boundary
  that returns `{:error, :not_implemented}` without adding AG-UI/A2UI runtime
  dependencies.
- `AllbertAssist.App.CoreApp` as the first surface provider, declaring the
  existing `/agent` route as the built-in chat surface.
- `mix allbert.validate_app MODULE` and
  `docs/developer/how-to-create-an-allbert-app.md`.

### Changed

- Runtime turns now default to `active_app: :allbert` when no known request or
  scratchpad app context exists. Unknown app id strings fall back to `:allbert`
  with diagnostics and without atom creation.
- App registry entries now store agents, signals, settings schema entries,
  provider surfaces, and surface catalogs.
- `mix allbert.apps show` and the `show_app` action now expose v0.18 contract
  summaries without raw node trees or process internals.
- Settings Central now merges app and plugin settings schema contributions at
  read/validation time, closing the v0.17 schema-consumption gap.

### Safety

- App registration, provider surfaces, action bindings, and `active_app`
  context do not grant permissions or bypass Security Central.
- Surface validation rejects unknown components, duplicate node ids, non-local
  paths, secret-like props, raw HTML/script values, remote URL props, and
  unknown action bindings before registration.
- v0.18 does not add memory namespace registration, canvas rendering, dynamic
  route loading, generated UI execution, AG-UI/A2UI dependencies, or app/plugin
  generators.

### Verification

- Focused suites passed for the app contract, Surface DSL, app registry,
  settings schema merge, runtime active-app defaulting, app actions, and Mix
  app validation tasks.
- Final v0.18 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.18-request-flow.md`.

## v0.17 - Plugin Contract And Shipped Channel Plugins

Status: implemented through M6 closeout on 2026-05-14. Version metadata is
`0.17.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.Plugin` behaviour, normalized plugin entries, manifest
  validation, plugin discovery, supervised plugin registry/bootstrap, and a
  plugin child supervisor.
- Static `plugins.*` settings schema and default scan paths for `./plugins`
  and `<ALLBERT_HOME>/plugins`.
- Shipped source-tree plugin packages for Telegram and email under
  `./plugins/allbert.telegram` and `./plugins/allbert.email`.
- Plugin-contributed skill roots, actions, apps, channel descriptors, settings
  schema metadata, and supervised child specs.
- Read-only registered actions `list_plugins` and `show_plugin`.
- `mix allbert.plugins list/show/diagnostics`.

### Changed

- Telegram and email provider-specific channel code moved out of the core app
  tree and into shipped source-tree plugin packages while preserving v0.16
  channel behavior and settings keys.
- `AllbertAssist.Channels` now reads channel descriptors from
  `AllbertAssist.Plugin.Registry` instead of a hardcoded provider map.
- `AllbertAssist.Actions.Registry` can merge trusted compiled
  plugin-contributed actions while stamping plugin provenance on capability and
  runner metadata.
- `AllbertAssist.App.Bootstrap` consumes plugin-contributed app modules.
- Version metadata and built-in app versions moved to `0.17.0`.

### Safety

- Plugins are discovery and packaging contracts, not authority. Plugin metadata
  does not grant permissions, trust, confirmations, resource access, or
  execution rights.
- v0.17 does not load arbitrary code from `<ALLBERT_HOME>/plugins`, run package
  managers during discovery, install remote plugins, hot-reload plugin code, or
  automatically compile arbitrary `./plugins/*/lib` folders.
- Plugin CLI/action output renders normalized metadata and contribution counts;
  it does not print raw manifests, provider payloads, or secret reference keys.

### Verification

- Milestone focused suites passed for plugin validation, manifest discovery,
  plugin registry/bootstrap, skill roots, channel descriptor migration,
  plugin-contributed apps/actions, and `mix allbert.plugins`.
- Final v0.17 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.17-request-flow.md`.

## v0.16 - Additional Channels

Status: implemented through M7 closeout on 2026-05-14. Version metadata is
`0.16.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Shared `AllbertAssist.Channels` substrate with durable `channel_events`,
  explicit external identity mapping, stable channel `session_id` derivation,
  and supervised channel adapters.
- Telegram Bot API long-polling adapter with bounded `Req` client, text and
  callback parsing, runtime submission, response rendering, inline approval
  buttons, callback acknowledgements, and restart offset derivation.
- Email IMAP/SMTP adapter with minimal TLS IMAP polling, `gen_smtp` outbound
  replies, MIME text parsing, typed confirmation commands, and Message-ID
  dedupe.
- Read-only registered actions `list_channels` and `show_channel`.
- `mix allbert.channels` for list/show, Telegram token storage, email password
  storage, identity map/unmap, local simulation, and bounded `poll-once`.

### Changed

- Runtime turns from Telegram and email preserve `channel`, external identity,
  resolved `user_id`, `session_id`, `thread_id`, input signal id, and trace id
  on channel event rows.
- Durable confirmation resolution now preserves redacted `resolver_metadata`
  from channel callbacks and typed email commands.
- Version metadata and built-in app versions moved to `0.16.0`.

### Safety

- Channels are delivery adapters only. They do not own intent, security policy,
  confirmation storage, memory, jobs, app routing, or execution authority.
- Telegram and email credentials are stored through Settings Secrets and are
  redacted from CLI output, traces, logs, and channel summaries.
- v0.16 adds no SMS, Discord, Slack, webhooks, IMAP IDLE, SMTP provider APIs,
  media downloads, attachments, remote document extraction, provider method
  execution, or proactive broadcast.

### Verification

- Milestone focused suites passed for channel settings/schema, durable event
  dedupe, identity resolution, Telegram transport/runtime/callbacks, email
  transport/runtime/commands, confirmation action metadata, and
  `mix allbert.channels`.
- Final v0.16 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.16-request-flow.md`.

## v0.15 - Minimal App Registration Contract

Status: released and tagged as `v0.15` on 2026-05-14. Version metadata is
`0.15.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.App` lite behaviour for local workspace app identity,
  validation, optional child supervision, registered actions, skill paths, and
  static navigation surface entries.
- Supervised volatile `AllbertAssist.App.Registry`,
  `AllbertAssist.App.DynamicSupervisor`, and `AllbertAssist.App.Bootstrap`
  under `AllbertAssist.App.Supervisor`.
- Built-in `AllbertAssist.App.CoreApp` (`app_id: :allbert`) and transitional
  `AllbertAssist.App.StockSageStub` (`app_id: :stocksage`).
- Optional `app_id` on `AllbertAssist.Actions.Capability`, registry-backed
  stamping for app-registered actions, and
  `AllbertAssist.Actions.Registry.capabilities_for_app/1`.
- Read-only registered actions `list_apps` and `show_app`.
- `mix allbert.apps list`, `mix allbert.apps show APP_ID`, and
  `mix allbert.apps validate MODULE`.
- App-contributed skill paths in `AllbertAssist.Skills.Registry` at
  precedence 3, after project roots and before user roots.

### Changed

- `AllbertAssist.Session.AppId` now validates active app ids through
  `AllbertAssist.App.Registry.normalize_app_id/1` instead of the v0.14 static
  allowlist.
- `AllbertAssist.Intent.Decision` treats unknown candidate `active_app` values
  as diagnostics-only fallbacks while preserving known session context.
- App id normalization avoids dynamic atom creation from operator, channel, or
  model input.

### Safety

- App registration is contract data, not authority. App ids, skill paths,
  navigation surfaces, and capability tags do not grant permissions.
- Registered app actions still execute only through
  `AllbertAssist.Actions.Runner.run/3`, Security Central, confirmation
  workflow, redaction, traces, and audits.
- v0.15 adds no `AllbertAssist.Surface` DSL, dynamic route loading, workspace
  shell, canvas state, app-scoped jobs, app-scoped permission grants, hosted
  accounts, external UI protocol adapters, or app generator.

### Verification

- Milestone focused suites passed for app behaviour/validation, registry
  supervision, capability tagging, decision validation, active-app session
  continuity, app actions, `mix allbert.apps`, app skill-path discovery, child
  failure diagnostics, and restart recovery.
- Final v0.15 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.15-request-flow.md`.

## v0.14 - Session Scratchpad And Active App Context

Status: released and tagged as `v0.14` on 2026-05-14. Version metadata is
`0.14.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Supervised `AllbertAssist.Session.Scratchpad` GenServer owning a protected
  ETS table keyed by `{user_id, session_id}`.
- `AllbertAssist.Session` facade for normalized `get`, `put`,
  `set_active_app`, `clear_active_app`, `merge_working_memory`, `clear`,
  `list`, `touch`, and `sweep_expired` operations.
- Settings Central key `sessions.scratchpad_ttl_minutes` with default `30`
  and validation range `[1, 1440]`.
- Static v0.14 `AllbertAssist.Session.AppId` allowlist for nil/general,
  `:allbert`, and `:stocksage` active-app context.
- Registered actions `set_active_app`, `clear_active_app`, and
  `show_session_scratchpad` through the shared action runner.
- `mix allbert.sessions` list/show/set-active-app/clear-active-app/clear/sweep
  commands.
- `mix allbert.ask --session SESSION_ID`.

### Changed

- Runtime requests with a `session_id` read scratchpad context once per turn,
  touch live entries, and propagate `active_app` to input signals,
  intent-agent request maps, response signals, response maps, traces,
  assistant/user message metadata, and assistant action logs.
- `AllbertAssist.Intent.Decision` validates `active_app` through the v0.14
  allowlist and rejects unknown model/agent active-app output.
- Scheduled runtime-prompt job run logs now preserve inherited response
  `active_app` context.

### Safety

- Scratchpad state is volatile ETS context only. It is not durable memory,
  auth, hosted sessions, app registration, app routing, or a security boundary.
- Raw `working_memory` values stay out of CLI output, registered action
  results, signals, traces, logs, response payloads, and persisted action logs.
- v0.14 adds no workspace UI, canvas state, browser/crawler behavior,
  semantic/vector retrieval, hosted accounts, new permission classes, new
  confirmation semantics, or new execution primitives.

### Verification

- Milestone focused suites passed for scratchpad API/TTL/restart behavior,
  Settings validation, AppId normalization, registered actions, sessions CLI,
  runtime propagation, Decision validation, ask CLI, job inheritance, and
  observability redaction.
- Final v0.14 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.14-request-flow.md`.

## v0.13 - Scheduled Jobs

Status: released and tagged as `v0.13` on 2026-05-14. Version metadata is
`0.13.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- SQLite scheduled jobs and run records through `AllbertAssist.Jobs`,
  `scheduled_jobs`, and `scheduled_job_runs`, with opaque `job_...` and
  `run_...` ids.
- Schedule normalization and next-due calculation for manual, daily, weekly,
  and supported five-field cron-like schedules.
- Supervised local `AllbertAssist.Jobs.Scheduler` with durable due-job polling,
  schedule-policy pause support, job lifecycle signals, and stale running-run
  cleanup using `scheduler_restarted`.
- `AllbertAssist.Jobs.Runner` for manual and scheduler runs through existing
  runtime/action boundaries.
- `mix allbert.jobs` for list/show/runs/create/pause/resume/run plus explicit
  CLI templates.
- Built-in templates `daily-brief`, `registry-health`, and `trace-summary`;
  templates instantiate ordinary job rows and are not seeded.
- Read-only registered actions `registry_health` and `trace_summary`.
- Thin `/jobs` LiveView inspection for jobs, recent runs, confirmation ids,
  and pause/resume/manual-run controls.

### Changed

- `jobs.timezone`, `jobs.default_state`, and `jobs.schedule_policy` are now
  writable Settings Central keys.
- Confirmation origins now preserve scheduled-job `job_id`, `run_id`,
  `user_id`, `operator_id`, `thread_id`, `session_id`, and `app_id` when
  confirmation-producing actions run from jobs.
- Job run summaries are redacted and JSON-safe before persistence.

### Safety

- Jobs do not add new execution primitives. Runtime prompt jobs call
  `AllbertAssist.Runtime.submit_user_input/1`; registered action jobs call
  `AllbertAssist.Actions.Runner.run/3`.
- Confirmation-required job work stops at the existing durable confirmation
  workflow and blocks automatic reruns without creating a job-specific approval
  queue.
- v0.13 adds no hosted accounts, roles, distributed scheduling, remote workers,
  archive/delete workflow, app-specific routing, session scratchpad semantics,
  or automatic markdown-memory promotion.

### Post-Validation Fixes

- Blocked jobs can no longer be resumed while their referenced confirmation is
  still pending. Once the confirmation is resolved, resume clears
  `blocked_confirmation_id`, reactivates the job, and recomputes `next_due_at`.
- Manual job runs now reject blocked jobs before creating a run record, with
  CLI and `/jobs` LiveView output pointing to `mix allbert.confirmations show`.
- The scheduled job unique constraint name now matches the migration index.
- Added regression coverage for blocked resume/run behavior, CLI and LiveView
  blocked-state handoff, `new_thread_per_run`, deleted origin-thread runtime
  failures, and cross-midnight cron schedules.

### Verification

- Milestone focused suites passed for job schema/context behavior, schedule
  parsing, manual runner behavior, supervised scheduler due polling, restart
  cleanup, CLI commands/templates, confirmation origin metadata, and LiveView
  inspection.
- Final v0.13 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.13-request-flow.md`.

## v0.12 - Local Workspace Identity And Conversation History

Status: released and tagged as `v0.12` on 2026-05-13. Version metadata is
`0.12.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- SQLite conversation history through `AllbertAssist.Conversations`,
  `conversation_threads`, and `conversation_messages`, with opaque `thr_...`
  and `msg_...` ids.
- Canonical local string `user_id`, preserving `operator_id` as a compatibility
  alias and defaulting omitted identity to `"local"`.
- Runtime thread selection for explicit `thread_id`, recent general thread,
  and `new_thread` requests.
- User messages are persisted before the agent runs; assistant messages are
  persisted after response and trace metadata are known.
- Bounded recent thread context, initially the last 12 prior messages, is
  passed to the intent agent as structured `thread_context`.
- `mix allbert.ask` now accepts `--user`, `--thread`, and `--new-thread`, while
  preserving `--operator`.
- `mix allbert.threads` lists user-scoped threads and shows ordered messages.

### Changed

- Runtime responses, input/response signals, traces, v0.11 intent decisions,
  confirmation origins, and persisted assistant action logs carry `user_id`
  and `thread_id`.
- CLI ask output renders `User:` and `Thread:` alongside status, message,
  signal, trace, Approval Handoff, diagnostics, and actions.
- v0.11 confirmation-required turns now persist pending assistant history with
  decision, resource access, Approval Handoff, diagnostics, and confirmation
  metadata.

### Safety

- v0.12 adds no hosted accounts, auth, roles, teams, app routing, session
  scratchpad, semantic retrieval, vector search, LiveView thread sidebar, or
  markdown-memory promotion.
- User isolation is local context and UX scoping, not hosted authorization.
- Conversation history is SQLite-only and distinct from markdown long-term
  memory. Ordinary conversation turns do not create markdown memory entries;
  explicit memory actions and explicit trace recording keep their existing
  behavior.
- v0.11 operation-scoped approvals, remembered grant matching, Security
  Central, Settings Central, confirmation resolution, shell/package/network
  policy, redaction, traces, and audits remain authoritative.

### Verification

- Milestone focused suites passed for conversation schema/context behavior,
  runtime identity normalization, thread selection, message persistence,
  bounded thread context, CLI ask/thread surfaces, cross-user isolation,
  trace/signal metadata, confirmation-origin metadata, and v0.11 Approval
  Handoff persistence.
- Final v0.12 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.12-request-flow.md`.

## v0.11 - Execution-Aware Intent, Resource Access, And Approval Handoff

Status: released and tagged as `v0.11` on 2026-05-13. Version metadata is
`0.11.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.Intent.Decision`, `AllbertAssist.Intent.ResourceAccess`, and
  `AllbertAssist.Intent.ApprovalHandoff` as inert contracts for selected
  intent, skills/actions, permission, confirmation, execution mode, URI-backed
  resource posture, alternatives, diagnostics, traces, and reserved
  `user_id`/`thread_id`/`session_id`/`active_app` context.
- Runtime responses, signals, and markdown traces now carry decision,
  resource-access, diagnostics, and Approval Handoff metadata.
- CLI and LiveView approval surfaces render the shared Approval Handoff for
  pending confirmations, including confirmation id, target action, operation
  class, scope, limits, downstream consumer, remember-scope choices, and
  approve/deny/details controls.
- URL summary prompts now create pending `external_network_request`
  confirmations with `summarize_url` resource refs before any fetch. Approved
  fetches report `summarizer_unavailable` until a summarizer action exists.
- Remote document inspection prompts now create pending
  `external_network_request` confirmations with `inspect_document` resource refs
  before any fetch. Approved fetches report `extractor_unavailable` until a
  registered extractor exists.
- Generic local file inspection prompts now return inert `file://...`
  `read_local_path` posture and an explicit no-shell-fallback unavailable state.
- Direct skill URL import, local skill directory import, package planning,
  shell execution, trusted skill scripts, online skill sources, and unsupported
  MCP/agent schemes are covered as operation-scoped URI consumers in the
  decision/handoff path.

### Changed

- The v0.10 URI-first resource substrate is now consumed by execution-aware
  intent instead of only by individual actions.
- Approval Handoff is shared channel metadata; CLI and web surfaces still resolve
  through `approve_confirmation` and `deny_confirmation` rather than mutating
  confirmation records or invoking adapters directly.
- URL/document consumer approvals are operation-scoped. `summarize_url` and
  `inspect_document` grants do not authorize `import_skill`,
  `external_service_request`, package install, activation, or script execution.
- README, roadmap, v0.11 plan, v0.11 request flow, and v0.12/v0.13/v0.16
  handoff docs now describe v0.11 as the current implemented base for the next
  milestones.

### Safety

- v0.11 adds no new browser, crawler, MCP, agent, package, shell, skill script,
  generic local file, or network primitive.
- Intent decisions are descriptive and validated before dispatch; they do not
  execute or authorize work by themselves.
- Approved URL/document fetches still run only through the v0.10 confirmed Req
  adapter, Settings Central policy, Security Central, confirmation re-check,
  redaction, trace, and audit boundaries.
- Missing summarizer, extractor, or bounded local reader capabilities are shown
  as unavailable instead of falling back to shell commands, ad hoc file reads,
  browser automation, or model-generated scripts.

### Verification

- Milestone focused suites passed for intent decision validation, Approval
  Handoff data, CLI and LiveView rendering, URL summary/document/local-file
  consumers, external request operation-scoped grants, direct/local skill import,
  package resource posture, resource refs, remembered grants, and unsupported
  MCP/agent flows.
- Final v0.11 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.11-request-flow.md`.

## v0.10 - External Capability Adapters

Status: implemented through M14 after the reopened v0.10 M6-M9 sequence. The
original M5 release-readiness gate was reopened for online skill approval
clarity/search fixes and Resource Access Security Posture planning; M9 closed
the release-readiness refresh. A later zoom-out release audit reopened v0.10
for M10-M14 closeout milestones before release. M10 landed
resource identity hardening; M11 has landed remembered-grant operator
UX/application for existing v0.10 actions. M12 has landed URI-first
`resource_uri` resource/grant authority through
`AllbertAssist.Resources.ResourceURI`. M13 has landed direct/local skill
import consumers on that URI substrate. M14 has landed final unsupported UX
and v0.11 handoff readiness. v0.10 was released and tagged as `v0.10` on
2026-05-04.

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
- Unsupported v0.11-owned resource workflows now route to the inert
  `unsupported_resource_workflow` action. CLI, LiveView, and the runtime give
  the same no-fetch/no-read/no-execute explanation for URL summarization,
  document inspection/extraction, MCP resource/tool calls, `agent://` or
  `agent+https://` delegation, broad browsing/crawling/research, and future
  channel-native approval handoff.
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
- M14 closes v0.10 by routing v0.11-owned resource workflows to explicit
  unsupported/deferred UX rather than creating partial `external_network`
  confirmations. v0.11 consumes this as the baseline for execution-aware
  intent and channel-native Approval Handoff.

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
  flows now return explicit unsupported/deferred responses and still need the
  v0.11 intent and Approval Handoff contract over the v0.10 URI resource
  posture.

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
- M14 focused tests pass for unsupported URL summarization, document/MCP/agent
  handoff routing, CLI ask output, LiveView rendering, registry metadata, plus
  the existing external request, online skill, package install, direct/local
  skill import, confirmations, resource refs, resource grants, resource CLI,
  skill CLI, and `/settings` suites.
- Operator/user testing should start with `docs/operator/onboarding.md` and
  use the disposable v0.10 smoke flow in `docs/plans/v0.10-request-flow.md` or
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
