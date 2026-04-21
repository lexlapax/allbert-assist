# ADR 0059: Sessions routed by identity with cross-channel resume

Date: 2026-04-20
Status: Accepted

## Context

v0.6 session durability (ADR 0049) made sessions persistent across daemon restart. v0.7 Telegram (ADR 0057) resumes sessions per channel-sender: an inbound Telegram message from an allowlisted sender reattaches to that sender's most-recently-active session. Same rule for REPL reattachment.

The v0.7 model silos sessions per channel. If the operator speaks on REPL, then picks up the phone and speaks on Telegram, those are two independent sessions with independent journals and independent memory context. The "remembers you" promise degrades the moment continuity crosses a channel boundary.

v0.8's continuity goal requires a single routing step ahead of channel-scoped session lookup: who is this person, and what session did they last speak to, **regardless of channel**?

ADR 0058 lands the identity record that answers "who." This ADR decides how sessions route once identity is known, and what happens when the same identity speaks through two channels concurrently.

## Decision

Sessions are routed by identity, not by channel-sender.

### Routing rule

On inbound message from an allowlisted sender:

1. Resolve sender to an identity via ADR 0058's `user.md`. If no identity matches, fall through to v0.7 per-channel-sender routing (graceful degradation during overlay period).
2. Query the kernel's session map for the identity's most-recently-active session across all channels.
3. If that session exists and is younger than `daemon.session_max_age_days` (ADR 0049), attach the inbound turn to it.
4. Otherwise, create a new session tagged with the identity.

This turns the v0.7 per-sender routing into a v0.8 per-identity routing while keeping the v0.7 behaviour as a fallback for senders that have not been mapped to an identity yet.

### Configuration

- `sessions.cross_channel_routing = inherit | scoped` (default `inherit`).
  - `inherit`: the identity-based rule above. v0.8 default.
  - `scoped`: preserves v0.7 per-channel-sender routing even when an identity is known. Operator opt-out for users who prefer per-channel continuity.

### Journal structure

One journal per session. Channel attribution moves *into* the journal (per-turn), not *above* it (per-session):

- `turns.md` entries gain a `channel:` field in their header.
- `meta.json` gains `identity_id: usr_<ulid>`.
- Old journals (pre-v0.8) without `identity_id` load under a sentinel identity; first subsequent mutation writes the correct value.

No per-channel sub-journals. A single logical conversation produces a single append-only journal the operator can read front-to-back regardless of which channel contributed each turn.

### Concurrent inbound rule: last-speaker-wins

When the same identity speaks on two channels:

- **In-flight turns complete at their originating channel.** If a REPL turn is mid-stream when Telegram inbound arrives, REPL's stream finishes and the Telegram message queues until the REPL turn closes.
- **New inbound triggers reattachment.** On turn boundary, the next inbound (whichever channel it is on) becomes the "active attach." Subsequent streamed responses go to the most-recent attacher.
- **Read-only journal access** remains for both channels: either channel can render the journal on demand (for resumption UX), even when it is not the active attacher.

In practice: the operator uses whatever channel is convenient at the moment, and Allbert follows. No explicit handoff command needed.

### Exclusive-attach guard

Only one channel may be the active attacher at a time. If two inbound messages race on the exact same turn boundary, the kernel picks one deterministically (timestamp, then channel priority) and the other queues behind it. The queued message becomes its own turn on the same session.

### Job-originated sessions

Jobs have no identity and no inbound channel. Job-run sessions remain one-session-per-run and do not participate in cross-channel resume. A job can reference durable memory (which is continuity-bearing per ADR 0061), but its session journal is ephemeral to that run.

## Consequences

**Positive**

- The operator has one logical conversation across all their channels. Matches the "remembers you across surfaces" promise that v0.7 channels alone cannot deliver.
- Journal remains a single markdown file per session — readable, exportable, greppable.
- `scoped` config key gives operators an escape hatch for deployments that prefer per-channel silos.

**Negative**

- Concurrent-inbound race handling adds edge cases to the session state machine.
- Cross-channel journaling leaks channel-specific formatting artifacts into a shared file (e.g. MarkdownV2 escapes from Telegram). The journal writer sanitises on append.
- Operators who assume Telegram is a private channel may be surprised that a REPL session picks up. Document this clearly; the `scoped` mode is the answer when desired.

**Neutral**

- Supersedes ADR 0057's per-sender session model for identity-mapped senders. ADR 0057's fallback path still applies for senders not yet in `user.md`.
- `identity_id` on session meta.json is continuity-bearing per ADR 0061 and is part of profile export/import.
- Sub-agent budget (ADR 0054) is per-turn, not per-session. Cross-channel resume does not carry budget state across turns — each new turn has its own budget.

## References

- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0054](0054-sub-agent-depth-is-budget-governed-not-nesting-bounded.md)
- [ADR 0055](0055-channel-trait-with-capability-flags.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [docs/plans/v0.8-continuity-and-sync.md](../plans/v0.8-continuity-and-sync.md)
