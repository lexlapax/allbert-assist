# Allbert Roadmap

This roadmap is the running planning index for Allbert. The long-term vision is
captured in `docs/plans/allbert-jido-vision.md`; implementation-ready milestone
plans live alongside this file. Identified but unassigned future work lives in
`docs/plans/future-features.md`.

`docs/plans/post-v0.10-implementation-tasks.md` and
`docs/plans/aiworkspace-plan.md` are superseded reference files retained only
for verification before deletion. This roadmap and the v0.xx plan files are
the canonical implementation sources.

For coding agents, this roadmap is the current planning index. Use
`CHANGELOG.md` for released behavior, ADRs for binding decisions, and active
milestone plans/request-flow docs for implementation details.

## Vision

Allbert is a personal assistant runtime that grows with its user. The core
direction is Elixir/OTP plus Jido: supervised processes, signal-driven
coordination, Jido agents for intent and delegation, Jido actions for validated
capabilities, and markdown-first memory that remains inspectable and portable.

Status: vision drafted.

## v0.01: First Local Assistant Loop

Plan: `docs/plans/v0.01-plan.md`
Request flow: `docs/plans/v0.01-request-flow.md`

Status: complete. Milestones 1 and 2 are complete and tested; Milestone 3 is
complete, tested, and operator-verified; Milestone 4 is complete, tested, and
operator-verified; Milestones 5, 5.1, 6, and 7 are complete and tested.

Summary:

- Clean the formatter/precommit baseline. Complete.
- Introduce a signal-first runtime boundary. Complete.
- Add the first primary intent agent. Complete.
- Add explicit Jido actions and a permission gate. Complete.
- Add markdown memory v0. Complete.
- Add deterministic personal preference heuristics. Complete.
- Record traces and basic cost/diagnostic metadata. Complete.
- Expose the same loop through CLI/REPL and Phoenix LiveView. Complete.

Current operator loop:

- `AllbertAssist.Runtime.submit_user_input/1` accepts local user input and
  emits `allbert.input.received` / `allbert.agent.responded` log signals.
- The default runtime path uses `AllbertAssist.Agents.IntentAgent` with a
  deterministic v0.01 action surface for direct answers, memory intent
  selection, skill inspection, and inert shell-command planning.
- `AllbertAssist.Security.PermissionGate` records explicit permission decisions
  for read-only work, memory-write intent, command planning, blocked command
  execution, and external network confirmation.
- `AllbertAssist.Memory` stores explicit memories as user-readable markdown.
  v0.01 used `ALLBERT_MEMORY_ROOT` or `var/allbert/memory`; v0.02 supersedes
  that default with `<ALLBERT_HOME>/memory` while preserving temp root
  overrides for tests and operator escape hatches.
- Basic identity and preference statements, such as "my name is Sandeep" and
  "I prefer short updates", flow through the same markdown memory path with
  conservative heuristics.
- When tracing is enabled, runtime turns write inspectable markdown traces under
  the memory `traces` category and return the trace path in `response.trace_id`.
- `mix allbert.ask` provides the first terminal entrypoint over the same runtime
  core.
- The `/agent` LiveView uses the same runtime boundary and displays the
  response, status, signal id, and trace path when available.

Exit signal: Allbert can remember something, recall recent memory, explain or
select a safe action, and leave an inspectable trace from both CLI and web UI.

Next milestone: v0.02 Allbert Home, Settings Central, Secrets, And Operator
Profile.

## Dependency Reassessment After v0.01

The origin and vision both point at the same growth path: a small kernel first,
then operator settings, inspectable skills and actions, confirmations, jobs,
channels, memory curation, and only later richer intent or more autonomous
execution.

v0.01 completed the first kernel slice. The important remaining foundation is
not more UI, embeddings, or command execution. The next missing layer is a
canonical Allbert home, a settings engine, and then skills compatibility plus
durable capability contracts:

- where durable local runtime data lives
- which settings exist, who changed them, and which layer supplied them
- which user-supplied provider credentials are configured, without exposing
  raw secret values
- which provider/model profiles exist
- which skills exist
- where they came from and whether the source is trusted
- what `SKILL.md` instructions and bundled resources they expose
- which Allbert/Jido actions they are allowed to invoke, if any
- which permissions those actions require
- which confirmations are needed
- what memory and trace effects they produce
- how those capabilities appear to the intent agent, CLI, LiveView, jobs, and
  future channels

That contract should come before scheduled jobs, richer automation, external
network access, shell execution, or autonomous skill creation. Otherwise those
features will each invent their own private capability rules.

Dependency order from here:

1. Allbert Home plus Settings Central, secrets, provider/model profiles, and
   operator profile.
2. Agent Skills-compatible parsing, discovery, trust, and activation.
3. Jido Runtime Convergence so internal runtime/domain operations share
   signals, agents, action boundaries, and lifecycle metadata.
4. Security Central as the shared policy, risk, redaction, audit, and trust
   boundary evaluator.
5. Action-backed Allbert skills and capability translation.
6. Confirmation workflow for sensitive capabilities.
7. Local execution sandbox and confirmed shell execution.
8. Trusted skill script execution through the same sandbox.
9. External service, package-install, online skill import adapters, and the
   first resource access security posture substrate across local and remote
   resources.
10. Execution-aware intent decisions, Approval Handoff, and resource access
    consumers over real risky capabilities.
11. Local workspace identity and SQLite conversation history.
12. Scheduled jobs that emit signals into the same runtime.
13. Session scratchpad and minimal app registration.
14. Additional channels that translate messages into the same runtime.
15. Plugin contract and shipped source-tree channel plugins so developer
    extensions have one discovery and registration path.
16. Full app/surface contract: `CoreApp` becomes the first `SurfaceProvider`
    (declaring the built-in chat surface), channels default to
    `active_app: :allbert`, and the contract is ready for StockSage to
    implement from day one.
17. Cross-surface intent enrichment over real skills, actions, permissions,
    confirmations, jobs, channels, existing memory metadata, app context, and
    registered surface metadata.
18. StockSage as the first plugin-contributed workspace app, implementing the
    full app/surface contract from day one through the plugin layer.
19. Memory review, summarization, and retrieval improvements.
20. StockSage Python bridge bringing real analysis results into Allbert.
21. Jido State-Machine Convergence: convert `Confirmations.Store` and
    `Jobs.Scheduler` from plain `GenServer` to `Jido.Agent` so the runtime
    substrate is consistent with the original Jido vision before the
    objective runtime ships. Pure refactor; no new user-visible features.
22. Objective Runtime Foundation: shared durable layer for multi-step,
    multi-turn work. `Objectives.Engine` as a Jido.Agent built on the
    converged substrate; `objectives`/`objective_steps`/`objective_events`
    SQLite tables; `objective_id`/`step_id` threaded through confirmations,
    jobs, and StockSage `RunAnalysis`.
23. Native financial specialist agents as the second analysis engine,
    consuming objective state from day one so both engines are available before
    StockSage web surfaces are built. These are reusable delegate agents, not
    a one-for-one Python graph clone.
24. Workspace shell upgrade: `CoreApp`'s surface transitions from the
    rudimentary `/agent` prompt to a signal-driven LiveView workspace with
    canvas and ephemeral UI substrate.
25. Workspace UX closeout for the few core `/agent` polish items deferred from
    `0.26.1`, without changing the workspace contract.
26. App Surface Contract: StockSage LiveViews built on the Surface DSL, proving
    the plugin-contributed app surface pattern on top of the workspace shell.
    StockSage is the reference implementation, not a special case.
27. Security hardening and evals after real execution, import, channel, job,
    memory, intent, app, workspace, surface, objective, and financial-
    analysis behavior exists.
28. App Memory + Outcomes Contract: StockSage polish, outcomes, trends, and
    explicit memory sync through the namespace declared before security evals.
29. App Canvas Contract: StockSage canvas integration wiring proven components
    into durable `/agent` tiles through the audited workspace canvas mechanism.
30. v0.31 Runtime and UI-substrate consolidation: action DSL, typed responses,
    shared path/redaction/audit/persistence facades, unified surface catalog
    and extension registry, and settings schema fragments.
31. v0.32 Workspace-only app UI: `/workspace` becomes the operator home, app UI moves
    into host-owned workspace panels, and Settings Central becomes a workspace
    utility panel.
32. v0.33 Conversational app intent handoff and direct-answer foundation:
    neutral workspace requests can propose explicit app handoff or ask
    clarification without silently executing app actions.
33. v0.34 Workspace UX refresh: a chat-centered shell, a view-only left
    launcher, a single-destination Canvas, and routing context set
    conversationally through the v0.33 handoff.
34. v0.35 User theming and layout overrides from Allbert Home after the workspace
    panel/zone contract and app-intent descriptor path are proven.
35. v0.36 Elixir/OTP sandbox and gate runner: a default-off, OS-aware sandbox
    (static reviewed backend registry + `"auto"` resolver — optional
    doctor-gated Apple `container`, rootless Podman, Docker+runsc/gVisor
    preferred over plain Docker, Docker fallback) for generated Elixir/OTP
    drafts and explicit reviewed `mix` gate commands, with approved local
    images only, facade-level source-policy checks, copy-in/copy-out bundles,
    no network/secrets/real-home access, bounded reports/audit, and no live
    loading.
36. v0.37 Dynamic code & config generation and live capability integration:
    implements ADR 0021's reserved capability-gap/acquisition vocabulary, lets
    LLM agents generate to proven shapes, trials project-shaped drafts through
    the v0.36 sandbox, and — after the warning gate plus operator confirmation
    — hot-loads into the live runtime without a restart (audited, reversible).
37. v0.38 Templated creation: vetted plugin/app/LLM-tool/scheduled-flow/code
    templates via Mix tasks, operator workspace flows, and a Canvas Create
    surface, reusing the v0.36 sandbox and v0.37 loader.
38. v0.39 First-run onboarding and provider control: guided operator setup
    over existing objectives/actions/settings, model/provider selection,
    explicit `providers.*.endpoint_kind` field, two-branch provider doctor
    (credentialed-remote + local-endpoint) with shared redacted return shape
    pinned by ADR 0047, optional channel registration, optional
    `intent.model_assist_enabled` toggle, default-profile hygiene fix, and
    cross-OS first-run smoke (macOS, Linux, Windows/WSL2). Active Memory and
    identity slot moved to v0.39b.
39. v0.39b Identity slot and Active Memory: implemented as `0.39.1`.
    Optional inert `identity` memory namespace declared through a new
    system-namespace declarer, `:identity` added as a 5th `Memory` category,
    plus deterministic direct-answer `:kept` memory retrieval scoped to
    `{thread_id, active_app, identity}` with `## Active Memory` trace
    metadata. Algorithm spec'd in `docs/research/active-memory-retrieval.md`.
40. v0.40 MCP client integration: explicit MCP server configuration and secret
    refs, `:mcp_tool_call` / `:mcp_resource_read` permission classes, `mcp://`
    promoted to a supported Resource Access adapter, HTTP/SSE + stdio
    transports, and registered MCP actions (doctor/list/read/call) under
    Security Central. The substrate v0.42 panels consume.
41. v0.41 Developer Velocity and Parallel Test Methodology: make Allbert's
    development gate match the OTP/concurrency vision before more feature
    surface area lands. Adds ADR 0049, a test strategy guide, a gate matrix,
    resource-lane taxonomy, and a decision-complete isolation/migration plan for
    parallel precommit work. No operator-facing assistant capability.
42. v0.42 Tool Discovery + MCP-first Integration Pack 1: implemented as
    `0.42.2`. `find_tools` capability search (local tools + internet MCP
    registries behind a provider port) with a confirmation-gated connect gate
    and an opt-in, passive background scan. Calendar, Mail, and GitHub ship as
    MCP-configured workspace panels; `notes/files` ships as the native reference
    plugin and starter scaffold for plugin authors (does NOT replace StockSage
    as the depth reference). Closeout hardens the discovery permission boundary,
    live connected-server baseline, CLI connect contract, notes/files metadata,
    submitted effect arguments, and deterministic release gate. Native
    integration plugins for the other three are post-1.0 follow-on.
43. v0.43 Browser and web research: browser-session Resource Access policy,
    sandboxed browser plugin, research/extract/screenshot actions, and bounded
    HTML/markdown/text/PDF extraction.
44. v0.44 Plan/Build mode and operator workflow YAML: workspace and existing
    channel UX
    over Objective Runtime, declarative workflow input (lives under
    `<ALLBERT_HOME>/workflows/`), plan preview, and subagent delegation
    visibility.
45. v0.45 Marketplace lite — implemented as `0.45.0`: local reviewed catalog
    schema, Allbert-author seed bundles, provenance/hash/version/rollback
    metadata, disabled/untrusted installs, browse-only plugin index metadata,
    workspace/intent/CLI surfaces, and marketplace doctor. Community-submission
    governance remains parked. Started the v0.59 ADR for settings schema
    migration policy (ADR 0046).
45.1. v0.45.1 Gate Transparency and Precommit Decomposition — implemented as
    `0.45.1`: commit/prepush/release command split, timed direct release
    phases, redacted gate evidence, and `mix precommit` as commit-time
    feedback rather than release evidence.
46. v0.46 Delegation hardening + research specialist — implemented as
    `0.46.0`: second native delegate-agent consumer, a plugin-contributed research/summarize
    specialist at `./plugins/allbert.research/` — so the v0.24
    `AgentRegistry`/`delegate_agent` contract is proven against two domains
    (finance + research) before the v1.0 freeze (ADR 0021 amendment A21).
    No new authority: the agent orchestrates shipped v0.43 browser actions
    through `Actions.Runner.run/3`; v0.46 also hardens allowlisted delegate
    command strings and documents the extension point so plugin authors can
    register their own. Operator no-code agent authoring stays parked.
47. v0.47 Operator-supervised self-improvement (discovery + local drafts) -
    implemented as `0.47.0`: a read-only trace index, the generalized v0.42
    suggestion surface, a read-only pattern-discovery action, and
    skill/workflow/memory drafts in one unified reviewed-draft store; no
    autonomous authority.
47b. v0.47b Operator-supervised self-improvement (handoff drafts) -
    implemented as `0.47.1`: template-backed, marketplace-backed, inert
    delegate-plugin, capability-gap, and objective drafts that hand off to the
    v0.36/v0.37/v0.38 sandbox/gate/templated-creation path; seven `:v047b`
    eval rows and `release.v047b`; no new trust tier.
48. v0.48 Voice modality and provider capabilities - implemented through
    M8R real-provider remediation and M8R7 local voice runtime remediation.
    The release includes capability-aware provider/model profiles, ranked
    operator preferences, fixture STT/TTS for tests only, CLI file
    transcription, workspace microphone capture, TTS, Telegram voice-note
    ingestion, executable local adapter calls, OpenAI remote STT/TTS, Gemini
    remote STT/TTS, an Ollama-backed local text turn in the voice loop, 16
    `:v048` voice-modality eval rows, and expanded `release.v048` coverage.
    M8R7 adds the Allbert-owned local voice runtime endpoint. Manual `.env`
    live smokes remain the release handoff before tag. Fake providers are
    fixture-only. Discord voice is
    deferred to a focused follow-on after Channel Pack 1.
49. v0.49 Vision and image generation - implemented as 0.49.0: consumes the
    v0.48 provider capability substrate for image/screenshot resource classes,
    vision model profile checks, image-generation actions, workspace rendering,
    retention, redaction, display-only cost metadata, 8 `:v049`
    vision-modality eval rows, and `release.v049`.
50. v0.50 Artifacts Central: a uniform content-addressable store for artifacts
    uploaded by the operator, created by Allbert, or found through approved
    tools, deduplicated by content hash with provenance/type/retention metadata,
    linking artifacts to the threads/messages that created them, backfilling
    retained v0.48 audio, v0.49 vision-input, and v0.49 generated-image roots,
    excluding historical Browser cache, and adding the first supervised
    `Jido.Sensor` ingestion path. Identity is content-addressed; Security
    Central and Resource Access remain the authority boundary.
    v0.50b Artifacts Browser ships the operator browsing repository (workspace
    panel + `/apps/artifacts/<sha>` page + `mix allbert.artifacts` CLI) as a
    plugin/app (`allbert.artifacts`) over the core read actions.
51. v0.51 Public Protocol Surfaces (expanded full release; resequenced ahead of
    the channel packs): exposes registered actions as MCP tools and memory
    namespaces as MCP resources, plus an OpenAI-compatible HTTP API and an ACP
    server surface. Public AG-UI/A2UI bridge stays parked post-1.0.
52. v0.52 Channel Pack 1 (Discord and Slack) + ADR 0016 amendment for the
    channel approval-primitive contract (`{list, button, typed_command, link}`).
    Locks the channel approval shape before mobile channels need it.
53. v0.53 Channel Pack 1 retro-validation (Telegram + email, first real-provider
    live validation) then Channel Pack 2 — WhatsApp, Signal, and Matrix. iMessage
    is parked (macOS-only platform constraint). Note: live validation (2026-06-16)
    found the channel *approval* workflow dead-ended in the intent router, so v0.54
    was resequenced ahead to fix it; Telegram/email/Matrix manual checks now pass.
M11 adds capability release availability (ADR 0066): WhatsApp and Signal are
implemented but not released for live use in v0.53 because their provider/
bridge onboarding is too high-friction for the release bar. Discord/Slack remain
released from v0.52; both passed v0.53 M11 closeout regression after M11 shared
channel plumbing changes. That does not make either channel new v0.53 feature
scope.
54. v0.54 Intent Deepening: a local-first **two-stage intent router** (embedding
    prefilter → constrained LLM disambiguation → confidence gate; ADR 0060/0061)
    as the default selector, plus the original deepening (multi-turn context,
    generalized disambiguation, clarification turn-state; ADR 0019/0034) — and it
    **removes the app-handoff channel dead-end** so a channel message reaches the
    approve/deny gate. Expanded 2026-06-16 (post-validation) to also carry **M9 —
    intent descriptor lifecycle foundation** (coverage across the action surface +
    data-only YAML descriptor/vocabulary generation, dynamic-codegen reindex hooks,
    operator YAML curation, and a comprehensive golden-set; ADR 0062) and
    **M10 — outbound compose actions** (send_email / send_channel_message /
    create_calendar_event via MCP; ADR 0063); M9+M10 are in v0.54 and gate the tag.
    The advanced ADR 0062 self-optimizing pieces move to v0.56.
    Resequenced ahead of completing v0.53 (its channel approval workflow depends on
    the router) and before the v0.58 UX redo (chat quality depends on intent).
55. v0.55 Channel Parity + TUI/Terminal Channel: explicit channel capability/
    parity matrix and a proper TUI/terminal channel under the ADR 0016 contract
    (list-shaped identity map, dedupe, approval primitives, a basic
    `mix allbert.tui` launcher), not just `mix allbert.ask`. Harvests Pi's split
    tool result (`model_payload` vs. `surface_payload`; ADR 0029/0030), plus
    scrollback rendering and a transient Owl status/live block that v0.57 can
    extend with its own streamed diff renderer. ADR 0067.
55.1. v0.55.1 TUI Operator/Validation Console: makes the v0.55 TUI the persistent,
    mix-free operator/validation console — in-TUI slash-commands (`/status`,
    `/confirmations`, `/events`, `/channels`, `/settings get`, `/help`) and
    `mix allbert.channels status`, each backed by registered **read-only internal**
    inspection actions, reachable only through the slash-command allowlist or their
    explicit Mix task twin, never intent candidates, resolved through
    `Actions.Runner.run/3`. Migrates interactive operator validation onto one warm
    BEAM (no cold per-turn `mix` calls). Point release; arc unchanged. ADR 0070.
56. v0.56 Intent Descriptor Learning + Registration Lifecycle Completion:
    completes ADR 0062 with local-model descriptor generation, learned-review
    proposal mining from reviewed runtime evidence, operator-callable
    `optimize_intent_descriptors`, full app/plugin/action registration reindex
    signals, the ADR 0071 blocking routing-accuracy gate, and ADR 0072
    per-purpose model recommendations. Model/learned proposals remain inert
    until operator promotion and never grant authority.
57. v0.57 Pi-mode Coding Surface: a gated terminal coding surface on the one
    authority spine — a **six-tool** default (read-only/sensitive
    read/grep/glob + effectful write/edit/bash) through
    `Actions.Runner.run/3`, sub-1000-token prompt+tool-defs budget, chunked-read
    context discipline, **coder-ergonomics parity** with Claude Code / Pi /
    Codex / Gemini CLI (approval modes as a `Security.Decision` confirmation-cost
    seam + per-repo "always allow" reusing `Resources.Grants`, assistant-text token
    streaming + progressive diff streaming over the v0.55 static split on a new
    async turn-execution boundary that enables real Esc-to-cancel + queued steering,
    coding slash set with `/model`/`/clear`/`/compact` ungated), and a named
    "local-coding operator" trust tier (ADR 0056 lineage at ADR 0009 Level 1, not
    "level 0"). Never YOLO-by-default, never for channel-originated or
    generated-code sessions; modes/grants grant no authority; deterministic
    acceptance gates and Security Central stay intact. Milestones M0–M9. ADR 0068;
    rationale in `docs/archives/pi-integration-rethink.md`; operator handoff in
    `docs/operator/pi-mode-coding.md`.
58. v0.58 Web UX Redo + Surface Policy: re-layout `/workspace` (ADR 0023/0024
    kept) — chat primary, ephemeral surfaces become popups, canvas demoted,
    labels cleaned up ("Conversations" replaces "threads"); references
    ChatGPT/Claude/Hermes. Adds operator-managed surface policy for
    raw-vs-summary report shape, redaction/display bounds, and explicit operator
    affordances. Sequenced after intent (v0.56) and the channel/console/coding
    surfaces (v0.55/v0.55.1/v0.57) so chat quality is mature first.
59. v0.59 Hardening, export/import, settings schema migration substrate,
    operator onboarding simplification, and final RC: no new user-facing
    capability; Allbert Home portability, cross-surface security eval sweep,
    operator docs, performance hardening, CSP reconciliation, settings schema
    migration tool (per ADR 0046), central action param-contract enforcement
    (M7, ADR 0065; precursor v0.54 ADR 0064), a genuinely easy first-run
    operator onboarding path over the existing settings/secrets/channel-pairing/
    doctor flows surfaced through the v0.55.1 TUI console (ADR 0069), and
    release-candidate closeout.
60. v1.0 Stability release and **tiered public contract freeze**: no new
    features; freeze Tier 1 (Runtime, Actions/permissions, Plugin, App,
    Settings Central schema shape, Allbert Home layout, Channel adapter
    boundary, Resource Access URI/grants) and Tier 2 (SurfaceProvider, Surface
    DSL with additive-only carve-out, workspace canvas/ephemeral substrate
    minus single-consumer components).

`config.exs` remains deployment and boot configuration. It should not become
the user/operator settings surface. `ALLBERT_HOME` is bootstrap configuration:
the local root for settings, encrypted secrets, memory, database files, user
skills, caches, and temporary runtime data. Allbert needs a domain settings
engine that can be read and changed through CLI, LiveView, future channels, and
traces. The current runtime dependency set is almost enough, but direct YAML
parse/write dependencies are reasonable v0.02 dependencies if settings use
YAML; v0.03 will need YAML parsing for Agent Skills frontmatter anyway. Jido
remains the right substrate, `Req` remains the preferred HTTP client for
external adapters, and scripting should enter only as confirmed action-backed
execution, not as ambient authority from a skill declaration.

## v0.02: Allbert Home, Settings Central, Secrets, And Operator Profile

Plan: `docs/plans/v0.02-plan.md`
Request flow: `docs/plans/v0.02-request-flow.md`

Status: complete.

Expected direction:

- Add `AllbertAssist.Paths` and make `ALLBERT_HOME` the canonical local root,
  defaulting to `~/.allbert` with `ALLBERT_HOME_DIR` as an accepted alias.
- Store settings, encrypted secrets, memory, local database, user skills,
  imported caches, and temporary runtime data under Allbert Home by default.
- Add a typed, file-backed settings subsystem for user/operator domain
  settings.
- Keep deployment config in `config.exs` and environment variables.
- Store user-supplied API keys through the Settings Central secret store,
  encrypted at rest and redacted everywhere they are displayed.
- Add layered settings resolution: defaults, deployment overrides, operator,
  project, channel, and request/session.
- Add settings namespaces for operator profile, runtime, providers, model
  profiles, skills, permissions, channels, jobs, and memory policy.
- Expose settings through runtime actions plus CLI and LiveView surfaces.
- Validate and audit settings writes.

Exit signal: Allbert has one local home directory and one operator-facing
settings center that can be used by CLI, LiveView, future channels, skill
trust, confirmation policy, jobs, and memory review without scattering paths or
settings across subsystems.

## v0.03: Agent Skills Substrate

Plan: `docs/plans/v0.03-plan.md`
Request flow: `docs/plans/v0.03-request-flow.md`

Status: released as v0.03. Milestones 1 through 6 are complete and tested.
v0.04, Jido Runtime Convergence Refactor, has since been released.

Expected direction:

- Adopt the open Agent Skills `SKILL.md` folder format as Allbert's external
  and native skill authoring format.
- Add the substrate that parses standard skills into internal skill records,
  activation context, trust state, resource inventories, and diagnostics.
- Load built-in, project, user, and imported skills from predictable
  Agent-Skills-compatible directories.
- Route list/read/activate skill behavior through the registry instead of the
  current static in-code list.
- Use a dedicated `activate_skill` action/tool so Allbert can enforce trust,
  wrap instructions, list resources, and trace activation.
- Keep bundled scripts and external package installation non-executable in
  v0.03; they may be inspected, planned, and traced, but not run.
- Parse Allbert-specific metadata as inert contract data, but do not yet use it
  to drive action execution.

Current implementation:

- `AllbertAssist.Skills.Parser` parses standard Agent Skill directories with
  `SKILL.md` YAML frontmatter and markdown bodies.
- `AllbertAssist.Skills.AgentSkillSpec` stores parsed manifests, optional
  metadata, body text, external fields, diagnostics, and inert resource
  inventory.
- `AllbertAssist.Skills.Resource` inventories files under `scripts/`,
  `references/`, and `assets/` without execution.
- Parser tests cover valid standard skills, Allbert metadata, invalid YAML,
  missing required fields, duplicate names, resources, and scripts.
- `AllbertAssist.Skills.Registry` discovers bounded skill directories, applies
  trust and enablement policy, resolves duplicates, reserves built-in names,
  and reports skipped declarations through diagnostics.
- `AllbertAssist.Skills.Skill` and
  `AllbertAssist.Skills.CapabilityContract` represent normalized skill records
  and inert Allbert metadata contracts.
- Settings Central now validates and writes `skills.scan_paths`,
  `skills.trusted_project_roots`, `skills.enabled`, `skills.disabled`, and
  `skills.imported_cache_policy`.
- `list_skills` and `read_skill` use the registry.
- Built-in skill wrappers now live under `apps/allbert_assist/priv/skills/`
  as standard `SKILL.md` declarations with inert Allbert metadata. The
  temporary `:built_in_legacy` bridge remains only as a defensive fallback when
  no built-in declarations are packaged.
- `activate_skill` loads trusted skill instructions through progressive
  disclosure, returns resource inventory metadata, preserves inert capability
  contracts, and refuses missing or hidden skills with a structured not-found
  response.
- Traces now render selected skill metadata explicitly in the runtime turn
  header and in a dedicated `## Skill Metadata` section.
- CLI and LiveView operator tests cover registry-backed skill list/read and
  activation through the shared runtime boundary.

Exit signal: Allbert can discover standard Agent Skills, activate their
instructions through progressive disclosure, show source/trust/diagnostics, and
trace skill activation without granting any new unsafe capability.

Exit status: complete.

## v0.04: Jido Runtime Convergence Refactor

Plan: `docs/plans/v0.04-plan.md`
Request flow: `docs/plans/v0.04-request-flow.md`
ADR: `docs/adr/0007-jido-native-internal-runtime-boundaries.md`

Status: released as v0.04.

Implemented direction:

- Adopt Boundary Actions as the runtime rule: externally invoked, effectful,
  security-relevant, or observable domain operations enter through signals,
  internal agents or runtime routers, and registered Jido actions.
- Keep pure parsing, schema, validation, formatting, and storage helpers as
  plain Elixir behind action boundaries.
- Add the shared action runner that emits consistent
  `allbert.action.requested` and `allbert.action.completed` metadata.
- Remove direct-call debt in `IntentAgent`, Settings LiveView,
  `mix allbert.settings`, and runtime trace recording.
- Add action-backed settings/model/provider surfaces and an internal
  `record_trace` action while keeping pure modules plain.
- Add no new execution powers.

Exit signal: Allbert's docs and implementation plan make the Jido boundary
mandatory for runtime-facing domain behavior without wrapping pure helper
modules in unnecessary agents.

Closeout signal: v0.04 kept user-visible behavior stable while routing
intent actions, settings surfaces, provider credentials, and trace recording
through registered actions and shared runner lifecycle metadata. v0.05
Security Central can consume this boundary without reopening the v0.04
architecture decision.

## v0.05: Security Central Foundation

Plan: `docs/plans/v0.05-plan.md`
Request flow: `docs/plans/v0.05-request-flow.md`
ADR: `docs/adr/0006-security-central.md`

Status: released as v0.05.

Implemented scope:

- Added Security Central as the shared security evaluation surface.
- Consumed the v0.04 action/runtime boundary instead of creating private
  security policy paths in CLI, LiveView, jobs, or channels.
- Kept Settings Central as policy and secret storage; Security Central reads
  settings, skill trust, secret status, and runtime context.
- Defined security context, decisions, policy resolution, risk tiers, redaction,
  audit event shape, trust/provenance summary, and operator-visible security
  status.
- Kept `AllbertAssist.Security.PermissionGate.authorize/2` as a compatibility
  entrypoint that delegates to Security Central while preserving current
  fields and behavior.
- Preserved v0.04's existing action runner and lifecycle signals; v0.05 widens
  decision metadata rather than replacing the runner.
- Added built-in safety floors so Settings Central can tighten policy but cannot
  prematurely grant shell, script, package-install, network, online-import, raw
  secret-read, unknown-action, or unknown-permission authority.
- Added Security & Permissions status to `/settings`: permission settings remain
  editable through Settings Central actions, while effective Security Central
  decisions, safety floors, trust, secret status, and redaction posture are
  displayed read-only.
- Added no new execution powers.

Exit signal: Allbert can make and explain structured security decisions with
permission, risk, confirmation, redaction, audit, trace, actor/channel/session,
selected skill/action, and trust boundary metadata.

v0.06 handoff: action-backed skills should consume the implemented
`AllbertAssist.Security` decision shape, selected skill trust/provenance
context, registered action metadata, known permission classes, and safety-floor
capped Settings Central policy. Skill metadata still never grants permission by
itself.

## v0.06: Action-Backed Allbert Skills

Plan: `docs/plans/v0.06-plan.md`
Request flow: `docs/plans/v0.06-request-flow.md`

Status: released as v0.06 on 2026-05-02. Milestones 1 through 6 are complete
and tested.

Release tag: `v0.06`.

Expected direction:

- Promote trusted Allbert metadata overlays from inert capability contracts
  into validated action bindings.
- Map capability skills only to registered Jido actions and known Security
  Central permission classes.
- Treat built-in Allbert skills as standard `SKILL.md` wrappers around
  registered Elixir/Jido actions; do not auto-convert skill files or scripts
  into executable modules.
- Use the existing v0.04 action lifecycle runner that emits
  `allbert.action.requested` and `allbert.action.completed`.
- Wire action-backed built-in skills through the current conservative intent
  routing while preserving v0.01 safety behavior.
- Keep trusted non-built-in capability candidates validation-first unless an
  explicit deterministic router binding exists for their action and parameter
  shape.
- Keep `activate_skill` as progressive-disclosure context loading; activation
  does not execute the activated skill's declared action.
- Add the first Allbert skill creation/validation workflow for standard
  `SKILL.md` directories that reference only existing registered action names
  and known permission classes. Complete for local operator helpers through
  `mix allbert.skills`, registered helper actions, and the `:skill_write`
  Settings Central/Security Central policy surface.

Current implementation:

- Action capability metadata and contract validation are implemented through
  `AllbertAssist.Actions.Registry`, `AllbertAssist.Actions.Capability`, and
  `AllbertAssist.Skills.CapabilityContract`.
- Registry list/read/activation output surfaces contract validation and keeps
  invalid contracts inspectable but non-executable.
- Deterministic built-in routes validate selected skill/action contracts before
  invoking `Actions.Runner.run/3`.
- Runner, signal, trace, and Security Central metadata include selected skill,
  contract validation, action capability, permission decision, risk, and
  outcome context.
- `validate_skill` and `create_skill` are registered operator helper actions;
  they are intentionally excluded from the intent-agent tool surface.
- Local skill scaffolds write only standard `SKILL.md` files and do not create
  scripts, modules, package manifests, network adapters, online imports, or
  trust escalation.

Exit signal: Allbert can explain, activate, and run action-backed built-in
skills through registered Jido actions with Security Central decisions and
trace metadata, while still refusing or deferring unsafe execution.

v0.07 handoff: confirmation workflow should consume the v0.06 action
capability metadata, selected skill contract summaries, `:skill_write`
permission policy, and existing external-network confirmation requirement
without moving shell, script, package-install, network, or import execution
forward prematurely.

Closeout signal: v0.06 passed focused milestone tests, closeout `rg`
architecture checks, operator smoke against a disposable Allbert home,
`mix compile --warnings-as-errors`, `mix format --check-formatted`,
`mix credo --strict`, `mix dialyzer`, and `mix precommit`.

## v0.07: Confirmation Workflow

Plan: `docs/plans/v0.07-plan.md`
Request flow: `docs/plans/v0.07-request-flow.md`
ADR: `docs/adr/0008-durable-confirmation-requests.md`

Status: released and tagged as `v0.07` on 2026-05-02.

Expected direction:

- Add durable pending capability requests for registered actions that receive a
  Security Central `:needs_confirmation` decision.
- Store confirmation records under Allbert Home with redacted params, selected
  skill/action/capability metadata, Security Central decisions, runner/signal
  context, origin channel, resolver channel, trace ids, and audit links.
- Add Settings Central confirmation preferences for TTL, expiration, display,
  and enabled approval surfaces.
- Let CLI and LiveView list, show, approve, deny, and expire the same pending
  requests through registered Jido actions and `Actions.Runner.run/3`.
- Re-check Security Central on approval and resume only the original eligible
  registered target action. Approval of unavailable adapters records
  `adapter_unavailable` and performs no target side effect.
- Treat CLI and LiveView as the first two channels in a channel-aware workflow:
  requests remember where they originated, resolutions remember where they
  happened, and future channels consume the same queue.
- Persist requested, approved, denied, expired, and adapter-unavailable
  outcomes in traces and human-inspectable audit records.
- Keep command execution, skill scripts, package installs, online imports, and
  real external network calls inert.

Milestones:

- M1: complete. Confirmation domain, Allbert Home paths, store, Settings
  Central keys, and ADR alignment.
- M2: complete. Registered confirmation actions and
  `mix allbert.confirmations` CLI.
- M3: complete. Pending creation from confirmation-needed actions, starting
  with `external_network_request`.
- M4: complete. Approval resume semantics, target policy re-check, and
  adapter-unavailable behavior.
- M5: complete. LiveView confirmation surface over the same action boundary.
- M6: complete. Trace, audit, cleanup, release docs, version metadata, and
  release gate.

Exit signal: Allbert can pause sensitive registered actions as durable pending
requests, let the operator approve or deny them from CLI or LiveView, record
the result in traces/audit, and still avoid any new risky execution adapter.

Closeout signal: v0.07 passed focused milestone tests, full warning gates,
precommit, diff checks, and disposable-home operator smoke. The app versions
are bumped to `0.7.0`. External-network approvals resolve as
`adapter_unavailable` with operator-facing output that explains the approval
was recorded but no adapter ran; v0.08 should replace that baseline only for a
registered confirmed shell adapter with sandbox policy.

## v0.08: Local Execution Sandbox And Shell Adapter

Plan: `docs/plans/v0.08-plan.md`
Request flow: `docs/plans/v0.08-request-flow.md`
ADR: `docs/adr/0009-local-execution-sandbox-levels.md`

Status: released and tagged as `v0.08` on 2026-05-02.

Expected direction:

- Add the first real local execution boundary for confirmed shell commands:
  Level 1 local policy sandboxing, not OS/container isolation.
- Represent shell execution as registered Jido actions, not as skill metadata
  or arbitrary model authority.
- Restrict executable/argv, working roots, environment access, timeout, output
  capture, and destructive ambiguity through Security Central and Settings
  Central policy.
- Cover local shell execution as a general command framework: conservative
  default read-only commands plus explicitly operator-profiled local developer
  commands, all still confirmed and policy checked.
- Require the v0.07 confirmation flow for command execution and record redacted
  stdout/stderr, security decisions, and sandbox metadata in traces.
- Add a local runner adapter boundary so later Docker, Podman, Mac/Linux
  container, remote, or microVM backends can be introduced without changing the
  action, confirmation, Security Central, Settings Central, trace, or audit
  contracts.

Milestones:

- M1: Sandbox ADR, Settings Central execution policy, command spec, and
  conservative classification.
- M2: Level 1 local process runner with explicit executable/argv, cwd, env
  allowlist, timeout, output cap, and redaction.
- M3: Registered `run_shell_command` action and v0.07 confirmation resume.
  Complete in implementation: shell approvals now resume only the shell target
  after Security Central re-check and record target result metadata.
- M4: CLI and `/settings` operator surfaces over the same action boundary.
  Complete in implementation: `mix allbert.exec`, prompt routing,
  confirmation display, and `/settings` now expose shell command/result
  metadata without bypassing actions.
- M5: Trace, audit, release docs, version metadata, focused tests, and final
  warning gates.
  Complete in implementation: trace/audit metadata, version `0.8.0`, release
  docs, and gates are ready for release/tag.

Exit signal: Allbert can execute an explicitly confirmed shell command through
a registered action, inside a bounded Level 1 local policy sandbox, with denial
defaults, redacted output, and inspectable trace/audit records. It does not
claim Docker/Podman/container/microVM isolation in this release.

Status: v0.08 is released and tagged as `v0.08`.

## v0.09: Skill Script Runner

Plan: `docs/plans/v0.09-plan.md`
Request flow: `docs/plans/v0.09-request-flow.md`
ADR: `docs/adr/0010-resource-gated-skill-script-execution.md`

Status: accepted for operator/user testing. Release tag is `v0.09`.

Expected direction:

- Add a confirmed `run_skill_script` path for trusted, enabled, inventoried
  Agent Skill scripts.
- Add `:skill_script_execute` permission with a confirmation safety floor and
  `execution.skill_scripts.*` Settings Central policy.
- Resolve script paths only from the selected skill's v0.03 resource inventory,
  and re-check the resource digest before pending creation and before approved
  execution.
- Run scripts through v0.08 Level 1 host-process controls and v0.07
  confirmation workflow, adding skill provenance, script path, digest, cwd,
  env, timeout, output, and capability-contract checks before execution.
- Keep direct executable script resources as the first launch mode. Interpreter
  profiles must be explicit Settings Central policy, not broad file-extension
  authority.
- Keep `run_skill_script` separate from `run_shell_command`; it owns
  selected-skill, resource-inventory, digest, and script launch policy while
  reusing lower-level v0.08 timeout/output/redaction/audit helpers where useful.
- Continue to forbid runtime module loading, package installs, external service
  calls, generic scripting engines, imported-skill auto-enable, and
  non-inventoried script execution.
- Preserve the sandbox caveat: Level 1 host execution is not network,
  container, remote, or microVM isolation.

Milestones:

- M1: ADR, Security Central permission, Settings Central policy, capability
  metadata, and active-doc onboarding updates.
  Complete in implementation: M1 added the `:skill_script_execute` policy
  vocabulary, `execution.skill_scripts.*` settings, ADR 0010, and registered
  non-executing `run_skill_script` capability metadata.
- M2: Resource-gated script spec with skill trust, exact inventory match,
  path validation, digest re-check, cwd/env/limit validation, and redacted
  summaries.
  Complete in implementation: M2 added `AllbertAssist.Execution.SkillScriptSpec`
  and connected `run_skill_script` to the inert resolver, so valid trusted
  script requests now produce auditable metadata while disabled, untrusted,
  missing, non-script, hidden, path-escaping, digest-drifted, non-executable,
  cwd/env/limit, and path-like-arg violations are denied before confirmation.
- M3: Registered `run_skill_script` action with durable pending creation,
  confirmation resume, policy re-check, digest re-check, and idempotent
  resolution, consuming the M2 spec and stored expected digest instead of
  trusting client-supplied paths or summaries.
  Complete in implementation: M3 creates pending confirmations, resumes through
  `approve_confirmation` and the shared action runner, re-checks Security
  Central and script digests, denies policy/digest drift before execution, and
  established the resume contract that M4 now uses for actual process running.
- M4: Script runner, execution audit, CLI surface, `/settings` confirmation
  metadata, trace metadata, and activation-stays-inert coverage.
  Complete in implementation: M4 replaced the temporary `runner_pending`
  handoff with the bounded skill script runner, shared output buffering,
  script audit events, CLI request/show/approve rendering, and `/settings`
  pending/resolved metadata for completed, failed, timed-out, truncated, and
  redacted script output.
- M5: Docs, future milestone handoffs, pre-release smoke matrix, focused
  tests, final gates, and release/tag readiness.
  Complete in implementation: M5 updated release docs, bumped version metadata
  to `0.9.0`, marked the Security status boundary implemented, preserved
  v0.10/v0.11 handoffs, and documented exact user-testing commands and tag
  readiness.

Exit signal: Allbert can run a bundled skill script only when the skill is
trusted, enabled, selected, inventoried, digest-verified, confirmed, bounded
by Level 1 host-process controls, audited, and traced.

## v0.10: External Services, Package Installs, Online Skill Import, And URI-First Resource Access Posture

Plan: `docs/plans/v0.10-plan.md`
Request flow: `docs/plans/v0.10-request-flow.md`
ADR: `docs/adr/0011-confirmed-external-capability-adapters.md`
Identity ADR: `docs/adr/0013-uri-first-resource-identity.md`

Status: M1-M14 implemented and focused verified. v0.10 was reopened
after M5 because post-M5 commits added online skill approval clarity/search
fixes and Resource Access Security Posture planning. M6 reconciles that
history, M7 implements shared resource reference metadata, M8 implements
Settings-backed remembered resource grant storage and matching, and M9 closes
the first release-readiness/user-testing refresh. A later zoom-out release
audit reopened v0.10 for M10-M14 closeout before release. M10
finished canonical resource identity hardening, and M11 added
remembered-grant operator UX plus application to existing v0.10 flows.
M12 added URI-first resource identity through
`AllbertAssist.Resources.ResourceURI` and required `resource_uri` grant
authority. M13 has added direct/local skill import consumers. M14 has added
explicit unsupported/deferred UX for v0.11-owned URL/document, MCP/agent,
broad browsing/crawling, and future channel-native approval workflows. v0.10
was released and tagged as `v0.10` on 2026-05-04.

Expected direction:

- Replace new v0.10 `external_network_request` approvals with a real confirmed
  `Req` adapter instead of `adapter_unavailable`, while preserving historical
  pre-v0.10 records.
- Add external service policy under Settings Central: enabled flag, service
  profiles, allowed hosts/methods/paths, timeout, response cap, redirect/retry
  policy, redaction, and credential refs.
- Add `:package_install` and `:online_skill_import` permission classes with
  high-risk classification and confirmation safety floors.
- Add package install planning and confirmed package-manager execution through
  profiles, not shell strings. npm is the first executable profile; pip remains
  preview/audit-only unless strict hash, binary, pinned requirement, and target
  policy are implemented and tested.
- Add skills.sh or remote-source search, detail, audit, and import support
  through `Req`, source profiles, bounded downloads, source manifests, and the
  existing Agent Skills parser/registry.
- Treat `skills.sh` as one source profile and search convenience, not the
  platform model. v0.10's durable primitive is approved resource access with
  canonical `resource_uri`, derived origin kind/source/profile metadata,
  operation class, access mode, scope, limits, confirmation, audit, and trace
  metadata.
- Resource identity is URI-first before adding more consumers. Remembered
  grants require `resource_uri`; pre-M12 `canonical_scope` grant records are
  not matched through a legacy compatibility layer. Authority is
  `resource_uri + operation_class + access_mode + downstream_consumer` plus
  current Security Central permission.
- Implement direct/local skill import as `import_skill` and
  `import_local_skill` consumers, and keep future URL summarization and
  document inspection on `summarize_url`/`inspect_document` without sharing
  unsafe approval authority.
- Write imported skills only under `<ALLBERT_HOME>/cache/skills`; keep them
  disabled, untrusted, and non-executable until parsed, validated, audited,
  enabled, trusted, and separately confirmed for any script execution.
- Keep Docker, Podman, Mac/Linux containers, remote sandboxes, and microVMs out
  of v0.10. Deny or defer workflows that need deeper isolation.

Milestones:

- M1 (Milestone 1): Implemented. Policy, ADR, Settings Central schema,
  Allbert Home paths,
  and registered capability contracts for external, package, and online import
  actions.
- M2 (Milestone 2): Implemented. Confirmed `Req` external service adapter,
  SSRF/redirect/retry policy, confirmation resume, redacted trace/audit, and
  Req.Test coverage.
- M3 (Milestone 3): Implemented. Package install preview, confirmed npm adapter
  through package-manager profiles, exact package spec validation, package
  confirmation metadata, `mix allbert.packages`, and pip preview-only denial.
- M4 (Milestone 4): Implemented. Confirmed online skill search, detail, audit,
  and disabled imported-cache write through allowed source profiles, `Req`,
  source manifests, existing parser/registry validation, and CLI/confirmation
  metadata. Approved source failures resolve as `approved` confirmations with
  `target_status=failed` and rendered failure reasons.
- M5 (Milestone 5): Implemented. Release readiness, operator surfaces,
  trace/audit polish, docs, future milestone handoffs, focused tests, final
  gates, version metadata `0.10.0`, and release/tag readiness docs.
- M6 (Milestone 6): Implemented. Post-M5 reconciliation and Resource Access
  Security Posture rebaseline. Records the online approval clarity/search fix,
  README/operator onboarding cleanup, ADR 0012, and the decision to resume
  implementation at M7.
- M7 (Milestone 7): Implemented. Shared resource reference contract through
  `AllbertAssist.Resources.Ref`, `Scope`, `OperationClass`, inert `Grant`
  descriptors, and confirmation resource metadata rendering for local paths,
  local skill resources, Allbert Home resources, remote URLs, remote sources,
  and package registries, including skills special cases such as
  `import_local_skill`, `run_skill_script`, and `import_skill`.
- M8 (Milestone 8): Implemented. Resource-scoped remembered grants under
  `resource_grants.remembered`, with generic local/remote scope matching,
  explicit caller-supplied permission re-check, expiry/revocation, redirect
  escape denial, traversal/symlink escape denial, and no cross-use between
  local import, remote summary, skill import, package install, activation, or
  script execution.
- M9 (Milestone 9): Implemented. Release readiness and user testing refresh
  after M6-M8, including focused online skill regressions, resource
  reference/grant tests, full gates, docs, and tag-readiness wording.
- M10 (Milestone 10): Implemented. Resource identity and scope hardening
  before grants become user-facing: canonical-resource versus
  redacted-display separation for URL refs, intermediate local symlink escape
  denial, source profile drift checks, and registry-driven resumable-action
  metadata.
- M11 (Milestone 11): Implemented. Remembered grant operator UX and
  application for existing v0.10 actions: registered list/show/revoke/remember
  actions, `mix allbert.resources grants ...`, approval-time remember options,
  thin `/settings` list/revoke/approve-with-remember controls, and grant
  lookup before creating confirmations for external request, online skill
  source, and package install consumers.
- M12 (Milestone 12): Implemented. URI-first resource identity refactor through
  `AllbertAssist.Resources.ResourceURI`, required `resource_uri` grant
  authority, removal of the temporary `canonical_scope` grant shape, and inert
  future URI scheme representation for
  `mcp://`, `agent://`, and `agent+https://`.
- M13 (Milestone 13): Implemented. Direct skill URL import and local skill
  directory import as concrete URI-backed resource consumers that import only
  disabled/untrusted skill candidates and never trust, enable, execute, or
  install dependencies.
- M14 (Milestone 14): Implemented. Final closeout and v0.11 handoff
  readiness: explicit no-op/unsupported UX for URL summarization and document
  inspection, MCP resource/tool calls, and `agent://` delegation in v0.10,
  refreshed tests, docs, and release/tag readiness.

Exit signal: Allbert can search, audit, and import online skills, call approved
external services, and run the first confirmed npm package-manager profile
through registered actions without making imports, package manifests, or
package-manager metadata executable by themselves. CLI, `/settings`, traces,
audits, and Security Central render the same v0.10 metadata and policy
summaries, including the distinction between operator approval and target
execution failure. The docs and code also identify Resource Access Security
Posture as the common substrate for future local and remote consumers. The
reopened M6-M9 sequence, M10 hardening, M11 remembered-grant
operator/application work, M12 URI-first resource identity refactor, M13
direct/local skill import consumers, and M14 unsupported workflow handoff are
complete. v0.10 was released and tagged as `v0.10` on 2026-05-04.

## v0.11: Execution-Aware Intent, URI-Based Resource Access, And Approval Handoff

Plan: `docs/plans/v0.11-plan.md`
Request flow: `docs/plans/v0.11-request-flow.md`

Status: released and tagged as `v0.11` on 2026-05-13. Ready for operator manual
verification with the v0.11 request-flow matrix.

Implemented direction:

- Introduce the inert `AllbertAssist.Intent.Decision` contract with selected
  intent, candidate skills/actions, permission, risk, confirmation, execution
  mode, resource access posture, Approval Handoff, alternatives, diagnostics,
  trace metadata, and reserved `user_id`, `thread_id`, `session_id`, and
  `active_app` fields.
- Validate every decision against known skills, registered actions, known
  permissions, Security Central, Settings Central, and confirmation state.
- Represent URL summaries, document inspection, direct skill URL import, local
  skill directory import, shell execution, skill scripts, package installs,
  external services, online skill sources, and unsupported MCP/agent URI flows
  as resource-access consumers over the v0.08-v0.10 substrates.
- Produce Approval Handoff data for CLI and web approval UX without giving
  channels authority to approve, deny, fetch, import, execute, or grant.
- Keep conversation history out of v0.11; v0.12 plugs into the reserved
  identity/thread fields.

Exit signal: risky URL/document/import prompts produce inspectable decisions,
operation-scoped resource posture, and approval handoff without hidden
execution or new file/browser/crawler primitives.

Release handoff: v0.11 request-flow docs now carry the manual verification
matrix for CLI URL summary approval, LiveView approval/denial, approved fetch
with missing summarizer/extractor, direct/local skill import, unsupported
MCP/agent URI behavior, and operation-scoped grant negative checks.

## v0.12: Local Workspace Identity And Conversation History

Plan: `docs/plans/v0.12-plan.md`
Request flow: `docs/plans/v0.12-request-flow.md`
ADR: `docs/adr/0014-local-workspace-identity.md`

Status: released and tagged as `v0.12` on 2026-05-13. Ready for operator manual
verification with the v0.12 request-flow matrix. Formerly M-D1a.

Implemented direction:

- Add canonical string `user_id`, preserving `operator_id` as a compatibility
  alias and defaulting omitted identity to `"local"`.
- Add SQLite `Thread` and `Message` conversation history with user isolation,
  explicit `thread_id`, recent-thread selection, and `--new-thread` creation.
- Persist user messages before the agent runs and assistant messages after
  response and trace metadata are known.
- Pass bounded recent thread context to the intent agent, initially the last
  12 messages.
- Add `--user`, preserve `--operator`, fail fast if both differ, and add
  `mix allbert.threads`.
- Keep acceptance on CLI/runtime/signals/traces/tests. No AgentLive thread
  sidebar, no semantic retrieval, and no markdown-memory promotion.

Exit signal: `mix allbert.ask --user alice --new-thread ...`, follow-up calls,
`mix allbert.threads`, default `"local"` behavior, and alice/bob isolation
prove durable thread context without hosted accounts.

## v0.13: Scheduled Jobs

Plan: `docs/plans/v0.13-plan.md`
Request flow: `docs/plans/v0.13-request-flow.md`

Status: released and tagged as `v0.13` on 2026-05-14. Formerly v0.12.

Expected direction:

- Add local SQLite-backed scheduled jobs that emit signals into the same
  runtime or run registered actions through the action runner.
- Preserve originating `user_id`, `thread_id`, and `app_id` when available so
  traces and audits carry local ownership context without accounts tables.
- Pause risky job actions for durable confirmation and render the same
  resource posture/Approval Handoff metadata as CLI and web.
- Keep jobs observable through durable run records, lifecycle signals, traces
  when enabled, registered skills/actions, and Settings Central schedule
  policy.
- Keep the scheduler local and supervised; no distributed scheduler, remote
  workers, or new execution primitives.
- Instantiate initial low-risk job templates through explicit CLI commands,
  not seeded database rows or autonomous job creation.

## v0.14: Session Scratchpad And Active App Context

Plan: `docs/plans/v0.14-plan.md`
Request flow: `docs/plans/v0.14-request-flow.md`
ADR: `docs/adr/0014-local-workspace-identity.md`

Status: released and tagged as `v0.14` on 2026-05-14. Formerly M-D1b.

Expected direction:

- Add supervised volatile ETS scratchpad state keyed by `{user_id, session_id}`
  with TTL expiry, periodic sweep, and no restart persistence.
- Store `active_app` and bounded transient working memory for runtime/session
  use while keeping raw working-memory values out of traces/logs by default.
- Add a CLI sessions surface and `mix allbert.ask --session` so Phase 1
  acceptance can prove active-app propagation without adding workspace UI.
- Expose active-app session inspection/mutation through registered actions
  that reuse existing `:settings_write`/`:read_only` permissions and do not
  add new Security Central permission classes.
- Propagate `active_app` through runtime requests, signals, intent-agent
  context, decisions, traces, responses, and assistant message metadata.
- Treat scratchpad state as context only, not durable memory, app routing,
  authorization, or a security boundary.

## v0.15: Minimal App Registration Contract

Plan: `docs/plans/v0.15-plan.md`
Request flow: `docs/plans/v0.15-request-flow.md`
ADR: `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

Status: released and tagged as `v0.15` on 2026-05-14. Formerly
M-AppContract-Lite.

Expected direction:

- Add the lite `AllbertAssist.App` behaviour and registry for app identity,
  validation, child supervision, registered actions, skill paths, and nav
  surfaces.
- Register built-in `CoreApp` and transitional `StockSageStub` so v0.14
  `active_app` acceptance continues until real StockSage lands in v0.20.
- Tag registered actions with optional `app_id`.
- Normalize app ids through the registry without dynamic atom creation from
  operator/channel/model input.
- Keep permission, confirmation, security, traces, and execution authority at
  existing Allbert action boundaries.
- Do not add `AllbertAssist.Surface`, dynamic route loading, workspace shell,
  or canvas work yet.

## v0.16: Additional Channels

Plan: `docs/plans/v0.16-plan.md`

Request flow: `docs/plans/v0.16-request-flow.md`

ADR: `docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md`

Status: implemented and ready for operator manual verification on 2026-05-14.
Formerly v0.13.

Implemented direction:

- Add the channel adapter boundary and prove it with two providers: Telegram
  (Bot API long polling, inline keyboard buttons) and email (IMAP polling,
  SMTP replies, typed-command confirmations).
- Translate external messages into `AllbertAssist.Runtime.submit_user_input/1`
  requests and render responses without owning agent logic, security policy,
  confirmations, memory, or execution.
- Map external identities to local string `user_id` values through explicit
  Settings Central configuration; traces and channel events include both
  external identity and resolved local `user_id`.
- Add durable `channel_events` SQLite records for inbound/callback dedupe,
  provider status, response delivery, trace ids, and thread ids; shared by
  both providers.
- Store Telegram bot tokens and email credentials through Settings Secrets and
  keep provider payloads redacted and bounded at CLI/log/trace boundaries.
- Consume Approval Handoff and Resource Access Security Posture natively without
  channel-specific resource or approval rules. Telegram uses inline buttons;
  email uses typed-command replies (`ALLBERT:APPROVE/DENY/SHOW:<id>`); both
  resolve existing durable confirmations through registered actions.
- Supervise Telegram and email adapters independently under `:one_for_one` so a
  crash or misconfiguration in one adapter does not affect the other.
- Keep SMS, Discord, Slack, media downloads, webhooks, IMAP IDLE, SMTP provider
  APIs, arbitrary provider method calls, email attachments, remote document
  extraction, and proactive broadcast out of v0.16.

## v0.17: Plugin Contract And Shipped Channel Plugins

Plan: `docs/plans/v0.17-plan.md`

Request flow: `docs/plans/v0.17-request-flow.md`

ADR: `docs/adr/0017-allbert-plugin-contract.md`

Status: implemented through M6 closeout on 2026-05-14. Ready for operator
manual verification.

Expected direction:

- Add `AllbertAssist.Plugin`, `AllbertAssist.Plugin.Registry`, plugin
  discovery, plugin bootstrap, and plugin supervision.
- Use `./plugins` as a real source-tree plugin root, starting with shipped
  `./plugins/allbert.telegram` and `./plugins/allbert.email` packages.
- Scan default folder plugin paths: `./plugins` and `<ALLBERT_HOME>/plugins`.
- Keep plugin ids as strings and reject atom creation from manifests, settings,
  channel input, model output, or operator input.
- Support shipped compiled source-tree plugins and skill-only folder plugins in
  v0.17; do not compile or load arbitrary code from
  `<ALLBERT_HOME>/plugins`, and do not automatically compile arbitrary
  `./plugins/*/lib` directories.
- Move the v0.16 Telegram and email provider-specific code into the shipped
  plugin packages while preserving v0.16 channel behavior.
- Let plugin contributions feed app registration, first-class channel
  descriptors in `AllbertAssist.Plugin.Registry`, action registry additions,
  skill roots, settings schema entries, and supervised children without
  granting permission or trust.
- Start compiled plugin-owned child specs under a plugin child supervisor;
  channel adapters still start under `AllbertAssist.Channels.Supervisor` from
  registered descriptors.
- Add `mix allbert.plugins` and read-only plugin inspection actions.
- Prepare v0.20 StockSage to land through a `./plugins/stocksage` package
  that contributes `StockSage.Plugin`, `StockSage.App`, and StockSage skill
  roots.

## v0.18: Full App Contract And Surface DSL

Plan: `docs/plans/v0.18-plan.md`

Request flow: `docs/plans/v0.18-request-flow.md`

ADR: `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

Status: implemented through M6 closeout on 2026-05-15. Formerly M-AppContract-Full, previously planned as v0.25,
then v0.21. Moved before StockSage so v0.20 implements the app/surface contract
from day one and v0.27 (formerly v0.25) LiveViews build on
`AllbertAssist.App.SurfaceProvider` without any stepping-stone migration.
Later roadmap reconciliation split the final deferred memory namespace layer:
namespace declaration lands in v0.27, and namespace-consuming memory sync lands
in v0.29.

Expected direction:

- Expand the app contract into identity/OTP, agents/actions/signals, skills,
  UI surface, and data/settings layers. Memory namespace declaration is
  deferred to v0.27; namespace-consuming memory sync is deferred to v0.29.
- Add `AllbertAssist.App.SurfaceProvider`, `AllbertAssist.Surface` DSL with
  catalog validation, and `AllbertAssist.Surface.Encoder.to_a2ui/1` as the
  typed AG-UI adaptation stub.
- Upgrade `AllbertAssist.App.CoreApp` to implement `SurfaceProvider`, declaring
  the `/agent` conversation route as the first built-in chat surface. This is
  the first `SurfaceProvider` implementation; v0.20 StockSage is the second.
- Default runtime requests to `active_app: :allbert` when no known app context
  is active in request data or scratchpad. Every runtime turn now has a
  declared home app.
- Add `mix allbert.validate_app MyApp` and
  `docs/developer/how-to-create-an-allbert-app.md`.
- Design the app/surface contract so v0.20 StockSage can implement
  `SurfaceProvider` from day one; no lite-to-full migration needed.
- Keep AG-UI/A2UI as future adapters, not local hard dependencies.

## v0.19: Cross-Surface Intent Enrichment

Plan: `docs/plans/v0.19-plan.md`

Request flow: `docs/plans/v0.19-request-flow.md`

ADR: `docs/adr/0019-cross-surface-intent-enrichment.md`

Status: implemented through M6 closeout on 2026-05-15. Ready for operator
manual verification. Formerly v0.15, previously planned as v0.22.

Expected direction:

- Move from route predicates toward hybrid deterministic and model-assisted
  intent ranking over real runtime signals.
- Use settings, skills, actions, Security Central, confirmations, traces,
  jobs, channels, existing memory/trace metadata, session scratchpad, plugin
  provenance, app registry context, and registered surface metadata as routing
  inputs. Reviewed-memory retrieval plugs in later through v0.21 and is not a
  v0.19 prerequisite.
- Prioritize app-registered actions and skill paths only when `active_app`
  gives explicit session evidence.
- Use registered app surface metadata to include surface navigation as a
  routing target when session context supports it.
- Keep `active_app` and plugin provenance as ranking/explainability metadata,
  never authorization.
- Keep v0.11 resource posture and Approval Handoff behavior unchanged for URL,
  document, package, shell, script, import, MCP, and agent-resource prompts.

## v0.20: StockSage Plugin App And Domain

Plan: `docs/plans/v0.20-plan.md`

Request flow: `docs/plans/v0.20-request-flow.md`

ADR: `docs/adr/0018-stocksage-local-domain-app.md`

Status: implemented through M5 closeout fixes on 2026-05-15. Ready for
operator manual verification; release tag pending operator acceptance.
Formerly M-D2a.

Expected direction:

- Implement `./plugins/stocksage` as the shipped plugin app package, with
  `StockSage.Plugin` as the plugin entrypoint and `StockSage.App` using the
  v0.18 app/surface contract.
- Keep StockSage implementation code plugin-owned; do not add `apps/stocksage`
  or `apps/stocksage_web` umbrella apps.
- Add SQLite-first StockSage domain records with string `user_id` and optional
  thread/request context.
- Use the existing `AllbertAssist.Repo` and central SQLite database with
  `stocksage_*` tables; do not add `StockSage.Repo`.
- Add local StockSage skill pack paths and an import task for the frozen Python
  `stocksage.db` baseline.
- Add safe local StockSage actions for listing/showing imported analyses,
  reading local trends, and queueing an analysis request without executing it.
- Add scoped `:stocksage_write` permission for local StockSage domain writes;
  it does not authorize financial API calls or analysis execution.
- Keep PostgreSQL, Oban-as-hard-dependency, LiveViews, bridge execution, and
  native financial specialist agents out of this slice.

## v0.21: Memory Review And Retrieval

Plan: `docs/plans/v0.21-plan.md`

Status: implemented; ready for operator manual verification before release tag.
Formerly v0.14.

Expected direction:

- Added operator review, correction, promotion, and pruning over markdown
  long-term memory.
- Generated summaries and compiled runtime views from markdown sources.
- Kept SQLite conversation history from v0.12 distinct from markdown memory;
  no automatic promotion of thread turns.
- Added metadata-only memory candidates to the v0.19 intent engine after
  review and source-of-truth semantics stabilized.

## v0.22: StockSage Python Bridge

Plan: `docs/plans/v0.22-plan.md`
Request flow: `docs/plans/v0.22-request-flow.md`
ADR: `docs/adr/0020-stocksage-python-bridge-protocol.md`

Status: released and tagged as `v0.22` on 2026-05-16 after audit closeout
and post-implementation gap fixes.
Formerly M-D2b.

Expected direction:

- Add `StockSage.TraderBridge` as a supervised JSON-over-stdio Port GenServer
  started under `StockSage.Supervisor` (plugin-owned; Allbert core is not
  aware of bridge internals).
- Add `./plugins/stocksage/priv/python/bridge.py` wrapping the frozen Python
  TradingAgents baseline.
- Add `StockSage.Actions.RunAnalysis` as a registered Jido action with the
  new `:stocksage_analyze` permission class (default `needs_confirmation`,
  safety floor `needs_confirmation`, risk tier `high`).
- Register `RunAnalysis` through `StockSage.Plugin.actions/0` and
  `allbert_plugin.json`.
- Add `mix stocksage.analyze TICKER DATE` as the first-class CLI entry point.
- Consume v0.20 queue records via `--queue-id` and persist bridge results into
  `stocksage_analyses` and `stocksage_analysis_details`.
- Route natural language "analyze AAPL" to `RunAnalysis` when `active_app:
  :stocksage` gives explicit session evidence; no new core predicates.
- Accept ADR 0020 defining the JSON-over-stdio protocol, plugin ownership
  boundary, and v0.28 (formerly v0.26) market-data hardening handoff.

## v0.23: Jido State-Machine Convergence

Plan: `docs/plans/v0.23-plan.md`
Request flow: `docs/plans/v0.23-request-flow.md`

Status: implemented through M5 closeout and ready for operator manual
verification. Release tag pending operator acceptance. NEW milestone inserted
by the project-direction rethink (see
`docs/archives/project-direction-rethink-01.md`). Closes the clearest part of
the gap between the original Jido-substrate vision and the current code before
v0.24 ships `Objectives.Engine` as another new Jido.Agent.

Expected direction:

- Ship `AllbertAssist.JidoBacked` shared behaviour + macros so both
  v0.23 conversions and v0.24 `Objectives.Engine.Agent` use one
  substrate contract, not three ad-hoc ports.
- Ship `AllbertAssist.JidoBacked.Supervisor` (one-for-one) under
  `AllbertAssist.Supervisor`; hosts both v0.23 agents and later v0.24
  `Objectives.Engine.Agent`.
- Convert `AllbertAssist.Confirmations.Store` from its current plain
  Allbert Home file-backed module into a JidoBacked agent.
  Confirmation YAML files and audit markdown remain authoritative;
  no confirmation SQLite migration. Module split: existing name stays
  as the public facade; new `.Agent` submodule holds the JidoBacked
  agent. Transitional compatibility modules were deleted at v0.23 M5
  closeout.
- Convert `AllbertAssist.Jobs.Scheduler` from plain `GenServer` to
  JidoBacked scheduler with the same facade + `.Agent` split.
  Jobs and job runs remain authoritative in SQLite; due work is still
  read from SQLite on each tick. Use `Jido.Agent.Directive.schedule/2`
  as the primary tick scheduling primitive; document any required
  fallback in the agent's `@moduledoc`.
- Implement private Jido.Action command modules for store/scheduler
  operations. They are not registered in `AllbertAssist.Actions.Registry`,
  are not intent candidates, and are not operator-callable capability
  actions.
- Add exactly one new setting: `allbert.jido.debug_trace` (boolean,
  default `false`). When `true`, JidoBacked agents emit bounded
  debug metadata to trace markdown via a `## Jido Debug` subsection.
- Compatibility test mechanism: focused regression/snapshot assertions for
  trace markdown, audit YAML, CLI output, state transitions, and retained
  v0.23 fixture snapshots under
  `apps/allbert_assist/test/fixtures/v0.23/` for canonical confirmation
  audit and scheduler summary scenarios.
- Codify the pragmatic substrate rule in the vision, `AGENTS.md`, and
  `DEVELOPMENT.md`: use Jido.Agent when state machines, lifecycle hooks,
  or successor agents are plausibly useful; use plain GenServer for
  stateful storage where Jido.Agent buys nothing. Settings, Trace,
  Memory storage IO, Session.Scratchpad, Memory.Compiler, and
  Memory.Promotion stay as plain GenServers.
- New `docs/developer/jido-agent-pattern.md` with worked example
  (state shape, schema validation, lifecycle hooks, directive
  emission, signal correlation, supervisor placement,
  rebuild-on-restart contract); short summary subsection in
  `DEVELOPMENT.md` pointing at it.
- Pure architectural refactor: no new user-visible features beyond
  the operator-opt-in debug-trace gate;
  no schema changes; no permission changes. All v0.07 and v0.13
  acceptance criteria continue to hold byte-for-byte against the
  golden-file snapshots.
- v0.23 version metadata is `0.23.0`; manual smoke remains the final
  release gate before tagging `v0.23`.

## v0.24: Objective Runtime Foundation

Plan: `docs/plans/v0.24-plan.md`
Request flow: `docs/plans/v0.24-request-flow.md`
ADR: `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md`
Research note: `docs/research/objective-runtime-research.md`

Status: released and tagged as `v0.24` on 2026-05-17 after M6 closeout,
post-audit hardening, and release verification. NEW milestone inserted by the
project-direction rethink (see `docs/archives/project-direction-rethink-01.md`).
Adds the durable multi-step work substrate that v0.25 native financial
specialist agents, v0.26 workspace shell, and future apps will build on.

Expected direction:

- Add `AllbertAssist.Objectives` umbrella with `Objective`, `Step`,
  `Event` schemas and `Objectives.Engine.Agent` as a JidoBacked
  agent (built on v0.23 `AllbertAssist.JidoBacked` substrate)
  implementing a seven-stage state machine through 10 private
  objective command modules. These command modules are not registered
  capability actions.
- Expose `AllbertAssist.Objectives.list/2`, `get/2`, `frame/2`,
  `advance/2`, `cancel/3`, and `continue/2` as the public lifecycle
  facade while keeping lower-level store helpers internal to the
  engine and tests.
- Add `objectives`, `objective_steps`, `objective_events` SQLite tables
  via four sequential timestamped migrations (3 core +
  1 StockSage plugin). The `objectives` table carries durable
  `proposer_hint` JSON for hybrid proposer continuation; the
  Engine.Agent state only caches it.
- Thread `objective_id` + `step_id` through confirmations, scheduled_jobs,
  `stocksage_analysis_queue`, `stocksage_analyses` (with btree index on
  `stocksage_analyses.objective_id`), traces, and audit.
- Ship six step kinds: `action`, `ask_user`, `wait`, `observe`,
  `reflect`, and the **minimal `:delegate_agent` contract** that
  unblocks v0.25 specialist trading agents. Other reserved kinds
  (`capability_inventory`, `route`, etc.) named in ADR 0021 but not
  implemented in v0.24.
- Ship monitored `AllbertAssist.Objectives.AgentRegistry` for
  `:delegate_agent` targets. It evicts dead registered agent processes
  and dispatches through `Jido.AgentServer.call/3`.
- Hardcoded per-app Proposer modules (e.g., `StockSage.Proposer`)
  registered via `AllbertAssist.Objectives.Proposer.register_app_proposer/2`
  at app boot. Proposer rules are Elixir code, not settings data.
- Add `:objective_write` permission class (default `:allow`, floor
  `:allow`; symmetry with other `_write` classes).
- Ship `mix allbert.objectives list|show|cancel|continue` CLI commands;
  `cancel --reason` is required. Known errors use real OS exit codes:
  `64` usage, `65` not found, `66` identity mismatch, `1` unexpected
  action/security failure.
- Add `## Objective` and `## Objective Steps` trace sections.
- Extend `AllbertAssistWeb.AgentLive` with an objective badge; add new
  `AllbertAssistWeb.ObjectiveLive` at `/objectives/:id`.
- Cooperative cancellation only; mid-action interruption deferred to
  v0.25+. Cancel-then-approve preserves the single-shot confirmation
  audit trail.
- Eager engine rehydration at boot; objectives with `updated_at`
  older than 1 hour are marked `:abandoned` (new terminal status).
- `Intent.Engine.collect_candidates/2` arity adds `:objective`
  candidate kind; ADR 0019 amended.
- Preserve legacy `allbert.input.received` and
  `allbert.agent.responded` emissions; add CoreApp-declared
  `allbert.runtime.turn.started` / `allbert.runtime.turn.completed`
  aliases. Objective and canonical runtime turn signals publish through
  `AllbertAssist.SignalBus`; SignalBridge subscribers use
  `allbert.objective.**`. Both `allbert.runtime.turn.completed` and
  `allbert.objective.completed` share `trace_id` for consumer
  correlation.
- Acceptance smokes: single-step `analyze AAPL` objective and two-step
  `analyze AAPL and compare to MSFT` objective (with `parent_step_id`
  populated end-to-end).
- ADR 0021 accepted at v0.24 M6 and amended to enumerate
  `:objective_write`, `parent_step_id` semantics, minimal
  `:delegate_agent`, `objective_id` on `stocksage_analyses`, and the
  `:abandoned` status.
- Reserved vocabulary: advisory provider behaviour, world-model
  provider, capability inventory, route, acquisition option, planner.
  See ADR 0021 and the research note.

## v0.25: Native Financial Specialist Agents

Plan: `docs/plans/v0.25-plan.md`
Request flow: `docs/plans/v0.25-request-flow.md`
ADR: `docs/adr/0022-native-financial-specialist-agents.md`

Status: released. Implemented through M6 closeout on 2026-05-17; release tag
`v0.25.0` reconciled during the v0.29 release closeout. Formerly M-D2c,
previously planned as
v0.19, then v0.23 before the project-direction rethink inserted
v0.23 Jido State-Machine Convergence and v0.24 Objective Runtime
Foundation.

Expected direction:

- Implement reusable native financial specialist agents behind StockSage
  actions. They are NOT a one-for-one translation of the Python TradingAgents
  graph; they adapt role intent and license-compatible prompt material into
  11 bounded Jido.AI specialists + 1 deterministic Jido.Agent quality_gate,
  plus one JidoBacked `StockSage.Agents.NativeCoordinator` orchestrator.
- Register 12 specialist agent ids in
  `AllbertAssist.Objectives.AgentRegistry` at boot:
  `stocksage.market_context`, `stocksage.news_sentiment`,
  `stocksage.fundamentals`, `stocksage.bull_thesis`,
  `stocksage.bear_thesis`, `stocksage.risk_aggressive`,
  `stocksage.risk_conservative`, `stocksage.risk_neutral`,
  `stocksage.research_manager`, `stocksage.trader_plan`,
  `stocksage.decision_synthesizer`, `stocksage.quality_gate`.
  Three risk debaters preserved as distinct agents (per ADR 0022 A1) for
  Python-parity final-decision quality.
- Multi-round bull/bear and risk debate runs inside the plugin-owned
  native coordinator graph while recording one `objective_steps` row
  of `kind: :delegate_agent` per specialist turn. Bounded by
  `stocksage.native_max_debate_rounds` (default 2) +
  `stocksage.native_max_risk_rounds` (default 1).
- Keep native worker supervisors under `StockSage.Supervisor`, contributed
  through the StockSage plugin child spec.
- Consume v0.24 objective state from day one: each analysis runs as an
  objective with multiple steps; `objective_id`/`step_id` threaded through
  confirmations, traces, and `stocksage_analyses` rows.
- Add 5 tiered action-backed evidence providers (`FetchMarketData`,
  `FetchNews`, `FetchSentiment`, `FetchFundamentals`, `FetchFinancials`)
  under `StockSage.Actions.Evidence.*` with new
  `:stocksage_evidence_fetch` permission class. Fixture mode is a
  first-class operator surface (not test-only) so native analysis can be
  smoke-tested without market-data credentials while preserving Resource
  Access Security Posture.
- Keep the Python bridge available only for explicitly requested comparison,
  similarity scoring, and regression fixtures. It is NOT automatic fallback.
- Add `--engine both` for parallel parity runs (native + Python concurrent),
  persists ONE `stocksage_analyses` row with both engines' fields + a
  parity_diff JSON computed as 5-point rating-scale agreement +
  bounded confidence delta. Parity acceptance:
  `rating_agreement >= 0.5 AND confidence_delta < stocksage.native_parity_variance`
  (default 0.25).
- Add per-agent LLM model profile overrides via
  `stocksage.native_model_profile_<role>` settings (matches Python's
  `deep_think_llm` / `quick_think_llm` split).
- Hybrid prompt provenance: verbatim from TradingAgents v0.2.5 where
  license permits (with `## Attribution` header), Allbert-authored
  otherwise. M1 task = per-prompt license audit. Prompts ship under
  `plugins/stocksage/priv/prompts/native_agents/<role>.md`.
- Ship `mix allbert.delegate <agent_id>` Mix task in Allbert core (NOT
  StockSage) as operator-visible cross-app reuse proof. Any registered
  specialist agent callable from outside StockSage via the v0.24
  DelegateAgent registered action + AgentRegistry.
- Make native analysis the only default operational engine in v0.25.
  Engine choice is per request: absent engine means native; `--engine
  python` and `--engine both` are explicit comparison/reference modes
  gated by `stocksage.python_comparison_enabled`. Do not extend
  `stocksage.analysis_engine` into a persistent Python/parity default.
- ADR 0022 is Accepted and records the 10-agent topology, multi-round
  coordinator graph with objective-step observability, parity metric,
  NativeCoordinator, tiered evidence actions, and `mix allbert.delegate`
  cross-app proof.

## v0.26: Agentic Workspace Surface And Ephemeral UI Substrate

Plan: `docs/plans/v0.26-plan.md`

Status: implemented through M30 UI release closeout on 2026-05-19, then
accepted with the v0.26a/v0.26b `0.26.1` closeout on 2026-05-22. Formerly
the old v0.17 workspace-surface plan, then v0.27, then v0.24 when moved before
StockSage LiveViews, then v0.26 after the project-direction rethink.

Prerequisite: v0.18 app/surface contract, v0.19 intent enrichment, v0.21 memory
review, v0.22 Python bridge, v0.23 Jido Convergence, v0.24 Objective Runtime
Foundation, and v0.25 Native Jido agents are complete.

Shipped direction:

- Upgrade `AllbertAssist.App.CoreApp`'s declared surface from the rudimentary
  `/agent` prompt into a **fully-dynamic signal-driven LiveView workspace**.
  v0.26 is `CoreApp`'s surface implementation, not a free-floating shell; it
  does not redefine the app contract or surface DSL that v0.18 provides.
- **The workspace shell IS itself a Surface tree** (per ADR 0023 §2). The
  web renderer walks the tree and dispatches each node's `:component` atom to
  a LiveComponent through `AllbertAssistWeb.Workspace.Renderer`; v0.31 M7 moves
  that dispatch table into the unified `AllbertAssist.Surface.Catalog`. No
  hardcoded HEEx layout for regions.
- **Per-thread Canvas** (persistent tiles bound to v0.12 thread; survives
  refresh + restart) + **per-thread Ephemeral Surfaces** (task-scoped
  overlays, shared across tabs of the same thread, GC'd on thread close).
  Hybrid SQLite-metadata + YAML-body persistence under `<ALLBERT_HOME>/workspace/`.
- **Catalog expands from 12 → 42 components** (per ADR 0015 v0.26
  amendment): 12 v0.18 carryover + 10 workspace structural + 12 Allbert-domain
  + 4 Allbert-app cards + 4 reserved StockSage cards (v0.26 ships stubs;
  v0.27 implements real rendering).
- **Strict + HMAC-signed runtime Fragment emission** via
  `allbert.workspace.fragment.**` SignalBus topic. Any in-BEAM module can
  emit; `AllbertAssistWeb.SignalBridge` validates (envelope shape +
  signature + catalog component + emitter allow-list + per-emitter rate
  limit + payload size) before forwarding to per-user PubSub.
- **Multi-tab sync** via Phoenix.PubSub for canvas tiles AND ephemeral
  surfaces. Tabs viewing the same thread see the same state.
- **UX qualities all first-class**: dark mode + theme toggle, high contrast,
  reduced motion, WCAG-oriented structural accessibility (keyboard nav +
  ARIA + focus traps + skip-to-content), mobile responsive layout (two-pane
  above fixed 768px, single-pane with tab toggle below), offline text/markdown
  tile editing via service worker + browser-side Yjs + IndexedDB with bounded
  reconnect sync + conflict-banner UX. Manual axe and screen-reader validation
  remain the operator release gate.
- **Internal `AllbertAssist.Workspace.AGUI.Bridge`** translates curated
  Allbert signals to AG-UI event shape for test-only semantic mapping.
  NOT exposed over HTTP. Public AG-UI / A2UI / MCP Apps interop is
  post-v0.38 (per Future Features Post-v0.38 UI Protocol Interop).
- **`StockSage.Actions.RunAnalysis`** + objective engine + v0.25 native
  specialist agents emit Fragments rendering as canvas tiles + ephemeral
  approval cards. Operator sees the analysis stream in real-time as
  agents complete.
- **14 new `workspace.*` settings** (theme, offline, accessibility,
  fixed read-only mobile breakpoint, fragment rate limits, etc.). **New
  `:workspace_canvas_write` permission class** for tile-state mutations.
- **9 new `allbert.workspace.**` signal topics** (`fragment.emitted`,
  `fragment.dropped`, `tile.added/updated/removed`,
  `ephemeral.opened/closed`, `canvas.snapshot.requested` reserved no-op,
  `offline.reconciled`).
- **`## Workspace` trace section** + inline `### Workspace` subsection
  per v0.24 inline placement rule.
- **`mix allbert.workspace canvas|ephemeral|inspect|rotate-signing-secret`**
  Mix tasks.
- Sibling routes (`/objectives/:id`, `/jobs`, `/settings`) remain
  top-level for deep-linking. The workspace can render
  catalog-backed summary tiles for those domains without replacing
  the sibling routes in v0.26.
- ADR 0015 v0.26 planning amendment records the catalog expansion;
  new ADR 0023
  (Workspace Canvas And Ephemeral Surface Substrate) reaches Accepted
  at v0.26 M20 with all binding decisions.
- Defer to v0.27+: drag-drop tile reordering, real StockSage card
  rendering. Plugin-contributed workspace regions graduated to v0.32
  (ADR 0024). Defer to post-v0.38: multi-user collaborative cursors,
  public AG-UI HTTP endpoint, A2UI / MCP Apps interop, canvas snapshot /
  undo / time-travel.

## v0.26a: Workspace UX/UI Substrate Pass

Plan: `docs/plans/v0.26a-ui-plan.md`

Status: implemented through M35 closeout on 2026-05-21. Version metadata
is `0.26.1`. Fast-follow visual + interaction polish on top of v0.26;
substrate (catalog, schema, signals, settings, fragment validation, AGUI
bridge, offline editor) untouched.

- Live chat history accumulates without navigation (M28).
- Composer clears on submit; Enter submits + Shift+Enter newlines + live
  char counter against `workspace.canvas.tile_body_max_bytes` (M29).
- Sticky AppBar + independently scrolling chat / canvas panes; full
  `100dvh` flex-column shell (M30).
- Mobile tab strip becomes sticky just below the AppBar; pane heights
  retightened to suit the new chrome (M31).
- Approval handoff renders as a centered modal overlay with backdrop
  scrim, dark-mode and reduce-motion variants, and copy chip on the
  confirmation id. Authority unchanged (M32).
- Every catalog card renders a status pill driven by emitter
  `prop(:status)` and a copy chip for its external id; tile kebab gains
  "Copy tile id" (M33).
- AppBar chips wire real interactions (objective → workspace Objectives
  Canvas destination, tile → canvas anchor, ephemeral → ephemeral anchor);
  3-state theme cycle (system → dark → light); overflow menu opens with theme
  cycle + workspace settings + jobs + objectives links (M34).
- Bumped `App.CoreApp.version/0` + umbrella + child app metadata to
  `0.26.1`; CHANGELOG entry + this roadmap row.
- Defer to a follow-up: real tile inspector modal (M33 footed at "expand
  to inspect"), thread switcher dropdown (current AppBar thread chip
  copies the id), real-time turn streaming, multi-tab sync screenshot
  verification.

## v0.26b: Backend Runtime Bugfix Pass

Plan: `docs/plans/v0.26b-backend-plan.md`

Status: implemented and merged into the `0.26.1` release on 2026-05-22.
No new schema, security authority, public protocol surface, or version bump
beyond `0.26.1`.

- H1: generic safe setting-shaped prompts route through `update_setting`
  without requiring LLM credentials; unsafe/secret/read-only setting prompts
  remain bounded by Settings Central and registered actions.
- H2: native StockSage LLM credential/preflight failures surface bounded
  `native_llm_unavailable: ...` reasons through the action result, persisted
  analysis metadata, analysis-failed signal, and workspace-fragment metadata.
- H3: fresh `/agent` composer state is empty with neutral placeholder copy.
- `mix precommit` on merged `main` passed: 754 core tests, 79 web tests, 168
  StockSage plugin tests, and 2 channel plugin tests, all 0 failures.

## v0.26c: Workspace UX Closeout

Plan: `docs/plans/v0.26c-ux-closeout-plan.md`
Request flow: `docs/plans/v0.26c-request-flow.md`

Status: implemented as a small `0.26.2` point release; release gate passed and
operator manual verification/tagging is pending. This is not a new platform
contract and not a StockSage milestone.

Shipped:

- Real tile inspector modal deferred from the `0.26.1` closeout.
- AppBar thread switcher dropdown with recent-thread navigation, new-thread
  creation through `Conversations.resolve_thread/1`, and copy-thread-id.
- Same-thread multi-tab sync verification recorded in the request-flow doc with
  Chrome browser-smoke notes.
- Leave progress streaming to v0.27, where StockSage analysis progress is the
  real app-flow driver.
- No schema, catalog, settings, signal, permission, Security Central, or
  StockSage card changes.

## v0.27: App Surface Contract - StockSage LiveViews

Plan: `docs/plans/v0.27-plan.md`
Request flow: `docs/plans/v0.27-request-flow.md`

Status: released. Implemented through M8 closeout on 2026-05-22; release tag
`v0.27.0` exists. Formerly M-D3a, previously planned as v0.24, then v0.25
before the project-direction rethink. Redesigned to build on the v0.18
app/surface contract and Surface DSL from day one. Renamed after the post-v0.26
roadmap reconciliation to make the platform contract explicit: StockSage is the
reference implementation, not a special-case app.

Prerequisite: v0.18 app/surface contract, v0.22 Python bridge, v0.24
Objective Runtime Foundation, v0.25 Native Jido agents, and v0.26 workspace
surface are complete so both analysis engines, objective state, and the
workspace shell are available from the start.

Shipped:

- Add StockSage workspace, analysis, queue, and trends LiveViews in
  plugin-owned StockSage web surface modules.
- Implement `AllbertAssist.App.SurfaceProvider` on `StockSage.App` and declare
  StockSage surfaces through real `%AllbertAssist.Surface{}` structs validated
  by the app registry. Static route mounts live in the host router; provider
  metadata drives navigation and validation.
- Replace the reserved v0.26 StockSage card stubs with real renderers in
  StockSage-owned `/stocksage/...` LiveViews. This is renderer/app-surface
  proof; v0.30 is durable `/agent` canvas-emission proof.
- Render objective state for StockSage analyses: which objective an analysis
  belongs to, delegated specialist steps, pending confirmation links, and
  cancellation affordance.
- Declare StockSage component catalog entries for the four v0.26-reserved
  StockSage card atoms so `RunAnalysis` results carry validated Surface nodes
  from day one. Queue and trend pages render with existing Surface primitives in
  v0.27 unless ADR 0015 and the global component catalog are explicitly amended.
  Canvas tile emission remains v0.30.
- Add app memory namespace declaration/registration and have `StockSage.App`
  declare its namespace. No memory sync, reflection, lesson promotion, or
  markdown-memory write lands in v0.27.
- Use PubSub/streams for live progress, set `active_app: :stocksage` when
  navigating under `/stocksage/`, and cover app-flow empty/loading/error,
  keyboard/focus, and mobile behavior.
- Configure Tailwind to scan `plugins/stocksage/lib/stocksage_web` so
  plugin-owned responsive classes ship with the host asset build.

## v0.28: Security Hardening And Evals

Plan: `docs/plans/v0.28-plan.md`
Request flow: `docs/plans/v0.28-request-flow.md`

Status: released. Release tag `v0.28.0` reconciled during the v0.29 release
closeout. Formerly v0.16, previously planned as v0.25, then v0.26 before the
project-direction rethink.

Expected direction:

- Add evals for prompt/tool injection, SSRF, unsafe redirects, untrusted skill
  activation, malicious imports, package abuse, command bypass, resource-scope
  bypass, path traversal, credential leakage, channel spoofing, and unsafe
  background execution.
- Add cross-user/thread leakage, app-scoped action routing, Python bridge
  protocol/path/crash safety, and financial workflow authorization coverage.
- Add objective runtime security evals: `objective_id` used as authority,
  cross-user objective lookup, cross-thread objective resume, unbounded
  loop_count, advisory provider output treated as observed fact, predictions
  about user behavior short-circuiting confirmation, `cancel_objective` race
  conditions, simulated state written as memory truth without operator
  confirmation.
- Add surface and SurfaceProvider security evals: catalog bypass, component
  injection, cross-app component type theft, and `to_a2ui/1` redaction-bypass
  attempts. v0.18 app/surface contract is complete; app-registration evals are
  required, not conditional.
- Add namespace claim abuse and namespace isolation evals before v0.29 adds
  memory writes through StockSage's declared namespace.
- Require StockSage external market-data calls to flow through Resource Access
  Security Posture and confirmations.

Implemented closeout:

- Added a shared security eval harness and concrete M2-M7 eval rows for
  resource/execution, identity/context, plugin/app registry,
  surface/workspace/namespace, objective/financial/bridge, and operator review
  surfaces.
- Hardened trusted context normalization, app-scoped action routing, disabled
  plugin exposure, app surface catalog ownership, namespace claim isolation,
  advisory-origin memory writes, StockSage bridge argument validation, and
  workspace fragment emergency disable behavior.
- Added `mix allbert.security review --recent` plus emergency switches for
  external services, StockSage bridge calls, plugin registration, app registry
  registration, and workspace fragment emission.

Risk reassessment for the next contracts:

- v0.29 memory sync can proceed only through explicit registered actions behind
  the StockSage namespace declared in v0.27 and audited in v0.28. The tested
  invariant remains: completing an analysis, resolving an outcome, or producing
  a reflection does not automatically write markdown memory.
- v0.30 canvas work should reuse the v0.26/v0.28-audited fragment and canvas
  mechanism. It should not introduce a new renderer contract, bypass app
  surface catalogs, or persist unaudited component atoms.
- v0.38 generator scaffolding should emit inert-by-default SurfaceProvider,
  memory namespace, action/objective, and canvas stubs only because the
  contracts were manually proven first. Generated files and metadata still do
  not grant permission.

## v0.29: App Memory + Outcomes Contract - StockSage Polish

Plan: `docs/plans/v0.29-plan.md`
Request flow: `docs/plans/v0.29-request-flow.md`

Status: released. Formerly M-D3b, previously planned as v0.27 before the
project-direction rethink. Renamed after the post-v0.26 roadmap reconciliation
to make the platform contract explicit. Version metadata is `0.29.0`; release
tag `v0.29.0` created after the full gate and operator smoke passed.

Expected direction:

- Consume the v0.27 StockSage memory namespace through explicit, traceable
  memory sync actions after v0.28 audits namespace ownership and isolation.
- Add outcome resolver, trend metrics, rating calibration, reruns, empty/error
  states, and responsive polish.
- Keep the tested invariant that completed analyses are not automatically
  promoted into markdown memory.
- Replicate Python StockSage 0.0.2 user-facing behavior in Elixir, with Python
  remaining only as an explicitly requested comparison/reference harness.

## v0.30: App Canvas Contract - StockSage Canvas Integration

Plan: `docs/plans/v0.30-plan.md`
Request flow: `docs/plans/v0.30-request-flow.md`

Status: released. Formerly M-Canvas, previously planned as v0.28 before the
project-direction rethink. Renamed after the post-v0.26 roadmap reconciliation
to make the platform contract explicit. Version metadata is `0.30.0`; release
tag `v0.30.0` was created after operator manual verification was accepted.

Implemented:

- No new `:stock_chart` atom. v0.30 reuses the four v0.26-reserved and
  v0.27-proven StockSage card atoms: `:analysis_card`, `:agent_report_card`,
  `:parity_card`, and `:debate_round_card`.
- `/agent` workspace rendering adapts those four atoms to the existing
  `StockSageWeb.Components.Cards` renderers instead of the v0.26 stubs.
- `RunAnalysis` lifecycle signals emit durable StockSage canvas tiles through
  `AllbertAssist.Workspace.Emitters.stocksage_signal/2`, signed
  `Workspace.Fragment.Envelope` validation, and the v0.26/v0.28-audited
  Fragment/canvas persistence path.
- Duplicate same-semantic-body Fragment emission remains idempotent when only
  the volatile Fragment `emitted_at` value changes.
- No new StockSage domain model, analysis behavior, migration, renderer
  contract, or workspace setting was added.

## v0.31: Runtime And UI-Substrate Consolidation

Plan: `docs/plans/v0.31-plan.md`
Request flow: `docs/plans/v0.31-request-flow.md`
ADRs: `docs/adr/0026-runtime-public-facades-and-boundaries.md`,
`docs/adr/0027-allbert-action-dsl-and-capability-registry.md`,
`docs/adr/0028-shared-runtime-substrates.md`,
`docs/adr/0029-typed-runtime-response-contracts.md`,
`docs/adr/0030-unified-surface-catalog-renderer-and-extension-registry.md`,
`docs/adr/0031-settings-schema-fragments-and-authority.md`

Status: implemented through M9 closeout and ready for operator manual
verification before the `v0.31.0` release tag. Inserted after v0.30 so the
workspace UI, theming, dynamic plugin trials, and generator build on one
consolidated runtime/UI substrate instead of encoding duplicated seams.

Prerequisite: v0.26 workspace shell, v0.27 StockSage renderers, v0.28 security
evals, v0.29 memory/outcomes, and v0.30 canvas emission.

Expected direction:

- Behavior-preserving consolidation: no route removals, no theming, no dynamic
  code, no generator, no domain changes, no migration.
- Introduce public facades and retirement criteria for compatibility shims.
- Add `use AllbertAssist.Action` and a compile-time capability registry for
  runtime-facing actions while keeping private Jido command modules private.
- Consolidate path, redaction, audit, trace, persistence, and response helper
  substrates behind documented facades.
- Unify Surface component catalog, renderer dispatch, app surface metadata,
  and plugin/app contribution discovery.
- Split Settings Central schema into registered fragments while preserving
  keys, defaults, validation, secret handling, and action-backed writes.

Implemented so far:

- M1: `AllbertAssist.Boundary` and `docs/developer/runtime-boundary-map.md`
  inventory the v0.31 public facades, compatibility shims, and retirement
  owners.
- M2: removed the obsolete `AllbertAssist.Workspace.Catalog.component_renderer/1`
  compatibility probe.
- M3: added `AllbertAssist.Runtime.Paths` and
  `AllbertAssist.Runtime.Redactor`; runtime-facing redaction callers now use
  the facade.
- M4: added `AllbertAssist.Runtime.Audit`,
  `AllbertAssist.Runtime.Persistence`, and `AllbertAssist.Runtime.Trace`;
  audit, trace, workspace body persistence, and Fragment body decoding route
  through the runtime facades without changing durable formats.
- M5: added `AllbertAssist.Action`, migrated registered core and StockSage
  actions to declare capability metadata on the action module, and removed the
  duplicate central registry capability map.
- M6: added `AllbertAssist.Runtime.Response`; Runtime, Runner,
  `PermissionGate.response_status/1`, and representative objective paths now
  share completed, confirmation-needed, denied, advisory, error, unsupported,
  and unavailable response helpers without changing operator-facing copy.
- M7: added `AllbertAssist.Surface.Catalog`,
  `AllbertAssistWeb.Surface.Renderer`, and `AllbertAssist.Extensions.Registry`;
  workspace and StockSage app surfaces now render through one catalog-backed
  path, and the v0.30 StockSage pass-through adapters plus
  `StockSageWeb.Components.SurfaceRenderer` were retired.
- M8: added `AllbertAssist.Settings.Fragment` and
  `AllbertAssist.Settings.Fragments`; `Settings.Schema` now assembles schema,
  defaults, and safe-write keys from registered core/app/plugin fragments
  without changing Settings Central behavior. `PermissionGate` remains a
  compatibility shim over Security Central for remaining live callers.
- M9: bumped release metadata to `0.31.0`, accepted ADR 0026-0031, updated
  README/CHANGELOG/roadmap/request-flow/developer context, and reconciled
  downstream v0.32-v0.38 handoffs.

## v0.32: Workspace-Only App UI And Settings Central

Plan: `docs/plans/v0.32-plan.md`
Request flow: `docs/plans/v0.32-request-flow.md`
ADR: `docs/adr/0024-app-ui-contribution-and-workspace-zones.md`

Status: released. Shifted from v0.31 after the consolidation insert and
completed as `v0.32.0`; release tag `v0.32.0` exists.

Prerequisite: v0.31 consolidated action, catalog, registry, response, path,
redaction, audit, persistence, and settings-fragment substrates.

Implemented:

- Add a two-tier app UI contribution model: rare `page` surfaces (own route,
  now under `/apps/<app_id>`) and default `:panel` surfaces composed into
  host-owned named workspace zones (`:nav_apps`, `:context_rail`,
  `:canvas_panels`, `:utility_drawer`, `:ephemeral`).
- Make `/workspace` the only operator home. `/agent`, `/settings`, and
  `/stocksage/*` are removed rather than redirected.
- Rebuild the workspace into a ChatGPT-style shell while preserving existing
  offline/a11y/mobile behavior.
- Make app selection explicit in the `:nav_apps` zone so selecting StockSage
  sets active app context through the existing registered/session boundary,
  replacing manual URL editing for in-context app requests.
- Move Settings Central into the workspace utility drawer while preserving
  existing action/security boundaries.
- Move StockSage dashboard/recent/queue/trends into workspace panels and use
  the same panel-zone path for CoreApp cards.
- Add no new domain behavior, analysis engine, execution authority, neutral
  natural-language app inference, arbitrary model-generated UI, theming
  system, dynamic code, or external UI protocol bridge. Conversational app
  handoff belongs to v0.33.

Closeout:

- M1 removed `/agent`, `/settings`, and `/stocksage/*` operator routes and
  made `/workspace` the canonical shell.
- M2 added panel and zone validation plus security eval rows for panel catalog
  bypass and zone injection.
- M3-M4 added the workspace shell, app launcher, mobile tabs, and Settings
  Central utility drawer through registered actions.
- M5-M6 moved CoreApp and StockSage operator UI into workspace panels while
  retaining StockSage analysis detail at `/apps/stocksage/analyses/:id`.
- M7 bumped release metadata to `0.32.0`, updated README/CHANGELOG/ADR
  0024/request-flow/developer context, extended the settings-action bypass
  eval, and ran the final release gate.

## v0.33: Conversational App Intent Handoff And Direct Answer Foundation

Plan: `docs/plans/v0.33-plan.md`
Request flow: `docs/plans/v0.33-request-flow.md`
ADR: `docs/adr/0034-conversational-app-intent-handoff-and-clarification.md`

Status: released as `v0.33.1`. M0-M6 implemented the direct-answer
foundation, descriptor contribution and validation, explicit app handoff,
targeted clarification, advisory-only classifier integration, StockSage
hardcode retirement, descriptorized StockSage trend/queue prompts, release
metadata, manual verification docs, and final release gate.

Prerequisite: v0.31 consolidated intent/action/response/catalog substrates and
v0.32 workspace app selection, panel zones, and Settings Central inside
`/workspace`.

Implemented direction:

- Replace the static direct-answer echo with a real side-effect-free direct
  answer path; remove stale version-specific copy from fallback responses.
- Let apps contribute generic intent descriptors with app id, action name,
  examples/synonyms, required slots, display label, and handoff requirement.
- In neutral workspace context, use descriptors and the bounded classifier to
  propose explicit app handoff when an app-owned capability is plausible:
  "StockSage can analyze CIEN; run it?"
- Accepting a handoff changes active app context and then enters the normal
  registered action confirmation path. Declining leaves context unchanged and
  creates no pending action.
- Ask targeted clarification when required slots are missing or top app/action
  candidates are close; use threshold plus top-two margin rather than a silent
  route.
- Reuse `Intent.Classifier` as advisory only. It may choose among already
  collected candidates or suggest ambiguity, but cannot invent actions, alter
  permissions, set trust, or bypass confirmation.
- Retire the current StockSage-specific ranker hardcode once app-contributed
  descriptors cover the StockSage `run_analysis` examples.
- Remove the remaining StockSage symbol parser from core once descriptors also
  cover `get_trends` and `queue_analysis`.
- Preserve v0.28 app-scope hardening: app-owned actions still require explicit
  matching `active_app` before `Actions.Runner.run/3`.

Closeout:

- M3 Chrome extension verification covered neutral handoff render, Decline,
  re-offer after dismissal, Accept into StockSage with the normal confirmation
  path, and missing-slot clarification.
- M5 security evals cover handoff bypass denial and unchanged runner
  app-scope denial for missing/mismatched active app context.
- M6 descriptorizes `get_trends` and `queue_analysis`, adds optional
  descriptor slots, and removes the last core StockSage symbol regex.
- Final release gate passed `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`; version metadata is `0.33.1`.

## v0.34: Workspace UX Refresh

Plan: `docs/plans/v0.34-plan.md`
Request flow: `docs/plans/v0.34-request-flow.md`
ADR: `docs/adr/0024-app-ui-contribution-and-workspace-zones.md` (v0.34 revision)

Status: released and tagged as `v0.34.0` on 2026-05-24. Inserted after v0.33
because the shipped v0.32 workspace shell rendered too many simultaneous
regions (left rail, a floating app/objectives band, chat, a permanent Canvas
column, and a permanent Tools column) with no clear primary, and v0.33 made
conversational handoff the way to enter app context. v0.34 restructures the
shell around that model without changing domain behavior, security, or routing
authority.

Prerequisite: v0.32 workspace route, panels, named zones, and Settings Central;
v0.33 conversational app-intent handoff (the only way to set `active_app`).

Delivered:

- The left rail is a view-only launcher. Output, registered non-Allbert Apps,
  and Workspace tools/Settings render in Canvas; Threads switch chat. Launcher
  selection never changes routing context.
- Canvas is a replace-model destination host. Output (durable tiles) is the
  default; `app:<app_id>` renders that app's panels; `workspace:<tool>` renders
  the mapped CoreApp tool panel.
- The permanent Tools column and floating app band are gone. Settings/tools
  are Canvas destinations; `:utility_drawer` remains a compatibility atom but
  is not a rendered v0.34 region.
- Routing context (`active_app`) remains conversational and handoff-only. The
  passive top-bar indicator shows Neutral vs the active app and exits through
  the registered `clear_active_app` action path.
- StockSage dashboard/recent/queue/trends panels render inside Canvas without
  restoring app-private shell chrome.
- Desktop and mobile are first-class: wide screens keep launcher + chat +
  Canvas with a Canvas focus toggle; narrow screens use a hamburger launcher
  sheet plus Chat/Canvas tabs.
- No new domain behavior, analysis engine, theming system, dynamic code,
  generator, route compatibility shim, or new Surface catalog atom shipped.

## v0.35: User Theming And Layout Overrides

Plan: `docs/plans/v0.35-plan.md`
Request flow: `docs/plans/v0.35-request-flow.md`
ADR: `docs/adr/0025-user-theming-and-override-security.md`

Status: implemented and release-ready as `v0.35.0` on 2026-05-24; ready for
operator manual verification. Shifted from v0.33 so v0.31 consolidation,
v0.32 workspace composition, v0.33 app-intent descriptors, and v0.34 workspace
UX landed first.

Prerequisite: v0.31 shared paths/settings fragments, v0.32 workspace-only app
UI and panel-surface substrate, v0.33 app intent descriptor/handoff behavior,
and v0.34 chat-primary workspace shell with view-only launcher and
single-destination Canvas.

Expected direction:

- Add Allbert Home theme roots under `<ALLBERT_HOME>/themes` and
  `<ALLBERT_HOME>/themes/snippets`.
- Add token YAML themes served as `/theme/user.css`, linked after app CSS with
  no asset rebuild.
- Add opt-in sanitized CSS snippets with reject/strip/warn behavior for remote
  fetch and import constructs.
- Add validated `<ALLBERT_HOME>/workspace/layout.yaml` for v0.34 launcher
  destination ordering, hiding, default Canvas destination, and panel pins.
- Add Settings Central keys for theme selection, snippets, and layout override;
  audit those gates/selections, keep raw CSS/YAML in Allbert Home, and expose
  read-only fingerprints/status/diagnostics inside the v0.34 Settings Canvas
  destination.
- Add CSP regression coverage and Chrome verification for desktop/narrow
  workspace retinting, snippet blocking, and layout fallback behavior.

## v0.36: Elixir/OTP Sandbox And Gate Runner

Plan: `docs/plans/v0.36-plan.md`
Request flow: `docs/plans/v0.36-request-flow.md`
ADRs: `docs/adr/0009-local-execution-sandbox-levels.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`

Status: released and tagged as `v0.36.0` on 2026-05-25 after local sandbox
image preparation and M10 full-gate remediation were added. The default
approved local image can now be built and verified through Allbert-owned Mix
tasks. Inserted as the concrete sandbox substrate before dynamic
generation/live integration. v0.36 is
deliberately narrow: Elixir/OTP generated drafts plus explicit shell-command
gate profiles only. It produces reports, not trust grants.

Prerequisite: v0.31 paths/redaction/audit/settings/typed-response facades and a
local container/VM-capable host. Backend selection is OS-aware (`backend=auto`):
optional doctor-gated Apple `container` on supported macOS (Apple silicon,
macOS 26+), rootless Podman where available, Docker+runsc/gVisor preferred over
plain Docker when configured, and Docker as the fallback. Firecracker, remote
builders, broader/cross-version Apple Container features, multi-language
targets, implicit image pulls, and package-manager execution remain future
work.

Implemented:

- Add Settings Central keys and `mix allbert.sandbox doctor`.
- Add `mix allbert.sandbox image build` and `mix allbert.sandbox image verify`
  so the default approved local image is not an undocumented prerequisite.
- Build the approved image with the minimal C/git toolchain needed by real
  Allbert deps, pre-bake compiled dependency artifacts and Dialyzer PLT state
  when available, and seed writable runtime dependency/build/cache paths and
  test DB roots from that baked state.
- Build copy-in/copy-out sandbox bundles with a disposable Allbert Home.
- Include root warning-gate config in default bundles so sandbox Credo and
  Dialyzer use the same policy as host gates.
- Require approved local images; sandbox runs never pull from registries.
- Add static `SourcePolicy` checks for dangerous Elixir constructs in the
  sandbox facade before backend resolution/execution.
- Run only structured reviewed `mix` argv commands for compile, test, Credo,
  Dialyzer, and security-eval gate profiles; `elixir --version` is limited to
  the image-verification setup task.
- Register backends through a static reviewed behaviour/registry with an
  OS-aware `"auto"` resolver; implement Docker and Podman-rootless as
  baseline, prefer Docker `runsc` / gVisor over plain Docker when installed,
  and include Apple `container` as an optional doctor-gated backend that is not
  release-blocking.
- Deny network, secrets, real Allbert Home, package managers, migrations, NIFs,
  ports, arbitrary shell strings, shell chaining, host Docker socket, and
  untrusted core-node module loading.
- Return bounded redacted reports. A sandbox pass grants no authority.
- Keep the opt-in Docker full-gate smoke
  (`ALLBERT_DOCKER_FULL_GATE_TEST=1`) as the local proof that v0.37 can rely on
  a real in-sandbox warning gate pass.
- Emit signals and bounded/redacted sandbox audit records for backend
  resolution, run, gate, denial, and cleanup through the signal-driven runtime.
- Ship operator/developer docs for the new boundary:
  `docs/operator/sandbox-gate-runner.md`,
  `docs/developer/sandbox-gate-runner.md`, security-hardening/onboarding
  updates, runtime-boundary-map updates, and agent-context-map updates.

## v0.37: Dynamic Code & Config Generation and Live Capability Integration

Plan: `docs/plans/v0.37-plan.md`
Request flow: `docs/plans/v0.37-request-flow.md`
ADRs: `docs/adr/0032-dynamic-plugin-generation-and-sandboxed-loading.md`,
`docs/adr/0033-capability-gap-acquisition-and-trust-tiers.md`,
`docs/adr/0035-codegen-agents-and-live-integration-loader.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`

Status: released and tagged as `v0.37.5` on 2026-05-26. v0.37.1
post-implementation audit hardening and final gates completed on 2026-05-25.
The release was reopened before the tag for v0.37.2 capability-first generator
and bounded model-backed committee implementation, v0.37.3 delegated generated
writes, v0.37.4 audit hardening, and v0.37.5 fourth-audit closeout. The
self-extending-runtime engine now has file-backed dynamic drafts, v0.36 sandbox
trial/gate handoff, trusted validation, dynamic lifecycle audit/signals, and
gated live in-core integration for action artifacts. v0.37.2 added
source-bearing LLM-backed read-only action generation through separate
Planner/Author/TrialAuthor/Critic packets plus invoked Repair packets and
proved the full generate -> repair -> gate -> approve -> live run -> rollback
loop. The M16 closeout adds the explicit `request_draft_with_gate/3` workflow facade
so sandbox trial/gate reports and trusted-validation failures can drive bounded
Repair until deterministic evidence passes or workflow-wide limits stop the
attempt.
v0.37.3 lets generated action artifacts declare `:memory_write` or
`:external_network` only when effectful work delegates through a literal,
operator-allowlisted reviewed facade (`append_memory` or
`external_network_request` initially). The delegated facade keeps its normal
Security Central approval behavior; the dynamic action itself remains
non-resumable.
Broader generated app/config targets remain deferred until their validators
exist.
v0.37.4 closes the remaining release-readiness gaps: registered discard
workflow, delegated-write security eval coverage, separate
`:dynamic_codegen_request` permission with default `allowed`, validator
coherence for delegated calls under `run/2`, explicit delegated approval-surface
docs, version metadata closeout, and final release gates.
v0.37.5 moves discard to dedicated `:dynamic_codegen_discard` policy, records
dynamic delegate provenance in facade confirmations, and makes the delegated
facade approval policy explicit without blocking generated actions from running
through reviewed facades.
Highest-capability and highest-risk milestone; its safety rests on the v0.36
sandbox evidence plus operator-confirmed integration.

Prerequisite: v0.36 sandbox/gate runner; v0.24 objective runtime; v0.31
consolidated runtime substrates; v0.25 native-agent + Jido.AI pattern; and the
v0.27-v0.35 contract shapes.

Expected direction:

- Detect a capability gap through the objective runtime.
- Use producer-neutral codegen scaffolding for explicit capability-gap draft
  requests, and implement the v0.37.2 LLM-backed action producer through this
  guarded path.
- Keep Planner, Author, TrialAuthor, Critic, and invoked Repair calls
  model-backed but advisory. `dynamic_codegen.max_provider_calls_per_gap` is a
  settable whole-workflow cap, not a one-call-per-role limit. Deterministic
  validators, v0.36 sandbox tests/gates, and operator confirmation remain
  authority; Critic output can request repair but cannot trust or integrate a
  draft.
- Store draft metadata, source, provenance, repair history, and sandbox reports
  file-backed under `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/`, separate
  from ordinary plugin discovery roots.
- Compile, trial, and gate generated artifacts only through the v0.36 sandbox.
- Integrate only after v0.36 gate pass, v0.37 integrity/static checks, and
  explicit operator confirmation.
- Hot-load and register a gate-passing action artifact live without restart
  through an audited reversible loader; rollback also requires operator
  confirmation and removes live authority. v0.37.3 action authority is either
  pure read-only or delegated to reviewed `append_memory` /
  `external_network_request` facades. Route pages, panels, settings fragments,
  memory namespaces, objective wiring, and child processes remain deferred live
  targets.
- Forbid dependencies, package-manager execution, migrations, NIFs, secrets,
  unrestricted network, core/static module replacement, action shadowing,
  untrusted in-core loading, and integration without the gate or operator
  confirmation.
- Ship operator/developer docs for the new live-integration boundary:
  `docs/operator/dynamic-capability-integration.md`,
  `docs/developer/dynamic-plugin-drafts.md`, security-hardening/onboarding
  updates, app-creation guide updates, runtime-boundary-map updates, and
  agent-context-map updates.

## v0.38: Templated Creation: Plugins, Apps, Tools, and Code Patterns

Plan: `docs/plans/v0.38-plan.md`
Request flow: `docs/plans/v0.38-request-flow.md`
ADRs: `docs/adr/0036-templated-creation-and-pattern-registry.md`,
`docs/adr/0035-codegen-agents-and-live-integration-loader.md`,
`docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md`,
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md`,
`docs/adr/0017-allbert-plugin-contract.md`

Status: released and tagged as `v0.38.1` on 2026-05-27 after M6 closeout,
operator manual verification, disposable-validation cleanup, and workspace
form-contrast polish. Fresh manual-validation homes are bootstrapped by root
`mix phx.server` when `ALLBERT_HOME` or `ALLBERT_HOME_DIR` is set and
`DATABASE_PATH` is absent. The curated, deterministic creation experience sits
on top of the v0.36 sandbox and v0.37 loader: vetted templates are exposed
through Mix tasks, operator-facing workspace flows, and a Canvas Create
surface.

Prerequisite: v0.36 sandbox/gate runner; v0.37 generation/loader engine; the
v0.27-v0.35 contract shapes; the v0.25 Jido.AI pattern; and the v0.34 Canvas
destination model.

Shipped direction:

- A `TemplatePattern` registry of vetted, parameterized patterns: plugin, app,
  LLM tool, scheduled/chron flow, objective workflow, and extensible templated
  code patterns.
- Mix tasks for developers: `mix allbert.gen.plugin` / `gen.app` / `gen.tool` /
  `gen.flow` / `gen.<pattern>`, and `mix allbert.validate_app`; `--target`
  defaults to `./plugins/<name>`, disposable validation can set
  `ALLBERT_TEMPLATE_SMOKE=1` to use
  `<ALLBERT_HOME>/template-smoke/<name>`, and existing roots require explicit
  `--force` plus preview/diff.
- A guided operator creation flow in `/workspace` and a Canvas **Create**
  destination (`workspace:create`): template gallery → parameter form → preview
  → validate → developer-scaffold or operator live integration.
- Two output modes: developer scaffold (inert source under `./plugins/<name>/`,
  no integration) and operator templated creation (reuses the v0.36/v0.37 gated
  path, operator-confirmed and reversible). Live integration in v0.38 covers
  the LLM-tool (action) template only; plugin, app, scheduled/chron flow, and
  objective workflow patterns are developer-scaffold-only because v0.37.5
  loader scope rejects those artifact shapes as live targets. Templated
  drafts share `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with v0.37
  codegen drafts and record `producer: "template_pattern"`.
- Generated output is inert by default: no automatic compile-path change, trust,
  skill enablement, route authority, permission grant, or execution authority.
  Generated theme/snippet/layout stubs are disabled by default.
- Ship operator/developer docs for creation workflows:
  `docs/operator/templated-creation.md`,
  `docs/developer/template-patterns.md`, generator-first updates to
  `docs/developer/how-to-create-an-allbert-app.md`, security-hardening/
  onboarding updates, runtime-boundary-map updates, and agent-context-map
  updates.

## v0.39: First-Run Onboarding And Provider Control

Plan: `docs/plans/v0.39-plan.md`
Request flow: `docs/plans/v0.39-request-flow.md`
ADR: `docs/adr/0047-provider-doctor-contract.md`

Status: implemented as `0.39.0`; ready for operator manual validation before
release tagging. Promoted from `docs/archives/version-1.0-planning-03.md` and
split from the original "Onboarding + Provider + Identity + Active Memory"
bundle — identity slot and Active Memory now ship in v0.39b so each
sub-milestone has its own focused scope.

Implemented shape:

- Onboarding is a registered durable objective that can run from CLI or
  `/workspace?destination=workspace:onboard`.
- Provider/model control-plane UX exists over the Settings Central
  provider/model profile schema through `mix allbert.model` and the workspace
  Settings panel.
- Added explicit `providers.*.endpoint_kind` field
  (`:credentialed_remote | :local_endpoint`) with derivation default and
  operator-overridable safe-key write. Branch selection is field-driven, not
  heuristic.
- Provider doctor has two code paths matching `endpoint_kind`:
  `:credentialed_remote` (bounded probe with redacted summary) and
  `:local_endpoint` (reachability + model presence via `/api/tags` or
  equivalent). Both return the same redacted summary shape pinned by
  ADR 0047 (Tier-1 freeze candidate for v1.0).
- Doctor reports model availability, context window, deprecation hints, and
  recent rate-limit signals — not just credential validity.
- Bumped the shipped `model_profiles.local.model` default from the fictional
  `gemma4:26b` to `llama3.2:3b`, a real small Ollama model. A fresh Ollama
  endpoint without that model reports `model_available: false` with fixed
  remediation; the pass row runs after the operator explicitly pulls the
  shipped default. v0.39 does not auto-run `ollama pull`.
- Provider/model catalog cleanup keeps Settings Central model profiles as the
  only operator-editable model surface. Jido aliases are generated from
  `model_profiles.*`, and the code-generation pair is consistently named
  `coding` / `coding_local`.
- Onboarding's model-assist step toggles `intent.model_assist_enabled`
  (default `false` today) explicitly so picking a profile actually wires up
  model-assisted intent ranking.
- Cross-OS first-run on macOS, Linux, and Windows/WSL2 remains the operator
  manual-validation smoke path per the v1.0 acceptance matrix items 1 and 2.
- Dropped the placeholder "no hidden failover; explicit operator opt-in only"
  wording. Model fallback policy is parked (see `future-features.md`).

## v0.39b: Identity Slot And Active Memory

Plan: `docs/plans/v0.39b-plan.md`
Request flow: `docs/plans/v0.39b-request-flow.md`
Research note: `docs/research/active-memory-retrieval.md`
Operator doc: `docs/operator/active-memory.md`.

Status: implemented as `0.39.1`; ready for operator manual validation before
release tagging. First revision followed the post-v0.38 readiness review on
2026-05-27. New slot split off from v0.39 in the post-v0.37 planning pass so
Active Memory retrieval could land in its own focused milestone.

Implemented scope:

- Adds an optional inert `identity` memory namespace under
  `<ALLBERT_HOME>/memory/identity/` for operator-editable personality/context
  material. Inert content; never grants permission or executes.
- Declares `identity` as a **system memory namespace** through a new
  `AllbertAssist.Memory.SystemNamespaces` module. System namespace
  declarations are merged by a memory namespace facade and use
  `origin: :system`, `app_id: nil`; `:_system` is not an app id and is not
  passed through app validation. This extends but preserves the v0.27
  app-namespace contract.
- Adds `:identity` as a 5th value in `AllbertAssist.Memory.@categories`
  alongside `:notes`, `:preferences`, `:traces`, `:skills`.
  `<ALLBERT_HOME>/memory/identity/` becomes the category root; entries are
  ordinary markdown files surfaced through existing `Memory` helpers.
- Adds deterministic direct-answer Active Memory retrieval using the existing
  v0.21 memory review/retrieval substrate. Scope:
  `{thread_id, active_app, identity}`. Neutral/core context
  (`active_app: nil` or `:allbert`) surfaces identity + general chunks only,
  excluding app-tagged chunks for non-active apps.
- Algorithm: deterministic recency-weighted lexical scoring over
  `review_status: :kept` entries. Top-K bounded (default K=5 chunks, <=2KB
  each). No embeddings; same query + same memory state returns the same chunks
  byte-for-byte (replayable from traces). Snapshot rule: concurrent v0.21
  review changes during scoring land on the next turn. Embedding-backed
  retrieval is a future advisory provider per ADR 0021, not v0.39b.
- Trace metadata renders the retrieved chunk ids, scoring breakdown, and any
  excluded candidates so retrieval is operator-auditable. `## Active Memory`
  section is placed after `## Intent Candidates` and before
  `## Memory Review` in the per-turn trace.
- Extends `mix allbert.memory` with `list --namespace` / `list --category`
  flags and a new `mix allbert.memory retrieve --query` developer/operator
  helper.

## v0.40: MCP Client Integration

Plan: `docs/plans/v0.40-plan.md`
Request flow: `docs/plans/v0.40-request-flow.md`
ADRs: `docs/adr/0038-mcp-client-trust-tier.md`,
`docs/adr/0013-uri-first-resource-identity.md` (mcp:// graduation),
`docs/adr/0047-provider-doctor-contract.md` (MCP doctor fields),
`docs/adr/0009-local-execution-sandbox-levels.md` (stdio startup).

Status: implemented as `0.40.0` and ready for operator manual validation before
release tagging.

Expected direction:

- Add Settings Central `mcp.servers.*` configuration and `secret://mcp/...`
  refs.
- Promote `mcp://` from reserved/inert to a supported Resource Access adapter;
  add MCP operation classes and the `:mcp_tool_call` / `:mcp_resource_read`
  permission classes (floors: tool call confirms, resource read is grant-gated).
- Ship HTTP/SSE transports (through Allbert's `HttpPolicy` SSRF/redaction
  posture) and stdio transports (bounded under ADR 0009). v0.40 uses
  `hermes_mcp` for protocol codec only and keeps runtime egress in
  Allbert-owned transports.
- Register MCP actions: `mcp_doctor_server`, `mcp_list_tools`,
  `mcp_list_resources`, `mcp_read_resource`, `mcp_call_tool`. Tool calls are
  confirmation-gated; resource reads use remembered Resource Access grants per
  `mcp://` scope.
- Keep MCP server schemas descriptive only; Security Central and confirmations
  remain authority. Flip the intent agent's `mcp://` routing from the
  unsupported-resource workflow to the MCP actions (`agent://` stays
  unsupported).
- Validate the first MCP client path against GitHub, calendar, and mail server
  shapes (the v0.42 consumers) plus deterministic mock servers for CI. The
  validation matrix records which panel data is exposed as resources and which
  is tool-only; tool-only reads remain per-call-confirmed unless a later ADR
  amendment changes the trust tier.
- Approved real-server smoke validated official GitHub MCP over read-only stdio:
  doctor completed, tools listed, `get_me` required confirmation and completed
  after approval, and the configured token did not leak into result/audit
  surfaces.

## v0.41: Developer Velocity And Parallel Test Methodology

Plan: `docs/plans/v0.41-plan.md`
Developer flow: `docs/plans/v0.41-request-flow.md`
ADRs: `docs/adr/0049-development-gates-and-test-parallelization.md`,
`docs/adr/0050-vendored-memento-compatibility-override.md`
Developer guide: `docs/developer/test-strategy.md`

Status: implemented. Inserted after v0.40 when full `mix precommit` time became
a developer-velocity blocker. This is a docs/methodology release before the next
operator-facing capability milestone.

Implemented outcomes:

- Measure the current test suite and precommit shape with slowest-module reports
  and a resource-lane inventory.
- Define the lane taxonomy: `pure_async`, `db_serial`, `app_env_serial`,
  `home_fs_serial`, `global_process_serial`, `external_runtime_serial`,
  `liveview_serial`, and `security_eval_serial`.
- Define the isolation contract for per-test and per-partition `ALLBERT_HOME`,
  `DATABASE_PATH`, Settings Central roots, secret roots, memory roots, sandbox
  roots, tmp roots, and process names.
- Define and implement the gate matrix: docs, focused, static, fast-local,
  serial-core, release, and external-smoke gates.
- Define the implementation-plan annotation format so future milestone plans
  name parallel workstreams, serial barriers, gate evidence, and rejoin points
  before coding starts.
- Preserve the authoritative release gate while making focused and fast local
  gates legitimate development evidence.
- Add benchmarked `mix allbert.test fast-local` variants for quick pure-lane
  feedback and high-coverage local core, StockSage, and web serial lanes.
- Carry the temporary `vendor/memento` compatibility override needed for the
  current Jido stack on Elixir 1.19, and remove it when upstream publishes a
  compatible path.

Exit signal:

- ADR 0049 is accepted; ADR 0050 records the temporary Memento compatibility
  override if it is still required at closeout.
- `docs/developer/test-strategy.md` is the routing contract for tests and gates.
- Future feature milestones can name focused gates, serial lanes, and release
  gate requirements, plus which implementation/testing lanes may run in
  parallel versus serial, without rediscovering SQLite/app-env/home/process
  contention.
- Final benchmark evidence records quick `fast-local` under the M1 target and
  the combined high-coverage local gate under the 10 minute target; the
  remaining web `WorkspaceLiveTest` long pole is explicitly left as
  release-only `external_runtime_serial` work for a later plan.

## v0.42: Tool Discovery + MCP-First Integration Pack 1

Plan: `docs/plans/v0.42-plan.md`
Request flow: `docs/plans/v0.42-request-flow.md`
ADRs: `docs/adr/0048-tool-discovery-and-discovered-server-trust.md` (discovery),
`docs/adr/0039-mcp-first-native-plugin-second-integrations.md` (integration).

Status: implemented as `0.42.2`. Promoted from
`docs/archives/version-1.0-planning-03.md`; tightened in the post-v0.37 planning
pass to **MCP-configured only** for calendar/mail/GitHub plus one native
reference plugin (notes/files). The post-v0.40 planning pass added a
**discovery track**, shipped first, that lets Allbert find and connect MCP
servers through a confirmation-gated gate. The 0.42.1/0.42.2 closeout shipped
the discovery permission boundary, live connected-server trust baseline, CLI
contract reconciliation, reference-plugin resilience, concrete integration
effect forms, and deterministic release smoke. Native plugins for the other
integrations move to post-1.0 follow-on releases.

Shipped scope:

- **Tool discovery track:** `find_tools`, a capability search that
  fans out to local tools (registered actions, skills, connected MCP servers) and
  to internet MCP registries (official MCP Registry required; optional keyed
  subregistries such as PulseMCP only when configured) behind a provider port.
  A discovered server connects only through a
  confirmation-gated consent that shows the exact command/URL and records a
  tool-definition baseline hash (rug-pull defense). An opt-in, paused-by-default
  background scan writes candidates to a passive Discovery Suggestions surface; no
  unprompted messaging, no auto-connect. Discovery search egress reuses
  `External.HttpPolicy`; server metadata is never authority.
- Shipped workspace summary panels for **calendar, mail, and GitHub** driven by
  **MCP servers configured in v0.40** (or connected through the discovery gate
  above). No native plugin surface for calendar/mail/GitHub in v0.42.
- Shipped a **`notes/files` native reference plugin** as a starter scaffold for
  plugin authors: minimal app+SurfaceProvider+memory-namespace+intent-descriptor
  example. This is the developer-onboarding reference; StockSage remains the
  depth reference.
- Shipped intent descriptors per integration so v0.33 handoff works.
- Keep integration effects behind registered actions, Resource Access,
  Security Central, confirmations, traces, and audits.
- Native integration plugins for calendar/mail/GitHub graduate to post-1.0
  follow-on releases only when MCP coverage proves insufficient for a
  specific workspace surface or memory-namespace need. Not 1.0-blocking.

## v0.43: Browser And Web Research

Plan: `docs/plans/v0.43-plan.md`
Request flow: `docs/plans/v0.43-request-flow.md`
ADR: `docs/adr/0040-browser-session-and-web-research-policy.md` (binding,
deepened in the post-v0.42 planning pass). Amends
`docs/adr/0013-uri-first-resource-identity.md` to register
`browser://session/<id>` as a supported plugin-owned scheme.

Status: implemented as `0.43.0`. Promoted from
`docs/archives/version-1.0-planning-03.md` and deepened in the post-v0.42
planning pass to v0.02-style per-milestone structure with development-lane
annotations per ADR 0049.

Shipped scope:

- Added the `./plugins/allbert.browser/` reviewed source-tree plugin alongside
  Telegram, email, StockSage, and the notes/files reference plugin. Browser
  process ownership lives in the plugin supervisor; core spawns no browser.
  Operational control uses the reviewed plugin-owned Playwright/Chromium
  bridge; deterministic release tests keep using the stub driver.
- Registered `browser://session/<id>` as the session identity URI (ADR 0013
  v0.43 amendment); navigated URL targets keep their native
  `https://`/`http://` URI and are authorized through per-domain remembered
  grants on the target URL.
- Added the six browser operation classes (`:browser_navigate`,
  `:browser_extract`, `:browser_screenshot`, `:browser_interact`,
  `:browser_form_fill`, `:browser_download`) and the
  `:browser_session` origin kind to `Resources.OperationClass`.
- Added the seven `:browser_*` permission classes to `Security.Policy` with
  documented safety floors: navigation/click/form-fill/download are
  `:needs_confirmation`; extraction/screenshot are `:allowed`; form fill and
  download still default to `:denied` and can never be set to unconditional
  allow.
- Added the plugin-contributed `browser.*` Settings Central namespace with
  `enabled: false` default, read-only `headless`/`profile_mode`/
  credential-redaction invariants, bounded extraction caps, ephemeral profile,
  and a paused-by-default cache sweep job.
- Registered browser actions through the action DSL including `browser_doctor`,
  `browser_start_session`, `browser_navigate`, `browser_extract`,
  `browser_screenshot`, `browser_click`, `browser_fill`,
  `browser_download`, `browser_close_session`, `browser_list_sessions`,
  `browser_sweep_cache`, and `browser_research_handoff`.
  Doctor follows ADR 0047's redacted shape.
- Enforced network policy at two layers: top-level navigation pre-flights
  through a v0.43 browser navigation helper that reuses `External.HttpPolicy`
  checks; subresources and redirects pass through `AllbertBrowser.NetworkPolicy`
  enforced via the driver's request-interception API. Cross-domain redirects
  fail closed.
- Added bounded extraction for HTML, markdown, plain text, and PDF. PDF parsing uses
  a doctor-verified bounded local text-layer parser path inside the browser
  plugin (no embedded JS execution, no follow-on fetch, byte/page caps, parse
  timeout, malformed/encrypted/scanned unsupported inputs fail closed; no host
  parser subprocess in release tests).
- Added screenshot redaction at the driver layer: `type=password`,
  `autocomplete=otp`, `autocomplete=cc-number` nodes are redacted before
  bitmap encoding.
- Added the workspace browser results panel under `:canvas_panels`; the panel calls
  only registered actions, never the driver.
- Added `mix allbert.browser research <url>` as the operator wrapper over the
  registered doctor/start/navigate/extract/close workflow.
- Extended trace redaction: cookies, Authorization, full URLs with userinfo, and
  sensitive query parameter values are scrubbed from `memory/traces/`;
  raw page content lives in `<ALLBERT_HOME>/cache/browser/<session_id>/`,
  not in traces.
- Preserved the routing predicate: v0.10 `external_network_request` and v0.11 inert
  `summarize_url`/`inspect_document` intact; browser is the graduated path
  when extraction needs DOM/JS or the operator explicitly asks.
- Forward-pinned the v0.52 channel approval-primitive amendment: browser
  confirmations are expressible as `:typed_command` (CLI/email),
  `:button` (LiveView/Telegram/Discord/Slack), and `:link` (screenshot
  review).
- v0.47 may mine v0.43 redacted trace envelopes as one pattern source;
  raw page content is out of bounds.

Implementation consumed the locked decisions from `docs/plans/v0.43-plan.md`
§"M1 Locked Decisions": Playwright Chromium through a reviewed local bridge,
macOS + Linux only (Windows/WSL2 parked to v0.43.x), headless-only,
ephemeral-only profiles, the browser-vs-HTTP routing predicate, and
JavaScript-enabled rendering.

Exit signal: a disposable-home operator can enable browser, pass
`browser_doctor` through real local Playwright/Chromium, approve a session
start and a navigation, receive
bounded extracted evidence (HTML/markdown/text/PDF), see a screenshot with
credential inputs redacted, and inspect redacted trace/audit records.
Per-domain grants survive across navigations within a host; cross-domain
redirects fail closed; form fill and download deny by default.

v0.43.x follow-on candidates (not 1.0-blocking): Windows/WSL2 driver
support, persistent profiles + authenticated browser operation, headed
mode, multi-tab/window orchestration, JS evaluation actions, broader
document formats. All parked in `docs/plans/future-features.md`.

## v0.44: Plan/Build Mode And Operator Workflow YAML

Plan: `docs/plans/v0.44-plan.md`
Request flow: `docs/plans/v0.44-request-flow.md`
ADR: `docs/adr/0041-plan-build-and-operator-workflow-yaml.md` (binding,
deepened in the post-v0.43 planning pass). Amends
`docs/adr/0013-uri-first-resource-identity.md` to register `workflow://<id>`
and `plan://run/<objective_id>` as supported schemes.

Status: implemented as `0.44.0`. Promoted from
`docs/archives/version-1.0-planning-03.md`; workflow YAML location was
clarified in the post-v0.37 planning pass, and implementation-readiness
depth was brought to v0.43-style per-milestone structure with
development-lane annotations per ADR 0049 in the post-v0.43 pass. Moved
before channel expansion in the pass-2 roadmap restructuring.

Shipped scope: Plan/Build is a pinnable workspace panel over the v0.24
Objective Runtime; operator-authored workflow YAML lives under
`<ALLBERT_HOME>/workflows/<workflow-id>.yaml`; schema validation derives
from the current action registry snapshot plus step kinds; expressions
use the closed v1 grammar; seven operator-facing Plan-Build actions and
the internal `plan_step_confirm` continuation are registered; approved
workflow runs execute through the Objective Runtime with plan-start and
per-step confirmations, `if:` skips, `on_error` behavior, cooperative
cancel, subagent delegation visibility, and runtime `${steps.*}` output
references. The deterministic `release.v044` gate writes redacted
evidence under `<ALLBERT_HOME>/release_evidence/v044/`.

Expected direction:

- Add Plan/Build as an operator surface over the v0.24 Objective Runtime.
  Plan/Build is a **pinnable panel** on the workspace canvas (ADR 0023/
  0024/0030), NOT a separate destination route. The 2025-2026 prior art
  (Cursor 2.2 Plan Mode panel, Claude Code plan side-panel, Devin plan
  card) all converged on plan-adjacent panels because plans need ambient
  context.
- Treat workflow YAML as declarative input that produces objective steps,
  not a new execution engine. Every produced step still runs through
  `Actions.Runner.run/3`, Security Central, confirmations, traces, and
  audits.
- **User-authored workflow YAML lives under
  `<ALLBERT_HOME>/workflows/<workflow-id>.yaml`**, with id pattern
  `^[a-z0-9][a-z0-9_-]*$`. Discovery is on-demand (no autoload, no
  scan). Each file validates against the v1 schema; unknown keys fail
  closed with JSON-Pointer-bearing diagnostics. The schema is assembled
  from the current `Actions.Registry.modules/0` snapshot +
  `Step.kinds()` so doc and runtime cannot drift across source-tree,
  plugin, and dynamic action overlays.
- Render plan previews (per-step ordinal, kind, action name, params
  summary, permission, safety floor, resources needed, estimated cost,
  confidence tier, confirmations required, subagent target, failure
  blast radius), required capabilities/resources, confirmation points,
  subagent delegation visibility (inline child events under parent
  steps), and background objective progress on existing surfaces
  (workspace, CLI, Telegram, and email). Discord/Slack inherit
  summaries when Channel Pack 1 lands in v0.52.
- Workflow YAML expression substitution uses a **closed function table**
  (`${inputs.x}`, `${steps.<id>.<field>}`, `${user.locale|timezone}`,
  `${workflow.id|version}`); AST-parsed at load. No `eval`. No
  `${secrets.x}`. No `${env.x}`. No dynamic action-name resolution
  (`action: ${...}` rejects).
- v0.24's six step kinds are exhaustive; v0.44 ships no new step kinds.
  Loops, parallel/fan-out, sub-workflow includes, `on:` triggers,
  `env:` blocks, and retry policies are explicitly parked.

M1 locked decisions (six rows; full rationale in `docs/plans/v0.44-plan.md`
§"M1 Locked Decisions"):

1. Plan/Build surface shape — pinnable panel over the workspace canvas;
   NOT a destination route.
2. Workflow YAML expression grammar — closed function table; AST-parsed.
3. Schema validation source-of-truth — derived from the current
   `Actions.Registry.modules/0` snapshot + `Step.kinds()`.
4. File location and id pattern — `<ALLBERT_HOME>/workflows/<id>.yaml`,
   `^[a-z0-9][a-z0-9_-]*$`, on-demand discovery, collisions fail closed.
5. Execution semantics — sequential array order plus per-step `if:`; no
   loops, parallel, sub-workflow, `on:`, `env:`, or retry policies in
   v0.44.
6. Confirmation semantics — action's registered floor is authoritative;
   YAML `confirm: true` may only upgrade; plan-start gate is
   `:workflow_run_start` `:needs_confirmation`.

Exit signal: an operator can author or request a plan, preview the Plan
Preview Contract packet with all fields rendered, edit inputs and
reorder/remove steps, approve the plan-start gate, see the run proceed
through the Objective Runtime with per-step events rendering on
workspace and existing supported surfaces, inspect subagent delegation
inline, and cancel cooperatively with a durable reason. Workflow YAML
with any unknown key, dynamic action name, `${secrets.x}`, `${env.x}`,
cycle, forward ref, unknown action, unknown delegate agent, or
exceeded cap rejects with a structured `error_category` diagnostic.

v0.44.x follow-on candidates (not 1.0-blocking): `for_each`/`parallel:`
step kinds, sub-workflow includes, `on: schedule`/`on: event` triggers,
remote workflow distribution, multi-user collaborative plan editing,
LLM-cost estimators, advisory-provider confidence tier engines. All
parked in `docs/plans/future-features.md`.

## v0.45: Marketplace Lite (Data Shape + Allbert-Author Seeds) - implemented as 0.45.0

Plan: `docs/plans/v0.45-plan.md`
Request flow: `docs/plans/v0.45-request-flow.md`
ADR: `docs/adr/0043-marketplace-lite-trust-tier.md`

Status: implemented as `0.45.0`. Promoted from
`docs/archives/version-1.0-planning-03.md` and tightened in the post-v0.37
planning pass to ship the **data shape and Allbert-author seed bundles only**;
community-submission governance remains parked.

Shipped scope:

- Shipped the catalog **schema**, Allbert-author seed bundles, install path,
  provenance/hash/version/rollback metadata, and disabled/untrusted-on-install
  default.
- Shipped skill, template, and browse-only plugin-index entries for the v0.45
  catalog; no community submissions or external reviewers.
- Community submission/review process remains parked in `future-features.md` under
  "Marketplace Community Submission / Review Governance"; promote post-1.0
  when the project decides on governance.
- Added reviewed-source plugin index metadata without automatic code install.
- Added template catalog metadata for `workspace:create`.
- Added the Marketplace Catalog workspace panel, marketplace intent corpus,
  CLI subcommands, `marketplace_doctor`, deterministic `release.v045` gate, and
  post-implementation remediation for the master disable switch, custom
  Allbert Home-rooted cache/install paths, and workflow-YAML forward-pin
  validation.
- Promoted the closeout follow-up on `mix precommit` /
  `mix allbert.test release` lane decomposition and progress reporting into
  the implemented v0.45.1 developer-tooling patch.
- Kept arbitrary remote code-bearing plugin install, remote dependency
  resolution, remote theme/snippet distribution, and MCP Apps iframe execution
  out of 1.0.
- **Started drafting ADR 0046** (Settings Central schema migration policy) here
  because marketplace adds new settings fragments; ADR is accepted before
  v0.59 implements the migration tool.

## v0.45.1: Gate Transparency And Precommit Decomposition - implemented as 0.45.1

Plan: `docs/plans/v0.45.1-plan.md`
Request flow: `docs/plans/v0.45.1-request-flow.md`
ADR: `docs/adr/0049-development-gates-and-test-parallelization.md`

Status: implemented as `0.45.1`. Inserted after v0.45 closeout when the final
release gate passed but the wrapper still delegated through the old monolithic
`mix precommit` alias and produced opaque long phases.

Shipped scope:

- Added `mix allbert.test commit` and `mix allbert.test prepush`.
- Rewired `mix precommit` to the commit gate; it is no longer release evidence.
- Changed `mix allbert.test release` to run explicit release phases directly
  instead of delegating to `mix precommit`.
- Added timed phase summaries, bounded redacted output tails, full redacted
  phase logs, ExUnit seed capture, and failed-test manifest snapshots for gate
  evidence.
- Updated ADR 0049 and the developer test strategy so commit, prepush,
  release, version-specific release, docs, focused, and external-smoke gates are
  distinct.
- No assistant capability, marketplace behavior, Security Central authority, or
  external smoke semantics changed.

## v0.46: Delegation Hardening And Research Specialist

Plan: `docs/plans/v0.46-plan.md`
Request flow: `docs/plans/v0.46-request-flow.md`
ADR: `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md`
(amendment A21 accepted in M1).

Status: implemented as `0.46.0`; ready for operator manual validation before
release tagging. Inserted in the post-v0.45 planning pass to give the v0.24
delegate-agent substrate a second consumer before the v1.0 freeze. The
v0.47-v0.53 arc shifted down by one to open this slot (the arc later extended to
v0.57 in the 2026-06-09 restructure, then v0.58 in the v0.54 post-audit
renumbering, then v0.59 in the 2026-06-21 replan that reordered v0.55-v0.59 and
inserted the v0.57 Pi-mode coding surface).

Shipped scope:

- Shipped a **second native consumer** of the v0.24 delegate-agent substrate
  (`AllbertAssist.Objectives.AgentRegistry` + the `:delegate_agent` step +
  the `delegate_agent` action). Through v0.45, StockSage financial
  specialists (ADR 0022) are the only registered consumer; freezing the
  contract on one-consumer evidence at v1.0 is the risk this release
  closes (ADR 0021 amendment A21).
- The second consumer is a **plugin-contributed research/summarize
  specialist** at `./plugins/allbert.research/`, registered as
  `research.specialist`. Its `research`/`summarize_url` commands
  orchestrate the already-shipped v0.43 browser navigate/extract actions
  with deterministic extractive fallback, all through `Actions.Runner.run/3`.
- Threaded the delegate step command (`action_params.command`, default
  `execute`) through `Objectives.Commands.execute/4` instead of the
  previous hard-coded `execute`, then hardened the existing `delegate_agent`
  action so that command is validated against registered-agent metadata
  (`execute`, `research`, `summarize_url`) without dynamic atom creation.
  Both are bounded changes at existing surfaces; the step kind stays
  minimal (ADR 0021 A3), with no Step-schema migration.
- **No new authority.** No new permission class, operation class, URI
  scheme, or registered action; only a small `research.*` settings
  fragment (enable toggle + bounded source cap). Every `browser_navigate`
  inside a research dispatch still confirms (or applies a v0.43 remembered
  per-domain grant) - delegation provably does not widen authority.
- **Documented the extension point** (`docs/developer/delegate-agents.md`)
  so third-party plugin authors can register a delegate agent. Exercises
  v0.44 Plan/Build inline subagent-delegation rendering against a
  non-StockSage agent via a `kind: delegate_agent` workflow step.
- M3 added the `mix allbert.research` CLI, inert research intent
  descriptors, the v0.46 `research_delegate` Plan/Build fixture, and
  research-specific inline subagent rendering coverage. The older browser
  handoff descriptor now owns browser-specific page/render/extract prompts;
  v0.46 research phrases route to `research.specialist`.
- M4 added nine `:v046` security eval rows, the deterministic
  `mix allbert.test release.v046` gate, the opt-in
  `browser_research_delegate` external smoke, and the test-env migration
  connection-pool fix that avoids SQL Sandbox ownership contention during
  version-specific release evidence.

Locked decisions (six; full rationale in `docs/plans/v0.46-plan.md`
§"M1 Locked Decisions"): plugin-contributed delegate agent (not core);
zero new authority (orchestrate shipped actions); read-only research scope
(inherits v0.43 deny-by-default); second consumer to harden — not to
abstract or to add operator no-code authoring; allowlisted delegate
commands at the existing action boundary; the engine threads the step
command into that boundary (no longer hard-coding `execute`).

Exit signal: a delegated research objective runs the v0.43 browser
sequence per source with each navigation still confirming inline under the
parent delegate step; research output is advisory and never auto-promotes
to memory; `research.max_sources` bounds fan-out; the browser session is
always closed; an unknown delegate command is rejected at the action
boundary through the objective/Plan-Build path (not only a direct action
call); a third-party plugin can register a delegate agent from the
documented contract; the v1.0 freeze can lock a two-consumer-proven
`AgentRegistry`/`delegate_agent` contract.

Parked remainder: operator no-code delegate-agent authoring (vs.
developer-authored plugin agents) stays in `future-features.md`
§"Operator-Authorable And Third-Party Delegate Agents", routed through the
v0.36/v0.37/v0.47 supervised dynamic path post-1.0.

## v0.47: Operator-Supervised Self-Improvement (Discovery + Local Drafts)

Plan: `docs/plans/v0.47-plan.md`
Request flow: `docs/plans/v0.47-request-flow.md`
ADR: `docs/adr/0045-operator-supervised-self-improvement-trust-tier.md`
(amendments A1–A4).

Status: implemented as `0.47.0`. Split from the original single-release plan
into v0.47 (discovery + local drafts) and v0.47b (handoff drafts), following
the v0.39b/v0.45.1 pattern, so the discovery substrate and inert non-code
drafts landed on a proven base before the code-bearing and catalog-backed
kinds.

Shipped scope:

- Built a read-only **trace index** over `<ALLBERT_HOME>/memory/traces/` so
  repeated prompts, action chains, corrections, and failed intents are
  queryable; it inherits trace redaction and grants nothing (ADR 0045 A1).
- **Generalized the v0.42 discovery suggestion surface**
  (`Tools.Discovery.Suggestion` + `Workspace.DiscoverySuggestions`) to carry
  self-improvement suggestion types: one queue, one panel (ADR 0045 A2).
- Added a read-only `discover_patterns` action (modeled on `find_tools`) that
  reads the index plus objective events and memory review decisions, then
  writes only inert suggestions.
- Created **skill, workflow, and memory drafts** behind **one unified
  reviewed-draft facade**, generalized from the v0.37 `DynamicPlugins.Draft`
  lifecycle (ADR 0045 A3, ADR 0032 amendment). Existing source-bearing dynamic
  drafts remain compatible under `<ALLBERT_HOME>/dynamic_plugins/drafts/`;
  workflow drafts reconcile the ADR 0041
  `<ALLBERT_HOME>/drafts/workflows/` root.
- Kept every suggestion advisory and every draft inert; promotion to a live
  skill/workflow/memory entry is a separate confirmed action through the
  existing path.

Locked decisions (five; full rationale in `docs/plans/v0.47-plan.md`
§"M1 Locked Decisions"): one unified reviewed-draft store; generalize the
v0.42 suggestion surface; build a redaction-respecting trace index;
discovery + non-code local drafts only (handoff drafts are v0.47b); the
discovery action mirrors `find_tools`.

Exit signal: a read-only discovery scan proposes inert suggestions from a
redaction-safe trace index; suggestions render in the generalized v0.42 panel
and expire per policy; skill/workflow/memory drafts are created inert in one
unified store and discarding them leaves nothing; promotion writes a live
artifact only through an existing confirmed action; no trace signal,
suggestion score, or repeated approval grants permission by itself.

Non-goals:

- No autonomous skill creation; no auto-enable, auto-publish, package
  install, or remote plugin install from trace patterns.
- No small-model/personality distillation or learned system-memory authority.
- No unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation outside the v0.36/v0.37/v0.38 review path.
- No settings, secrets, shell, package, confirmation-decision, trust-control,
  or live workspace/canvas write facades.
- No code-bearing, template-backed, marketplace-backed, delegate-plugin,
  capability-gap, or objective drafts — those are v0.47b.
- No distributed multi-node or hosted multi-user execution model.

## v0.47b: Operator-Supervised Self-Improvement (Handoff Drafts)

Plan: `docs/plans/v0.47b-plan.md`
Request flow: `docs/plans/v0.47b-request-flow.md`
ADR: `docs/adr/0045-operator-supervised-self-improvement-trust-tier.md`
(amendments A5–A7).

Status: implemented as `0.47.1`. Inserted between v0.47 and v0.48 (no renumber
of v0.48+) and shipped as the `0.47.1` point release on top of v0.47.

Shipped scope:

- On the v0.47 discovery substrate and unified draft store, added the draft
  kinds that hand off to shipped substrates: **template-backed** (v0.38
  `Templates.Registry`/`create_from_template`), **marketplace-backed** (v0.45
  `Marketplace.list_entries/1`, descriptive only), **inert delegate-plugin
  draft requests** (v0.46 contract via the v0.38 plugin template),
  **capability-gap** (v0.37 `DynamicPlugins.request_draft/2` →
  `Sandbox.run_gate/2` → `Loader.integrate/2`), and **objective** drafts.
- Code-bearing drafts reach live authority only through the existing v0.36
  sandbox + v0.37 trusted-validation/gate/loader path plus operator
  confirmation, with rollback available (ADR 0045 A6).
- Marketplace metadata stays descriptive; delegate-plugin drafts stay inert;
  objective drafts stay declarative (ADR 0045 A5, A7).
- Added seven v0.47b security eval rows plus the deterministic
  `mix allbert.test release.v047b` gate.

Non-goals:

- No new sandbox/gate/loader and no new trust tier; v0.47b stays inside the
  v0.47 self-improvement tier.
- No operator no-code delegate-agent authoring (stays parked).
- No marketplace submission/publishing automation; submission stays a
  confirmed operator action.
- No autonomous creation, distillation, or unsupervised self-recompilation.

Exit signal: template-backed, marketplace-backed, delegate-plugin,
capability-gap, and objective drafts are created inert in the v0.47 unified
store; a code-bearing draft reaches live authority only through the existing
sandbox/gate/loader path plus confirmation; marketplace metadata grants
nothing and a delegate-plugin draft registers no agent.

## v0.48: Voice Modality

Plan: `docs/plans/v0.48-plan.md`
Request flow: `docs/plans/v0.48-request-flow.md`
ADRs: `docs/adr/0051-provider-capability-preferences.md`,
`docs/adr/0042-audio-image-and-media-resource-classes.md`,
`docs/adr/0047-provider-doctor-contract.md`,
`docs/adr/0052-local-voice-runtime-endpoint.md`

Status: implemented through M8R real-provider remediation and M8R7 local
voice runtime remediation. M1-M8 landed provider
capability metadata, ranked preferences, capability-aware voice doctors, the
audio resource/security substrate, CLI fixture transcription, workspace
microphone capture, fixture TTS, Telegram voice-note ingestion, ten first-pass
`:v048` voice-modality eval rows, and deterministic first-pass `release.v048`
evidence. M8R then added real local OpenAI-compatible adapter calls, OpenAI
remote STT/TTS, Gemini remote STT/TTS, Ollama-backed local text-loop
validation, six more `:v048` eval rows, expanded `release.v048`, and the
manual `.env` live-smoke script. M8R7 adds the Allbert-owned, Settings
Central-configured, Security Central-managed local voice runtime endpoint so
the local path is not an operator-supplied mystery server.
Current authority is the v0.48 plan/request-flow plus ADR 0011, ADR 0051,
ADR 0042 audio amendments, ADR 0047, and ADR 0052; the older archive source is
historical context only.

Expected direction:

- Generalize the existing provider/model framework with capability metadata and
  ranked operator preferences before wiring voice consumers.
- Add media/profile metadata for input/output modality, transport mode,
  deployment mode, accepted audio formats, and audio bounds without treating
  that metadata as permission.
- Add executable STT/TTS capability as media resources and registered actions,
  not as a separate runtime or separate provider system.
- Add CLI file transcription, workspace microphone affordance, TTS, and
  Telegram voice-note ingestion as transcribed runtime input.
- Keep captured audio bounded, redacted from traces by default, and retained
  only by explicit operator policy.
- Ship display-only provider/cost metadata for STT/TTS action results; unified
  dashboards and budget enforcement remain parked.
- Prove the feature through deterministic real-adapter/runtime fixtures in
  `mix allbert.test release.v048`, then run opt-in live smokes for OpenAI,
  Gemini, the Allbert local voice runtime, and Ollama before manual validation.
- Defer Discord voice support to a focused follow-on after Discord lands in
  v0.52.
- Keep realtime speech sessions, generic audio understanding, and video input
  as metadata/future-planning concerns unless a later plan explicitly accepts
  them.

## v0.49: Vision And Image Generation

Plan: `docs/plans/v0.49-plan.md`
Request flow: `docs/plans/v0.49-request-flow.md`
ADRs: `docs/adr/0051-provider-capability-preferences.md`,
`docs/adr/0042-audio-image-and-media-resource-classes.md`,
`docs/adr/0047-provider-doctor-contract.md`

Status: implemented as `0.49.0`; v0.49 M7-M10 remediation is complete and
ready for operator manual validation before release tag. Current authority is
the v0.49 plan/request-flow plus the v0.48 provider capability substrate; the
older archive source is historical context only.

Shipped direction:

- Consume the v0.48 provider capability and preference substrate instead of
  adding image-specific provider routing.
- Add image and screenshot resources for operator-supplied paste/upload and
  browser-screenshot workflows.
- Add vision-capable provider/model checks to the provider doctor path.
- Add image generation as a registered action with provider profile,
  display-only cost metadata, workspace rendering, retention, and redaction.
- Prove ReqLLM provider/model support from the app-started runtime in M1;
  no-start probes and stale sample model IDs are not release evidence.
- Completed post-M6 release remediation before tag: deterministic gate
  hardening, env-gated live OpenAI/Gemini vision/image smokes, explicit local
  Ollama multimodal-profile proof including Gemma 4 as a vision-input
  candidate, and status/evidence drift closeout.
- Treat `video_input` as shared vocabulary/future metadata only; v0.49 does not
  implement video ingestion, generic audio understanding, or video generation.

## v0.50: Artifacts Central

Plan: `docs/plans/v0.50-plan.md`
Request flow: `docs/plans/v0.50-request-flow.md`
ADRs: `docs/adr/0053-content-addressable-artifact-store.md`,
`docs/adr/0054-artifact-provenance-and-browser-surface.md` (provenance linking +
browser-surface split), `docs/adr/0042-audio-image-and-media-resource-classes.md`
(artifact resource class amendment),
`docs/adr/0031-settings-schema-fragments-and-authority.md`,
`docs/adr/0046-settings-schema-migration-policy.md`

Status: implemented as `0.50.0` and released through the `v0.50.1` Artifacts
Browser sidecar tag on 2026-06-09. Inserts a content-addressable artifact store between v0.49 vision and
v0.52 Channel Pack 1, so durable media has one canonical home before channels
begin forwarding attachments. Built on Allbert Home, Resource Access, Security
Central, Settings Central, and the Jido action framework — a thin CAS over BEAM
primitives (`:crypto` SHA-256 + sharded objects + atomic writes), not a
third-party store. The CAS-specific Hex packages (hashfs, scarab) are abandoned
and metadata-free; upload utilities (waffle, Capsule) are not content-addressed
stores; so the store is owned in-tree. M1 has landed the Home-rooted
`artifacts_root`, sharded SHA-256 object store, and markdown metadata sidecar
index. M2 has landed `artifact://sha256/<hex>` identity, artifact permissions
and operation vocabulary, artifact redaction, and pre-write bounds enforcement.
M3 has landed the persisted `artifacts.*` fragment, core artifact actions,
delete confirmation, `artifact_doctor`, retention honoring, and supervised
mark-and-sweep GC. M4 has landed `artifact_thread_links`, message-precise and
thread-level provenance recording from `context.request`, by-thread
`list_artifacts`, and reverse `artifact_threads`. M5 has formalized the
audio/images/generated-image Home roots as retained-media backfill inputs, added
retained-media backfill into CAS, and routed generated-image, workspace voice,
and workspace image retained writes through Artifacts Central while leaving
transient scratch unchanged. M6 has landed the first supervised
`Jido.Sensor.Runtime` path for retained-media ingestion: the sensor emits
redacted `allbert.artifact.ingest_requested` signals to an explicit
`IngestionConsumer` dispatch target, and retained writes still store only
through the registered `put_artifact` action.
M7 has landed the `:v050` artifact-store eval rows, operator/developer/security
docs, version/changelog closeout, and deterministic `release.v050` evidence.
The 2026-06-09 post-implementation remediation cleared the Dialyzer/Credo gate
drift and the full `mix allbert.test release` handoff is green.

Expected direction:

- Add a uniform content-addressed store for artifacts supplied by the operator,
  created by Allbert, or found by Allbert through approved tools such as browser
  research. The artifact is type-agnostic: audio, video, images, PDFs, text,
  office documents, and more.
- Keep artifact identity independent of transport-specific resource URIs:
  `image://`, `screen://`, `browser://`, generated-media handles, and future
  channel attachments may point at or derive from the store, but they do not
  become the store's authority model by themselves. Durable identity is an
  `artifact://sha256/<hex>` content address.
- Record provenance, MIME/type metadata, byte/hash metadata, redaction status,
  retention policy, source surface, and lifecycle state without storing raw
  sensitive content in traces or audits.
- Define the promotion/retention path from temporary v0.48 audio and v0.49
  media input/output files into durable artifacts, including deduplication and
  operator removal; backfill retained `<ALLBERT_HOME>/audio`,
  `<ALLBERT_HOME>/images`, and `<ALLBERT_HOME>/generated_images` from the
  existing `voice.audio.retention_root`, `vision.media.retention_root`, and
  `image.generation.retention_root` setting keys, while leaving ephemeral
  scratch and historical Browser cache files out of the M5 backfill.
- Add `put_artifact`/`get_artifact`/`list_artifacts`/`delete_artifact`
  registered actions and the codebase's first Jido ingestion sensor
  (`use Jido.Sensor`, supervised by `Jido.Sensor.Runtime`), wired through the
  existing `Actions.Registry` and `Actions.Runner`; the sensor emits
  ingestion-request signals to an explicit dispatch target and never writes
  around `put_artifact`.
- Link artifacts to the threads/messages that created or referenced them via an
  `artifact_thread_links` SQLite join table (role created_by/referenced_by) from
  `context.request`, with a by-thread query and reverse lookup; the link is
  provenance, never authority.
- Add `:v050` artifact-store eval rows and `mix allbert.test release.v050`
  evidence under `<ALLBERT_HOME>/release_evidence/v050/`.
- Preserve Security Central and Resource Access as the authority boundary:
  content-addressed identity never grants read/write/send permission by itself.

The operator browsing repository ships separately as v0.50b below.

## v0.50b: Artifacts Browser

Plan: `docs/plans/v0.50b-plan.md`
Request flow: `docs/plans/v0.50b-request-flow.md`
ADRs: `docs/adr/0054-artifact-provenance-and-browser-surface.md`,
`docs/adr/0015-allbert-app-contract-and-surface-dsl.md`,
`docs/adr/0017-allbert-plugin-contract.md`,
`docs/adr/0024-app-ui-contribution-and-workspace-zones.md`

Status: released and tagged as `v0.50.1` on 2026-06-09. This is a focused
sidecar after v0.50 (the v0.47b-after-v0.47 shape), depending on the v0.50 core
read actions.

Expected direction:

- Ship the operator browsing repository for Artifacts Central as a plugin/app
  (`plugins/allbert.artifacts/`, plugin id `allbert.artifacts`), modeled on
  StockSage and `allbert.browser`, not as core. It reads the store only through
  core `:artifact_read` actions. M1 has added the shipped plugin/app scaffold,
  workspace panel, discovery allowlist, and metadata-only Chrome-validated
  panel render. M2 has added the plugin-owned detail LiveView route with Chrome-
  validated metadata/provenance rendering, invalid-SHA handling, and
  confirmation-gated delete request. M3 has added the plugin-owned
  `mix allbert.artifacts list|show|threads|doctor|rm` CLI over core actions.
  M4 has added panel + CLI filters by type, origin, thread, since date,
  retention, lifecycle, and limit without introducing a new index.
- Contribute a workspace `:canvas_panels` Artifacts panel, an
  `/apps/artifacts/<sha>` detail page (route in the core router, module
  plugin-owned, implemented in M2), and a `mix allbert.artifacts` CLI
  (implemented in M3; filter options implemented in M4).
- Browse, search, and filter by type, origin, thread, and date, including the
  by-thread and reverse-thread provenance lookups from v0.50.
- Render redacted metadata only (raw bytes never in assigns/page/CLI); the
  plugin grants no authority and owns no store internals; delete routes through
  the core confirmation-gated action.
- Add `:v050b` artifact-browser eval rows, `mix allbert.test release.v050b`,
  and deterministic browser-validation fixture seeding so `/apps/artifacts/<sha>`
  screenshots use a real seeded SHA recorded in release evidence. M5 has landed
  the eval rows, release lane, operator/developer guides, `0.50.1` version
  metadata, CHANGELOG closeout, and fixture evidence for SHA
  `c9a2b5ecd64bfc421d4aac9c308cf5d02d899b16b6d2f48d85bf482e6a8060b2`.
  The 2026-06-09 post-implementation remediation re-ran `release.v050b` and
  the full `mix allbert.test release` gate successfully. Chrome extension
  revalidation passed on a disposable `http://localhost:4062` server after a
  full Chrome restart cleared a wedged extension/native-host session; browser
  control verified the filtered workspace panel, detail route metadata and
  provenance, metadata-only redaction, return link, and zero detail-page console
  warnings/errors.

## v0.51: Public Protocol Surfaces

Plan: `docs/plans/v0.51-plan.md`
Request flow: `docs/plans/v0.51-request-flow.md`
ADRs: `docs/adr/0044-public-protocol-exposure.md` (exposure — which surfaces,
what's exposed; re-decided for the expanded v0.51 scope),
`docs/adr/0055-inbound-public-surface-trust-tier.md` (inbound trust — permission
class, per-client auth, rate-limit, API secure-header posture, poll-by-id readback)

Status: implemented as `0.51.0`; ready for operator manual validation before
release tag. Promoted from a point release (was v0.52b) to a full release and
expanded in the 2026-06-09 restructure, then resequenced ahead of the channel
packs.

Expected direction:

- Allbert exposes its registered actions as MCP **tools** and memory
  namespaces (per app) as MCP **resources**. Symmetric to the v0.40 MCP client
  work.
- Beyond the MCP tools/resources surface, v0.51 adds an
  **OpenAI-compatible HTTP API** and an **ACP server** surface (re-decided in
  ADR 0044, Phase B). The public
  **AG-UI/A2UI bridge stays parked** in `future-features.md`.
- External clients (Claude Desktop, Cursor, ChatGPT MCP, ACP/OpenAI-API agents)
  never receive more authority than local workspace users.
- External clients cannot approve their own confirmations; Approval Handoff
  remains operator-owned and renders through the workspace or origin channel.
- Conversational protocol requests enter through `Runtime.submit_user_input/1`;
  all effectful work still routes through `Actions.Runner.run/3`, Security
  Central, confirmations, Resource Access, traces, and audits.
- **Inbound trust tier (ADR 0055):** a new `:public_surface_call_inbound`
  permission class with a `:needs_confirmation` floor, per-client Settings-Central
  tokens, a net-new inbound rate-limiter, and an API secure-header posture govern
  HTTP-bearing surfaces. Stateless clients retrieve confirmation-gated results
  via a poll-by-id readback action (`:agent`-exposable, client-scoped, never
  before operator approval) — genuinely new substrate, not a thin adapter.
- v0.51 is a text-first protocol subset. OpenAI/ACP image, audio, resource,
  filesystem-root, and client-supplied MCP-server payloads do not grant media,
  filesystem, or MCP-client authority; unsupported content is rejected unless a
  later capability-specific plan exposes it.
- The MCP surface targets the protocol versions supported by pinned
  `hermes_mcp` 0.14.1 (`2025-03-26` / `2025-06-18` where available), not
  unverified latest-MCP parity. The OpenAI-compatible surface is a bounded
  Chat Completions shim, not full OpenAI API or Responses API parity.
- M7 adds 34 `:v051` public-protocol security eval rows,
  `mix allbert.test release.v051`, operator/developer guides, and release
  evidence:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-13250/home/release_evidence/v051/release-v051-1781040338.json`.
  The full release gate also passed:
  `/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-13250/home/release_evidence/gates/release-2026-06-09T21_27_25Z.json`.

## v0.52: Channel Pack 1 (Discord And Slack) + Cross-Channel Conversation Threading

Plan: `docs/plans/v0.52-plan.md`
Request flow: `docs/plans/v0.52-request-flow.md`
ADRs: `docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md`
(v0.52 amendment — channel boundary + approval primitives),
`docs/adr/0056-channel-inbound-trust-tier.md` (NEW — the
`:channel_message_inbound` permission class + floor + per-interaction
clicker-authorization; channel counterpart to ADR 0055),
`docs/adr/0057-cross-channel-conversation-threading.md` (NEW — canonical thread
model, `thread_channel_refs` / `conversation_message_refs` /
`cross_channel_identity_links` tables, owner/account/key scope fields,
`threading:` capability + degradation ladder, echo-loop suppression, explicit
identity links, unified history view, explicit resume)

Status: released as `v0.52.0`. Implemented as `0.52.0`; real-provider Discord and
Slack validation (per-provider smokes + live operator manual checks) completed
2026-06-14 and tagged `v0.52.0` (see `CHANGELOG.md` "Post-implementation
validation"). The pass-3 zoom-out expanded the milestone
from "Discord + Slack" to "Discord + Slack + a system-wide cross-channel
conversation-thread construct (ADR 0057), with Telegram/email/web/CLI
retrofitted"; pass-4 hardening locked the owner/account/key schema and runtime
handoff so provider ids cannot become canonical authority. Substrate-first, one
version, nine milestones (M0-M8). Promoted from
`docs/archives/version-1.0-planning-03.md`.

Expected direction:

- **Cross-channel conversation threading (ADR 0057):** the existing
  `conversation_threads.id` is the canonical thread id; durable SQLite tables
  (`thread_channel_refs`, `conversation_message_refs`, and
  `cross_channel_identity_links`) map it per channel using `owner_scope`,
  `receiver_account_ref`, and deterministic `provider_thread_key` fields.
  v0.52 writes `owner_scope: "local"` only, preserving a post-1.0
  multi-user/multi-tenant migration path without introducing hosted tenancy.
  A per-adapter `threading:` capability
  (`:native_threads | :reply_chain | :flat | :rich`) drives reply placement + a
  degradation ladder; a unified read-only history view + an explicit
  `resume_thread_on_channel` action + explicit (never auto-merged)
  cross-channel identity links. Telegram/email/web/CLI are retrofitted onto the
  substrate (M6) with byte-equivalent existing output.
- Add Discord and Slack source-tree channel plugins.
- Reuse v0.16 channel identity, event dedupe, runtime submission, Approval
  Handoff, and redaction boundaries.
- Prove workspace/server identity mapping, group/channel authorization, mention
  handling, threaded replies, and callback affordances.
- Lock the provider-thread bridge: Slack `thread_ts` / root message `ts` and
  Discord thread-channel / `message_reference` metadata scope channel
  `session_id` continuity and reply placement, but internal Allbert
  conversation `thread_id` remains runtime-owned by
  `Conversations.resolve_thread/1`.
- **Amend ADR 0016** to declare the four standardized approval primitives —
  `{list, button, typed_command, link}` — each channel adapter declares its
  supported subset in its plugin descriptor; `Approval.Handoff` picks the
  highest-fidelity primitive available from an effective descriptor that
  honors provider settings such as `render_approval_buttons: false`. Telegram:
  button. Email: typed_command. Discord: button. Slack: button. Mobile
  channels (v0.53) inherit the same contract.
- **Introduce ADR 0056 (Channel Inbound Trust Tier):** a new
  `:channel_message_inbound` permission class (floor `:needs_confirmation`),
  the channel counterpart to v0.51's ADR 0055, with a per-interaction
  clicker-authorization invariant (the clicker is re-resolved on every button
  tap, never trusted from the payload) and ack-before-runtime ordering.
- **Transport vehicle locked by an M0 spike** (raw `Req` + reviewed WS client vs
  Nostrum / `slack_elixir`), reconciled with the Req-only rule and ADR 0050.
  Discord reads free-text only on @mention + DM via the privileged
  `MESSAGE_CONTENT` intent; Slack via mention + DM in Socket Mode.
- `mix allbert.test release.v052` is the deterministic fast/CI gate for the
  implemented surface. `mix allbert.test external-smoke -- discord_slack`
  records real outbound/threading/echo evidence against sandbox Discord and
  Slack providers, and operator manual validation covers live inbound delivery,
  button approval, and unmapped-clicker rejection before the v0.52 tag.

## v0.53: Channel Pack 1 Retro-Validation (Telegram, Email) + Channel Pack 2 (Matrix, WhatsApp, Signal) + System-Wide Custody/Trust Constructs

Plan: `docs/plans/v0.53-plan.md`
Request flow: `docs/plans/v0.53-request-flow.md`
ADRs: `docs/adr/0056-...` (v0.53 amendment — public signed webhook),
`docs/adr/0057-...` (threading substrate consumed),
`docs/adr/0058-key-custody-and-channel-daemon-supervision.md` (NEW),
`docs/adr/0059-channel-trust-class-and-relay-gating.md` (NEW),
`docs/adr/0066-capability-release-availability-gate.md` (Accepted).

Status: released and tagged as `v0.53.0` on 2026-06-21 after M11. Version
metadata for the historical v0.53 implementation was `0.53.0`; current mainline
metadata is `0.54.0` because v0.54 has already closed. **Telegram + email live
real-provider validation is done
(2026-06-17):** email surfaced and fixed three IMAP/SMTP bugs (login/select 3-tuple,
verified-TLS SMTP, success-as-error normalization — see CHANGELOG v0.53 §Fixed);
Telegram doctor + delivery + inbound smokes passed with **0 code bugs**, and both
channels' approval/rejection/poll-resume manual checks passed after v0.54 landed
the required router/descriptor/outbound prerequisite. **Matrix real-provider
validation is done (2026-06-18):** delivery and inbound smokes passed, mapped
approval callbacks processed, unmapped callbacks were rejected, and the release
owner accepted the encrypted-room exclusion as validated for this pass.
**Discord + Slack v0.53 M11 regression validation is done (2026-06-21):**
delivery and inbound smokes passed for both v0.52-released channels after M11
shared-channel changes.
WhatsApp Cloud API is implemented but live Cloud API validation is
provider-blocked/deferred after Meta returned object/permission and
unregistered-account failures in both the developer UI and Graph API; the
signed-webhook auth path remains covered locally by `whatsapp post-webhook` and
deterministic evals. Signal is implemented as a `signal-cli` bridge, but live
validation is parked in `future-features.md` because it requires
operator-managed daemon/linked-device onboarding that is too high-friction for
v0.53 release authority. M11 records and enforces both as
implemented-not-released via plugin-owned YAML release declarations under ADR
0066, with undeclared capabilities released by default for compatibility.
Scope: first retro-validate
**Telegram + email** to Discord/Slack live-provider parity (done), then build
**Matrix + WhatsApp (Cloud
API) + Signal (signal-cli daemon)**; **Viber** documented on paper as a validated
WhatsApp-twin and **deferred** (~€100/mo standing bot fee); **iMessage + SMS
parked**. Public protocol interop is v0.51.
v0.53 now **opens with a Channel Pack 1 retro-validation milestone (M5)**: the
first real-provider live validation of the already-shipped Telegram and email
channels — brought to Discord/Slack parity (per-provider external smokes,
provider doctors, operator guides, and live manual checks) — before building
Matrix/WhatsApp/Signal.

Expected direction:

- v0.53 is not "three more plugins" — it **finishes the system-wide constructs
  v0.52 declared but did not build**, because Matrix/WhatsApp/Signal force them:
  - **Key Custody (ADR 0058):** an in-BEAM `:sensitive` decrypt-once secret-
    custody GenServer (0 new deps; `:crypto` + `plug_crypto`) replacing
    decrypt-on-every-read, plus supervised external `signal-cli` daemon custody
    (muontrap/erlexec, 0600 keys + preferred 0600 UNIX socket, or loopback
    TCP/HTTP only with auth/ACL controls). Explicitly does **not** claim
    locked/zeroed memory (not achievable on the BEAM).
  - **Channel trust-class gating (ADR 0059):** completes ADR 0057's E2EE-origin
    promise — a `trust_class` field (`:e2ee_origin`/`:server_readable`/`:local`),
    the unified view excludes cross-channel E2EE-origin content by default
    (audited opt-in), resume-onto-weaker-class requires an audited confirmation.
    Retrofits the web + CLI unified view.
  - **Public signed webhook (ADR 0056 amendment):** WhatsApp Cloud API verifies
    `X-Hub-Signature-256` raw-body HMAC before parse, reusing the v0.51 HTTP
    ingress controls (body cap, secure headers, rate-limit) through a
    webhook-aware raw-body/pre-parser branch.
  - **Descriptor flag consumption + phone-PII redaction:** wire the v0.52
    declared-only `reply_key_type` (Signal timestamp) / `quote_ttl_ms` (WhatsApp
    30-day degrade); redact E.164 phone numbers; Signal keys on ACI, not phone.
- Channels (corrected from the skeleton): **Matrix** = raw `Req` + `/sync`,
  **unencrypted rooms only** (no Elixir E2EE), `:native_threads`/`:reply_chain`,
  `typed_command`/`link`/`list` (no portable Matrix bot-button primitive).
  **WhatsApp** Cloud API, `:reply_chain` + quote-TTL, in-session `:button` with
  `typed_command`/`link`/`list` fallback, `:server_readable`. **Signal** via
  `signal-cli`, `:reply_chain` reply-by-timestamp, ACI identity,
  `typed_command`/`link`/`list`, `:e2ee_origin`.
- Substrate-first sequencing: Channel Pack 1 retro-validation (M5) and
  constructs (M0-M4) before adapters (M6-M8); pairing/identity/delivery (M9);
  evals + **completed Telegram/email retro-validation, completed Matrix
  real-provider live smokes, parked WhatsApp Cloud API live validation, parked
  Signal advanced-bridge live validation** + capability release availability
  closeout (M11).
- Keep SMS, iMessage, the Viber build, WhatsApp Cloud API/Baileys onboarding, and
  Signal advanced-bridge onboarding parked in `future-features.md`.

## v0.54: Intent Deepening

Plan: `docs/plans/v0.54-plan.md`
Request flow: `docs/plans/v0.54-request-flow.md`
ADRs: `docs/adr/0060-...` (two-stage router + approval-gate separation, Accepted),
`docs/adr/0061-...` (local embedding + router model tiers, Accepted),
`docs/adr/0062-intent-descriptor-lifecycle-generation-and-operator-curation.md`
(NEW; M9; Accepted),
`docs/adr/0063-outbound-compose-actions-email-calendar-channel.md` (NEW; M10;
Accepted). Amends ADR 0019/0034.

Status: released and tagged as `v0.54.0` on 2026-06-17. `mix allbert.test release.v054`
passed, the two-stage router is the default selector, and version metadata is
`0.54.0`. Live
local-model validation surfaced ReqLLM/Ollama integration fixes, slot/param seam
hardening, Discord validation-tool fixes, descriptor grammar fixes, and outbound
descriptor fixes (all shipped; see v0.54-plan.md Appendix B). v0.54 now unblocks
v0.53 approval validation after the tag.

Expected direction:

- A local-first **two-stage intent router** (ADR 0060/0061): embedding prefilter
  → constrained LLM disambiguation over a shortlist → confidence gate, as the
  **default selector**, with the deterministic ladder kept as fast-path + offline
  fallback. Local text-embedding capability + US-origin router model tiers
  (nomic-embed-text + llama3.1:8b default + local gemma4:26b escalation).
- **Removes the app-handoff channel dead-end**: a channel message that maps to a
  `confirmation: :required` action now executes and reaches the approve/deny
  primitive instead of proposing inert text. This is the v0.53 channel approval
  blocker found in live validation (2026-06-16).
- The original deepening (ADR 0019/0034: `Intent.Engine`, `Classifier`,
  `Descriptor`/`Handoff`): stronger classification, bounded multi-turn context,
  generalized disambiguation, and a TTL'd clarification turn-state.
- **M9 — intent descriptor lifecycle foundation (ADR 0062):** the audit baseline
  was **192** registered actions, **47** effective agent-routable actions, and
  **12** descriptor-backed actions. v0.54 expands coverage the canonical way
  (`intent_descriptors/0`, dual-source app- and action-module), stores generated
  and override descriptors as data-only YAML, layers them through
  `DescriptorResolver`, supports audited CLI curation, adds heuristic
  local-only generation via `mix allbert.intent optimize`, and reindexes on
  dynamic-codegen registration signals. Generated descriptors for dynamic/write-code
  actions are inert until operator-promoted unless explicitly autoaccepted.
  Routable != executable. The web Intents panel remains v0.58.
  **Moved to v0.56:** local-model descriptor generation, learned-review proposal
  mining, the `optimize_intent_descriptors` action, and full app/plugin/action
  registration signals.
- **M10 — outbound compose actions (ADR 0063):** three NEW effectful actions for
  intents the router can recognize but couldn't execute — `send_email` (wraps the
  existing SMTP send), `send_channel_message` (per-adapter outbound with
  identity-allowlist + trust-class gating before dispatch), `create_calendar_event`
  (via a configurable calendar **MCP** server id; graceful degrade if none). Each
  is `confirmation: :required` behind the existing gate. Matrix generic outbound
  gracefully degrades in v0.54 and is deferred to **v0.55 M1**.
- Keep model output advisory re: authority; intent never grants authority; the
  approval gate stays a separate layer (ADR 0019, ADR 0060, ADR 0062, ADR 0063).

## v0.55: Channel Parity + TUI/Terminal Channel

Plan: `docs/plans/v0.55-plan.md`
Request flow: `docs/plans/v0.55-request-flow.md`
ADR: `docs/adr/0067-tui-terminal-channel.md` (Accepted in v0.55)

Status: released and tagged as `v0.55.0` on 2026-06-22; current metadata now
reports `0.57.0` after the follow-on v0.55.1, v0.56, and v0.57 closeouts. NEW in the
2026-06-09 roadmap restructure; full plan authored in Phase B (research R4).
Moved from v0.56 to v0.55 in the 2026-06-21 replan.
M0-M4 landed on 2026-06-21. Post-M4 audit corrections route the live
`mix allbert.tui` prompt through the descriptor-derived `Channels.Supervisor`
child and stabilize prompt rendering. M5 warm TUI validation was operator-
accepted on 2026-06-22. The separate Matrix live provider smoke was attempted and
blocked by inactive Matrix credentials (`M_UNKNOWN_TOKEN`, "Token is not
active"), while deterministic Matrix outbound/parity gates cover the
v0.54-deferred code path.

Expected direction:

- Establish an explicit channel capability/parity matrix across web, Telegram,
  email, Discord, Slack, and the mobile channels (lightweight acceptance frame;
  the exhaustive cross-surface eval sweep stays in v0.59).
- Introduce a proper TUI/terminal channel — a real channel under the ADR 0016
  contract (list-shaped identity mapping, event dedupe, approval primitives, a
  basic `mix allbert.tui` launcher), not just the `mix allbert.ask` task.
- Harvest Pi's split tool result (`model_payload` vs. `surface_payload`) into
  the typed response contract (ADR 0029/0030) as the foundation for terminal
  rendering without model-context chrome leakage. v0.55 lands the split and live
  region; v0.57 owns true streamed diff/token semantics.

## v0.55.1: TUI Operator/Validation Console

Plan: `docs/plans/v0.55b-plan.md`
Request flow: `docs/plans/v0.55b-request-flow.md`
ADR: `docs/adr/0070-tui-operator-console-and-read-only-operator-actions.md`
(Accepted in v0.55.1)

Status: released and tagged as `v0.55.1` on 2026-06-22. Point release after
`0.55.0`; the v0.56-v0.59 arc is unchanged. M6/final release evidence was
verified locally during closeout.

Closeout shape:

- Make the v0.55 TUI the persistent, mix-free operator/validation console: one
  warm BEAM (DB open, `Channels.Supervisor` up) for interactive operator work and
  go-forward operator validation, instead of cold per-turn `mix allbert.ask`.
- In-TUI slash-commands (`/status`, `/confirmations`, `/events`, `/channels`,
  `/settings get`, `/help`) and `mix allbert.channels status`, each a registered
  **read-only internal** inspection action resolved through `Actions.Runner.run/3`
  and reachable only through the slash-command allowlist or explicit Mix task twin
  — not intent candidates, no mutation, redacted output, backed by the same
  read-report DTO source / existing action reads the `mix allbert.*` tasks render
  (ADR 0070).
- Migrate the operator-validation/testing instructions onto the warm console;
  `mix allbert.test` (deterministic CI gates) is unchanged.
- Reinforces the v0.57 Pi-mode foundation: Pi-mode runs in this same persistent
  session.

## v0.56: Intent Descriptor Learning + Registration Lifecycle Completion + Routing-Accuracy Gate + Model Recommendations

Plan: `docs/plans/v0.56-plan.md`
Request flow: `docs/plans/v0.56-request-flow.md`
ADRs: `docs/adr/0062-...` (completion amendment),
`docs/adr/0071-intent-routing-accuracy-evaluation-harness-and-promotion-gate.md`
(Accepted),
`docs/adr/0072-recommended-model-profiles-per-purpose.md` (Accepted).

Status: released and tagged as `v0.56.0` on 2026-06-23. Inserted by the v0.54
post-implementation audit so the advanced
ADR 0062 lifecycle remains in the 1.0 arc rather than being parked. Moved from
v0.57 to v0.56 in the 2026-06-21 replan. Deepened 2026-06-22 from a 6-milestone
foundation into a 16-milestone release (M0-M15) after the readiness pass: routing
accuracy, full coverage, and model recommendations became first-class pillars.

Expected direction:

- Complete ADR 0062 beyond the v0.54 foundation: local `router_local` descriptor
  generation (bounded, redacted, deterministic YAML, heuristic fallback);
  learned-review proposal-mining infrastructure for reviewed evidence maps from
  memory, resolved clarifications, approved confirmations, redacted intent traces,
  and operator corrections; the
  operator-callable `optimize_intent_descriptors` action; and full
  reindex-on-registration for `allbert.app.registered`,
  `allbert.plugin.registered`, and `allbert.action.registry_changed` alongside the
  v0.54 dynamic-codegen signals.
- **Make routing correct, not just covered:** curate descriptors for the full
  current routable inventory (`57/57` at closeout; only 12 were covered at audit
  time), and add a deterministic
  routing-accuracy evaluation harness (ADR 0071) — a data-only YAML corpus, scorer,
  and **blocking** promotion + release gate (no-regression vs the ratcheted
  committed release baseline, a ratcheting absolute floor, and zero negative-route violations, including the
  standing guarantee that v0.55.1 operator-inspection / `exposure: :internal` /
  doctor actions never route). A live `mix allbert.intent bench` lane stays the
  operator's model-quality signal.
- **Recommend which model to use for what** (ADR 0072): a consolidated operator
  guide (`docs/operator/model-recommendations.md`), recommended Settings Central
  defaults per purpose, and per-purpose reporting folded into
  `mix allbert.intent doctor` + `mix allbert.settings model-doctor`. v0.56 also
  keeps repo-wide defaults aligned to current public Ollama tags
  (`gemma4:26b` escalation and the existing `gemma4:e2b` local STT default).
- **Operator Action Layer (systemic):** every intent/eval/model operation — including
  the shipped v0.54 `mix allbert.intent` CLI — becomes a registered Jido action through
  `Actions.Runner.run/3` (reads `:internal`/`:read_only`; mutations callable only from
  explicit operator surfaces/tasks + gated), so CLI, TUI slash, and the v0.58 web
  operator panels are thin views over one implementation (extends ADR 0070). Now 16
  milestones (M0-M15); gate thresholds 0.85 overall / 0.80 per-domain; corpus
  capture→add→commit to a committed fixture.
- Cross-cutting: all new settings go through Settings Central, all security
  decisions through Security Central, and every operator read-model (coverage,
  descriptor list, eval/gate status, model recommendations) is a redacted DTO from a
  read action — rendered in CLI + minimal TUI reads in v0.56, with the web Intents +
  Settings/Models panels contracted and flagged to the v0.58 Web UX redo.
- Prove in evals that model output and learned proposals grant no authority, routing
  only changes after operator promotion (and passing the accuracy gate), the right
  agent fires across surfaces, registration signals rebuild correctly, and the model
  doctor leaks no secrets and grants no egress.

## v0.57: Pi-mode Coding Surface

Plan: `docs/plans/v0.57-plan.md`
Request flow: `docs/plans/v0.57-request-flow.md`
ADR: `docs/adr/0068-pi-mode-coding-surface-and-local-coding-trust-tier.md`
(Accepted in v0.57 M0)
Rationale: `docs/archives/pi-integration-rethink.md`

Status: released and tagged as `v0.57.0` on 2026-06-24. Implementation,
deterministic release gate, pre-release audit remediation, and warm TUI operator
validation are complete. NEW in the 2026-06-21 replan. Incorporates the
Pi-vs-Allbert analysis:
keep Allbert's authority spine, give it Pi's minimal inner loop where it helps (a
gated coding surface), and adopt Pi's split-tool-result and minimalism budget.

Expected direction:

- A gated terminal coding surface as a channel/app under ADR 0016, on the one
  authority spine: the same registered action runner, Security Central, trace,
  and memory posture as every other surface.
- **Six default tools** — three read-only/sensitive actions
  (`read`/`grep`/`glob`, direct Elixir file-walk/globbing, unprompted but
  policy-bounded) +
  three effectful actions (`write`/`edit`/`bash`) — through the action runner, a
  sub-1000-token prompt+tool-defs budget, and a chunked-read context discipline
  (offset/limit + artifacts, not whole-file). `bash` runs host processes at
  sandbox Level 1; raw shell only at the local-coding tier.
- **Coder-ergonomics parity** (benchmarked against Claude Code / Pi / Codex /
  Gemini CLI): coder-facing approval modes (`default`/`accept-edits`/`plan`/`tier`)
  as a confirmation-cost seam, per-repo remembered command grants, transcript-stable
  streaming progress over the v0.55 split-payload contract, async turn execution
  with Esc-to-cancel, queued correction, and a familiar coding slash set
  (`/help`/`/mode`/`/model`/`/clear`/`/init`/`/diff`/`/compact`).
- A named "local-coding operator" trust tier (ADR 0056 lineage, running at ADR
  0009 **Level 1** — not "level 0"): a single trusted operator, main session,
  terminal channel — never the default, never for channel-originated or
  generated-code sessions; lowers confirmation burden only, not isolation. Modes
  and "always allow" grant no authority.
- Operator affordances for in-session approval-mode switching and mid-session model
  switch. Detailed implementation milestones, audit remediations, evidence paths,
  and validation handoffs stay in the v0.57 plan and request-flow docs.
- Non-goals: no YOLO-by-default; no weakening of the action boundary, Security
  Central, or confirmations; no model-decides-it's-done for effectful or
  generated-code work; keep MCP-first with lazy disclosure; no sibling runtime.

## v0.58: Web UX Redo + Surface Policy

Plan: `docs/plans/v0.58-plan.md`
Request flow: `docs/plans/v0.58-request-flow.md`

Status: planned. NEW in the 2026-06-09 roadmap restructure; full plan authored
in Phase B (research R3). Moved from v0.55 to v0.58 in the 2026-06-21 replan so
it lands right before v0.59 hardening, on top of mature intent and surfaces.

Expected direction:

- Re-layout the existing `/workspace` Surface substrate (ADR 0023/0024 kept):
  chat becomes the primary surface, ephemeral surfaces become popups/modals,
  the canvas is demoted to a launcher/secondary, and UI labels are cleaned up —
  **"Conversations"** replaces the "threads" label (no internal rename; the
  volatile `Session.Scratchpad` concept is untouched).
- References the ChatGPT, Claude, and Hermes (nousresearch) agent UIs.
- Sequenced after v0.56 intent deepening and the v0.55/v0.55.1/v0.57
  channel/console/coding surfaces, so the chat-primary redo lands on top of
  mature routing.
- Implements the v0.56 M12 web handoff: Intents and Settings/Models panels
  render the registered action DTOs (`intent_coverage`,
  `intent_list_descriptors`, `intent_show_descriptor`, `intent_eval_run`,
  `intent_list_review`, `model_doctor`, `list_model_profiles`,
  `list_provider_profiles`) through `Actions.Runner.run/3`, with
  no CLI scraping, direct store reads, secret/endpoint leakage, or new
  authority.
- Adds the formal operator-managed surface policy layer: Settings Central-backed
  policy DTOs/actions and a web panel controlling per-surface report mode,
  redaction/display profile, row/count bounds, and explicit-affordance
  requirements. This policy is presentation governance only: descriptors remain
  routing vocabulary, and Security Central remains authority.

## v0.59: Hardening, Export/Import, Settings Migration, Operator Onboarding, And Final RC

Plan: `docs/plans/v0.59-plan.md`
Request flow: `docs/plans/v0.59-request-flow.md`
ADR: `docs/adr/0046-settings-schema-migration-policy.md` (accepted here;
drafted in v0.45); `docs/adr/0065-central-action-param-contract-enforcement.md`
(Proposed; accept in v0.59 M7); `docs/adr/0069-operator-onboarding-flow.md`
(Proposed; accept in v0.59 M8)

Status: planned. Promoted from `docs/archives/version-1.0-planning-03.md`;
not implemented. Settings schema migration substrate added in the post-v0.37
planning pass; moved from v0.58 to v0.59 and given operator-onboarding scope in
the 2026-06-21 replan.

Expected direction:

- Add no new user-facing capability.
- Prove Allbert Home export/import dry runs, secret migration policy, schema
  metadata, rollback docs, and identical behavior on a second machine.
- **Implement the Settings Central schema migration tool** per ADR 0046:
  per-fragment `schema_version`, additive-only between minor releases,
  one-release deprecation window, `mix allbert.settings.migrate` runner,
  operator-visible pending-migration report on boot.
- **Make operator onboarding genuinely easy:** a guided first-run/setup path
  over the *existing* settings, secrets, channel-pairing, and doctor flows —
  framed as hardening/polish of paths that already exist, not a new capability —
  surfaced through the v0.55.1 TUI console.
- Run the full security eval sweep across MCP client, integrations, browser,
  channels (Discord/Slack and WhatsApp/Signal/Matrix), Plan/Build,
  marketplace, self-improvement, voice, vision, and the v0.51 public protocol
  surfaces (MCP server, OpenAI-compatible API, ACP). Public AG-UI/A2UI and MCP
  Apps iframe evals remain parked.
- Central action param-contract enforcement (M7, ADR 0065; precursor v0.54
  ADR 0064).
- Gather final RC evidence for the v1.0 contract freeze.

## v1.0: Stability Release And Public Contract Freeze

Plan: `docs/plans/v1.0-plan.md`
Request flow: `docs/plans/v1.0-request-flow.md`

Status: planned. Promoted from `docs/archives/version-1.0-planning-03.md`; not implemented.

Expected direction:

- Add no new features.
- Freeze public contracts for Runtime, actions, plugin/app/surface/resource
  APIs, workspace canvas/ephemeral surfaces, channel adapters, Settings
  Central, and Allbert Home layout.
- Treat 1.0 as the stable platform commitment, not a feature ceiling.

## v1.0 Strategic Frame And Acceptance Matrix

Allbert is not behind OpenClaw or Hermes on architecture; it is ahead on
architecture and behind on shipped capability. The v0.38-to-v1.0 arc is a
delivery push over already-proven substrates: templates first, onboarding and
provider control next, identity slot + Active Memory, then MCP client,
MCP-first integrations, browser research, Plan/Build, marketplace seed,
operator-supervised self-improvement, media, team channels, mobile channels,
public protocol surfaces, hardening/export with settings migration, final RC
evidence, and a tiered contract freeze.

The strategic moat is the safety architecture (Security Central, durable
confirmations, Resource Access posture, sandbox/gate runner, reversible
dynamic loader). The 1.0 commitment is to add user-visible capability under
that authority boundary without compromising it.

### 1.0 Acceptance Matrix (freeze-blocking)

Tightened in the post-v0.37 planning pass to 8 criteria. Each item is a
disposable-home checkpoint the release cannot ship without:

1. First-run setup succeeds on macOS, Linux, and Windows/WSL2 (v0.39).
2. Operator can choose local Ollama, OpenAI, Anthropic, or OpenRouter through
   model/profile control and the doctor (v0.39). The doctor return shape is
   pinned by
   ADR 0047 and becomes a Tier-1 freeze contract at v1.0.
3. Operator can connect at least one remote channel — Telegram, email,
   Discord, Slack, WhatsApp, Signal, or Matrix (v0.16 / v0.52 / v0.53).
4. Operator can configure and use at least one MCP server under policy
   (v0.40).
5. Operator can ask Allbert to research a web target with approved navigation
   scope (v0.43).
6. Operator can review and approve a multi-step plan before execution
   (v0.44).
7. Operator can export Allbert Home and re-import on a second machine with
   identical behavior, including settings migration (v0.59 + ADR 0046).
8. All warning, security, precommit, and cross-surface eval gates pass
   (v0.59).

### Capabilities That Ship In The Arc But Are Not Freeze-Blocking

These are part of the 1.0 release but do not block the freeze if their
acceptance criteria are subjective or provider-dependent:

- Identity slot + Active Memory (v0.39b) — algorithm is deterministic but
  retrieval quality is subjective.
- Tool discovery + MCP-first integration panels + notes/files reference plugin
  (v0.42) — the connect gate and discovery boundary are objective; registry
  coverage and search quality are ecosystem-dependent.
- Marketplace seed catalog (v0.45) — content scarcity is honest; the data
  shape is the deliverable.
- Self-improvement suggestion quality (v0.47) — quality bar is subjective.
- Voice (v0.48) — explicitly experimental.
- Vision and image generation (v0.49) — provider-dependent quality.
- Public Protocol Surfaces (v0.51) — external-client interop is verifiable but
  ecosystem maturity varies.

### Capabilities Parked Post-1.0

Moved out of the 1.0 arc into `future-features.md`:

- Public AG-UI/A2UI bridge.
- MCP Apps iframe UI.
- iMessage channel adapter.
- Native plugin variants for calendar / mail / GitHub integrations beyond MCP
  (post-1.0 follow-on if needed).
- Marketplace community submission / review governance.

## Future: Distillation, Autonomy, And Distributed Operation

Status: research.

Expected direction:

- Explore small-model memory/personality distillation only after memory,
  deletion, trace quality, reproducibility, and evals are trustworthy.
- Explore autonomous skill creation only after the v0.47 supervised precursor
  proves suggestion quality, review ergonomics, and safety invariants.
- Explore deeper self-modification only if it remains reviewable, reversible,
  auditable, and bounded by explicit operator authority.
- Keep hosted multi-user authorization, broad remote sync, and complex
  distributed multi-node operation parked until a concrete deployment need
  exists.
