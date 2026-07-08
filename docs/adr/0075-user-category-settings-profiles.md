# ADR 0075: User-Category Settings Profiles (Personas)

Status: Proposed (v0.63).
Date: 2026-06-25
Related: ADR 0077 (Product Experience Design & IA — designs the persona/profile
model in v0.60 M4; this ADR applies and builds it in v0.63), ADR 0004 / ADR 0031
(Settings Central — profiles seed defaults through it and nowhere else), ADR 0069
(guided onboarding — the primary place a profile is applied), ADR 0072 (model
recommendations — profiles reference recommended model purposes), ADR 0006
(Security Central — profiles grant no authority).
Anchors the v0.63 "profiles" half of Guided Onboarding & Profiles.

## Context

A new operator today lands on a blank, undifferentiated configuration: one
"default profile" exists purely for hygiene, and there is no concept of "what
kind of user am I." Every operator must discover, one setting at a time, which
apps, channels, intents, and model defaults make sense for their work.

The 2026 competitive bar is **opinionated presets over raw config** — Claude
Desktop's effort toggle, OpenClaw's QuickStart defaults, Msty's personas, and
Hermes Agent's `SOUL.md` behaviour persona. Hiding a settings matrix behind one
human-readable choice is now expected, especially for the technical-prosumer
audience who wants polish without a config tour. Allbert adopts the easy preset
UX, but deliberately rejects behaviour-persona authority creep.

Allbert has the substrate (Settings Central, the app/channel/intent catalogs, the
ADR 0072 recommendation matrix) but no preset layer that turns "I am a
researcher / developer / writer / ops person" into a tailored starting point.

## Decision

Introduce **repo-maintained user-category profiles** (personas): declarative,
version-controlled presets that seed a tailored starting configuration. The
persona *model* — the category set and what a profile seeds — is designed in the
v0.60 Product Experience Design release (ADR 0077 M4); this ADR **applies and
builds** it in v0.63.

- **Shipped categories** (extensible): `researcher`, `developer`, `writer`,
  `ops`, `general`.
- **Each profile is a reviewed, in-repo declarative preset** that specifies:
  Settings Central default values; a suggested set of apps to enable; suggested
  channels; suggested intents; and a recommended model-purpose mapping (referencing
  ADR 0072 recommendations, not pinning specific endpoints).
- **Application is explicit and reviewable.** A profile is applied during guided
  onboarding (ADR 0069) or through a registered settings action, always with an
  operator review/confirm step that shows exactly what will be seeded.
- **Repo-maintained, not user-generated.** Profiles are curated and reviewed in
  the source tree — the same trust posture as reviewed plugins, and a deliberate
  contrast with open community preset marketplaces.

The concrete v0.60 M4 persona artifact is `docs/design/persona-model.md`: the
persona categories, seed envelope, per-persona seed intent, review/confirm
application model, and v0.63 handoff.

## Consequences

- A new user gets a tailored, sensible starting point with one choice instead of
  a settings tour — the onboarding "opinionated preset" the competitive bar
  expects.
- **Seed-only semantics: profiles are defaults, not authority.** Applying a
  profile only pre-populates operator-tunable Settings Central values and
  suggestions the operator can change. It lowers no confirmation floor, grants no
  egress, enables nothing effectful without the normal gates, and Security Central
  (ADR 0006) is unchanged.
- Profiles flow through Settings Central (ADR 0004/0031) like any other settings
  write — they are not a configuration side channel.
- The curated/reviewed model is a trust differentiator and keeps the preset set
  small and legible for the v1.0 freeze.

## Non-goals and guardrails

- **Not runtime authorization.** A profile is not a permission set, a trust tier,
  or a per-user authority model; it cannot grant capabilities.
- **Not learned or auto-generated.** Personas are reviewed in-repo presets, not
  distilled from traces or model output (that stays a durable non-goal); the
  existing free-text `persona.md`/identity memory is unrelated operator content.
- **Not hosted/multi-user.** Profiles are local operator presets, not a
  multi-tenant role system.
- Profiles never override Security Central, confirmations, or the action boundary.

## v0.63 Build Decisions (resolved for implementation)

Ratified in the v0.63 plan's Locked Decisions (2026-07-07/2026-07-08):

- **Storage = declarative `priv/` catalog (Decision 2).** Each persona is a
  reviewed `priv/personas/<persona_id>.{yaml|json}` file carrying the 8-field seed
  envelope (`persona_id`, `label`, `settings_seeds`, `suggested_apps`,
  `suggested_channels`, `suggested_intents`, `model_purpose_map`,
  `first_chat_prompts`). A persona **registry module** (`AllbertAssist.Personas`)
  loads and validates the catalog at boot and **rejects** any `settings_seeds` key
  that is not an existing Settings Central `@safe_write_key` — not Elixir modules
  (heavier to review) and not a settings fragment (hides the standalone reviewable
  artifact).
- **Application = a registered, review-gated action.** `apply_persona_profile`
  (permission `:settings_write`, exposure `:internal`, `confirmation: :required`)
  computes a **review diff** of proposed values against current Settings and seeds
  only through `Settings.put/3` over safe-write keys after explicit confirm. It is
  callable inside onboarding (`profile_review` step) and standalone. Skipping never
  blocks first useful chat.
- **Persona ≠ system prompt (Decision 8).** A persona is a **seed-only settings
  profile**, explicitly not a `SOUL.md`-style system-prompt/behaviour persona (the
  competitor pattern). It changes starting *configuration*, never runtime behaviour
  or authority — the deliberate trust-preserving contrast with OpenClaw/Msty/Hermes
  Agent-style personas cited in Context.
- **Exact per-persona seed values** (all seed only existing safe-write keys; enums
  per `docs/design/persona-model.md` pre-audit). Suggested apps/channels/intents and
  `model_purpose_map` are UI/advice only (post-first-chat), never QuickStart model
  pulls:

  | persona | Exact Settings Central writes after review/confirm |
  |---|---|
  | `general` | `operator.communication_style=balanced`; `operator.handoff_detail=concrete_next_steps`; `model_preferences.primary=local`; `objectives.enabled=true`; `objectives.max_steps_per_turn=3`; `objectives.max_loop_count=5`; `objectives.trace_detail=operator` |
  | `researcher` | `operator.communication_style=detailed`; `operator.handoff_detail=full_context`; `model_preferences.primary=local`; `active_memory.enabled=true`; `active_memory.top_k=8`; `active_memory.chunk_max_bytes=4096`; `intent.router_embedding_profile=embedding_local`; `intent.router_model_profile=router_local`; `intent.router_escalation_profile=router_escalation_local`; `objectives.enabled=true`; `objectives.max_steps_per_turn=6`; `objectives.max_loop_count=8`; `objectives.trace_detail=operator` |
  | `developer` | `operator.communication_style=concise`; `operator.handoff_detail=concrete_next_steps`; `model_preferences.primary=local`; `coding.default_approval_mode=plan`; `coding.model_profile=pi_coding_local`; `coding.read.default_limit=4000`; `coding.search.max_results=200`; `coding.search.max_output_bytes=240000`; `model_preferences.tasks.coding=["pi_coding_local","coding_local","coding","capable","local"]`; `objectives.enabled=true`; `objectives.max_steps_per_turn=5`; `objectives.max_loop_count=8`; `objectives.trace_detail=operator` |
  | `writer` | `operator.communication_style=detailed`; `operator.handoff_detail=full_context`; `model_preferences.primary=local`; `active_memory.enabled=true`; `active_memory.top_k=6`; `active_memory.chunk_max_bytes=4096`; `objectives.enabled=true`; `objectives.max_steps_per_turn=4`; `objectives.max_loop_count=6`; `objectives.trace_detail=operator` |
  | `ops` | `operator.communication_style=concise`; `operator.handoff_detail=brief`; `model_preferences.primary=local`; `runtime.diagnostics_verbosity=verbose`; `objectives.enabled=true`; `objectives.max_steps_per_turn=5`; `objectives.max_loop_count=8`; `objectives.trace_detail=debug`; `intent.router_model_profile=router_local`; `intent.router_escalation_profile=router_escalation_local` |

  Suggested apps/channels/intents and `model_purpose_map` are UI/advice only
  (post-first-chat), never QuickStart model pulls or Settings writes. Hosted-egress
  warnings are review copy attached to relevant advice; they are not settings.
  Any candidate not already a safe-write key is a schema decision surfaced in the
  v0.63 plan's Settings Keys section, never a silent write.

This ADR is Accepted at v0.63 (asserted by the plan's `adr-0075-accepted-001` eval
row).
