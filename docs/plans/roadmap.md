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

Agents must exist as first-class runtime participants before skills can contribute them. Adopting the AgentSkills folder format first would leave us translating AgentSkills frontmatter to a runtime shape that does not yet exist. v0.3 lands the agent abstraction; v0.4 then extends skill frontmatter to contribute agents naturally (ADR 0031).

### v0.4 before v0.5

Curated memory depends on being able to describe memory access patterns as skills rather than bespoke kernel features. The folder format (ADR 0032), progressive disclosure (ADR 0036), and script policy (ADR 0034) give v0.5 a clean substrate for memory skills — indexers, retrievers, summarisers — without adding one-off surfaces to the kernel.

### v0.5 before v0.6

New channels (Telegram, Discord, eventually web and email) carry less interactive context than a REPL. Without curated memory, those channels would repeatedly send stale or redundant context to the assistant, or would miss what the user needs. v0.5 makes per-session context construction cheap and predictable, which is a precondition for channels where turns are sparse and asynchronous.

### v0.6 before v0.7

Self-improvement (the assistant rebuilding its own Rust binary, or authoring new skills) is both powerful and risky. It should land after Allbert has real channel coverage so the operator does not need a terminal to approve a rebuild, and after the memory and skill-install trust model is mature enough that self-authored artifacts route through the same gates as any other skill.

## Cross-cutting concerns

These themes recur across multiple releases. They are noted here so individual plans do not have to re-establish them.

- **Security envelope.** Every new capability routes through existing policy surfaces — `exec_policy`, `confirm-trust`, skill `allowed-tools`, install preview (ADR 0033). No release adds a privileged bypass. New hook points extend the existing hook surface rather than replacing it.
- **Kernel-first.** New runtime behaviour lands in the kernel when it is runtime behaviour (agents, intent routing, memory retrieval surfaces). Adapters and frontends stay thin.
- **Progressive disclosure.** From v0.4 onward, skill prompt contribution is tier-aware (ADR 0036). Memory retrieval in v0.5 follows the same principle: surface metadata cheaply, load content on demand.
- **Markdown as ground truth.** Jobs (ADR 0022), skills (ADR 0032), and memory (v0.5) all persist as markdown files with defined frontmatter. Indices and caches are derived artifacts that can be rebuilt from the markdown at any time.
- **Backward compatibility windows.** Format migrations get one release of dual-loading with deprecation warnings, then a clean break — the pattern ADR 0037 establishes for single-file skills.

## Deferred ambitions

Explicitly parked, not forgotten.

- **Remote skill registry.** Deferred per ADR 0035. Local path and git URL are the v0.4 install sources. A curated registry can land as a third source type in v0.5+ without redesigning the install flow.
- **Multi-user workstation daemon.** The v0.2 trust model (ADR 0023) assumes a single local user. Multi-user daemon isolation is future work.
- **Capability tokens for local IPC.** ADR 0023 explicitly defers these. v0.6 channels may push on the edges of this decision; revisit if so.
- **Cross-network daemon.** Out of scope through v0.7. If and when it returns, it will be an explicit design pass, not an incremental add-on.
- **Large embedded runtime.** Lua or similar embedded scripting enters only through the v0.7 scripting seam (ADR pending in that release) rather than as a kernel dependency.

## References

- [docs/vision.md](../vision.md)
- [docs/adr/](../adr/)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
