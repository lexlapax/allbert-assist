# ADR 0062: Intent Descriptor Lifecycle — Generation, Layered Curation & Reindex Hooks

Status: Accepted (v0.54 M9 foundation; v0.56 completion accepted at v0.56 M15
closeout on 2026-06-23). v0.54 gates the tag with the heuristic/YAML/CLI
foundation; v0.56 completes the model-generation, learned-mining, operator-action,
eval-gated promotion, model-recommendation, and full registration-signal lifecycle.
Date: 2026-06-16
Related: ADR 0060 (two-stage router + approval-gate separation), ADR 0061 (local
embedding + router model tiers), ADR 0047 (doctor envelope), ADR 0019 (cross-surface
intent enrichment), ADR 0034 (conversational app intent handoff).

## Post-Implementation Correction

The v0.54 implementation intentionally shipped a narrower but safe foundation:

- dual-source `DescriptorResolver` over app/plugin-module and action-module
  descriptors, plus generated YAML and operator overrides;
- data-only YAML descriptor/vocabulary storage;
- heuristic-only `Optimizer.generate/2`;
- CLI curation (`doctor|bench|optimize|reindex|list|show|edit|disable|review|promote`);
- an inert review tier and operator promotion path;
- reindex-on-signal for the existing `allbert.dynamic_codegen.**` lifecycle.

The following originally planned ADR 0062 pieces are **not** v0.54 shipped
behavior and are now assigned to v0.56:

- local-model descriptor generation through `router_local`;
- learned-review proposal-mining infrastructure for reviewed evidence maps from
  memory, clarifications, confirmations, traces, and operator corrections;
- the operator-callable `optimize_intent_descriptors` registered action;
- `allbert.app.registered`, `allbert.plugin.registered`, and
  `allbert.action.registry_changed` signal emission/consumption.

The v0.56 readiness pass (2026-06-22) added two coupled decisions the lifecycle now
depends on: **ADR 0071** introduces a deterministic routing-accuracy evaluation
harness and makes it a **blocking** gate — `optimize_intent_descriptors`, `mix
allbert.intent promote`, and `release.v056` all run `Intent.Eval.Gate.check`, and a
regression vs the committed baseline or any negative-route violation **rejects the
promotion / fails the release**; and **ADR 0072** ships per-purpose model
recommendations + Settings Central recommended defaults + per-purpose doctor coverage
for the local models this lifecycle uses. v0.56 also targets the full current
routable inventory (`57/57` at closeout), not just the machinery.

This correction does not weaken the authority invariant: every descriptor remains
only a routing hint, and active routing changes still require code declaration,
accepted generated YAML, or operator override/promotion that passes the ADR 0071
gate.

## Context

The two-stage intent router (ADR 0060) routes over **intent descriptors** originally
gathered only from app/plugin `intent_descriptors/0` callbacks
(`Extensions.Registry.registered_intent_descriptors/0`) and embedded into an
in-memory `Intent.Router.Index`. Manual validation (2026-06-16) plus a zoom-out of
the action surface exposed two structural problems:

1. **Coverage is static and partial.** The live registry has **192 registered
   actions** and `Actions.Registry.agent_modules/0` currently returns **49** modules.
   Two of those (`signal_doctor`, `whatsapp_doctor`) declare internal capability
   metadata and should not be routable natural-language targets, so the intended
   descriptor target was the original effective routable inventory estimate after
   that cleanup/exclusion. v0.56 closeout covers the current `agent_modules/0`
   inventory (`57/57`). Only **12** actions had descriptors at audit time, and they were
   notes/stocks/research/browser/panel-centric. Whole domains a user speaks (email,
   calendar, memory, image-gen, channels, settings/model, skills/plugin authoring,
   MCP, objectives) had no descriptor and could not route.

2. **Descriptors do not track a changing action set.** The action set is dynamic —
   it changes at runtime via plugin install, marketplace bundles, and especially
   the **dynamic-codegen / write-code path** (`DynamicPlugins.ActionsOverlay`
   registers new action modules live). But:
   - The action *list* is re-queried fresh on every call
     (`Actions.Registry.modules/0 = static ++ plugin_actions() ++ dynamic_actions()`),
     **yet descriptors only come from app/plugin modules exporting
     `intent_descriptors/0`** — action modules and dynamically-generated actions are
     invisible to the router unless a separate resolver reads them, though
     registered and callable.
   - The `Index` is rebuilt **lazily** and has **no subscriber** to the
     `allbert.dynamic_codegen.{registered,rolled_back,reconcile_completed}` signals
     that already fire on the SignalBus (currently unused). So after an integrate /
     rollback the index is stale until a process restart or a manual rebuild.

We need descriptors to be **lifecycle-managed**: generated for actions that lack
them, operator-curatable without code, layered with clear precedence, and
re-derived automatically when the action set changes — without ever turning a
routing hint into authority.

## Decision

### 1. Layered descriptor resolution (precedence)

Introduce `Intent.Router.DescriptorResolver`, which produces the descriptor set the
Index builds from by merging four active layers, deduped by
`{app_id, action_name}` with
**later layers winning** (mirrors `Settings.Store` `deep_merge(defaults, overrides)`):

1. **App/plugin-module code-declared** — existing `intent_descriptors/0` from
   app/plugin authors via `Extensions.Registry.registered_intent_descriptors/0`.
   This remains the authoritative base for hand-written extension descriptors.
2. **Action-module code-declared** — new resolver scan over live action modules that
   export `intent_descriptors/0`, so M9.1 descriptors may be co-located with the
   action implementation without changing the app/plugin registry contract.
3. **Accepted generated YAML** — descriptors synthesized for registered,
   agent-exposed actions that lack a code descriptor and have been accepted for
   routing. Persisted as data-only YAML under
   `<ALLBERT_HOME>/intents/generated/`.
4. **Operator overrides YAML** — operator-curated data-only YAML under
   `<ALLBERT_HOME>/intents/overrides/`. Highest active precedence; can tweak
   label/examples/synonyms/vocabulary, **disable** a descriptor, or mark an action
   **non-routable**.

A fifth **non-active learned-review tier** lives under
`<ALLBERT_HOME>/intents/learned/review/`. It is where descriptor/vocabulary
proposals produced from reviewed memory, resolved clarification turns, approved
confirmations, and operator corrections land. The resolver does **not** load this
tier; proposals become routable only after operator promotion into `generated/` or
`overrides/`.

The merge is advisory-only: it changes *which* candidates the router shortlists,
never *whether* an action may run.

All descriptor consumers must use this resolved layered set. The embedding Index
and the older `Intent.Engine` app-intent candidate path both consume
`DescriptorResolver.resolve/1`; neither may call
`Extensions.Registry.registered_intent_descriptors/0` directly as its final source
of truth. Candidate normalization must accept descriptor-layer source atoms
(`:app`, `:plugin`, `:action`, `:generated`, `:overrides`, `:review`,
`:learned_review`) so higher-precedence action/generated/operator descriptors are
not silently dropped before ranking. Slot-aware ranking is generic: completed
required slots may boost a descriptor, while missing required slots lead to
clarification rather than execution.

### 2. YAML descriptor and vocabulary files

Lifecycle-managed descriptor payloads are **data-only YAML**, never `.exs` or any
other executable format. The descriptor YAML is also the editable vocabulary file:
the router/ranker compiles it into the in-memory index during startup, `reindex`,
or optimize. Domain-specific routing words do not belong hard-coded in
`ranker.ex`; code should stay generic and consume normalized descriptor/vocabulary
data.

One file represents one `{app_id, action_name}` descriptor:

```yaml
schema_version: 1
app_id: notes_files
action_name: write_note
label: Write note
description: Create or replace a local markdown note.
examples:
  - create a note titled quarterly goals with body grow retention
  - write a note named travel plans saying pack adapters
synonyms:
  - create note
  - write note
slots:
  title:
    required: true
  body:
    required: true
slot_extractors:
  title: title_phrase
  body: body_phrase
vocabulary:
  phrases:
    - create a note
    - write a note
    - note titled
  negative_phrases:
    - find my notes
    - search notes
  allow_single_token_match: false
disabled: false
```

`DescriptorStore` reads/writes these files through `Settings.YamlCodec` and atomic
same-directory writes. It must reject symlinks, path traversal, directories, files
outside Allbert Home, non-map YAML documents, unknown schema versions, and
unregistered actions. Invalid YAML fails closed with a diagnostic in
`mix allbert.intent doctor`; it is never evaluated. Existing `.exs` descriptor
files are implementation drift and must be replaced before v0.54 validation
continues.

Slot extraction stays code-whitelisted even when descriptor metadata is
operator-editable. YAML may name approved extractors such as `ticker_symbol`,
`title_phrase`, or `body_phrase`; it may not define regexes, scripts, functions,
or executable parsing logic.

### 3. Descriptor generation and learning (local, advisory)

**v0.54 shipped foundation:** `Optimizer.generate/2` is heuristic-only and
offline. It writes advisory descriptor attrs from action name/description style
metadata and never calls a model. Review-tier descriptors are inert until
operator promotion.

**v0.56 completion:** the advanced generation and learning loop below is the
inserted v0.56 milestone (`docs/plans/v0.56-plan.md`), not v0.54 shipped behavior.

A generation pass derives candidate descriptors (label, 3–6 example utterances,
synonyms, slot hints) for actions missing them, from the action's `name/0`,
`description/0`, and `capability/0`, using the **local** `router_local` model
(no egress; bounded; redacted — ADR 0061). Heuristic fallback (name/description
tokenization) when the model is unavailable. Generation never reads secrets and
never emits raw prompts to traces.

**Acceptance policy (security-aligned with the dynamic-codegen trust model):**
- Code-declared descriptors from installed plugins are **trusted** (the author
  wrote them).
- Generated descriptors for **dynamic/write-code-originated** actions land in a
  **review tier** (inert) by default and require operator promotion before they
  become routable. A setting (`intent.descriptor_autoaccept`, default `false`)
  can opt into auto-accept-with-audit for trusted generated descriptors in trusted
  environments.
- Memory-analysis and trace-analysis proposals are **always learned-review** in
  v0.56. They may add synonyms, positive phrases, negative phrases, slot markers,
  or examples with evidence references, but they do not update active routing until
  promoted by an operator.

The learning loop is bounded and local:

1. Inputs: reviewed/kept memory, resolved clarification turns, approved
   confirmations, explicit operator corrections, and redacted intent traces.
2. Output: YAML proposal files under `intents/learned/review/` with evidence refs,
   support counts, timestamps, and a confidence score.
3. Promotion: `mix allbert.intent review|promote` moves selected proposals into
   `generated/` or `overrides/` with confirmation + audit.
4. Non-goals: no secrets, no raw private message dumps, no external egress, no
   silent active-route mutation from memory analysis.

### 4. The reindex / optimize entry point

A single runnable maintenance operation re-derives descriptors and rebuilds the
index. v0.54 shipped the Mix task/CLI path; v0.56 adds the registered action
surface (doctor envelope, ADR 0047):

- v0.54: `mix allbert.intent optimize` / `mix allbert.intent reindex`.
- v0.56: action `optimize_intent_descriptors` (internal action callable only from
  explicit operator surfaces/tasks).
- Steps: scan the live action registry → diff against resolved descriptors →
  generate candidates for uncovered actions (→ `learned/review/` or accepted
  `generated/` per policy) → rebuild the Index → emit an audit + a **coverage
  report** (routable / missing / generated / learned-review / overridden /
  disabled), visible in `mix allbert.intent doctor`.

### 5. Reindex hooks (when it runs)

- **Startup**: Index build stays lazy; a debounced boot reconcile ensures coverage
  for the reconciled action set without blocking boot.
- **On action-set change**: Settings Central owns
  `intent.reindex_on_registration_signal` (default `true`). When enabled, the
  v0.54 Index subscribes to the existing `allbert.dynamic_codegen.**` lifecycle
  events. v0.56 completes this hook with `allbert.app.registered`,
  `allbert.plugin.registered`, and `allbert.action.registry_changed` signals
  emitted from the canonical app, plugin, and action registration paths. On receipt it marks the
  index `:not_built` (lazy rebuild) **and** enqueues a descriptor-generation pass
  for newly-seen actions. Disabling the setting is an operator escape hatch for
  controlled tests or recovery only; the product default is to keep plugin/app/action
  registration reflected in intent routing.
- **Debounce**: bursts (e.g. boot reconcile registering many drafts) coalesce into
  one rebuild + one generation pass via a short debounce window.
- **Manual**: `mix allbert.intent optimize|reindex`, operator restart, and the web
  Intents panel button when that surface lands (deferred out of v0.54).

### 6. Operator curation surfaces (YAML-first)

- **Storage**:
  `<ALLBERT_HOME>/intents/{generated,learned/review,overrides,audit}/` —
  operator-editable YAML whose shape mirrors the `Intent.Descriptor` struct plus
  bounded vocabulary/evidence metadata. Overrides and promotions are
  **trusted-local** (same trust class as settings / reviewed memory), audited
  append-only under `intents/audit/`.
- **CLI** (`mix allbert.intent`): `doctor` (+coverage), `list` (resolved
  descriptors with source-layer badges), `show <action>`, `optimize`/`reindex`,
  `edit <action>` (open the override YAML), `disable <action>`, `review` /
  `promote <draft>`.
- **Web**: an eventual **Intents panel** in `WorkspaceLive`
  (`@workspace_tools` + `intents`) listing descriptors by domain with source badges
  (code / generated / override), coverage stats, edit/disable,
  review-generated-drafts, and a trigger-optimize button. This is the target UI
  surface, but v0.54 acceptance uses the CLI curation surface and defers the web
  panel to v0.58.

## Implementation surface (verified against the codebase)

- **Signal subscription**: `Jido.Signal.Bus.subscribe(AllbertAssist.SignalBus,
  "/allbert/dynamic_codegen/registered", dispatch: {:pid, target: self(),
  delivery_mode: :async})`; subscriber receives `{:signal, %Jido.Signal{type:
  ...}}` in `handle_info/2` (existing precedent: `Artifacts.IngestionConsumer`).
  Index gains `:subscription_id` + `:rebuild_timer`; debounce via
  `Process.send_after(self(), :rebuild_debounced, ms)`.
- **Resolver wrap point**: all routing descriptor consumers call
  `DescriptorResolver.resolve/1`. The resolver wraps
  `Extensions.Registry.registered_intent_descriptors/0`, scans live action modules
  exporting `intent_descriptors/0`, then layers accepted generated YAML + operator
  override YAML. Learned-review YAML is listed/reviewed but not loaded by the
  resolver.
- **Descriptor shape**: `%Intent.Router`/`Intent.Descriptor{}` (descriptor.ex) with
  `Descriptor.normalize_many/2` (:96) for validation.
- **Descriptor store**: use existing `Settings.YamlCodec` (`YamlElixir` + `Ymlr`)
  for data-only read/write; remove `Code.eval_file/1`; write atomically under
  Allbert Home; reject path escapes and invalid YAML fail-closed.
- **Generation**: v0.54 heuristic fallback from action
  `name/0`+`description/0`+`capability/0`; v0.56 adds `router_local` via ReqLLM,
  json_schema mode, local-only/redacted (ADR 0061), with heuristic fallback.
- **Review tier**: v0.54 stores and promotes review-tier YAML manually; v0.56 adds
  learned proposal mining into `intents/learned/review/` with evidence and support
  counts.
- **Action + task**: v0.54 ships `mix allbert.intent
  optimize|reindex|list|show|edit|disable|review|promote`; v0.56 adds
  `Actions.Intent.OptimizeIntentDescriptors` (`use AllbertAssist.Action`).
- **Settings**: `intent.descriptor_autoaccept` (default `false`) and
  `intent.reindex_on_registration_signal` (default `true`) in Schema specs +
  defaults + safe_write_keys. Storage under `<ALLBERT_HOME>/intents/{generated,
  learned/review,overrides,audit}/`.

## Authority invariants (unchanged; reaffirmed)

- A descriptor — code, generated, learned-review, or operator — is a **routing hint
  only**. It never grants authority, never sets a `confirmation_id`, never lowers a
  safety floor. The runner + Security Central + the confirmation gate remain the
  only authority boundary (ADR 0060).
- Making an action *routable* does not make it *executable*: its own
  permission/confirmation/exposure still govern. A generated descriptor for a
  `confirmation: :required` action still hits approve/deny.
- Generation and learning are **local-only** (no egress), bounded, redacted;
  operator overrides are trusted-local and audited. Generated descriptors for
  dynamic/write-code actions and all memory-analysis proposals are inert until
  operator-promoted (default).
- The router still only routes within the registry-validated candidate set; a
  resolved descriptor for an unregistered/removed action is dropped on rebuild.

## Consequences

- New in v0.54: `DescriptorResolver`, a YAML descriptor/vocabulary store, a
  heuristic descriptor generator, inert review-tier storage/promotion, `mix
  allbert.intent optimize|reindex`, Index SignalBus subscription + debounce for
  `allbert.dynamic_codegen.**`, an `intents/` home tree,
  `intent.descriptor_autoaccept`, and a future Intents web panel target.
- New in v0.56: model-backed descriptor generation, learned-review proposal
  mining, the `optimize_intent_descriptors` action, and the app/plugin/action
  registration signals that complete automatic reindex on all action-set changes.
- Doctor gains a coverage report over the effective routable inventory; new eval
  rows (new action becomes routable after reindex; operator override wins; generated
  descriptor grants no authority; rollback removes routability; reindex debounced;
  dynamic action inert-until-promoted; internal-capability actions are not routable).
- Net effect: the router's coverage tracks the live action set, operators can curate
  routing vocabulary in YAML without code, and authority/security posture is
  unchanged.

## Alternatives considered

- **Require every action to hand-declare a descriptor.** Rejected: doesn't cover
  dynamic/write-code actions and pushes routing-quality work onto every author.
- **Auto-accept all generated descriptors.** Rejected as default: vague/auto
  descriptions cause mis-selection (external prior art) and would let dynamic
  actions silently become routable; kept as an opt-in setting.
- **Poll/watchdog the registry on an interval.** Rejected in favor of
  signal-subscription + debounce (events already exist; polling adds latency/waste).
- **Store curation in the DB / settings.yml.** Rejected in favor of data-only YAML
  descriptor/vocabulary files under Allbert Home, so operators can edit in an
  editor and diff.
- **Store descriptors as `.exs` files.** Rejected: executable descriptor payloads
  are unnecessary, harder for operators to edit safely, and violate the data-only
  boundary this lifecycle needs. Existing `.exs` descriptor-store code is
  implementation drift to remove.
