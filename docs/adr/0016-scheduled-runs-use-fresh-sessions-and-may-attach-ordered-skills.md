# ADR 0016: Scheduled runs use fresh sessions and may attach ordered skills

Date: 2026-04-18
Status: Proposed

## Context

Both OpenClaw and Hermes treat scheduled work as something more deliberate than "resume whatever the agent was last doing." Hermes in particular documents cron runs as fresh sessions and allows one or more attached skills to provide reusable procedure without requiring giant repeated prompts.

That maps well to Allbert's current architecture. The kernel already supports skills and a frontend boundary. What scheduled runs need is a clear rule about context: do they inherit ambient REPL history, or do they start fresh and only load the context the job explicitly names?

The second option is safer and more auditable.

## Decision

Scheduled runs will use fresh sessions by default.

- A job should not inherit ambient REPL conversation state.
- A job prompt should be self-contained unless reusable procedure is supplied through attached skills.
- Jobs may attach zero, one, or multiple skills.
- Attached skills are ordered and should be loaded in declared order before the job prompt is layered on top.
- The jobs system should not invent a second procedural format when the existing skills system is already available.

## Consequences

**Positive**
- Keeps scheduled behavior reproducible and easier to debug.
- Prevents accidental dependence on stale or private chat context.
- Reuses the existing skills model instead of inventing a jobs-only workflow language.

**Negative**
- Some jobs will need more explicit prompts than an interactive user might expect.
- Skill ordering and prompt layering become part of the job contract and need tests.

**Neutral**
- A future version could add a persistent-session job mode, but that is not the default in v0.2.
- This decision is compatible with bundled first-party job templates and first-party skills.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
