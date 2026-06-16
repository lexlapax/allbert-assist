# ADR 0062: Intent Descriptor Lifecycle — Generation, Layered Curation & Reindex Hooks

Status: Accepted (v0.54 M9; in-scope for v0.54, gates the tag — operator decision
2026-06-16). Implementation-ready; APIs below verified against the codebase.
Date: 2026-06-16
Related: ADR 0060 (two-stage router + approval-gate separation), ADR 0061 (local
embedding + router model tiers), ADR 0047 (doctor envelope), ADR 0019 (cross-surface
intent enrichment), ADR 0034 (conversational app intent handoff).

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
   descriptor target is the **47-action effective routable inventory** after that
   cleanup/exclusion. Only **12** actions have descriptors today, and they are
   notes/stocks/research/browser/panel-centric. Whole domains a user speaks (email,
   calendar, memory, image-gen, channels, settings/model, skills/plugin authoring,
   MCP, objectives) have no descriptor and cannot route.

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
Index builds from by merging four layers, deduped by `{app_id, action_name}` with
**later layers winning** (mirrors `Settings.Store` `deep_merge(defaults, overrides)`):

1. **App/plugin-module code-declared** — existing `intent_descriptors/0` from
   app/plugin authors via `Extensions.Registry.registered_intent_descriptors/0`.
   This remains the authoritative base for hand-written extension descriptors.
2. **Action-module code-declared** — new resolver scan over live action modules that
   export `intent_descriptors/0`, so M9.1 descriptors may be co-located with the
   action implementation without changing the app/plugin registry contract.
3. **Generated** — descriptors synthesized for registered, agent-exposed actions
   that lack a code descriptor (esp. dynamic/write-code actions). Persisted as
   md/yaml under `<ALLBERT_HOME>/intents/generated/`.
4. **Operator overrides** — operator-curated md/yaml under
   `<ALLBERT_HOME>/intents/overrides/`. Highest precedence; can tweak
   label/examples/synonyms, **disable** a descriptor, or mark an action
   **non-routable**.

The merge is advisory-only: it changes *which* candidates the router shortlists,
never *whether* an action may run.

### 2. Descriptor generation (local, advisory)

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
  **review tier** (inert) by default and require operator promotion
  (reuse the `Drafts` propose→review→promote + confirmation pattern) before they
  become routable. A setting (`intent.descriptor_autoaccept`, default `false`)
  can opt into auto-accept-with-audit for trusted environments.

### 3. The reindex / optimize entry point

A single runnable maintenance operation re-derives descriptors and rebuilds the
index, surfaced as both an action and a mix task (doctor envelope, ADR 0047):

- Action `optimize_intent_descriptors` (operator-exposed) and
  `mix allbert.intent optimize` / `mix allbert.intent reindex`.
- Steps: scan the live action registry → diff against resolved descriptors →
  generate candidates for uncovered actions (→ review tier or generated/) →
  rebuild the Index → emit an audit + a **coverage report** (routable / missing /
  generated / overridden / disabled), visible in `mix allbert.intent doctor`.

### 4. Reindex hooks (when it runs)

- **Startup**: Index build stays lazy; a debounced boot reconcile ensures coverage
  for the reconciled action set without blocking boot.
- **On action-set change**: the Index **subscribes** to the SignalBus lifecycle
  events — `allbert.dynamic_codegen.{registered,rolled_back,reconcile_completed}`
  (existing), plus new `allbert.app.registered` / `allbert.plugin.registered` /
  `allbert.action.registry_changed` signals emitted from `App.Registry` /
  `Plugin.Registry` / `ActionsOverlay` registration paths. On receipt it marks the
  index `:not_built` (lazy rebuild) **and** enqueues a descriptor-generation pass
  for newly-seen actions.
- **Debounce**: bursts (e.g. boot reconcile registering many drafts) coalesce into
  one rebuild + one generation pass via a short debounce window.
- **Manual**: `mix allbert.intent optimize|reindex`, the web Intents panel button,
  and operator restart.

### 5. Operator curation surfaces (md-first)

- **Storage**: `<ALLBERT_HOME>/intents/{generated,overrides,drafts,audit}/` —
  operator-editable md/yaml whose shape mirrors the `Intent.Descriptor` struct.
  Overrides and promotions are **trusted-local** (same trust class as settings /
  memory md), audited append-only under `intents/audit/`.
- **CLI** (`mix allbert.intent`): `doctor` (+coverage), `list` (resolved
  descriptors with source-layer badges), `show <action>`, `optimize`/`reindex`,
  `edit <action>` (open the override md), `disable <action>`, `review` /
  `promote <draft>`.
- **Web**: an **Intents panel** in `WorkspaceLive` (`@workspace_tools` + `intents`)
  listing descriptors by domain with source badges (code / generated / override),
  coverage stats, edit/disable, review-generated-drafts, and a trigger-optimize
  button — edits write the override md and audit, gated like other operator writes.

## Implementation surface (verified against the codebase)

- **Signal subscription**: `Jido.Signal.Bus.subscribe(AllbertAssist.SignalBus,
  "/allbert/dynamic_codegen/registered", dispatch: {:pid, target: self(),
  delivery_mode: :async})`; subscriber receives `{:signal, %Jido.Signal{type:
  ...}}` in `handle_info/2` (existing precedent: `Artifacts.IngestionConsumer`).
  Index gains `:subscription_id` + `:rebuild_timer`; debounce via
  `Process.send_after(self(), :rebuild_debounced, ms)`.
- **Resolver wrap point**: `Intent.Router.Index.build/0` calls
  `Extensions.Registry.registered_intent_descriptors/0` (registry.ex:79) today; the
  new `DescriptorResolver.resolve/1` wraps it, scans live action modules exporting
  `intent_descriptors/0`, then layers generated + override.
- **Descriptor shape**: `%Intent.Router`/`Intent.Descriptor{}` (descriptor.ex) with
  `Descriptor.normalize_many/2` (:96) for validation.
- **Generation**: `router_local` via ReqLLM, json_schema mode, local-only/redacted
  (ADR 0061); heuristic fallback from action `name/0`+`description/0`+`capability/0`.
- **Review tier**: `Drafts.Store.create_*_draft/2` (store.ex) → `promote_draft/2`
  (:205); a `Drafts.Promotion.promote_descriptor/2` writes the override md.
- **Action + task**: new `Actions.Intent.OptimizeIntentDescriptors`
  (`use AllbertAssist.Action`); `mix allbert.intent optimize|reindex|list|show|
  edit|disable|review|promote` (extends the existing `doctor` dispatch).
- **Settings**: `intent.descriptor_autoaccept` (default `false`) in Schema specs +
  defaults + safe_write_keys. Storage under `<ALLBERT_HOME>/intents/{generated,
  overrides,drafts,audit}/`.

## Authority invariants (unchanged; reaffirmed)

- A descriptor — code, generated, or operator — is a **routing hint only**. It never
  grants authority, never sets a `confirmation_id`, never lowers a safety floor.
  The runner + Security Central + the confirmation gate remain the only authority
  boundary (ADR 0060).
- Making an action *routable* does not make it *executable*: its own
  permission/confirmation/exposure still govern. A generated descriptor for a
  `confirmation: :required` action still hits approve/deny.
- Generation is **local-only** (no egress), bounded, redacted; operator overrides
  are trusted-local and audited. Generated descriptors for dynamic/write-code
  actions are inert until operator-promoted (default).
- The router still only routes within the registry-validated candidate set; a
  resolved descriptor for an unregistered/removed action is dropped on rebuild.

## Consequences

- New: `DescriptorResolver`, a descriptor generator, the `optimize_intent_descriptors`
  action + `mix allbert.intent optimize|reindex`, Index SignalBus subscription +
  debounce, three registration signals, an `intents/` home tree, the Intents web
  panel, and `intent.descriptor_autoaccept` setting.
- Doctor gains a coverage report over the effective routable inventory; new eval
  rows (new action becomes routable after reindex; operator override wins; generated
  descriptor grants no authority; rollback removes routability; reindex debounced;
  dynamic action inert-until-promoted; internal-capability actions are not routable).
- Net effect: the router's coverage tracks the live action set, operators can curate
  routing in md without code, and authority/security posture is unchanged.

## Alternatives considered

- **Require every action to hand-declare a descriptor.** Rejected: doesn't cover
  dynamic/write-code actions and pushes routing-quality work onto every author.
- **Auto-accept all generated descriptors.** Rejected as default: vague/auto
  descriptions cause mis-selection (external prior art) and would let dynamic
  actions silently become routable; kept as an opt-in setting.
- **Poll/watchdog the registry on an interval.** Rejected in favor of
  signal-subscription + debounce (events already exist; polling adds latency/waste).
- **Store curation in the DB / settings.yml.** Rejected in favor of md/yaml files
  consistent with memory/drafts, so operators can edit in an editor and diff.
