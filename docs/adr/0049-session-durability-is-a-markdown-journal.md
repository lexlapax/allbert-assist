# ADR 0049: Daemon-hosted sessions persist as markdown journals

Date: 2026-04-20
Status: Accepted

## Context

Through v0.5, REPL session state is held only in live daemon memory. Reattaching from a new client reuses existing in-memory state while the daemon runs, but a daemon restart clears everything. For a personal assistant whose value proposition is "remembers you," this is fragile: any OS upgrade, power event, or operator-triggered restart silently discards conversational context.

ADR 0003 already commits to markdown as ground truth for durable memory; ADR 0045 extends the principle to "derived artifacts rebuildable from markdown." v0.6 extends the same principle to session state.

Explicit tension with ADR 0003: session journals are not a reinstatement of chat history as durable memory. They are **working state** — the context a live session is operating on — and they remain subject to the staging/promotion pipeline for anything that should survive as durable memory. Journals replay a session, not teach the assistant.

## Decision

v0.6 persists each active session as an append-only markdown journal:

```
~/.allbert/sessions/<session-id>/turns.md
~/.allbert/sessions/<session-id>/meta.json
```

`turns.md` records turns with role (user/assistant/tool), UTC timestamp, cost delta, and content. Tool outputs are truncated to `memory.max_journal_tool_output_bytes` (default 4 KiB) in the journal; full outputs remain in the trace log.

`meta.json` holds:

- active agent name and stack
- ephemeral (tier 1) working memory for the session
- intent classification history
- channel attribution (kind + sender identifier)
- session start time and last-activity time

### Restart behaviour

On daemon start:

- Enumerate `sessions/` and list sessions younger than `daemon.session_max_age_days` (default 30) as resumable.
- `allbert-cli daemon resume [--session <id>]` reattaches a client to a rehydrated session. Without `--session`, the most-recently-active session is chosen.
- Sessions older than the retention window move to `sessions/.archive/`.
- Sessions interrupted mid-tool resume to the **last completed turn boundary**; incomplete tool invocations are discarded with an audit log entry, not replayed.

### Privacy

- Session journals live under the same file-mode as `~/.allbert/config` and the IPC socket (ADR 0023).
- `allbert-cli daemon resume --list` exposes session ids and last-activity times only, not content.
- Forgetting a session via `allbert-cli daemon forget <session-id>` moves the directory to `sessions/.trash/` with the same retention policy as forgotten memory (ADR 0047's forgetting flow).

## Consequences

**Positive**

- Conversations survive daemon restart, closing the most fragile gap in the v0.5 personal-assistant promise.
- Sessions are auditable from markdown using standard tools (`cat`, `less`, `grep`).
- Channel-originated sessions (v0.7) inherit durability without channel-specific code.

**Negative**

- Every turn incurs small filesystem writes (append to `turns.md`, rewrite of `meta.json`).
- Tool-output truncation can obscure replay fidelity; the trace log is the tie-break.
- Long-running sessions grow until archive retention kicks in.

**Neutral**

- Chose markdown over SQLite for consistency with curated memory (ADR 0045), at the cost of no structured queries over session history. That is an acceptable trade: structured session search is not a shipped requirement, and when it becomes one the tantivy index can extend to cover journals without changing ground truth.
- Channel-attribution metadata in `meta.json` is forward-compatible with v0.7 non-REPL channels.
- Session journals are explicitly working state, not durable memory. Nothing in them becomes learned knowledge without going through staging (ADR 0042).

## References

- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md) — session journals are working state, not a bypass of staging/promotion.
- [ADR 0018](0018-kernel-must-be-capable-of-running-as-a-long-lived-daemon-host.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
- [ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0047](0047-staged-memory-entries-have-a-fixed-schema-and-limits.md)
