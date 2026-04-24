# ADR 0080: Self-change artifacts share approval, provenance, and rollback envelope

Date: 2026-04-24
Status: Proposed

## Context

The roadmap now contains several ways Allbert can create artifacts that may affect its future behavior:

- v0.11 personality digests and staged memory candidates;
- v0.12 source patches and self-authored skills;
- v0.13 model adapters;
- v0.14 diagnostic patches, diagnostic skills, and memory remediation.

Each artifact kind has its own storage and review shape, but they should not each invent a new trust model.

## Decision

All self-change artifacts share one envelope:

- artifacts are produced in an isolated or reviewable location before activation;
- artifacts carry provenance metadata where the artifact format supports it;
- state-changing activation requires an approval surface or the staging pipeline;
- monetary spend is gated by ADR 0051, and future local compute-bound jobs add compute caps explicitly where needed;
- hook and telemetry surfaces make the attempted change observable;
- accepted artifacts have an audit or rollback trail appropriate to their type.

Concrete mappings:

- v0.11 personality digest drafts live under `~/.allbert/learning/personality-digest/runs/<run_id>/` and install to the configured personality output path (`PERSONALITY.md` by default) only after acceptance. The digest may install that learned overlay only; any proposed `SOUL.md` edit remains a separate sensitive bootstrap-file mutation requiring direct operator intent and confirmation.
- v0.12 source patches use sibling worktrees and `patch-approval`.
- v0.12 self-authored skills use `skills/incoming/` and install preview.
- v0.13 adapters use `~/.allbert/adapters/` and `adapter-approval`.
- v0.14 diagnostic skills use the skill quarantine and `provenance: self-diagnosed`; diagnostic memory remediation uses staging.

The provenance enum is additive across releases. Planned values include `self-authored`, `self-trained`, and `self-diagnosed`.

## Consequences

**Positive**

- Future self-change features reuse a common safety story.
- Review surfaces stay familiar even as artifact kinds grow.
- Operators can audit what Allbert proposed, what was accepted, and how to roll it back.

**Negative**

- New artifact kinds must do extra product work before they can ship.
- Some future releases need migration tests for provenance values and rollback metadata.

**Neutral**

- This ADR defines the envelope, not the exact schema for every future artifact kind.

## References

- [docs/plans/roadmap.md](../plans/roadmap.md)
- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0073](0073-rebuild-patch-approval-is-a-new-inbox-kind.md)
- [ADR 0079](0079-personality-digest-is-a-review-first-learningjob-not-hidden-memory-or-training.md)
