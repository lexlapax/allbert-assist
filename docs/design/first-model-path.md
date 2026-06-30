# First-Model Path

Status: v0.60 M3 design artifact. This document expands ADR 0078 into the
QuickStart path, option analysis, first-model-state handoff, and v0.62/v0.63
packaging/onboarding implications. It is design only; v0.60 does not install,
pull, configure, or call any model.

## Decision Summary

The v0.60 First-Model Path is:

- QuickStart default: assisted-local model through detect + guided Ollama install
  and a curated model pull.
- Advanced and fallback: honest BYOK, including hosted-provider keys or an
  existing local endpoint.
- Rejected: managed-hosted default through an Allbert-operated relay.

The product promise is first useful chat without surprise egress or hidden
permission. Local first is the default because it best demonstrates Allbert's
trust posture. BYOK exists so the operator is not blocked when local model setup
is unavailable, declined, or below the hardware floor.

## First Useful Chat Contract

QuickStart succeeds when the operator can:

1. Start from a clean Allbert Home.
2. Reach the model setup path from first-run or onboarding.
3. Use an assisted-local model by default, or BYOK fallback when local setup is
   blocked.
4. Ask a task-relevant question in the product workspace.
5. Receive a useful answer with visible model/provider status and no new hidden
   authority.

This is the M1 first-value moment made concrete. A provider response alone is not
enough; the surface must also show the operator why the path is local or BYOK,
what egress posture applies, and what safe next action is available.

## Option Analysis

| Option | First-run value | Trust posture | Product cost | Decision |
|---|---|---|---|---|
| Assisted-local default | Strong: empty-handed operators can reach chat without a hosted key. | Best match for local-first: no default egress, no hosted credential dependency. | Requires v0.62 to detect Ollama, guide install, pull a curated model, and explain hardware blockers. | Chosen for QuickStart. |
| Honest BYOK | Moderate: fast if the operator already has a key or endpoint. | Clear if egress is explicit and keys use the OS vault. | Uses existing provider abstractions and secret storage path; weaker zero-config story. | Chosen for Advanced and fallback. |
| Managed-hosted default | Strongest apparent first-run speed. | Weak fit: default egress and Allbert-operated relay obscure local-first value. | Requires perpetual service, cost, abuse, credential, and availability ownership. | Rejected. |

## QuickStart Path

QuickStart is a guided state path, not a raw settings page:

1. Detect whether a supported local model runtime is already available.
2. If Ollama is present and healthy, detect whether the curated default model is
   pulled.
3. If the curated model is missing, offer a one-action pull with clear download
   size, progress, retry, and resume behavior.
4. If Ollama is missing, offer guided install through the packaged v0.62 path.
   Allbert does not bundle the Ollama runtime into the `allbert` binary.
5. If the machine is below the curated model hardware floor, the install is
   blocked, the operator declines local setup, or Ollama remains unavailable,
   route to BYOK fallback.
6. BYOK fallback explains egress plainly, stores keys only through the OS
   secret-vault path, and lets the operator point at an existing local endpoint
   when available.
7. After a model path is ready, the operator lands in the first useful chat
   checkpoint instead of an abstract "setup complete" page.

The curated default model is selected in v0.62, not v0.60. v0.60 records the
selection criteria: open-weight, runs on typical technical-prosumer hardware,
modest download weight, acceptable latency for first chat, compatible with the
provider abstraction, and reviewed against ADR 0072's per-purpose recommendation
matrix. The chosen model may be refreshed by packaging docs/gates when public
tags or hardware expectations change.

The curated default model is the only QuickStart model requirement before first
useful chat. Persona-specific `model_purpose_map` recommendations from
`docs/design/persona-model.md` are reviewed after the first model path is ready;
they are seed advice for later defaults, not extra model-pull requirements for
the initial chat. If a persona recommends embeddings, `:capable`, `:thinking`, or
Pi-mode model profiles, v0.63 may surface that as a follow-on readiness check or
Advanced-track choice, but QuickStart must not block first useful chat on those
persona tiers.

## First-Model State Handoff

M5 entry-point design and v0.62 packaging should be able to reason in these
operator-facing states:

| State | Meaning | Product response |
|---|---|---|
| `local_ready` | Local runtime and curated model are available. | Continue directly to first useful chat. |
| `runtime_missing` | Ollama or equivalent chosen runtime is absent. | Offer guided install; keep BYOK fallback visible. |
| `runtime_unhealthy` | Runtime exists but does not pass health checks. | Show repair steps and BYOK fallback. |
| `model_missing` | Runtime is healthy but the curated model is not pulled. | Offer pull with progress/retry; keep BYOK fallback visible. |
| `below_hardware_floor` | The machine should not be asked to run the curated default. | Recommend BYOK or existing endpoint; do not shame the machine or loop install. |
| `byok_ready` | A hosted key or existing endpoint is configured and healthy. | Continue to first useful chat with egress posture visible. |
| `blocked` | No local or BYOK path is currently ready. | Present the smallest repair choice and preserve the option to skip setup. |

These are design states, not new Settings Central keys. v0.62/v0.63 may choose the
actual read model and persistence shape, subject to Security Central and Settings
Central.

## v0.62 Packaging Implications

The packaging release must implement the parts of QuickStart that cannot be
retrofit after the binary exists:

- Detect a local model runtime from the packaged `allbert` context without
  requiring a source checkout or Mix task.
- Guide Ollama installation through the supported package path instead of bundling
  Ollama into the Allbert binary.
- Pull the curated default model with visible progress, retry, resume, and
  failure output.
- Keep the curated default model configurable and refreshable; do not freeze a
  stale model tag in v0.60 docs or code.
- Expose a first-model-state check that first-run, onboarding, and CLI/TUI can
  consume consistently.
- Store BYOK credentials through the OS secret-vault path; never print secrets,
  raw endpoints, or provider tokens in CLI, web, traces, or release evidence.
- Provide a health check that can distinguish runtime missing, runtime unhealthy,
  model missing, below hardware floor, BYOK ready, and blocked.
- Keep all effectful setup actions confirmation- and policy-bounded; setup copy
  never grants authority by itself.

The seven first-model states in this document are the v0.60 design/test handoff
contract. They are intentionally enforced by the v0.60 docs/eval sweep, not by a
new runtime source of truth in this design release. v0.62 packaging and v0.63
onboarding must introduce or consume a runtime source without inventing divergent
labels.

## v0.61 And v0.63 Handoff

v0.61 presentation work consumes this path for launch, empty-state, model-status,
and first useful chat surfaces. The screen should present local-first QuickStart
as the default and BYOK as a clear alternative, without turning first-run into a
settings grid.

v0.63 onboarding consumes this path for the QuickStart and Advanced branches.
QuickStart tries assisted-local first, falls back to BYOK, and only claims
onboarding success when the operator reaches first useful chat or receives a
specific repairable blocker. Persona/profile review happens after the first-model
path has established a usable chat path; persona model-purpose mappings are
advisory seed recommendations and must not retroactively change the QuickStart
curated model requirement.

v0.64 validates install -> first-run -> onboard -> first useful chat against the
implemented v0.61-v0.63 surfaces and records evidence that the path did not drift
back to BYOK-only or managed-hosted.

## Guardrails

- No managed-hosted relay is introduced by implication.
- No model runtime is bundled into `allbert` by v0.60 decision text.
- No concrete default model tag is pinned in v0.60.
- No local model path grants tool, filesystem, egress, or channel authority.
- No BYOK key is accepted outside the secret-vault path.
- No surface treats "setup complete" as equivalent to first useful chat.
