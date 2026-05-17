# ADR 0021: Intent, Objective, Capability, And Advisory Boundary

## Status

Proposed. Targeted for acceptance with v0.24 Objective Runtime Foundation
M6 closeout. Amendments below (Section: v0.24 Amendments) enumerate the
plan-level decisions that crystallized during the third validation pass
on 2026-05-16.

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
   v0.24/v0.25 native trading agents will either duplicate this
   pattern or invent something incompatible.
4. **v0.22 `RunAnalysis` confirmation flow.** A multi-step request
   like "analyze AAPL and compare to MSFT" cannot be represented as
   one work item that spans two `RunAnalysis` confirmations.

The project-direction rethink draft
(`docs/plans/project-direction-rethink-01.md`) proposes adding an
objective runtime layer between intent selection and action execution.
This ADR records the binding decisions that govern that layer.

The rethink draft also reserves vocabulary for future advisory
providers (LLM-based step proposers, world models, diffusion proposers,
market allocators, capability inventory, route proposal, acquisition
options). That vocabulary needs an authority rule that survives all
future provider implementations, so this ADR records it now even
though most providers are not implemented in v0.24.

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
deferred until v0.25+ has a clearer story for native trading
agents and bridge processes.

### 8. Coexisting signals

`allbert.objective.*` signals emit alongside existing
`allbert.action.*` and `allbert.runtime.turn.*` events. No existing
signal is removed or renamed. Trace volume is bounded by
`objectives.trace_detail` (default `:operator`).

### 9. Pragmatic substrate rule (from v0.23)

`Objectives.Engine` is a Jido.Agent because it is a stage state
machine with lifecycle hooks that earn their keep. New state-bearing
components author chooses Jido.Agent or plain GenServer based on
plausible value (state machine, lifecycle hooks, successor-agent
story). This is not a hard rule; reviewers judge case-by-case.

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
  via the new `AllbertAssist.Objectives.Actions.DelegateAgent`
  registered action.
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
the two without scanning per-turn payload identifiers. This is the
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
- New `allbert.objective.*` signal namespace (11 signals); both
  `allbert.runtime.turn.completed` and `allbert.objective.completed`
  share `trace_id` for single-step objectives (Amendment A7).
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

Reject. By the time pain shows up in v0.25+ native agents and
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

- `docs/plans/project-direction-rethink-01.md` — the rethink draft
  that motivates this ADR.
- `docs/plans/v0.23-plan.md` — Jido State-Machine Convergence
  (prerequisite).
- `docs/plans/v0.24-plan.md` — Objective Runtime Foundation (where
  this ADR is implemented).
- `docs/plans/v0.24-request-flow.md` — engine flows.
- `docs/research/objective-runtime-research.md` — primary-source
  citations and provider research.
- ADR 0006 — Security Central as policy evaluation boundary.
- ADR 0007 — Jido-native internal runtime boundaries.
- ADR 0008 — Durable confirmation requests as action state.
- ADR 0014 — Local workspace identity.
- ADR 0015 — Allbert app contract and Surface DSL.
- ADR 0019 — Cross-surface intent enrichment.
- ADR 0020 — StockSage Python bridge protocol.

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
