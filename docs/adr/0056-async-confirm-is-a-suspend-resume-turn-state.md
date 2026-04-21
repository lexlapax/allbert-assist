# ADR 0056: Async-confirm is a suspend/resume turn state

Date: 2026-04-20
Status: Proposed

> **Amended in part by [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md) in v0.8**: the one-pending-approval-per-session and sender-only-resolution rules are lifted once the identity-scoped approval inbox lands. Everything else in this ADR (file layout, timeout semantics, restart recovery, REPL inline path) remains in force.

## Context

[ADR 0007](0007-session-scoped-exact-match-confirm-trust.md) established confirm-trust: actions that match a `security.confirm_match` pattern prompt the user once, then are remembered for the session. v0.2's `ConfirmPrompter` assumes a synchronous channel: the prompter blocks until the user answers, then returns `confirmed | rejected`.

That assumption does not carry to async channels. On Telegram, the bot sends a prompt, and the user may reply in seconds, minutes, or hours. The daemon may restart in between. Collapsing async confirm into "fail closed if the prompt cannot block" would make policy-gated tools unusable through chat — which defeats the point of shipping channels at all. The opposite extreme (a synchronous-style blocking worker pinned per pending approval) does not scale and does not survive daemon restart.

v0.6's session durability (ADR 0049) gives us a durable markdown surface. v0.7 can build the missing piece on top of it: a turn state that suspends cleanly, persists to markdown, and resumes cleanly — including across daemon restart.

## Decision

Async confirm is a first-class turn state: **suspended-for-approval**. When a policy gate requires confirmation and the active channel declares `supports_async_confirm: true` and not `supports_inline_confirm` (per ADR 0055's capability flags):

### 1. Persist the pending approval as markdown

```
~/.allbert/sessions/<session-id>/approvals/<approval-id>.md
```

Frontmatter + body, following ADR 0049's journal aesthetic so an operator can read the directory without tooling:

```markdown
---
id: <approval-id>                # ULID-ish, stable across restarts
session_id: <session-id>
channel: telegram
sender: <channel-local-id>       # only this sender may resolve
agent: <agent-name>
tool: <tool-name>
request_id: <uuid>               # correlates with trace
requested_at: 2026-04-20T18:02:11Z
expires_at: 2026-04-20T19:02:11Z
status: pending                  # pending | accepted | rejected | timeout
---

## Tool invocation

<plain-English rendering of the gated action, same surface the operator
sees on the originating channel>
```

Once resolved, the file is rewritten in place with the final `status` and a resolution block (resolver, timestamp, verbatim reply). Resolved approvals are retained alongside the session journal for audit.

### 2. Surface one pending approval per session

`meta.json` (per ADR 0049) gains a `pending_approval: <approval-id>` field. When a second policy gate fires while an approval is pending, the tool call refuses with `prior-approval-pending`. The agent can report this and resume after resolution.

A multi-approval inbox that lifts this restriction is scoped to [v0.8](../plans/v0.8-continuity-and-sync.md); v0.7 explicitly ships the one-at-a-time posture.

### 3. Approver identity is the original sender

Only the channel-local identifier that triggered the turn may resolve the approval. Other allowlisted senders replying to the same approval are ignored with an audit entry. This matches the "approval is a confirmation of intent from the person who asked" reading of ADR 0007 rather than a general moderation surface.

REPL and CLI may inspect pending approvals in v0.7, but they do not resolve channel-originated approvals. Cross-surface resolution belongs to the v0.8 approval inbox once identity mapping and continuity rules exist to make that safe and legible.

### 4. Bounded timeout

`channels.approval_timeout_s` (default `3600` = 1 hour). On expiry the kernel auto-rejects the pending tool, writes `status: timeout` into the markdown file, logs an audit entry, and returns a `confirm-timeout` error to the agent loop. The agent chooses whether to re-prompt, narrow scope, or inform the user.

### 5. Daemon-restart recovery

Because the approval is durable markdown, a daemon restart does not drop it. On `daemon start`, pending approvals are re-enumerated and their sessions resume in suspended-for-approval state. Incoming channel replies reconcile against the file; an approval for an expired or missing id is dropped with an audit entry.

### 6. REPL remains inline

REPL and CLI channels declare `supports_inline_confirm: true` and continue using the v0.2 blocking prompt path. This ADR does not change their behaviour.

## Consequences

**Positive**

- Synchronous and asynchronous confirm converge on the same policy outcome vocabulary (`accepted | rejected | timeout`), so hooks, audit trails, and tests treat them uniformly.
- Approvals outlive daemon restart, consistent with v0.6's durability principle.
- The one-at-a-time rule keeps the v0.7 state machine small, and the markdown file layout is already what the v0.8 approval inbox wants to read.
- Audit by `ls`: operators can see outstanding approvals with nothing more than the filesystem.

**Negative**

- Turn state now has a paused branch the kernel agent loop must handle cleanly. Incremental complexity on the hot path.
- The one-at-a-time rule creates a minor UX wart when a user triggers two gated actions in quick succession. v0.8's approval inbox removes it.
- Channel adapters carry approval-vocabulary responsibility (`/approve`, `/reject`, reaction emoji, etc.), not the kernel. Two channels will naturally use slightly different idioms — reasonable, but surface expectations must be documented per channel.
- Approval-state files accumulate per session. ADR 0049's retention window (default 30 days) applies; beyond that, resolved approvals move to `.archive/` with the parent session.

**Neutral**

- REPL and CLI continue using the inline path — no functional change for them.
- Approvers must be channel-local (Telegram chat id, etc.); cross-channel approval resolution is v0.8 concern.
- `confirm-timeout` as an agent-visible error means bootstrap prompts (`AGENTS.md`, `TOOLS.md`) need a line on expected agent behaviour when an approval times out. Documented alongside the ADR 0054 `budget-exhausted` guidance.

## References

- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0025](0025-v0-2-daemon-shutdown-is-bounded-graceful-and-job-failures-are-surfaced.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0054](0054-sub-agent-depth-is-budget-governed-not-nesting-bounded.md)
- [ADR 0055](0055-channel-trait-with-capability-flags.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [docs/plans/v0.8-continuity-and-sync.md](../plans/v0.8-continuity-and-sync.md) — approval inbox extends this to multi-approval UX.
