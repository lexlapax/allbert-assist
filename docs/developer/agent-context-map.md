# Agent Context Map

This is the optional, lazy-loaded routing map for coding agents. Use it when a
task touches released behavior and the active plan plus ADRs are not enough.
Do not load every section by default.

## How To Use This File

- Start with `AGENTS.md`, `DEVELOPMENT.md`, the roadmap, the active plan, and
  relevant ADRs.
- Read only the subsystem section below that matches the task.
- Use `CHANGELOG.md` for shipped-history context and regression clues.
- Treat active plans, ADRs, code, and tests as more authoritative than
  historical release summaries.
- Do not add AI-tool attribution, co-author trailers, or generated-by footers
  to commits, PR text, release notes, changelog entries, or generated docs.

## Subsystem To Docs Map

| Area | Start With | History / Anchor |
| --- | --- | --- |
| Runtime, signals, agents, action runner | ADR 0001, ADR 0007, active plan | v0.01, v0.04, v0.06 |
| Security Central, permissions, trust, redaction, eval harness | ADR 0006, ADR 0007, ADR 0012, `docs/plans/v0.28-plan.md`, `docs/plans/v0.28-request-flow.md` | v0.05, v0.06, v0.11, v0.28 |
| Confirmations and approval resume | ADR 0008, active plan | v0.07 |
| Local execution, scripts, packages, external services | ADR 0009, ADR 0010, ADR 0011, ADR 0012, ADR 0013 | v0.08-v0.11 |
| Local identity, users, threads, conversation history | ADR 0014 | v0.12 |
| Scheduled jobs | ADR 0008, ADR 0012, ADR 0014 | v0.13 |
| Session scratchpad and active app context | ADR 0014 | v0.14 |
| App registration, surfaces, app-scoped routing | ADR 0015, `docs/plans/v0.27-plan.md`, `docs/plans/v0.28-plan.md` | v0.15, v0.18, v0.27, v0.28 |
| Channels and external identity mapping | ADR 0016 | v0.16 |
| Plugins and plugin-contributed apps/actions/skills/channels | ADR 0017 | v0.17 |
| Intent candidates, active app routing, classifier hooks | ADR 0019 | v0.19 |
| StockSage plugin app, domain, outcomes, reflections, reruns | ADR 0018, ADR 0017, ADR 0015, `docs/plans/v0.29-plan.md`, `docs/plans/v0.29-request-flow.md` | v0.20, v0.27, v0.29 |
| Markdown memory review, promotion, index, retrieval, app memory sync | ADR 0014, ADR 0019, `docs/plans/v0.21-plan.md`, `docs/plans/v0.29-plan.md` | v0.21, v0.29 |
| Jido.Agent vs GenServer substrate (pragmatic rule) | ADR 0007, vision "Jido.Agent vs GenServer", v0.23 plan | v0.23 |
| Objectives, steps, events, advisory providers, world models | ADR 0021, ADR 0019, v0.24 plan/request-flow, research note | v0.24 |
| StockSage Python bridge | `docs/plans/v0.22-plan.md`, ADR 0020 | v0.22 |
| StockSage native financial specialist agents (10 + coordinator) | `docs/plans/v0.25-plan.md`, `docs/plans/v0.25-request-flow.md`, ADR 0022 | v0.25 |
| StockSage LiveViews and app-flow UX | `docs/plans/v0.27-plan.md`, `docs/plans/v0.27-request-flow.md`, ADR 0015, ADR 0018 | v0.27 |
| StockSage security posture and adversarial evals | `docs/plans/v0.28-plan.md`, `docs/plans/v0.28-request-flow.md`, ADR 0015, ADR 0023 | v0.28 |
| StockSage app memory, outcomes, reflection sync, reruns | `docs/plans/v0.29-plan.md`, `docs/plans/v0.29-request-flow.md`, ADR 0015, ADR 0018, ADR 0022 | v0.29 |
| Workspace shell, canvas, ephemeral UI substrate | ADR 0015 (catalog), ADR 0023 (workspace substrate), `docs/plans/v0.26-plan.md`, `docs/plans/v0.26-request-flow.md` | v0.26 |
| StockSage canvas integration, workspace plugin contributions | `docs/plans/v0.30-plan.md`, `docs/plans/v0.30-request-flow.md`, ADR 0015, ADR 0023 | v0.30 |
| Runtime/UI-substrate consolidation, action DSL, settings fragments, unified catalog/registry | ADR 0026, ADR 0027, ADR 0028, ADR 0029, ADR 0030, ADR 0031, `docs/plans/v0.31-plan.md`, `docs/developer/runtime-boundary-map.md` | v0.31 |
| Workspace-only plugin UI, panel surfaces, named zones, workspace Settings Central | ADR 0024, ADR 0015, ADR 0023, `docs/plans/v0.32-plan.md` | v0.32 |
| Conversational app intent handoff, clarification, and direct answer | ADR 0034, ADR 0019, ADR 0021, `docs/plans/v0.33-plan.md` | v0.33 |
| Workspace UX refresh: chat-primary shell, view-only launcher, single-destination Canvas, conversational context indicator | ADR 0024 (v0.34 revision), `docs/plans/v0.34-plan.md`, `docs/plans/v0.34-request-flow.md` | v0.34 |
| User theming and layout overrides | ADR 0025, ADR 0024, `docs/plans/v0.35-plan.md`, `docs/plans/v0.35-request-flow.md` | v0.35 |
| Elixir/OTP sandbox and gate runner | ADR 0037, ADR 0009, `docs/plans/v0.36-plan.md`, `docs/plans/v0.36-request-flow.md`, `docs/developer/sandbox-gate-runner.md`, `docs/operator/sandbox-gate-runner.md` | v0.36 |
| Dynamic code & config generation, code-gen agents, bounded model-backed repair loop, v0.36 sandbox trial, gated live integration | ADR 0032, ADR 0033, ADR 0035, ADR 0037, ADR 0021, ADR 0027, `docs/plans/v0.37-plan.md`, `docs/plans/v0.37-request-flow.md`, `docs/research/codegen-agent-loop-research.md`, `docs/developer/dynamic-plugin-drafts.md`, `docs/operator/dynamic-capability-integration.md` | v0.37 |
| Templated creation: plugin/app/LLM-tool/scheduled-flow/code templates, Mix tasks, operator flows, Canvas Create surface | ADR 0036, ADR 0035, ADR 0037, ADR 0017, ADR 0015, `docs/plans/v0.38-plan.md`, `docs/plans/v0.38-request-flow.md` | v0.38 |
| First-run onboarding and provider control (two-branch doctor, `endpoint_kind` field, ADR 0047 doctor contract) | ADR 0004, ADR 0005, ADR 0014, ADR 0047, `docs/plans/v0.39-plan.md`, `docs/plans/v0.39-request-flow.md` | v0.39 |
| Identity slot (non-app system memory namespace + new `:identity` category) and deterministic direct-answer Active Memory retrieval | ADR 0015, ADR 0021, `docs/plans/v0.39b-plan.md`, `docs/plans/v0.39b-request-flow.md`, `docs/research/active-memory-retrieval.md`, `docs/operator/active-memory.md` | v0.39b |
| MCP client integration and trust tier (`:mcp_tool_call` / `:mcp_resource_read`, `mcp://` adapter, HTTP/SSE + stdio transports, doctor reuse) | ADR 0009, ADR 0011, ADR 0012, ADR 0013, ADR 0038, ADR 0047, `docs/plans/v0.40-plan.md`, `docs/plans/v0.40-request-flow.md` | v0.40 |
| Developer velocity, test strategy, precommit gate matrix, async eligibility, test-lane/resource isolation, implementation-readiness audits, milestone parallelization annotations, v0.45.1 commit/prepush/release gate semantics, and the temporary Memento/Jido compatibility override | ADR 0049, ADR 0050, `docs/plans/v0.41-plan.md`, `docs/plans/v0.41-request-flow.md`, `docs/plans/v0.45.1-plan.md`, `docs/plans/v0.45.1-request-flow.md`, `docs/developer/test-strategy.md`, `DEVELOPMENT.md` | v0.41 / v0.45.1 |
| Tool discovery: `find_tools` source port (local + internet MCP-registry adapters, optional keyed providers only when configured), persisted candidates/evaluations, `mcp_server_connect` confirmation gate, opt-in background scan to a passive surface | ADR 0048, ADR 0038, ADR 0011, ADR 0033, `docs/plans/v0.42-plan.md`, `docs/plans/v0.42-request-flow.md` | v0.42 |
| MCP-first integration pack 1: calendar/mail/GitHub MCP panels + notes/files native reference plugin | ADR 0015, ADR 0017, ADR 0039, `docs/plans/v0.42-plan.md`, `docs/plans/v0.42-request-flow.md` | v0.42 |
| Browser and web research: `./plugins/allbert.browser/` plugin with real local Playwright/Chromium control, `browser://session/<id>` identity, six browser operation classes, seven `:browser_*` permission classes, `browser.*` settings namespace, per-domain remembered grants on navigated URLs, two-layer network policy (top-level via `External.HttpPolicy` + subresources via `AllbertBrowser.NetworkPolicy`), bounded HTML/markdown/text/PDF extraction, credential-input screenshot redaction, ephemeral profiles, workspace results panel, doctor (ADR 0047 shape), v0.52 channel-primitive forward pin | ADR 0011, ADR 0012, ADR 0013 (v0.43 amendment), ADR 0017, ADR 0023, ADR 0025, ADR 0027, ADR 0033, ADR 0040 (binding), ADR 0047, ADR 0049, `docs/plans/v0.43-plan.md`, `docs/plans/v0.43-request-flow.md` | v0.43 |
| Plan/Build mode and operator workflow YAML: pinnable workspace panel surface over the v0.24 Objective Runtime, `workflow://<id>` and `plan://run/<objective_id>` identity (ADR 0013 v0.44 amendment), three `:workflow_*`/`:plan_*` permission classes, four operation classes plus `:plan_run` origin kind, `workflows.*` + `plan.*` core settings namespace (`schema_version: 1` per ADR 0046 draft; exposed through core fragments), v1 YAML schema assembled from the current `Actions.Registry.modules/0` snapshot + `Step.kinds()` with `additionalProperties: false` and closed-grammar `${...}` expression substitution (no `eval`, no `${secrets.x}`, no `${env.x}`, no dynamic action names), seven operator-facing Plan-Build actions (`list_workflows`, `inspect_workflow`, `expand_workflow`, `preview_plan`, `start_plan_run`, `cancel_plan_run`, `list_plan_runs`) plus internal `plan_step_confirm`, Plan Preview Contract packet (advisory-only per ADR 0021 §4), approved runs executed through the existing Objective Runtime, workspace Preview + RunProgress panels, subagent delegation inline rendering, confirmation upgrade-only rule, v0.52 channel-rendering forward pin | ADR 0011, ADR 0013 (v0.44 amendment), ADR 0017, ADR 0021, ADR 0023, ADR 0024, ADR 0027, ADR 0029, ADR 0030, ADR 0031, ADR 0041 (binding), ADR 0046 (drafted), ADR 0049, `docs/plans/v0.44-plan.md`, `docs/plans/v0.44-request-flow.md` | v0.44 / 0.44.0 |
| Marketplace lite (local reviewed catalog + Allbert-author seeds): shipped seed catalog under `priv/marketplace/`, SHA-256 recursive bundle verification, disabled/untrusted skill/template installs under configurable Allbert Home-rooted roots, browse-only plugin-index metadata, `marketplace://entry/<author>/<name>` identity, `:marketplace_install` permission class, marketplace operation classes, seven registered marketplace actions, eight CLI subcommands, Marketplace Catalog workspace panel + intent routing, ADR 0047-style marketplace doctor, `marketplace.*` settings fragment (`schema_version: 1` per ADR 0046 draft), master `marketplace.enabled` disable switch, workflow-YAML forward-pin enforcement | ADR 0013 (v0.45 amendment), ADR 0043, ADR 0046 (drafted), ADR 0047, ADR 0049, `docs/plans/v0.45-plan.md`, `docs/plans/v0.45-request-flow.md` | v0.45 / 0.45.0 |
| Delegation hardening and research specialist: implemented second native `AgentRegistry` consumer (`research.specialist`) contributed by `./plugins/allbert.research/`, orchestrating shipped v0.43 browser navigate/extract plus deterministic extractive fallback through `Actions.Runner.run/3`; zero new authority (no new permission/operation-class/URI/action), only a `research.*` settings fragment (`schema_version: 1`); threads the delegate step command into the `delegate_agent` action (replacing the hard-coded `execute` in `Objectives.Commands.execute/4`) and hardens allowlisted command validation (string or atom) against agent metadata at that boundary - no Step-schema migration (ADR 0021 A3); advisory report packets (ADR 0021 §4); composed via v0.44 `kind: delegate_agent` step with inline subagent-delegation rendering; `mix allbert.research` and inert research intent descriptors route research phrases to the delegate; `docs/developer/delegate-agents.md` documents the extension point; nine v0.46 security eval rows and `release.v046` prove the delegate contract against two domains before the v1.0 freeze | ADR 0017, ADR 0021 (amendment A21), ADR 0022, ADR 0029, ADR 0031, ADR 0040 (binding), ADR 0041, ADR 0046 (drafted), ADR 0049, `docs/plans/v0.46-plan.md`, `docs/plans/v0.46-request-flow.md`, `docs/operator/research-specialist.md` | v0.46 / 0.46.0 |
| Operator-supervised self-improvement (discovery + local drafts): read-only `SelfImprovement.TraceIndex` over `<ALLBERT_HOME>/memory/traces/` (inherits trace redaction); generalized v0.42 `Tools.Discovery.Suggestion` + `Workspace.DiscoverySuggestions` panel (self-improvement suggestion types); read-only `discover_patterns` action (mirrors `find_tools`); one unified reviewed-draft store generalized from v0.37 `DynamicPlugins.Draft` holding skill/workflow/memory drafts; reviewed memory/workflow draft facades; `self_improvement.*` settings fragment (`schema_version: 1`); seven `:v047` eval rows + `release.v047`; no new authority, promotion via existing confirmed paths | ADR 0045 (amendments A1-A4), ADR 0032 (v0.47 amendment), ADR 0048 (v0.47 amendment), ADR 0041 (workflow drafts reconciliation), ADR 0031, ADR 0049, `docs/plans/v0.47-plan.md`, `docs/plans/v0.47-request-flow.md` | v0.47 |
| Operator-supervised self-improvement (handoff drafts): template-backed (v0.38 `Templates.Registry`/`create_from_template`), marketplace-backed (v0.45 `Marketplace.list_entries/1`, descriptive only), inert delegate-plugin draft requests (v0.46 contract), capability-gap (v0.37 `DynamicPlugins.request_draft` to v0.36 `Sandbox.run_gate` to `Loader.integrate`), and objective drafts in the v0.47 unified store; code-bearing drafts reach live authority only via the existing sandbox/gate/loader path + confirmation; seven `:v047b` eval rows + `release.v047b`; no new trust tier | ADR 0045 (amendments A5-A7), ADR 0033, ADR 0035, ADR 0036, ADR 0037, ADR 0043, `docs/plans/v0.47b-plan.md`, `docs/plans/v0.47b-request-flow.md` | v0.47b / 0.47.1 |
| Provider capabilities, operator model preferences, voice, vision, and media resources | ADR 0011, ADR 0051, ADR 0042, ADR 0047, ADR 0052, `docs/plans/v0.48-plan.md`, `docs/plans/v0.48-request-flow.md`, `docs/developer/provider-capabilities.md`, `docs/operator/voice-and-provider-preferences.md`, `docs/operator/vision-and-image-generation.md`, `docs/developer/vision-and-image-generation.md`, `docs/plans/v0.49-plan.md`, `docs/plans/v0.49-request-flow.md` | v0.48-v0.49; v0.48 implements bounded STT/TTS and the Allbert-owned local voice runtime, while v0.49 implements bounded vision input, workspace image upload, and provider-backed image generation; richer realtime audio/video profile metadata remains routing/future scope |
| Content-addressable artifact store (Artifacts Central; implemented as `0.50.0`): `artifact://sha256/<hex>` identity over an `<ALLBERT_HOME>/artifacts` object store (thin CAS on `:crypto` SHA-256 + sharded objects + atomic writes, no third-party store); type-agnostic durable artifacts uploaded by the operator, created by Allbert, or found via approved tools; provenance/MIME/byte/hash/retention metadata index with bytes never in traces; `artifact_read`/`artifact_write`/`artifact_delete` permissions + operation classes; `artifacts.*` settings fragment (`schema_version: 1`); `put_artifact`/`get_artifact`/`list_artifacts`/`delete_artifact`/`artifact_doctor` actions plus the first supervised Jido ingestion sensor (`IngestionSensor` under `Jido.Sensor.Runtime`, explicit `IngestionConsumer` dispatch target, redacted `allbert.artifact.ingest_requested` signals, writes only through `put_artifact`); an `artifact_thread_links` SQLite join table (role created_by/referenced_by) linking artifacts to the threads/messages that created them, from `context.request`, with by-thread + reverse query and idempotent deterministic link ids; backfills retained v0.48 audio, v0.49 vision-input, and v0.49 generated-image roots from existing retention-root settings while leaving ephemeral scratch and historical Browser cache outside M5; adds `:v050` artifact-store eval rows + `release.v050`; content-addressed identity, thread links, and sensor signals never grant permission | ADR 0053, ADR 0054 (provenance + browser-surface split), ADR 0042 (artifact amendment), ADR 0031, ADR 0046, `docs/plans/v0.50-plan.md`, `docs/plans/v0.50-request-flow.md`, `docs/operator/artifacts-central.md`, `docs/developer/artifact-store.md` | v0.50 / 0.50.0 |
| Artifacts Browser (released as `v0.50.1`): operator browsing repository for Artifacts Central as a plugin/app (`plugins/allbert.artifacts/`, plugin id `allbert.artifacts`, modeled on StockSage + `allbert.browser`); M1 has shipped the workspace `:canvas_panels` panel via `App`/`SurfaceProvider` + `workspace_panel_surfaces/1`; M2 has shipped the `/apps/artifacts/<sha>` page LiveView route (core router, plugin-owned module, sha validated before store reads, Chrome-validated metadata/provenance rendering and delete confirmation request); M3 has shipped `mix allbert.artifacts list|show|threads|doctor|rm` as a thin CLI over core actions; M4 has shipped panel + CLI filters by type, origin, thread, since date, retention, lifecycle, and limit without a new index; M5 has shipped `:v050b` artifact-browser eval rows, `release.v050b`, deterministic browser-validation fixture seeding, and operator/developer guides; reads the store only through core `:artifact_read` actions (list incl. by-thread, get, `artifact_threads`, doctor) and deletes via the core confirmation-gated action; renders redacted metadata only; grants no authority | ADR 0054, ADR 0015 (app/surface DSL), ADR 0017 (plugin contract), ADR 0024 (UI zones/page routes), `docs/plans/v0.50b-plan.md`, `docs/plans/v0.50b-request-flow.md`, `docs/operator/artifacts-browser.md`, `docs/developer/artifacts-browser.md` | v0.50b / 0.50.1 |
| Public Protocol Surfaces (implemented as `0.51.0`): registered actions as MCP tools; app memory namespaces as MCP resources; OpenAI-compatible HTTP API; ACP server; AG-UI/A2UI parked. Inbound trust tier (ADR 0055): `:public_surface_call_inbound` permission (floor `:needs_confirmation`), per-client Settings-Central tokens, net-new inbound rate-limiter, API secure-header posture, and a poll-by-id result-readback action (`:agent`-exposable, client-scoped, never before approval). v0.51 is a text-first protocol subset: OpenAI/ACP image, audio, resource, filesystem-root, artifacts, and client-supplied MCP-server payloads do not grant media/filesystem/MCP/artifact authority; artifacts are not MCP resources unless a future adapter routes through Artifacts Central + `:artifact_read`. Release lane: `mix allbert.test release.v051`. | ADR 0044 (exposure), ADR 0055 (inbound trust), ADR 0038 (symmetric outbound tier), `docs/plans/v0.51-plan.md`, `docs/plans/v0.51-request-flow.md`, `docs/developer/public-protocol-surfaces.md`, `docs/operator/public-protocol-surfaces.md` | v0.51 / 0.51.0 |
| Discord and Slack channel plugins + ADR 0016 amendment for channel approval primitives, **plus a system-wide cross-channel conversation-thread construct (ADR 0057)**. Implemented as `0.52.0` across nine milestones (M0-M8), substrate-first, one version. Inbound trust tier (ADR 0056): new `:channel_message_inbound` permission class (floor `:needs_confirmation`, registered at every Security.Policy/Risk/Settings.Schema spot, cannot be lowered below floor), per-interaction clicker re-authorization, ack-before-runtime dedupe. **Threading (ADR 0057):** canonical thread id = existing `conversation_threads.id`; `thread_channel_refs` + `conversation_message_refs` + `cross_channel_identity_links` with `owner_scope`, `receiver_account_ref`, deterministic `provider_thread_key`, `direction` echo-suppression, and `part_id`; `Conversations.ChannelThread`; per-adapter `threading:` descriptor (`:native_threads`/`:reply_chain`/`:flat`/`:rich`) + degradation ladder; `channel_events.thread_id` canonical-only; unified read-only history view; explicit `resume_thread_on_channel` (same user_id + explicit link when identities differ); explicit never-auto-merged cross-channel identity links; Telegram/email/web/CLI retrofitted (M6, byte-equivalent). v0.52 uses `owner_scope: "local"` only so post-1.0 multi-tenant work does not require a second canonical thread id. Transport vehicle locked by an M0 spike (raw Req + reviewed WS client vs Nostrum/slack_elixir; ADR 0050); Discord free-text on @mention+DM via privileged MESSAGE_CONTENT intent; Slack Socket Mode. Release lane: `mix allbert.test release.v052`; required pre-tag provider smoke: `mix allbert.test external-smoke -- discord_slack` plus manual live inbound/callback checks. | ADR 0016, ADR 0017, ADR 0056 (inbound trust), ADR 0057 (cross-channel threading), ADR 0050 (dependency compat), `docs/plans/v0.52-plan.md`, `docs/plans/v0.52-request-flow.md`, `docs/operator/discord-channel.md`, `docs/operator/slack-channel.md`, `docs/developer/channel-approval-primitives.md`, `docs/developer/cross-channel-threading.md` | v0.52 / 0.52.0 |
| **Channel Pack 1 retro-validation (Telegram + email) + Channel Pack 2: Matrix + WhatsApp (Cloud API) + Signal (signal-cli daemon)**; validation complete and release-ready for `0.53.0` through M11. Telegram + email delivery/inbound live smokes and manual approval/rejection/poll-resume checks passed after the v0.54 router prerequisite landed. Matrix delivery/inbound smokes plus mapped approval and unmapped callback rejection passed after the Matrix sync/catch-up remediations, with release-owner acceptance of the encrypted-room exclusion for this pass. Discord/Slack remain v0.52-released channels and passed v0.53 M11 delivery/inbound regression after shared-channel changes. WhatsApp Cloud API is implemented but not released for live use after Meta setup/object/registration failures; its signed-webhook auth path remains covered locally and by evals. Signal is implemented as a `signal-cli` bridge, but not released for live use because it requires operator-managed daemon/linked-device onboarding. ADR 0066 defines the capability release gate: undeclared capabilities default released; explicit `live_use_allowed: false` fails closed; v0.53 stores the WhatsApp/Signal decisions as plugin-owned YAML release declarations. `:list` remains the mandatory fallback primitive. Matrix scope stays unencrypted rooms only, and Matrix/WhatsApp typed approval commands are adapter-handled callback events rather than runtime text. | ADR 0016, ADR 0017, ADR 0056 (v0.53 amendment), ADR 0057, ADR 0058, ADR 0059, ADR 0066, ADR 0050, `docs/plans/v0.53-plan.md`, `docs/plans/v0.53-request-flow.md` | v0.53 / 0.53.0 |
| Intent deepening for chat-primary routing, implemented as `0.54.0`: ADR 0060 two-stage local router; ADR 0061 local embedding/router tiers; ADR 0062 descriptor lifecycle **foundation** (dual-source descriptors, layered data-only YAML resolver/store, heuristic generation, CLI curation, dynamic-codegen reindex); ADR 0063 outbound compose actions for email/channel/calendar; ADR 0064 slot/param seam hardening. Matrix generic outbound degrades and is deferred to v0.55 M1. Local-model descriptor generation, learned-review proposal-mining infrastructure, `optimize_intent_descriptors`, and app/plugin/action registration signals move to v0.56. Full typed action param contracts move to v0.59 M7 / ADR 0065. | ADR 0060, ADR 0061, ADR 0062, ADR 0063, ADR 0064, ADR 0019, ADR 0034, ADR 0016/0056/0059, `docs/plans/v0.54-plan.md`, `docs/plans/v0.54-request-flow.md` | v0.54 / 0.54.0 |
| Channel parity matrix + proper TUI/terminal channel under the ADR 0016 contract and ADR 0057 `threading: :rich` substrate, shipped as `0.55.0`: list-shaped channel identity map, a basic supervised `mix allbert.tui` launcher, prompt-stable scrollback rendering, and warm TUI validation accepted on 2026-06-22. Harvests Pi's split tool-result pattern as `model_payload` vs. `surface_payload` (ADR 0067 extending ADR 0029/0030) as the foundation for the v0.57 Pi-mode coding surface; v0.55 lands the split/live-region substrate, not true streamed diff/token semantics. M1 also closes the v0.54-deferred Matrix generic outbound implementation behind `Channels.Outbound`; live Matrix provider smoke is blocked by inactive credentials, not by code. | ADR 0016, ADR 0067, ADR 0057, ADR 0029, ADR 0030, `docs/plans/v0.55-plan.md`, `docs/plans/v0.55-request-flow.md` | v0.55 / 0.55.0 |
| TUI Operator/Validation Console (point release), released as `0.55.1`: the v0.55 TUI becomes the persistent, mix-free operator/validation console — in-TUI slash-commands (`/status`, `/confirmations`, `/events`, `/channels`, `/settings get`, `/help`) + `mix allbert.channels status`, backed by registered **read-only internal** inspection actions, reachable only through the slash-command allowlist or explicit Mix task twin, not intent candidates or tool-discovery suggestions, through `Actions.Runner.run/3`; migrates operator validation onto one warm BEAM with release evidence verified during closeout. | ADR 0070, ADR 0067, ADR 0016, `docs/plans/v0.55b-plan.md`, `docs/plans/v0.55b-request-flow.md` | v0.55.1 / 0.55.1 |
| Intent Descriptor Learning + Registration Lifecycle Completion + Routing-Accuracy Gate + Model Recommendations, released and tagged as `v0.56.0` on 2026-06-23: completes ADR 0062 (local-model descriptor generation, learned-review proposal-mining infrastructure, operator-callable `optimize_intent_descriptors`, full app/plugin/action registration reindex signals); adds the ADR 0071 deterministic routing-accuracy evaluation harness (data-only YAML corpus + scorer + **blocking** promotion/release gate: no-regression vs ratcheted release baseline + ratcheting floor + zero negative-route violations) and full current descriptor coverage (`57/57` at closeout); adds ADR 0072 per-purpose model recommendations (`docs/operator/model-recommendations.md` + recommended Settings Central defaults + `mix allbert.intent doctor` / `mix allbert.settings model-doctor` coverage, aligned to current public Ollama defaults such as `gemma4:26b` escalation). Third-pass adds the **Operator Action Layer**: every intent/eval/model operation (incl. the shipped v0.54 CLI) is a registered Jido action through `Actions.Runner.run/3` (reads `:internal`/`:read_only`; mutations callable only from explicit operator surfaces/tasks + gated), so CLI/TUI/web operator surfaces are thin views (extends ADR 0070). M14 warm-TUI validation passed; M14b post-audit hardening tightened strict negative-route semantics, data-only bench fixture loading, Settings Central scoring knobs, package-owned descriptor slot tests, and the 254-case `v056-release-baseline`; M15 accepted ADR 0071/0072 and bumped metadata to `0.56.0`. Gate thresholds 0.85 overall / 0.80 per-domain; corpus capture→add→commit to a committed fixture; all settings via Settings Central, security via Security Central. | ADR 0062, ADR 0071, ADR 0072, ADR 0070, ADR 0060, ADR 0061, `docs/plans/v0.56-plan.md`, `docs/plans/v0.56-request-flow.md`, `docs/operator/model-recommendations.md` | v0.56 / 0.56.0 |
| Pi-mode coding surface: a gated terminal coding surface (four boundary actions read/write/edit/bash through `Actions.Runner.run/3`, sub-1000-token prompt, streamed split-payload diffs, full-file context) on the one authority spine, plus a named local-coding/sandbox-level-0 trust tier (extends ADR 0009) — never YOLO-default, never for channel-originated or generated-code sessions; deterministic acceptance and Security Central stay intact. Builds on the v0.55 TUI channel, v0.55.1 persistent console, and split tool-result payload. | ADR 0068, ADR 0067, ADR 0009, ADR 0016, `docs/plans/v0.57-plan.md`, `docs/plans/v0.57-request-flow.md`, `docs/archives/pi-integration-rethink.md` | v0.57 |
| Web UX redo + surface policy: chat-primary `/workspace`, ephemeral -> popups, canvas demoted, "Conversations" relabel, plus the Intents web panel over the v0.54/v0.56 descriptor YAML lifecycle (override files are `.yaml`), Settings/Models panel over v0.56 DTOs (`model_doctor`, `list_model_profiles`, `list_provider_profiles`), and operator-managed surface policy for raw-vs-summary report shape, redaction/display mode, row/count bounds, and explicit operator affordances. Surface policy is presentation governance, not descriptor vocabulary or Security Central authority. Surface substrate kept. | ADR 0023, ADR 0024, ADR 0015, ADR 0062, `docs/plans/v0.58-plan.md`, `docs/plans/v0.58-request-flow.md` | v0.58 |
| Release candidate hardening, export/import, settings schema migration, operator onboarding simplification (ADR 0069, via the v0.55.1 TUI console), ADR 0065 central param contracts, and 1.0 tiered contract freeze | ADR 0046, ADR 0065, ADR 0069, `docs/plans/v0.59-plan.md`, `docs/plans/v0.59-request-flow.md`, `docs/plans/v1.0-plan.md`, `docs/plans/v1.0-request-flow.md` | v0.59-v1.0 |

## v0.41 Test Lane Classification

Use this section when adding, moving, or auditing tests. The authoritative
contract remains `docs/developer/test-strategy.md`; this map gives agents enough
detail to classify new work without reading the full strategy first.

Each test file has exactly one primary lane. Pick the lane by the strongest
shared resource the file touches, not by the fastest command you hope to run.
If two resources apply, choose the more conservative lane and leave a note in
the active plan when a later split could safely narrow it.

Lane meanings:

- `pure_async`: pure functions, render helpers, parsing, deterministic
  transformations, and static assertions that do not mutate process-global
  state, repo state, Allbert Home, app env, or external runtimes. These are the
  only tests in the quick default `mix allbert.test fast-local` lane.
- `db_serial`: uses Repo, Ecto sandbox, Mnesia/Memento state, persisted
  objective/session/trace/memory rows, or migrations. These tests are serial
  inside a VM and may run across OS partitions with separate `DATABASE_PATH` and
  `ALLBERT_HOME`.
- `db_partition_safe`: reserved for database-backed tests that have an explicit
  per-partition database/home ownership proof and no stronger app-env,
  filesystem, process, LiveView, security, or external-runtime coupling. Most
  `DataCase` tests should stay `db_serial` unless a plan proves this narrower
  lane is useful.
- `app_env_serial`: mutates `Application` env, Settings Central process config,
  feature flags, provider config, or any global setting whose value could leak
  across tests in the same VM.
- `home_fs_serial`: reads/writes Allbert Home, skill/plugin/template roots,
  scratch files, sandbox roots, memory files, generated drafts, or filesystem
  fixtures whose path ownership matters.
- `global_process_serial`: starts/stops or depends on named processes,
  registries, supervisors, ETS tables, PubSub topics, Jido agents, schedulers,
  or singleton runtime components.
- `liveview_serial`: uses `AllbertAssistWeb.ConnCase`, Phoenix LiveView,
  ConnTest with endpoint/router state, or browser-like UI process trees. It
  runs serial inside a VM and partitions across OS processes through
  `mix allbert.test fast-local --web-lanes --partitions N`.
- `security_eval_serial`: uses `AllbertAssist.SecurityEvalCase`, adversarial
  fixtures, redaction/security boundary assertions, or eval inventories. Keep it
  serial/release unless a dedicated ADR/plan changes the eval isolation model.
- `external_runtime_serial`: touches Docker, OS ports, stdio bridge processes,
  browser drivers, provider endpoints, package managers, real MCP servers, or
  other shared machine resources. These are release/external-smoke lanes until a
  plan documents per-partition port/path/process ownership.

Case-template defaults:

- `AllbertAssist.DataCase` defaults to `db_serial`.
- `AllbertAssistWeb.ConnCase` defaults to `liveview_serial`.
- `AllbertAssist.SecurityEvalCase` defaults to `security_eval_serial`.
- `StockSage.DataCase` defaults to `db_serial`.
- Plain `ExUnit.Case` files must carry an explicit primary lane tag such as
  `@moduletag :pure_async` or `@moduletag :app_env_serial`.
- Template users may pass a narrower explicit lane only when the active plan or
  nearby test evidence proves the narrower resource class is correct, for
  example `use AllbertAssistWeb.ConnCase, lane: :external_runtime_serial` for a
  web file that drives runtime/external behaviors.

Classification workflow:

1. Read the test file and setup helpers before tagging. Look for Repo calls,
   `Application.put_env`, Settings changes, Allbert Home paths, temporary files,
   named processes, LiveView/ConnTest helpers, ports, Docker, provider calls,
   bridge processes, and security eval fixtures.
2. Choose exactly one primary lane, using the strongest shared resource.
   `external_runtime_serial` outranks LiveView/DB/app-env, and
   `security_eval_serial` stays its own lane even if it also touches DB.
3. Prefer splitting a mixed file into narrower files only when the split is
   small and useful. Do not retag runtime-heavy tests as fast-local just to make
   the benchmark look better.
4. Run
   `mix allbert.test inventory --check-tags --output docs/developer/v0.41-test-inventory.csv`
   after changing lane tags or templates. The inventory gate must report zero
   unclassified files and zero double-counts.
5. Pick the validation gate from the lane: quick pure changes use
   `mix allbert.test fast-local`; core serial lanes can use
   `mix allbert.test serial-core --lane <lane> --partitions N`; StockSage/web
   partitioned local gates use the high-coverage fast-local flags; release
   evidence uses `mix allbert.test release`.
6. For implementation milestones, record benchmark evidence before work, after
   each milestone, and at closeout. If the measured efficiency does not improve
   enough for the milestone's planned share, reorder the remaining work toward
   the measured long pole.

Implemented v0.41 gates:

- Quick daily gate:
  `mix allbert.test fast-local`
- High-coverage local gate:
  `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions N`
- Core serial lane gate:
  `mix allbert.test serial-core --lane <lane> --partitions N`
- Release handoff:
  `mix allbert.test release`

## Version Map

- v0.01: first local assistant loop, signals, direct answer, markdown memory,
  traces, CLI and LiveView entrypoints.
- v0.03: Agent Skill compatibility/importability substrate.
- v0.04: runtime convergence and boundary actions.
- v0.05: Security Central vocabulary and enforcement baseline.
- v0.06: action-backed skill execution through registered actions.
- v0.07: durable confirmation workflow.
- v0.08: Level 1 local shell execution policy.
- v0.09: trusted skill script runner with resource gates.
- v0.10: confirmed external capability adapters, package installs, online
  skill search/import.
- v0.11: execution-aware intent, Approval Handoff, Resource Access Security
  Posture.
- v0.12: local workspace identity and SQLite conversation history.
- v0.13: scheduled jobs and supervised scheduler.
- v0.14: volatile session scratchpad and active app context.
- v0.15: minimal app registration contract.
- v0.16: Telegram/email channel substrate and explicit external identity
  mapping.
- v0.17: plugin contract and shipped source-tree channel plugins.
- v0.18: full app contract and validated surface DSL.
- v0.19: cross-surface intent candidates and active app ranking.
- v0.20: StockSage plugin app, local domain, import, actions, and skills.
- v0.21: memory review, correction, pruning, promotion, index, search, and
  memory intent candidates.
- v0.22: StockSage Python bridge and `RunAnalysis` confirmation flow. Released
  and tagged after audit closeout and post-implementation gap fixes.
- v0.23: Jido State-Machine Convergence for Confirmations.Store and
  Jobs.Scheduler using `AllbertAssist.JidoBacked`.
- v0.24: Objective Runtime Foundation: durable objectives,
  objective steps/events, canonical runtime turn signal aliases,
  objective signals, SignalBridge, and objective intent candidates.
- v0.25: Native financial specialist agents for StockSage: 9 reusable
  supervised LLM-capable `Jido.Agent` delegate specialists whose execute
  command calls Jido.AI (analysts, bull/bear theses, 3 risk debaters,
  decision synthesizer) + 1 deterministic Jido.Agent quality gate + 1 JidoBacked
  `StockSage.Agents.NativeCoordinator` orchestrator. Multi-round
  bull/bear/risk debate runs inside the plugin-owned coordinator graph
  while recording durable v0.24 objective steps. 5 tiered evidence actions
  (`StockSage.Actions.Evidence.*`) with new `:stocksage_evidence_fetch`
  permission class. `--engine both` parallel parity runs with 5-point
  rating-scale agreement metric. Per-agent model profiles drive Jido.AI
  generation when `stocksage.native_llm_enabled` is true. Prompt files are
  Allbert-authored; verbatim TradingAgents prompt adaptation is deferred
  until an explicit license audit. New `mix allbert.delegate
  <agent_id>` Mix task in Allbert core proves cross-app callability.
  No one-for-one Python graph clone. No automatic native → Python
  fallback, and no persistent Python/parity engine default.
- v0.26: Agentic Workspace Surface And Ephemeral UI Substrate (implemented
  2026-05-18; release tag pending operator acceptance). The
  `/agent` LiveView becomes a fully-dynamic workspace shell rendered
  by walking a Surface tree composed of regions, tiles, and
  ephemeral surfaces. Per-thread Canvas (persistent tiles bound to
  v0.12 thread; survives refresh + restart) and per-thread Ephemeral
  Surfaces (task-scoped overlays, shared across tabs of same thread,
  GC'd on thread close). Hybrid SQLite-metadata + YAML-body
  persistence. Catalog expands from 12 → 42 components (10 workspace
  structural + 12 Allbert-domain + 4 Allbert-app cards + 4 reserved
  StockSage cards rendered as stubs + 12 v0.18 carryover). Strict +
  HMAC-signed `FragmentEnvelope` emission via
  `allbert.workspace.fragment.**` SignalBus topic; receiver
  validates envelope shape, signature, catalog component, emitter
  allow-list, per-emitter rate limit, payload size. Multi-tab sync
  via PubSub. WCAG 2.1 AA accessibility (keyboard nav + ARIA + focus
  traps + skip-to-content). Dark mode + theme toggle. Mobile
  responsive (two-pane above 768px, single-pane with tab toggle
  below). Offline text/markdown tile editing via service worker +
  browser-side Yjs + IndexedDB with bounded reconnect sync +
  conflict banner UX.
  Internal `AllbertAssist.Workspace.AGUI.Bridge` translates curated
  Allbert signals to AG-UI event shape for test-only semantic
  mapping (NOT exposed over HTTP). 14 new `workspace.*` settings.
  New `:workspace_canvas_write` permission class. 9 new
  `allbert.workspace.**` signal topics. `## Workspace` trace
  section + inline `### Workspace` subsection. `mix
  allbert.workspace canvas|ephemeral|inspect|rotate-signing-secret`
  Mix tasks. Per ADR 0023.
- v0.27: App Surface Contract - StockSage LiveViews. Historically introduced
  plugin-owned `StockSageWeb.WorkspaceLive`, `AnalysisLive`, `QueueLive`, and
  `TrendsLive` mounted by the host router at `/stocksage/*` and declared
  through `StockSage.App.surfaces/0`. v0.32 removes the dashboard/list/queue/
  trend routes in favor of `/workspace` panels, retaining only
  `StockSageWeb.AnalysisLive` at `/apps/stocksage/analyses/:id`. StockSage
  still ships real renderers for `:analysis_card`, `:agent_report_card`,
  `:parity_card`, and `:debate_round_card`, `RunAnalysis` validated
  `surface_nodes`, objective and confirmation state on analysis pages, PubSub
  progress streaming, and the app memory namespace declaration.
- v0.28: Security Hardening And Evals. This is the security routing anchor
  after v0.26 workspace surfaces and v0.27 real StockSage app surfaces. It
  adds the shared security eval harness under `apps/allbert_assist/test/security`,
  adversarial fixtures, Resource Access trace assertions, app-scoped action
  routing coverage, disabled-plugin and registry-boundary coverage, surface
  catalog injection coverage, workspace fragment/canvas substrate coverage,
  objective and advisory-provider coverage, bridge/native StockSage coverage,
  namespace claim/isolation coverage before memory writes, and operator-facing
  security review/status tasks. Pre-tag hardening makes app-owned actions fail
  closed when `active_app` is missing, neutral, or wrong; jobs and objective
  execution propagate explicit active-app context instead of relying on
  `app_id` as authority.
- v0.29: App Memory + Outcomes Contract - StockSage Polish. StockSage now has
  outcome resolution through registered actions, due-outcome resolution,
  trend/calibration summaries, deterministic local reflection generation,
  explicit confirmation-gated lesson sync, app-memory metadata on
  `Memory.Entry`, idempotent namespaced memory upsert behind
  `sync_app_lesson`, no-auto-promotion tests, source-analysis-aware reruns,
  and polished app-flow UX for run context, empty/error states, and mobile-safe
  StockSage surfaces. v0.29 consumes the namespace declared in v0.27 and
  audited in v0.28; it still does not emit durable `/agent` canvas tiles.
- v0.30: App Canvas Contract - StockSage Canvas Integration. Released and
  tagged as `v0.30.0` after operator manual verification. `/agent` now
  renders durable StockSage canvas tiles with the v0.27
  `StockSageWeb.Components.Cards` renderers instead of v0.26 stubs.
  `RunAnalysis` lifecycle signals flow through
  `AllbertAssist.Workspace.Emitters.stocksage_signal/2`, signed
  `Workspace.Fragment.Envelope` validation, and the existing
  `workspace_canvas_tiles` + YAML body store. v0.30 adds no `:stock_chart`
  atom, no migration, no new StockSage domain behavior, and no private
  canvas-write path.
- v0.31 (implemented; pending operator manual verification): Runtime And
  UI-Substrate Consolidation. Consolidates the
  action DSL, typed runtime responses, shared paths/redaction/audit/persistence
  facades, unified Surface catalog/renderer path, unified extension registry,
  and settings fragments. Behavior-preserving: no route removals, theming,
  dynamic code, generator, domain behavior, or migrations. M3 adds
  `AllbertAssist.Runtime.Paths` and `AllbertAssist.Runtime.Redactor`; M4 adds
  `AllbertAssist.Runtime.Audit`, `AllbertAssist.Runtime.Persistence`, and
  `AllbertAssist.Runtime.Trace`; M5 adds `AllbertAssist.Action` and
  module-owned capability metadata for registered actions; M6 adds
  `AllbertAssist.Runtime.Response` for shared Runtime/Runner/objective response
  normalization; M7 adds `AllbertAssist.Surface.Catalog`,
  `AllbertAssistWeb.Surface.Renderer`, and `AllbertAssist.Extensions.Registry`
  while retiring the StockSage-only renderer/adapters; M8 adds
  `AllbertAssist.Settings.Fragment` and `AllbertAssist.Settings.Fragments` so
  Settings Central schema/default/safe-write assembly comes from registered
  core/app/plugin fragments. `PermissionGate` remains a compatibility shim over
  Security Central pending a later caller-migration parity pass. Per ADR
  0026-0031.
- v0.32 (released): Workspace-Only
  App UI And Settings Central. Makes
  `/workspace` the operator home; removes `/agent`, `/settings`, and
  `/stocksage/*` without compatibility redirects; adds `:panel` surfaces into
  host-owned zones (`:nav_apps`, `:context_rail`, `:canvas_panels`,
  `:utility_drawer`, `:ephemeral`); moves Settings Central into the workspace
  utility drawer; moves StockSage dashboard/recent/queue/trends into workspace
  panels; migrates CoreApp domain cards to the same panel-zone path; and keeps
  StockSage analysis detail as `/apps/stocksage/analyses/:id`. Per ADR 0024.
  No new domain behavior, theming system, neutral app-intent inference, or
  model-generated UI.
- v0.33 (released): Conversational App Intent Handoff And Direct Answer
  Foundation. Replaces the static direct-answer fallback with a real
  side-effect-free answer path, adds app-contributed intent descriptors,
  proposes explicit app handoff from neutral workspace context, asks targeted
  clarification when slots are missing or candidates are close, uses the
  classifier only as advisory selection over collected candidates, and
  preserves app-scope denial until a handoff is accepted. v0.33.1 adds
  optional descriptor slots, descriptorizes StockSage `get_trends` and
  `queue_analysis`, and removes the remaining core StockSage symbol parser.
  Per ADR 0034.
- v0.34 (released): Workspace UX Refresh. Revises the v0.32 shell into a
  chat-primary layout with a view-only launcher, single-destination Canvas,
  Output as the durable-tile destination, Settings/tools as Canvas
  destinations, and a passive top-bar context indicator. Launcher selection and
  URL destination state are view-only; `active_app` is set only by accepting a
  v0.33 handoff, and legacy `?app_id=` / app-launcher setters are retired as
  routing authority. Released and tagged as `v0.34.0` on 2026-05-24. Per ADR
  0024's v0.34 revision.
- v0.35 (implemented as `v0.35.0`): User Theming And Layout Overrides. Adds
  Allbert Home theme roots, token YAML, opt-in sanitized CSS snippets, validated
  v0.34 launcher/Canvas-destination layout YAML, Settings Central-accountable
  gates and selections, and CSP regression coverage for `/workspace`. Start
  with ADR 0025 plus `docs/plans/v0.35-plan.md` /
  `docs/plans/v0.35-request-flow.md`, and carry forward v0.34 constraints:
  Output is the neutral destination, `app:allbert` is not a layout destination,
  launcher/layout state is view-only, AppBar is fixed chrome, Settings/Output
  are non-hideable, and `active_app` remains handoff-only.
- v0.36 (implemented as `v0.36.0`): Elixir/OTP Sandbox And Gate Runner. Adds the default-off,
  OS-aware sandbox facade (static reviewed backend registry + `"auto"` resolver:
  optional doctor-gated Apple `container`, rootless Podman, Docker+runsc/gVisor
  preferred over plain Docker, Docker fallback), approved local images only
  with dependency cache/source, compiled deps, and Dialyzer PLT state prepared
  by image setup when available, runtime dependency/build/cache paths and test
  DB roots seeded by a fixed image-owned runner, facade-level source-policy
  checks, copy-in/copy-out bundles that include root warning-gate config,
  explicit reviewed `mix` gate commands, bounded reports and sandbox audit
  records, and fail-closed denial of
  network, secrets, real Allbert Home, package-manager execution, NIFs, ports,
  shell strings, and untrusted core loading. Per ADR 0037 and ADR 0009.
- v0.37 (released as `v0.37.5`): Dynamic Code & Config Generation And Live
  Capability Integration. Adds file-backed dynamic draft metadata under
  `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/`, an explicit source-bearing
  read-only/delegated action generator for capability gaps, v0.36 sandbox
  trial/gate handoff, trusted validation, and hot-load registration for
  gate-passed action artifacts only after operator confirmation. The generator
  uses bounded Planner/Author/TrialAuthor/Critic/Repair packets. Rollback also
  requires confirmation and removes live authority; module purge is
  best-effort/audited.
  Per ADR 0032, ADR 0033, and ADR 0035. Implementation docs live in
  `docs/developer/dynamic-plugin-drafts.md` and
  `docs/operator/dynamic-capability-integration.md`.
- v0.38 (implemented as `v0.38.0`): Templated Creation. Scaffolds the proven
  plugin/app/tool/flow shapes through Mix tasks (`--target` defaults to
  `./plugins/<name>` and existing roots require `--force` plus preview/diff)
  and a `workspace:create` Canvas destination, reusing the v0.36 sandbox and
  v0.37 loader for optional live integration. Live integration is shipped only
  for the LLM-tool/action pattern; other patterns are inert developer
  scaffolds.
- v0.39 (implemented as `0.39.0`; ready for operator manual validation):
  First-Run Onboarding And Provider Control. Adds guided setup, a
  `providers.*.endpoint_kind` field, a two-branch provider doctor
  (credentialed-remote + local-endpoint) with shared redacted return shape
  pinned by ADR 0047, an optional `intent.model_assist_enabled` toggle, a
  default-profile hygiene fix, and cross-OS first-run smoke
  (macOS/Linux/WSL2). Split from the original "Onboarding + Provider +
  Identity + Active Memory" bundle in the post-v0.37 planning pass.
- v0.39b (implemented as `0.39.1`; ready for operator manual validation):
  Identity Slot And Active Memory. Adds optional inert `identity` memory
  namespace declared through a non-app system-namespace declarer, adds
  `:identity` as a 5th `Memory` category, and adds deterministic
  recency-weighted direct-answer retrieval over `:kept` entries scoped to
  `{thread, active_app, identity}` with neutral/core-context behavior and a
  `## Active Memory` trace section at a pinned placement. Ships
  `retrieve_active_memory`, `mix allbert.memory list --namespace`, and
  `mix allbert.memory retrieve --query`, with executable Active Memory
  security evals. Algorithm spec'd in
  `docs/research/active-memory-retrieval.md`; operator doc at
  `docs/operator/active-memory.md`.
- v0.40 (implemented as `0.40.0`; ready for operator manual validation): MCP
  Client Integration. Adds `mcp.servers.*` configuration
  and `secret://mcp/...` refs, the `:mcp_tool_call` (confirmation-gated) and
  `:mcp_resource_read` (grant-gated) permission classes, `mcp://` promoted from
  reserved to a supported Resource Access adapter, HTTP/SSE + stdio transports
  (codec via `hermes_mcp`, egress through Allbert's posture), and the registered
  actions `mcp_doctor_server` / `mcp_list_tools` / `mcp_list_resources` /
  `mcp_read_resource` / `mcp_call_tool`. Real-server smoke validated the
  official GitHub MCP server in read-only stdio mode. The substrate v0.42
  panels consume.
- v0.41 (implemented): Developer Velocity And Parallel Test Methodology. Adds
  ADR 0049, ADR 0050, `docs/developer/test-strategy.md`, a gate matrix,
  test-lane taxonomy, async eligibility rules, and the isolation contract for
  per-test/per-partition Allbert Home, SQLite database, Settings Central roots,
  secrets roots, memory roots, sandbox roots, tmp roots, and process names. Also
  adds the implementation-plan annotation contract for parallel workstreams,
  serial barriers, gate evidence, and rejoin points, then migrates the existing
  suite onto those lanes with benchmark records after each implementation
  milestone and adaptive reordering when efficiency does not improve. The
  implemented high-coverage local gate is
  `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions N`.
  No operator-facing assistant capability.
- v0.42 (implemented as `0.42.2`): Tool Discovery + MCP-First Integration Pack 1. Ships
  `find_tools` (local tools + internet MCP-registry search behind a provider
  port), `mcp_fetch_server_manifest` / `mcp_evaluate_server`, and the
  confirmation-gated `mcp_server_connect` gate (pre-config consent showing the
  exact command/URL plus a live connected-server baseline for rug-pull defense), plus
  an opt-in, paused-by-default background scan to a passive Discovery Suggestions
  surface (no unprompted messaging, no auto-connect). Also ships calendar/mail/
  GitHub as MCP-server-configured workspace panels driven by the v0.40 MCP
  client, plus the `notes/files` native reference plugin as a starter scaffold for
  plugin authors. Closeout hardens the discovery permission boundary, CLI
  contract, effect forms, and deterministic release smoke. Native variants for
  the other three are post-1.0 follow-on.
- v0.43 (implemented as `0.43.0`): Browser And Web Research. Adds the `./plugins/allbert.browser/`
  reviewed source-tree plugin alongside Telegram, email, StockSage, and
  notes/files with
  real local Playwright/Chromium control, `browser://session/<id>` identity
  (ADR 0013 v0.43 amendment), per-domain
  remembered grants on navigated URLs, six browser operation classes, seven
  `:browser_*` permission classes (form fill and download default denied with
  confirmation floors),
  registered browser actions including a doctor (ADR 0047 shape),
  `mix allbert.browser research`, bounded
  HTML/markdown/text/PDF extraction, credential-input screenshot redaction
  at the driver layer, ephemeral profiles, two-layer network policy (top-level
  via `External.HttpPolicy` + subresources via `AllbertBrowser.NetworkPolicy`),
  a workspace browser results panel under `:canvas_panels`, and a paused-by-
  default cache sweep job. Page content is descriptive evidence, never
  authority. Forward-pins v0.52 channel approval-primitive amendment with
  `:typed_command`, `:button`, and `:link` confirmation shapes. v0.43.x
  follow-on candidates (Windows/WSL2, persistent profiles, authenticated
  operation, headed mode, multi-tab, JS evaluation) parked in
  `docs/plans/future-features.md`.
- v0.44 (implemented as `0.44.0`): Plan/Build Mode And Operator Workflow YAML. Adds a
  pinnable workspace panel over the v0.24 Objective Runtime (Preview +
  RunProgress under `:canvas_panels`), `workflow://<id>` and
  `plan://run/<objective_id>` URI schemes (ADR 0013 v0.44 amendment),
  three `:workflow_*`/`:plan_*` permission classes (`:workflow_read`,
  `:workflow_run_start` with `:needs_confirmation` floor,
  `:plan_cancel`), four operation classes plus `:plan_run` origin kind,
  `workflows.*` + `plan.*` core Settings Central namespace with
  `schema_version: 1`, and seven operator-facing Plan-Build actions
  (`list_workflows`, `inspect_workflow`, `expand_workflow`,
  `preview_plan`, `start_plan_run`, `cancel_plan_run`,
  `list_plan_runs`) plus internal `plan_step_confirm`. Workflow YAML lives under
  `<ALLBERT_HOME>/workflows/<id>.yaml` with id pattern
  `^[a-z0-9][a-z0-9_-]*$`. The v1 schema is assembled from the current
  `Actions.Registry.modules/0` snapshot + `Step.kinds()`; unknown keys reject with
  `additionalProperties: false` at every level. Expression substitution
  uses a closed function table (`${inputs.x}`,
  `${steps.<id>.<field>}`, `${user.locale|timezone}`,
  `${workflow.id|version}`); `eval`, `${secrets.x}`, `${env.x}`, and
  dynamic action-name resolution all reject at load. v0.24's six step
  kinds are exhaustive. The Plan Preview Contract packet carries
  per-step ordinal, kind, action name, params summary, permission,
  safety floor, resources needed, estimated cost, confidence tier,
  confirmations required, subagent target, and failure blast radius.
  Subagent delegation events render inline under the parent step
  (`plan.subagent.delegation_visibility: :expanded_inline` invariant).
  YAML `confirm: true` may only upgrade an action's confirmation
  floor, never downgrade. The plan-start gate is the only authority
  transition from preview to run; approved runs execute through the
  existing Objective Runtime; per-step confirmations are enforced at
  execution time. Forward-pins v0.52 channel-rendering
  amendment. v0.44.x follow-on candidates (loops, parallel/fan-out,
  sub-workflow includes, `on:` triggers, remote workflow
  distribution, multi-user collaborative plan editing) parked in
  `docs/plans/future-features.md`.
- v0.45 (implemented as `0.45.0`): Marketplace Lite — data shape +
  Allbert-author seeds only. Adds a shipped local seed catalog under
  `priv/marketplace/`, SHA-256 bundle verification, disabled/untrusted
  skill/template installs, browse-only plugin-index metadata, marketplace
  workspace panel and intent routing, CLI subcommands, custom Allbert
  Home-rooted install/cache settings, master disable switch, workflow-YAML
  forward-pin validation, and ADR 0047-style marketplace doctor. Community
  submissions stay parked. Drafts ADR 0046 for v0.59.
- v0.45.1 (implemented as `0.45.1`): Gate Transparency And Precommit
  Decomposition. Adds `mix allbert.test commit`, `mix allbert.test prepush`,
  timed direct release phases, redacted gate evidence, and `mix precommit` as
  commit-time feedback rather than release evidence. No assistant capability or
  Security Central authority changes.
- v0.46 (implemented as `0.46.0`): Delegation Hardening And Research
  Specialist. Ships a second native `AgentRegistry` consumer — a plugin-contributed
  research/summarize specialist (`research.specialist` under
  `./plugins/allbert.research/`) — so the v0.24 `AgentRegistry`/
  `delegate_agent` contract is proven against two domains (StockSage
  finance + research) before the v1.0 freeze (ADR 0021 amendment A21).
  The agent's `research`/`summarize_url` commands orchestrate the shipped
  v0.43 browser navigate/extract actions with deterministic extractive
  fallback through `Actions.Runner.run/3`. It also hardens the existing
  `delegate_agent` boundary so command strings are accepted only when
  declared in registered-agent metadata; unknown names stay on
  `:invalid_delegate_command` and no dynamic atom creation is allowed.
  Adds no new permission class, operation class, URI scheme, or
  registered action; only a `research.*` settings fragment
  (`schema_version: 1`). A `browser_navigate` inside a research dispatch
  still confirms (or applies a v0.43 remembered grant) — delegation
  provably does not widen authority. Output is advisory (ADR 0021 §4) and
  never auto-promotes to memory. Composed via the v0.44
  `kind: delegate_agent` workflow step with inline subagent-delegation
  rendering. `docs/developer/delegate-agents.md` documents the extension
  point so third-party plugins can register a delegate agent. Operator
  no-code agent authoring stays parked in `future-features.md`.
- v0.47 (implemented as `0.47.0`): Operator-Supervised Self-Improvement
  (Discovery + Local Drafts). Adds no autonomous authority; builds a read-only
  trace index, the generalized v0.42 suggestion surface, a read-only
  pattern-discovery action, and skill/workflow/memory drafts in one unified
  reviewed-draft store.
  Suggestions are advisory; drafts are inert; promotion to a live
  skill/workflow/memory entry is a separate confirmed action.
- v0.47b (implemented as `0.47.1`): Operator-Supervised Self-Improvement
  (Handoff Drafts). Adds template-, marketplace-, delegate-plugin-,
  capability-gap-, and objective-draft kinds on the v0.47 base; code-bearing
  drafts still route through v0.36 sandbox/gate, v0.37 dynamic integration,
  v0.38 templates, Security Central, confirmations, traces, and audits. Seven
  `:v047b` eval rows plus `release.v047b` prove the handoff boundary. No new
  trust tier.
- v0.48 (implemented through M8R with M8R7 local-runtime remediation):
  Voice Modality And Provider Capabilities. Adds capability metadata, ranked
  operator preferences, STT/TTS media resources, CLI file transcription,
  workspace microphone capture, TTS, Telegram voice-note ingestion, executable
  local adapter calls, OpenAI remote STT/TTS, Gemini remote STT/TTS, an
  Ollama-backed local text turn, 16 `:v048` eval rows, and expanded
  `release.v048`. M8R7 adds the Allbert-owned local voice runtime endpoint so
  the local path is product-owned, Settings Central-configured, Security
  Central-managed, and token-protected for STT/TTS HTTP requests. Fake
  providers are fixtures only. Discord voice is deferred until after Discord
  exists.
- v0.49: Vision And Image Generation. Implemented as `0.49.0`. Consumes the
  v0.48 provider capability substrate for image/screenshot resources,
  workspace image upload, vision-input plumbing, and provider-backed image
  generation through `generate_image`. `release.v049` proves the app-started
  ReqLLM path, 8 `:v049` eval rows, redaction, bounds, confirmation floors, and
  media secret scanning. Content hashes are metadata only; v0.50 owns the
  canonical content-addressed artifact store. Generic audio/video and catch-all
  multimodal routing remain future scope.
- v0.50 (implemented as 0.50.0): Artifacts Central. A uniform
  content-addressable store for artifacts uploaded by the operator, created by
  Allbert, or found through
  approved tools — type-agnostic (audio, video, images, PDFs, text, office
  docs), deduplicated by `artifact://sha256/<hex>` content hash with
  provenance/type/retention metadata, raw bytes kept out of traces. Adds
  `put_artifact`/`get_artifact`/`list_artifacts`/`delete_artifact` actions and
  the codebase's first supervised Jido ingestion sensor, links artifacts to the
  threads/messages that created them
  (`artifact_thread_links`, by-thread + reverse query, deterministic link ids,
  ADR 0054), and backfills the retained v0.48 audio, v0.49 vision-input, and
  v0.49 generated-image roots from the existing retention-root settings while
  leaving ephemeral scratch and historical Browser cache outside M5. Adds
  `:v050` artifact-store eval rows and `release.v050`. A thin CAS over BEAM
  primitives, not a third-party store; content-addressed identity and thread
  links never grant permission.
- v0.50b (released as v0.50.1 on 2026-06-09): Artifacts Browser. The operator browsing repository for
  Artifacts Central as a plugin/app (`plugins/allbert.artifacts/`, plugin id
  `allbert.artifacts`, modeled on StockSage + `allbert.browser`): a workspace
  `:canvas_panels` panel (M1 complete), an
  `/apps/artifacts/<sha>` detail page (M2 complete; core route, plugin-owned
  LiveView, sha validation before store reads), and a `mix allbert.artifacts`
  CLI (M3 complete; `list|show|threads|doctor|rm`), all reading the store only
  through core `:artifact_read` actions and rendering redacted metadata only.
  M4 completes panel + CLI filters by type, origin, thread, since date,
  retention, lifecycle, and limit. M5 adds `:v050b` artifact-browser eval rows,
  `release.v050b`, deterministic browser-validation fixture seeding, and the
  operator/developer browser guides. The plugin grants no authority and owns no
  store internals.
- v0.51 (implemented as `0.51.0`; ready for operator manual validation): Public
  Protocol Surfaces. Allbert exposes registered actions as MCP tools and memory
  namespaces as MCP resources, plus an OpenAI-compatible HTTP API and an ACP
  server surface (re-decided in ADR 0044, Phase B). Public AG-UI/A2UI bridge
  stays parked post-1.0. The MCP surface targets pinned Hermes-supported
  protocol versions, and the OpenAI-compatible surface is a bounded Chat
  Completions shim rather than full API parity. The v0.51 release lane is
  `mix allbert.test release.v051`.
- v0.52 (implemented as `0.52.0`): Channel Pack 1 - Discord And Slack. Adds team/community chat
  plugins over the existing channel substrate, amends ADR 0016 to lock the
  channel approval-primitive contract (`{list, button, typed_command, link}`)
  before mobile channels need it, and adds ADR 0057 cross-channel threading:
  `conversation_threads.id` stays canonical while owner/account-scoped provider
  thread keys drive reply placement and echo suppression.
- v0.53 (implemented as `0.53.0`; Telegram/email/Matrix validation complete, WhatsApp/Signal implemented-not-released by M11 / ADR 0066): Channel Pack 1 retro-validation (Telegram + email, first
  real-provider live validation) then Channel Pack 2 - Matrix + WhatsApp (Cloud
  API) + Signal (signal-cli daemon); Viber on paper + deferred, iMessage/SMS
  parked. One large release (M0-M11, constructs-first; M5 retro-validation before
  the new adapters). Finishes v0.52's unbuilt system-wide
  constructs — Key Custody (ADR 0058), channel trust-class gating (ADR 0059),
  public signed webhook (ADR 0056 amendment), descriptor reply-key/quote-TTL
  consumption, phone-PII redaction — and consumes the v0.52 approval-primitive +
  ADR 0057 threading contracts while preserving mandatory `:list` fallback.
  Matrix = unencrypted rooms only; no portable Matrix button primitive is claimed.
  Capability release availability is a generic release overlay, not a security
  boundary: undeclared capabilities default released, explicit unreleased refs
  fail closed, and Security Central remains authority.
- v0.54 (implemented as `0.54.0`): Intent Deepening. The local two-stage router
  removes the v0.53 channel approval dead-end; M9 adds the ADR 0062 descriptor
  lifecycle foundation; M10 adds outbound compose actions for email, calendar, and
  channel send (ADR 0063); M11 hardens slot/param normalization (ADR 0064). Model
  output stays advisory. Matrix generic outbound is deferred to v0.55 M1.
- v0.55 (shipped as `0.55.0`): Channel Parity + TUI/Terminal Channel. Explicit
  channel capability/parity matrix,
  Matrix generic outbound gap closure, and a proper TUI/terminal channel under
  the ADR 0016 contract using the shared list-shaped identity map (basic
  supervised `mix allbert.tui` launcher); harvests Pi's
  `model_payload`/`surface_payload` split (ADR 0067 extending ADR 0029/0030) and
  live region as the v0.57 coding-surface foundation. Post-M4 audit corrections
  made the live prompt the descriptor-derived `Channels.Supervisor` child and
  stabilized prompt rendering. Warm TUI validation passed; Matrix live provider
  smoke is blocked by inactive credentials.
- v0.55.1 (released as `0.55.1`): TUI Operator/Validation Console (point release). The v0.55
  TUI becomes the persistent, mix-free operator/validation console — in-TUI
  slash-commands + `mix allbert.channels status` backed by registered read-only
  internal inspection actions, reachable only through the slash-command allowlist
  or explicit Mix task twin, not intent candidates or tool-discovery suggestions,
  through `Actions.Runner.run/3`;
  migrates operator validation onto one warm BEAM. ADR 0070 is Accepted, and M5
  and M6/final release evidence were verified locally during closeout.
- v0.56 (released and tagged as `v0.56.0` on 2026-06-23): Intent Descriptor Learning +
  Registration Lifecycle Completion. Completes ADR 0062 with local-model generation,
  learned-review proposal-mining infrastructure, operator-callable optimization,
  app/plugin/action registration reindex signals, the ADR 0071 blocking
  routing-accuracy gate with a ratcheted release baseline, ADR 0072 model
  recommendations, minimal TUI `/intents`/`/models` validation reads, and warm-TUI
  M14 evidence. M14b post-audit hardening adds strict no-execute negative semantics,
  data-only live-bench fixture loading, Settings Central scoring knobs, package-owned
  descriptor slot tests, and the 254-case `v056-release-baseline`.
- v0.57 (planned): Pi-mode Coding Surface. A gated terminal coding surface (four
  boundary actions through `Actions.Runner.run/3`, sub-1000-token prompt, split
  diffs, full-file context) plus a local-coding/sandbox-level-0 trust tier
  (ADR 0068/0067/0009) — never YOLO-default, deterministic acceptance intact.
- v0.58 (planned): Web UX Redo + Surface Policy. Re-layouts `/workspace`
  (ADR 0023/0024 kept) — chat primary, ephemeral surfaces become popups, canvas
  demoted, labels cleaned up ("Conversations" replaces "threads"); references
  ChatGPT/Claude/Hermes. Adds operator-managed surface policy for report
  shape/display controls that remains separate from descriptor YAML and Security
  Central authority.
- v0.59 (planned): Hardening, Export/Import, Settings Migration, Operator
  Onboarding, And Final RC. Adds no new user-facing capability; proves
  portability, accepts and implements ADR 0046 (`mix allbert.settings.migrate`),
  adds a guided first-run onboarding path via the v0.55.1 TUI console (ADR 0069), runs the
  cross-surface eval sweep over v0.40-v0.58, implements ADR 0065 param-contract
  enforcement, and gathers RC evidence.
- v1.0 (planned): Stability Release And **Tiered Public Contract Freeze**.
  Adds no new features; Tier 1 freezes Runtime, Actions/permissions, Plugin,
  App, Settings Central schema shape, Allbert Home layout, Channel adapter
  boundary, and Resource Access URI/grants; Tier 2 freezes SurfaceProvider,
  Surface DSL with additive-only carve-out, and workspace canvas/ephemeral
  substrate minus single-consumer components. ADR 0021 reserved
  advisory-provider vocabulary is **not** part of the freeze.

## Area Notes

### Runtime And Actions

Runtime-facing, effectful, security-relevant, or observable behavior should
enter through signals, internal agents/runtime routers, and registered Jido
actions. CLI tasks, LiveViews, jobs, and channels should not own domain
semantics directly. Use `AllbertAssist.Actions.Runner.run/3` for action
execution so lifecycle signals, runner metadata, permission decisions,
redaction, and traces stay consistent.

### Security And Resource Access

Security Central owns permission decisions. Skills, model output, app metadata,
plugin metadata, YAML declarations, and generated files never grant authority.
Resource grants are operation-scoped; a grant for one operation class must not
authorize another.

For security work after v0.28, start with `docs/plans/v0.28-plan.md`,
`docs/plans/v0.28-request-flow.md`, and the eval modules under
`apps/allbert_assist/test/security/`. v0.28 hardened the app-scope boundary:
app-owned actions require explicit matching `active_app`, missing or neutral
scope fails closed, and non-interactive jobs/objectives must propagate trusted
active-app context before reaching `Actions.Runner.run/3`.

The `to_a2ui` redaction eval is a stub tripwire until protocol emission is
implemented after v0.38; do not treat it as full redaction coverage. Advisory
or proposer-origin memory writes must be stamped centrally by the objective or
memory-sync boundary, not by scattered callers.

For v0.36-v0.38 work, keep the authority split explicit: v0.36 sandbox runs
produce bounded reports only; v0.37 file-backed dynamic drafts can integrate
only after the v0.36 gate plus Security Central confirmation; v0.38 templates
add deterministic creation surfaces, not new sandbox, loader, permission, route,
or `active_app` authority.

For v0.37 code, start with `docs/developer/dynamic-plugin-drafts.md`. Use
`AllbertAssist.DynamicPlugins` as the public facade, keep
`DynamicPlugins.MetadataStore` file-backed under Allbert Home, keep
`DynamicPlugins.ActionsOverlay` behind `Actions.Registry`, and keep
`DynamicPlugins.TrustedValidator` separate from the v0.36 regex/source-policy
scanner. Dynamic integration and rollback confirmations must verify resolver
surface against `dynamic_codegen.integration_approval_surfaces`; delegated
facade confirmations from integrated dynamic actions intentionally follow the
reviewed facade's normal confirmation policy.

### Memory

Markdown memory is the long-term, inspectable source of truth. SQLite
conversation history is separate local workspace context and is not
auto-promoted. v0.21 added review, correction, archive, prune, promotion,
derived indexes/summaries, and metadata-only memory intent candidates.

v0.29 adds explicit app-memory sync for StockSage without changing the
no-auto-promotion rule. Namespaced app-memory writes go through the registered
`sync_app_lesson` action, durable confirmation, and `Memory.upsert_app_entry/1`.
`Memory.Entry` carries app namespace metadata and an idempotency key so markdown
render/parse, filters, and review flows preserve app ownership. Completing an
analysis, resolving an outcome, or generating a reflection must not write memory
unless the operator explicitly approves the sync.

### Plugins And Apps

Plugins are package/discovery contracts, not authority. They may contribute
apps, actions, skills, settings schema entries, channel descriptors, and
supervised children. They must not load arbitrary code from user folders, grant
trust, grant permissions, bypass confirmations, or execute package managers
during discovery.

For planned generation work, keep three roots distinct: source-tree plugins
under `./plugins`, v0.37 untrusted draft metadata/source under
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` that ordinary plugin discovery
must not scan, and v0.38 developer scaffolds whose `--target` defaults to
`./plugins/<name>` but remain inert until reviewed, compiled, tested, and
registered through normal paths.

### StockSage

StockSage is a shipped source-tree plugin app under `./plugins/stocksage`.
It uses `AllbertAssist.Repo` and `stocksage_*` tables. Do not create
`apps/stocksage`, `apps/stocksage_web`, or a separate `StockSage.Repo`.
Permission for local domain writes does not authorize financial API calls or
analysis execution.

For StockSage surface work, read `docs/plans/v0.32-plan.md`,
`docs/plans/v0.32-request-flow.md`, `docs/plans/v0.34-plan.md`, and
`docs/plans/v0.34-request-flow.md`, then the v0.27 docs for historical
renderer/detail context. v0.34 owns the planned operator shape after the
v0.32 shell: dashboard, recent analyses, queue, and trends are `/workspace`
Canvas destinations selected through the view-only launcher; selecting
StockSage does not set `active_app`; `/stocksage/*` routes are gone; analysis
detail remains `/apps/stocksage/analyses/:id`.

For StockSage security work, read v0.28 before editing runtime boundaries.
v0.28 added app-scope, registry, surface/catalog, namespace, Resource Access,
bridge/native, objective, and workspace-fragment evals around the StockSage
surface. The security posture assumes StockSage actions run only with explicit
`active_app: :stocksage` and normal confirmation/resource checks.

For StockSage memory/outcomes/rerun work, read `docs/plans/v0.29-plan.md`
and `docs/plans/v0.29-request-flow.md`. v0.29 owns outcome resolution,
trend calibration, deterministic reflections, explicit app-memory lesson sync,
source-analysis-aware reruns, and app-flow polish. It consumes the namespace
declared in v0.27 and audited in v0.28.

v0.25 native financial agents are plugin-owned but runtime-callable through
the shared objective delegate-agent substrate. Read
`docs/plans/v0.25-plan.md`, `docs/plans/v0.25-request-flow.md`, ADR 0020, ADR
0021, and ADR 0022 before touching them. The native agents should adapt the
TradingAgents baseline's role intent, fixtures, and result fields, not clone
every Python role/class one for one. v0.25 prompt/control files are
Allbert-authored; verbatim upstream prompt adaptation requires a future
explicit license-audit milestone.
`plugins/stocksage/priv/python/bridge.py` contains the bridge protocol and
final-state field list, not the role prompts; prompt inventory belongs under
`plugins/stocksage/priv/prompts/native_agents/`.

Native financial agents register 12 stable ids in
`AllbertAssist.Objectives.AgentRegistry` at app boot (per ADR 0022
Amendment A1):

- `stocksage.market_context` — Jido.AI; tool: FetchMarketData
- `stocksage.news_sentiment` — Jido.AI; tools: FetchNews, FetchSentiment
- `stocksage.fundamentals` — Jido.AI; tools: FetchMarketData, FetchFundamentals, FetchFinancials
- `stocksage.bull_thesis` — Jido.AI; multi-round capable
- `stocksage.bear_thesis` — Jido.AI; multi-round capable
- `stocksage.risk_aggressive` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.risk_conservative` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.risk_neutral` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.research_manager` — Jido.AI; preliminary research decision; slow-profile default
- `stocksage.trader_plan` — Jido.AI; bounded advisory plan; slow-profile default
- `stocksage.decision_synthesizer` — Jido.AI; slow-profile default
- `stocksage.quality_gate` — plain Jido.Agent (deterministic; no LLM)

Plus one supervised JidoBacked orchestrator NOT registered in
AgentRegistry: `StockSage.Agents.NativeCoordinator` (per ADR 0022 A3).
The coordinator owns per-analysis projection, multi-round dispatch
order, and parity-run composition; it is called from
`StockSage.Actions.RunAnalysis` via `JidoBacked.dispatch/4`.

All agents return bounded advisory report packets per ADR 0022 only.
Market data, news, fundamentals, persistence, confirmations, settings,
traces, and final analysis writes still flow through registered
actions, `Actions.Runner.run/3`, Security Central, and Resource
Access Security Posture. The 5 tiered evidence actions live under
`StockSage.Actions.Evidence.*` and are gated by the new
`:stocksage_evidence_fetch` permission class (per ADR 0022 A4).

Multi-round debate (bull/bear/risk) is implemented inside the
plugin-owned native coordinator graph. Each specialist turn still
creates one `objective_steps` row of `kind: :delegate_agent` with
round metadata (per ADR 0022 A2). Operators inspect rounds via
`mix allbert.objectives show <id>`.

Engine choice is request-scoped. Absent engine means native;
`--engine python` and `--engine both` are explicit
comparison/reference modes, not Settings Central defaults.
`--engine both` runs native + Python concurrently; persists ONE
analysis row with both engines' fields populated + parity_diff JSON
(per ADR 0022 A5, A6). Parity metric: 5-point rating-scale agreement
(exact 1.0 / adjacent 0.5 / distant 0.0) + bounded confidence delta.

Cross-app callability: `mix allbert.delegate <agent_id>` Mix task lives
in Allbert core (not StockSage) and proves any registered specialist
agent is callable from outside StockSage via the v0.24 DelegateAgent
registered action + AgentRegistry (per ADR 0022 A7).

### Workspace And Surfaces

Apps may have reviewed Phoenix LiveViews and routes, but web surfaces must be
declared through `AllbertAssist.App.SurfaceProvider` and validated by
`AllbertAssist.Surface`. Surface metadata is not authority and must not create
routes dynamically without an explicit plan.

v0.38's `workspace:create` surface consumes the v0.34/v0.35 workspace
contracts: launcher/layout state is view-only, Output and Settings remain
non-hideable, `app:allbert` is not a layout destination, generated
theme/snippet/layout stubs are disabled by default, and any live integration
routes through the v0.37 loader instead of private LiveView logic.

v0.28 is the security reference for this substrate: catalog bypass, component
injection, fragment replay/tampering, emitter allow-list, app-scope routing,
and workspace/canvas hard-disable behavior all have named eval coverage. v0.30
wires v0.27-proven StockSage components into durable workspace canvas tiles
through the v0.26/v0.28-audited mechanism; future app canvas work should reuse
that same signed Fragment path unless a new ADR changes the substrate.

v0.26 expands the Surface DSL substrate from a single chat-only `/agent`
LiveView to the shipped **agentic workspace shell**:

- The workspace shell IS itself a Surface tree (per ADR 0023 §2 + the
  v0.26 design choice). `CoreApp.surfaces/0` declares the workspace
  tree at boot; the web renderer walks it and dispatches each node's
  `:component` atom through the v0.31 `AllbertAssist.Surface.Catalog` and
  `AllbertAssistWeb.Surface.Renderer` path. There is NO hardcoded HEEx layout
  for regions.
- Per-thread Canvas (persistent tiles) lives in SQLite metadata +
  YAML body under `<ALLBERT_HOME>/workspace/canvas/<user_id>/<thread_id>/`.
  Per-thread Ephemeral Surfaces live in SQLite + YAML under
  `<ALLBERT_HOME>/workspace/ephemeral/<user_id>/<thread_id>/`. Both
  are shared across browser tabs viewing the same thread via the
  `SignalBridge.workspace_topic_for/2` PubSub topic
  `workspace:<user_id>:<thread_id>`.
- Runtime Fragment emission is signal-topic-driven: any in-BEAM
  module publishes a HMAC-signed `%Workspace.Fragment.Envelope{}` to
  `allbert.workspace.fragment.**`; `AllbertAssistWeb.SignalBridge`
  (extends v0.24) validates strictly (envelope shape + signature +
  catalog component + emitter allow-list + per-emitter rate limit +
  payload size) and forwards valid envelopes to the per-user
  `SignalBridge.topic_for/1` PubSub topic `objectives:<user_id>`.
  Invalid envelopes drop with bounded log +
  `allbert.workspace.fragment.dropped` signal.
- 42-component catalog (per ADR 0015 v0.26 amendment): 12 v0.18
  carryover + 10 workspace structural + 12 Allbert-domain + 4
  Allbert-app cards + 4 reserved StockSage cards. v0.27 ships real
  StockSage-owned renderers for those cards; v0.30 wires those renderers into
  durable canvas tiles without adding a new `:stock_chart` atom; v0.32 reuses
  them in StockSage workspace panels.
- 14 new `workspace.*` settings (theme, offline, accessibility,
  fixed read-only mobile breakpoint, fragment rate limits, etc.). New
  `:workspace_canvas_write` permission class.
- UX qualities are first-class in v0.26: dark mode, high contrast,
  reduced motion, structural accessibility coverage, mobile responsive
  layout, and offline text/markdown editing via browser-side Yjs +
  IndexedDB with bounded reconnect sync + conflict-banner UX. v0.26
  does not add a server-side Rust NIF or server-side CRDT interpreter;
  manual axe/screen-reader validation remains the release gate.
- Internal `AllbertAssist.Workspace.AGUI.Bridge` translates curated
  Allbert signals to AG-UI event shape for test-only semantic
  mapping; NOT exposed over HTTP. Public AG-UI / A2UI / MCP Apps
  interop is post-v0.38 (per Future Features UI Protocol
  Interop).

In v0.26, sibling routes (`/objectives/:id`, `/jobs`, `/settings`) remain
top-level for deep-linking. The workspace can render catalog-backed summary
tiles for those domains, but it does not replace the sibling routes in v0.26.
v0.32 supersedes this route shape for operator UI: Settings Central moves into
`/workspace`, and plugin workspace regions graduate as panels. Plugins MAY
emit Fragments via the SignalBus topic (existing v0.26 emission path).

### Jido.Agent vs. GenServer Substrate (v0.23)

Allbert uses both `Jido.Agent` and plain `GenServer` for state-bearing
components. The pragmatic rule (from v0.23 and the vision): use `Jido.Agent`
when state machines, documented lifecycle hooks (`on_before_cmd/2`,
`on_after_cmd/3`), Skill composition, or successor agents are plausibly
useful; use plain `GenServer` for stateful storage where Jido.Agent buys
nothing. As of v0.23, `IntentAgent`,
`Confirmations.Store.Agent`, and `Jobs.Scheduler.Agent` are Jido agents;
v0.24 adds `Objectives.Engine.Agent`. `Confirmations.Store` remains Allbert
Home file-backed, not SQLite-backed. `Jobs.Scheduler` remains
SQLite-job-backed and keeps no authoritative in-memory job queue. `Settings`,
`Trace`, `Memory` storage IO, `Session.Scratchpad`, `Memory.Compiler`, and
`Memory.Promotion` stay plain GenServers/modules. New modules document their
substrate choice in the module `@moduledoc`. Private Jido command modules
inside these agents are not registered Allbert capability actions and must not
appear in intent candidates. Worked conversion details live in
`docs/developer/jido-agent-pattern.md`. Transitional compatibility modules
used during v0.23 parity testing were removed before release closeout, while
retained fixture snapshots under `apps/allbert_assist/test/fixtures/v0.23/`
document canonical confirmation audit and scheduler summary behavior.

### Objectives And Advisory Providers (v0.24)

The objective runtime is the durable cross-turn substrate. `Objectives`
hold acceptance criteria and status; `Objectives.Step` records
per-step work; `Objectives.Event` records lifecycle history.
`Objectives.Engine.Agent` is a JidoBacked agent implementing a
seven-stage state machine: receive → interpret intent → frame/resume
objective → propose and evaluate steps → authorize → execute → observe
and advance. The seven-stage pipeline is implemented by 10 real private
`AllbertAssist.Objectives.Commands.*` `Jido.Action` modules routed through
JidoBacked signal dispatch; they are not registered actions and must not appear
as intent candidates. Do not define custom `cmd/3` functions on a JidoBacked
agent; `use Jido.Agent` already provides that API.

Facade rule: use `AllbertAssist.Objectives.list/2`, `get/2`, `frame/2`,
`advance/2`, `cancel/3`, `continue/2`, or registered objective actions for
lifecycle transitions. The lower-level create/update/list helpers in the same
module are internal store helpers. `frame/2` requires explicit user identity.

Authority rule (ADR 0021): `objective_id` is not permission;
`active_app` on an objective is not permission; advisory provider
output (LLM proposers, world-model predictors, diffusion proposers,
market allocators, probabilistic critics) is never authority. Everything
effectful flows through `Actions.Runner.run/3` and Security Central.
Objective-driven `RunAnalysis` or other app actions must still use the
registered action runner path; the objective engine never calls
confirmation storage directly.

Delegate rule: `AllbertAssist.Objectives.AgentRegistry` is a monitored local
registry. It evicts dead registered agent processes and dispatches through
`Jido.AgentServer.call/3`; plugins should not keep their own hidden delegate
agent lookup tables.

Durability rule: JidoBacked state is a rebuildable projection. Hybrid
proposer continuation state is stored in durable
`objectives.proposer_hint` JSON and only cached in
`Engine.Agent.proposer_hints`. Crash/rehydrate behavior should reload
from SQLite, not from serialized agent state.

Signal rule: v0.24 preserves legacy `allbert.input.received` and
`allbert.agent.responded` emissions and adds canonical
`allbert.runtime.turn.started` / `allbert.runtime.turn.completed`
aliases. Objective signals publish through the named
`Jido.Signal.Bus` (`AllbertAssist.SignalBus`); web subscribers use
`allbert.objective.**`, not `allbert.objective.*`. SignalBridge lives
in the web app and broadcasts objective events to per-user PubSub
topics; the engine remains Phoenix-agnostic.

ADR accounting: v0.24 M2 amends ADR 0019 to register the `:objective`
candidate kind. v0.24 M6 moves ADR 0021 to Accepted after confirming
the implemented `:objective_write`, `parent_step_id`,
`objectives.proposer_hint`, minimal `:delegate_agent`, `:abandoned`,
signal, and confirmation-threading contracts.

Reserved vocabulary: capability inventory, capability gap, route,
acquisition option, world-model provider, diffusion proposer, market
allocator. Named in ADR 0021; not implemented in v0.24. Research note
at `docs/research/objective-runtime-research.md`.
