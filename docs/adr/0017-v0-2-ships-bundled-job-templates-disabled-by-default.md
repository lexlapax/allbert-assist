# ADR 0017: v0.2 ships bundled job templates disabled by default

Date: 2026-04-18
Status: Accepted

## Context

The point of v0.2 is not only to let advanced users hand-author jobs. It should also show what a good Allbert automation looks like out of the box. OpenClaw and Hermes both make their automation systems legible by pairing the scheduler with concrete examples such as reminders, briefs, monitoring, and recurring maintenance work.

For Allbert, that suggests shipping a small starter set of first-party jobs. The remaining choice is whether those should be auto-enabled or merely available.

Given Allbert's local-first and explicit-trust posture, auto-enabling background work would be too aggressive for the first release.

## Decision

v0.2 will ship bundled first-party job templates owned by the daemon-managed jobs system, and they will be disabled by default.

- The user can inspect, enable, edit, or copy them.
- The initial bundled set should include `daily-brief`, `weekly-review`, `memory-compile`, `trace-triage`, and `system-health-check`.
- Bundled jobs should prefer first-party skills or concise first-party prompts rather than large duplicated prompt blobs.
- Bundled jobs should also document their default report policy, with anomaly-first defaults where appropriate.

## Consequences

**Positive**
- Gives users a concrete starting point without turning on background behavior implicitly.
- Makes the product easier to understand and test.
- Encourages shared patterns for maintenance-oriented jobs.

**Negative**
- Adds some product/design surface because the bundled jobs become part of the release contract.
- Requires docs and tests to explain what each template does and why it starts disabled.

**Neutral**
- Users can still create jobs from scratch; the bundled set is a starter kit, not a limit.
- Future releases can add more templates or enable setup-time recommendations without changing this default.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [docs/notes/v0.2-target-2026-04-18.md](../notes/v0.2-target-2026-04-18.md)
