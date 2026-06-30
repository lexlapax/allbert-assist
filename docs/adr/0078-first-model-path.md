# ADR 0078: First-Model Path

Status: Accepted (v0.60). Decision recorded 2026-06-30 — assisted-local model as
the QuickStart default, bring-your-own-key as the Advanced/fallback path,
managed-hosted default rejected; implemented across v0.60 M3, v0.61
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
  - **Default model — criteria, not a pinned model.** The curated default is
    selected (and periodically refreshed) at v0.60 M3 / v0.62 against criteria
    (open-weight, runs on typical prosumer hardware, modest download weight) with no
    hard licensing or family constraint fixed in this ADR. ADR 0072's
    recommended-model matrix seeds the first entry.
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
