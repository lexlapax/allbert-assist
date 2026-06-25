# ADR 0070: TUI Operator Console And Read-Only Operator Actions

Status: Accepted (v0.55.1).
Proposed amendment (v0.58, 2026-06-24): the "operator operations are registered
read-only actions; surfaces are thin views" discipline is extended to the **web**.
The web workspace stops reading `Confirmations`/`Settings.Store` directly and
routes operator reads (confirmations, settings, channels, intents, models, status)
through the same `:internal`/`:read_only` action layer the TUI and Mix already use
(ADR 0073). The v0.58 Intents, Settings/Models, and Surface-Policy panels are thin
views over these registered actions; they remain non-routable and grant no
authority. No new `:operator` exposure is introduced.
Second-pass v0.58 audit amendment (2026-06-25): the existing
`list_provider_profiles` and `list_model_profiles` actions may remain
`exposure: :agent` only as assistant-safe summary reads after their source DTOs
drop endpoint URLs and secret refs. Any raw/operator profile report that needs
fields beyond the redacted DTO must use a separate `:internal` read or an
explicit operator affordance; an `:agent` action is never the backing for raw
secret-bearing profile inspection.
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
inspection. The same exclusion extends to every other model-reachable surface —
tool-discovery suggestions and the capability-inventory candidate set — so there
is no back door by which a conversation turn reaches an inspection read. Routing
decides which *user-facing* action runs; operator inspection is reachable only
through the explicit slash-command surface.

### No mutation, no authority, redacted output

The inspection actions perform **no mutation**, grant **no authority**, and emit
**redacted/truncated** output — no secrets, no raw payloads. They read state and
render an operator-readable summary; they never create a confirmation, set a
`confirmation_id`, change a setting, or lower a safety floor (ADR 0006).

### One report source, two entry points

The TUI slash-command router maps each data `/cmd` to its registered read-only
internal action; `mix allbert.channels status` renders the **same read-report DTO
source** behind the `/channels` action. Concretely, `/channels` and
`mix allbert.channels status` reuse the existing `list_channels` read action plus a
supervisor-status read; the TUI does not reimplement channel-status,
`channel_events`, confirmation, or settings reads in a parallel path. The slash
surface and the `mix` report converge on one implementation rather than diverging
into two command surfaces.

Two clarifications on "reuse": (1) the slash backings are `exposure: :internal`
reads. Sharing a *context facade / report DTO* with an existing `exposure: :agent`
read (e.g. `read_setting`) is fine, but the `:agent` action is **not** itself the
slash backing — wiring a slash to an `:agent` action would leave it model-routable
and would not provide the operator-specific DTO/redaction boundary for sensitive
settings layers. (2)
`/help` and any unknown slash are handled **router-local** — no action, no Runner —
so not every `/cmd` is an action invocation.

v0.58 M13.1 adds one bounded carve-out to that rule: profile inventory reads can
share an `:agent` action only if the DTO itself is redacted at source and contains
no endpoint URL, API-key reference, provider body, or raw secret-bearing field.
The action may still offer an assistant-summary render mode; the operator-report
mode must remain bounded by surface policy and explicit affordance.

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
