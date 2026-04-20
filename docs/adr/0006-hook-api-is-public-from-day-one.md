# ADR 0006: Hook API is public from day one

Date: 2026-04-17
Status: Accepted

## Context

Allbert's kernel runs an agent loop that touches several cross-cutting concerns at predictable moments: bootstrap context injection before a prompt, memory injection before a prompt, security policy before a tool runs, cost accounting after a model response, and — eventually — tracing probes, auto-skill-creation, cost caps, and other extensions the vision anticipates. A reasonable alternative would be to wire these behaviors directly into the agent loop as hardcoded steps and expose nothing to external callers in v0.1.

That alternative is cheaper for the first milestone, but it pushes every future cross-cutting concern back into the kernel itself. Once the loop has only hardcoded extension points, adding the next one means editing kernel code, which raises the cost of experimentation and makes the "small, auditable kernel" claim harder to keep as the system grows. Worse, the built-in behaviors end up intertwined with loop mechanics and become difficult to replace or test in isolation.

## Decision

The kernel will expose a stable hook API as part of its public surface in v0.1.

- `Kernel::register_hook(HookPoint, Arc<dyn Hook>)` is a public method.
- `HookPoint` enumerates named extension points in the agent loop (before prompt, before model, before tool, after tool, on model response, on turn end).
- v0.1 ships with bootstrap-context, memory-index, security, and cost hooks registered by default at boot.
- The default hooks are exposed as public types so external callers can compose with them or replace them.
- The canonical v0.1 hook point names are `BeforePrompt`, `BeforeModel`, `BeforeTool`, `AfterTool`, `OnModelResponse`, and `OnTurnEnd`. Future ADRs may add hook points, but they do so additively rather than silently renaming this accepted set.
- Lower-level exec activity in v0.1 remains observable through `BeforeTool` / `AfterTool` on the `process_exec` tool. If a future release needs dedicated exec-specific hook points, that addition should be explicit and documented as a new hook family.
- v0.5's curated-memory design may add a memory hook family (`BeforeMemoryPrefetch`, `AfterMemoryPrefetch`, `BeforeMemoryStage`, `AfterMemoryStage`, `BeforeMemoryPromote`, `AfterMemoryPromote`, `BeforeIndexRebuild`, `AfterIndexRebuild`, and related progress/trim events). That family is an additive extension to this accepted surface, not a replacement for it.

For `BeforePrompt`, registration order is significant and documented: bootstrap context is assembled first, then memory context, then later prompt-builder steps consume that snapshot.

Hooks are the intended extension seam for policy, observability, and future features like auto-skill-creation or cost caps.

## Consequences

**Positive**
- Cross-cutting concerns live behind a uniform, inspectable interface rather than ad hoc kernel edits.
- The default behaviors can be replaced or augmented without forking the kernel.
- Tests can register probe hooks to assert loop invariants without reaching into internals.

**Negative**
- The hook surface is public from day one, so shape changes carry an API cost earlier than strictly necessary.
- Hook authors can introduce subtle loop effects; the API contract must be clear about what `Continue` and `Abort` mean at each point. v0.1 intentionally keeps the outcome set small rather than carrying a generic `Skip` with ambiguous semantics.

**Neutral**
- External extension is encouraged, which nudges future features toward hooks instead of kernel patches.
- A small set of well-named hook points beats a proliferation of one-off callbacks; future ADRs may add points but should not retrofit existing ones silently.
- Larger feature families can introduce grouped hook points as long as they remain explicit, additive, and documented by ADR.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
