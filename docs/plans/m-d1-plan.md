# Allbert D-Track M-D1: Multi-User Identity, Conversation History, And Session Scratchpad

## Purpose

M-D1 adds the local workspace identity foundation that every other D-track
milestone depends on. It splits into two sequential sub-milestones:

- **M-D1a** — string `user_id`, SQLite conversation threads and messages,
  multi-user mix task API, and runtime propagation of identity and thread
  context.
- **M-D1b** — ETS-backed session scratchpad keyed by `{user_id, session_id}`,
  TTL expiry, and `active_app` context for later app-scoped routing.

Neither sub-milestone introduces hosted accounts, authentication, roles, or
multi-device sync. `user_id` is a plain string (`"local"`, `"alice"`, etc.)
that carries ownership context before a real accounts model is needed.

## Expected Inputs

- v0.10 is complete: SQLite via `ecto_sqlite3` is already the project database;
  `AllbertAssist.Repo` exists and has migrations infrastructure.
- v0.11 has reserved `user_id`, `thread_id`, `session_id`, and `active_app`
  fields in the intent decision struct.
- `AllbertAssist.Runtime.submit_user_input/1` already accepts `user_id` as a
  fallback alias for `operator_id` (runtime.ex line 122-123). M-D1a extends
  this rather than replacing it.
- `AllbertAssist.Memory` (markdown-first) exists and is unchanged by M-D1. The
  new SQLite conversation history is a separate store, not a replacement.
- ADR 0014 (local workspace identity) is accepted.

## M-D1a: Multi-User Conversation Layer

**Goal:** `user_id` and `thread_id` flow through runtime, storage, CLI, and
LiveView. Existing single-user behavior defaults to `user_id: "local"` and is
fully preserved.

### Scope

**New Ecto schemas and migrations:**

```elixir
AllbertAssist.Memory.Thread
  fields: id (binary_id), user_id (string), title (string),
          app_id (string, nil = general), timestamps()

AllbertAssist.Memory.Message
  fields: id (binary_id), thread_id (string), user_id (string),
          role (string — "user" | "assistant" | "tool"),
          content (string), action_log (map), trace_id (string),
          inserted_at only (no updated_at)
```

**Runtime changes:**

`AllbertAssist.Runtime.submit_user_input/1` accepts and propagates three new
optional fields alongside the existing `operator_id` / `user_id`:

```
user_id:    string — defaults to operator_id value or "local"
thread_id:  string | nil — nil creates or selects a thread implicitly
session_id: string | nil — ETS scratchpad key (used in M-D1b)
```

The intent agent reads the last N messages from the selected thread as
conversation context prefix. When `thread_id` is nil and the request creates
new context, a thread is created automatically. Existing `operator_id` behavior
is preserved as a legacy alias.

**Mix tasks:**

```sh
mix allbert.ask "hello"                          # user_id defaults to "local"
mix allbert.ask --user alice "hello"             # explicit user_id
mix allbert.ask --user alice --thread abc "..."  # continue thread
mix allbert.ask --user alice --new-thread "..."  # always creates a new thread
mix allbert.threads --user alice                 # list threads for user
mix allbert.threads --user alice --thread abc    # show messages in thread
```

**LiveView:**

`AgentLive` shows a basic thread list sidebar. Navigating threads sets the
active thread for the session.

### Acceptance

- `mix allbert.ask --user alice "hello"` creates a thread and a message.
- `mix allbert.ask --user alice "what did I just say?"` reads context from
  that thread and responds correctly.
- `mix allbert.ask "hello"` (no `--user`) still works and defaults to
  `user_id: "local"`.
- Two users' threads are isolated; user alice cannot see user bob's threads.

---

## M-D1b: ETS Session Scratchpad

**Goal:** Volatile, per-session state keyed by `{user_id, session_id}` exists
in ETS, TTL-expires automatically, and carries `active_app` context for
app-scoped routing.

### Scope

**New module:**

```elixir
AllbertAssist.Session.Scratchpad
  # ETS table: :allbert_session_scratchpad, type: :set
  # Key: {user_id, session_id}
  # Value: %{active_app: atom | nil, working_memory: map, expires_at: integer}

  get(user_id, session_id) :: map | nil
  put(user_id, session_id, key, value) :: :ok
  delete(user_id, session_id) :: :ok
  # TTL sweep via :timer.send_interval/2, cleans expired entries
```

Started in `AllbertAssist.Application` supervision tree before the runtime
starts. TTL defaults to settings-configurable value (default: 30 minutes).

**Runtime:**

`submit_user_input/1` populates `active_app` from scratchpad if `session_id`
is present. `AgentLive` stores its `session_id` in the LiveView process state
and reads scratchpad for `active_app` context on each turn.

**Reserved key:** `canvas_tiles` is reserved for allbert core v0.17. M-D1b
must not define or populate it.

### Acceptance

- Two concurrent `mix allbert.ask --user alice` calls with different
  `session_id` values get isolated scratchpad entries.
- Stale entries expire after TTL; an expired entry returns nil on `get/2`.
- No scratchpad state persists across application restart.
- `active_app: nil` is the default for general Allbert context.

---

## Non-Goals

- No `AllbertAssist.Accounts.User` schema, authentication, roles, or
  organization/team ownership. These belong to a later hosted production
  milestone.
- No automatic promotion of conversation turns into markdown long-term memory.
  That is an explicit operator action (v0.14 work).
- No vector/semantic search over thread history. That is a later phase.
- No cross-device sync or cloud thread backup.
- No `canvas_tiles` key in scratchpad (reserved for v0.17).
- No hosted session tokens or JWT; `session_id` is a local process identifier
  only.
- No security isolation boundary from the ETS table itself. ETS is not a trust
  boundary; the scratchpad is volatile working state only.

## Test Plan

Focused tests should cover:

- `Thread` and `Message` Ecto schemas round-trip through the repo.
- `submit_user_input/1` stores a `Message` row when `thread_id` is present.
- `submit_user_input/1` creates a `Thread` when `thread_id` is nil.
- Intent agent reads thread messages as context prefix.
- `mix allbert.ask` CLI accepts and propagates `--user` and `--thread`.
- User alice cannot read user bob's threads (scope enforcement).
- Scratchpad `get/2` returns nil for an expired or nonexistent key.
- Scratchpad entries for `{alice, sess-1}` and `{alice, sess-2}` are isolated.
- TTL expiry removes entries without affecting non-expired entries.
- Application restart produces an empty scratchpad.
- Legacy `operator_id`-only calls still work and default to `user_id: "local"`.

Final gates (code changes):

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix precommit
```

## Definition Of Done

M-D1 is done when:

- `Thread` and `Message` SQLite tables exist with migrations.
- `AllbertAssist.Session.Scratchpad` ETS table starts in the supervision tree.
- Runtime propagates `user_id`, `thread_id`, `session_id` through request,
  intent decision, traces, and signals.
- Intent agent uses thread message history as conversation context.
- Mix tasks support `--user`, `--thread`, `--new-thread` flags; legacy
  single-user invocations are fully preserved.
- `AgentLive` shows a thread list sidebar and sets `session_id` on connect.
- Two users' data is isolated in both SQLite and ETS.
- All focused tests and final gates pass.
