# Allbert Future Features Parking Lot

This file tracks features that have been identified in plans, ADRs, or
discussion, but are not yet assigned to a concrete roadmap milestone with an
implementation-ready plan.

Use this as a parking lot, not a backlog commitment. When a feature graduates
into `docs/plans/roadmap.md` with a versioned plan, remove or update its entry
here.

## Already Planned Elsewhere

See `docs/plans/roadmap.md` for the full milestone list (v0.01 through v1.0).
Recently graduated parking-lot items are flagged with **Status: graduated to
vX.Y** headers in their entries below; do not duplicate them here unless the
future feature is broader than the existing plan.

## Unassigned Future Features


### system memory
was `Small-Model Memory Or Personality Distillation`

Status: split. A deterministic Active Memory precursor is planned for v0.39:
it reuses reviewed-memory retrieval before replies and does not train,
distill, or generate a system model. Operator-supervised trace pattern
suggestions are planned for v0.45 in `docs/plans/v0.45-plan.md`.
Small-model memory/personality distillation remains parked here as research.

need to think about not just user/operator memory, but the allbert system memory as the use of allbert evolves with the operators request .. things like
- common agent use, action use signal use patterns, could be codified into intents or workflows rather than rediscovery it every time
- suggestions to create skills based on repeated prompts
- suggestion to create llm use tools to codify certain system commands or web searches or data access that can be more deterministic
etc..

Source: origin note and roadmap future research.

The origin note imagines compiled memory, nightly distillation, or a small
personal model. The safe near-term interpretation is deterministic retrieval
and trace-derived draft suggestions. Training, distillation, or learned
system-memory authority remains research until memory review, trace quality,
retrieval, deletion policy, reproducibility, and evals are stable.

Needed before planning:

- v0.21 reviewed markdown memory corpus
- rebuildable derived artifacts
- evals for personality and recall quality
- privacy and deletion policy
- training cost and reproducibility policy


### Remote Secrets Manager

Source: v0.02 non-goals.

v0.02 uses an encrypted local Settings Central secret store. A future milestone
may add an adapter for an OS keychain, cloud secret manager, or enterprise
vault.

Needed before planning:

- local secret store stability
- provider abstraction for secret backends
- migration/export policy
- offline behavior
- redaction and audit consistency across backends
- v0.28 (formerly v0.26) security evals covering secret redaction regressions


### Operator first run onboarding.
**Status: graduated to v0.39 First-Run Onboarding + Provider Control +
Identity Slot + Active Memory.**

when the user first downloads from git, the allbert runtime, what to run, is it a guided run.. the run should also be made up of agents, actions, signals etc, so that it can be run from the command line or any other channel, like the web.

- ask to set up keys for remote llms or local llm configs
- ask for default workflows and intent styles
- ask to set up default recurring crons
- other things (like sandboxes etc)

### Autonomous Skill Creation

Source: origin note, ADR 0003, v0.03 through v0.06 non-goals, v0.37 dynamic
code/config generation planning, and v0.38 templated-creation planning.

Status: split. A safe trace-to-skill draft suggestion precursor is planned for
v0.45 in `docs/plans/v0.45-plan.md`. Fully autonomous skill creation remains
parked here.

Allbert should eventually help create new skills from traces, repeated tasks,
corrections, or explicit user requests. v0.36 implements the narrow Elixir/OTP
sandbox/gate substrate; v0.37 covers operator-confirmed dynamic generation and
gated live integration for explicit capability gaps; v0.38 covers templated
creation (vetted plugin/app/tool/flow/code templates via Mix tasks, operator
flows, and a Canvas surface). v0.45 can propose inert drafts from trace
patterns and route them into those reviewed paths. None of these
milestones autonomously infers, trusts, enables, publishes, or activates new
capabilities from traces.

Needed before scheduling autonomous creation:

- v0.36 sandbox/gate runner accepted through user testing
- v0.37 dynamic generation/live-loader accepted through user testing
- v0.38 manual plugin/app/template generator accepted
  through user testing
- v0.45 supervised suggestion precursor accepted through user testing
- review and trust workflow
- trace-to-skill draft workflow
- explicit operator approval before enabling
- evals for generated skill quality and unsafe capability requests
- policy for instruction-only drafts versus generated app/action code

### Dynamic Capability Expansion

Source: v0.37 implementation audits, v0.37.5 release closeout, and v0.38
templated-creation planning.

Status: split. v0.36-v0.38 already define the current supervised dynamic
capability path. v0.45 connects that path to trace-derived capability-gap
suggestions. Unsupervised self-recompilation and compiler-loop bootstrapping
remain research.

v0.37.5 ships the first runnable dynamic-code path: explicit capability gaps
can produce pure read-only actions or delegated memory/network actions through
the reviewed `append_memory` and `external_network_request` facades. Future
enablement work can broaden that surface without changing the core rule that
generated code gains authority only through reviewed contracts, sandbox/gate
evidence, and operator-controlled integration.

Potential directions:

- add reviewed delegate facades for operations such as memory update/promotion
  once their operator contract, permission class, validator mapping, and
  security eval rows are explicit;
- extend the generated permission ceiling to additional reviewed domains such
  as objective or workspace-canvas writes after matching facades and validators
  exist;
- add a `mix allbert.dynamic.enable` helper, optionally with an
  `--allow-writes` mode, to flip a coherent operator setup bundle with clear
  warnings instead of requiring several manual settings changes;
- surface `dynamic_codegen_delegate` provenance in CLI, LiveView, email, and
  channel confirmation cards so operators can see which generated action caused
  a reviewed facade confirmation.
- analyze repeated capability gaps in v0.45 and propose inert dynamic draft
  requests that still enter the v0.36/v0.37/v0.38 review path.

Needed before scheduling broader dynamic expansion:

- v0.37.5 dynamic generation/live-loader accepted through manual operator
  testing
- v0.38 templates accepted through operator use
- v1.0 public contracts frozen
- reviewed facade contracts for each new delegated operation
- security eval rows proving permission/facade/confirmation behavior
- operator documentation for any setup helper or new delegated approval surface


### Intents vs Objective for agent tasks (graduated)

**Status: graduated to v0.24 Objective Runtime Foundation.**

The original parking-lot note observed that Allbert should be organized
around two layers — intent (what the user appears to mean now) and
objective (what outcome to pursue across steps) — that decompose into
span-out / span-in / hierarchy / consolidation cycles.

That observation drove the project-direction rethink
(`docs/plans/project-direction-rethink-01.md`) and graduated into
v0.24 Objective Runtime Foundation:

- ADR: `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md`
- Plan: `docs/plans/v0.24-plan.md`
- Request flow: `docs/plans/v0.24-request-flow.md`
- Research note: `docs/research/objective-runtime-research.md`

Reserved vocabulary still in research stage (named in ADR 0021,
implemented only when real consumers appear):

- Capability inventory, capability gap, route, acquisition option modules.
- Advisory provider umbrella behaviour and provider roles
  (`WorldModelProvider`, `DiffusionProposalProvider`,
  `MarketAllocatorProvider`, `ProbabilisticInferenceProvider`,
  `CriticEvaluatorProvider`, `ResourceDecisionProvider`).
- Hook contribution API for plugins/apps.
- LLM-assisted step proposer and acceptance evaluator.
- Parallel step execution.
- Capability acquisition automation.

The narrow intent/route advisory subset for app handoff and clarification is
planned in v0.33 (ADR 0034). Broader advisory providers and world-model
behaviors remain parked here.

These remain parked here as a single line in `docs/plans/future-features.md`
"Advisory Providers And World Models" entry below until a real consumer
arrives.

### Additional Remote Channel Adapters

Source: origin note, allbert-jido vision, and v0.16 dual-channel planning.

Status: split. Discord and Slack are planned for v0.43. WhatsApp, Signal,
iMessage, and Matrix are planned for v0.48. SMS remains parked here until a
dedicated cost, truncation, phone-number mapping, and provider-delivery design
exists.

v0.16 proves the channel adapter boundary with Telegram (Bot API long polling,
inline buttons) and email (IMAP polling, SMTP replies, typed-command approvals).
v0.17 makes Telegram and email shipped source-tree channel plugins under
`./plugins`. The remaining remote channels named in the vision, including
Discord, WhatsApp-style chat, SMS, and Slack-style team chat, are still parked
here until promoted to their own implementation-ready milestone. They should
reuse the v0.16 channel context, identity mapping posture, durable event
dedupe, runtime submission flow, Approval Handoff rendering, confirmation
callback/command pattern, redaction rules, and v0.17 plugin contribution model
instead of inventing provider-specific runtimes.

Each remaining provider still needs a focused design pass because the security
and UX surfaces differ:

- SMS needs phone-number mapping, short-message truncation, cost/rate limits,
  and provider delivery failure handling.
- Discord, WhatsApp-style chat, and Slack-style team chat need workspace/server
  identity mapping, group/channel authorization, mention handling, threaded
  replies, callback affordances, and team-channel privacy rules.

Needed before planning:

- v0.16 Telegram and email adapters accepted through user testing
- v0.17 channel plugin contribution model accepted through user testing
- v0.16 channel event and identity-map contracts stable
- provider-specific Settings Central schema and secret policy
- provider-specific delivery, retry, dedupe, and callback model
- v0.28 (formerly v0.26) security evals for cross-channel spoofing, replay,
  group leakage, command injection in reply bodies, and resource approval
  scope leakage
- operator UX for mapping, disabling, and inspecting external identities
- clear decision on whether a provider starts as inbound-only, response-only,
  or full request/response with confirmation callbacks

### Full Settings UI Polish

**Status: largely subsumed by v0.32 (workspace Settings Central) plus v0.39
(provider/model control surface). Remaining polish — search, accessibility,
mobile-specific layout, and secret-entry UX — stays parked here for a
post-1.0 product/UI milestone.**

Source: v0.02 non-goals.

The v0.02 settings LiveView is functional by design. A future product/UI
milestone may make Settings Central easier to browse, search, validate, and
operate.

Needed before planning:

- stable settings schema
- operator workflows from real usage
- v0.18 app settings schema declarations, if app-scoped settings have landed
- grouping, search, validation, and audit navigation design
- secret entry UX
- accessibility and mobile behavior

### Post-v0.38 UI Protocol Interop

Source: operator UI discussion, v0.16 channel planning, v0.21 memory review,
v0.19 intent enrichment, v0.28 (formerly v0.26) security hardening, and
research into A2UI, AG-UI, MCP Apps, ChatGPT Canvas, Claude Artifacts,
Google Gemini generative UI, BISCUIT, and Athena.

Status: split. Public API, ACP, MCP-server, and AG-UI/A2UI bridge exposure is
planned for v0.49 (`docs/plans/v0.49-plan.md`, ADRs 0043 and 0044). MCP Apps
sandboxed-iframe compatibility remains parked here because it conflicts with
Allbert's declarative/catalog-bound Surface stance and needs a separate
trust-policy ADR.

The v0.26 internal `AllbertAssist.Workspace.AGUI.Bridge` (ADR 0023 §8) is
authoritative for the signal → AG-UI event mapping that any public bridge
must preserve. The v0.49 public bridge inherits that mapping; see ADR 0023
§8 for the table.

Still parked here:

- **MCP Apps sandboxed-iframe trust policy.** Conflicts with the declarative
  + catalog-bound Surface stance; would need its own trust-policy ADR.
- **Multi-user collaborative cursors.** Deferred from v0.26; "Cursor"
  vocabulary reserved in ADR 0023 §1.
- **Canvas snapshot / undo / time-travel.** Deferred from v0.26; signal
  topic `allbert.workspace.canvas.snapshot.requested` reserved as v0.26
  no-op.
- **Server-side CRDT interpretation, compaction, or Rust/NIF-backed Yjs
  reconciliation.** v0.26 deliberately keeps Yjs in the browser and stores
  opaque bounded update blobs plus readable snapshots server-side.
- **Remote theme marketplaces and federated UI-protocol styling beyond the
  v0.35 sanitized override path.** Needs a separate security/design pass.


### Advisory Providers And World Models

Source: v0.24 reserved vocabulary in ADR 0021.

v0.24 ships one deterministic step proposer and one deterministic
acceptance evaluator. The advisory provider umbrella (intent provider,
route provider, capability provider, resource decision provider,
world-model provider, diffusion proposal provider, probabilistic
inference provider, market allocator provider, critic evaluator
provider) is reserved vocabulary in ADR 0021. The first behaviour
extraction happens when at least two providers of the same role exist.

v0.33 graduates the narrow app-intent descriptor, handoff, and clarification
subset as a concrete intent/route advisory consumer. This entry remains for
broader advisory provider extraction, world models, learned schedulers,
capability providers, and resource decision providers.

Hard rules that apply to any future advisory provider (carry into
planning):

- No advisory output authorizes execution.
- World-model output is predictive/counterfactual, not observed fact.
- Predictions about user behavior never short-circuit confirmation.
- All effectful work flows through `Actions.Runner.run/3`, Security
  Central, confirmations, resource access posture, traces, and audits.
- Settings Central config, Security Central posture, redaction,
  traces, and evals gate any provider call.

Needed before planning:

- A concrete consumer (e.g., an LLM-assisted step proposer in
  StockSage v0.25+, or a learned scheduler in a later release).
- Eval coverage for the rules above.
- Settings Central schema for provider config and timeouts.
- Trace/audit shape for advisory output.

### StockSage Native/Python Parity Tuning

Source: v0.25 post-remediation parity runs against Python TradingAgents using
matched provider/model settings.

v0.25 makes native StockSage the default operational engine and adds explicit
Python comparison through `--engine python` and `--engine both`. The native
graph now preserves research-manager, trader-plan, risk-debate, and final
decision-synthesizer handoffs, and records a parity diff for comparison runs.
That is enough for operator inspection and v0.26/v0.27 rendering work, but it
is not a claim of exact rating parity with Python TradingAgents.

Future parity tuning should improve the native graph against a larger stock
matrix by comparing like-for-like provider/model runs, inspecting evidence
coverage, and tuning role prompts and agent boundaries. It must avoid
ticker-specific overrides, deterministic rating floors, silent post-processing
of final ratings, and automatic native-to-Python fallback. Python remains an
explicit reference/comparison path, not a hidden recovery engine.

Needed before planning:

- accepted v0.25 native specialist-agent release and operator smoke
- reproducible comparison harness that records provider, model, evidence mode,
  run time, final rating, confidence, and per-agent summaries for both native
  and Python
- representative ticker matrix, including large-cap, high-growth, OTC/GSE,
  low-data, and ambiguous/risk-managed names
- evidence-source parity audit for price, fundamentals, financial statements,
  news, sentiment, and unavailable-data semantics
- prompt and role-boundary review focused on portfolio-posture semantics
  (`Buy`/`Overweight`/`Hold`/`Underweight`/`Sell`)
- eval policy that distinguishes acceptable stochastic disagreement from
  native graph defects

### Browser/Search Capture

Source: origin note and v0.16 channel adapter foundation.

Status: split. Browser and web research are planned for v0.42 with a
browser-session Resource Access policy, plugin-owned browser supervisor,
research/extract/screenshot actions, and bounded HTML/markdown/text/PDF
extraction. Broader browser capture, memory promotion from browsing, and
authenticated-account operations remain parked here.

The origin note describes capturing searches or browsing activity and turning
useful context into memory. v0.11 owns the Resource Access Security Posture for
approved URL/document consumers, and v0.16 proves the channel adapter boundary
with Telegram. Browser capture is still broader than approved
URL fetches: it may involve page state, user sessions, cookies, interactive
navigation, screenshots, or memory promotion, so it remains parked until
channel adapters, memory review, and security hardening are ready.

Needed before planning:

- v0.16 channel adapter foundation
- external network/browser permission policy
- v0.11 URL/document resource posture and Approval Handoff accepted
- v0.21 memory review workflow
- v0.26 browser/search security eval posture
- sensitive-data detection and confirmation
- traceable extraction path

### Deep Remote Document Extraction

Source: v0.11 Resource Access Security Posture planning.

Status: split. v0.42 plans bounded HTML, markdown, plain text, and PDF
extraction for browser/web research. Broader Office, archive, unknown-binary,
and deep extractor support remains parked here.

v0.11 should let the system represent and approve requests like "check this
URL and summarize it" through resource access posture. That does not mean every
local or remote document type is deeply parsed in the same release. Broad
document handling may need a later focused milestone once the first approved
read/fetch/extract/summarizer handoff is boring.

Needed before planning:

- stable resource access reference and approval scope records
- v0.11 URL/document approval handoff accepted through user testing
- v0.26 prompt-injection and data-exfiltration evals for fetched content
- bounded content cache/digest policy
- extractor contracts for HTML, markdown, plain text, PDF, office documents,
  archives, and unknown binary content
- prompt-injection and data-exfiltration posture for fetched content sent to
  summarizers
- unsupported-format and partial-extraction UX
- tests for size caps, content-type mismatches, malformed files, redirects,
  private-network targets, and redacted traces

### MCP And Agent URI Resource Access

Source: v0.10 URI-first resource identity planning and v0.11 Approval Handoff
planning.

Status: split. MCP client execution is planned for v0.40. Future `agent://`
and `agent+https://` endpoint execution, MCP Apps UI, and broader agent
endpoint discovery/authentication remain parked here.

MCP resources and future agent endpoints should be modeled as URI-addressed
resources before they gain execution authority. `mcp://`, `agent://`, and
`agent+https://` can be represented as inert planning/approval metadata after
the v0.10 URI substrate exists, but calling them requires later explicit
actions, Security Central policy, Settings Central configuration, channel
handoff, adapter implementation, redaction, trace, audit, and tests.

Needed before planning:

- v0.11 unsupported MCP/agent URI posture accepted
- v0.28 (formerly v0.26) evals for cross-scheme grant reuse,
  tool/resource confusion, prompt injection through MCP resources, and
  remote agent impersonation
- v0.18/v0.26 (formerly v0.18/v0.24) surface contract stability if MCP Apps
  UI is in scope
- MCP server configuration and permission model
- agent endpoint discovery, authentication, and trust model
- channel-native Approval Handoff consumption from v0.16

### Native UI Surface

Source: origin note and v0.16 channel adapter foundation.

Native UI is listed as a possible channel but has no dedicated plan. It should
not be planned before the Telegram-proven channel adapter contract and local
workspace surface contract are stable.

Needed before planning:

- v0.16 channel adapter contract
- v0.26 (formerly v0.24) workspace/surface contract
- Settings Central channel preferences
- authentication or local operator identity policy
- confirmation handoff behavior
- packaging/release approach


### Remote Sync And Profile Export/Import

Source: v0.02 non-goals and ADR 0005 consequences.

Status: split. Local-first profile export/import dry runs are planned for
v0.50. Broad remote sync service remains parked here as a separate product
decision.

Allbert Home gives a clear local boundary for backup and migration, but there
is no remote sync or full profile import/export plan yet.

Needed before planning:

- stable Allbert Home layout
- schema/version metadata for settings, memory, skills, cache, and database
- SQLite conversation and app data export policy after v0.12/v0.20
- encrypted secret migration policy
- conflict resolution policy
- operator-visible dry run and rollback

### Hosted Multi-User Authorization Model

Source: v0.02, v0.07, and v0.12 non-goals.

Allbert's near-term identity model is local string `user_id`. Hosted accounts,
roles, teams, auth sessions, API keys, and cross-user authorization remain
future work for shared workspaces, team channels, or hosted deployments.

Needed before planning:

- v0.12 string identity and thread isolation accepted
- v0.26 cross-user/thread leakage evals accepted
- hosted deployment posture and threat model
- operator/user/admin role model
- per-user Settings Central scope
- per-user memory and channel policy
- audit and confirmation ownership

### Remote Plugin Marketplace And Code-Bearing Plugin Distribution

Source: v0.17 plugin substrate, v0.36 sandbox planning, v0.37 dynamic draft
planning, and v0.38 generator planning.

Status: split. Marketplace lite is planned for v0.49: reviewed-skill discovery,
reviewed-source plugin index metadata, and template catalog metadata. Arbitrary
remote code-bearing plugin install, dependency resolution, hot-loading, remote
theme/snippet distribution, and binary/plugin package distribution remain
parked here.

v0.17 creates local plugin discovery and ships Telegram/email as source-tree
plugins under `./plugins`, but it does not install remote plugins, resolve
dependencies, automatically compile arbitrary `./plugins/*/lib` directories,
compile code from `<ALLBERT_HOME>/plugins`, hot-reload code-bearing plugins,
or sandbox untrusted plugin execution. v0.36 adds a local Elixir/OTP
sandbox/gate runner only; v0.37 adds local dynamic draft generation under
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` plus gated live integration;
neither is remote distribution. v0.38 may scaffold plugin source for developer
review, compile, and test, but marketplace distribution, remote template
catalogs, and arbitrary runtime loading remain parked here.

Needed before planning:

- v0.17 plugin registry accepted through user testing
- v0.26 plugin-boundary security evals accepted
- v0.36 sandbox/gate runner accepted through user testing
- v0.37 dynamic generation/live-loader accepted through user testing
- v0.38 plugin/app generator accepted through user
  testing
- dependency install/update policy
- plugin signing, provenance, versioning, and rollback model
- clear trust tiers for skill-only, compiled local, third-party source, and
  remote binary/plugin packages
- sandbox or review posture for code-bearing third-party plugins

### Scripting Engine Interface

Source: origin note, v0.03 through v0.06 non-goals, and v0.09 boundaries.

The origin note leaves room for Lua, Python, JavaScript, or another scripting
interface. Elixir remains the runtime substrate for now; no scripting engine is
currently planned. v0.09 runs trusted, inventoried Agent Skill script
resources through `run_skill_script`; that does not graduate a general
scripting engine, dependency installer, or untrusted code runtime.
After v0.09, this boundary is tested capability rather than only planning:
trusted inventoried scripts may run after confirmation, but arbitrary language
runtime access, dependency bootstrap, and untrusted-code execution remain
future work.

Needed before planning:

- clear use cases that are not better served by Jido actions
- sandbox and dependency policy
- permission and confirmation integration
- trace and audit integration
- install/update story for runtime dependencies
- v0.26 eval coverage for script/package/resource bypasses

### Container And Remote Execution Sandboxes

Source: v0.08 planning and ADR 0009.

v0.08 intentionally implements only Level 1 local policy sandboxing: confirmed
host process execution through registered actions, Settings Central execution
policy, Security Central decisions, output limits, redaction, and trace/audit.
That is useful for a first local shell adapter, but it is not OS isolation and
should not be described as protecting the host from hostile code.

v0.36 implements the first narrow sandbox/gate backend for generated Elixir/OTP
drafts and explicit gate commands. It uses approved local images only, static
source-policy checks, copy-in/copy-out bundles, no default network, and a
doctor-gated backend resolver. `docker_runsc` / gVisor is preferred over plain
Docker when installed; Apple `container` is included only as an optional
doctor-gated macOS backend and is not release-blocking. Broader future work
should still add deeper execution backends when Allbert needs to run untrusted
scripts, package installs, broad coding workflows, online skill bootstrap,
multi-user workloads, or network-heavy adapters.

Candidate levels:

- Level 2 trusted project/process sandbox: still host execution, but with
  per-project execution profiles, stricter command/package-manager allowlists,
  scoped temp/work roots, and skill/action-specific env passthrough.
- Level 3 local container sandbox: Docker, Podman, Linux containers, Mac
  containers, or another local container backend with explicit bind mounts,
  non-root user policy, capability drops, resource limits, and network policy.
- Level 4 remote or microVM isolation: remote builders, cloud sandboxes, or
  microVM-backed execution for hostile code, untrusted imports, hosted
  deployments, or multi-user isolation.

Questions to resolve before graduation:

- which workflows require stronger isolation than Level 1
- whether later backends should add broader/cross-version Apple Container
  features, Firecracker, remote builders, hosted sandbox services, or explicit
  image-management workflows beyond v0.36's approved-local-image build/verify
  task
- how Allbert maps host paths to sandbox paths without over-mounting
  user-owned data
- whether workspace mounts are read-only, read-write, or copy-in/copy-out
- default network posture and how external service policy composes with it
- CPU, memory, process, disk, and wall-clock limits
- UID/GID, rootless mode, capabilities, seccomp/AppArmor availability, and
  macOS portability
- image provenance, update, vulnerability, and cache policy
- credential/env/file passthrough policy through Settings Central secrets
- how traces/audits represent host path, sandbox path, mount, image, backend,
  network, and resource-limit metadata
- cleanup, persistence, rollback, and recovery when a container or remote
  sandbox fails

v0.08 through v0.11 establish the local host-process and resource-access
baseline. v0.26 should show which real workflows cannot be made acceptable
with registered actions, Settings Central policy, Security Central,
confirmation, Level 1/Level 2 host controls, redaction, and audit alone.

This should become a versioned roadmap item only after security evals and real
operator traces identify a concrete workflow that needs deeper isolation.

## Review Cadence

Review this file when:

- closing a roadmap release
- adding a new roadmap milestone
- converting a non-goal into planned work
- discovering a repeated operator request that does not fit the current
  roadmap
