# ADR 0057: Telegram pilot uses teloxide and long-polling

Date: 2026-04-20
Status: Accepted

## Context

v0.7 ships Telegram as the reference non-REPL channel implementation. Three cross-cutting decisions shape the implementation and want to be settled once, in writing, rather than revisited per milestone:

1. **Rust Telegram library.** The two serious options are `teloxide` (full framework with dialogue subsystem, command parsing, long-polling and webhook support, dptree-based message pipelines) and `frankenstein` (lower-level 1:1 Telegram Bot API client). A third option is raw `reqwest` against the Bot API HTTP surface — maximum control, maximum reinvention.
2. **Transport.** Long-polling (`getUpdates` in a loop; no public URL, no TLS, no domain) versus webhooks (Telegram pushes updates to a public HTTPS endpoint; cheaper per update, requires hosted deployment).
3. **Session model on inbound messages.** Does a message from a known sender create a new session, or resume an existing one?

Each decision has downstream implications for the `Channel` trait contract (ADR 0055), the async-confirm state machine (ADR 0056), operator trust posture, and the local-first positioning in [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md).

## Decision

### Library: teloxide

teloxide is the library for the v0.7 pilot.

- teloxide's dialogue subsystem and command-enum parser map directly onto the approval vocabulary from ADR 0056 (`/approve`, `/reject`) and onto the broader channel-command surface the v0.7 plan introduces. Frankenstein's 1:1 API mapping would force us to reinvent command dispatch.
- teloxide supports both long-polling and webhooks, so a later webhook transport does not require a library swap.
- Dependency cost is non-trivial but bounded to the `allbert-channels` crate (ADR 0055) and does not leak into kernel or daemon core crates.

Frankenstein remains a reasonable choice for a future minimal-dependency channel if Allbert ever grows a constrained-environment variant; v0.7 does not need that.

### Transport: long-polling only

Long-polling is the v0.7 transport. Webhooks are documented as a valid future option but are not shipped.

- Long-polling needs no public URL, no TLS certificate, no reverse proxy. A user can run Telegram-flavoured Allbert on a laptop over a residential connection — matching the local-first posture.
- grammY's documentation explicitly recommends long-polling for home-computer deployments; the same reasoning applies here.
- Webhooks imply hosted deployment, which Allbert does not commit to through v0.12. Adding webhooks later is a configuration option, not a trait change.

### Session model: resume on any inbound message

On a message from an allowlisted sender:

- If the most-recent active session for that sender is younger than `daemon.session_max_age_days` (ADR 0049, default 30), attach to it.
- Otherwise create a new session.
- `/start` is treated identically to any other inbound message — it does not force a reset. Users expecting Telegram `/start` conventions instead get continuity, which matches the "remembers you" promise.
- Explicit reset uses `/reset`. This ends the current session and creates a new one on the next inbound message.

Cross-channel session routing (the same user's REPL + Telegram sessions as one logical thread) is explicitly deferred to v0.8. In v0.7, the same user on REPL and Telegram has two independent sessions.

Inbound media, including Telegram photos, is stored under the session working directory and treated as a session artifact rather than durable memory. It archives, forgets, and purges with the parent session under the same session-retention rules from ADR 0049; v0.7 does not add a separate media-retention subsystem.

### Rate limiting

Telegram's published limits (see references) are 1 message per second per chat, 20 messages per minute in groups, and 30 messages per second globally per bot. The daemon enforces its own per-chat and global queues so outbound bursts never hit a 429:

- `channels.telegram.min_interval_ms_per_chat` — default `1200` (safe margin over 1 msg/sec/chat).
- `channels.telegram.min_interval_ms_global` — default `40` (~25 msg/sec, under the 30 msg/sec ceiling).
- Per-chat FIFO queue; global queue is cross-chat FIFO.
- Exceeding either bound queues the outbound message; the queue is observable in trace.

### Approval vocabulary

Per ADR 0056, Telegram async confirm uses `/approve <approval-id>` and `/reject <approval-id>`. The id is short (ULID-ish) and included in the outbound confirm message. Only the sender who triggered the turn may resolve. Reaction-emoji approval is a stretch UX; it is not required for the v0.7 pilot minimum.

### Outbound rendering

- Telegram MarkdownV2 is the primary rendering format, with safe-escape of reserved characters.
- Messages are chunked at `max_message_size` (Telegram's 4096 character limit) with visual continuation markers.
- Code blocks preserve language hints where MarkdownV2 allows.

### Secrets

- Bot token under `~/.allbert/secrets/telegram/bot_token`.
- File permissions match the IPC socket (ADR 0023).
- Bot token is loaded once at daemon startup; rotation requires daemon restart in v0.7 (a hot-reload seam is not part of this ADR).

### Minimum v0.7 capability contract

Telegram's declared capabilities in v0.7:

- `supports_inline_confirm`: false
- `supports_async_confirm`: true
- `supports_rich_output`: true
- `supports_file_attach`: true
- `supports_image_input`: true (provider-gated; see v0.7 plan)
- `supports_image_output`: false
- `supports_voice_input`: false (stretch, not guaranteed for v0.7)
- `supports_voice_output`: false
- `supports_audio_attach`: false
- `max_message_size`: 4096
- `latency_class`: Asynchronous

## Consequences

**Positive**

- Long-polling means a user can run Telegram Allbert on a laptop with no network plumbing — matches local-first.
- teloxide's command derive + dialogue handling absorbs the boilerplate we would otherwise hand-write for command parsing and approval flows.
- Session-resume on any inbound message preserves the "remembers you" promise across client restarts and across daemon restarts (because of ADR 0049).
- Telegram-specific knobs (rate limits, secrets path, approval vocabulary) are one ADR rather than folklore split across the plan and code.

**Negative**

- teloxide pulls in a non-trivial dependency graph (tokio runtime assumptions, reqwest, serde, dptree). Compile-time cost rises.
- Long-polling holds an outbound HTTPS connection continuously. On a metered connection this is user-visible; document it in onboarding.
- Per-chat rate limits delay delivery under bursty agent output. Chunking and queuing must be observable in trace so operators can tell "my bot is slow" from "my LLM is slow."
- Treating `/start` as continuity differs from Telegram convention. Document it; provide `/reset` as the explicit escape.

**Neutral**

- Future channels are free to pick a different library; ADR 0055's capability flags mean the choice does not leak beyond the adapter.
- Webhooks can be added later as a configuration-driven transport without trait or ADR changes.
- The Telegram session model (one logical session per allowlisted sender, resumed on any inbound message) is a v0.7 choice, not a universal channel mandate. Other channels may legitimately ship different session models surfaced through ADR 0055.

## References

- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0055](0055-channel-trait-with-capability-flags.md)
- [ADR 0056](0056-async-confirm-is-a-suspend-resume-turn-state.md)
- [teloxide](https://github.com/teloxide/teloxide) — Rust Telegram bot framework
- [Telegram Bots FAQ — rate limits](https://core.telegram.org/bots/faq)
- [grammY: Long Polling vs. Webhooks](https://grammy.dev/guide/deployment-types) — prior-art reasoning on transport choice
