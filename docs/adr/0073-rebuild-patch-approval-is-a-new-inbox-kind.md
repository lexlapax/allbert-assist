# ADR 0073: Rebuild patch approval is a new inbox kind

Date: 2026-04-23
Status: Proposed

Amends: [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)

## Context

v0.12's Rust rebuild skill (ADR 0067) produces diffs that the operator must review before any installation. The v0.8 approval inbox (ADR 0060) already handles three kinds of operator-pending actions — `tool-approval`, `cost-cap-override`, `job-approval` — using a uniform on-disk file layout (markdown + frontmatter, addressable by approval id, identity-scoped).

Reusing the inbox for rebuild patches is the right choice. Inventing a parallel "patch review" surface would fragment operator UX: the operator already knows how `inbox list / show / accept / reject` works. But rebuild diffs are different in shape from the existing kinds in three ways:

1. **Size.** A typical rebuild diff is hundreds to thousands of lines. The existing tool-approval renderer assumes the approval body is short — the operator scans it and decides. A diff at that scale needs a different rendering shape (summary first, file-by-file detail on demand, never inline-everything).
2. **Artifact.** The diff is too large to inline into the approval markdown without bloating session storage. The natural answer is: store the diff as a separate artifact, reference it by path from the approval markdown.
3. **Side effects of accept/reject.** Accepting a `tool-approval` resumes a suspended turn. Accepting a `patch-approval` does **not** apply the patch — that is an explicit operator command (ADR 0068). The accept verb here means "this patch is approved for installation"; the install itself is a separate step. Reject behavior also differs: it should clean up the worktree (configurable), which other inbox kinds do not need to do.

The right move is to extend ADR 0060's inbox-kind list with `patch-approval`, define the shape it requires, and document the resolution semantics that differ from the existing kinds.

## Decision

ADR 0060 is amended to add a fourth inbox kind: `patch-approval`.

### File layout

A `patch-approval` lives at the standard ADR 0056 / ADR 0060 path:

```
~/.allbert/sessions/<sid>/approvals/<aid>.md
```

Frontmatter mirrors existing approval kinds with these additional fields:

```yaml
kind: patch-approval
source_checkout: /Users/.../allbert-assist
branch: main
worktree_path: /Users/.../.allbert/worktrees/feature-x
validation:
  fmt: passed
  clippy: passed
  test: passed
  cli_help: passed
  daemon_smoke: passed
artifact_path: /Users/.../.allbert/sessions/<sid>/artifacts/<aid>/patch.diff
overall: safe-to-merge        # safe-to-merge | needs-review
```

`overall` is `safe-to-merge` only when every entry in `validation` is `passed`. Any failure marks the patch `needs-review`; accept paths refuse the `safe-to-merge` install command (ADR 0068) for `needs-review` patches and require an explicit override.

### Diff stays out of the approval markdown

The diff itself is **not** inlined into the approval markdown. Diffs at hundreds to thousands of lines would bloat the session journal and slow every inbox query. Instead the diff lives at `sessions/<sid>/artifacts/<aid>/patch.diff` and the approval references it via `artifact_path`. This is the same pattern v0.8 uses for image attachments (referenced, not inlined) and is consistent with ADR 0045's "derived/large artifacts live alongside markdown ground truth, not inside it."

### Renderer

`allbert-cli inbox show <aid>` for a `patch-approval` surfaces:

```
Patch approval <aid>
Branch:       <branch>
Worktree:     <worktree_path>
Validation:   fmt ✓  clippy ✓  test ✓  cli_help ✓  daemon_smoke ✓
Overall:      safe-to-merge

Summary:      <N> files changed, +<X> / -<Y> lines

Files:
  + crates/allbert-kernel/src/foo.rs   (+42 / -3)
  + crates/allbert-kernel/src/bar.rs   (+15 / -0)
  - crates/allbert-kernel/src/baz.rs   (+0  / -27)

To view the full diff:
  allbert-cli self-improvement diff <aid>

To install (operator action — daemon does not auto-swap):
  allbert-cli self-improvement install <aid>
```

The renderer never tries to print thousands of diff lines into the inbox view. The full diff is one command away.

### Resolution semantics (where this differs from other kinds)

Accept and reject differ from the existing kinds:

- **`inbox accept <aid>`** marks the patch approved, records approver identity + reason, and **does nothing else**. It does NOT apply the patch and does NOT swap any binary. The operator is directed to `allbert-cli self-improvement install <aid>` as the next step (per ADR 0068).
- **`inbox reject <aid>`** marks the patch rejected, records rejector identity + reason, and (by default) deletes the worktree at `worktree_path`. The deletion is configurable via `self_improvement.keep_rejected_worktree` (default `false`); when `true`, the worktree is preserved for forensic review and operators must `self-improvement gc` to reclaim disk later.

Both verbs continue to use the same vocabulary as other inbox kinds — operators don't have to learn a new command shape.

### Identity-scoped resolution

Per ADR 0060's ground rules, any surface belonging to the approval's identity (per ADR 0058) can resolve. A patch approval emitted from a REPL rebuild can be accepted from Telegram if the operator's identity covers both. Approver channel + sender are recorded on the resolution entry for audit, just as for other inbox kinds.

### Retention

Patch approvals follow the same retention as other inbox kinds: pending and resolved approvals within `channels.approval_inbox_retention_days` (default `30`, ADR 0060). Rejected worktrees that were preserved (per `keep_rejected_worktree`) remain on disk past the inbox retention window and are reclaimed only by `allbert-cli self-improvement gc`.

### What this ADR explicitly does NOT change

- The ADR 0060 inbox file layout (paths, identity scoping, retention defaults) — `patch-approval` is additive.
- The ADR 0056 cross-session resolution behavior — `patch-approval` resolves the same way other kinds do.
- The relationship between inbox accept and install — install remains a separate operator command (ADR 0068).

## Consequences

**Positive**

- Operators get rebuild review through the same surface they already use for tool, cost-cap, and job approvals — no new command vocabulary.
- Diffs live as artifacts, not inline, so inbox storage stays tractable even with frequent rebuilds.
- The renderer's "summary first, full diff on demand" shape scales cleanly to multi-thousand-line patches.
- Accept/install separation keeps the no-auto-swap posture (ADR 0068) intact: approving a patch and installing it are deliberately different verbs.

**Negative**

- A fourth inbox kind adds rendering surface in the inbox CLI. Acceptable: rendering is per-kind anyway, and the patterns from cost-cap-override and job-approval already established that inbox rendering is kind-aware.
- Operators may expect `inbox accept` to actually do the install. Documentation in `docs/operator/self-improvement.md` (M9 in the v0.12 plan) covers this; the renderer message also calls it out.

**Neutral**

- ADR 0060 gains a banner noting this amendment. The amendment chain is now: ADR 0056 → amended by ADR 0060 → amended by this ADR. ADR 0056's file-format-of-record status is unchanged; this ADR only adds a new `kind` value.
- Future inbox kinds (e.g. for a hypothetical "agent self-correction approval") can follow the same additive pattern without re-amending the inbox.

## References

- [docs/plans/v0.12-self-improvement.md](../plans/v0.12-self-improvement.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0056](0056-async-confirm-is-a-suspend-resume-turn-state.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md) — amended by this ADR (adds `patch-approval` kind).
- [ADR 0067](0067-self-modification-uses-a-sibling-worktree-with-operator-diff-review.md)
- [ADR 0068](0068-rebuild-binary-swap-requires-explicit-operator-action.md)
