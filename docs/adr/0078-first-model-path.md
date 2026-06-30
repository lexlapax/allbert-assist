# ADR 0078: First-Model Path

Status: Proposed (v0.60); decided at v0.60 M3.
Date: 2026-06-30
Related: ADR 0072 (recommended model profiles per purpose — the
recommended-model-per-purpose matrix the chosen path seeds a *first* entry into),
ADR 0069 (guided onboarding — consumes this decision in its v0.63 first-run flow),
ADR 0076 (packaging & unified CLI — may bundle/manage a model runtime per the
chosen option, v0.62), ADR 0077 (product-experience design — this decision is made
within the v0.60 design release ADR 0077 opens), ADR 0006 (Security Central — the
action/credential boundary is unchanged regardless of the option chosen). Decided
in v0.60 M3.

## Context

The v0.60 QuickStart / "fastest first chat" path needs a **reachable model** for a
first useful chat to happen at all. The redesigned onboarding (ADR 0077 → ADR 0069)
must define **explicitly** what happens for a user who arrives with **neither a
hosted-provider key nor a running local model** — the empty-handed first-run case.

This is the single biggest "does it feel like 1.0" onboarding risk. The bar set by
the comparison-class tools (LM Studio, Jan) is effectively **zero-config first
value**: install, open, chat — no key, no separate runtime to stand up. Allbert's
default first-run today does not clear that bar, and the empty-handed user hits a
dead end exactly at the moment first impressions are formed.

Why this must be decided in **v0.60**, not deferred to the onboarding release's M0
as previously planned: option (a) below — an assisted local model — requires the
**package** (v0.62, ADR 0076) to bundle or manage a model runtime and a default
weight. Deciding the First-Model Path *after* packaging is built would mean
**repackaging**. The decision is therefore a prerequisite of v0.62 packaging and
must be locked in the v0.60 design release, before packaging is built.

## Decision

**Resolve the First-Model Path in v0.60 M3**, choosing among three options and
recording the chosen option with its rationale. The downstream artifacts are then
all defined against that single choice:

- (a) **Assisted local model.** Detect or instruct Ollama and offer one-click pull
  of a small default model. *Implies* a managed local dependency and a download
  weight, and a v0.62 packaging bundle decision (ADR 0076). Closest to the
  zero-config bar; heaviest packaging and footprint cost; no recurring operator
  cost.
- (b) **Managed hosted default.** An Allbert-operated free / low-tier provider
  endpoint that works out of the box. *Implies* a credential or relay, an abuse-
  and-cost policy, and an ongoing-cost owner. Lowest user friction; introduces an
  operated service Allbert does not have today and a standing cost/abuse surface.
- (c) **Honest bring-your-own-key.** QuickStart explicitly requires either a
  provider key or a running local model, and says so plainly. *Not* truly
  zero-config; lowest build and operating cost; honest about the requirement but
  does not clear the LM Studio / Jan bar for the empty-handed user.

The chosen option is recorded in v0.60 M3 along with its rationale and tradeoffs.
Against that choice, the following are then defined:

- the **QuickStart fast path** (ADR 0072's recommended-model matrix seeds the first
  entry),
- the **v0.61 landing / empty-state messaging** (what the empty-handed user is
  told and offered),
- the **v0.62 packaging bundle decision** (whether the package ships/manages a
  runtime, per option (a)),
- the **v0.63 onboarding flow** first-run branch (ADR 0069 / ADR 0077), and
- the **v1.0 acceptance-matrix "first useful chat" criterion**.

**Recommendation.** Lock the choice in v0.60 M3. The source plan does not record a
final pick; this ADR frames the three options and their costs and requires the
decision be made and recorded in v0.60 M3 — it does **not** fabricate a final
selection. If the project has not yet picked at the time this ADR is accepted, the
three options above stand as the decision frame, with option (a) carrying the
zero-config strength and the packaging dependency that forces the timing, and the
explicit instruction that M3 resolve and record one.

## Consequences

- The empty-handed first-run case has a single, explicit, designed answer instead
  of a dead end, and every downstream surface (QuickStart, landing/empty-state,
  packaging, onboarding, the v1.0 "first useful chat" criterion) is defined against
  that one answer.
- The packaging-order hazard is removed: because the path is decided in v0.60
  before v0.62, the package is built once against a known requirement rather than
  repackaged after the fact.
- Downstream costs follow the chosen option — a managed local dependency and
  download weight for (a), an operated endpoint with abuse/cost ownership for (b),
  or an explicit key/local-model requirement for (c).

## Non-goals and guardrails

- **No new authority.** Whichever path is chosen routes through the same runtime,
  action, and settings spine; it grants no new capability or egress.
- **Security Central and the credential-vault model are unchanged.** The OS
  secret-vault path (ADR 0076, v0.62) and the action boundary (ADR 0006) are not
  altered by the First-Model Path; option (b)'s relay, if chosen, is a provider
  endpoint under the existing credential and policy boundary, not a new one.
