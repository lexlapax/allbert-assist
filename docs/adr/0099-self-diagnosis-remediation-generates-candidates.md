# ADR 0099: Self-diagnosis remediation generates concrete candidates with bounded LLM call

Date: 2026-04-26
Status: Accepted
Amends: [ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md), [ADR 0080](0080-self-change-artifacts-share-approval-provenance-and-rollback-envelope.md), [ADR 0067](0067-self-modification-uses-a-sibling-worktree-with-operator-diff-review.md)

## Context

v0.14 shipped self-diagnosis with three remediation routes ([ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md)): code (worktree plus `patch-approval`), skill (quarantine), and memory (staging). Each route was supposed to consume the diagnosis bundle and produce a candidate fix the operator reviews.

In practice, all three routes write scaffolds that point back at the diagnosis report:

- code remediation at [`self_diagnosis.rs:598`](../../crates/allbert-kernel/src/self_diagnosis.rs) creates a worktree, copies the report, and emits an empty patch artifact;
- skill remediation at line 659 writes a SKILL.md body that says "Describe the repeatable procedure that would prevent or explain this failure";
- memory remediation at line 702 stages a generic review note rather than a learned candidate.

None of these is a fix proposal. `--remediate` is therefore partial as of v0.14 and tracked by v0.14.1.

## Decision

v0.14.1 adds a candidate-generation step to each remediation route. Before writing the review artifact, the kernel issues one bounded provider call:

```rust
fn generate_candidate(
    provider: &dyn LlmProvider,
    kind: DiagnosisRemediationKind,
    bundle: &TraceDiagnosticBundle,
    report_md: &str,
    max_tokens: u32,
) -> Result<CandidateArtifact, KernelError>;
```

Prompt shape is kind-specific:

- **Code:** "You are reviewing an Allbert self-diagnosis report. Produce a unified diff under the source tree that addresses the identified failure. Output only the diff."
- **Skill:** "You are reviewing an Allbert self-diagnosis report. Produce a SKILL.md body for a remediation skill, including frontmatter with `allowed-tools` and a populated `## Behavior` section. Output only the SKILL.md."
- **Memory:** "You are reviewing an Allbert self-diagnosis report. Produce a memory candidate (>= 64 chars, factually grounded in the bundle) that captures what was learned. Output only the memory body."

User content is the bounded `TraceDiagnosticBundle` summary plus the existing `report.md`.

`max_tokens` is bounded by:

```toml
[self_diagnosis]
remediation_provider_max_tokens = 4096
```

Default: `4096`. Validation clamps to `[256, 16384]`.

## Validation and fallback

Each candidate is validated kind-specifically:

- Code: must parse as a unified diff, must not be empty, and must modify only allowed source-tree paths.
- Skill: must include valid frontmatter, `allowed-tools`, and a non-empty `## Behavior` section.
- Memory: must be at least 64 characters and reference at least one specific identifier from the bundle, such as a span id, tool name, classification label, or report evidence item.

Provider failure, empty output, malformed output, cost-cap refusal, disabled remediation, or validation failure falls back to the existing report-only scaffold unless the candidate is valid enough to route with a validation-failure marker. Fallback records `remediation.candidate_status = "fallback:<reason>"`. Reasons include `empty`, `malformed_diff`, `disallowed_path`, `missing_frontmatter`, `cost_cap`, `provider_error`, and `disabled`.

## Code remediation safety envelope

Code remediation preserves the self-change envelope from ADR 0067 and ADR 0080:

- The active source checkout is never modified directly.
- Candidate diffs are applied only inside a sibling worktree.
- Diff paths must be relative source-tree paths. Absolute paths, parent traversal, `.git`, runtime profile directories, secrets, adapter artifacts, and generated caches are rejected.
- Tier A validation runs inside the sibling worktree after applying a valid candidate diff. The default validation set is `cargo fmt --check`, workspace clippy with warnings denied, `cargo test -q`, and CLI help smoke unless the existing self-improvement policy narrows the set for the specific route.
- Validation command status and output paths are recorded in the patch approval metadata.
- A candidate that applies but fails validation may be routed for operator review only with `candidate_status = "validation_failed:<reason>"`; it is never installed automatically.

## Existing gates preserved

Candidate generation respects every v0.14 gate:

- `self_diagnosis.allow_remediation = false` short-circuits before the provider call.
- The daily monetary cost cap refuses the provider call when exceeded.
- Telegram remains structural-only; Telegram cannot start remediation.
- The `self_diagnose` tool remains report-only and rejects remediation input.
- Output routing remains `patch-approval`, `skills/incoming/`, and memory `staging/`. The candidate generator does not write directly into installed skills, durable memory, active source, adapters, or bootstrap files.

## Provenance

The candidate's frontmatter records:

- `provenance: self-diagnosed`;
- `diagnosis_id`;
- `candidate_status: routed | validation_failed:<reason> | fallback:<reason>`;
- `candidate_tokens_used`;
- `candidate_provider`;
- `candidate_model`;
- for code remediation, sibling worktree path, validation command list, validation status, and validation-output artifact paths.

## Consequences

- `--remediate` produces a real artifact the reviewer can read, edit, accept, or reject.
- The fallback path preserves the v0.14 report-only scaffold for weak providers, cost-cap exhaustion, or disabled remediation.
- Cost is bounded and visible through candidate token metadata and the daily cap.
- The "v0.14 remediation shipped" claim becomes true only after v0.14.1 lands; until then it remains partial as of v0.14 and tracked by v0.14.1.
- Future improvements such as multi-shot candidate ranking can be additive.

## Alternatives considered

- **Keep the scaffolding-only path.** Rejected because the operator still has to author the fix manually.
- **Use a dedicated specialized model for candidate generation.** Rejected for v0.14.1 because the existing provider seam is sufficient.
- **Generate candidates outside the cost-cap gate.** Rejected because remediation work is normal model work and must respect spend controls.
- **Require another per-run opt-in beyond `allow_remediation` and `--remediate`.** Rejected because the operator already opts in through config and command intent.
