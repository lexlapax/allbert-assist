# ADR 0070: TUI Operator Console And Read-Only Operator Actions

Status: Proposed (v0.55.1).
Date: 2026-06-21
Related: ADR 0067 (TUI/terminal channel — this console runs on that channel),
ADR 0016 (channel adapter boundary — channels do not own conversation history /
confirmation storage / settings), ADR 0060 (two-stage intent router — operator
inspection actions are excluded from the router candidate set), ADR 0027 (action
DSL/capability registry — the exposure mechanism for these reads), ADR 0006
(Security Central — inspection grants no authority).

## Context

The v0.55 TUI is a real channel (ADR 0067), not a dressed-up `mix allbert.ask`.
v0.55.1 makes it the persistent, mix-free **operator/validation console**: the
surface an operator keeps open to inspect and validate a running Allbert without
dropping out to `mix` tasks. It adds in-TUI slash-commands (`/status`,
`/confirmations`, `/events`, `/channels`, `/settings get`, `/help`) and a
`mix allbert.channels status` report.

Every one of those affordances is a **read**: channel_events rows, the
confirmation store, settings, and channel status. They are inspection, not
confirmation actions — the operator looks at state, it does not change it.

That read crosses a boundary the channel must not own directly. ADR 0016 says
channels do **not** own conversation history, confirmation storage, or settings;
those live behind context-owned read facades that the existing `mix allbert.*`
tasks already use. A naive in-TUI direct repo read (the channel reaching into
`channel_events` or the confirmation store itself) would cross the ADR 0016
channel boundary and create a second, parallel read path next to the `mix` tasks.

## Decision

Operator inspection reads are exposed as **registered READ-ONLY operator
actions** resolved through `Actions.Runner.run/3` — the one authority boundary —
and backed by the **same context read facades** the existing `mix allbert.*`
tasks use. There is a single source of truth for each read; the TUI does not
reimplement `channel_events`, confirmation, settings, or channel-status reads in
a parallel path.

### Operator-only, never intent candidates

These actions are exposed **operator-only and are NOT intent candidates**. The
two-stage intent router (ADR 0060) must never select them: they are excluded from
the router candidate set (Stage-1 prefilter and Stage-2 disambiguation), so the
model cannot route a user utterance to operator inspection. Routing decides which
*user-facing* action runs; operator inspection is reachable only through the
explicit slash-command surface.

### No mutation, no authority, redacted output

The inspection actions perform **no mutation**, grant **no authority**, and emit
**redacted/truncated** output — no secrets, no raw payloads. They read state and
render an operator-readable summary; they never create a confirmation, set a
`confirmation_id`, change a setting, or lower a safety floor (ADR 0006).

### One exposure, two entry points

The TUI slash-command router maps each `/cmd` to its registered read-only action;
`mix allbert.channels status` calls the **same facade** behind the `/channels`
action. The slash surface and the `mix` report converge on one implementation
rather than diverging into two command surfaces.

## Consequences

- The operator console adds operator convenience — inspect status,
  confirmations, events, channels, and settings without leaving the TUI — without
  a second command surface and without a channel-boundary leak: every read goes
  through `Actions.Runner.run/3` and the existing context read facades.
- The `tui-no-authority` invariant (ADR 0067) extends to a **`tui-slash-readonly`**
  guarantee: in-TUI slash-commands are read-only operator actions that mutate
  nothing and grant nothing.
- Future operator-only read actions follow this **exposure pattern** —
  registered through the action registry (ADR 0027), routed through
  `Actions.Runner.run/3`, excluded from the intent router candidate set (ADR
  0060), backed by the existing context read facade rather than a new parallel
  read path.
- No change to confirmation semantics, settings ownership, or the channel
  boundary (ADR 0016): inspection reads observe that state, they do not own or
  alter it.
