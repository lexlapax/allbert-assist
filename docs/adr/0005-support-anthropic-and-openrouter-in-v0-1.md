# ADR 0005: Support Anthropic and OpenRouter in v0.1

Date: 2026-04-17
Status: Accepted

## Context

Allbert's runtime boundary includes model-provider selection. The question is whether v0.1 should exercise that boundary with one provider first or carry at least two providers from the start. For this project, switching between providers is part of the intended workflow rather than a speculative future feature.

Deferring the second provider would simplify the first implementation, but it would also delay pressure-testing the provider seam, model configuration shape, cost accounting differences, and UX around switching models. If those seams are wrong, later retrofit work will be more expensive.

## Decision

v0.1 will ship with a provider abstraction and two supported providers:
- Anthropic
- OpenRouter

Provider choice is a runtime configuration concern, not a frontend concern. The kernel selects the provider implementation based on config and can expose runtime switching through frontend commands.

Provider metadata, especially OpenRouter pricing data, is best-effort. Failure to fetch pricing metadata must not block kernel boot or provider availability; fallback pricing data is acceptable for the MVP.

## Consequences

**Positive**
- The provider abstraction is exercised immediately instead of existing only on paper.
- Users can switch providers early to compare quality, latency, and cost.
- Cost tracking is forced to account for provider differences from the start.

**Negative**
- More implementation and verification work in M2.
- Slightly larger configuration and testing surface for the first release.

**Neutral**
- The abstraction should stay narrow; adding two providers does not imply supporting every provider soon.
- OpenRouter metadata freshness is useful but non-critical in the MVP.

## References

- [docs/plans/v0.01-mvp.md](../plans/v0.01-mvp.md)
