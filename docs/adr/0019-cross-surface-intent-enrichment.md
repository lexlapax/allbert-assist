# ADR 0019: Cross-Surface Intent Enrichment

## Status

Accepted. v0.19 M1 confirmed the candidate contract and engine skeleton follow
these invariants.

ADR 0021 (Intent, Objective, Capability, And Advisory Boundary) supersedes
any reading of this ADR that implies intent ranking is the full
work-management layer. The intent engine continues as proposal
infrastructure under this ADR's invariants; multi-step / cross-turn work
state lives in the v0.24 objective runtime
(`AllbertAssist.Objectives`).

### v0.24 Amendment (2026-05-16): `:objective` candidate kind registered

v0.24 M2 amends this ADR to formally register `:objective` as a
candidate kind. An objective candidate carries the same
proposal-only authority limits as memory candidates, surface
candidates, and action candidates. Specifics:

- New arity `AllbertAssist.Intent.Engine.collect_candidates/2`
  accepts an optional keyword list with an `:objective` key. The
  legacy `collect_candidates/1` arity is preserved and delegates to
  `/2` with empty opts.
- Candidate shape: `kind: :objective`, `id:` set to the target
  `objective_id`, `source: :objective`, `score: 0.2..0.5` (recency
  + topic match), `reason:` set to the objective title.
- `Candidate.bound/2` `@default_kind_limits` gains
  `objective: 5`.
- Section 2 invariants (proposal-only, no permission grant, no
  authority bypass) hold for `:objective` candidates without
  exception.
- Selecting an `:objective` candidate routes to the engine's
  `:continue_objective` command rather than creating a new
  objective.
- Memory candidates (`:memory`) and objective candidates
  (`:objective`) can coexist in the same ranking pass without
  conflict.

ADR 0021 Section 3 (Vocabulary) and Section 4 (Authority rule)
remain the source of truth for objective semantics; this amendment
records only the engine-side candidate registration.

## Context

v0.11 introduced `AllbertAssist.Intent.Decision` as an inert decision contract
with execution-aware intent, resource posture, and Approval Handoff. Intent
routing in `AllbertAssist.Agents.IntentAgent` remained deterministic: a fixed
set of route predicates matched each turn to a skill, action, or refusal. This
works for a small, stable action surface, but it does not scale to plugin-
contributed apps, registered surfaces, jobs, multiple channels, and session-
scoped context.

v0.15 through v0.18 added significant new routing inputs: minimal app
registration, channel adapters with external identity, plugin-contributed
apps/actions/skills, and the full app/surface contract with `SurfaceProvider`.
By v0.18 every runtime turn has a declared `active_app`, and the app registry
exposes surface metadata, action capabilities, and skill paths. The intent
agent cannot reasonably encode all of this as private predicates without
becoming a maintenance liability.

v0.19 upgrades the intent layer to a registry-aware, ranking-based engine. This
ADR records the behavioral invariants that govern the engine and that must be
preserved by all future changes to intent routing.

## Decision

### 1. The engine is proposal infrastructure, not an authority escalation

`AllbertAssist.Intent.Engine` collects candidates and ranks them. It does not
grant permissions, confirm actions, or change execution modes. A candidate's
high score does not make the underlying action safer or more trusted.

The existing authority chain is unchanged:

```
Engine.decide/1
  → Candidate collected from Registry
  → Safety filter (registry validation, Security Central posture)
  → Decision returned to IntentAgent
  → Action executed through Actions.Runner.run/3
  → Security Central authorization
  → Confirmation if required
```

No step in the engine can skip or shortcut any step in the execution chain.

### 2. Model output is untrusted ranked proposal data

When `intent.model_assist_enabled` is true, `AllbertAssist.Intent.Classifier`
may receive a bounded, redacted summary of already-collected candidates and
return a selection proposal. The proposal is advisory only.

Invariants:

- A classifier proposal can only refer to a candidate already in the collected
  set. It cannot create a new candidate, name an unregistered action, or select
  a hidden action.
- The classifier cannot change a candidate's `permission`, `execution_mode`,
  `confirmation`, or `resource_access` fields. Those come from the registry
  only.
- Low-confidence, timed-out, invalid, or non-JSON classifier output falls back
  to deterministic ranking silently.
- The classifier prompt must never receive raw secrets, full memory file
  contents, raw thread history, unredacted trace internals, or unbounded
  conversation context.
- Raw model prompts and raw model completions must never appear in traces, CLI
  output, or audit records.

### 3. `active_app` is ranking context, never authorization

Session `active_app` may boost the score of candidates whose action capability,
skill path, or surface metadata belongs to the matching app. It does not:

- grant the app's actions any additional permissions
- bypass Security Central authorization
- allow the engine to select a candidate that would otherwise be rejected
  for permission, trust, or safety-floor reasons
- cause neutral Allbert context to route silently into app-specific actions

`active_app: :allbert` and `active_app: :stocksage` are equivalent from a
permission standpoint. They differ only in which candidates are scored higher.

### 4. Registry validation is mandatory before selection

Before a candidate can be marked `:selected`, it must pass validation through
the relevant registry:

- Action candidates: `AllbertAssist.Actions.Registry`
- Skill candidates: `AllbertAssist.Skills.Registry` (trusted or activatable
  only)
- Surface candidates: `AllbertAssist.App.Registry` (`SurfaceProvider` or
  validated legacy surface)
- App id fields: `AllbertAssist.App.Registry` (known registered app only;
  never atomized from external input)

Unknown, untrusted, hidden, disabled, or unavailable candidates become
`:rejected` candidates with a bounded `rejection_reason`. They do not become
`:selected`.

### 5. Candidate scores cannot exceed permission floors

A candidate's score determines ranking position only. The safety filter applied
after ranking enforces:

- A denied permission produces a `:refusal` or confirmation-blocked decision,
  regardless of score.
- A `:needs_confirmation` decision still goes through the full v0.07
  confirmation workflow.
- An unavailable execution mode produces an `adapter_unavailable` outcome.
- A `:confirmation_needed` candidate with no pending record still creates a new
  pending record through the v0.07 flow.

No score, model confidence value, or app affinity metric can override these
floors.

### 6. Plugin provenance is explainability metadata only

A candidate's `plugin_id` field records where an action, skill, surface, or
app was contributed. Plugin provenance:

- May be included in trace metadata and candidate reasons for operator
  inspection.
- Does not increase or decrease a candidate's trust level.
- Does not change the candidate's permission class or execution mode.
- Does not make a disabled or untrusted contribution available.

### 7. Resource workflow posture is unchanged

The v0.11 resource access posture, Approval Handoff data, and operation-scoped
grant matching are preserved unchanged by v0.19. The engine maps risky resource
prompts to the appropriate existing action candidates (URL summary, document
inspection, shell, script, package, skill import, unsupported MCP/agent URI)
with their full `resource_access` metadata. The engine does not collapse
operation classes, share grants across consumers, or bypass confirmation.

## Consequences

### For intent routing

- `AllbertAssist.Agents.IntentAgent` delegates to `Engine.decide/1` instead
  of growing more private predicates. App-specific routing comes from
  app/action/skill/surface registry metadata, not from agent-level
  StockSage-or-any-other-app predicates.
- Future milestones (v0.21 memory retrieval, v0.26 workspace shell — formerly
  v0.24) can plug
  into the engine as additional candidate sources or scoring signals without
  changing the authority model.

### For v0.20 StockSage

- StockSage registers its app, actions, skill paths, and surfaces through the
  normal plugin/app contracts. The intent engine sees these through the
  registries.
- No StockSage-specific predicates are needed in the core intent agent.
- `active_app: :stocksage` boosts StockSage candidates but does not grant
  StockSage actions elevated permissions.

### For operators

- Traces include a bounded, redacted Intent Candidates section that explains
  why a candidate was selected or rejected. Operators can inspect routing
  decisions without reading source code.
- The `intent.model_assist_enabled` setting is false by default. Operators
  must explicitly enable model-assisted classification.

### Violations of this ADR

The following changes require a new ADR or a revision to this one:

- Making model output authoritative (removing the collected-candidate
  validation gate).
- Using `active_app` to grant permissions or bypass Security Central.
- Collapsing resource operation classes (treating a URL grant as a shell grant,
  etc.).
- Adding a candidate source that executes code during collection.
- Making plugin provenance a trust or permission escalation mechanism.
