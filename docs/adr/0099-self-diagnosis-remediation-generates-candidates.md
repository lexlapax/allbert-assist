# ADR 0099: Self-diagnosis remediation generates concrete candidates with bounded LLM call

Date: 2026-04-26
Status: Accepted

## Context

v0.14 shipped self-diagnosis with three remediation routes ([ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md)): code (worktree + `patch-approval`), skill (quarantine), and memory (staging). Each route was supposed to consume the diagnosis bundle and produce a candidate fix the operator reviews.

In practice, all three routes write empty review forms that point back at the diagnosis report:

- Code remediation at [`self_diagnosis.rs:598`](../../crates/allbert-kernel/src/self_diagnosis.rs) creates a worktree, copies the report into `docs/reports/self-diagnosis/<id>.md`, and emits an empty patch artifact.
- Skill remediation at line 659 writes a SKILL.md body that reads "Describe the repeatable procedure that would prevent or explain this failure."
- Memory remediation at line 702 stages a memo that reads "Review this candidate before promotion. Do not promote if it is only a transient local failure."

None of these is a *fix proposal*. Each is a placeholder pointing the operator at the same diagnosis report they already read. The operator has to author the fix manually anyway, which makes `--remediate` no faster than `diagnose run` followed by handwritten remediation.

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

Prompt shape (kind-specific):

- **Code:** "You are reviewing an Allbert self-diagnosis report. Produce a unified diff under the source tree that addresses the identified failure. Output only the diff."
- **Skill:** "You are reviewing an Allbert self-diagnosis report. Produce a SKILL.md body for a remediation skill, including frontmatter with `allowed-tools` and a populated `## Behavior` section. Output only the SKILL.md."
- **Memory:** "You are reviewing an Allbert self-diagnosis report. Produce a memory candidate (>= 64 chars, factually grounded in the bundle) that captures what was learned. Output only the memory body."

User content: the bounded `TraceDiagnosticBundle` summary plus the existing `report.md`.

`max_tokens` is bounded by a new config key `self_diagnosis.remediation_provider_max_tokens` (default 4096, range 256..16384).

### Validation and fallback

Each candidate is validated kind-specifically:

- Code: must parse as a unified diff; rejected if empty or malformed.
- Skill: must include valid frontmatter, `allowed-tools`, and a non-empty Behavior section.
- Memory: must be >= 64 characters and reference at least one specific identifier from the bundle (span id, tool name, classification label).

On validation failure, the kernel falls back to the existing report-only scaffold and records `remediation.candidate_status = "fallback:<reason>"` in the approval/skill/staged-memory frontmatter. Reasons: `empty`, `malformed_diff`, `missing_frontmatter`, `cost_cap`, `provider_error`, `disabled`.

### Existing gates preserved

Candidate generation respects every v0.14 gate:

- `self_diagnosis.allow_remediation = false` short-circuits before the provider call (existing rule, [ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md)).
- The daily monetary cost cap ([ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)) refuses the provider call when exceeded; fallback path is taken.
- Telegram remains structural-only — Telegram cannot start remediation; the candidate generator is unreachable from a Telegram session.
- `self_diagnose` tool input rejection still applies — the model cannot start remediation by emitting tool calls; remediation requires CLI/REPL/TUI command parsing.
- Output routing — `patch-approval`, `skills/incoming/`, and `staging/` remain the only review surfaces. The candidate generator does not write directly into installed skills, durable memory, or active source.

### Provenance

The candidate's frontmatter records:

- `provenance: self-diagnosed`;
- `candidate_status: routed | fallback:<reason>`;
- `candidate_tokens_used: <n>` for cost transparency;
- `candidate_provider: <provider/model>` so reviewers can see which provider produced the artifact;
- `diagnosis_id: <id>` linking back to the source report.

## Consequences

- `--remediate` produces a real artifact the reviewer can read, edit, accept, or reject — not a form that says "describe the procedure."
- The fallback path preserves the existing scaffold, so an operator at the cost cap or a provider with weak generation still gets the v0.14 review form.
- Cost is bounded and visible: `candidate_tokens_used` plus the daily cap mean a runaway remediation pass is impossible.
- The "v0.14 remediation shipped" claim becomes accurate after v0.14.1.
- Future improvements (e.g. multi-shot candidate generation, candidate ranking, golden-set evaluation of candidates) are additive and don't require revisiting this ADR.

## Alternatives considered

- **Keep the scaffolding-only path.** Rejected because the v0.14 user transcript shows operators expecting a candidate fix; the empty form is interpreted as a bug.
- **Use a dedicated specialized model for candidate generation.** Rejected for v0.14.1 because the kernel's existing provider seam works; specialized models can land additively later.
- **Generate candidates outside the cost-cap gate.** Rejected because remediation work is the operator's daily-cost work like any other turn.
- **Require the operator to opt into candidate generation per run.** Rejected because the operator already opts in twice (`self_diagnosis.allow_remediation = true` and `--remediate <kind> --reason <text>`); a third opt-in is redundant.
