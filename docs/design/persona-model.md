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

## Persona Seeds

| persona_id | Settings seed families | Suggested apps/channels/intents | Model-purpose mapping | First useful chat examples |
|---|---|---|---|---|
| `general` | `operator.communication_style`, `operator.handoff_detail`, `model_preferences.primary`, objective defaults. | Workspace, Models, Settings, TUI; direct answer, remember/recall memory, objectives. | Main conversational loop local-first; ADR 0072 defaults unless operator chooses hosted. | "Help me understand what Allbert can do locally." / "Summarize my current setup." |
| `researcher` | `operator.communication_style`, active-memory tuning, `model_preferences.primary`, intent router profiles. | Notes/files, browser or MCP resource reads when configured, mail/calendar optional; summarize, extract, compare, remember citation notes. | Embedding local required; main loop `:capable` or `:thinking`; hosted research only by explicit egress opt-in. | "Summarize these notes into claims and open questions." / "Compare two sources and list evidence." |
| `developer` | `coding.model_profile`, `coding.default_approval_mode`, coding read/search limits, `model_preferences.tasks.coding`, intent router profiles. | GitHub, notes/files, TUI/Pi-mode, plan preview; read/grep/glob, plan, code review, remember project facts. | Pi-mode coding profile from ADR 0072; local/private preferred, hosted coding only after source-code egress opt-in. | "Read this repo and propose the smallest safe fix." / "Review this change for regressions." |
| `writer` | `operator.communication_style`, `operator.handoff_detail`, active-memory tuning, `model_preferences.primary`. | Notes/files, mail, image generation only when configured; draft, revise, outline, summarize. | Main loop `:capable`; advisory critics optional; image generation remains provider-confirmed. | "Turn these rough notes into an outline." / "Rewrite this with a clearer voice." |
| `ops` | `runtime.diagnostics_verbosity`, `objectives.trace_detail`, `model_preferences.primary`, intent router profiles. | Jobs, Objectives, Calendar/Mail/GitHub panels, channel setup later; status, doctor, triage, plan/run monitoring. | Fast local model for status/triage, escalation profile for complex incidents, hosted only by explicit egress opt-in. | "Give me an operator status brief." / "Triage these pending jobs and blockers." |

Exact seeded values are finalized in v0.63 after a Settings Central schema audit.
This v0.60 design fixes the persona categories, seed groups, review shape, and
per-persona intent so the implementation cannot drift back to an undifferentiated
settings tour.

## Review/Confirm Application Model

Before applying a persona, v0.63 must show a review diff with:

- Settings Central keys or key families and proposed values.
- Suggested apps/channels/intents that will become visible or highlighted.
- Model-purpose mapping advice and any hosted-egress warnings.
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
- Existing free-text identity or memory files are not persona definitions.

## Handoff To v0.63

v0.63 implements the persona registry, review UI, settings-write action, and
onboarding integration. The implementation must keep this review/confirm model
and seed-only authority boundary intact. v0.60 does not create the registry or
seed files; it only provides the v0.63 design input.
