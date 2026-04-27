# Allbert Roadmap

This is a living index of release plans. Each release has its own plan file with goals, milestones, and ADR references. Details belong in those files; this document covers sequencing and cross-release context.

## Status

| Release | Focus | Status | Plan |
| --- | --- | --- | --- |
| v0.1 | Source-based CLI MVP with kernel, skills, memory, exec policy | Shipped | [v0.01-mvp.md](v0.01-mvp.md) |
| v0.2 | Daemon host, scheduled jobs, multi-session kernel, local IPC | Shipped | [v0.02-scheduled-jobs.md](v0.02-scheduled-jobs.md) |
| v0.3 | First-class agents, sub-agent harness, intent routing | Shipped | [v0.03-agent-harness.md](v0.03-agent-harness.md) |
| v0.4 | AgentSkills folder format, install trust model, script policy | Shipped | [v0.04-agentskills-adoption.md](v0.04-agentskills-adoption.md) |
| v0.5 | Curated memory: tiered memory service, ranked retrieval, staging, promotion | Shipped | [v0.05-curated-memory.md](v0.05-curated-memory.md) |
| v0.6 | Foundation hardening: session durability, richer staged-memory review, cost cap enforcement, memory verification, maintenance policy fix | Shipped | [v0.06-foundation-hardening.md](v0.06-foundation-hardening.md) |
| v0.7 | Channel expansion: Telegram pilot, `Channel` trait + multimodal flags, tool-surface normalization, budget-governed sub-agents, intent-guided routing defaults, explicit-intent web learning | Shipped | [v0.07-channel-expansion.md](v0.07-channel-expansion.md) |
| v0.8 | Continuity and sync: cross-channel identity mapping, durable session routing, approval inbox, sync posture | Shipped | [v0.08-continuity-and-sync.md](v0.08-continuity-and-sync.md) |
| v0.9 | Developer environment and Codex Web readiness: pinned toolchain, contributor contract, provider-free validation | Shipped | [v0.09-developer-environment-and-codex-web.md](v0.09-developer-environment-and-codex-web.md) |
| v0.10 | Provider expansion and local-first default: OpenAI, Gemini, Ollama/Gemma4 | Shipped | [v0.10-provider-expansion.md](v0.10-provider-expansion.md) |
| v0.11 | TUI and adaptive memory: Ratatui operator surface, session telemetry, configurable memory routing, episode/fact recall, review-first personality digest + `LearningJob` seam | Shipped | [v0.11-tui-and-memory.md](v0.11-tui-and-memory.md) |
| v0.12 | Self-improvement: Rust rebuild skill, user-facing skill-authoring skill, embedded scripting seam | Shipped | [v0.12-self-improvement.md](v0.12-self-improvement.md) |
| v0.12.1 | Operator UX polish: shared activity awareness, responsive TUI, settings/command hub, legibility, approval context, channel-native Telegram, recovery, discovery, error hints | Shipped | [v0.12.1-operator-ux-polish.md](v0.12.1-operator-ux-polish.md) |
| v0.12.2 | Tracing and replay: persisted session spans, trace/replay surfaces, privacy/redaction posture, protocol v4, OTLP-JSON export | Shipped | [v0.12.2-tracing-and-replay.md](v0.12.2-tracing-and-replay.md) |
| v0.13 | Local personalization: LoRA/adapter training through the v0.11 `LearningJob` seam, owned `AdapterTrainer` trait with mlx + llama.cpp + fake backends, local-only base-model-pinned activation, `adapter-approval` inbox kind, daily wall-clock compute cap, profile-export exclusion | Shipped | [v0.13-personalization.md](v0.13-personalization.md) |
| v0.14 | Self-diagnosis and Unix co-tenant: trace-aware self-diagnose skill, curated local-utilities surface, bounded `unix_pipe` tool shape | Shipped | [v0.14-self-diagnosis.md](v0.14-self-diagnosis.md) |
| v0.14.1 | Vision alignment: doc-reality gate, local-default tool-call parser fix, daemon adapter wiring, trainer factory wiring, concrete diagnosis remediation candidates | Shipped | [v0.14.1-vision-alignment.md](v0.14.1-vision-alignment.md) |
| v0.14.2 | Kernel core/services split: retire the monolithic kernel crate, add direct core/services imports, default-parallel daemon socket reliability, and size/dependency gates | Shipped | [v0.14.2-kernel-core-services.md](v0.14.2-kernel-core-services.md) |
| v0.14.3 | Operator reliability patch: schema-bound intent router, deterministic conversational scheduling, explicit memory capture, OpenAI Responses assistant-history serialization, local-model tool-call retry/provenance, and follow-up operator-test fixes | Shipped | [v0.14.3-operator-reliability.md](v0.14.3-operator-reliability.md) |
| v0.15 | RAG foundation plus growth loop: SQLite lexical/vector retrieval substrate, router RAG hints, local staged ingestion endpoint, CLI feed, browser extension/proxy proofs, and review-first ingestion memory flow | Stub | [v0.15-growth-loop.md](v0.15-growth-loop.md) |

Note: some v0.9 contributor-contract work landed before the final v0.8 release-alignment pass. The roadmap order still reflects dependency intent rather than strict commit chronology.

## Sequencing rationale

The order matters. Each release unlocks the one after it.

### v0.3 before v0.4

Agents must exist as first-class runtime participants before the richer AgentSkills install/validation story has a stable runtime target. v0.3 lands the agent abstraction and previews `intents:` / `agents:` on the existing minimal skill shape; v0.4 then makes those same metadata keys portable, validated, installable, and resource-aware inside canonical AgentSkills folders (ADR 0031, ADR 0032).

### v0.4 before v0.5

Curated memory needs more than a retriever. It needs a full turn-assembly contract: bootstrap identity, bounded always-on memory, ranked prefetch, explicit search/read, staging, promotion, and session working memory. v0.4 provides the right substrate for that: portable skills, progressive disclosure, install trust, and script policy. v0.5 then adds the kernel-owned memory service and lets skills package review, compaction, promotion, and maintenance workflows around it instead of replacing that service.

### v0.5 before v0.6

v0.5 closed with curated memory, tantivy retrieval, and the `memory-curator` skill shipped. A retrospective on 2026-04-20 surfaced five gaps that did not change what Allbert *could* do, but changed how reliably the shipped experience landed: the staged-memory notice was too generic for efficient review, sessions still died on daemon restart, there was no hard daily cost cap, bundled maintenance loops were not yet safely defaultable, and markdown reconciliation lacked operator-visible verification. v0.6 closed those gaps without changing the core product shape, which is exactly why it belonged before v0.7.

### v0.6 before v0.7

New channels (Telegram, Discord, eventually richer native and web surfaces) carry less interactive context than a REPL. Without curated memory (v0.5) and without the session durability, cost enforcement, operator-visible memory verification, and safer maintenance defaults that landed in v0.6, those channels would either repeatedly send stale or redundant context, die on daemon restart, or silently burn budget. v0.6 stabilized the substrate that v0.7's channel-adaptive rendering and approval flows rely on. v0.7 folds in tool-surface normalization and explicit-intent web learning because they co-evolve with the channel surface.

### v0.7 before v0.8

The first non-REPL channel changes what "continuity" means. Once a user can talk to Allbert from Telegram or another async surface, the next pain point is not yet self-improvement; it is continuity across channels and devices: shared identity mapping, durable session routing, pending approvals that outlive a single surface, and an explicit sync posture for memory and session artifacts. v0.7 intentionally stops short of cross-surface approval resolution and cross-channel identity routing: approvals still resolve only on the originating async channel, and trust/continuity remain channel-local. v0.8 addresses that operator-facing gap before the roadmap jumps to the more ambitious self-improvement work.

### v0.8 before v0.9

Before Allbert can safely rebuild itself, the repository itself needs a declared contributor contract. The current project is well specified as a local-first source-based product, but not yet as a reproducible macOS/Linux development workspace or a Codex Web coding workspace. v0.9 closes that gap by pinning the Rust toolchain, documenting the required validation path, separating provider-free contributor checks from optional live-provider verification, and adding repo-level contributor instructions distinct from runtime bootstrap files.

### v0.9 before v0.10

Once v0.9 made contributor work provider-free and reproducible, the next operator-facing gap was provider choice. v0.10 expands the owned provider seam to OpenAI, Gemini, and local Ollama while preserving Anthropic/OpenRouter. It also flips fresh profiles to a local-first Ollama/Gemma4 default so the default bootstrap path no longer assumes a hosted API key.

This release deliberately keeps Allbert's provider layer small and kernel-owned instead of adopting a general provider framework. That keeps cost logs, daemon protocol, setup, jobs, skill-contributed agents, and channel image gating under the same policy surface. The decision is recorded in [ADR 0066](../adr/0066-owned-provider-seam-over-rig-for-v0-10.md).

ADR 0066 was accepted as the frozen provider-framework decision before implementation and remains the release rationale now that v0.10 has shipped.

### v0.10 before v0.11

v0.10 made provider choice broader and fresh profiles local-first. The next pain point is operator visibility and memory confidence, not self-modification. Once users can run local or hosted providers, the terminal surface should show what the daemon is doing: model, context pressure, token usage, cost, active skills, memory state, pending approvals, and trace posture.

v0.11 also deepens memory without weakening the v0.5 safety contract:

- `memory-curator` becomes always eligible through configurable routing, but not always active;
- session journals become searchable episode recall, but not durable learned memory;
- staged/promoted facts can carry temporal provenance, but still require review before durable promotion;
- semantic retrieval remains optional and derived, while BM25/Tantivy remains the default. v0.11 ships the fake deterministic semantic provider for validation; real embedding providers remain additive follow-up work.

v0.11 also takes the first review-first step toward the origin note's nightly-learning ambition: an opt-in `personality-digest` job compiles a markdown `PERSONALITY.md` learned overlay from approved durable memory, approved fact memory, and bounded recent episode summaries, and a `LearningJob` trait seam defines the shape future learning jobs plug into. The shipped digest renderer is provider-free and deterministic while preserving the hosted-provider consent and draft/install envelope. `SOUL.md` remains the seeded operator-owned persona and is never written by the digest. No model is trained in v0.11; that lands in v0.13.

This keeps Allbert's normal operating loop legible before the roadmap moves to self-improvement.

### v0.11 before v0.12

Self-improvement (the assistant rebuilding its own Rust binary, authoring new skills, or running embedded scripts) is both powerful and risky. It should land only after Allbert has:

- at least one approval-capable non-REPL channel,
- a settled pattern for cross-channel operator review,
- a continuity model that makes pending approvals and resumable work legible outside the REPL,
- a pinned, reproducible contributor environment so rebuild flows are not built on unstated workstation assumptions,
- a local-first provider default plus direct hosted-provider alternatives so self-improvement can run in more operator environments without forcing one vendor path,
- a richer terminal operator surface with session telemetry, status-line state, and memory/inbox visibility.

v0.12 also depends on the tool surface being normalized so embedded-script hook observation is uniform (ADR 0052), and on the memory and skill-install trust model being mature enough that self-authored artifacts route through the same gates as any other skill. v0.11 reduces the risk further by making cost, context, memory, and approvals visible in the terminal before self-improvement workflows arrive.

### v0.12 before v0.12.1

v0.12 introduced the self-improvement surfaces that make Allbert more capable: Rust rebuild proposals, user-facing skill authoring, scripting seams, and patch approvals. The first operator test showed that the safety posture is sound but the interface is not yet smooth enough: long turns appear frozen, review paths require CLI knowledge, setup can leave users without next steps, and help output undersells the shipped surface.

v0.12.1 shipped as a patch release, not a new self-change capability layer. It has three operator-surface pillars: shared activity awareness, responsive TUI behavior, and a settings/command hub. The activity pillar adds a narrow protocol v3 surface so TUI, classic REPL, CLI, Telegram, jobs, and future channels can all answer "what is Allbert doing, how long has it been there, and what can I do next?" from the same daemon-owned state. That v3 surface remains backward-compatible with shipped v2 clients by negotiating per-connection protocol versions and filtering v3-only activity messages and fields away from v2 peers. The settings/command pillar makes setup choices, daily operation, and later customization share one mental model instead of scattering choices across TOML, setup, TUI-only commands, and CLI-only commands. Settings writes use typed, allowlisted, path-preserving TOML edits instead of whole-config rewrites, so supported changes do not silently erase operator comments or unrelated tables. The earlier usability-audit work is folded into this same point release through legibility, approval-context, channel-native Telegram, recovery, discovery, setup-resume, and error-hint work. Together, those changes make the v0.12 surfaces operator-legible before the roadmap asks users to review personalized adapter artifacts.

### v0.12.1 before v0.12.2

v0.12.2 deliberately builds on v0.12.1 instead of competing with it. v0.12.1 owns live legibility: daemon-owned `ActivitySnapshot`, responsive TUI behavior, settings/command descriptors, setup state, and path-preserving settings persistence. v0.12.2 owns after-the-fact legibility: durable session spans, replay, redacted trace inspection, and file-based OTLP-JSON export.

That split keeps protocol and persistence work orderly. v0.12.1's protocol v3 is only a live activity surface and remains backward-compatible with shipped v2 clients. v0.12.2's protocol v4 is additive on top of that: v4 daemons accept v2, v3, and v4 clients, filter messages per peer, and expose trace read responses plus subscribed completed-span broadcasts only to v4 clients. The v0.12.1 settings registry and path-preserving TOML writer become the mechanism for v0.12.2's `trace` settings and existing-profile default-write, so trace rollout does not introduce a second configuration mutation policy.

### v0.12.2 before v0.13

Local personalization — training a LoRA adapter over approved durable memory, approved facts, bounded recent episode summaries, `SOUL.md` baseline persona, and accepted `PERSONALITY.md` learned adaptation input — is powerful, personal, and hard to undo. It should land only after v0.11 has stabilised the `LearningJob` seam and the corpus contract, after v0.12 has demonstrated the review-first posture for "Allbert produces an artifact, the operator reviews it before it takes effect" via patch-approval, after v0.12.1 has made those review-first workflows discoverable in the everyday TUI/CLI, and after v0.12.2 has made failures and review paths replayable from durable traces (and made those traces available as opt-in additional training corpus material under the same redaction posture).

v0.13's `adapter-approval` flow is deliberately modeled on v0.12's `patch-approval` (ADR 0086), so v0.12 proves the safety pattern, v0.12.1 proves the operator path, and v0.12.2 proves the diagnostic/replay path. v0.13 also inherits the v0.11 invariants it cannot weaken: the `LearningJob` trait shape, the approved durable/fact plus bounded episode-summary corpus rules, daily cost-cap behavior, fail-closed scheduling, `compute_wall_seconds` reporting, `SOUL.md` as baseline persona/constraints, and accepted `PERSONALITY.md` as reviewed learned adaptation input. v0.13 introduces an owned `AdapterTrainer` trait (ADR 0084) instead of adopting a Rust ML framework, the actual wall-clock compute cap for local training (ADR 0087), the local-only base-model-pinned activation rule (ADR 0085), the trainer-binary kind-scoped allowlist that combines with the universal exec policy (ADR 0089), and the host-specific profile-export exclusion for adapter weights (ADR 0088). Those are named in v0.11's "Handoff to v0.12 and v0.13" section so the recheck discipline carries forward.

Neither point release changes the v0.12 self-change envelope. v0.12.1 limits protocol work to additive live activity and operator-visibility messages; v0.12.2 adds persisted trace/replay under session artifacts with explicit privacy, retention, and export rules. Together they reduce support and trust risk before v0.13 by making review-first workflows easier to see, complete, and diagnose. v0.13 reuses every one of those mechanisms: the v0.12.1 settings registry plus path-preserving TOML edits handle the new `[learning.adapter_training]` block; the v0.12.2 secret redactor runs again at corpus-build time when traces are opted in; the v0.12.2 span schema gains `run_training` spans while ADR 0090 keeps protocol v5 as an additive adapter-management and training-progress surface.

### v0.13 before v0.14

v0.14 (self-diagnosis + Unix co-tenant) is scoped after v0.13 primarily for scope/complexity reasons, not raw dependency:

- v0.11's telemetry + routing + staging expose the trace and memory surfaces self-diagnosis reads and writes through.
- v0.12's sibling-worktree, Tier A validation, `patch-approval` inbox, and `skill-author` give candidate self-fixes a review home and an isolation mechanism.
- v0.12.2's persisted session traces and bounded trace read APIs over active plus rotated session artifacts give self-diagnosis durable diagnostic input.
- v0.13's personalization establishes that "Allbert changes itself, operator reviews before it lands" is a familiar loop, not a novel one.

v0.14's *hard runtime* dependencies are v0.11, v0.12, and v0.12.2. v0.13 is a sequencing neighbor: shipping v0.14 alongside personalization would combine two hard reviews (training data scope and self-modification proposals) into one release, which we deliberately avoid. If personalization were ever deprioritized, v0.14 could ship directly after v0.12.2 without code-level conflicts; the sequencing choice is reviewability, not capability.

Trace persistence no longer belongs to v0.14. v0.12.2 owns the durable trace storage location, schema version, retention policy, read API, privacy defaults, and OTLP export boundary. v0.14 consumes those session trace artifacts through bounded read APIs and focuses on correlation, explanation, candidate remediation, and Unix co-tenant tooling.

The v0.14 decision set shipped across four ADRs: [ADR 0091](../adr/0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md) fixes bounded trace diagnosis and remediation routing, [ADR 0092](../adr/0092-local-utility-discovery-uses-curated-operator-enabled-manifests.md) fixes curated utility enablement, [ADR 0093](../adr/0093-unix-pipe-is-a-structured-direct-spawn-tool-not-a-shell-runtime.md) fixes structured pipeline policy, and [ADR 0094](../adr/0094-protocol-v6-self-diagnosis-and-local-utility-surfaces.md) fixes protocol v6 compatibility.

### v0.14 before v0.14.1

The v0.14.1 release exists because the v0.13/v0.14 shipped narrative drifted ahead of the running code. Before adding another feature layer, Allbert needs the docs and product to agree again: daemon adapter requests must stop returning `adapter_surface_not_implemented`, production adapter training must use the configured backend instead of silently using fake, self-diagnosis remediation must produce candidate artifacts instead of placeholders, and the default local Gemma4 profile must be able to call tools reliably.

v0.14.1 is therefore a repair point release. It does not add ingestion, a new protocol version, a new approval kind, or a large structural refactor.

### v0.14.1 before v0.14.2

The kernel split should happen only after the honesty repair lands. v0.14.1 freezes doc-reality checks and closes partial operator surfaces; v0.14.2 can then move code across crate boundaries without also carrying semantic behavior fixes. It also fixes the default-parallel daemon integration socket flake before the structural work is treated as release-ready. That separation keeps review focused: v0.14.1 proves the promised behavior, while v0.14.2 proves the architecture can stay compact and the validation suite can stay trustworthy without changing operator behavior.

### v0.14.2 before v0.14.3

v0.14.2 intentionally changed architecture without adding operator-visible behavior. Live operator testing after that release surfaced a different kind of risk: local-model conversational scheduling can ask for plain-text approval and then fail to produce a parseable job tool call, explicit `remember that ...` memory capture can fail before staging a review candidate, and OpenAI Responses can reject assistant history serialized with the wrong content type. v0.14.3 keeps those repairs isolated as a patch release, with a schema-bound intent router as the foundation, before the roadmap moves on to growth-loop ingestion.

### v0.14.3 before v0.15

Growth-loop ingestion adds a new local service and protocol surface. v0.14.2 creates the acyclic core/services crate shape first and retires the old monolithic kernel crate, so retrieval and ingestion can land in the service layer rather than inflating the runtime core. v0.14.3 then replaces brittle semantic keyword routing with a schema-bound router, makes the operator scheduling and explicit-memory paths deterministic for local models, and repairs the OpenAI Responses multi-turn history mapping.

v0.15 starts with a RAG foundation before ingestion. That ordering matters: browser/search ingestion would create more staged and promoted knowledge than Allbert can retrieve or explain well if the system still only had memory-local BM25 plus the v0.11 fake semantic seam. The v0.15 RAG substrate uses SQLite lexical retrieval first, optional vector retrieval behind an owned embedding seam, and bounded RAG hints for the v0.14.3 router. The original growth-loop scope remains in v0.15 after the RAG foundation: daemon ingestion, CLI feed, browser extension, browser proxy/PAC mode, staging-only review, daily ingestion review, and promoted-record indexing.

## Cross-cutting concerns

These themes recur across multiple releases. They are noted here so individual plans do not have to re-establish them.

- **Natural interface for end users.** End users interact via natural language — text now, and later voice, images, and attachments as specific channel plans harden. User-authored extension lives in markdown and declarative config (bootstrap files, skills, jobs, agent prompts). Rust is runtime scaffolding; code-writing paths are opt-in advanced tools, never default user flow. Codified in [ADR 0038](../adr/0038-natural-interface-is-the-users-extension-surface.md).
- **Security envelope.** Every new capability routes through existing policy surfaces — `security.exec_allow` / `security.exec_deny`, explicit confirmation flows, skill `allowed-tools`, and install preview (ADR 0033). No release adds a privileged bypass. New hook points extend the existing hook surface rather than replacing it.
- **Kernel-first.** New runtime behaviour lands in the kernel when it is runtime behaviour (agents, intent routing, memory retrieval surfaces). Adapters and frontends stay thin.
- **Progressive disclosure.** From v0.4 onward, skill prompt contribution is tier-aware (ADR 0036). Memory retrieval in v0.5 follows the same principle: surface metadata cheaply, load content on demand.
- **Operator-visible runtime state.** v0.11 makes session telemetry a daemon protocol surface rather than terminal-only decoration. v0.12.1 extends that posture with daemon-owned activity and stuck-state snapshots so TUI, classic REPL, CLI, Telegram, jobs, and future channels consume the same operational truth. v0.12.2 persists that operational history as session-local spans so the operator can replay what happened after the turn.
- **Hot path vs background work.** The main turn loop may update ephemeral state and stage candidate learnings, but review, promotion assistance, compaction, and pruning can also run through jobs or memory-aware skills so the core turn does not carry every maintenance burden.
- **Markdown as ground truth.** Jobs (ADR 0022), skills (ADR 0032), and memory (v0.5) all persist as markdown files with defined frontmatter. Indices and caches are derived artifacts that can be rebuilt from the markdown at any time.
- **Canonical format bias.** When a format change is important to runtime simplicity or user clarity, prefer normalizing shipped artifacts to the new canonical shape over carrying bridge code. ADR 0037 now takes that path for the v0.4 skill cutover.
- **Self-change envelope.** When Allbert modifies its own state — source code (v0.12 `rust-rebuild`), installed skills (v0.12 `skill-author`, v0.14 diagnostic skills), model adapters (v0.13 `PersonalityAdapterJob`), or markdown memory/personality overlays (v0.11 `PERSONALITY.md` digest, v0.14 memory remediation) — the same envelope applies. Artifacts are produced in isolation (sibling worktree, `skills/incoming/`, `~/.allbert/adapters/`, staging), routed through an approval surface (inbox kind or staging pipeline), gated by the monetary spend cap (ADR 0051) and, for local compute-bound work, an explicit compute-wall cap introduced by v0.13, observable through the existing hook surface (ADR 0025), and reversible via a rollback trail. v0.12.2 session trace artifacts are diagnostic inputs to this envelope, not a new self-change output location. Provenance frontmatter (`self-authored` / `self-trained` / `self-diagnosed`) is an additive enum that labels every self-change artifact. `SOUL.md` is not a digest target; proposed `SOUL.md` edits require direct operator intent as sensitive bootstrap-file mutations. No flavor of self-change bypasses any part of this envelope. See [ADR 0080](../adr/0080-self-change-artifacts-share-approval-provenance-and-rollback-envelope.md).

## Deferred ambitions

Explicitly parked, not forgotten.

- **Remote skill registry.** Deferred per ADR 0035. Local path and git URL are the v0.4 install sources. A curated registry can land as a third source type in v0.5+ without redesigning the install flow.
- **Skill-format adapter for MCP / OpenClaw / legacy shapes.** Noted in v0.7's out-of-scope section. Strict AgentSkills-format cutover (ADR 0037) is the current policy; a one-shot importer can land alongside later channel or continuity work without changing kernel invariants.
- **Multi-user workstation daemon.** The v0.2 trust model (ADR 0023) assumes a single local user. Multi-user daemon isolation is future work.
- **Capability tokens for local IPC.** ADR 0023 explicitly defers these. v0.7 channels may push on the edges of this decision; revisit if so.
- **Cross-network daemon.** Out of scope through v0.12. If and when it returns, it will be an explicit design pass, not an incremental add-on.
- **Large embedded runtime.** Lua or similar embedded scripting enters only through the v0.12 `ScriptingEngine` seam ([ADR 0069](../adr/0069-scripting-engine-trait-with-lua-as-the-v0-12-default-embedded-runtime.md) and [ADR 0070](../adr/0070-embedded-script-sandbox-policy.md)) rather than as a kernel dependency.
- **Default embedding / vector retrieval for memory.** v0.5 commits to BM25 via tantivy (ADR 0046), and v0.11 adds optional fake-provider semantic retrieval as a derived, disabled-by-default layer. v0.15 now plans a broader SQLite RAG substrate with provider-free lexical retrieval and optional vector retrieval. A default real embedding provider remains a v0.15 implementation decision; hosted embeddings must stay optional and cost-gated.
- **Foundation-model retraining / distillation.** The origin note's ambition to retrain or distill a full local foundation model remains out of scope. v0.11 ships a review-first personality digest and `LearningJob` seam, and v0.13 trains small local adapters against that seam. Full foundation-model retraining is not on the roadmap.
- **Website-serving / hosted web surfaces.** The origin note's idea that Allbert might eventually serve websites or richer hosted interfaces is explicitly deferred beyond the current roadmap. The near-term web story is channel expansion and future native/web UI planning, not site-hosting from the daemon.
- **Additional messaging channels.** Discord, WhatsApp, email, and SMS channels from the origin note's wish list are deferred. v0.7 shipped a Telegram pilot and the `Channel` trait with multimodal flags, so each new channel can land as an adapter without reshaping the kernel. No specific additional messaging channel is assigned a release through v0.15.

## References

- [docs/vision.md](../vision.md)
- [docs/adr/](../adr/)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
