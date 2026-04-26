# ADR 0095: Doc-reality reconciliation gates are CI checks

Date: 2026-04-26
Status: Accepted

## Context

Through v0.14, several releases marked features as "Shipped" in the roadmap, plan files, README, CHANGELOG, and operator docs while leaving substantive parts unimplemented. Three concrete cases motivated this ADR:

- v0.13 marked the daemon adapter protocol as shipped while [`server.rs:1183-1205`](../../crates/allbert-daemon/src/server.rs) returns `adapter_surface_not_implemented` for every adapter message.
- v0.13 marked real-backend adapter training as shipped while [`adapters/job.rs`](../../crates/allbert-kernel/src/adapters/job.rs) only constructs `FakeAdapterTrainer`; `learning.adapter_training.default_backend` is collected and validated but never read by a factory.
- v0.14 marked self-diagnosis remediation as shipped while [`self_diagnosis.rs:598-751`](../../crates/allbert-kernel/src/self_diagnosis.rs) writes empty review artifacts that point back at the diagnosis report instead of generating candidate fixes.

Each case is recoverable. Without a guardrail, the same pattern can re-occur as new releases add ambition.

## Decision

Doc-reality reconciliation is a release-blocking CI gate, not a per-release review item.

A new script `tools/check_doc_reality.sh` runs in the standard `cargo test` path. It enforces three rules:

1. **Overclaim phrases require qualification.** The script greps the docs tree for known overclaim patterns (an extensible list maintained alongside the script) and requires each occurrence to be within 5 lines of either "partial", "scaffolding", "v0.x.y reconciled", or "Status: Stub". Unqualified occurrences fail the build.
2. **Code escape hatches require doc notes.** The script greps the codebase for `unimplemented!`, `todo!`, error codes ending in `_not_implemented`, and `FakeAdapterTrainer` outside `#[cfg(test)]` modules. Each occurrence must be paired with a doc-side acknowledgement in the relevant plan or upgrade note.
3. **Roadmap rows match release status.** The script parses [`docs/plans/roadmap.md`](../plans/roadmap.md) and confirms every "Shipped" row points to a plan file whose `Status:` line says `Shipped` (not `Draft` or `Stub`).

Violations are release-blocking. The script's allowlist is reviewable in PRs; loosening it requires explicit reviewer signoff on the diff to the script itself.

The script is wired into:

- the workspace `cargo test` pre-step, via a build-script invocation or `[[test]]` integration test, so contributors see failures locally before pushing;
- any CI workflow (when present) that runs `cargo test`.

## Consequences

- Reconciliation cost is paid up front, in v0.14.1, by adding qualifications to existing overclaims. Future releases pay it incrementally.
- New `unimplemented!` paths require an explicit doc note instead of silent landing. This trades a small per-PR cost for sustained doc credibility.
- The script's overclaim-pattern list is itself a doc artifact. As new release-blocking surfaces ship, the list grows; as old surfaces become stable, individual entries can be retired with reviewer signoff.
- The script does not enforce code correctness; it only enforces that doc and code agree about what shipped. Tier A validation continues to enforce code correctness.

## Alternatives considered

- **Per-release review item.** v0.13 and v0.14 both had readiness reviews. Both shipped overclaims anyway. Manual review at release time has not been sufficient.
- **External CI-only gate.** Rejected because the project must remain provider-free and Codex-Web-runnable per [ADR 0064](0064-default-contributor-validation-is-provider-free-temp-home-based-and-network-optional.md). The check must run inside `cargo test`.
- **Doc-tests inside Rust source.** Considered; rejected because most overclaim-prone strings live in markdown, not Rust doc comments.
