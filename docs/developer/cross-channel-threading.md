# Cross-Channel Threading

Status: implemented in v0.52. ADR 0057 owns the system-wide thread construct.
This document is the implementation guide for channel adapters and runtime
surfaces.

## Model

The canonical Allbert thread id is the existing
`conversation_threads.id`. Provider thread ids are never canonical authority.
They are lookup and reply-routing metadata scoped by:

- `owner_scope` - `"local"` in v0.52; reserved so post-1.0 tenancy does not
  require replacing the canonical id model.
- `channel` - `slack`, `discord`, `telegram`, `email`, `web`, or `cli`.
- `receiver_account_ref` - the configured Allbert-side receiver/install, such
  as `slack:team:T0123` or `discord:app:123:guild:987`.
- `provider_thread_key` - deterministic bounded key derived from a redacted
  provider thread ref.

The durable tables are:

- `thread_channel_refs`: provider-thread ref to canonical thread binding.
- `conversation_message_refs`: canonical message to provider message binding,
  with `direction` and `part_id`.
- `cross_channel_identity_links`: explicit operator-created links among already
  mapped channel identities.

The facade is `AllbertAssist.Conversations.ChannelThread`.

## Adapter Responsibilities

Each channel descriptor declares `threading:`:

- `:native_threads` - Slack `thread_ts`, Discord native thread channels.
- `:reply_chain` - email reference headers, future mobile quote/reply ids.
- `:flat` - transports with no stable native thread.
- `:rich` - Allbert-owned local surfaces such as web and CLI.

Adapters normalize provider metadata with `ChannelThread.normalize_ref/2`,
record outbound refs with `ChannelThread.record_message_ref/1`, and use
`ChannelThread.echo?/1` to drop Allbert's own redelivered outbound messages.
`ChannelThread.resolve_reply_target/2` applies the descriptor's threading
capability and returns the degradation mode for the renderer.

`channel_events.thread_id`, when present, stores only a canonical Allbert
thread id. It must not store Slack `thread_ts`, Discord message ids, email
headers, Telegram topic ids, or any provider conversation id.

## Unified View And Resume

`AllbertAssist.Conversations.UnifiedHistory.show_thread/3` aggregates the
canonical thread across message refs and channel refs. The view is redacted and
ordered by Allbert ingest sequence, not provider timestamps.

`resume_thread_on_channel` is the explicit cross-channel continuation action.
It requires:

- the same `user_id` that owns the canonical thread;
- the target channel descriptor;
- a receiver account ref;
- a provider thread key or provider thread ref for external channels;
- an explicit cross-channel identity link when the target identity differs from
  the source/local identity.

CLI examples:

```sh
mix allbert.conversations show THREAD_ID --user alice
mix allbert.conversations resume THREAD_ID --channel cli --user alice
mix allbert.conversations resume THREAD_ID --channel slack --user alice --receiver slack:team:T0123 --external-user U0123 --provider-thread-key 1718040000.000100
```

## Non-Authority Rules

- Provider thread refs never grant permission.
- `owner_scope` is not a tenant permission source in v0.52.
- `receiver_account_ref` prevents collisions across installs/accounts; it does
  not authorize a user by itself.
- Cross-channel identity links are never inferred from display names, subjects,
  emails, or provider profile names.
- Echo suppression drops only known outbound provider message ids scoped to the
  receiver account and channel.

## Tests

Use the focused threading tests when changing mappings or channel reply logic:

```sh
MIX_ENV=test mix test \
  apps/allbert_assist/test/allbert_assist/conversations/channel_thread_test.exs \
  apps/allbert_assist/test/allbert_assist/conversations/unified_history_test.exs \
  apps/allbert_assist/test/mix/tasks/allbert_conversations_test.exs \
  apps/allbert_assist/test/security/v052_channel_pack_eval_test.exs
```

The release handoff gate is:

```sh
mix allbert.test release.v052
```
