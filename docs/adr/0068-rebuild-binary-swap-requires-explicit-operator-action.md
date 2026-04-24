# ADR 0068: Rebuild binary swap requires explicit operator action

Date: 2026-04-23
Status: Proposed

## Context

The v0.11 rebuild skill (ADR 0067) produces a diff plus a built binary inside `~/.allbert/worktrees/<branch>/target/release/`. The natural next question is: how does that binary become the running daemon?

Three options:

1. **Auto-swap.** On approval, the daemon replaces its own running binary and re-execs.
2. **Daemon-mediated upgrade.** A new `allbert-cli daemon upgrade` command stops the daemon, copies the new binary into place, and restarts.
3. **Operator-driven install.** The daemon emits a build-and-install hint; the operator runs `cargo install` (or copies the binary) themselves on their own schedule.

Option 1 is dangerous in three independent ways:

- A long-lived process replacing its own executable while in-flight tool calls are running is a class of bug Allbert has spent eight releases avoiding. Mid-turn binary swaps interact badly with session journaling (ADR 0049), exec hook contracts (ADR 0006), and the daemon lockfile lifecycle (ADR 0061).
- A successfully-built binary that passes Tier A on a fixture set may still be wrong for the operator's environment. Auto-swap removes the operator's last chance to test a candidate binary in their actual workflow before it becomes load-bearing.
- Auto-swap concentrates power in the wrong place. ADR 0038 says the user is the reviewer, not the bystander. A patch the operator approved on a Tuesday afternoon should not silently restart their daemon and install itself.

Option 2 is more controlled but still puts the daemon in the position of orchestrating its own replacement. That requires an additional careful state machine (drain in-flight turns, persist sessions, swap, re-exec, re-attach channels) for one capability — it is a lot of new code for a capability whose entire premise is "the operator is in the loop anyway."

Option 3 keeps the trust model simple: Allbert produces an artifact; the operator chooses whether and when to install it. It also matches the existing v0.10 posture for Ollama (Allbert does not install Ollama or pull models — the operator does that themselves).

## Decision

The Allbert daemon **never** automatically swaps its own running binary. Installing a built rebuild artifact is always an explicit operator action.

### Flow

After a `patch-approval` (ADR 0073) is accepted:

1. `allbert-cli self-improvement install <aid>` applies the patch to the source checkout (`git apply` against the current branch by default; configurable via `self_improvement.install_mode`).
2. The CLI emits a build-and-install hint, e.g.:
   ```
   Patch applied. To install:
       cd <source-checkout>
       cargo install --path crates/allbert-cli
       allbert-cli daemon restart
   ```
3. The operator runs those commands on their own time. They may also choose to test the patch in the worktree (`cargo run --manifest-path <worktree>/Cargo.toml -p allbert-cli`) before installing.
4. The install event is recorded in `~/.allbert/self-improvement/history.md` (append-only operator log) when the operator runs `allbert-cli self-improvement install <aid>`. The log captures the approval id, applied SHA, and the operator's identity (per ADR 0058) at apply time. It does **not** record whether the binary was subsequently installed — that is outside the daemon's visibility on purpose.

### Configuration

- `self_improvement.auto_swap_binary` does not exist as a config key. There is no flag that flips this on. A future release may add a `daemon upgrade` command (option 2 above), but it would need its own ADR — this ADR explicitly forecloses option 1.
- `self_improvement.install_mode` (default `apply-to-current-branch`) controls how the patch lands in the source checkout. Other modes (`merge-into-branch`, `cherry-pick`) may be added later; the binary-install step remains operator-driven regardless.

### What the daemon does after the patch is applied

Nothing. The daemon continues to run the binary it was started with. The next time the operator restarts the daemon (manually or via OS-level restart), the new binary takes effect — exactly as it would for any other source change.

This is the same operational model contributors already use day-to-day, and it is what `daemon status` already exposes (lockfile owner, started-at, pid — ADR 0061 M4).

## Consequences

**Positive**

- Zero risk of a daemon replacing its own executable mid-turn.
- Operator retains the last word on whether a built binary becomes load-bearing.
- No new state machine for binary swap, no new failure modes around drain/re-exec/re-attach.
- Consistent with v0.10's Ollama posture (Allbert produces; operator installs).
- Aligns with ADR 0038: user is the reviewer, not the bystander.

**Negative**

- Self-improvement is a multi-step ritual rather than a one-click flow. Operators who want a faster loop may script the post-approve install themselves; that scripting is their choice and lives in their environment.
- Cannot push a hot-fix from one Allbert instance to another via this path. Out of scope; cross-device sync is not v0.11's problem (and was explicitly deferred per ADR 0061).

**Neutral**

- A future ADR may add `daemon upgrade` as a controlled mediated swap. This ADR does not foreclose that — it only forecloses **automatic** swap.
- The `self-improvement/history.md` log is append-only and operator-readable; it is the audit trail for "what patches did Allbert build and apply, when, by whom?"

## References

- [docs/plans/v0.11-self-improvement.md](../plans/v0.11-self-improvement.md)
- [ADR 0006](0006-tool-events-and-hooks-have-stable-names.md)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [ADR 0067](0067-self-modification-uses-a-sibling-worktree-with-operator-diff-review.md)
- [ADR 0073](0073-rebuild-patch-approval-is-a-new-inbox-kind.md)
