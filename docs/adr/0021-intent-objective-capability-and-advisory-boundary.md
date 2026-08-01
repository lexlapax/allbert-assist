# ADR 0021: Intent, Objective, Capability, And Advisory Boundary

## Status

Accepted. Accepted with v0.24 Objective Runtime Foundation M6 closeout on
2026-05-17.

Amendments below (Section: v0.24 Amendments) enumerate the plan-level
decisions that crystallized during the third validation pass on 2026-05-16,
the fourth validation pass on 2026-05-17, and the final
implementation-readiness correction on 2026-05-17. Amendments A1–A10 came
from the third pass; A11–A13 came from the fourth pass and were corrected in
the final readiness pass to match the closed v0.23 substrate and the verified
Jido APIs. M6 acceptance confirms those amendments as the binding v0.24
objective-runtime contract.

## Context

Through v0.22, Allbert is organized around a flat "intent routes to
action" loop. `AllbertAssist.Intent.Engine` collects ranked candidates
from registered actions, skills, surfaces, jobs, channels, memory, and
refusals. The selected candidate flows through `Actions.Runner.run/3`,
Security Central, optional confirmation, and execution. This works
well for one-shot capabilities — `mix allbert.ask "summarize this URL"`
maps cleanly to one action with one confirmation.

It does not work well for multi-step work. Four current seams expose
the gap:

1. **v0.07 confirmation resume.** A confirmation record carries the
   selected action and Security Central decision, but no first-class
   field for "what larger work is this in service of?"
2. **v0.13 job → confirmation handoff.** A scheduled job that triggers
   a high-risk action creates a confirmation. The job `run_id` and
   confirmation id are linked through trace metadata only; no durable
   record connects them as part of a shared objective.
3. **v0.20 StockSage queue.** `stocksage_analysis_queue` is already a
   domain-specific objective table with status, queued_at, started_at,
   completed_at, user_id, and thread_id. Without a shared primitive,
   v0.24/v0.25 native financial specialist agents will either duplicate this
   pattern or invent something incompatible.
4. **v0.22 `RunAnalysis` confirmation flow.** A multi-step request
   like "analyze AAPL and compare to MSFT" cannot be represented as
   one work item that spans two `RunAnalysis` confirmations.

The project-direction rethink draft
(`docs/archives/project-direction-rethink-01.md`) proposes adding an
objective runtime layer between intent selection and action execution.
This ADR records the binding decisions that govern that layer.

The rethink draft also reserves vocabulary for future advisory
providers (LLM-based step proposers, world models, diffusion proposers,
market allocators, capability inventory, route proposal, acquisition
options). That vocabulary needs an authority rule that survives all
future provider implementations, so this ADR records it now even
though most providers are not implemented in v0.24.

ADR 0034 (planned for v0.33) is the first narrow consumer of the reserved
intent/route advisory vocabulary. It limits that consumer to app-intent
handoff and clarification proposals; it does not authorize execution, trust,
permission, objective transitions, or capability acquisition.

## Decision

### 1. Three durable layers, not two

The runtime has three durable layers from v0.24 forward:

```
Intent          (per-turn; existing)
Objective       (cross-turn; new)
Action          (per-step; existing)
```

**Intent** is what the user appears to mean or request right now.
`AllbertAssist.Intent.Decision` continues as the inert selected-route
contract; `Intent.Engine` continues as candidate-ranking
infrastructure. Intent state is per-turn.

**Objective** is the outcome Allbert is trying to achieve across one
or more steps. It is durable: `objectives`, `objective_steps`, and
`objective_events` tables in SQLite. An objective has acceptance
criteria, constraints, a current step, and a status
(`:open | :running | :blocked | :completed | :cancelled | :failed`).

**Action** is the executable capability. `AllbertAssist.Actions.Runner`
and Security Central continue to own execution authority. No
objective, step, intent, planner, advisory provider, hook, or surface
can bypass them.

### 2. Authority boundary

`Actions.Runner.run/3` + Security Central + confirmations + resource
access posture remain the only effectful capability boundary. No
artifact above this boundary grants permission:

- `objective_id` is not authorization.
- `step_id` is not authorization.
- Intent ranking scores are not authorization.
- `active_app` is not authorization (per ADR 0015).
- Advisory provider output, world-model predictions, diffusion
  proposals, market bids, capability-inventory entries, and
  acquisition options are not authorization.
- Lifecycle hooks and stage transitions are not authorization.

Every step that mutates, fetches, sends, executes, analyzes, imports,
installs, or contacts external systems must ground to a registered
action and pass Security Central. The objective engine arranges
state; it does not arrange permission.

### 3. Vocabulary

Each term below has a precise meaning in the runtime. The vocabulary
exists so future agents, plugins, apps, and advisory providers can
plug in without renaming.

#### Intent

What the user appears to mean now. Per-turn. Inert
`Intent.Decision` shape carries selected skill/action/surface, risk
posture, confirmation mode, and resource access. Intent is not
authorization (ADR 0019).

#### Objective

Durable cross-turn outcome state. Has acceptance criteria,
constraints, current step, status, and links to traces, jobs,
messages, memory candidates, and step records. An objective never
grants permission; it only arranges state.

#### Step

A bounded unit of work inside an objective. Step kinds shipped in
v0.24:

- `action` — run one registered Jido action.
- `ask_user` — emit a question; pause until user responds.
- `wait` — pause for an external event (scheduled job, confirmation,
  channel callback).
- `observe` — record an external observation into the objective.
- `reflect` — propose memory or workflow candidates after a sequence
  of actions; never writes memory itself (the v0.21 review surface
  remains the only writer).
- `delegate_agent` — **minimal v0.24 implementation** that dispatches
  a command to a registered specialist agent in
  `AllbertAssist.Objectives.AgentRegistry`. v0.24 ships the
  contract and a stub-tested round-trip; v0.25 specialist trading
  agents are the first real consumers. See v0.24 Amendments below.

Reserved step kinds (named, not implemented in v0.24):
`capability_inventory`, `capability_gap`, `route`, `span_out`,
`consolidate`, `evaluation`, `acquisition`, `surface`.

#### Observation

A result from the environment, runtime, action, channel, job, memory,
trace, or user that updates the objective. Observations are durable
in `objective_events` and bounded in `objective_steps.observation_summary`.
Observations are facts, not predictions.

#### Capability inventory

A view over what Allbert can do right now: registered actions and
their permissions, app and plugin contracts, skills, channels, jobs,
settings, configured credentials, memory and derived indexes,
surfaces, provider/model profiles, local files, caches, resource
grants, and app-domain context. Reserved vocabulary in v0.24;
implemented only when a real consumer needs it. The inventory is a
*view* over authoritative registries (`Actions.Registry`,
`Skills.Registry`, `App.Registry`, `Plugin.Registry`, Settings
Central, Resource Access posture), not a new authoritative store.

#### Capability gap

A missing capability that would let a step succeed: missing setting
or credential, disabled plugin or app, unavailable provider profile,
missing resource grant, missing data, code that would need to be
written. Reserved vocabulary in v0.24.

#### Route

A proposed way to advance an objective using available or acquirable
capabilities. May reference existing actions, combinations, user
prompts, missing credentials, plugin installs, generated scaffolds,
deferrals, or refusals. Routes are proposal data only. Reserved
vocabulary in v0.24.

#### Acquisition option

A proposed investment in new capability: request a credential, change
a setting, install a plugin, generate a scaffold, write code. Always
explicit and operator-visible; never silent. Reserved vocabulary in
v0.24.

#### Resource decision model

Advisory logic that prices routes by capability availability,
acquisition cost, expected quality, latency, money/token/CPU cost,
Security Central risk, credential availability, trust, user attention
burden, reversibility, and maintenance burden. Reserved vocabulary
in v0.24.

#### Planner / evaluator

Logic that proposes steps and assesses them. v0.24 ships one
deterministic proposer (`AllbertAssist.Objectives.Proposer`) and one
deterministic evaluator (`AllbertAssist.Objectives.Evaluator`).
Future LLM-based planners, world-model-assisted evaluators,
probabilistic critics, and diffusion proposers are reserved
vocabulary.

#### World model

A future predictive or counterfactual model of how state may change
under proposed actions. Distinct from an LLM. May expose latent state
prediction (JEPA-style), simulator rollouts, agent-behavior
simulators, embodied predictors, or domain-specific deterministic
models. Reserved vocabulary in v0.24. **World-model output is never
observed fact**; simulated state must be labeled as simulated.

#### Advisory provider

The umbrella role for any provider that proposes, ranks, predicts,
scores, summarizes, critiques, or explains. Includes:

- `IntentProvider`
- `RouteProvider`
- `CapabilityProvider`
- `ResourceDecisionProvider`
- `WorldModelProvider`
- `DiffusionProposalProvider`
- `ProbabilisticInferenceProvider`
- `MarketAllocatorProvider`
- `CriticEvaluatorProvider`

All reserved vocabulary in v0.24. The first behaviour extraction
should wait until at least two providers of the same role exist.

#### Hook

A bounded extension point before, after, or around an engine stage.
Hook categories:

- **Guard** — may block or downgrade a stage before expensive work.
- **Enrichment** — adds bounded context or metadata.
- **Proposal** — generates candidates.
- **Evaluation** — scores risk, cost, feasibility, predicted progress.
- **Consolidation** — merges, ranks, prunes, deduplicates, explains.
- **Observation** — normalizes what happened.
- **Reflection** — proposes memory, workflow, or trace consolidation.
- **Rendering** — shapes what a surface or channel shows.

v0.24 implements five named hook points:

- `before_objective_frame` (guard / enrichment)
- `after_objective_frame` (observation)
- `step_proposer` (proposal)
- `step_evaluator` (evaluation)
- `on_impasse` (observation / rendering)

Other hook names are not reserved. New hook points are added when a
real consumer appears, not pre-named in this ADR.

#### Impasse

A first-class blocked-thinking state: no viable step, too many
unresolved candidates, missing context, pending confirmation, or
selected step unavailable. Impasses are recorded as objective events
(`allbert.objective.impasse`), not silent failures.

### 4. Authority rule (re-stated for emphasis)

A hook, advisory provider, world-model output, intent score, or
proposal can:

- propose, rank, predict, score, summarize, critique, explain;
- influence which step is selected by the engine;
- be rendered in trace, diagnostics, and surfaces.

It cannot:

- authorize execution;
- bypass `Actions.Runner.run/3`, Security Central, confirmations,
  resource access posture, or audit;
- mark simulated state as observed truth;
- short-circuit operator confirmation.

### 5. Privacy / over-reliance rule

A future agent-model provider may predict that the user is likely
to approve a given step. **That prediction never short-circuits
confirmation.** The fact that the user "usually says yes" is not
equivalent to the user saying yes this time. This rule holds
regardless of confidence score, calibration history, recency, or
provider type.

A future agent-model provider that simulates user attitudes,
behaviors, or social dynamics must run under explicit operator-
visible Settings Central config, Security Central posture, redaction,
traces, and evals.

### 6. Engine state machine

The objective engine is a seven-stage state machine:

1. Receive
2. Interpret intent
3. Frame/resume objective
4. Propose and evaluate steps
5. Authorize selected step
6. Execute
7. Observe and advance

The engine is implemented as a Jido.Agent (see ADR 0007 substrate
rule; see v0.23 Jido State-Machine Convergence for the pragmatic
rule on when to reach for Jido.Agent). The earlier rethink draft
proposed a sixteen-stage breakdown. That breakdown is brainstorming
and is not the v0.24 shape.

### 7. Cooperative cancellation only

`cancel_objective` transitions objective status to `:cancelled` and
blocks new step creation. Any in-flight registered action completes
normally (actions are single-shot). Mid-action interruption is
deferred until v0.25+ has a clearer story for native financial specialist
agents and bridge processes.

### 8. Coexisting signals

Objective namespace signals emit alongside existing
`allbert.input.received`, `allbert.agent.responded`, and
`allbert.action.*` signals. v0.24 also formalizes the
CoreApp-declared `allbert.runtime.turn.started` and
`allbert.runtime.turn.completed` aliases. No existing signal is
removed or renamed. Subscribers use `allbert.objective.**` on the
named `Jido.Signal.Bus` because nested objective signals can contain
more than one segment after `objective`. Trace volume is bounded by
`objectives.trace_detail` (default `:operator`).

### 9. Pragmatic substrate rule (from v0.23)

`Objectives.Engine` is a Jido.Agent because it is a stage state
machine with lifecycle hooks that earn their keep. New state-bearing
components choose Jido.Agent or plain GenServer based on
plausible value (state machine, lifecycle hooks, successor-agent
story). This is not a hard rule; reviewers judge case-by-case.

Private Jido command modules inside those agents are not registered
Allbert capability actions and are not intent candidates. Objective
runtime commands must not appear in `AllbertAssist.Actions.Registry`
unless a later ADR explicitly promotes an operator-facing diagnostic or
capability action.

### 10. Hard non-goals for v0.24

The following are reserved vocabulary in this ADR but not
implemented in v0.24:

- No advisory provider behaviour.
- No world-model abstraction.
- No JEPA, diffusion, or simulator runtime.
- No vector store, robot runtime, or external provider call.
- No marketplace, autonomous installer, dynamic code loader, spend
  policy, or provider bidding runtime.
- No public plugin hook contribution API.
- No automatic capability acquisition.
- No LLM-assisted acceptance evaluator (deterministic only).
- No parallel step execution (default 1; reserved
  `max_parallel_steps`).
- No mid-action interruption.
- No automatic memory promotion from objective observations.

## v0.24 Amendments (2026-05-16 third validation pass)

The third validation pass on v0.24 plan/flow surfaced a set of
plan-level decisions that need to live in this ADR so future readers
do not have to reconstruct them from plan history. Each amendment
below extends (does not contradict) the Decision section above.

### A1. `:objective_write` permission class

A new Security Central permission class governs the
cancel/continue lifecycle actions:

- Class name: `:objective_write`
- Default policy: `:allow` (for objective owner)
- Safety floor: `:allow`
- Risk tier: `:low`
- Settings Central key: `permissions.objective_write` (writable)

Rationale: the permission class exists for symmetry with other
`_write` classes (`:memory_write`, `:stocksage_write`,
`:settings_write`) and for future per-objective ACL scoping when
hosted multi-user lands (v0.31+). It does not contradict Section 4
(Authority rule): the underlying state mutation
(`status = :cancelled`, etc.) is engine bookkeeping, not external
capability work. Any effectful capability triggered as part of
cancel/continue (e.g., scheduling a follow-up action) still goes
through its own permission class on `Actions.Runner.run/3`.

### A2. `parent_step_id` populated semantics

The `objective_steps.parent_step_id` column is populated in v0.24's
two-step "analyze AAPL and compare to MSFT" smoke (step 2's
`parent_step_id` = step 1.id). This proves the column works
end-to-end before v0.25 builds on it. Per-app proposers
(e.g., `StockSage.Proposer`) set the field deterministically when
returning multi-step proposals.

### A3. Minimal `:delegate_agent` step kind

v0.24 ships the minimal `:delegate_agent` step-kind contract so
v0.25 specialist trading agents have a binding target on the day
they start. The contract is:

- `objective_steps.kind = :delegate_agent` accepted by the Step
  changeset.
- `objective_steps.delegate_agent_id` populated with the target
  agent's registry id.
- Engine's `:execute_step` for `kind: :delegate_agent` looks up the
  agent in `AllbertAssist.Objectives.AgentRegistry` and dispatches
  via the new `AllbertAssist.Actions.Objectives.DelegateAgent`
  registered capability action (operator-facing namespace
  `AllbertAssist.Actions.Objectives.*`, registered in
  `Actions.Registry`, gated by Security Central — not a private
  engine command). Private engine commands live in
  `AllbertAssist.Objectives.Commands.*`; see v0.24 plan Module
  Shapes for the namespace boundary.
- v0.24 ships the contract + a stub-tested round-trip. No specialist
  agents are registered in v0.24; the registry is empty by default.
  v0.25 specialist agents register themselves at boot.

This amendment moves `:delegate_agent` from the "reserved" list above
to the "shipped in v0.24" list (Section 3 — Step). All other reserved
step kinds remain reserved.

### A4. `objective_id`/`step_id` on `stocksage_analyses`

In addition to the `Consequences > What changes` list below, v0.24
also adds `objective_id` and `step_id` columns to
`stocksage_analyses` (not only `stocksage_analysis_queue`), plus a
btree index on `stocksage_analyses.objective_id`. This enables
efficient "list analyses for this objective" queries from the v0.24
LiveView `/objectives/:id` view (and future v0.26 workspace shell)
without requiring a join through `stocksage_analysis_queue`.

Pre-v0.24 `stocksage_analyses` rows have NULL in both new columns.
The migration is part of the v0.24 four-sequential-migration set
(specifically migration 4, which lives in the StockSage plugin's
`priv/repo/migrations/` directory and runs via
`mix ecto.migrate.allbert`).

### A5. `:abandoned` objective status

Per v0.24 Rule 10 (eager rehydration), the engine adds an
`:abandoned` terminal status to the objective status enum (Section 3
above lists `:open | :running | :blocked | :completed | :cancelled
| :failed`; v0.24 implementation adds `:abandoned`).

`:abandoned` is set by the boot-time rehydration scan for
objectives where `updated_at` is older than 1 hour AND status was
in `[:open, :running, :blocked]` at last write. The row is preserved
for forensic inspection but is not loaded into the engine's
in-memory projection.

### A6. Engine rehydration window

The 1-hour rehydration window is currently fixed. A future setting
(`objectives.rehydrate_window_minutes`) is reserved for operators
who need a different window; it is not implemented in v0.24.

### A7. Coexisting signal trace_id correlation

For single-step objectives, both
`allbert.runtime.turn.completed` and `allbert.objective.completed`
fire and **share the same `trace_id`** so consumers can correlate
the two without scanning per-turn payload identifiers. The runtime
turn signal is a v0.24 canonical alias; legacy
`allbert.agent.responded` remains intact. This is the
operator-visible form of the Section 8 ("coexisting signals")
guarantee.

### A8. Acceptance evaluator vs. `max_loop_count` precedence

When the acceptance evaluator returns `:needs_more_steps` AND
`loop_count >= max_loop_count`, the cap wins: the objective
transitions to `:blocked` and records an `allbert.objective.impasse`
event. The evaluator's verdict (`:needs_more_steps`) is preserved
in the event's `payload.would_have_continued_verdict` field for
operator diagnostics, so the impasse is never a black box.

This is the operator-visible form of the Section 3 (Bounded loops)
guarantee — specifically, "exceeding a cap records an `impasse`
event, not a silent failure" — now extended with diagnostic verdict
recording.

### A9. Deterministic per-app proposer dispatcher

The deterministic proposer (Section 3 — Planner/evaluator) is
implemented as a per-app registration dispatcher
(`AllbertAssist.Objectives.Proposer`) with per-app modules (e.g.,
`StockSage.Proposer`) registering themselves at app boot.
Settings Central does NOT carry proposer rules; proposers are
Elixir code, not settings data. This keeps proposers reviewable,
testable, and bounded in surface area.

A future settings-driven layer is reserved (
`objectives.proposer_overrides` is not currently named in this ADR;
when a real second proposer per app is needed, that namespace will be
created via a future ADR).

### A10. Intent.Engine.collect_candidates/2 arity

`AllbertAssist.Intent.Engine.collect_candidates/1` (existing) is
preserved by delegating to a new `collect_candidates/2` arity that
accepts an `opts` keyword list. The new arity sniffs `:objective`
from opts; older callers continue to work without modification.

ADR 0019 is amended separately at v0.24 M2 to register `:objective`
as a candidate kind under the existing Section 2 invariants.

### A11. Hybrid proposer contract (fourth-pass decision 2026-05-17)

The deterministic proposer (Section 3 — Planner/evaluator;
Amendment A9 above) supports a **hybrid propose-execute-reflect
cycle** for multi-step objectives. `Proposer.propose/2` returns one
of:

- `{:ok, [step_attrs, ...], :done}` — final batch; no more steps
  pending. Engine runs Stages 5–7 for each step, then evaluates
  acceptance.
- `{:ok, [step_attrs, ...], {:more, hint}}` — first or intermediate
  batch; engine re-invokes `propose/2` after Stage 7 with
  `Keyword.put(context, :proposer_hint, hint)`. Engine persists the
  hint as bounded JSON in `objectives.proposer_hint` and caches the
  decoded tagged tuple in
  `Objectives.Engine.Agent.proposer_hints[objective_id]` so a crash +
  rehydrate replays correctly.
- `{:no_steps, reason}` — no steps available; engine records reason
  in framing event and does not create the objective (framing call)
  or transitions to `:blocked` with reason `:no_more_steps`
  (mid-objective call).

The `hint` is a **tagged tuple keyed by app_id**
(e.g., `{:stocksage, %{step_index: 1, completed_steps: [...]}}`).
Engine pattern-matches on the tag to route back to the right
proposer without inspecting inner state. Inner-map shape is per-app
and opaque to the engine, but it must be JSON-encodable, redacted, and
bounded before persistence.

This contract supports the v0.24 two-step
"analyze AAPL and compare to MSFT" smoke without requiring the
proposer to predict the full plan upfront. v0.25+ LLM-assisted
proposers (when shipped under a future ADR) inherit the same
contract.

### A12. Acceptance criteria structured shape (fourth-pass decision 2026-05-17)

`objectives.acceptance_criteria` is a JSON-encoded TEXT column with
a structured map shape, not free-form natural language. The
`AllbertAssist.Objectives.Evaluator.evaluate/2` function compares
the map against completed step rows + observations and returns
`:met | :not_met | :needs_more_steps`.

Shape:

```elixir
%{
  "min_completed_steps" => integer,
  "required" => [clause, ...],          # all clauses must hold for :met
  "needs_more_when" => [clause, ...],   # holds → :needs_more_steps vs :not_met
  "summary" => string                   # operator-facing
}
```

Clause kinds shipped in v0.24 (extensible via future ADRs;
unknown kinds are rejected at changeset validation):

- `step_completed_with_action` — completed step exists whose
  `candidate_action` matches and `action_params` super-set-matches
  `params_match`; cardinality via `min_count` (default 1).
- `completed_step_count_below` — used in `needs_more_when` only;
  true if fewer than `value` steps are `:completed`.
- `observation_contains` — completed step's `observation_summary`
  contains the literal `substring`.

Reserved clause kinds (named, not implemented in v0.24):
`step_failed`, `step_observation_matches_regex`,
`total_duration_under_ms`, `acceptance_via_llm` (LLM-assisted
evaluation reserved per Section 3).

Test fixtures live under
`apps/allbert_assist/test/fixtures/v0.24/acceptance_criteria/` with
JSON exemplars for the two v0.24 acceptance flows.

This is the operator-visible form of the Section 3 "Planner /
evaluator" deterministic contract: acceptance is a function of
structured data, never free-form model output.

### A13. Directive support is conservative and advisory (fourth-pass correction 2026-05-17; hardening update 2026-05-17)

v0.24 Engine commands routinely emit directives such as
`Jido.Agent.Directive.schedule/2` for delayed next-stage self-signals.
`AllbertAssist.JidoBacked.unwrap_last_result/1` treats directive-only
command returns as successful dispatch instead of missing results:

- `{:ok, %{}, directives}` returns a non-error dispatch success.
- `{:ok, %Jido.Agent.Directive{} = d}` returns a non-error dispatch
  success.
- Existing result-bearing happy paths stay unchanged.

Directives remain scheduler hints inside supervised Jido execution. They do
not authorize actions, grant permissions, bypass confirmations, or mutate
durable objective truth privately. v0.24 includes a real command path
(`PruneStale`) that may return a conservative schedule directive.

### A14. Ten private objective commands are the release contract (post-audit hardening 2026-05-17)

The objective engine command graph consists of 10 real private `Jido.Action`
modules:

- `FrameObjective`
- `ProposeSteps`
- `EvaluateSteps`
- `AuthorizeStep`
- `ExecuteStep`
- `ObserveStep`
- `AdvanceObjective`
- `CancelObjective`
- `ContinueObjective`
- `PruneStale`

No `Commands.Noop` placeholder is part of the v0.24 contract. These modules are
private engine commands, not Allbert capability actions, and must remain absent
from `AllbertAssist.Actions.Registry`.

### A15. Objectives facade and store helpers cohabit in one module (post-audit hardening 2026-05-17)

`AllbertAssist.Objectives` is both the public lifecycle facade and the local
store context during v0.24. The public facade functions are:

- `list/2`
- `get/2`
- `frame/2`
- `advance/2`
- `cancel/3`
- `continue/2`

The existing lower-level `create_*`, `update_*`, `list_*`, and `get_*` helpers
remain in the same module as internal runtime/store helpers for the engine,
migrations, and focused tests. Apps, plugins, LiveViews, and v0.25 specialist
agents should use the facade or registered actions for lifecycle transitions.
`frame/2` requires an explicit `user_id`; local identity defaults stay at
operator/runtime boundaries.

### A16. AgentRegistry is monitored and local (post-audit hardening 2026-05-17)

`AllbertAssist.Objectives.AgentRegistry` is a small monitored GenServer registry
for the local v0.24/v0.25 objective-agent namespace. It validates that a
registered server is alive, monitors the pid, evicts entries on `DOWN`, and
dispatches through `Jido.AgentServer.call/3`. This avoids dead-pid delegation
without adding a distributed registry dependency before Allbert needs one.

### A17. Objective CLI exit codes are enforced (post-audit hardening 2026-05-17)

`mix allbert.objectives` uses real OS exit codes for known failure classes:
usage `64`, not found `65`, `--user`/`--operator` mismatch `66`, and unexpected
action/security/final failures `1`. Success, including advisory no-op
`continue` statuses, exits `0`. Tests inject the halt function so these codes
are verified without terminating ExUnit.

### A18. v0.25 delegate agents are reusable specialists, not a private graph

ADR 0022 records the first real consumer of the v0.24 delegate-agent substrate:
StockSage native financial specialist agents. They register in
`AllbertAssist.Objectives.AgentRegistry`, return advisory report packets, and
are callable through objective steps by Allbert runtime paths that have the
right action/permission story. They do not own durable objective state, bypass
registered actions, or create a StockSage-private agent graph.

### A19. Orchestrator commands compose subcommands directly

`AdvanceObjective` and `ContinueObjective` are themselves already invoked by
the Engine.Agent through JidoBacked signal routing. Inside those orchestrators,
subcommands are invoked through `AllbertAssist.Objectives.Commands.run_subcommand/3`
so their patches and directives can be composed before one outer `finish/4`.
They do not recursively call `JidoBacked.dispatch/4` against the same engine
agent. This preserves state projection semantics and avoids re-entering the
same `AgentServer` while it is handling a command.

### A20. Reserved advisory-provider vocabulary is NOT part of the 1.0 freeze

Status: amendment added in the post-v0.37 planning pass for v1.0 closeout.

The 1.0 stability release (`docs/plans/archives/v1.0-plan.md`) uses a tiered freeze
policy. This amendment records that the reserved advisory-provider vocabulary
in Section 3 (Vocabulary) and Section 6 (Engine state machine) is **not**
part of the 1.0 frozen contract.

Specifically, the following names are reserved in ADR 0021 but are not
implemented in v1.0 and are not protected by the v1.0 contract freeze:

- `WorldModelProvider`
- `DiffusionProposalProvider`
- `MarketAllocatorProvider`
- `ProbabilisticInferenceProvider`
- `CriticEvaluatorProvider`
- `ResourceDecisionProvider`
- `CapabilityProvider`
- `RouteProvider`

`IntentProvider` (implemented via `Intent.Classifier`) is the only advisory
provider role implemented in v1.0; its shape ships under the v1.0 Tier 1
freeze through the Runtime/Actions surface.

The first concrete implementation of any other reserved role MAY amend this
ADR and is allowed to alter the role's behaviour shape, parameter list,
return shape, or naming. v1.0 does not promise these names are stable.

### Rationale

ADR 0021 Section 3 itself enforces "first behaviour extraction waits until
at least two providers of the same role exist." That rule is incompatible
with freezing the role's contract before two providers exist. Promoting any
reserved role to Tier 1 (frozen) requires a separate post-1.0 ADR after the
second concrete provider proves the shape.

### Consequences

- Allbert 1.0 ships with one advisory provider implementation (`IntentProvider`
  via classifier). Operators and plugin authors do not see the reserved
  vocabulary as a binding API.
- Post-1.0 work that introduces a `WorldModelProvider` (or any other reserved
  role) is free to choose the contract shape based on the concrete second
  provider, not on the v0.21 vocabulary draft.
- The v1.0 freeze notes in `docs/plans/archives/v1.0-plan.md` cross-link this
  amendment so the reserved-vocabulary status is operator-visible.

### A21. The delegate-agent substrate gets a second consumer before the 1.0 freeze (v0.46)

Status: accepted in v0.46 M1 for Delegation Hardening And Research
Specialist (`docs/plans/archives/v0.46-plan.md`).

A18 records StockSage native financial specialist agents as the **first**
real consumer of the v0.24 delegate-agent substrate
(`AllbertAssist.Objectives.AgentRegistry` + the `:delegate_agent` step
kind + the registered `delegate_agent` action). Through v0.45, StockSage
is the **only** registered consumer (`AgentRegistry.register/4` is called
in exactly one non-test location). The `AgentRegistry`/`delegate_agent`
contract is part of Objective Runtime, which the v1.0 Tier 1 freeze locks.

This ADR section §3 ("Planner / evaluator") and amendment A20 both record
the same principle: **do not freeze a contract proven by a single
consumer.** A20 applies it to reserved advisory-provider roles; A21
applies it to the delegate-agent substrate. Freezing `AgentRegistry` and
the `:delegate_agent` step on one-consumer (StockSage-only) evidence
risks locking a contract shaped by one domain's needs.

Therefore v0.46 shipped a **second** delegate-agent consumer — a
plugin-contributed research/summarize specialist
(`./plugins/allbert.research/`) — whose commands orchestrate the
already-shipped v0.43 browser navigate/extract actions and fall back to
deterministic extractive summaries. Like StockSage's agents (A18), it:

- registers in `AllbertAssist.Objectives.AgentRegistry` and is invoked
  only through the registered `delegate_agent` action;
- declares its allowed delegate commands in registry metadata; the
  `delegate_agent` action validates and normalizes those strings without
  dynamic atom creation and rejects unknown names;
- returns advisory report packets — its output is descriptive, never
  authority (Section 4);
- owns no durable objective state, bypasses no registered action, and
  creates no plugin-private agent graph;
- introduces **no** new permission class, operation class, URI scheme,
  or registered action — every effectful step still grounds through
  the shipped v0.43 browser actions, Security Central, confirmations, and
  Resource Access posture.

What A21 unblocks:

- the `AgentRegistry`/`delegate_agent` contract can be **reviewed against
  two distinct domains** (financial specialists + research) before the
  v1.0 freeze, so the freeze locks a two-consumer-proven contract;
- the v0.44 workflow-YAML `command` field is reconciled with the runtime
  boundary through allowlisted command-string validation instead of an
  execute-only shortcut or arbitrary command dispatch;
- the plugin-author extension path for delegate agents becomes
  documented (`docs/developer/delegate-agents.md`), so the substrate is
  discoverable rather than implicit.

What A21 does **not** do:

- it does **not** extract a shared delegate-agent behaviour abstraction
  or refactor StockSage. Proving the contract against two consumers is a
  precondition for a future abstraction, not the abstraction itself;
- it does **not** add operator-authorable (no-code) delegate-agent
  creation. Operators authoring their own delegate agents remains parked
  (`docs/plans/future-features.md` §"Operator-Authorable And Third-Party
  Delegate Agents") behind the v0.36/v0.37/v0.38 supervised dynamic path;
- it does **not** promote any reserved advisory-provider role; A20
  stands unchanged.

### A22. Parallel planning and report composition are advisory Objective work (v1.3 M9.b.4/M9.b.5)

Status: accepted for v1.3 M9.b.4/M9.b.5 and implemented through the original
M9.b.5 selected-report authority contract at `b7ea776d`. The M9.b.4.2/M9.b.5.2
quality and synthesis refinements below are accepted for implementation;
executable, operator, and release evidence remains governed by
`docs/plans/v1.3-plan.md`.

Adaptive parallel work deepens the existing Intent → Objective → Action spine;
it does not create a fourth durable layer. On the clean DirectAnswer route, the
qualified conversation model may return either the ordinary answer or a typed,
inert parallel-work proposal. A deterministic compiler validates that proposal
before the existing Objectives fan-out Interface can create a parent or
children. The planning
model cannot select an action, permission, identity, confirmation result,
worker implementation, or delivery route. Exact counted fan-out protocols use
a model-independent Adapter to the same compiler.

Each compiled child remains an Objective. A normal Lifecycle Adapter executes
a validated non-DirectAnswer action; a temporary bounded Jido worker delegates
a clean conversational child to the same registered DirectAnswer action so its
existing policy stack remains authoritative. Conversation-manager children are
DirectAnswer-only. An exact-counted child may select a registered action only
when its task is an exact span of the digest-verified operator request; legacy
ordinary Objectives preserve their existing behavior. In every case,
model-authored child prose is advisory. Effect selection must retain evidence
from the original operator turn, and every effect still
resolves through `Actions.Registry`, executes through `Actions.Runner.run/3`,
and reaches Security Central and confirmations. A Jido worker's process,
parentage, state, output, or successful tool call is never durable authority.

M9.b.4.2 deepens only the temporary DirectAnswer worker for conversation-
manager, exact-counted, or verified operator-steered fan-out children. One source-bound
quality contract is derived from the digest-verified original request, compiled
child objective, expected-result guidance, the existing DirectAnswer rules, and
a small task-neutral child-coverage extension. The same typed rules derive the
prompt and closed review evidence; production behavior contains no domain
keyword/regex, prompt-specific fact, source-format oracle, or exact-answer
check. The private Jido lifecycle is `draft` → `review_and_revise` → `accepted`
or `unresolved`: the registered DirectAnswer action produces the draft, with model
failover disabled only in this grounded worker context, and the already-budgeted
second call uses the `fanout_synthesis` task chain to return the final answer and
closed rule verdicts. A non-model draft spends no review call; malformed,
negative, unavailable, or unresolved review fails the child honestly in that
attempt. Corrupt/untrusted provenance cannot enter this quality path. Ordinary
DirectAnswer fallback behavior is unchanged, and non-DirectAnswer children keep
the existing registered-action/effect-receipt contract without a model review.
Verified operator steering replaces the child objective, so its contract uses a
fixed Allbert-owned task-neutral completion instruction and binds the verified
directive/event digests instead of evaluating against stale pre-steer expected-
result prose.

The worker deterministically validates that advisory result and normalizes the
accepted answer at the existing durable Objective-summary boundary. A typed,
content-free quality receipt binds the Objective and step, task contract and
rule-catalog version, reviewer configuration, exact provider-call count, closed
verdict/failed-rule ids, and the exact normalized-answer digest; acceptance
requires the full two-call path. Lifecycle
observation verifies that binding before the existing terminal transaction can
store it in `run_completed`; recovery verifies it again before a completed
child may enter a new report snapshot. The receipt proves that the configured
review boundary ran, not that model judgment is authority: it cannot select an
action, grant permission, assert an effect, alter status, or create work.
Reviewed completion does not duplicate answer prose into that event payload:
the complete receipt and existing atomic Step id/status correlation are its only
members, while the exact normalized answer remains on the atomically committed
Objective/Step and the post-commit signal. This keeps the existing event-payload
bound without another store.

Under the original layout-v1 selection contract, deterministic reduction froze
child statuses, observations, and effect receipts and the composer used one
structured-output call over that snapshot. Its response was a content-free,
locally versioned relationship-section layout: closed
`complementary | contrasting | sequential | supporting | independent` enums
plus ordered completed-child queue positions. The deterministic compiler
requires those sections to partition every completed child exactly once and
rejects unknown positions, duplicates, omissions, extra fields, invalid
cardinality, and an all-independent result when two or more children completed.
All non-completed children remain outside model ordering and are rendered first
by Allbert's local deterministic compiler. The model writes none of the report
language and cannot revise the plan, child state, join outcome, permissions,
observations, failures, or receipt truth. Child detail remains explicitly an
observation; only a durable effect receipt reference supports an effect claim.
The resulting local rendering or deterministic complete-child fallback is
stored before report delivery becomes pending. Model refusal, truncation,
malformed output, provider failure, or unavailability therefore degrades
presentation without losing completion evidence or indefinitely withholding a
report.

M9.b.5.2 supersedes that write path without invalidating it: layout v1 remains
validated read/replay compatibility only, and every new selection writes layout
v2. `ReportComposer` remains the durable plain-GenServer owner of queueing,
claiming, compare-and-swap persistence, recovery, and delivery readiness. Inside
one claimed composition, a private ephemeral Jido synthesis lifecycle advances
from deterministic baseline through one `fanout_synthesis` structured call to
`accepted | unresolved`. That single result contains relationship sections,
one bounded model-authored advisory paragraph, and closed rule/child-coverage
evidence; it is both review and revision, not an additional judge or repair
call. Invalid, negative, unavailable, timed-out, or deadline-exhausted synthesis
selects a truthful deterministic fallback and never becomes healthy model
provenance. One pure `Fanout.Report.SynthesisPolicy` module owns the immutable
ordered synthesis rule catalog consumed by provider schema/prompt, local
validation, and selection provenance.

Layout v2 binds the original request, parent-only join guidance, each reviewed
DirectAnswer observation/quality-receipt digest, and each non-DirectAnswer
result/effect receipt. A historical DirectAnswer completion without the new
receipt remains readable but forces the closed `legacy_unreviewed_children`
fallback rather than model synthesis. With no completed child there is no
accepted advisory substrate: the composer makes no provider call and stores v2
fallback `no_completed_children` with outcome `not_run`. A persisted non-
DirectAnswer action must still resolve through the Action Registry before v2
labels it `registered_action`; unknown action identity fails v2 freeze, while
already-selected v1 replay remains byte-exact and independent of later Registry
removal. A completed child observation requires exact current-Step ownership and
a completed Step. Cancellation, stale abandonment, and retry-exhaustion
recovery may legitimately leave a non-completed child pointing at any valid
active or terminal Step status; v2 verifies ownership and the real Step status,
rejects completion/quality-receipt evidence for that non-result, Registry-
resolves any persisted non-DirectAnswer action identity, and keeps the child
outside synthesis. A missing Step is compatible only when `current_step_id` is
nil. Deterministic code still owns every
status and attention fact, failure/cancellation truth, effect receipt, ordered
authoritative child appendix, heading/label, byte allocation, digest,
persistence, and surface projection. The 16 KiB canonical model-input envelope
prioritizes the complete bounded request and fairly marks any unavoidable child
shortening. In the 32 KiB stored report, deterministic evidence has first claim
on bytes; advisory synthesis is one anti-spoofed paragraph of at most 4,096 UTF-8
bytes and cannot displace an otherwise complete child appendix. The model cannot
revise observations, identifiers, ordering, authority, delivery, or work.
The v2 appendix makes its closed authority explicit per child: a reviewed
advisory row names the verified quality-receipt digest and says that review is
not effect evidence; a registered-action row marks semantic review not
applicable and preserves the separate effect-receipt truth; a legacy-unreviewed
row exposes the absent receipt and required deterministic fallback. Layout-v1
rendering remains byte-exact. In layout v2, the operator-derived parent title
and every rendered child title, objective, and observation/detail are untrusted
display data. All occurrences use deterministic reversible JSON-string encoding
before Allbert-owned status/authority/receipt syntax, including ordinary,
fallback, attention, relationship, appendix, and emergency rendering; embedded
newlines therefore cannot forge a report boundary.

Every durable selection is bound twice: `report_input_digest` binds the frozen
authoritative snapshot, while `report_selection_digest` binds the selected
source and every exact normalized provenance field. Layout v1 keeps its existing
digest domains and closed provenance byte-for-byte for reads. Layout v2 uses the
versioned canonical domains `allbert:fanout-report-input:v2\0` and
`allbert:fanout-report-selection:v2\0`; model provenance additionally binds the
synthesis contract/review, reviewed child positions, and exact paragraph digest,
while fallback provenance binds its closed reason and `not_run | unresolved`
outcome and contains no model prose. Projection rehydrates and deterministically
re-renders the selected version against the event and stored body. Unknown
versions, a new v1 write, extra or missing provenance, changed source/fallback,
altered receipt/section/synthesis/body/input, or digest/event tampering fails
closed to inconsistent Objective state and cannot become a deliverable report.
An unselected queued or composing v1 input is verified and compare-and-swap
rebound in the existing immediate transaction to its authority-bearing v2
digest before claim/recovery selection; already-selected/pending/delivered v1
state is never rebound. One explicit integrity-error classifier lets queue scan
and recovery leave a corrupt parent untouched and continue later valid work;
bounded diagnostics retain each skipped parent id plus its typed content-free
reason instead of collapsing distinct integrity failures into an id range.
`recovery_after_restart` records `unresolved`, because a stranded `composing`
row cannot prove whether its single provider call crossed the boundary;
unclassified storage/operational failures still abort. Historical
pending/delivered v1 state remains on its explicit byte-exact compatibility
path.

The durable selection transaction precedes best-effort joined publication.
Signals are wake-ups rather than report authority: bounded API waiters perform a
final durable projection check, attached TUI sessions monitor/re-subscribe to
SignalBus and reconcile only their owned attachment set, and unattended
notification consumers reconcile the durable completion outbox. Publication
loss or a SignalBus-only restart can delay notification but cannot erase,
consume, or authorize a report.

This amendment does not promote the reserved generic Planner/Evaluator or
AdvisoryProvider vocabularies from A20. The v1.3 planner, worker, and composer
are private Allbert implementations at the existing Intent/Objectives seams.
Their tested Interfaces may inform a later extraction only after a second real
Adapter exists. TUI, Web, DMs, plugins, and public protocols do not implement
private planning, worker, or fan-in loops.

## Consequences

### What changes

- Three new SQLite tables: `objectives`, `objective_steps`,
  `objective_events`.
- New columns on `confirmations` (`objective_id`, `step_id`),
  `scheduled_jobs` (`objective_id`), `stocksage_analysis_queue`
  (`objective_id`, `step_id`), and `stocksage_analyses`
  (`objective_id`, `step_id`, plus btree index on `objective_id` per
  Amendment A4). All nullable; pre-v0.24 rows remain valid.
- Four sequential timestamped migrations (per v0.24 plan): three core
  migrations + one StockSage plugin migration.
- New `AllbertAssist.Objectives.*` modules; `Objectives.Engine.Agent`
  as a JidoBacked agent (built on v0.23 `AllbertAssist.JidoBacked`)
  under `AllbertAssist.JidoBacked.Supervisor`.
- New `:objective_write` permission class in Security Central
  (Amendment A1).
- New `:abandoned` objective status (Amendment A5).
- New objective signal namespace (11 signals), published through
  `Jido.Signal.Bus` under `AllbertAssist.SignalBus`; subscribers use
  `allbert.objective.**`. v0.24 preserves legacy
  `allbert.input.received` / `allbert.agent.responded` emissions and
  adds CoreApp-declared `allbert.runtime.turn.started` /
  `allbert.runtime.turn.completed` aliases. For single-step
  objectives, `allbert.runtime.turn.completed` and
  `allbert.objective.completed` share `trace_id` (Amendment A7).
- New `objectives.*` settings keys (4 implemented; ~15 reserved).
- New `mix allbert.objectives list|show|cancel|continue` CLI
  commands; `cancel --reason` is required.
- New `## Objective` and `## Objective Steps` trace sections.
- StockSage `RunAnalysis` accepts optional `objective_id`/`step_id`
  parameters; threaded through confirmation, audit, trace, and the
  `stocksage_analyses` row.
- New `StockSage.Proposer` module registered via
  `AllbertAssist.Objectives.Proposer.register_app_proposer/2` at
  app boot (Amendment A9).
- LiveView `/agent` (AgentLive) gains an objective badge component;
  new `/objectives/:id` (AllbertAssistWeb.ObjectiveLive) renders the
  objective view with cancel/continue controls.
- Telegram and email confirmation rendering includes objective
  context when applicable.
- New `Intent.Engine.collect_candidates/2` arity surfaces
  `:objective` candidates without breaking the existing `/1` arity
  (Amendment A10).
- Minimal `:delegate_agent` step kind contract shipped so v0.25
  specialist agents have a binding target (Amendment A3).
- ADR 0019 amended at v0.24 M2 to register `:objective` as a
  candidate kind.
- Hybrid proposer contract (`{:more, hint}` / `:done` /
  `{:no_steps, _}`) shipped so multi-step objectives can stream
  proposals across observation cycles (Amendment A11). Engine
  persists hints in durable `objectives.proposer_hint` JSON and caches
  them in JidoBacked agent state under `proposer_hints`.
- Acceptance criteria are persisted as structured JSON in
  `objectives.acceptance_criteria` (Amendment A12). Evaluator clauses
  are deterministic and reject unknown kinds at changeset
  validation.
- Directive-only JidoBacked command output is explicitly supported and advisory
  only (Amendment A13).
- The v0.24 objective command graph is 10 real private `Jido.Action` modules;
  no `Commands.Noop` placeholders ship (Amendment A14).
- `AllbertAssist.Objectives` exposes lifecycle facade functions while keeping
  lower-level store helpers in the same module as internal runtime helpers
  (Amendment A15).
- `AllbertAssist.Objectives.AgentRegistry` ships as an empty monitored local
  GenServer registry in v0.24 (specialist agents register themselves in
  v0.25+). It exposes `register/4`, `lookup/1`, `list/0`, `unregister/1`, and
  `dispatch/4`, monitors registered servers, and evicts dead entries
  (Amendment A16).
- `mix allbert.objectives` enforces documented OS exit codes through a
  test-injectable halt function (Amendment A17).
- `AllbertAssistWeb.SignalBridge` GenServer (web-app side) bridges
  `allbert.objective.**` signals to per-user Phoenix.PubSub topics so
  AgentLive + ObjectiveLive update in real time. Engine never knows
  about Phoenix.PubSub; web-app graceful absence falls back to
  5-second poll.
- `objectives.continue` action is **idempotent for no-progress
  calls**: returns `{:ok, %{status: :still_blocked, reason}}` without
  `loop_count` increment or impasse event when nothing has changed
  since the objective was blocked. Terminal statuses are advisory no-ops:
  `:objective_abandoned`, `:objective_cancelled`, `:objective_failed`, and
  already `:completed` return status/reason and do not mutate the row.
- Confirmations carry a snapshot of `objective_title` +
  `objective_status` in `params_summary` at creation. Renderers fetch
  the live objective row and prepend a stale-warning `Note:` line
  when the snapshot diverges. Applies uniformly across CLI,
  Telegram, email, and LiveView.
- Trace markdown places objective context as **inline `### Objective`
  subsections** under each top-level section that touched the
  objective during the turn (Selected Skill, Confirmation, Action
  Result, Intent Candidates, Memory Review). A dedicated top-level
  `## Objective Steps` section also renders per turn.
- Per-app `StockSage.Proposer` registers at app boot via
  `AllbertAssist.Objectives.Proposer.register_app_proposer/2`. v0.24
  ships exactly one registered proposer; proposer rules are
  hardcoded Elixir, not settings data.

### What stays the same

- `Actions.Runner.run/3` + Security Central + confirmations remain
  the only effectful boundary.
- `Intent.Engine` continues as candidate ranking infrastructure;
  ADR 0019 invariants hold; the engine gains an `:objective`
  candidate kind.
- All v0.07, v0.13, v0.16, v0.21, v0.22 acceptance criteria
  continue to hold.
- SQLite remains authoritative for durable state; the engine agent
  is a cache.
- `active_app` remains session context, not authorization.
- Markdown memory remains the source of truth; the v0.21 review
  surface remains the only writer.

### What's reserved but not implemented

Per Section 3, the following vocabulary is reserved and documented
in this ADR. No code is shipped for them in v0.24:

- Capability inventory, gap, route, acquisition option modules.
- Advisory provider umbrella behaviour and all nine provider roles.
- World-model provider behaviour with `encode_state`,
  `predict_latent_transition`, `compare_prediction_to_observation`,
  etc.
- Diffusion proposer, market allocator, probabilistic inference
  provider.
- Hook contribution API for plugins/apps.
- LLM-assisted step proposer or acceptance evaluator.
- Parallel step execution.
- Capability acquisition automation.

These are documented in `docs/research/objective-runtime-research.md`
along with the primary-source citations that motivate each.

### Migration story for v0.20 StockSage queue and analyses

The v0.20 `stocksage_analysis_queue` records are a domain-specific
objective table. v0.24 does **not** migrate that data into the new
`objectives` table. The queue records gain optional `objective_id`
and `step_id` columns; new queue entries created from objective
steps carry the parent objective id and step id. Pre-v0.24 queue
rows have NULL.

Per Amendment A4, `stocksage_analyses` also gains `objective_id` and
`step_id` columns plus a btree index on `objective_id`. This
enables efficient "list analyses for this objective" queries
directly against the analyses table without requiring a join through
the queue. Pre-v0.24 analyses rows have NULL.

A future milestone may define the queue as a *view* over objectives
+ steps, but that migration is out of scope for v0.24.

## Alternatives Considered

### Alternative B: Build inside StockSage native agents

Reject. Putting the objective shape inside one app means cross-
cutting concerns (Security Central integration, traces, redaction,
audit, cross-channel resume) get wired through StockSage first.
Later extraction is a refactor rather than a clean library.

### Alternative C: Extend confirmations + jobs as the durable spine

Reject. Adding `objective_id` to existing tables without a new
entity means cross-record joins remain manual, impasse and progress
semantics get bolted onto existing tables, and reflection candidates
have no home. The first-class "what is Allbert pursuing right now"
question stays unanswered.

### Alternative D: Defer entirely

Reject. By the time pain shows up in v0.25+ native financial agents and
workspace shell, those subsystems will have shaped private
continuation patterns. Later extraction is more expensive than
inserting the layer now while StockSage is the only proving app.

### Sixteen-stage pipeline

Reject. The rethink draft's sixteen-stage breakdown is brainstorming.
Five of the seven stages in this ADR already exist in some form
(receive, interpret intent, authorize, execute, observe). Adding
three (frame, propose-and-evaluate, observe-and-advance) is enough
for v0.24 acceptance. Sixty named hook points without consumers
are dead reservation; this ADR names five.

### Full Jido.Agent convergence as part of v0.24

Reject. The user's project-direction rethink decision separates this
from v0.24. v0.23 Jido State-Machine Convergence converts the two
clearest existing fits (`Confirmations.Store` + `Jobs.Scheduler`).
v0.24 builds Objectives.Engine on top of that converged substrate.
Storage components (Settings, Trace, Memory IO, Scratchpad) stay as
plain GenServers per the pragmatic rule.

### Advisory provider umbrella behaviour in v0.24

Reject. v0.24 has one deterministic proposer and one deterministic
evaluator. Designing an interface before two consumers exist is
premature. The first behaviour extraction happens when a real second
provider (LLM-assisted proposer in v0.25, world-model evaluator
later) is on the path.

### Hermes-style execute_code meta-tool

Reject. Hermes Agent (Nous Research) lets the LLM write Python that
calls other Hermes tools via a local RPC bridge. This collapses many
tool calls into one model turn but concentrates authority in a
meta-tool. Allbert's action/Security Central boundary is designed
to prevent this concentration. Each step that mutates state runs
through one registered action with its own permission check and
audit record.

### LLM-as-completion-judge

Reject. Hermes lets the LLM decide a goal is done. Allbert's
acceptance evaluator is deterministic in v0.24. Future LLM-assisted
evaluators are reserved vocabulary, but the rule above
(Authority rule, Section 4) applies: LLM evaluator output is
advisory; the deterministic acceptance check (against
`acceptance_criteria` and observation data) is authoritative.

## References

- `docs/archives/project-direction-rethink-01.md` — the rethink draft
  that motivates this ADR.
- `docs/plans/archives/v0.23-plan.md` — Jido State-Machine Convergence
  (prerequisite).
- `docs/plans/archives/v0.24-plan.md` — Objective Runtime Foundation (where
  this ADR is implemented).
- `docs/plans/archives/v0.24-request-flow.md` — engine flows.
- `docs/research/objective-runtime-research.md` — primary-source
  citations and provider research.
- ADR 0006 — Security Central as policy evaluation boundary.
- ADR 0007 — Jido-native internal runtime boundaries.
- ADR 0008 — Durable confirmation requests as action state.
- ADR 0014 — Local workspace identity.
- ADR 0015 — Allbert app contract and Surface DSL.
- ADR 0019 — Cross-surface intent enrichment.
- ADR 0020 — StockSage Python bridge protocol.
- ADR 0022 — Native financial specialist agents.

External references (full list in the research note):

- Hermes Agent (Nous Research) — `/goal` command, sub-agent
  delegation, no first-class objective entity.
- OpenClaw — hub-and-spoke gateway, per-session serial queues,
  trust-tiered runtime sandboxing.
- BDI (Belief–Desire–Intention) — durable separation of beliefs,
  desires, intentions, plans.
- Soar — impasses as first-class.
- ReAct — interleave reasoning and acting.
- HTN planning — hierarchical task decomposition (reserved
  vocabulary).
- Tree of Thoughts — deliberate span-out and evaluation.
- Workflow Memory — reusable workflows from traces.
- World Models surveys, JEPA family, diffusion planners, FrugalGPT,
  RouterBench, RouteLLM, OpenAI Agents SDK guardrails, LangGraph
  state and graph patterns, Jido documentation.
