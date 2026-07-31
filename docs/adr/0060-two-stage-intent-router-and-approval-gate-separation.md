# ADR 0060: Two-Stage Intent Router And Approval-Gate Separation

## Status

Accepted (v0.54 Intent Deepening, M8 closeout, 2026-06-16) —
`docs/plans/archives/v0.54-plan.md`. The two-stage router shipped across M0–M7; the
`:v054` intent-router eval and the router suite pass under `mix allbert.test
release.v054`. Live local-model routing (the embedding + LLM disambiguation
against Ollama) is validated by the operator manual-validation punchlist in
`docs/plans/archives/v0.54-request-flow.md`.

**Amendment (2026-06-16, M9):** descriptors are no longer purely static. The
descriptor set is **lifecycle-managed** (generated for actions lacking declarations,
layered with operator curation, re-derived on action-set change via SignalBus
hooks) per **ADR 0062**. The approval-gate separation here is unchanged and
reaffirmed: a descriptor — code-declared, generated, or operator-authored — is a
routing hint only; routable ≠ executable.

**Amendment (2026-07-31, v1.3 M9.b.3):** an Engine/classifier or Router outcome
is a **selection proposal**, not the final route. Descriptors now have an
additive, validated `selection_policy`: existing descriptors default to
`:semantic`, while a descriptor may require `:explicit_evidence`. The final
policy is resolved from the active descriptor by action identity at each
effectful Jido consumer: the interactive `IntentAgent` and the Objectives
default lifecycle. Engine also enforces the same invariant at its central API:
an ordinary classifier/ranker/model candidate cannot become
`intent: :registry_action` or a non-`nil` selected action unless its canonical
descriptor resolves and its evidence is satisfied. Proposal diagnostics are
advisory and cannot weaken either check; no consumer may call `Intent.Engine`
and later execute its selected action without the shared consumer check.
Missing or unresolvable canonical descriptor policy rejects an ordinary
Engine/Router proposal. Edit, override, promotion, and operator inspection
preserve or expose this field so a later descriptor layer cannot silently reset
an explicit policy to the compatibility default.

The `:semantic` compatibility default is not unconditional proposal acceptance.
A model/ranker proposal satisfies it only when a positive descriptor-owned
operator-act phrase (label, action name, example, synonym, or positive
vocabulary) leads the utterance after removal of only bounded polite-request
scaffolding. A contiguous action phrase elsewhere in the utterance is ranking
context, not final selection evidence. The broader ordered-token/fuzzy affinity
used for ranking is likewise never final evidence. Required slots do not
authorize an action by themselves unless that descriptor explicitly sets the
validated `vocabulary.allow_required_slot_selection: true` opt-in; its default
is `false`, and no v1.3 descriptor opts in unless a frozen-corpus compatibility
case is individually reviewed and recorded before closeout. The leading-act
boundary rejects negated, referential, and supplied-text frames that do not
start with an operator act; descriptor-owned `negative_phrases` separately veto
action-language and opted-in slot evidence. This does not claim a generic
natural-language negation parser.

For `:explicit_evidence`, the same leading-operator-act boundary applies and
slots never independently authorize. Leading request scaffolding is a bounded
token rule, and the first non-whitespace character must itself be lexical;
tokenization never strips a quote, code span, escape, list marker, bracket, or
other wrapper to manufacture an operator act. Negated acts and action phrases
embedded in supplied or quoted text reject rather than execute. Ordinary
punctuation after an act remains natural (`Remember, ...`, `What do you
remember?`). Descriptor-owned phrases cover both explicit Memory commands and
the established leading low-risk personal-assertion/recall forms. Extracted
slots can strengthen and explain an operator act, but cannot create one. These
are generic, bounded descriptor/token rules, not private prompt-shaped regular
expressions.

Operator-language matching scans Unicode letters and numbers and treats ASCII
or Unicode punctuation, symbols, and emoji as token boundaries. That same token
contract applies to leading selection phrases, descriptor negative vetoes, and
clarification categories: `?`, fullwidth punctuation, or an emoji suffix cannot
bypass a secret-bearing negative phrase, while `model settings?` ranks like
`model settings`. The lexical-start check still inspects the original text, so
tokenization never strips a leading wrapper into an operator act.

Execute proposals must satisfy the resolved policy. A clarification shortlist
is first validated as one complete proper list of well-formed action options;
one malformed item rejects the whole advisory proposal. A structurally valid
shortlist is then reduced to its canonically grounded options, and only that
subset may be rendered or persisted. Dedicated descriptor
`clarification_phrases` may ground category-level presentation (for example,
bare `note`) but never authorize direct execution. Resolving one persisted,
still-canonical option is the operator's bound selection; the consumer
revalidates that choice against the original prompt's canonical clarification
contract, then proceeds through ordinary parameter, Registry, Runner, Security
Central, and confirmation gates. If the chosen action still lacks required
parameters, the consumer persists that normal parameter clarification; the
operator's third turn supplies them and resumes the same bound action through
the same gates. If validation leaves no option, the consumer uses its clean
canonical direct-answer path. A rejected proposal carries no rejected slots or
resource metadata, creates no rejected action or pending clarification, and
cannot be reinterpreted as another Engine action.

A model/Router `:none` is likewise advisory abstention rather than an
operator-facing refusal. For ordinary text, `IntentAgent` builds a fresh
validated direct-answer decision. Only the canonical deterministic `InputGuard`
may retain the terminal no-match response for slash-command or internal-action-
shaped input; model diagnostics cannot impersonate that guard.

Deterministic ladder routes remain compatible: an explicit deterministic
`route_decision`/route hint is already selected by the typed ladder, so Engine
annotates rather than replacing it. Its typed predicate is the selection
evidence for a resolved semantic route, while an action carrying
`:explicit_evidence` must satisfy the same stricter canonical policy at the
consumer even when the ladder recognized it. A genuinely descriptor-ungoverned
legacy route is not silently disabled unless an inherited explicit policy
requires evidence. This exception does not authorize unresolved ordinary
ranker/classifier/model candidates. Under the default `:two_stage_local`
strategy, Engine does
not also invoke the legacy model classifier before the Router. The deterministic
eval runner applies the same execute/clarify proposal-acceptance contract against
its resolved descriptor set; that is not a claim that it reproduces every
interactive consumer outcome. This adds no process, state, permission,
confirmation bypass, or authority; action execution remains behind Registry,
Runner, and Security Central.

This ADR is the **routing foundation** of v0.54 Intent Deepening (ADR 0019/0034),
**resequenced ahead of completing v0.53** because the v0.53 channel approval
workflow depends on it: a channel message that should run an action — and, for a
`confirmation: :required` action, render approve/deny buttons — currently
dead-ends in an app-handoff text proposal instead. v0.54 also carries the
remaining intent depth (multi-turn memory of intent, chat-primary refinements)
built on this router; the v0.58 UX redo follows.

## Context

The intent decision today is **single-stage deterministic keyword/descriptor
matching** (`AllbertAssist.Intent.Engine` + `Agents.IntentAgent`). The LLM
`Intent.Classifier` (`intent/classifier.ex`) is **off by default**
(`intent.model_assist_enabled = false`) and, when on, is only a **re-ranker over
already-collected candidates** — it cannot route to an unlisted action and is
prompted to treat descriptors as handoff proposals, not execution.

Two failures follow, both observed live during v0.53 channel validation:

- **Mis-route.** "create a note titled X" matches the notes_files **`search_notes`**
  descriptor ("Search local notes") because notes_files declares **no
  `write_note` descriptor** and the bare synonym `"notes"` wins the deterministic
  text match (`Intent.Ranker`, single-token match ≥4 chars). The correct
  capability is invisible to the router.
- **Dead-end.** On a neutral surface (`active_app` ∈ `[nil, :allbert]` — every
  channel message), `Engine.descriptor_decision_attrs/5` fires first and emits an
  **`:app_handoff`** decision. `IntentAgent.run_validated_route/4` routes that to
  `intent_handoff_response/2`, which sets **`approval_handoff: nil`** and returns
  the handoff as inert text. The action never executes; no confirmation is
  created. The only "accept" affordance is a **workspace-canvas `:approval_card`
  fragment**, never wired to channel adapters — there is no `accept_handoff`
  primitive anywhere. On a channel the operator literally cannot accept, and the
  real approve/deny path (`ConfirmationCallback`, keyed on a `confirmation_id`) is
  never reached.

So the end-to-end workflow (request → action → approval → done) breaks for any
app-routable request from a channel. v0.52 Discord approval only worked because
its prompt drove a **direct, non-app** `confirmation: :required` action, which
skips the app-handoff fork. This is an architecture gap in the **router**, not in
any channel adapter, and the app-handoff layer is from v0.33 (not a v0.53
regression).

Current practice (2025–2026) is consistent: single-stage similarity over
semantically overlapping capabilities is the documented cause of this mis-route
class; the robust fix is **two-stage routing** — a cheap embedding prefilter to a
shortlist, then a constrained LLM disambiguation over only that shortlist — with a
**confidence gate**, while keeping approval gating a **separate layer** keyed on
the resolved action and arguments. Small local models are unreliable at open
tool selection over many tools but usable at constrained disambiguation over a
short, pre-filtered list.

## Decision

### Two-stage `Intent.Router`

Introduce an `AllbertAssist.Intent.Router` behaviour (mirroring the proven
`Intent.Classifier.Behaviour` extension pattern — behaviour + settings-gated
default impl + `Application.get_env` swap for tests). It is inserted at the engine
decision fork (`Engine.decide_without_explicit_route/1`), consumes the **full
candidate set over the real action surface**, and returns one routing outcome:

- **Stage 1 — embedding prefilter** (ADR 0061): rank actions by cosine similarity
  of the utterance against per-action example utterances → top-K shortlist
  (K≈3–5) plus a similarity-margin signal. Local, offline, sub-second.
- **Stage 2 — LLM disambiguator** over the shortlist: `ReqLLM.generate_object`
  with a JSON-schema/enum-**constrained** answer field choosing exactly one of
  `{shortlisted action id, :clarify, :answer, :none}`, a free-form `reason` field
  (reasoning is **not** constrained), and extracted `required_slots`.
- **Confidence gate**: combine the model's confidence (average-token logprob where
  the provider exposes it) and the Stage-1 similarity margin → **act**, **ask one
  targeted clarifying question**, or **abstain**. Per-model thresholds
  (`intent.router_min_confidence`).

Outcome contract:
`{:execute, action_name, slots, confidence} | {:clarify, shortlist, question} | {:answer} | {:none}`.
There is **no open-ended app-handoff dead-end** in any outcome.

### Default posture

The **local two-stage router is the default** routing strategy
(`intent.router_strategy = :two_stage_local`). The existing deterministic
predicate ladder is retained as (a) a high-precision **fast-path** for explicit,
unambiguous routes (e.g. slash-style/marketplace/settings commands) and (b) the
**offline fallback** when the router model is unavailable or times out
(`intent.router_model_timeout_ms`). Strategy is settings-gated so an operator can
pin `:deterministic` on constrained hardware.

### Clarify is a real, channel-answerable turn

A `:clarify` outcome renders a **targeted either/or question scoped to the
shortlist** (e.g. "Did you want to *create* a note or *search* notes?"), not the
open "hand this to app X" text. Before rendering, the consumer validates the
whole proposed shortlist and removes options not grounded by the original turn's
canonical descriptors. The operator's reply resolves one persisted option;
that bound choice is revalidated under the current canonical clarification
contract and enters the ordinary parameter, approval, and execution gates. A
reply is selection evidence, not permission or confirmation, and an action with
missing parameters persists its normal follow-up; the next operator turn
supplies those parameters before the same bound action can continue. The
app-handoff `:approval_card` workspace-only path is **removed for channel
surfaces** and replaced everywhere by this targeted-clarify primitive, which
renders through the existing ADR 0016 channel primitives
(`:button`/`:typed_command`/`:list`).

### Approval-gate separation (the invariant)

Routing decides **which** action; the approval gate decides **whether** an
effectful action runs. They are **independent layers**:

- A `confirmation: :required` action — however it was routed (deterministic
  fast-path, router execute, or clarify-resolved) — creates a confirmation and
  surfaces the **existing** `approval_handoff` → `ConfirmationCallback` channel
  primitive (inline approve/deny buttons or `ALLBERT:APPROVE:<id>` typed
  command). The router never approves an action, never sets a `confirmation_id`,
  and never lowers a safety floor.
- `:channel_message_inbound` (ADR 0056) and every Security Central invariant apply
  unchanged. The router is `exposure`-neutral metadata selection; it grants no
  authority.

### Honest framing

The router improves **selection**, not **authority**. Constrained decoding
guarantees a *syntactically valid* action choice, not a *semantically correct*
one. The confidence gate, the targeted clarify, and the unchanged approval gate
are what keep a wrong-but-valid selection from causing an unconfirmed effect. We
make no claim that the local router matches a hosted model on hard multi-step
selection; the optional hosted-escalation tier (ADR 0061) covers the
low-confidence tail.

## Consequences

- The end-to-end channel workflow works: a channel message routes to the correct
  action and reaches the approval primitive; app-routable requests no longer
  dead-end. This unblocks the v0.53 Telegram/email manual approval checks.
- New `Intent.Router` behaviour + default impl; `Engine` fork and
  `IntentAgent.run_validated_route/4` consume the router outcome; the app-handoff
  channel dead-end is replaced by targeted clarify.
- Depends on the local embedding capability and router model tiers (ADR 0061).
- A **golden-set intent eval** (top-1 action accuracy, abstention/`:none`
  accuracy, clarify-precision) joins the release gate. The existing
  security/permission evals are unaffected because the approval gate is unchanged.
- v0.54 carries this router foundation plus the remaining intent depth
  (multi-turn memory of intent, chat-primary refinements); it is implemented
  ahead of completing v0.53 (the channel approval workflow depends on it) and
  ahead of the v0.58 UX redo (chat quality depends on intent).

## Related

- ADR 0016 (channel adapter boundary + approval primitives), ADR 0056 (channel
  inbound trust tier — invariants unchanged), ADR 0019/0034 (intent subsystem
  prior art deepened here), ADR 0011-era approval-handoff lineage (v0.11), ADR
  0006 (Security Central), ADR 0051 (provider capability preferences).
- ADR 0061 (local embedding capability + router model tiers).
- `docs/plans/archives/v0.54-plan.md`, `docs/plans/archives/v0.54-request-flow.md`.
