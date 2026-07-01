# Persona Model

Status: v0.60 M4 design artifact and v0.63 design input. This document defines
the ADR 0075 persona/profile model. It is design only: v0.60 adds no persona data
file, Settings key, seeded value, authorization model, or runtime behavior.

## Model Summary

Personas are repo-maintained, reviewed presets that seed a starting
configuration after explicit operator review. They are not roles, permission
sets, trust tiers, or learned user models.

Initial categories:

- `researcher`
- `developer`
- `writer`
- `ops`
- `general`

Each persona defines seed contents in four groups:

- Settings Central defaults or key families.
- Suggested apps/channels/intents.
- Recommended model-purpose mappings, referencing ADR 0072.
- Onboarding copy and first useful chat prompt suggestions.

All seeds are defaults or suggestions. They never grant authority, enable egress,
lower a confirmation floor, connect a channel, or store a secret without the
normal review/confirm and secret-vault paths.

## Seed Envelope

| Field | Meaning | v0.63 application rule |
|---|---|---|
| `persona_id` | Stable id such as `developer`. | Repo-maintained; not user-generated. |
| `label` | Human-readable role name. | Shown in QuickStart/Advanced selection. |
| `settings_seeds` | Settings Central keys or key families to pre-populate. | Written only through Settings Central after review. |
| `suggested_apps` | Product/app panels to highlight. | Suggestions only; no app permission grant. |
| `suggested_channels` | Channels or MCP integrations worth configuring later. | Disabled until the operator configures them. |
| `suggested_intents` | Intent examples and shortcuts to surface. | Routing hints only; no capability grant. |
| `model_purpose_map` | ADR 0072 model-purpose recommendations to emphasize. | Advice only; hosted/egress remains explicit opt-in. |
| `first_chat_prompts` | Starter prompts for first useful chat. | Prompt suggestions only. |

## Relationship To First-Model Path

The First-Model Path in `docs/design/first-model-path.md` is the only
pre-first-chat model requirement. QuickStart reaches first useful chat through
the curated assisted-local model or BYOK fallback before persona model-purpose
recommendations are applied.

`model_purpose_map` entries are post-first-chat seed recommendations. They may
suggest future defaults, readiness checks, or Advanced-track choices after
operator review, but they do not require v0.62 to pull extra persona-specific
models during QuickStart. For example, `researcher` can recommend local
embeddings and a `:capable` / `:thinking` main loop as follow-on setup, while
`developer` can recommend Pi-mode coding profiles after source-code egress and
model posture are reviewed. Those recommendations never redefine the initial
curated model that gets the operator to first useful chat.

## Daily-Use Posture

Personas are setup seeds only. After onboarding, daily-use surfaces, authority
checks, confirmation floors, and channel/provider behavior are persona-uniform
unless the operator later changes Settings Central, configures a provider or
channel, or confirms an action through the normal authority path. The persona id
itself is not a runtime mode, trust tier, or hidden policy switch.

## Persona Seeds

| persona_id | Settings seed families | Suggested apps/channels/intents | Model-purpose mapping | First useful chat examples |
|---|---|---|---|---|
| `general` | `operator.communication_style`, `operator.handoff_detail`, `model_preferences.primary`, objective defaults. | Workspace, Models, Settings, TUI; direct answer, remember/recall memory, objectives. | Main conversational loop local-first; ADR 0072 defaults unless operator chooses hosted. | "Help me understand what Allbert can do locally." / "Summarize my current setup." |
| `researcher` | `operator.communication_style`, active-memory tuning, `model_preferences.primary`, intent router profiles. | Notes/files, browser or MCP resource reads when configured, mail/calendar optional; summarize, extract, compare, remember citation notes. | Local embeddings recommended after review; main loop `:capable` or `:thinking`; hosted research only by explicit egress opt-in. | "Summarize these notes into claims and open questions." / "Compare two sources and list evidence." |
| `developer` | `coding.model_profile`, `coding.default_approval_mode`, coding read/search limits, `model_preferences.tasks.coding`, intent router profiles. | GitHub, notes/files, TUI/Pi-mode, plan preview; read/grep/glob, plan, code review, remember project facts. | Pi-mode coding profile recommended after review; local/private preferred, hosted coding only after source-code egress opt-in. | "Read this repo and propose the smallest safe fix." / "Review this change for regressions." |
| `writer` | `operator.communication_style`, `operator.handoff_detail`, active-memory tuning, `model_preferences.primary`. | Notes/files, mail, image generation only when configured; draft, revise, outline, summarize. | Main loop `:capable`; advisory critics optional; image generation remains provider-confirmed. | "Turn these rough notes into an outline." / "Rewrite this with a clearer voice." |
| `ops` | `runtime.diagnostics_verbosity`, `objectives.trace_detail`, `model_preferences.primary`, intent router profiles. | Jobs, Objectives, Calendar/Mail/GitHub panels, channel setup later; status, doctor, triage, plan/run monitoring. | Fast local model for status/triage, escalation profile for complex incidents, hosted only by explicit egress opt-in. | "Give me an operator status brief." / "Triage these pending jobs and blockers." |

The M9.2 pre-audit below confirms which candidate key families already exist as
Settings Central safe-write keys. Exact per-persona seeded values are still
finalized in v0.63 during review-diff implementation. This v0.60 design fixes the
persona categories, seed groups, review shape, and per-persona intent so the
implementation cannot drift back to an undifferentiated settings tour.

## Settings Central Seed Pre-Audit

M9.2 pre-audits the seed candidates above against the current Settings Central
schema so v0.63 starts from known key status. This is still design-only: v0.60
adds no seed file, default override, registry row, Settings write, or persona
runtime behavior.

| Seed candidate / family | Current schema status | v0.63 action |
|---|---|---|
| `operator.communication_style` | Existing safe-write enum: `concise`, `balanced`, `detailed`. | Choose per-persona value during review diff design. |
| `operator.handoff_detail` | Existing safe-write enum: `brief`, `concrete_next_steps`, `full_context`. | Choose per-persona value during review diff design. |
| `model_preferences.primary` | Existing safe-write profile reference. | Keep as reviewed preference; do not change QuickStart model-pull requirements. |
| `model_preferences.tasks.coding` | Existing safe-write wildcard task preference. | Developer persona may propose coding profile order after egress posture review. |
| `coding.model_profile` | Existing safe-write profile reference. | Developer persona may propose Pi-mode coding profile after source-code egress review. |
| `coding.default_approval_mode` | Existing safe-write enum. | Developer persona may propose a conservative approval default; never bypass confirmation. |
| `coding.read.default_limit`, `coding.search.max_results`, `coding.search.max_output_bytes` | Existing safe-write bounded coding limits. | Developer persona may propose reviewed limits within schema bounds. |
| `intent.router_embedding_profile`, `intent.router_model_profile`, `intent.router_escalation_profile` | Existing safe-write router profile references. | Researcher/developer/ops personas may propose router profile emphasis after model posture review. |
| `active_memory.enabled`, `active_memory.top_k`, `active_memory.chunk_max_bytes` | Existing safe-write active-memory tuning keys. | Researcher/writer personas may propose memory tuning after explicit review. |
| `runtime.diagnostics_verbosity` | Existing safe-write enum: `quiet`, `normal`, `verbose`. | Ops persona may propose verbosity, without enabling new authority. |
| `objectives.trace_detail` | Existing safe-write enum: `operator`, `debug`. | Ops persona may propose trace detail, without changing objective authority. |
| Objective defaults | Partly covered by existing `objectives.*` keys. | v0.63 must pick exact keys and values; no fuzzy "objective defaults" seed writes. |
| Suggested apps/channels/intents | Not Settings writes by themselves. | Keep as UI suggestions until the operator configures apps/channels/intents through existing confirmations. |

Open v0.63 decisions: exact seeded values, per-persona default/opt-out behavior,
whether any active-memory or objective defaults are proposed in QuickStart, and
the review diff copy for hosted-egress/model-profile warnings. Any key not named
as an existing safe-write key above must be treated as a v0.63 schema/design
decision before implementation.

## Review/Confirm Application Model

Before applying a persona, v0.63 must show a review diff with:

- Settings Central keys or key families and proposed values.
- Suggested apps/channels/intents that will become visible or highlighted.
- Model-purpose mapping advice and any hosted-egress warnings, explicitly marked
  as post-first-chat seed recommendations rather than QuickStart model-pull
  requirements.
- Secrets or provider keys required later, all marked as not yet stored unless
  the operator enters them through the OS vault path.
- Permission statement: no capability, egress, filesystem, channel, MCP,
  package-install, or confirmation-decision authority is granted by the persona.

The operator can confirm, edit, or skip. Skipping a persona must not block first
useful chat.

## Guardrails

- Personas are seed-only defaults and suggestions.
- Personas are repo-maintained and reviewed; they are not learned from traces or
  generated by a model.
- Personas do not replace Settings Central, Security Central, or confirmations.
- Personas do not enable channels, providers, MCP servers, tools, or external
  network access by themselves.
- Personas do not write secrets or raw endpoints.
- Personas do not add model-install requirements to QuickStart before first
  useful chat.
- Personas do not change daily-use runtime behavior by themselves.
- Existing free-text identity or memory files are not persona definitions.

## Handoff To v0.63

v0.63 implements the persona registry, review UI, settings-write action, and
onboarding integration. The implementation must keep this review/confirm model
and seed-only authority boundary intact. v0.60 does not create the registry or
seed files; it only provides the v0.63 design input.
