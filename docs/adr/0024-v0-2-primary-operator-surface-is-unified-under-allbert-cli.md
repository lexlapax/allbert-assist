# ADR 0024: v0.2 primary operator surface is unified under allbert-cli

Date: 2026-04-19
Status: Accepted

## Context

By the end of M4, the daemon runtime and jobs client both existed, but the operator experience was still split. The plan already treated `allbert-cli` as the main user-facing binary, while `allbert-jobs` existed as a convenience alias. The remaining question is whether v0.2 should close out with multiple equally documented binaries, or with one primary operator surface and smaller aliases around it.

For a source-based technical-user release, one primary CLI is the more usable shape. It keeps onboarding, docs, support expectations, and shell history simpler, while still allowing convenience aliases for advanced users.

## Decision

v0.2's primary operator surface is unified under `allbert-cli`.

- REPL usage, daemon lifecycle commands, and jobs lifecycle commands are all supported from `allbert-cli`.
- `allbert-jobs` remains available as an alias binary over the same thin-client implementation, not as a separate product surface.
- Source-based docs should use `cargo run -p allbert-cli -- ...` as the canonical example path.
- Any future shorter installed alias (such as `allbert`) is a packaging concern, not a separate runtime contract.
- This operator unification does not mean recurring jobs are CLI-only forever. Conversational job management remains an expected v0.2 closeout path, with `allbert-cli` preserved as the authoritative operator escape hatch.

## Consequences

**Positive**
- Gives v0.2 one clear end-user entry point.
- Keeps docs and support burden lower.
- Preserves the alias binary without making it architecturally special.

**Negative**
- Requires some command-surface refactoring before closeout.
- Makes the primary CLI slightly larger than a REPL-only tool.

**Neutral**
- The alias binary can still be useful for users who prefer dedicated job commands.
- A future packaged release can change the executable name without changing the operator model.
- Prompt-native job management can still be added without changing this ADR, as long as `allbert-cli` remains the canonical explicit operator surface.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md)
- [ADR 0026](0026-interactive-sessions-expose-first-class-daemon-backed-job-management-tools.md)
