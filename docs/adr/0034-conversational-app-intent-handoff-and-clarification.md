# ADR 0034: Conversational App Intent Handoff And Clarification

## Status

Proposed for v0.33 Conversational App Intent Handoff And Direct Answer
Foundation (`docs/plans/v0.33-plan.md`).

## Context

After v0.31, the safe routing behavior is visible in the operator UI: a neutral
workspace prompt such as `analyze CIEN` falls to `direct_answer` unless the
operator has already selected StockSage. This preserves ADR 0019 and v0.28
app-scope hardening, but the fallback is unhelpful: `direct_answer` is a static
echo and plausible app-owned candidates are not surfaced as choices.

Modern assistant routers use a similar pattern: deterministic or semantic
candidate collection first, explicit clarification when intent is ambiguous,
and model/tool choices only as application-validated proposals. Relevant
references include Amazon Lex Intent Disambiguation, Rasa two-stage fallback,
OpenAI function/tool calling with allowed tools, and clarification research
such as CLAM.

## Decision

Allbert adds a conversational app-handoff layer between neutral intent
recognition and app-owned action execution.

1. App-owned natural-language hints are declared as registered intent
   descriptors. Descriptors are metadata only and cannot grant permission,
   trust, route authority, settings authority, or execution.
2. Neutral context may produce an `:app_handoff` decision. The handoff asks the
   operator whether to enter a named app context and run the proposed
   capability.
3. Accepting handoff is an explicit context transition. It sets or carries the
   matching `active_app` before action execution, after which the normal
   `Actions.Runner.run/3`, Security Central, confirmation, resource access,
   trace, and audit boundaries apply.
4. Declining handoff creates no action confirmation and leaves app context
   unchanged.
5. Missing slots or close competing candidates produce `:clarify_intent`
   rather than silent selection.
6. The existing bounded `Intent.Classifier` remains advisory. It may recommend
   a collected candidate or low-confidence clarification, but it cannot invent
   candidates, change permissions, set app context, or bypass confirmation.
7. Core routing must not grow StockSage-specific core predicates. StockSage proves
   the descriptor/handoff contract as the first app consumer.
8. The direct-answer model call is Settings Central-gated (operator-decided
   default, following the bounded `Intent.Classifier` precedent rather than being
   implicitly on), redacted and traced per ADR 0019, and grants no Resource
   Access escalation. When the model is disabled or unavailable it returns a
   deterministic bounded fallback.
9. Descriptor candidates are collected through `AllbertAssist.Extensions.Registry`
   from an optional `SurfaceProvider.intent_descriptors/0` callback and validated
   by `AllbertAssist.Intent.Descriptor`. A descriptor whose `app_id`/`action_name`
   is unregistered, disabled, or not agent-exposed is inert.
10. The deterministic decision rule selects `:app_handoff`, `:clarify_intent`, or
    `:direct_answer` from descriptor scores using Settings-Central thresholds
    (`intent.handoff_threshold`, `intent.handoff_margin`, `intent.clarify_floor`).
    The classifier may only re-rank or select within the already-collected
    candidate set; it never changes the outcome's authority.
11. The handoff/clarify proposal is surfaced as a v0.26 ephemeral surface
    composed from existing catalog primitives; v0.33 adds no catalog atom and
    requires no ADR 0030 amendment. Slot extraction is descriptor-declared and
    conservative — missing or ambiguous slots produce clarification, never a
    guessed value.

## Consequences

- ADR 0019 remains intact: intent ranking and model output are proposal
  infrastructure, not authority.
- ADR 0021 remains intact: advisory provider output never authorizes execution.
- v0.28 app-scope hardening remains intact: app-owned actions still require
  explicit matching `active_app` at the runner boundary.
- The direct-answer path must become useful and side-effect-free rather than a
  static echo.
- Future app/plugin generator work must scaffold app intent descriptors only
  as inert proposal metadata.

## Implementation Notes

The v0.33 M0 preflight on 2026-05-23 confirmed that the descriptor/handoff
contract can use the existing v0.32 `/workspace` route, session active-app
actions, and v0.26 ephemeral surface renderer. The implementation should add
descriptor discovery and handoff/clarification data without adding a new
Surface catalog atom or changing ADR 0030.

## References

- Amazon Lex Intent Disambiguation:
  `https://docs.aws.amazon.com/lexv2/latest/dg/generative-intent-disambiguation.html`
- Rasa two-stage fallback:
  `https://rasa.com/docs/rasa/reference/rasa/core/policies/two_stage_fallback/`
- OpenAI function calling:
  `https://developers.openai.com/api/docs/guides/function-calling`
- CLAM: Selective Clarification for Ambiguous Questions:
  `https://arxiv.org/abs/2212.07769`
- Deciding Whether to Ask Clarifying Questions in Spoken Language
  Understanding:
  `https://arxiv.org/abs/2109.12451`

## Relates To

- Amends: ADR 0019 (Cross-Surface Intent Enrichment) with explicit handoff and
  clarification decisions.
- Amends: ADR 0021 (Intent, Objective, Capability, And Advisory Boundary) by
  promoting a narrow intent/route advisory-provider consumer while preserving
  authority rules.
- Constrained by: ADR 0015, ADR 0017, ADR 0024, and v0.28 app-scope security
  evals.
- Reuses (no amendment): ADR 0030 (Unified Surface Catalog/Renderer And
  Extension Registry) — handoff/clarify compose from existing primitives via the
  ephemeral substrate, and descriptors flow through the extension registry.
- Owns settings through: ADR 0031 (Settings Schema Fragments And Authority) —
  the new `intent.*` handoff/clarify/direct-answer keys live in the intent
  settings fragment and are written only through Settings Central actions.
- Enables: v0.36 generator scaffolding for app intent descriptors.
