# Onboarding Flow

Status: v0.60 M4 design artifact and v0.63 design input. This document defines
the two-track wizard UX for ADR 0069. It is design only: v0.60 builds no wizard,
adds no Settings key, writes no secret, and seeds no profile.

## Product Goal

Onboarding turns a clean Allbert Home into first useful chat with the fewest
decisions that still preserve operator trust. It should explain the local-first
posture, verify a model path, apply a reviewed persona/profile only when the
operator confirms it, and leave optional channel setup for later unless the
operator chooses the Advanced path.

The wizard has two tracks:

- QuickStart: fastest first chat, assisted-local by default, BYOK fallback,
  minimal choices, channel setup skipped.
- Advanced: explicit provider/model/profile/channel choices before first chat.

Both tracks are v0.63 implementation inputs. The same flow powers the web wizard
and the CLI/TUI wizard; surfaces may differ, but the step semantics do not fork.

## Surfaces

| Surface | Role | Design requirement |
|---|---|---|
| Web wizard | Primary onboarding surface, launched from first-run / launch / empty state. | Renders through the v0.58 catalog/shell and v0.61 screen composition; shows progress, model state, profile review, and first useful chat checkpoint. |
| CLI/TUI wizard | Mix-free terminal path for operators who start from `allbert` or TUI. | Uses the same step IDs and state transitions; prompts and verifies in place rather than printing copy-paste commands. |
| Workspace | First useful chat checkpoint and post-onboarding continuation. | Chat-primary; visible provider/model status; no hidden authority. |
| Settings/Models/Trust surfaces | Review and repair surfaces, not the first screen. | Linked from wizard when needed; never replace the guided path with a raw settings grid. |

## Step Sequence

| step_id | Step | QuickStart behavior | Advanced behavior | Writes in v0.63 |
|---|---|---|---|---|
| `welcome` | Welcome / resume | Explain local-first posture, Allbert Home, and first useful chat goal. | Same, plus explicit path chooser. | None. |
| `track_select` | Choose track | Default selected; one sentence of what will happen. | Operator chooses full-control setup. | None. |
| `model_path` | First-Model Path | Map first-model probes to operator readiness: Ready -> continue; Needs runtime/model -> guided repair; Needs credentials -> BYOK/custom endpoint. This establishes the chat-capable path only; it does not pull persona-specific model tiers. | Operator can choose local runtime, existing endpoint, or hosted BYOK up front. | New secrets write through OS vault or encrypted-store fallback; env-provided secrets are read-only; model/provider settings through Settings Central after review. |
| `profile_select` | Persona/profile | Offer `general` by default plus one quick role picker after the model path is usable; do not apply silently. | Full persona selection with seed detail visible. | None until review/confirm. |
| `profile_review` | Review seeds | Compact diff: settings seeds, suggested apps/channels/intents, model-purpose mapping as post-first-chat recommendation, no permissions granted. | Full diff with per-section opt-out. | Applies only after explicit confirm. |
| `health_check` | Verify setup | Run model/provider health check and show repairable blockers. | Run selected provider/model/channel checks. | No authority change; diagnostic evidence only. |
| `first_chat` | First useful chat | Open workspace with a suggested first prompt and visible model/provider/trust status. | Same, using chosen path. | Conversation/runtime behavior happens through existing runtime. |
| `optional_connect` | Optional extensions | Deferred until after first useful chat. | Operator may connect channels/apps before or after first chat. | Channel/app setup uses existing confirmations and settings writes. |

## QuickStart UX

QuickStart is the default for an empty-handed first-run operator:

1. State the goal: get to first useful chat locally if possible.
2. Detect first-model state from M3.
3. Prefer assisted-local setup through guided Ollama install and curated model
   pull when needed.
4. Keep BYOK fallback visible for hardware blockers, declined install, or local
   runtime failures.
5. Ask for a persona only after the model path is usable, as a reviewed preset
   choice, defaulting to `general` when the operator wants the fastest path.
6. Show a compact profile review before any settings seed is applied.
7. Land in the workspace and complete first useful chat before suggesting
   channels or deep settings work.

QuickStart must not end at "setup complete" without a model-backed conversation
or a specific repairable blocker.

## Advanced UX

Advanced is for operators who know their provider, local runtime, profile, or
channel needs:

1. Choose local runtime, existing endpoint, or hosted BYOK.
2. Choose or skip a persona/profile.
3. Review the complete seed diff.
4. Optionally configure apps/channels before first chat.
5. Run health checks for each selected provider/channel.
6. Continue to first useful chat with explicit egress and trust context.

Advanced exposes control without making QuickStart feel incomplete.

## Review And Confirmation

The review step is mandatory before any persona/profile seed is applied. It shows:

- Settings Central keys or key families that will be written.
- Suggested apps, channels, and intents that will be highlighted.
- Model-purpose mappings referenced from ADR 0072.
- Model-purpose mappings are seed recommendations for later defaults, not extra
  model-pull requirements before first useful chat.
- Secrets required for BYOK or channels, with OS-vault storage called out.
- A clear statement that profiles do not grant permission, egress, channel
  authority, file access, or confirmation bypass.

The review step may be compact in QuickStart and detailed in Advanced, but both
tracks require explicit operator confirmation in v0.63.

## Failure And Repair States

The `model_path` step maps technical first-model probe results to simple
operator-facing readiness labels. Surfaces show the operator label and one next
action; raw probe atoms stay in traces/tests/diagnostics.

| Technical probe result | Operator readiness | Wizard response |
|---|---|
| `local_ready` | `Ready` | Continue to first useful chat with local/provider status visible. |
| `runtime_missing` | `Needs runtime` | Offer guided runtime install and keep BYOK fallback visible. |
| `runtime_unhealthy` | `Needs runtime` | Show runtime repair guidance and keep BYOK fallback visible. |
| `model_missing` | `Needs model` | Offer curated model pull with progress/retry/resume. |
| `below_hardware_floor` | `Needs credentials` | Explain the local blocker and recommend BYOK or an existing endpoint. |
| `byok_ready` | `Ready` | Continue to first useful chat with egress posture visible. |
| Profile not reviewed | `Needs review` | Show the profile review diff or allow continuing with unseeded defaults. |

Other onboarding outcomes are not first-model states:

| Outcome | Wizard response |
|---|---|
| BYOK key invalid | Keep key redacted, show provider doctor result, allow retry or local path. |
| Profile review declined | Continue with unseeded defaults; do not block first useful chat. |
| Channel setup failed | Defer channel setup; do not block first useful chat. |

## Handoff To v0.63

v0.63 implements this flow as the ADR 0069 guided onboarding capability. It must
drive all writes through Settings Central, new secrets through OS vault or
encrypted-store fallback with env as read-only detected input, all effectful setup
through registered actions and confirmations, and all model state through the
First-Model Path contract from `docs/design/first-model-path.md`.
The `model_path` step comes before persona selection so QuickStart can reach first
useful chat on the curated local/BYOK path; persona `model_purpose_map` entries
are reviewed seed advice after that path is usable, not a second hidden model
setup gate.

v0.60 M4 is complete when this document and `docs/design/persona-model.md` are
present as v0.63 design inputs and no v0.60 code, settings, wizard, or profile
implementation exists.
