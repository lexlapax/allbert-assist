# ADR 0068: Pi-mode Coding Surface and Local-Coding Trust Tier

Status: Proposed (v0.57).
Date: 2026-06-21
Related: ADR 0067 (TUI/terminal channel + split tool result — the foundation
this surface streams over), ADR 0009 (local execution sandbox levels — extended
here with a named local-coding tier), ADR 0016 (channel adapter boundary — the
coding surface is a channel/app, not a second runtime), ADR 0006 (Security
Central — unchanged), ADR 0029 (typed response contracts — split payload),
ADR 0056 (channel inbound trust tier — invariants unchanged).
Predecessor/foundation: ADR 0067 (split result + terminal channel), ADR 0009
(sandbox levels), ADR 0016 (channel contract).
Rationale source: `docs/archives/pi-integration-rethink.md`.

## Context

The v0.55 terminal channel (ADR 0067) makes a real, streamed, identity-mapped
terminal surface available with a split model-facing/surface-render payload. That
opens a concrete question the rethink in `docs/archives/pi-integration-rethink.md`
raises: can Allbert host a focused terminal **coding** surface — read/write/edit
files and run shell — without becoming a second authority spine, and without
adopting the "YOLO, auto-approve everything, let the model decide when it's done"
posture that off-the-shelf terminal coding agents default to?

The constraints are firm. Allbert has **one** authority spine: every effectful
operation goes through `Actions.Runner.run/3`, the action boundary, Security
Central (ADR 0006), and confirmations. Sandbox levels (ADR 0009) define the
isolation posture, and the project is MCP-first for external capability. A coding
surface that bypassed any of these would be exactly the "second runtime / second
security policy" the channel contract (ADR 0016) exists to prevent.

A coding loop also has a failure mode generic channels do not: the model deciding
on its own that effectful or generated-code work is "done." For effectful and
generated-code work that judgement must be **deterministic**, not model-asserted.

## Decision

### Pi-mode coding surface as a channel/app on the one authority spine

Introduce **Pi-mode**, a gated terminal coding surface implemented as a
channel/app on the existing terminal channel (ADR 0067) — **not** a new runtime
or a new authority path. Its capability is exactly **four boundary actions**, each
a registered action invoked through `Actions.Runner.run/3`:

- **read** — read file/context;
- **write** — create a file;
- **edit** — modify an existing file;
- **bash** — run a shell command (subject to the sandbox level, ADR 0009).

Surface discipline:

- a **sub-1000-token prompt** — the coding surface runs a deliberately small
  system prompt, not a sprawling agent harness;
- **streamed split-payload diffs** — edits/writes stream as a surface-render diff
  while the model-facing payload carries the canonical change, using the ADR 0067
  split-result pattern;
- **full-file context discipline** — the surface works from full-file context
  rather than fragmentary snippets, so edits are grounded.

Every one of the four actions is an ordinary registered action: it passes the
action boundary, Security Central, and its own confirmation gate. The surface
selects and sequences; it grants no authority.

### Named "local coding / sandbox level 0" trust tier (extends ADR 0009)

Add a named trust tier — **local coding / sandbox level 0** — extending the
sandbox levels of ADR 0009. It is scoped to **a single trusted operator in the
main session on the terminal channel**: the local human driving Pi-mode
interactively. It is a named, explicit tier so the trust assumption is legible
and auditable, not an implicit relaxation buried in the coding surface.

## Non-goals and guardrails

- **Never YOLO-by-default.** Pi-mode does not auto-approve effectful actions and
  is not enabled by default.
- **Never for channel-originated or generated-code sessions.** The local-coding
  tier applies only to the single trusted operator in the main terminal session.
  It never extends to channel-originated requests or to generated-code execution
  sessions, which keep their existing tiers.
- **No weakening of the action boundary, Security Central, or confirmations.**
  The four actions run through `Actions.Runner.run/3` and Security Central
  (ADR 0006) exactly like any other action; confirmation gates are unchanged.
- **The model never decides it is "done"** for effectful or generated-code work.
  Acceptance is governed by **deterministic acceptance rules**, not the model's
  self-assessment.
- **Keep MCP-first.** Pi-mode does not displace the MCP-first posture for
  external capability; it is a focused local surface over the existing boundary.

## Consequences

- Allbert gains a focused, streamed terminal coding surface that lives entirely
  on the one authority spine: four registered boundary actions, no second runtime,
  no second security policy.
- A named local-coding/sandbox-level-0 tier (ADR 0009 extension) makes the single
  trusted-operator trust assumption explicit and auditable, and bounds it to the
  main terminal session.
- The guardrails preserve every existing invariant: action boundary, Security
  Central, confirmations, sandbox levels, and MCP-first are unchanged; "done" for
  effectful/generated-code work is deterministic, not model-asserted.
- This surface depends on the v0.55 terminal channel and split-result pattern
  (ADR 0067); without that substrate the streamed split-payload diffs and the
  terminal coding loop would have nowhere to render.
