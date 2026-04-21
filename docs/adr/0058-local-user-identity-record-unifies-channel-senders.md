# ADR 0058: Local user identity record unifies channel senders

Date: 2026-04-20
Status: Proposed

## Context

Through v0.7, each channel owns its own allowlist of senders. Telegram (ADR 0057) keys on Telegram chat ids; REPL/CLI (ADR 0023) keys on filesystem trust; future channels will key on whatever makes sense for their protocol. This is fine when channels operate independently.

v0.8 changes the shape: sessions should resume across channels for one operator, approvals should be resolvable from any surface that operator controls, and profile export/import must carry a stable notion of "who this profile belongs to." None of that works if each channel's allowlist is the only answer to "is this person allowed?" — because no component knows that `telegram:123456789` and `repl:local` are the same human.

Three options:

1. **Per-channel allowlists only.** Preserves v0.7 shape; scales poorly to continuity; breaks the "remembers you across surfaces" promise.
2. **Fuzzy merge** based on display name, phone, or email. Silently wrong, unsafe. A Telegram display-name collision would cross-wire accounts.
3. **Explicit operator-managed identity record** that enumerates which channel-local senders belong to the operator. Editable, inspectable, no hidden logic.

ADR 0023 keeps the daemon single-local-user. v0.8 does not change that — it adds routing metadata for one operator who happens to be reachable through multiple channels. Multi-user daemon isolation stays deferred alongside the network-addressable daemon, per the roadmap.

## Decision

Introduce a single, explicit, operator-managed identity record.

### Location and schema

`~/.allbert/identity/user.md`:

```markdown
---
id: usr_<ulid>                   # stable, minted on first boot
name: "primary"                  # operator-chosen label
created_at: 2026-04-20T18:00:00Z
channels:
  - kind: repl
    sender: "local"
  - kind: telegram
    sender: "123456789"
---

# Primary operator

<free-form notes; may reference IDENTITY.md for bootstrap persona>
```

Markdown + YAML frontmatter, consistent with ADR 0003/0045 (markdown as ground truth).

### First-boot seeding

On first daemon start after v0.8 upgrade, the kernel creates `user.md` with:

- a minted `id`,
- `name: "primary"`,
- the local REPL operator populated under `channels`,
- an empty body the operator can extend.

Channel entries are added by the operator as allowlists grow — either by editing `user.md` directly or via CLI (below).

### Relationship to the v0.7 per-channel allowlists

Overlay, do not replace. Both surfaces remain:

- `user.md` channel entries route to this identity.
- The v0.7 per-channel allowlist files still admit senders (no identity attachment → no cross-channel continuity, but the turn still runs).
- If a sender is in both, `user.md` wins — the session routes by identity per ADR 0059.

Operators can migrate incrementally; nothing about v0.7 behaviour is removed.

### Relationship to the bootstrap bundle

`user.md` is *routing metadata*, not *assistant persona*.

- `SOUL.md`, `USER.md`, `IDENTITY.md` describe who the operator is to the assistant.
- `AGENTS.md` (ADR 0039) enumerates available agents.
- `user.md` enumerates which channel senders are the operator.

`user.md` is **not** injected into the prompt each turn. It is not part of the bootstrap bundle. The kernel consults it during channel-inbound routing and during inbox scoping; it never leaves the kernel boundary except via CLI surfaces.

### CLI

- `allbert-cli identity show` — render current record.
- `allbert-cli identity add-channel <kind> <sender>` — append to `channels`.
- `allbert-cli identity remove-channel <kind> <sender>` — drop entry.
- `allbert-cli identity rename <new-name>` — update `name`.
- Every mutation rewrites `user.md` atomically (fsync+rename).

`id` is immutable once minted. Regenerating requires deleting the file, which is a profile-reset-level operation and is documented as such.

## Consequences

**Positive**

- Cross-channel routing (ADR 0059) and the approval inbox (ADR 0060) have a defensible primary key.
- Identity is inspectable as markdown — auditable by `cat user.md`, editable without tooling.
- Fuzzy merges and silent cross-wiring are avoided by construction.
- Sets up profile export/import (ADR 0061) to carry identity natively.

**Negative**

- Slight redundancy with v0.7 per-channel allowlists during overlay period. Operators have two places to edit; the CLI must keep both coherent (or document which takes precedence).
- Operators who add a channel sender to `user.md` but forget the per-channel allowlist file (or vice versa) can produce confusing routing behaviour until both agree. The CLI should warn when it detects inconsistency.

**Neutral**

- Maintains ADR 0023's single-local-user posture. Multi-user continues deferred alongside network-addressable daemon.
- Identity record does not gate prompt content. The bootstrap bundle is unchanged.
- `user.md` is continuity-bearing per ADR 0061 and ships in profile export/import.

## References

- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0055](0055-channel-trait-with-capability-flags.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [ADR 0059](0059-sessions-routed-by-identity-with-cross-channel-resume.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [docs/plans/v0.8-continuity-and-sync.md](../plans/v0.8-continuity-and-sync.md)
