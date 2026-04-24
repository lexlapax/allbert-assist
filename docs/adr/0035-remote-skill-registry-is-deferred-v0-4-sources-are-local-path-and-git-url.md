# ADR 0035: Remote skill registry is deferred; v0.4 sources are local path and git URL

Date: 2026-04-18
Status: Accepted

## Context

Adopting the AgentSkills folder format (ADR 0032) raises the question of where skills come from. A curated central registry would help discovery, but it introduces:

- hosting scope (who runs it, who pays),
- governance (submission policy, removal policy, abuse reports),
- integrity story (signing, verification chain),
- ecosystem fragmentation risk (multiple competing registries).

v0.4's priority is the skill format and the local trust model, not a distribution platform. The release can ship real value with two well-understood install sources.

## Decision

v0.4 supports only two skill install sources:

1. **Local filesystem path** — a directory already on disk that matches the folder format.
2. **Git URL** — `https://` or `ssh://` URLs, optionally pinned to a ref or commit hash. Unpinned fetches resolve the current default branch and record the commit hash in the install metadata.

A curated registry is deferred. If a registry is introduced in a later release, it becomes a third source type and inherits the install preview + confirm gate (ADR 0033) with no other API change.

- Git fetches happen over the system `git` binary through the same `process_exec` seam (ADR 0004, ADR 0034) so all normal exec policy applies.
- Install metadata records the source identity, resolved commit hash, and fetch timestamp so the install can be re-verified later.
- Local-path installs record the absolute source path and the SHA-256 of the skill tree at install time.

## Consequences

**Positive**
- Keeps v0.4 scope contained to format + local trust model.
- Git URLs give real integrity guarantees when pinned and reproducible re-installs.
- Defers governance problems that a registry would force Allbert to solve before it is ready.

**Negative**
- No one-click discovery in v0.4. Users find skills out-of-band and install them explicitly.
- The ecosystem must tolerate that Allbert users share skills via git rather than a curated index for now.

**Neutral**
- A future registry (v0.5+ or later) slots in behind ADR 0033's preview + confirm gate with no redesign.
- Curated registry indexes published out-of-band remain usable as pointer lists even before an in-runtime registry exists.

## References

- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [docs/plans/v0.04-agentskills-adoption.md](../plans/v0.04-agentskills-adoption.md)
