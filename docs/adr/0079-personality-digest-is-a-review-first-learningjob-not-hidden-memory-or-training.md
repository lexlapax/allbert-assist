# ADR 0079: Personality digest is a review-first LearningJob, not hidden memory or training

Date: 2026-04-24
Status: Proposed

## Context

v0.11 adds a first step toward the origin note's "learn my personality over time" ambition. The risk is collapsing three different concepts into one vague feature:

- durable learned memory, which must stay review-first;
- bootstrap personality files, which affect every future prompt;
- model training, which is deferred to v0.13.

The v0.11 feature must be useful without creating hidden durable memory, silently rewriting bootstrap context, or training a model.

## Decision

v0.11 introduces `PersonalityDigestJob` as the first implementation of a general `LearningJob` trait.

The digest job:

- is opt-in and disabled by default;
- reads a bounded corpus of approved durable memory, approved fact entries, and recent episode summaries labelled as working-history-derived input;
- excludes staged entries and unapproved candidate learnings;
- runs through the active provider only after any required hosted-provider corpus-upload consent has been granted;
- records hosted-provider corpus-upload consent as profile-local runtime state under `~/.allbert/learning/personality-digest/consent.json`;
- writes draft artifacts under `~/.allbert/learning/personality-digest/runs/<run_id>/`;
- installs `~/.allbert/PERSONALITY.md` only after explicit operator acceptance;
- routes any net-new candidate learnings through the existing staging pipeline;
- does not train, fine-tune, distil, or create a model adapter.

`PERSONALITY.md` is an optional bootstrap prompt-surface artifact. It is not seeded on first boot, is skipped when absent, is bounded by bootstrap prompt limits when present, and is treated as sensitive prompt surface when changed.

The `LearningJobReport` shape uses general vocabulary so future learning jobs can reuse it without changing v0.11's contract: `inputs`, `execution`, `resource_cost`, `output_artifacts`, and `staged_candidates`.

## Consequences

**Positive**

- Allbert gets a reviewable personality digest without weakening the memory staging contract.
- Future personalization work can plug into the same `LearningJob` seam.
- Hosted-provider privacy implications are explicit before corpus upload.
- `PERSONALITY.md` remains inspectable and user-editable.

**Negative**

- The digest flow needs approval plumbing before `PERSONALITY.md` can affect prompts.
- Scheduled digest runs may defer more often when hosted-provider consent or digest acceptance is missing.

**Neutral**

- v0.13 may add adapter-training jobs additively, but v0.11 does not reserve or implement trainer backends.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0017](0017-v0-2-ships-bundled-job-templates-disabled-by-default.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0077](0077-episode-and-fact-memory-are-indexed-recall-not-durable-memory.md)
