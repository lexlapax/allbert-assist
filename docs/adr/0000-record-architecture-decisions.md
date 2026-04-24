# ADR 0000: Record architecture decisions

Date: 2026-04-17
Status: Accepted

## Context

Allbert is expected to grow from a small Rust kernel into a substantial system with many subsystems (kernel, skills, memory, security, scripting, cron, gateways, trainers). Decisions made early — choice of provider abstraction, skill format, hook API, memory layout, etc. — will be load-bearing for a long time. Without a durable record of *why* a decision was made, future contributors (including the original author) will revisit the same questions, often with incomplete context, and drift away from the reasoning that made the current design coherent.

Planning documents are not a substitute for decision records. A plan says "here is what I will build this week" and becomes stale the moment the milestone ships. A design document describes how a system currently works — but it rarely captures the reasoning for why it works *that way* rather than some equally plausible alternative.

## Decision

We adopt **Architecture Decision Records (ADRs)** using a lightly adapted Nygard format.

1. **Scope.** One ADR per significant architectural decision. "Significant" means: the decision shapes more than one file, constrains future work, or required rejecting a plausible alternative. Tactical choices (naming, crate version bumps, one-line refactors) do not need ADRs.

2. **Location.** `docs/adr/NNNN-kebab-case-slug.md`, where `NNNN` is a zero-padded four-digit sequential number. ADR `0000` is this meta-ADR. Numbers never repeat and never get reordered, even if an ADR is later superseded.

3. **Format.** Each ADR has at minimum:
   - `# ADR NNNN: Title` heading
   - `Date:` — ISO 8601 date of the decision
   - `Status:` — one of `Proposed`, `Accepted`, `Superseded by NNNN`, `Deprecated`
   - `## Context` — the problem, constraints, and what made this decision necessary
   - `## Decision` — what we chose, stated declaratively
   - `## Consequences` — positive, negative, and neutral effects; known trade-offs accepted

   Optional sections (`## Alternatives considered`, `## References`) are encouraged when they add value.

4. **Immutability.** Once an ADR is `Accepted`, its content is immutable except for status transitions. To change a decision, write a *new* ADR that supersedes the old one. The old ADR's status becomes `Superseded by NNNN`; its body is not edited. This preserves the historical reasoning.

5. **Relationship to plans and design docs.**
   - **Plans** (`docs/plans/`) are short-lived, milestone-scoped. They describe upcoming work and may contain decisions-in-flight. When a plan's decisions are ratified, extract them into ADRs.
   - **Design docs** (`docs/design/`) describe how subsystems currently work. They are living references, updated as the code changes. They may cite ADRs for reasoning but should not duplicate ADR bodies.
   - **ADRs** are the one-way record of *why*.

6. **Style.** Keep ADRs short: 200–600 words typical. If an ADR grows beyond a page, the decision is probably actually several decisions and should be split.

## Consequences

**Positive**
- Reasoning for load-bearing decisions survives author turnover, code refactors, and memory decay.
- "Why don't we just do X?" questions have a single-source answer or — if the answer isn't recorded — reveal an implicit decision that deserves its own ADR.
- Onboarding is faster: read the ADR index, understand the shape of the system before diving into code.

**Negative**
- Small ongoing maintenance cost: writing an ADR adds minutes to each significant decision.
- Risk of ADR sprawl if the bar for "significant" is set too low. Mitigation: when in doubt, write a design-doc update instead and let the ADR threshold stay high.
- Superseded ADRs accumulate. This is the intended trade-off (history over tidiness), but the index may need curation eventually.

**Neutral**
- ADRs numbered from `0000` rather than `0001` so the meta-ADR has its own slot without displacing substantive decisions.
- The format is deliberately lightweight; teams that prefer MADR or other templates can switch later by updating this ADR (which would then supersede itself via a new ADR).

## References

- Michael Nygard, ["Documenting Architecture Decisions"](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions) (2011) — original format.
- [docs/plans/v0.01-mvp.md](../plans/v0.01-mvp.md) — the planning document whose resolved decisions will seed ADRs `0001`–`0006` after v0.1 ships.
