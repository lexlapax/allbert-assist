# ADR 0087: Zero-Click First Run And Detection-Based Enablement

## Status

Proposed (v1.2 planning, 2026-07-24; amended by the third implementation-
readiness pass 2026-07-26, finalized by operator direction — §1 gains the
availability-first/local-preferred projection and the per-key
multi-key write rule, §4 gains the `runtime_unhealthy` and
`enabled_unavailable` rows and the hosted-key qualifiers, §5 gains the
wizard-completion decoupling). Binding on v1.2 M1a–M3 (ADR 0088 carries
M4–M5); flips Accepted at
the v1.2 milestone that proves the detection→enablement→disclosure chain on
web, TUI, and CLI together (`docs/plans/v1.2-plan.md`). This is a **consent
ADR**: it deliberately redefines the enablement point that ADR 0078's v0.63
M8.5 amendment placed inside the onboarding wizard, and it redefines the
first-run acceptance criteria (DIT-2 class) that assert QuickStart enables
direct answers before the first question.

Related: ADR 0078 (First-Model Path — the assisted-local default, BYOK
fallback, no-managed-hosted rejection, and the v1.0.5 configured-endpoint
local-readiness amendment all stand; this ADR moves only the *enablement
point*), ADR 0069 (Guided Onboarding — the wizard remains, demoted from
mandatory gate to optional step-addressable customization surface), ADR 0088
(model catalog/chooser + fallback policy — supplies the selection and
degradation machinery the detect states consume), ADR 0072 (recommended
model profiles per purpose), ADR 0075 (persona profiles — persona seeds still
flip the same keys), ADR 0006 (Security Central — unchanged), ADR 0031
(Settings Central — all writes remain safe-write-key writes).

## Context

Through v1.1, first-run chat is gated twice:

- **Soft gate (web/CLI ask):** `intent.direct_answer_model_enabled` defaults
  `false` (`settings/schema.ex:735-740`); until something flips it,
  `direct_answer` returns the deterministic `:model_disabled` fallback
  (`actions/intent/direct_answer.ex:96-101`). The flip sites are the wizard
  (`Onboarding.maybe_enable_model_answer/2`, `onboarding.ex:303-316`, gated on
  readiness `:ready` per ADR 0078 M8.5) and persona application (every shipped
  persona seeds the key `true` through the confirmation-gated
  `apply_persona_profile`).
- **Hard gate (packaged TUI):** `CLI.Tui.readiness_guard/1`
  (`cli/tui.ex:69-101`) refuses to start the TUI at all unless
  `FirstRun.detect_details().state == :product_ready`. The dev entry
  `mix allbert.tui` has no such guard — packaged and dev behavior diverge.

Meanwhile **detection already exists and already runs**: bare `allbert`, the
web auto-open decision, and the wizard all execute the bounded read-only probe
chain — configured local provider via `ModelDoctor.diagnose/2`
(`cli/first_run.ex:251-261`), localhost Ollama discovery
(`first_model/ollama.ex:87-100`: binary / `GET /api/version` / curated tag in
`GET /api/tags`), and BYOK key presence
(`cli/first_run.ex:232-237`). The system routinely *knows* a working model is
reachable and still refuses to answer with it until the operator walks a
wizard. For the non-developer operator this is the inverted priority the
comparison class (LM Studio, Jan) does not have: install, open, chat.

The backlog entry (`future-features.md:542-583`) names the tension precisely:
auto-enabling on detection needs deliberate redefinition of (a) the consent
semantics around `intent.direct_answer_model_enabled`, (b) the detect-state
matrix — what "chat-ready" means when no model is present — and (c) the DIT-2
acceptance criteria. This ADR is that redefinition.

Operator decision (2026-07-24, v1.2 planning): **auto-enable on any detected
configured provider — local or already-configured hosted** — not only
local-only auto-enable, and not a one-keystroke confirm.

## Decision

**Detection is enablement. Provisioning is consent.** If the operator has
already provisioned a way to run a model — a local runtime with a usable
model, a configured local endpoint, or a hosted provider key they entered —
Allbert treats that provisioning as the operative consent, auto-selects a
model profile, enables direct answers, and is chat-ready immediately. The
separate wizard-owned enable step is retired as a gate.

### 1. The detection→enablement rule

On first run and on every boot while unconfigured, Allbert runs the existing
bounded read-only detection chain and resolves the **first usable** hit in
strict local-first order:

1. configured local provider (`model_preferences.primary` →
   `ModelDoctor.diagnose/2`, `endpoint_kind: :local_endpoint` — the v1.0.5
   amendment's rule, unchanged);
2. discoverable localhost Ollama with the curated or any usable pulled model;
3. an already-configured hosted provider (vaulted key or provider env var
   present).

A hit auto-writes, through the ordinary audited safe-write path: the selected
profile (when none is set) and `intent.direct_answer_model_enabled = true`
(plus `intent.model_assist_enabled`, matching the wizard's existing pair).
The write records detection provenance in the audit trail
(`enabled_by: detection`, profile, provider class local|hosted).

“Absent” means absent from the raw operator settings map, not the effective
default-merged value. The check and conditional write execute under one
Settings StoreLock-owned transaction; a separate read followed by a write is
forbidden. Concurrent explicit `false` wins and remains sticky.

First-run selection cannot wait for the later chooser. A minimal deterministic
usable-local-model predicate ships with enablement and is reused by the catalog:
doctor-healthy configured local first, then the curated pulled tag, then a
compatible pulled text-generation model if M0 can define that compatibility
without guessing. Otherwise detection remains curated-tag-only. Hosted key
presence is configured-but-unverified, not “reachable”; provider priority is
explicit primary, task candidate order, then one stable documented order.

**Local always outranks hosted.** When both are detected, the local profile
is selected. ADR 0078's local-first posture and its rejection of a managed
hosted default are unchanged.

**Availability-first, local-preferred projection (final readiness decision,
operator 2026-07-26).** A healthy local rung always wins. When a local runtime
is detected but currently unusable (`model_missing`, `runtime_unhealthy`, or
`below_hardware_floor`) and a hosted key is configured, detection selects the
hosted profile so the first question still receives a model answer. The
pre-egress disclosure remains mandatory; local pull/restart/hardware guidance
is secondary and never blocks chat. Without a hosted key, those same states
remain honest repair states with one primary CTA. Detection itself still
performs no hosted probe or egress.

**Stickiness is per key across the whole write set.**
`intent.direct_answer_model_enabled` decides whether enablement runs at all;
`intent.model_assist_enabled` and the selected profile are each written only
when raw-absent. An explicitly stored value on any of the three survives
detection, and the provenance row records which keys were written and which
were already present. The raw-absent subset is applied atomically. Because the
Settings `StoreLock` is not reentrant, the compare-and-write primitive is
multi-key by construction: one lock, one raw read, one validation, one write,
one audit row per applied key, and one transaction provenance envelope naming
applied and preserved keys. A validation failure writes none of the subset.

### 2. What auto-enablement may and may not do

- **Detection reads; it never provisions.** The probe chain contacts only the
  local runtime and operator-configured endpoints, exactly as today. It never
  installs a runtime, pulls a model, writes a provider key, or performs
  hosted egress. Hosted "detection" is key **presence**, not a hosted probe —
  detection itself is egress-free.
- **Entering a hosted key remains an explicit act** through the existing
  vault/credential surfaces. Nothing in this ADR configures a provider on the
  operator's behalf; it only stops ignoring providers the operator already
  configured.
- **Model pulls stay one-click, never zero-click.** A detected runtime with
  no usable model (`detected_needs_model` below) offers the existing
  confirmation-gated one-click pull; a multi-gigabyte download is never a
  silent side effect of opening the app.
- **Explicit operator `false` is sticky.** Auto-enablement fires only when
  the key is *absent* (schema default). If the operator ever wrote
  `intent.direct_answer_model_enabled = false`, detection never overrides it
  (the v1.1 LD32 absent-key-vs-stored-value pattern). Disabling once means
  disabled until the operator re-enables.

### 3. Disclosure, not confirmation

The first auto-enabled session on each surface carries a durable disclosure
(normally once, not a modal):

- **which** profile/provider was selected and **why** ("detected running
  Ollama with llama3.2:3b" / "detected your configured OpenAI key");
- **where inference runs** — on-device for local; for a hosted selection, an
  explicit egress notice naming the provider **before the first message is
  sent**;
- **how to change or revert** — the ADR 0088 chooser, and the one-command
  revert (`allbert settings set intent.direct_answer_model_enabled false`).

Web (chat surface), TUI (banner), and CLI (`allbert` first-run output, including
one-shot `allbert ask`) all render it. Disclosure text is generated from the
audit provenance, so what is shown is what was done. For hosted inference the
marker is `pending` until the surface acknowledges rendering; transport
admission requires `acknowledged`. A crash before acknowledgement may repeat
the disclosure but cannot send the prompt first. Local inference is not gated
by this egress acknowledgement.

### 4. The redefined detect-state matrix

"Chat-ready" no longer means "a model answers"; it means **the chat surface
is open, honest about its current capability, and never a dead end**:

| Detect state | Meaning | First-run behavior |
|---|---|---|
| `detected_ready` | local ready, or any unusable/absent local state with a hosted key present | auto-enable per §1; local wins when healthy, otherwise hosted answers; disclosure shown |
| `detected_needs_model` | local runtime healthy, no usable model, no hosted key | chat opens with deterministic fallback; single primary CTA: one-click curated pull (existing progress surface); BYOK secondary |
| `runtime_unhealthy` | local runtime reachable but failing, no hosted key | chat opens with deterministic fallback; single primary CTA: restart/repair the local runtime; BYOK secondary |
| `nothing_detected` | no runtime, no endpoint, no key | chat opens with deterministic fallback; single primary CTA: guided install / BYOK (ADR 0078 repair paths) |
| `below_floor` | hardware below curated floor, no hosted key | chat opens with fallback; BYOK-first guidance (ADR 0078 degrade path) |
| `enabled_unavailable` | consent key already `true` from an earlier detection, but the provider it selected is gone | chat opens with the honest unavailable text and the repair CTA of the underlying state; the disclosure is not re-shown |

These are presentations of the existing six first-model states
(`cli/first_run.ex:42-49`); no parallel state machine is introduced. The
binding cell-by-cell derivation (six `model_state` values × hosted-key
presence) lives in `docs/plans/v1.2-request-flow.md` §D.0 and every cell
carries a regression.

### 5. Onboarding becomes optional and step-addressable

- The wizard (ADR 0069) survives as a **customization surface**: always
  available, every step directly addressable at any time — including after
  completion — generalizing the shipped `wizard_rewind` step navigation.
  Rewinding or re-entering a step never revokes enablement and never
  re-gates chat (today rewind clears `onboarding_complete`, which would
  re-trigger the auto-open and the TUI block; that coupling is removed).
- `onboarding_complete` stops gating anything user-facing, and **wizard
  completion is decoupled from consent** (third readiness pass, operator
  2026-07-26). `first_chat_ready?/1` today requires readiness `:ready` AND
  `intent.direct_answer_model_enabled == true`, so a Home carrying an
  operator-stored `false` could never finish the wizard — a permanent dead end
  of exactly the class §4 removes. Completion requires only a genuinely ready
  model path; the model step records an explicit decline and carries a
  one-time "re-enable model answers?" affordance that never nags again. The
  ADR 0069 false-complete rule is preserved in its real sense: the wizard
  still cannot claim complete while readiness is non-ready.
- The TUI
  `readiness_guard` hard block is inverted: the TUI always starts, and
  non-ready detect states render as in-TUI guidance instead of an stderr
  refusal. `mix allbert.tui` (dev) and `allbert tui` (packaged) adopt the
  same posture — the current divergence is closed.
- The QuickStart and persona flip sites remain and stay idempotent; personas
  still seed the same keys through the same confirmation-gated action.

### 6. Acceptance criteria (DIT-2 class) are redefined

The v1.0 criterion "QuickStart enables direct answers before the first
question" is retired. The v1.2 criteria:

- fresh Home + any reachable provisioned provider → the **first question is
  answered by the model with zero prior clicks**, and the disclosure is
  visible. "Reachable provisioned" means a §4 `detected_ready` cell; an
  unusable local runtime does not mask a configured hosted provider;
- fresh Home + nothing provisioned → the chat surface still opens, the
  deterministic fallback answers, and exactly one repair CTA per §4 is
  presented — zero clicks to a working (fallback) chat, no wizard wall;
- an operator-stored `false` is never overridden by detection.

## Consequences

- The first-impression path matches the zero-config bar the First-Model Path
  ADR set out to meet: install, open, chat — with the wizard as an upgrade
  path rather than a toll gate.
- The consent line moves from a per-feature toggle to the provisioning act.
  This is a deliberate relaxation for **already-provisioned** providers,
  including hosted ones: an operator who entered an OpenAI key gets model
  answers over that key without a second enable step. The disclosure banner
  and sticky explicit-`false` are the compensating controls; initial key
  entry and all credential custody are unchanged.
- Boot-time detection inherits the known ordering hazards (`:req` started
  before probing, fresh-process settings reads — the v1.0.5 RC.2 lessons);
  the v1.2 plan carries them as named acceptance rows rather than rediscovery.
- Surfaces asserting the old gating (onboarding tests, DIT-2 docs,
  `first_chat_ready?` consumers, web auto-open policy) all change with it;
  the v1.2 plan enumerates them.

## Non-goals and guardrails

- **No new authority, no new egress class.** Enablement flags are existing
  safe-write keys; selection writes go through Settings Central; every action
  still resolves through `Actions.Registry` + `Runner.run/3`. Detection
  performs no hosted egress. Security Central and the vault model are
  untouched (ADR 0078 guardrails restated).
- **No managed hosted default** — the ADR 0078 rejection stands.
- **No silent provisioning**: no runtime installs, no model pulls, no key
  writes, ever, from detection.
- **No silent runtime failover.** This ADR covers first-run enablement and
  selection only; mid-conversation provider failover is ADR 0088's policy
  and is opt-in there.
- Removal of the legacy gating keys or wizard steps is out of scope — v1.2
  is additive-only; nothing here requires a non-additive migration.
