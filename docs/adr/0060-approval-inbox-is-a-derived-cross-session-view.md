# ADR 0060: Approval inbox is a derived cross-session view

Date: 2026-04-20
Status: Accepted

## Context

v0.7 (ADR 0056) shipped the async-confirm state machine with two deliberate constraints to keep the v0.7 surface small:

- **One pending approval per session at a time.** A second policy gate refused with `prior-approval-pending`.
- **Sender-only resolution.** Only the channel-local identifier that triggered the turn could resolve the approval.

The v0.7 ADR explicitly flagged both as v0.8 inbox concerns. v0.8's continuity goal requires a surface where the operator can see "what is waiting for me" across channels and sessions, and resolve any of it from whatever surface is convenient.

Those constraints are now the v0.8 blocker. The approval-markdown file layout from ADR 0056 is already inbox-compatible — it just needs a cross-session view and the two constraints lifted.

## Decision

The approval inbox is a derived view over session approvals, scoped by identity (ADR 0058).

### Ground truth remains per-session

Approvals continue to persist at:

```
~/.allbert/sessions/<sid>/approvals/<aid>.md
```

Format is exactly ADR 0056's. No new ground-truth path is introduced. The inbox is a read-side aggregation, consistent with ADR 0045's "derived artifacts rebuildable from markdown" principle.

### Derived view

The daemon maintains an in-memory index keyed by identity:

- Enumerated on `daemon start` by walking `sessions/*/approvals/*.md`.
- Maintained on approval create/resolve/expire during runtime.
- Filtered by identity on query (via ADR 0058's identity record and ADR 0059's session `identity_id`).
- Retention: pending and resolved approvals within the last `channels.approval_inbox_retention_days` days (default `30`, mirroring session retention). Older approvals remain on disk with the archived session; they fall out of the inbox view.

The inbox never owns data. Rebuilding it from the filesystem is always valid.

### Amendments to ADR 0056

v0.8 lifts both v0.7 constraints:

1. **Multiple pending approvals per session are allowed.** The `pending_approval` field in `meta.json` becomes a list. The `prior-approval-pending` error is retired. Agents that triggered multiple gates see multiple approval ids queued in the same session.
2. **Resolution is identity-scoped, not sender-scoped.** Any surface belonging to the approval's identity (per ADR 0058) can resolve. Approver identity is recorded on resolution for audit (channel + sender) but does not have to match the triggering sender.

ADR 0056 gains a banner noting it is amended in part by this ADR.

### Inbox scope

The inbox surfaces three kinds of pending operator actions in a uniform shape:

- **Tool-use approvals** from ADR 0056 (channel-originated).
- **Cost-cap overrides** awaiting operator action. When a turn refuses under `limits.daily_usd_cap` (ADR 0051) on an async channel, the kernel writes an approval-markdown file of kind `cost-cap-override` instead of failing silently. Operator resolves with the same accept/reject vocabulary.
- **Job-origin fail-closed approvals.** Scheduled jobs (ADR 0015) still fail closed on interactive actions, but in v0.8 a job that hits a gate emits an approval-markdown file of kind `job-approval` rather than only logging `cap-reached` / `fail-closed`. The operator can inspect and approve, after which the job surfaces a retriable outcome.

All three share the same file layout (ADR 0056 frontmatter, with an additional `kind:` field distinguishing them). Consumers filter by `kind` when the distinction matters.

### CLI

Extends v0.7's `approvals` command without deprecating it:

```
allbert-cli inbox list  [--identity <id>] [--kind <kind>] [--include-resolved] [--json]
allbert-cli inbox show  <approval-id>
allbert-cli inbox accept <approval-id> [--reason <text>]
allbert-cli inbox reject <approval-id> [--reason <text>]
```

`allbert-cli approvals list | show` from v0.7 continues to work for per-session scope; `inbox` is the cross-session view.

Output is human-readable by default; `--json` emits a stable schema for future operator UIs.

### Channel-side resolution

Channel adapters (Telegram, future) use their channel-native vocabulary to resolve (`/approve <aid>` on Telegram per ADR 0057). Whether a resolution from one channel reaches an approval that originated on another is a function of identity match — not of channel match.

## Consequences

**Positive**

- "What is waiting for me?" is one command, or one glance at a shared file layout.
- The v0.7 one-at-a-time and sender-only constraints are removed without rewriting ADR 0056's file format.
- Cost-cap overrides and job approvals land in the same operator surface as tool approvals — no per-kind mental model.
- Stays aligned with ADR 0045: derived view, ground truth in markdown.

**Negative**

- In-memory inbox can drift from on-disk state if the daemon mishandles a crash between writing the approval file and updating the inbox. Mitigation: inbox is rebuilt on daemon start from the filesystem; runtime drift is bounded by the time between crash and restart.
- Removing `prior-approval-pending` means agents may trigger several gates in a row before any is resolved. Bootstrap prompts (`AGENTS.md`, `TOOLS.md`) should advise agents to avoid this pattern; it is not kernel-enforced.
- Channel adapters must handle approval replies referencing ids that may have been created by a different channel. Channel code already looks up by id; the behavioural change is mostly invisible there.

**Neutral**

- ADR 0056 remains the file-format-of-record for approvals. This ADR layers cross-session view and amends constraints.
- Scheduled-job approvals are a new kind; ADR 0015's "fail closed on interactive actions" becomes "fail closed or emit an approval, operator choice" — but the latter is still resolved through the same confirm-trust vocabulary, so the policy envelope is unchanged.
- Continuity-bearing per ADR 0061: approval markdown files travel with their parent session during profile export/import.

## References

- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0056](0056-async-confirm-is-a-suspend-resume-turn-state.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0059](0059-sessions-routed-by-identity-with-cross-channel-resume.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [docs/plans/v0.8-continuity-and-sync.md](../plans/v0.8-continuity-and-sync.md)
