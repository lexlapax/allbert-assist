# ADR 0067: Self-modification uses a sibling worktree with operator diff review

Date: 2026-04-23
Status: Proposed

## Context

v0.12 ships a Rust rebuild skill (`rust-rebuild`) that lets Allbert read, modify, build, and test its own source tree. That capability needs a concrete answer to four questions before any code lands:

1. **Where do edits happen?** Editing the active source checkout in place is the simplest model but it makes a broken edit immediately fatal: a failing `cargo build` in the same tree the running daemon is built from corrupts incremental state and can take down the operator's working setup. Editing somewhere isolated avoids that, but introduces a sibling-tree management problem.
2. **What is allowed to live in that workspace?** Without a path-allowlist, the rebuild agent could touch user data (sessions, memory, identity, secrets), other skills, or even its own source files in a way that subtly breaks the next rebuild.
3. **How does the operator review the result?** A successful rebuild produces a diff. Existing surfaces — the REPL, the v0.7 inbox tool-approval renderer — were designed for short tool-call confirmations, not for thousands of lines of code change.
4. **What if the rebuild needs source files that aren't there?** Operators who installed Allbert via `cargo install` or a binary drop don't have a source checkout. The skill cannot silently invent one.

The principle from ADR 0038 (natural interface) and ADR 0033 (skill install preview + confirm) makes the framing clear: Allbert codes; the operator reviews. Self-modification is not a privileged path — it is one more artifact that routes through an existing trust gate.

## Decision

Self-modification operates in **sibling git worktrees** of the active source checkout. Operator review happens through the v0.8 approval inbox, extended with a new `patch-approval` kind in ADR 0073.

### Source checkout resolution

The rebuild skill resolves the active source checkout in this order:

1. The `self_improvement.source_checkout` config value if set;
2. The `$ALLBERT_SOURCE_CHECKOUT` env var if set;
3. An upward walk from the running executable's symlink-resolved path looking for a `Cargo.toml` whose `[workspace].members` includes `allbert-kernel`.

If none resolves, the skill **refuses to activate** with an operator-readable error directing the user to `allbert-cli self-improvement config`. The rebuild path is opt-in for operators who have a local checkout; binary-drop installs neither silently work nor silently break.

### Worktree shape

- Worktrees live under `~/.allbert/worktrees/<branch>/` (configurable via `self_improvement.worktree_root`).
- Each worktree is a full `git worktree add` from the resolved source checkout, with its own isolated `target/` directory.
- A `self_improvement.max_worktree_gb` cap (default `10`) bounds total worktree disk use; the daemon refuses to create a new worktree past the cap.
- Stale worktree garbage collection is operator-driven via `allbert-cli self-improvement gc`. The daemon never runs GC automatically, because deciding which worktree is stale requires operator context (in-flight review, pending merge, etc.).

### Path allowlist

The rebuild skill's exec policy enforces a path allowlist for write operations:

- ✅ The active worktree directory tree.
- ❌ Any path under `~/.allbert/` other than the worktree root (no read or write access to user data: sessions, memory, identity, secrets, installed skills).
- ❌ The active source checkout's working tree (no in-place edits).
- ❌ The `skills/rust-rebuild/` directory inside the source checkout (the skill cannot patch itself; this is the runaway-self-edit guard).

Violations fail the turn at the exec seam. This is enforced by the kernel, not by the skill prompt — the skill cannot grant itself write access by editing its own SKILL.md.

### Validation contract

A rebuild is "safe to merge" only when ADR 0064 Tier A passes cleanly inside the worktree:

- `cargo fmt --check`;
- `env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings`;
- `env -u RUSTC_WRAPPER cargo test -q`;
- `env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help`;
- temp-home `daemon status` smoke.

Tier B (live-provider smokes) is **not** required. Any Tier A failure marks the patch `needs-review`; the inbox renderer shows the failing context but the patch cannot be accepted via the `safe-to-merge` path.

### Operator review

The diff produced by a successful (or `needs-review`) build is routed through a new `patch-approval` inbox kind, defined in ADR 0073. The diff itself lives at `sessions/<sid>/artifacts/<aid>/patch.diff`; the inbox markdown carries metadata only. The operator can approve, reject, or ask for changes from any surface the v0.8 inbox supports.

### Cost-cap interaction with long builds

`cargo build` and `cargo test` can take many minutes of wall-clock time but consume zero model tokens once the agent has emitted the build commands. ADR 0051 caps daily model spend at the turn boundary. v0.12 reaffirms that cap shape:

- Tier A validation counts as a single turn-unit for ADR 0051 accounting.
- Wall-clock build time is **not** charged against the cap; only model token usage is metered.
- A rebuild turn that exceeds the daily cap mid-run refuses at the next turn boundary per ADR 0051 — the same way any long-running tool sequence does.

This resolves the v0.12-pre-implementation ambiguity about whether a 20-minute test run "exceeds the cap." It does not, unless the model is also generating tokens during that 20 minutes.

### cargo network access

`cargo build` may fetch dependencies from crates.io. That fetch is a **build step**, not background web learning, and is governed by the exec policy (ADR 0004 / ADR 0034) only. ADR 0053's explicit-intent web-learning gate does **not** apply to cargo's own network calls. (An attempt by the rebuild agent to do its own raw HTTP fetch outside cargo would still be governed by ADR 0053.)

## Consequences

**Positive**

- A broken rebuild cannot take down the running daemon or corrupt the operator's primary checkout.
- Path allowlist makes the rebuild skill's blast radius auditable: the only thing it can touch is the worktree.
- Operator review of large diffs has a real surface (M3 / ADR 0073) instead of being shoehorned into the tool-approval renderer.
- `rustup`-pinned toolchain (ADR 0063) plus Tier A validation (ADR 0064) gives the safe-to-merge bar concrete content.
- Refusing to activate when no source checkout is resolvable is honest: binary-drop users get a clear message rather than a silent broken state.

**Negative**

- Each worktree carries its own `target/` directory — disk cost can be 1–5 GB per active worktree. Mitigated by the `max_worktree_gb` cap and operator-driven GC.
- Cold first-build per worktree is slower than incremental builds in the main checkout. Acceptable trade for isolation.
- Operators without a source checkout cannot use `rust-rebuild` at all in v0.12. This is the right scope: those operators can still use `skill-author` and the scripting engine.

**Neutral**

- Operator-driven GC means worktrees can accumulate if the operator forgets. The disk cap bounds the worst case.
- Rebuild patches are applied by an explicit operator command (ADR 0068), not by the skill itself.

## References

- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0053](0053-background-web-learning-requires-explicit-user-intent.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)
- [ADR 0063](0063-development-environment-is-rustup-pinned-and-supported-on-macos-and-linux.md)
- [ADR 0064](0064-default-contributor-validation-is-provider-free-temp-home-based-and-network-optional.md)
- [ADR 0068](0068-rebuild-binary-swap-requires-explicit-operator-action.md)
- [ADR 0073](0073-rebuild-patch-approval-is-a-new-inbox-kind.md)
