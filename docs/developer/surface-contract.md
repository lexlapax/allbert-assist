# Surface Contract

Status: v0.58 implementation contract; implemented through M13 with M13.1A/B
complete and M13.1C remediation active before M14.

Authority: `docs/adr/0073-cross-surface-contract.md`,
`docs/plans/v0.58-plan.md`, and
`docs/plans/v0.58-request-flow.md`.

## Purpose

v0.58 makes every operator and protocol surface a thin view over one runtime,
action, settings, identity, event, and rendering spine. This guide is the
implementation checklist for that contract. It does not grant new authority and
does not change the user-facing permission model.

## Surface Vocabulary

Use these `surface_id` values in event/audit records, traces, and diagnostics:

| Surface | `surface_id` |
| --- | --- |
| Phoenix workspace and operator pages | `live_view` |
| Mix tasks / CLI entrypoints | `cli` |
| Warm TUI channel and TUI operator reads | `tui` |
| MCP stdio | `mcp_stdio` |
| MCP streamable HTTP | `mcp_http` |
| ACP stdio | `acp` |
| OpenAI-compatible HTTP | `openai_api` |
| Channel adapters | adapter id, for example `telegram`, `email`, `slack` |
| Pi-mode coding surface | `tui` plus coding session metadata |

Add a new value only when the surface has a stable inbound boundary and its own
event/audit identity. Do not overload `cli` for public protocol or web traffic.

## One Request Path

Every surface follows the same shape:

```text
inbound surface input
  -> normalize
  -> Channels.Identity.resolve
  -> derive or load session
  -> record inbound event with surface_id
  -> Runtime.submit_user_input/1 or Actions.Runner.run/3
  -> Security Central and Settings Central
  -> typed Runtime.Response
  -> Surface.Renderer.render_response/2
  -> surface presentation
  -> record rejection/error event with surface_id
```

User turns use `Runtime.submit_user_input/1`. Operator reads and mutations use
registered actions through `Actions.Runner.run/3`. A surface may adapt input and
output, but it must not own domain logic, security policy, settings semantics, or
confirmation storage.

## Identity And Sessions

- Resolve identity through `Channels.Identity.resolve`; do not hardcode
  `user_id: "local"` or `session_id: "web-local"` in surface code.
- Channel identity maps stay list-shaped.
- Sessions are derived from provider/channel identity or a stable
  `surface_id`-specific seed.
- Protocol clients carry client identity in public-protocol metadata; that identity
  is for client scoping and result readback, not authority.

## Rendering

`Surface.Renderer.render_response(response, descriptor)` is the single renderer
contract. Surface adapters pass descriptors describing available primitives and
presentation constraints. Renderers may produce surface chrome, but only
`model_payload` reaches memory and model-facing context.

Do not:

- format the same `Runtime.Response` in private per-surface helper trees;
- put surface chrome in `model_payload`;
- let public protocol or channel adapters invent an alternate error shape;
- expose provider bodies, raw prompts, endpoint URLs, or secret refs.

## Action Access

Surfaces call actions through `Actions.Registry` and `Actions.Runner.run/3`.
Expected shared helpers:

- `Surfaces.ContextBuilder` for `cli`, `live_view`, `tui`, channel, and protocol
  action contexts;
- `Actions.Helper.completed_action/2` for consistent success packets;
- `ErrorExtraction.from_response/1` for uniform error presentation;
- `Surface.Renderer` for typed response rendering.

Web panels use the ADR 0070 operator-action layer for v0.56 DTO reads. Direct
reads from `Confirmations`, `Settings.Store`, descriptor stores, or business
stores are implementation bugs unless the plan explicitly marks them as internal
facade code.

## Operator Reads And Public Protocol

Operator reads may be `:internal` and `:read_only`, but they are only reachable
through explicit operator surfaces such as Mix, TUI slash allowlists, or web
panels. They are not public tools.

Public protocol exposure is deny-before-allow. These reads must not appear in MCP
or OpenAI-compatible tool lists:

- `model_doctor`
- `intent_coverage`
- `intent_list_descriptors`
- `intent_show_descriptor`
- `intent_eval_run`
- `intent_list_review`
- `promote_intent_descriptor`

Public protocol smoke tests should use public-safe tools such as `direct_answer`
and `get_public_call_result`, then separately prove that internal operator reads
are absent from `tools/list`.

## M13.1 Audit Remediation Contract

Second-pass audit findings that affect this surface contract:

- Complete in M13.1A: profile inventory DTOs are redacted before they leave
  Settings Central / action code. Do not carry endpoint URLs, API-key references,
  provider bodies, or raw secret-bearing fields in `providers` or `models`
  response packets.
- `list_provider_profiles` and `list_model_profiles` may be assistant-safe
  `:agent` reads only under the ADR 0070 carve-out: source-redacted DTOs and
  bounded render modes. Raw operator fields require an internal read or explicit
  operator affordance.
- Complete in M13.1A: ACP and MCP rejection paths that fail before
  `Runtime.submit_user_input/1` or `Actions.Runner.run/3` still record
  rejection/error events with `surface_id`.
- Surface-policy report-shape coverage is explicit. At M13 the covered read set is
  `list_settings`, `list_channels`, `list_model_profiles`, and
  `list_provider_profiles`; M13.1 widens it to `intent_coverage`,
  `intent_list_descriptors`, `intent_list_review`, and `model_doctor`, or records
  a narrower ADR 0073 scope before M14.
- The `:v058` eval module must include behavioral assertions for these contracts,
  not only EvalInventory row wiring.

## Settings And Security

- Settings Central is the only source for operator-tunable config.
- Security Central is the only authority boundary.
- Surface policy lives in the `surface_policy.*` Settings Central namespace and is
  read/updated through `surface_policy_read` / `surface_policy_update`. It governs
  report shape, redaction/display profile, row/count bounds, and explicit raw-report
  affordance. It cannot make `:internal` actions public, lower confirmation floors,
  bypass confirmation, or grant egress.
- Descriptors are routing and presentation vocabulary, not authority.

## Conformance Checklist

For each surface:

- identity resolves through `Channels.Identity.resolve`;
- inbound, rejection, and error events record `surface_id`;
- user turns call `Runtime.submit_user_input/1`;
- operations call `Actions.Runner.run/3`;
- output uses `Surface.Renderer`;
- operator reads use registered actions;
- no direct settings, confirmation, descriptor, or business-store reads in surface
  code;
- public protocol tool lists include only public-safe tools;
- redaction hides secrets, endpoints, raw prompts, provider bodies, and raw
  descriptor/evidence payloads;
- focused tests and `mix allbert.test release.v058` cover the surface.

`release.v058` is the M13 deterministic gate and must pass again after M13.1. It
bundles disposable migration,
surface contract units, Settings Central guard/schema checks, web/catalog/design
system units, operator-panel DTO and surface-policy units, helper-consolidation
regressions, `:v058` eval inventory and behavioral checks, task usage checks, and
the release-home secret scan.

## Operator Evidence

The manual validation authority is
`docs/plans/v0.58-request-flow.md`. It proves:

- browser/web design-system behavior;
- CLI and warm TUI DTO parity;
- MCP and OpenAI public-protocol smoke through public-safe tools;
- internal-read denial in public protocol;
- event evidence for `live_view`, `cli`, `tui`, `mcp_http`, and `openai_api`;
- settings-no-bypass and redaction checks.
