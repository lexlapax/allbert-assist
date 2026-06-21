# ADR 0070: TUI Operator Console And Read-Only Operator Actions

Status: Proposed (v0.55.1).
Date: 2026-06-21
Related: ADR 0067 (TUI/terminal channel — this console runs on that channel),
ADR 0016 (channel adapter boundary — channels do not own conversation history /
confirmation storage / settings), ADR 0060 (two-stage intent router — operator
inspection actions are excluded from the router candidate set), ADR 0027 (action
DSL/capability registry — these reads use the existing `:internal` exposure plus
a TUI slash-command allowlist), ADR 0006
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
those live behind context-owned reads. Existing `mix allbert.*` tasks already use
registered actions for action-backed reads, but v0.55.1 still needs a named
read-report interface for the new operator status/event views. A naive in-TUI
direct repo read (the channel reaching into `channel_events` or the confirmation
store itself) would cross the ADR 0016 channel boundary and create a second,
parallel read path next to the `mix` tasks.

## Decision

Operator inspection reads are exposed as **registered READ-ONLY internal
actions** resolved through `Actions.Runner.run/3` — the one action boundary — and
reachable from the TUI only through an explicit slash-command allowlist. They are
backed by a named read-report interface (`AllbertAssist.Operator.Inspection`, or
narrower documented report modules if implementation chooses that naming) plus
existing confirmation/settings action reads where they already fit. There is a
single source of truth for each read; the TUI does not reimplement
`channel_events`, confirmation, settings, or channel-status reads in a parallel
path.

### Operator-only, never intent candidates

These actions are `exposure: :internal`, slash-allowlisted, and **NOT intent
candidates**. The two-stage intent router (ADR 0060) must never select them: they
are absent from `Actions.Registry.agent_modules/0`, excluded from generated or
curated intent descriptors, and unavailable to Stage-1 prefilter and Stage-2
disambiguation, so the model cannot route a user utterance to operator
inspection. Routing decides which *user-facing* action runs; operator inspection
is reachable only through the explicit slash-command surface.

### No mutation, no authority, redacted output

The inspection actions perform **no mutation**, grant **no authority**, and emit
**redacted/truncated** output — no secrets, no raw payloads. They read state and
render an operator-readable summary; they never create a confirmation, set a
`confirmation_id`, change a setting, or lower a safety floor (ADR 0006).

### One report source, two entry points

The TUI slash-command router maps each `/cmd` to its registered read-only internal
action; `mix allbert.channels status` renders the **same read-report DTO source**
behind the `/channels` action. The slash surface and the `mix` report converge on
one implementation rather than diverging into two command surfaces.

## Consequences

- The operator console adds operator convenience — inspect status,
  confirmations, events, channels, and settings without leaving the TUI — without
  a second command surface and without a channel-boundary leak: every read goes
  through `Actions.Runner.run/3` and the shared read-report interface / existing
  action reads.
- The `tui-no-authority` invariant (ADR 0067) extends to a **`tui-slash-readonly`**
  guarantee: in-TUI slash-commands are read-only internal actions that mutate
  nothing and grant nothing, and are reachable only through the explicit slash
  surface.
- Future operator-only read actions follow this **routing pattern** — registered
  through the action registry (ADR 0027) as `exposure: :internal`, routed through
  `Actions.Runner.run/3`, slash-allowlisted where needed, excluded from the intent
  router candidate set (ADR 0060), backed by the shared read-report interface
  rather than a new parallel read path. A new `:operator` action exposure is not
  introduced by this ADR.
- No change to confirmation semantics, settings ownership, or the channel
  boundary (ADR 0016): inspection reads observe that state, they do not own or
  alter it.
