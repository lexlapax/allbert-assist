# ADR 0078: First-Model Path

Status: Accepted (v0.60). Decision recorded 2026-06-30 — assisted-local model as
the QuickStart default, bring-your-own-key as the Advanced/fallback path,
managed-hosted default rejected; recorded in v0.60 M3, then realized across v0.61
(landing/empty-state), v0.62 (packaging), and v0.63 (onboarding).
Date: 2026-06-30
Related: ADR 0072 (recommended model profiles per purpose — the
recommended-model-per-purpose matrix the chosen path seeds a *first* entry into),
ADR 0069 (guided onboarding — consumes this decision in its v0.63 first-run flow),
ADR 0076 (packaging & unified CLI — integrates detect + guided Ollama install and
the curated model pull per this decision, v0.62), ADR 0077 (product-experience
design — this decision is made within the v0.60 design release ADR 0077 opens),
ADR 0006 (Security Central — the action/credential boundary is unchanged).

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
as previously planned: the assisted-local path (option (a), now chosen) requires the
**package** (v0.62, ADR 0076) to integrate model-runtime management — detect + guided
install of Ollama and the curated model pull. Deciding the First-Model Path *after*
packaging is built would mean **repackaging**. The decision is therefore a
prerequisite of v0.62 packaging and is locked in the v0.60 design release, before
packaging is built.

## Decision

**The First-Model Path is decided (v0.60 M3): the assisted local model is the
QuickStart default, honest bring-your-own-key is the Advanced and fallback path,
and the managed-hosted default is rejected.**

- **Default — assisted local model.** QuickStart's "fastest first chat" runs on a
  local model, so the first useful chat happens fully on-device with no key and
  nothing leaving the machine. This is the strongest demonstration of the 1.0 trust
  position (local-first, inspectable, permissioned) and meets the zero-config bar
  set by LM Studio / Jan. The architecture is surfaced through onboarding *as the
  product advantage*, not a setup tax.
  - **Mechanism — detect + guided install, not bundle.** The package (v0.62, ADR
    0076) detects an existing Ollama install; if absent it offers a guided install
    through the v0.62 Homebrew/curl path, then manages a one-click pull of a curated
    default model. Allbert does **not** bundle the Ollama runtime into the `allbert`
    binary — Ollama is a managed external dependency, keeping the binary light.
  - **Default model — criteria, not a pinned model.** The selection criteria are
    recorded at v0.60 M3, and the curated default is selected and periodically
    refreshed in v0.62 against those criteria (open-weight, runs on typical
    prosumer hardware, modest download weight) with no hard licensing or family
    constraint fixed in this ADR. ADR 0072's recommended-model matrix seeds the
    first entry.
- **Advanced + fallback — honest bring-your-own-key.** The Advanced track lets the
  operator paste a provider key (OpenAI / Anthropic / OpenRouter) or point at an
  existing local model/endpoint. BYOK is also the **graceful fallback**: if the
  machine is below the curated model's hardware floor, or Ollama is unavailable and
  the user declines the guided install, QuickStart degrades to BYOK rather than
  dead-ending. "First useful chat" therefore always has a path — local first, BYOK
  second.
- **Rejected — managed hosted default.** An Allbert-operated free/low-tier relay is
  rejected: it would require the project to operate a credential/relay service with
  a standing abuse-and-cost policy and a perpetual cost owner it does not have, and
  routing the default first chat through an Allbert-operated endpoint contradicts
  the local-first trust position and sits adjacent to the "no hosted multi-user"
  vision non-goal. A one-time engineering cost on the local-first path is preferred
  over a perpetual operational and financial liability.

Against this decision the downstream artifacts are defined: the **QuickStart fast
path** (local model via guided Ollama; ADR 0072 seeds the first entry), the **v0.61
landing / empty-state messaging** (offer the local first chat, BYOK as the
alternative), the **v0.62 packaging integration** (detect + guided Ollama install +
curated model pull; no runtime bundling), the **v0.63 onboarding flow** first-run
branch (ADR 0069 / ADR 0077: try local → fall back to BYOK), and the **v1.0
acceptance-matrix "first useful chat" criterion** (satisfied by the local default,
with BYOK fallback).

The concrete v0.60 M3 artifact is `docs/design/first-model-path.md`: the
QuickStart path, option analysis, first-model-state handoff, and v0.62/v0.63
packaging/onboarding implications. *(Onboarding-state storage-shape ownership
resolved 2026-07-05: v0.62 M3 — v0.62 plan Locked Decision 6.)*

**Degrade path.** If robust Ollama integration proves too costly for the v0.62
window, the acceptable-but-weaker fallback is to ship BYOK-primary for 1.0 and add
assisted-local immediately after — recorded as a deliberate, documented tradeoff
(it knowingly misses the zero-config bar), not drifted into.

## Consequences

- The empty-handed first-run case has a single, explicit, designed answer instead
  of a dead end, and every downstream surface (QuickStart, landing/empty-state,
  packaging, onboarding, the v1.0 "first useful chat" criterion) is defined against
  that one answer.
- The packaging-order hazard is removed: because the path is decided in v0.60
  before v0.62, the package is built once against a known requirement rather than
  repackaged after the fact.
- Downstream cost is a managed local dependency (Ollama, via guided install) and a
  one-time curated-model download weight — a one-time engineering cost on the
  local-first path, with no recurring operator/relay cost and no bundled-runtime
  binary bloat. BYOK adds only the existing key-entry/credential-vault path.

## Non-goals and guardrails

- **No new authority.** Whichever path is chosen routes through the same runtime,
  action, and settings spine; it grants no new capability or egress.
- **Security Central and the credential-vault model are unchanged.** The OS
  secret-vault path (ADR 0076, v0.62) and the action boundary (ADR 0006) are not
  altered by the First-Model Path. BYOK keys (Advanced/fallback) write through the
  existing OS secret-vault path; the local model runs through the same provider
  abstraction as any other model. No new credential, authority, or egress surface.

## Amendment (v0.63 M8.5, 2026-07-08) — enablement point for the "first useful chat"

Operator validation found QuickStart reaching `first_chat` while a model-backed
`allbert ask` still returned the `:model_disabled` fallback, because
`intent.direct_answer_model_enabled` defaults `false` and no onboarding path set it —
a no-dead-end violation of this ADR. Decision: the wizard state machine
(`Onboarding.wizard_advance/3`) enables that safe-write key exactly when it confirms a
usable model — the `model_path` step (or a later completion step) advancing with
readiness `:ready`. Gating on `:ready` preserves the invariant that a broken model is
never presented as working: a below-floor / needs-runtime machine still routes to the
concrete repair or BYOK guidance and leaves the flag off. Applying a persona also seeds
the flag (belt-and-suspenders for the persona path, which QuickStart does not force).
No new authority or egress: the key is an existing `@safe_write_key`.

## Amendment (v0.64 planned, 2026-07-09) — two-tier model path + one-click consumer download

The post-v0.63 product-readiness review retargeted 1.0 at a non-developer local-first
operator (two-tier: consumer default + prosumer advanced). The First-Model Path is
extended accordingly:

- **Consumer default (new):** the web onboarding offers a **one-click in-app download of a
  curated local model** with an in-web progress surface. If the supported local runtime
  is absent, Allbert offers a guided, confirmation-gated Ollama install first. The
  operator does not run the `ollama` CLI and does not need an API key. This is the primary
  first-run path.
- **Advanced (existing):** BYOK hosted setup and custom endpoints remain, opt-in, for
  prosumers.

The assisted-local default, no-dead-end, and no-managed-hosted-default invariants are
unchanged; the consumer default is a friendlier *delivery* of the assisted-local path, not
a new authority or egress class.

The v0.64 delivery mechanism is locked to the existing ADR 0078/v0.62 substrate:
managed Ollama runtime plus Ollama's local pull API behind a web progress surface. v0.64
does not bundle a model or model runtime into the Allbert artifact and does not introduce
an embedded downloader. That keeps binary size, licensing, update, and offline-storage
questions out of the pre-1.0 path while still matching the consumer expectation that no
manual model CLI or hosted provider key is required. A literal no-external-runtime
artifact would require a later ADR amendment and a separate release scope.
