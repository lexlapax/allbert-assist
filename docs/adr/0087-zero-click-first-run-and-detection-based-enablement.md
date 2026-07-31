# ADR 0087: Zero-Click First Run And Detection-Based Enablement

## Status

Accepted (v1.2 M2, 2026-07-26; v1.2 M9 launcher correction binding and proved
2026-07-27; v1.2.5 daemon-session process-ownership amendment accepted
2026-07-28; proposed 2026-07-24 and amended by the third implementation-
readiness pass 2026-07-26, finalized by operator direction — §1 gains the
availability-first/local-preferred projection and the per-key
multi-key write rule, and the 2026-07-27 FV-01/M9 correction adds the bounded
local-TUI launcher enablement and identity bootstrap, §4 gains the
`runtime_unhealthy` and `enabled_unavailable` rows and the hosted-key
qualifiers, §5 gains the wizard-completion decoupling). Binding on v1.2 M1a–M3
and the M9 correction (ADR 0088 carries M4–M5). M2 proved the
detection→enablement→disclosure chain
on web, TUI, and CLI together; M9 proved the shared packaged/development
pre-adapter launcher correction (`docs/plans/archives/v1.2-plan.md`). This is a **consent
ADR**: it deliberately redefines the enablement point that ADR 0078's v0.63
M8.5 amendment placed inside the onboarding wizard, and it redefines the
first-run acceptance criteria (DIT-2 class) that assert QuickStart enables
direct answers before the first question.

v1.3 M9.b.3 amendment (2026-07-31): first-model substrate detection and
DirectAnswer task readiness are evaluated separately. The global
`local`/curated model remains `llama3.2:3b`; DirectAnswer defaults to the
qualified `direct_answer_local` / `qwen2.5:7b` task profile. The task chain,
not an unrelated global primary or hosted key, owns DirectAnswer selection.

Related: ADR 0078 (First-Model Path — the assisted-local default, BYOK
fallback, no-managed-hosted rejection, and the v1.0.5 configured-endpoint
local-readiness amendment all stand; this ADR moves only the *enablement
point*), ADR 0069 (Guided Onboarding — the wizard remains, demoted from
mandatory gate to optional step-addressable customization surface), ADR 0088
(model catalog/chooser + fallback policy — supplies the selection and
degradation machinery the detect states consume), ADR 0072 (recommended
model profiles per purpose), ADR 0075 (persona profiles — persona seeds still
flip the same keys), ADR 0006 (Security Central — unchanged), ADR 0031
(Settings Central — all writes remain safe-write-key writes), ADR 0016 and ADR
0067 (their 2026-07-27 v1.2 M9 amendments bind the local TUI channel and
identity boundary used by §1a), ADR 0091 (moves §1a execution into authenticated
daemon-session admission without changing its consent or identity semantics).

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
bounded read-only detection chain. It first derives the existing six-state
first-model substrate result from the global/curated path, then independently
resolves the head of `model_preferences.tasks.direct_answer`. The global path
still uses strict local-first order:

1. configured local provider (`model_preferences.primary` →
   `ModelDoctor.diagnose/2`, `endpoint_kind: :local_endpoint` — the v1.0.5
   amendment's rule, unchanged);
2. discoverable localhost Ollama with the curated or any usable pulled model;
3. an already-configured hosted provider (vaulted key or provider env var
   present).

A DirectAnswer-task hit auto-writes, through the ordinary audited safe-write
path, the task preference when raw-absent and
`intent.direct_answer_model_enabled = true` (plus
`intent.model_assist_enabled`, matching the wizard's existing pair). It does
not rewrite the global primary. The write records detection provenance in the
audit trail (`enabled_by: detection`, profile, provider class local|hosted).

“Absent” means absent from the raw operator settings map, not the effective
default-merged value. The check and conditional write execute under one
Settings StoreLock-owned transaction; a separate read followed by a write is
forbidden. Concurrent explicit `false` wins and remains sticky. If consent
becomes explicitly false or the DirectAnswer task head changes between
selection and the Store lock, the transaction applies none of the enablement
subset and the pending disclosure is cancelled; stale selection may never
enable transport.
A concurrent explicit `true` with the same selected route retains the pending
marker, preferring a repeated disclosure over undisclosed hosted egress.

First-run selection cannot wait for the later chooser. The existing global
substrate detector still checks configured local, curated pulled, and bounded
compatible local rungs. DirectAnswer readiness is deliberately narrower: it
doctors the exact task head (or the empty-list compatibility primary) and
abstains rather than substituting another pulled model. Hosted key presence is
configured-but-unverified, not “reachable”; provider priority for DirectAnswer
is its explicit task order.

**Automatic selection is local-first; explicit task order is binding.** A
non-empty DirectAnswer list is a closed chain in authored order. Its head must
be the exact usable profile selected and disclosed; an explicitly authored
hosted head may therefore outrank a newly ready local model. If the head is not
usable, enablement abstains and projects `enabled_unavailable` instead of
appending the global primary or an unrelated configured provider. Only an
empty task list retains the legacy primary compatibility fallback. ADR 0078's
rejection of a managed hosted default is unchanged.

### 1a. Local TUI launcher bootstrap

Zero-click TUI chat also requires admission identity, not only model
enablement. Immediately before starting the adapter, the packaged and
development local interactive launchers run one Settings Central
compare-and-write. If `channels.tui.enabled` is raw-absent, the operation writes
`true`. If the effective terminal profile is the built-in `default` and
`channels.tui.identity_map` is also raw-absent, it writes the ordinary
list-shaped `default → local` entry in the same atomic operation. If only one
eligible key is absent, only that key is written. The values are validated and
audited through Settings Central; concurrent first launches converge on the
same durable state.

A raw explicit `channels.tui.enabled = false` is authoritative: the launcher
performs no identity-map write, blocks before Adapter startup, and renders
bounded guidance to set the channel enabled again. Raw-present identity maps
(including empty, custom, or disabled entries) and custom terminal profiles are
also authoritative and are never replaced or merged. Generic adapter startup
does not bootstrap. The adapter receives no identity override: normal turns and
identity-requiring slash commands continue through
`Channels.Identity.resolve/3`, and an unmapped/disabled turn is visibly rejected
before runtime admission.

`channels.tui.enabled` controls channel launch; it is not
`onboarding_complete` or model consent. Bootstrapping it to `true` keeps the
optional onboarding surface available and does not complete or suppress
onboarding. The persisted TUI mapping resolves the same canonical `local` user
as the web surface's independent mapping; it grants no web access and creates
no implicit cross-surface thread link.

**v1.2.5 process-ownership amendment.** ADR 0091 makes both launchers
attach-only terminal clients. The daemon runs this same compare-and-write after
an authenticated open reserves the one TUI session and before it starts the
temporary Adapter. The client never opens Settings or performs bootstrap.
Every raw-present/absent, custom-profile, audit, and rejection rule in §1a
remains binding; references below to launcher bootstrap mean this daemon-owned
session-admission operation on v1.2.5 and later.

**Availability-first, local-preferred projection (final readiness decision,
operator 2026-07-26; task-chain correction v1.3).** With no explicit
DirectAnswer preference, the shipped local DirectAnswer profile wins. A hosted
profile may satisfy enablement only when it is explicitly present at the head
of the DirectAnswer task chain (or when that chain is empty and the legacy
primary fallback names it). The pre-egress disclosure remains mandatory;
mere presence of an unrelated hosted key never escapes into DirectAnswer
selection. Without an eligible task profile, unusable local states remain
honest repair states with one primary CTA. Detection itself still performs no
hosted probe or egress.

**Stickiness is per key across the whole write set.**
`intent.direct_answer_model_enabled` decides whether enablement runs at all;
`intent.model_assist_enabled` and the DirectAnswer task preference are each
written only when raw-absent. An explicitly stored value on any of the three
survives detection, and the provenance row records which keys were written and
which were already present. The raw-absent subset is applied atomically. Because the
Settings `StoreLock` is not reentrant, the compare-and-write primitive is
multi-key by construction: one lock, one raw read, one validation, one write,
one audit row per applied key, and one transaction provenance envelope naming
applied and preserved keys. A validation failure writes none of the subset.
If locked state now contains explicit consent `false` or a different selected
DirectAnswer task head than the route being disclosed, the primitive applies
none of the subset;
the caller cancels the pending disclosure and projects `sticky_disabled` or
`enabled_unavailable`.

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
- **Curated readiness is not task readiness.** A healthy global
  `local` / `llama3.2:3b` path with a missing selected
  `direct_answer_local` / `qwen2.5:7b` path yields
  `enabled_unavailable` with an explicit chooser or confirmation-gated Qwen
  pull. It does not offer runtime install or the starter-model pull as if either
  repaired the selected task.
- **Explicit operator `false` is sticky.** Auto-enablement fires only when
  the key is *absent* (schema default). If the operator ever wrote
  `intent.direct_answer_model_enabled = false`, detection never overrides it
  (the v1.1 LD32 absent-key-vs-stored-value pattern). Disabling once means
  disabled until the operator re-enables.

### 3. Disclosure, not confirmation

The first auto-enabled ordinary DirectAnswer text session on each local control
surface carries a durable disclosure (normally once, not a modal):

- **which** configured primary and enabled fallback profile/provider routes may
  serve the task, in their bounded operator-authored order;
- **where inference runs** — through the operator's configured local endpoint
  for `local_endpoint` (which may be this device, a WSL host, or a configured
  private/LAN endpoint); for a hosted selection, an
  explicit egress notice naming the provider **before the first message is
  sent**;
- **how to change or revert** — the ADR 0088 chooser, and the one-command
  revert (`allbert admin settings set intent.direct_answer_model_enabled false`).

Web (chat surface), TUI (pre-attach banner), and provider-capable one-shot CLI
(`allbert ask`, including its Mix dispatcher equivalent) all render the
route-derived copy. Bare `allbert` reports readiness but cannot transport a
prompt, so it does not create an acknowledgement merely by printing status.
It says "configured" rather than claiming auto-detection or another provenance
that may no longer be true after an operator edit. The durable record is the
exact ordered route set (primary plus at most one callable fallback), not a
surface boolean or one mutable route marker. A route-set change makes every
surface pending; an acknowledgement is accepted only for the exact set that
was rendered, so a concurrent edit cannot acknowledge different routes.

For hosted ordinary DirectAnswer text transport selected by this ADR, the
surface marker remains `pending` until rendering is acknowledged and provider
admission requires that exact route set to be `acknowledged`. Web derives the
surface from the runtime channel, not request metadata; TUI renders before raw
mode and daemon attachment. A crash before acknowledgement may repeat the
disclosure but cannot send the prompt first. A mapped DM or another
non-presenting runtime surface may reuse only an exact acknowledgement from a
Web, TUI, or CLI control surface in the same Allbert Home; otherwise it fails
closed and leaves those control surfaces pending for repair. This Home-level
acknowledgement records the operator's provider-egress configuration. It does
not grant a remote identity channel access, data scope, or cross-surface
history. Local DirectAnswer inference is disclosed but is not gated by the
egress acknowledgement.

The existing onboarding-marker seam uses atomic replacement but is not a
cross-BEAM compare-and-swap store. A rare simultaneous Web/TUI/CLI marker write
may therefore repeat a disclosure or require a retry. It cannot suppress a
required hosted disclosure: provider admission always recomputes the current
exact route set and rejects any stale or lost acknowledgement. v1.3 does not
couple attach-only clients to the Settings SQLite lock or add a second marker
locking subsystem for this fail-closed UX race.

This boundary does not borrow authority for separately configured vision or
coding profiles. Vision has its own capability/permission contract, and Pi-mode
coding has its own explicit session admission. Generalizing pre-egress
disclosure across every model capability requires capability-specific route
sets and a separate ADR; it is not implemented as ad hoc calls from those
branches.

### 4. The redefined detect-state matrix

"Chat-ready" no longer means "a model answers"; it means **the chat surface
is open, honest about its current capability, and never a dead end**:

| Detect state | Meaning | First-run behavior |
|---|---|---|
| `detected_ready` | first-model substrate is ready and the selected DirectAnswer task head is usable, or an explicit hosted DirectAnswer head is eligible | auto-enable per §1; task order is binding and disclosure names the actual route |
| `detected_needs_model` | local runtime healthy, no usable model, no hosted key | chat opens with deterministic fallback; single primary CTA: one-click curated pull (existing progress surface); BYOK secondary |
| `runtime_unhealthy` | local runtime reachable but failing, no hosted key | chat opens with deterministic fallback; single primary CTA: restart/repair the local runtime; BYOK secondary |
| `nothing_detected` | no runtime, no endpoint, no key | chat opens with deterministic fallback; single primary CTA: guided install / BYOK (ADR 0078 repair paths) |
| `below_floor` | hardware below curated floor, no hosted key | chat opens with fallback; BYOK-first guidance (ADR 0078 degrade path) |
| `enabled_unavailable` | consent is already `true` but the selected DirectAnswer head is gone/unusable, changed before the write, or `llama3.2:3b` is ready while selected `qwen2.5:7b` is missing | chat opens with honest unavailable text and an explicit DirectAnswer select/pull repair; no different profile is disclosed as ready |

These are presentations of the existing six first-model states
(`cli/first_run.ex:42-49`); no parallel state machine is introduced. The
binding cell-by-cell derivation (six `model_state` values × hosted-key
presence) lives in `docs/plans/archives/v1.2-request-flow.md` §D.0 and every cell
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
  `readiness_guard` model-state hard block is inverted: absent an explicit
  channel disable, the TUI starts in every detect state, and
  non-ready detect states render as in-TUI guidance instead of a standard-error
  refusal. `mix allbert.tui` (dev) and `allbert tui` (packaged) adopt the
  same posture — the current divergence is closed. On a fresh Home the shared
  daemon-side session bootstrap from §1a enables the channel and makes the
  first submitted turn admissible; guard inversion without channel and
  identity admission is not sufficient. A raw explicit
  `channels.tui.enabled = false` remains a deliberate session-admission stop
  with bounded re-enable guidance.
- The QuickStart and persona flip sites remain and stay idempotent; personas
  still seed the same keys through the same confirmation-gated action.

### 6. Acceptance criteria (DIT-2 class) are redefined

The v1.0 criterion "QuickStart enables direct answers before the first
question" is retired. The v1.2 criteria, with the v1.3 task-readiness
amendment, are:

- fresh Home + a usable selected DirectAnswer task head → the **first question is
  answered by the model with zero prior clicks**, and the disclosure is
  visible. A hosted key qualifies only when its profile is the selected task
  head (or the empty-list compatibility primary). On TUI,
  this includes atomic daemon-session bootstrap of raw-absent channel
  enablement and the built-in terminal identity before adapter initialization;
  no settings command is a prerequisite;
- fresh Home + only the global starter ready, or nothing provisioned → the
  chat surface still opens, the deterministic fallback answers, and exactly
  one repair CTA per §4 is
  presented — explicit DirectAnswer select/pull when Qwen is missing, otherwise
  the applicable runtime/model/BYOK repair; zero clicks to a working fallback
  chat and no wizard wall;
- an operator-stored `false` is never overridden by detection;
- a raw operator-stored `channels.tui.enabled = false` blocks session admission
  for both packaged and development TUI clients before Adapter startup,
  preserves the identity map, and gives bounded re-enable guidance.

## Consequences

- The first-impression path matches the zero-config bar the First-Model Path
  ADR set out to meet: install, open, chat — with the wizard as an upgrade
  path rather than a toll gate.
- The consent line moves from a per-feature toggle to provisioning plus explicit
  task selection. A hosted credential alone is insufficient; when its profile
  is the selected DirectAnswer head, no second enable step is required. The
  disclosure banner and sticky explicit-`false` are the compensating controls;
  initial key entry and all credential custody are unchanged.
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
