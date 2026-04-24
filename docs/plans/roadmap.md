# Allbert Roadmap

This is a living index of release plans. Each release has its own plan file with goals, milestones, and ADR references. Details belong in those files; this document covers sequencing and cross-release context.

## Status

| Release | Focus | Status | Plan |
| --- | --- | --- | --- |
| v0.1 | Source-based CLI MVP with kernel, skills, memory, exec policy | Shipped | [v0.1-mvp.md](v0.1-mvp.md) |
| v0.2 | Daemon host, scheduled jobs, multi-session kernel, local IPC | Shipped | [v0.2-scheduled-jobs.md](v0.2-scheduled-jobs.md) |
| v0.3 | First-class agents, sub-agent harness, intent routing | Shipped | [v0.3-agent-harness.md](v0.3-agent-harness.md) |
| v0.4 | AgentSkills folder format, install trust model, script policy | Shipped | [v0.4-agentskills-adoption.md](v0.4-agentskills-adoption.md) |
| v0.5 | Curated memory: tiered memory service, ranked retrieval, staging, promotion | Shipped | [v0.5-curated-memory.md](v0.5-curated-memory.md) |
| v0.6 | Foundation hardening: session durability, richer staged-memory review, cost cap enforcement, memory verification, maintenance policy fix | Shipped | [v0.6-foundation-hardening.md](v0.6-foundation-hardening.md) |
| v0.7 | Channel expansion: Telegram pilot, `Channel` trait + multimodal flags, tool-surface normalization, budget-governed sub-agents, intent-guided routing defaults, explicit-intent web learning | Shipped | [v0.7-channel-expansion.md](v0.7-channel-expansion.md) |
| v0.8 | Continuity and sync: cross-channel identity mapping, durable session routing, approval inbox, sync posture | In Closeout | [v0.8-continuity-and-sync.md](v0.8-continuity-and-sync.md) |
| v0.9 | Developer environment and Codex Web readiness: pinned toolchain, contributor contract, provider-free validation | Shipped | [v0.9-developer-environment-and-codex-web.md](v0.9-developer-environment-and-codex-web.md) |
| v0.10 | Self-improvement: Rust rebuild skill, user-facing skill-authoring skill, embedded scripting seam | Proposed | [v0.10-self-improvement.md](v0.10-self-improvement.md) |

Note: v0.9's contributor-contract work shipped before v0.8 closeout completed. The roadmap order still reflects dependency intent rather than strict release-closeout chronology.

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

Self-improvement (the assistant rebuilding its own Rust binary, or authoring new skills) is both powerful and risky. It should land only after Allbert has:

- at least one approval-capable non-REPL channel,
- a settled pattern for cross-channel operator review,
- a continuity model that makes pending approvals and resumable work legible outside the REPL,
- and a pinned, reproducible contributor environment so rebuild flows are not built on unstated workstation assumptions.

v0.10 also depends on the tool surface being normalized so embedded-script hook observation is uniform (ADR 0052), and on the memory and skill-install trust model being mature enough that self-authored artifacts route through the same gates as any other skill.

## Cross-cutting concerns

These themes recur across multiple releases. They are noted here so individual plans do not have to re-establish them.

- **Natural interface for end users.** End users interact via natural language — text now, and later voice, images, and attachments as specific channel plans harden. User-authored extension lives in markdown and declarative config (bootstrap files, skills, jobs, agent prompts). Rust is runtime scaffolding; code-writing paths are opt-in advanced tools, never default user flow. Codified in [ADR 0038](../adr/0038-natural-interface-is-the-users-extension-surface.md).
- **Security envelope.** Every new capability routes through existing policy surfaces — `security.exec_allow` / `security.exec_deny`, explicit confirmation flows, skill `allowed-tools`, and install preview (ADR 0033). No release adds a privileged bypass. New hook points extend the existing hook surface rather than replacing it.
- **Kernel-first.** New runtime behaviour lands in the kernel when it is runtime behaviour (agents, intent routing, memory retrieval surfaces). Adapters and frontends stay thin.
- **Progressive disclosure.** From v0.4 onward, skill prompt contribution is tier-aware (ADR 0036). Memory retrieval in v0.5 follows the same principle: surface metadata cheaply, load content on demand.
- **Hot path vs background work.** The main turn loop may update ephemeral state and stage candidate learnings, but review, promotion assistance, compaction, and pruning can also run through jobs or memory-aware skills so the core turn does not carry every maintenance burden.
- **Markdown as ground truth.** Jobs (ADR 0022), skills (ADR 0032), and memory (v0.5) all persist as markdown files with defined frontmatter. Indices and caches are derived artifacts that can be rebuilt from the markdown at any time.
- **Canonical format bias.** When a format change is important to runtime simplicity or user clarity, prefer normalizing shipped artifacts to the new canonical shape over carrying bridge code. ADR 0037 now takes that path for the v0.4 skill cutover.

## Deferred ambitions

Explicitly parked, not forgotten.

- **Remote skill registry.** Deferred per ADR 0035. Local path and git URL are the v0.4 install sources. A curated registry can land as a third source type in v0.5+ without redesigning the install flow.
- **Skill-format adapter for MCP / OpenClaw / legacy shapes.** Noted in v0.7's out-of-scope section. Strict AgentSkills-format cutover (ADR 0037) is the current policy; a one-shot importer can land alongside later channel or continuity work without changing kernel invariants.
- **Multi-user workstation daemon.** The v0.2 trust model (ADR 0023) assumes a single local user. Multi-user daemon isolation is future work.
- **Capability tokens for local IPC.** ADR 0023 explicitly defers these. v0.7 channels may push on the edges of this decision; revisit if so.
- **Cross-network daemon.** Out of scope through v0.10. If and when it returns, it will be an explicit design pass, not an incremental add-on.
- **Large embedded runtime.** Lua or similar embedded scripting enters only through the v0.10 scripting seam (ADR pending in that release) rather than as a kernel dependency.
- **Embedding / vector retrieval for memory.** v0.5 commits to BM25 via tantivy (ADR 0046); embedding-based retrieval is an explicit non-goal for v0.5 and may layer alongside tantivy in a later release rather than replacing it.
- **Local personalization / retraining pipeline.** The origin note's ambition to distill or retrain a small local model for memory/personality is still in scope philosophically, but it is not assigned to any release through v0.10. Revisit only after curated memory, continuity, model-management seams, and the contributor environment contract are stable.
- **Website-serving / hosted web surfaces.** The origin note's idea that Allbert might eventually serve websites or richer hosted interfaces is explicitly deferred beyond the current roadmap. The near-term web story is channel expansion and future native/web UI planning, not site-hosting from the daemon.

## References

- [docs/vision.md](../vision.md)
- [docs/adr/](../adr/)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
