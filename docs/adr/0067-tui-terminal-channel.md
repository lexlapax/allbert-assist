# ADR 0067: TUI/Terminal Channel

Status: Proposed (v0.55).
Date: 2026-06-21
Related: ADR 0016 (channel adapter boundary + identity mapping — this channel
is registered under that contract; the v0.55 amendment already reserves
`channel_id: "tui"`, provider `"terminal"`), ADR 0029 (typed runtime response
contracts — extended here with the split-payload pattern), ADR 0030 (unified
surface catalog/renderer — the terminal surface registers here), ADR 0006
(Security Central — a channel grants no authority), ADR 0056 (channel inbound
trust tier — invariants unchanged).
Successor: ADR 0068 (v0.57 Pi-mode coding surface), which builds directly on
this channel and on the split-result pattern established here — Pi-mode builds
on this ADR's split-payload seam and live region.

ADR 0016's v0.55 amendment owns the channel reservation and the
capability/parity-matrix artifact; this ADR (0067) owns the descriptor detail,
the split-payload extension, and the rendering model.

## Context

Allbert's local operator surfaces are CLI (`mix allbert.ask`, labelled `:cli`)
and LiveView. `mix allbert.ask` is a **non-channel** one-shot task: it has no
persistent session, no identity mapping, no inbound event dedupe, no approval
primitive wiring, and no channel-scoped trace or memory. It is a convenience
entry point, not a surface that participates in the channel-adapter contract
(ADR 0016).

That gap matters now for two reasons:

- The v0.55 ADR 0016 amendment already reserves a persistent **TUI/terminal
  channel** (`channel_id: "tui"`, provider `"terminal"`, primitives
  `[:typed_command, :list]`) as a first-class channel distinct from the
  `mix allbert.ask` `:cli` label. The reservation exists; the channel does not.
- The typed response contract (ADR 0029) carries a single result shape that is
  both reasoned over by the model and rendered to a surface. A terminal surface
  that streams output — incremental tokens, a diff being written, a long tool
  result — needs to render progressively **without** feeding the surface's
  rendering scaffolding (ANSI, paging hints, truncation markers, render frames)
  back into the model context as if it were model-facing content. Today there is
  no contracted seam separating "what the model should see" from "what the
  terminal should draw."

A real terminal channel must therefore do two things at once: register a genuine
channel under the ADR 0016 contract (not a dressed-up `mix allbert.ask`), and
give the typed response contract a way to express a result whose model-facing
payload and surface-render payload differ.

## Decision

### A real terminal/TUI channel under the ADR 0016 contract

Introduce a persistent terminal channel as a first-class channel adapter, not an
extension of the `mix allbert.ask` task. It satisfies the full ADR 0016 channel
contract:

- **Identity mapping.** The local terminal operator maps to a workspace
  identity through the same list-shaped identity-map seam every channel uses
  (`external_user_id` terminal profile → local `user_id`); the terminal is not
  an implicit super-user and does not get a shorthand `{"default":"local"}`
  contract.
- **Event dedupe.** Inbound terminal events (keystrokes/submits/resubmits,
  reconnect replays) pass the same inbound dedupe the channel boundary requires.
- **Approval primitives.** `confirmation: :required` actions surface the
  existing `approval_handoff` → `ConfirmationCallback` path, rendered with the
  channel's primitives (`:typed_command`, `:list`, e.g.
  `ALLBERT:APPROVE:<id>`). The terminal never self-approves and never sets a
  `confirmation_id`.
- **Trace and memory.** The channel carries a channel-scoped session with the
  same trace and conversational memory every channel session gets, rather than
  the stateless one-shot of `mix allbert.ask`.

`channel_id: "tui"`, provider `"terminal"`, registered through the surface
catalog (ADR 0030) like any other surface. Security Central (ADR 0006) and the
channel inbound trust tier (ADR 0056) apply unchanged: routing to this channel
grants no authority.

### The split tool result pattern (amendment/extension to ADR 0029 and ADR 0030)

Extend the typed response contract (`AllbertAssist.Runtime.Response`, ADR 0029)
so a single typed result can carry **two distinct named payloads**:

- `model_payload` — the canonical content the model and conversational memory
  reason over; and
- `surface_payload` — what the surface (here, the terminal) actually draws,
  including live-region framing, paging/truncation affordances, and
  surface-specific formatting that must **not** leak back into model context.

When a result carries only one payload, `surface_payload` defaults to
`model_payload`, so existing CLI/LiveView behaviour and operator-facing copy are
unchanged. The surface catalog/renderer (ADR 0030) is extended to honor the
split: a renderer draws `surface_payload`; the runtime threads only
`model_payload` into memory and subsequent turns.

This split is the contracted foundation for future **streamed terminal
rendering**: v0.55 lands the payload separation and live-region render substrate;
v0.57 Pi-mode owns true streamed diff/token semantics.

## Rendering Model

The TUI is **scrollback-native and line-oriented**. Completed turns are written
as static scrollback lines (`Owl.Data` / `IO.ANSI` styling) so the terminal
keeps its native scrolling and search. A SINGLE `Owl.LiveScreen` live block
renders the active input prompt and the in-progress/live status line — a
differential update of only the bottom region, using synchronized-output escape
sequences where supported to avoid flicker.

Explicitly: NO alternate-screen buffer, NO full-viewport ownership, NO
full-screen redraw.

Rationale: `owl` is a top-to-bottom CLI toolkit explicitly distinct from
full-screen TUI libraries; `ratatouille` / `ex_termbox` / `ExNcurses` are
rejected (native build + full-screen takeover that loses scrollback). Reference:
the Pi rationale in `docs/archives/pi-integration-rethink.md`.

## Foundation For v0.57 Pi-mode

v0.55 deliberately lands two seams as the substrate that ADR 0068 (Pi-mode
coding surface) extends ADDITIVELY, so Pi-mode needs no rework of this channel:

1. The **split tool-result payload seam** — `model_payload` separate from
   `surface_payload` (extends ADR 0029/0030) — established in v0.55 even though
   the v0.55 TUI consumes it simply.
2. The **live region** as the streaming-render substrate Pi-mode draws streamed
   diffs into.

Plus: v0.55 keeps the action boundary level-0-compatible (maps to `"local"`
identity, every action through `Actions.Runner.run/3` + Security Central) so
v0.57 can add the named "local coding / sandbox level 0" trust tier on the SAME
adapter/channel without weakening the boundary. Pi-mode runs IN the same
persistent TUI session (the v0.55 operator/validation console), not a new
channel.

## Consequences

- The terminal becomes a genuine channel with identity, dedupe, approval, trace,
  and memory — closing the gap between `mix allbert.ask` and the channel
  contract, and realizing the channel the v0.55 ADR 0016 amendment reserved.
- The typed response contract gains a model-facing vs. surface-render split.
  Single-payload results are unaffected; no operator-facing copy, confirmation
  semantics, or transport fields change for existing callers.
- Future streamed terminal rendering has a contracted seam: surface framing never
  pollutes model context.
- This channel and the split-result pattern are the **substrate the v0.57
  Pi-mode coding surface (ADR 0068) builds on** — its streamed split-payload
  diffs and terminal coding loop depend on both decisions here.
