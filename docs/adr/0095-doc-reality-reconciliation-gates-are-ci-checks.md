# ADR 0095: Doc-reality reconciliation gates are CI checks

Date: 2026-04-26
Status: Accepted

## Context

Through v0.14, several releases marked features as "Shipped" in the roadmap, plan files, README, CHANGELOG, and operator docs while leaving substantive parts unimplemented. Three concrete cases motivated this ADR:

- v0.13 marked the daemon adapter protocol as shipped while [`server.rs:1183-1205`](../../crates/allbert-daemon/src/server.rs) returns `adapter_surface_not_implemented` for every adapter message.
- v0.13 marked real-backend adapter training as shipped while [`adapters/job.rs`](../../crates/allbert-kernel/src/adapters/job.rs) constructs `FakeAdapterTrainer` on production paths; `learning.adapter_training.default_backend` is collected and validated but not used for production trainer selection.
- v0.14 marked self-diagnosis remediation as shipped while [`self_diagnosis.rs:598-751`](../../crates/allbert-kernel/src/self_diagnosis.rs) writes report-only scaffolds instead of candidate fixes.

Each case is recoverable. Without a guardrail, the same pattern can recur as new releases add ambition.

## Decision

Doc-reality reconciliation is a release-blocking validation gate, not a manual checklist item.

A new script `tools/check_doc_reality.sh` runs through the standard `cargo test` path by way of a Rust integration test wrapper. The wrapper invokes the script as a subprocess, checks its exit status, and prints the script output on failure so contributors see the same failure locally and in CI.

The script enforces three rules:

1. **Overclaim phrases require qualification.** The script greps the docs tree for known overclaim patterns maintained alongside the script. Each occurrence must be within 5 lines of one of these qualifiers: "partial as of v0.x", "planned for v0.x.y", "reconciled in v0.x.y", "scaffolded", or `Status: Stub`. Unqualified occurrences fail validation.
2. **Code escape hatches require doc notes.** The script greps the codebase for `unimplemented!`, `todo!`, error codes ending in `_not_implemented`, and production uses of `FakeAdapterTrainer` outside test-only or explicit fake-backend paths. Each occurrence must be paired with a doc-side acknowledgement in the relevant plan, upgrade note, or operator limitation.
3. **Roadmap rows match release status.** The script parses [`docs/plans/roadmap.md`](../plans/roadmap.md) and confirms every `Shipped` row points to a plan file whose `Status:` line says `Shipped`; draft and stub releases must be labelled as such.

Violations are release-blocking. The script's pattern list and allowlist are reviewable in PRs; loosening either requires explicit reviewer signoff on the diff to the script itself.

The script is wired into:

- a Rust integration test included in normal `cargo test`, so contributors see failures before pushing;
- any CI workflow that runs the default test suite.

## Consequences

- Reconciliation cost is paid up front in v0.14.1 by adding qualifications to existing overclaims.
- Future releases pay the cost incrementally: a release can still ship partial surfaces, but the docs must say so.
- New `unimplemented!` paths, `_not_implemented` errors, and fake-production fallbacks require explicit doc acknowledgement instead of silent landing.
- The script does not enforce code correctness; it enforces agreement between docs and code. Tier A validation continues to enforce code behavior.

## Alternatives considered

- **Per-release review item.** v0.13 and v0.14 both had readiness reviews. Both shipped overclaims anyway. Manual review at release time has not been sufficient.
- **External CI-only gate.** Rejected because the project must remain provider-free and Codex-Web-runnable per [ADR 0064](0064-default-contributor-validation-is-provider-free-temp-home-based-and-network-optional.md). The check must run inside `cargo test`.
- **Doc-tests inside Rust source.** Considered; rejected because most overclaim-prone strings live in markdown, not Rust doc comments.
