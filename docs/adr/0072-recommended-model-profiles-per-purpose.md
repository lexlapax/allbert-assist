# ADR 0072: Recommended Model Profiles Per Purpose

Status: Accepted (v0.56 M15 closeout, 2026-06-23).
Date: 2026-06-22
Related: ADR 0051 (provider capability preferences), ADR 0061 (local embedding +
router model tiers), ADR 0047 (provider doctor contract), ADR 0062 (intent
descriptor lifecycle), ADR 0071 (routing-accuracy evaluation harness), ADR 0006
(Security Central).

Amended by v1.3 M9.b.3 (2026-07-31): DirectAnswer is a separately qualified
purpose. Its shipped local recommendation is `direct_answer_local` /
`qwen2.5:7b` at deterministic temperature `0`; this does not replace the
cross-platform `local` / `llama3.2:3b` first-model default.

Amended by v1.3 M9.b.4.3/M9.b.5.3 (implemented at `c3baec24`): the
operator matrix and doctor add distinct `fanout_manager`, `fanout_review`, and
`fanout_synthesis` purpose rows. These rows expose Settings-owned task-route
selection and readiness; they do not independently choose a new default,
qualify a model, grant hosted egress, or make a recommendation authoritative.

## Context

Allbert consumes models for many distinct purposes — intent Stage-1 embedding,
intent Stage-2 disambiguation, escalation, descriptor generation (v0.56), the
intent eval live lane (v0.56), the main conversational loop (`:fast`/`:capable`/
`:thinking` aliases), voice STT/TTS, vision/image generation, the codegen
committee, advisory critics, and the forthcoming Pi-mode coding surface (v0.57).
Each purpose has different requirements (local vs hosted, size, capability,
latency, determinism, privacy).

The configuration substrate already exists: named profiles
(`embedding_local`, `router_local`, `router_escalation_local`) are Settings
Central schema defaults; `:fast`/`:capable`/`:thinking` aliases live in config;
ADR 0047 defines a provider doctor; ADR 0051 defines capability preferences. What
is missing is a **consolidated, operator-facing recommendation** of *which model
to use for what purpose*, and a way to **verify** an operator's configuration
against it. Today that guidance is scattered (`docs/operator/voice-and-provider-preferences.md`
covers voice only; `docs/developer/provider-capabilities.md` is developer-facing),
so an operator cannot answer "what should I pull/configure for purpose X?"

## Decision

Allbert ships a **recommended model profile set per purpose** as a first-class,
**advisory** artifact, operator-overridable through Settings Central, and surfaced
by the doctor.

### 1. The recommendation matrix

A single operator guide, `docs/operator/model-recommendations.md`, holds one row
per purpose: recommended **local** profile, recommended **hosted** alternative
(opt-in, audited), minimum capability/size, privacy/egress posture, the **Settings
Central** key/profile to set, the **verify** command, and the **fallback** when
the model is unavailable. Purposes covered: intent embedding, intent
disambiguation, intent escalation, descriptor generation, intent eval live lane,
main conversational loop, DirectAnswer, voice STT/TTS, image generation,
fan-out planning, fan-out rule review, fan-out synthesis/revision, codegen
committee, advisory critics, and a forward-looking Pi-mode coding row (v0.57).

### 2. Settings Central is authority; recommendations are advice

The recommended profiles are **defaults and advice only**. Actual configuration
lives in Settings Central (schema specs + defaults + `safe_write_keys`); operators
override per purpose with the documented keys. A recommendation never forces a
model, never enables egress on its own, and never lowers a safety floor. Egress
(any hosted profile) remains an explicit, audited operator choice through the
existing capability/egress path (ADR 0051/0006).

### 3. The doctor verifies (folded into existing surfaces)

Per-purpose model reporting folds into the **existing** doctor surfaces — no new
`mix allbert.models` task. It is implemented as a **registered read-only internal
action** `model_doctor` (`exposure: :internal`, `permission: :read_only`) resolved
through `Actions.Runner.run/3`, so `mix allbert.settings model-doctor`, the
`mix allbert.intent doctor` intent rows, the TUI `/models` read, and the v0.58
Settings/Models panel are all thin views over the same action (the ADR 0070 / v0.56
Operator Action Layer pattern). The v0.58 panel also consumes the bounded
`list_model_profiles` and `list_provider_profiles` read actions for profile inventory
display under surface policy. For each purpose `model_doctor` returns **recommended** vs
**configured** vs **status** — `ok | missing | under-capable | not-pulled |
unavailable | remote-egress-warning` — using the ADR 0047 doctor envelope
(redacted; never prints secrets or raw endpoints). Closed fan-out task rows
also expose their ordered chain, exact resolved profile, role readiness, and
exact unavailable role, with `auto_pull=false`.

### Current public model tags

The recommended defaults must reference **real public Ollama tags** and stay aligned
with Settings Central. Current public Ollama docs list `gemma4:26b` as the local
workstation escalation tag and `gemma4:e2b` / `gemma4:e4b` as edge local tags. v0.56
therefore keeps the existing Settings Central defaults (`router_escalation_local` =
`gemma4:26b`, local STT validation default = `gemma4:e2b`) and reconciles stale docs
that claimed `gemma4:*` was unavailable. `model_doctor` guards against drift by
reporting `not-pulled`/`under-capable` for missing or insufficient local models.

v1.3 adds the separate `direct_answer_local` recommendation on the official
Ollama `qwen2.5:7b` tag (4.7 GB catalog size; 16 GB recommended floor) with
temperature `0`, maximum `1024` output tokens, and a 60-second timeout. The
[official Ollama catalog](https://ollama.com/library/qwen2.5) and
[Qwen 2.5 release](https://qwenlm.github.io/blog/qwen2.5/) are the upstream
metadata sources; Qwen identifies the 7B model as Apache-2.0. This task row
does not replace `local` / `llama3.2:3b` as the first-model default, and its
external Ollama weights are not packaged Allbert components.

The three fan-out role rows use `direct_answer_local` / `qwen2.5:7b` as the
advisory local recommendation aligned with ADR 0051's additive initial task
chains. That alignment is not a fan-out quality verdict. The frozen configured-
provider matrix and attended operator validation determine whether a selected
profile qualifies for manager, critic, or composer behavior. An operator may
configure different capable profiles per role without changing the global
primary or DirectAnswer chain. The doctor reports configured truth and
callability; it does not silently substitute the recommendation when a role is
missing or unavailable.

### 4. UI/UX surfacing

The recommendation read-model (purpose -> recommended/configured/status) is exposed
as a read-only DTO so operator surfaces can render it: the CLI doctors and TUI
`/models` read render it in v0.56; the v0.58 Web UX redo renders it in a
Settings/Models panel alongside bounded model/provider profile inventories.
v0.56 ships the DTO plus CLI/TUI rendering; web rendering and operator-managed
raw-report policy are flagged for v0.58 (see the v0.56 plan UI/UX milestone).

## Authority invariants

- A recommendation is advice; Settings Central is the configuration authority.
- A role-chain selection is configuration, not semantic qualification or
  execution authority; Runtime callability and Disclosure still apply before
  durable fan-out framing.
- No recommendation grants capability, enables egress, or lowers a safety floor.
- Hosted/egress profiles stay explicit operator opt-ins, audited at the boundary
  (ADR 0051/0006).
- The doctor is read-only and redacted (ADR 0047): no secrets, no raw endpoints.

## Consequences

- New: `docs/operator/model-recommendations.md`, a recommended-profile-per-purpose
  default set in Settings Central, per-purpose reporting in `mix allbert.intent
  doctor` + `mix allbert.settings model-doctor`, and a recommendation read-model
  DTO for operator surfaces.
- Operators get one place to answer "what model for what" and a command to verify
  their setup — directly improving the ADR 0071 live bench experience (they learn
  `router_local` is not pulled before a bench fails confusingly).
- `docs/developer/provider-capabilities.md` and `docs/operator/voice-and-provider-preferences.md`
  link to the consolidated guide as the canonical recommendation source.

## Alternatives considered

- **A dedicated `mix allbert.models` task.** Rejected: folds more cleanly into the
  existing intent/settings doctors per operator decision; fewer surfaces to learn.
- **Fold the matrix into ADR 0051 only.** Rejected: the per-purpose operator
  recommendation is a distinct, durable artifact future releases (v0.57 Pi-mode,
  v0.58 web) build on; it earns its own ADR.
- **Hard-code recommended models in code.** Rejected: models change; the
  recommendation is documentation + Settings Central defaults, operator-overridable.
