# ADR 0079: Personality digest is a review-first LearningJob, not hidden memory or training

Date: 2026-04-24
Status: Accepted

## Context

v0.11 adds a first step toward the origin note's "learn my personality over time" ambition. The risk is collapsing three different concepts into one vague feature:

- durable learned memory, which must stay review-first;
- seeded bootstrap personality files, especially `SOUL.md`, which affect every future prompt and express operator-owned persona;
- learned personality overlays, which can summarize adaptation patterns but must not override the seeded persona;
- model training, which is deferred to v0.13.

The v0.11 feature must be useful without creating hidden durable memory, silently rewriting `SOUL.md`, replacing operator-authored identity, or training a model.

## Decision

v0.11 introduces `PersonalityDigestJob` as the first implementation of a general `LearningJob` trait.

The digest job:

- is opt-in and disabled by default;
- reads a bounded corpus of approved durable memory, approved fact entries, and recent episode summaries labelled as working-history-derived input;
- excludes staged entries and unapproved candidate learnings;
- ships with a provider-free deterministic renderer in v0.11 while preserving the hosted-provider corpus-upload consent gate for future model-authored digest renderers;
- records hosted-provider corpus-upload consent as profile-local runtime state under `~/.allbert/learning/personality-digest/consent.json`;
- writes draft artifacts under `~/.allbert/learning/personality-digest/runs/<run_id>/`;
- installs the accepted digest output path (`~/.allbert/PERSONALITY.md` by default) only after explicit operator acceptance;
- never writes `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `HEARTBEAT.md`, or `BOOTSTRAP.md`;
- routes any net-new candidate learnings through the existing staging pipeline;
- does not train, fine-tune, distil, or create a model adapter.

The accepted digest output path is an optional bootstrap prompt-surface artifact and `LearningJob` output, not a replacement for `SOUL.md`. It is not seeded on first boot, is skipped when absent, is bounded by bootstrap prompt limits when present, and is treated as sensitive prompt surface when changed.

| File | Role | Creation | Authority |
| --- | --- | --- | --- |
| `SOUL.md` | Constitutional persona: purpose, values, tone, boundaries, behavioral stance. | Seeded on first boot; operator-owned. | Higher authority; digest must never write it. |
| `PERSONALITY.md` | Reviewed learned-personality overlay: collaboration style and adaptation hints. | Optional; accepted digest output or direct operator edit. | Lower authority; loses conflicts to current user instruction, `SOUL.md`, user/profile files, policy, and tool/security rules. |

`learning.personality_digest.output_path` defaults to `PERSONALITY.md`, is profile-relative, must resolve inside `ALLBERT_HOME`, must be markdown, and must reject reserved prompt/runtime targets including `SOUL.md`. Digest-generated output carries provenance frontmatter (`version`, `kind = "personality_digest"`, `authority = "learned_overlay"`, `generated_by`, `source_run_id`, `corpus_digest`, `corpus_tiers`, `accepted_at`) and fixed body sections: `Learned Collaboration Style`, `Stable Interaction Preferences`, `Useful Cautions`, and `Open Questions`.

`PERSONALITY.md` must not contain raw transcript excerpts, unapproved staged facts, or durable factual claims that belong in memory. Net-new learnings still route to staging.

The `LearningJobReport` shape uses general vocabulary so future learning jobs can reuse it without changing v0.11's contract: `inputs`, `execution`, `resource_cost`, `output_artifacts`, and `staged_candidates`.

## Consequences

**Positive**

- Allbert gets a reviewable personality digest without weakening the memory staging contract.
- Future personalization work can plug into the same `LearningJob` seam.
- Hosted-provider privacy implications are explicit before any future corpus upload.
- `PERSONALITY.md` remains inspectable and user-editable without weakening `SOUL.md` ownership.

**Negative**

- The digest output can feel conservative in v0.11 because the shipped renderer is deterministic and provider-free.
- Scheduled digest runs may defer more often when hosted-provider consent or digest acceptance is missing.

**Neutral**

- v0.13 may add adapter-training jobs additively, but v0.11 does not reserve or implement trainer backends.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [OpenClaw SOUL.md guide](https://clawdocs.org/guides/soul-md/)
- [Claude Code memory docs](https://code.claude.com/docs/en/memory)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0017](0017-v0-2-ships-bundled-job-templates-disabled-by-default.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0077](0077-episode-and-fact-memory-are-indexed-recall-not-durable-memory.md)
