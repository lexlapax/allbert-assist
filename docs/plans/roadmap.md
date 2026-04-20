# Allbert Roadmap

This is a living index of release plans. Each release has its own plan file with goals, milestones, and ADR references. Details belong in those files; this document covers sequencing and cross-release context.

## Status

| Release | Focus | Status | Plan |
| --- | --- | --- | --- |
| v0.1 | Source-based CLI MVP with kernel, skills, memory, exec policy | Shipped | [v0.1-mvp.md](v0.1-mvp.md) |
| v0.2 | Daemon host, scheduled jobs, multi-session kernel, local IPC | Shipped | [v0.2-scheduled-jobs.md](v0.2-scheduled-jobs.md) |
| v0.3 | First-class agents, sub-agent harness, intent routing | Proposed | [v0.3-agent-harness.md](v0.3-agent-harness.md) |
| v0.4 | AgentSkills folder format, install trust model, script policy | Proposed | [v0.4-agentskills-adoption.md](v0.4-agentskills-adoption.md) |
| v0.5 | Curated memory: ranked retrieval, tiered storage, staging | Proposed | [v0.5-curated-memory.md](v0.5-curated-memory.md) |
| v0.6 | Channel expansion: Telegram pilot and the Channel trait | Proposed | [v0.6-channel-expansion.md](v0.6-channel-expansion.md) |
| v0.7 | Self-improvement: Rust rebuild skill, skill-authoring skill, embedded scripting seam | Proposed | [v0.7-self-improvement.md](v0.7-self-improvement.md) |

## Sequencing rationale

The order matters. Each release unlocks the one after it.

### v0.3 before v0.4

Agents must exist as first-class runtime participants before the richer AgentSkills install/validation story has a stable runtime target. v0.3 lands the agent abstraction and previews `intents:` / `agents:` on the existing minimal skill shape; v0.4 then makes those same metadata keys portable, validated, installable, and resource-aware inside canonical AgentSkills folders (ADR 0031, ADR 0032).

### v0.4 before v0.5

Curated memory needs two layers to be ready first: a small kernel retrieval seam, and a skill ecosystem rich enough to package promotion/indexing/summarisation workflows around it. The folder format (ADR 0032), progressive disclosure (ADR 0036), and script policy (ADR 0034) give v0.5 a clean substrate for memory-aware skills, while still leaving ranked retrieval as a kernel-owned runtime behaviour rather than a bespoke prompt hack.

### v0.5 before v0.6

New channels (Telegram, Discord, eventually web and email) carry less interactive context than a REPL. Without curated memory, those channels would repeatedly send stale or redundant context to the assistant, or would miss what the user needs. v0.5 makes per-session context construction cheap and predictable, which is a precondition for channels where turns are sparse and asynchronous.

### v0.6 before v0.7

Self-improvement (the assistant rebuilding its own Rust binary, or authoring new skills) is both powerful and risky. It should land after Allbert has at least one approval-capable non-REPL channel and a settled pattern for channel-mediated operator review, and after the memory and skill-install trust model is mature enough that self-authored artifacts route through the same gates as any other skill.

## Cross-cutting concerns

These themes recur across multiple releases. They are noted here so individual plans do not have to re-establish them.

- **Natural interface for end users.** End users interact via natural language — text now, and later voice, images, and attachments as specific channel plans harden. User-authored extension lives in markdown and declarative config (bootstrap files, skills, jobs, agent prompts). Rust is runtime scaffolding; code-writing paths are opt-in advanced tools, never default user flow. Codified in [ADR 0038](../adr/0038-natural-interface-is-the-users-extension-surface.md).
- **Security envelope.** Every new capability routes through existing policy surfaces — `exec_policy`, `confirm-trust`, skill `allowed-tools`, install preview (ADR 0033). No release adds a privileged bypass. New hook points extend the existing hook surface rather than replacing it.
- **Kernel-first.** New runtime behaviour lands in the kernel when it is runtime behaviour (agents, intent routing, memory retrieval surfaces). Adapters and frontends stay thin.
- **Progressive disclosure.** From v0.4 onward, skill prompt contribution is tier-aware (ADR 0036). Memory retrieval in v0.5 follows the same principle: surface metadata cheaply, load content on demand.
- **Markdown as ground truth.** Jobs (ADR 0022), skills (ADR 0032), and memory (v0.5) all persist as markdown files with defined frontmatter. Indices and caches are derived artifacts that can be rebuilt from the markdown at any time.
- **Backward compatibility windows.** Format migrations get one release of compatibility warnings and a normalization helper, then a clean break — the pattern ADR 0037 establishes for legacy minimal skills.

## Deferred ambitions

Explicitly parked, not forgotten.

- **Remote skill registry.** Deferred per ADR 0035. Local path and git URL are the v0.4 install sources. A curated registry can land as a third source type in v0.5+ without redesigning the install flow.
- **Multi-user workstation daemon.** The v0.2 trust model (ADR 0023) assumes a single local user. Multi-user daemon isolation is future work.
- **Capability tokens for local IPC.** ADR 0023 explicitly defers these. v0.6 channels may push on the edges of this decision; revisit if so.
- **Cross-network daemon.** Out of scope through v0.7. If and when it returns, it will be an explicit design pass, not an incremental add-on.
- **Large embedded runtime.** Lua or similar embedded scripting enters only through the v0.7 scripting seam (ADR pending in that release) rather than as a kernel dependency.
- **Local personalization / retraining pipeline.** The origin note's ambition to distill or retrain a small local model for memory/personality is still in scope philosophically, but it is not assigned to any release through v0.7. Revisit only after curated memory and model-management seams are stable.
- **Website-serving / hosted web surfaces.** The origin note's idea that Allbert might eventually serve websites or richer hosted interfaces is explicitly deferred beyond the current roadmap. The near-term web story is channel expansion and future native/web UI planning, not site-hosting from the daemon.

## References

- [docs/vision.md](../vision.md)
- [docs/adr/](../adr/)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
