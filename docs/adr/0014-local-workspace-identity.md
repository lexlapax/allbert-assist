# ADR 0014: Local Workspace Identity

## Status

Accepted.

## Context

Allbert began as a local single-operator assistant. The runtime and security
metadata use `operator_id` today, and
`AllbertAssist.Runtime.submit_user_input/1` already accepts `user_id` as a
fallback alias for `operator_id`. The unified post-v0.10 roadmap introduces
conversation history, per-session scratchpad state, and StockSage as the first
domain app inside the Allbert workspace. The old AI workspace labels
M-D1a/M-D1b remain historical aliases for v0.12/v0.14 only.

Those additions need stable ownership and session context before Allbert has a
hosted accounts, authentication, or role model. Introducing an
`AllbertAssist.Accounts.User` schema now would force hosted-product decisions
too early and would add unnecessary complexity to the local-first path.

Conversation history also has different storage needs from markdown long-term
memory. Markdown memory remains the inspectable, operator-edited source of
truth for durable memories, preferences, and traces. Conversation turns need
ordering, pagination, thread lookup, and app/thread context, which fit SQLite
better than markdown files.

## Decision

Allbert will use string `user_id` as the canonical local workspace identity.

`operator_id` remains an accepted legacy alias for compatibility with the
existing runtime, traces, security context, tests, CLI, and LiveView surfaces.
When both fields are absent, local runtime requests default to `"local"` under
canonical `user_id`. Future code should prefer `user_id` in new public
contracts while preserving `operator_id` compatibility until a later migration
explicitly removes it.

Runtime request and decision contexts may carry these optional fields:

- `user_id`: local string identity such as `"local"` or `"alice"`.
- `thread_id`: SQLite conversation thread id, nil when no thread is selected.
- `session_id`: volatile session key used for scratchpad lookup.
- `active_app`: atom identifying the current workspace app, such as
  `:stocksage`, nil in the general Allbert context.

v0.12, formerly M-D1a, will add SQLite conversation history through `Thread`
and `Message` records. Those records carry string `user_id`, optional app
context where needed, and no foreign key to an accounts table.

v0.14, formerly M-D1b, will add an ETS-backed session scratchpad keyed by the
tuple `{user_id, session_id}`. Scratchpad entries are volatile, TTL-expiring,
and not persisted across restarts. They may store active app context and
transient working memory, but they are not durable memory and are not an
authorization boundary.

Hosted accounts, authentication, roles, organization/team ownership, and
foreign-key user records are deferred to a later production or hosted
deployment milestone.

## Consequences

- v0.12 can add thread history without breaking v0.11 intent decisions because
  `user_id`, `thread_id`, `session_id`, and `active_app` are reserved fields.
- Jobs, channels, traces, audits, confirmations, and security metadata can
  preserve ownership context with strings before hosted accounts exist.
- External channel identities must map explicitly to local string `user_id`
  values through Settings Central rather than claiming local identities
  implicitly.
- Conversation history and markdown memory remain distinct. v0.18 review work
  may promote selected lessons from threads into markdown memory, but it must
  not automatically convert all turns into durable memory entries.
- Tests and CI still use temporary Allbert homes and must not write local
  identity data to a real user's `~/.allbert`.

## Deferred

- `AllbertAssist.Accounts.User` and hosted authentication.
- Role-based authorization and team/organization ownership.
- Cross-device identity sync.
- Automatic memory promotion from conversation history.
- Treating ETS, BEAM processes, or local sessions as a security isolation
  boundary.
