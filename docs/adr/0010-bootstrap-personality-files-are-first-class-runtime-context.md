# ADR 0010: Bootstrap personality files are first-class runtime context

Date: 2026-04-18
Status: Accepted

## Context

Allbert's vision is explicitly personal, not generic. That means the assistant's runtime personality, the user's profile, and local working conventions should be adjustable without code changes or hidden prompt edits. There are a few ways to model that:

1. keep personality mostly hardcoded in the kernel prompt and let memory gradually shape it;
2. treat personality files as ordinary documents the model may choose to read when it remembers to;
3. make a small bootstrap bundle of markdown files part of the kernel-owned prompt assembly.

The first option keeps runtime simpler but makes personality drift opaque and harder for the user to inspect. The second keeps files editable, but behavior becomes unreliable because the model may fail to reread the files before acting. The third costs prompt budget, but it gives Allbert a visible, inspectable, user-editable identity layer that the runtime can load deterministically on every turn.

OpenClaw's bootstrap-file pattern strongly supports the third option, but Allbert does not need to copy its full workspace file set in v0.1. In particular, OpenClaw-style `AGENTS.md` and `HEARTBEAT.md` mix in group-chat and proactive-scheduler concerns that Allbert's REPL-first MVP does not yet ship.

## Decision

Allbert will introduce a first-class bootstrap context layer in v0.1.

- The bootstrap bundle is:
  - `SOUL.md`
  - `USER.md`
  - `IDENTITY.md`
  - `TOOLS.md`
  - optional `BOOTSTRAP.md`
- These files live under `~/.allbert/` and are owned by the kernel prompt pipeline rather than by the skills subsystem.
- On first boot, the kernel seeds any missing bootstrap files with small markdown templates so the runtime personality surface is visible and editable immediately.
- At the start of each user turn, the kernel snapshots the bootstrap bundle and injects it ahead of memory and skills for every model round in that turn.
- `BOOTSTRAP.md`, when present, is treated as a one-time first-run ritual file. The normal completion path is to update the durable bootstrap files and then delete `BOOTSTRAP.md`.
- Bootstrap files are bounded by dedicated limits, separate from memory and skill budgets.
- Bootstrap files are distinct from both:
  - skills, which remain on-demand and explicitly activated;
  - memory, which remains the durable store for learned facts, notes, and decisions.
- Ownership is explicit:
  - `SOUL.md` and `IDENTITY.md` are user-owned.
  - `USER.md` is shared but user-led.
  - `TOOLS.md` is shared-maintenance.
  - `BOOTSTRAP.md` is kernel-seeded and ephemeral.
- Durable edits to bootstrap files require the same explicit confirm path as other sensitive prompt-surface mutations.

Allbert will not adopt `AGENTS.md` or `HEARTBEAT.md` in v0.1. Those can be reconsidered later when Allbert has broader session surfaces, proactive jobs, or group-chat behavior that makes them pull their weight.

v0.11 amendment: `PERSONALITY.md` joins the bootstrap load path as an optional artifact created by the review-first personality digest (ADR 0079) or by direct user edit. It is not seeded on first boot. When absent, the kernel skips it silently. When present, it is bounded by the same bootstrap prompt limits as the rest of the bundle and is treated as sensitive prompt surface: installing or replacing it requires explicit operator acceptance, and scheduled jobs may not silently mutate it.

## Consequences

**Positive**
- Runtime personality becomes user-editable and inspectable without recompiling or hiding prompt logic in code.
- The assistant can reliably "readjust" to updated personality or user-context files on the next turn.
- Identity/profile context stays separate from memory and from task skills, which keeps each layer conceptually cleaner.

**Negative**
- Always-on bootstrap files consume prompt budget on every turn.
- This creates a new sensitive prompt surface: careless edits to `SOUL.md` or related files can change future behavior significantly.
- The kernel prompt builder and hooks need more explicit ordering and testing.

**Neutral**
- The bootstrap bundle is intentionally smaller than OpenClaw's workspace bootstrap set.
- Future versions may add more bootstrap files or context modes, but should do so explicitly rather than turning one file into a catch-all.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.01-mvp.md](../plans/v0.01-mvp.md)
- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0006](0006-hook-api-is-public-from-day-one.md)
- [ADR 0009](0009-v0-1-tool-surface-expansion-and-policy-envelope.md)
- [ADR 0079](0079-personality-digest-is-a-review-first-learningjob-not-hidden-memory-or-training.md)
