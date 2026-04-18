# ADR 0011: v0.1 closeout targets a source-based CLI with guided onboarding and explicit workspace trust

Date: 2026-04-18
Status: Accepted

## Context

By the end of M6, Allbert's kernel feature milestones were complete: bootstrap context, provider switching, tools, skills, memory, security, cost tracking, and tracing all existed. That raised a release question rather than a kernel question: what does it take to call v0.1 actually wrapped?

There were at least three plausible interpretations:

1. call v0.1 done as soon as the milestone code exists;
2. broaden the scope to packaged installers or a richer frontend so non-technical users can adopt it immediately;
3. keep v0.1 focused on a technical local CLI user, but add the onboarding, docs, and release validation needed to make that audience successful.

Option (1) is too weak: it treats implementation milestones as equivalent to release readiness and leaves onboarding to guesswork. Option (2) broadens the product surface significantly and would delay shipping for reasons unrelated to the kernel architecture. Option (3) keeps the original scope disciplined while still taking usability seriously.

## Decision

v0.1 closeout targets a **source-based terminal CLI for technical users**.

- The primary v0.1 user is someone comfortable building from source, setting provider API-key environment variables, and working in a terminal.
- Onboarding belongs in the CLI/frontend layer rather than the kernel. The kernel remains the runtime core; the CLI owns first-run setup UX.
- `fs_roots` remains deny-by-default until the user explicitly configures trusted roots.
- Guided setup recommends the current working directory as a likely first trusted root, but does not auto-trust it.
- `BOOTSTRAP.md` is removed only after successful guided setup. If setup is cancelled or incomplete, it remains present so the runtime continues to signal unfinished onboarding.
- Packaged installers, desktop shells, and broader distribution UX are out of scope for v0.1.
- v0.1 is not marked shipped until clean-home live smoke succeeds on both Anthropic and OpenRouter through the documented setup path.

## Consequences

**Positive**
- The release target becomes explicit and achievable instead of drifting between "developer prototype" and "consumer app."
- Onboarding work improves real usability without bloating the kernel or changing its architectural boundary.
- Explicit workspace trust stays aligned with the security model already established by the earlier ADRs.

**Negative**
- v0.1 remains a technical-user release, not a general-audience product.
- Closeout adds work after the core feature milestones: setup UX, docs, and manual release validation.

**Neutral**
- Future versions can add packaged distribution or non-terminal frontends, but those will be new product-surface decisions rather than implicit v0.1 scope creep.
- The CLI becomes a better operator experience without becoming the architecture center.
