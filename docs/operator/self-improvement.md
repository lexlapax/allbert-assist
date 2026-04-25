# Self-improvement operator guide

v0.12 adds review-first self-improvement. Allbert can prepare source patches in an isolated sibling worktree and route them through the approval inbox, but it never applies or swaps its own binary without an explicit operator command.

## Source Checkout

The `rust-rebuild` path requires a local Allbert source checkout with the pinned Rust toolchain file present:

```bash
cargo run -p allbert-cli -- self-improvement config show
cargo run -p allbert-cli -- self-improvement config set --source-checkout /path/to/allbert-assist
```

Allbert resolves the checkout in this order:

- `self_improvement.source_checkout` in `~/.allbert/config.toml`
- `ALLBERT_SOURCE_CHECKOUT`
- an upward walk from the running executable looking for this workspace

If no checkout is resolved, ordinary Allbert usage still works. The `rust-rebuild` skill simply refuses activation with a setup hint. Binary-drop users still get `skill-author` and the Lua scripting seam.

## Worktrees And GC

Rebuild work happens under the configured worktree root:

```toml
[self_improvement]
source_checkout = ""
worktree_root = "~/.allbert/worktrees"
max_worktree_gb = 10
install_mode = "apply-to-current-branch"
keep_rejected_worktree = false
```

Each rebuild gets its own sibling worktree and isolated `target/`. The kernel write guard only allows self-improvement writes inside that active worktree. It denies writes to the operator profile, the live source checkout, and the `skills/rust-rebuild/` source directory.

Inspect or reclaim stale worktrees:

```bash
cargo run -p allbert-cli -- self-improvement gc --dry-run
cargo run -p allbert-cli -- self-improvement gc
```

The daemon does not run GC automatically.

## Patch Approval Flow

`rust-rebuild` produces a patch artifact and a `patch-approval` inbox item. The full diff lives under the session artifacts directory and is referenced by the approval markdown; the approval context may include a bounded preview so TUI, REPL, CLI, and Telegram can show what is being reviewed without inlining unbounded diffs.

Inspect pending approvals:

```bash
cargo run -p allbert-cli -- inbox list
cargo run -p allbert-cli -- inbox show <approval-id>
```

The TUI and classic REPL expose the same review path:

```text
/inbox list
/inbox show <approval-id>
/self-improvement diff <approval-id>
/self-improvement install <approval-id>
```

Accepting a patch approval records review only:

```bash
cargo run -p allbert-cli -- inbox accept <approval-id> --reason "looks good"
```

It does not apply the patch and does not swap the running binary. Rejecting a patch records rejection and deletes the worktree by default:

```bash
cargo run -p allbert-cli -- inbox reject <approval-id> --reason "not wanted"
```

Set `self_improvement.keep_rejected_worktree = true` if you want rejected worktrees preserved for forensic review.

## Diff And Install

Print the full unified diff:

```bash
cargo run -p allbert-cli -- self-improvement diff <approval-id>
```

Apply an accepted patch to the source checkout:

```bash
cargo run -p allbert-cli -- self-improvement install <approval-id>
```

`needs-review` patches are refused unless you opt in:

```bash
cargo run -p allbert-cli -- self-improvement install <approval-id> --allow-needs-review
```

Install mode is `apply-to-current-branch`. After applying the patch, the CLI prints the operator-owned next steps:

```bash
cargo install --path crates/allbert-cli
allbert-cli daemon restart
```

The append-only install history lives at:

```text
~/.allbert/self-improvement/history.md
```

It records the approval id, applied SHA, operator identity, and timestamp. It does not claim the rebuilt binary was installed or restarted.

## Trust Boundary

- All patch authoring happens in an isolated worktree.
- Tier A validation is provider-free and runs before the patch is proposed.
- Inbox acceptance is review, not install.
- Install applies a patch, not a binary swap.
- The operator owns `cargo install` and daemon restart.
- v0.12.1 adds clearer approval context and next-step feedback, but does not weaken the review/install split.

## Related Docs

- [Skill authoring guide](skill-authoring.md)
- [Scripting guide](scripting.md)
- [v0.12.1 upgrade notes](../notes/v0.12.1-upgrade-2026-04-25.md)
