# ADR 0013: Scheduled jobs are a non-interactive frontend over the kernel

Date: 2026-04-18
Status: Proposed

## Context

Allbert already made a load-bearing architecture choice in v0.1: the kernel is the runtime core and frontends are adapters. Scheduled jobs raise the same ownership question the REPL did earlier.

One option would be to add "job mode" directly into the kernel as a special execution path with its own state handling, input behavior, and output side effects. Another option is to treat jobs as just another frontend that drives the same kernel through the same adapter seam, but with non-interactive behavior.

The second option better matches the architecture already chosen. Jobs are not a new kernel. They are a new way of driving the existing one.

## Decision

Scheduled jobs will be implemented as a new frontend crate over `allbert-kernel`.

- v0.2 should add an `allbert-jobs` crate rather than embedding scheduler behavior into `allbert-cli` or into the kernel itself.
- `allbert-jobs` reuses the kernel API, hook system, tools, skills, memory, security, cost tracking, and tracing.
- The jobs frontend supplies its own adapter behavior for event handling, confirmation semantics, and input semantics.
- Each scheduled run should drive a fresh session by default rather than inheriting ambient REPL conversation state.
- Jobs may attach one or more ordered skills so reusable procedure can be layered onto a self-contained scheduled prompt.
- The kernel remains unaware of whether a turn came from the REPL or from a scheduled run.

## Consequences

**Positive**
- Preserves the kernel-first boundary already established in v0.1.
- Keeps scheduler behavior composable with the same tool, hook, memory, and policy surfaces.
- Makes future frontends easier because jobs do not become a privileged execution path inside the kernel.
- Keeps scheduled runs auditable because they do not depend on hidden chat carry-over.

**Negative**
- Requires designing one more frontend crate instead of dropping logic into the CLI.
- Non-interactive adapter semantics must be designed carefully to avoid silent unsafe behavior.
- Self-contained job prompts and skill attachment rules need clearer docs than the REPL path does.

**Neutral**
- `allbert-jobs` becomes a sibling of `allbert-cli`, not a replacement for it.
- Future automation or background surfaces can reuse the same pattern rather than inventing a new runtime boundary.
- First-party job templates can rely on the same skill system rather than inventing a second automation-specific procedure format.

## References

- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
