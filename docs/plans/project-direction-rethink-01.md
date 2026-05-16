# Project Direction Rethink 01

Status: working analysis draft.

Purpose: capture the current rethink that Allbert should be organized around
both intent understanding and objective/outcome management, with future room
for world-model providers beyond LLM/GPT-style language models.

This document is intentionally root-level and temporary while the project
direction is being questioned. It is not yet an ADR, roadmap, or implementation
plan. It is a coordination artifact for the human operator and future agents.

## Instructions For Future Agents

Read this file as a living architecture notebook, not as binding project law.
When asked to continue the rethink:

1. Separate facts from proposals.
2. Verify current repo state before making claims. Read at least:
   `docs/plans/allbert-jido-vision.md`, `docs/plans/roadmap.md`,
   `docs/plans/future-features.md`, the active milestone plan, relevant ADRs,
   and the current code around runtime, intent, actions, jobs, traces, memory,
   and StockSage.
3. Use web research when the user asks for research or when current AI-agent,
   planning, world-model, or framework terminology matters. Prefer primary
   papers, official docs, and reputable technical sources.
4. Update this file incrementally as questions are answered. Keep unresolved
   questions visible rather than smoothing them over.
5. Do not implement code directly from this file. First translate accepted
   conclusions into ADRs, roadmap edits, milestone plans, coding policies, and
   testable acceptance criteria.
6. If this file conflicts with accepted ADRs, active plans, or code, call out
   the conflict explicitly and propose a reconciliation.
7. Do not add AI-tool attribution, generated-by footers, or co-author trailers
   to this file, commits, PR text, release notes, or generated docs.

When extending this document, use these sections:

- "Current Claim" for the architectural idea under evaluation.
- "Evidence" for code/doc observations and external research.
- "Implications" for what changes if the claim is accepted.
- "Concrete Doc Edits" for files/plans/ADRs that need updating.
- "Open Questions" for items that need the operator's decision.

## Current Claim

Allbert should not be organized only around "intent routes to action." That is
too flat for agentic work.

The system should distinguish:

- Intent: what the user appears to mean or request right now.
- Objective: the outcome Allbert is trying to achieve across one or more
  actions, steps, agents, surfaces, jobs, and confirmations.
- Step: a bounded unit of work inside an objective.
- Observation: an actual result from the environment, runtime, action,
  channel, job, memory, trace, or user.
- World model: a future predictive or counterfactual model of how state may
  change under proposed actions. This is not the same thing as an LLM.
- Planner/evaluator: proposal and assessment logic that may use deterministic
  rules, LLMs, world models, traces, memory, or app-specific context.
- Hook: a bounded extension point before, after, or around a stage. Hooks can
  guard, enrich, propose, evaluate, consolidate, observe, reflect, or render.
  Hooks are not authority.
- Impasse: a first-class blocked-thinking state, such as no viable step, too
  many unresolved steps, missing context, pending confirmation, or selected
  step unavailable.

Proposed core loop:

```text
input signal
  -> perceive/intake
  -> orient/context assembly
  -> intent interpretation
  -> objective framing or resumption
  -> objective admission and constraint check
  -> span-out: propose possible operators/steps/workflows
  -> retrieve: memory, workflow memory, app/domain context
  -> evaluate/simulate: policy, risk, world-model predictions, cost, feasibility
  -> consolidate: compare, prune, merge, rank, and explain candidates
  -> commit: choose the next bounded step, ask the user, or block
  -> authorize: Security Central, resource posture, confirmation
  -> execute through registered actions only
  -> observe action/runtime/user/environment result
  -> reflect/consolidate: traces, memory candidates, workflow learning
  -> evaluate progress against objective acceptance criteria
  -> repeat, block, cancel, fail, or complete
```

The user's language for this was: intent first, objective after or in parallel,
then span-out, span-in, hierarchy, consolidate, and repeat until the actual
outcome is reached.

Important refinement: not every item above needs to become a durable database
row in v0.23. Some are concrete state-machine phases; others are hook points
where plugins, apps, policies, memories, model providers, or future world
models can contribute advisory data. The durable v0.23 records should stay
small: objectives, objective steps, and objective events. The richer stages can
be represented as event types, trace sections, and hook contracts first.

## Why This Matters Now

Allbert is almost done with v0.22, the StockSage Python bridge. The next planned
milestone is native Jido trading agents. That is the first real multi-agent
domain workflow.

If native StockSage agents are implemented before a shared objective runtime,
StockSage is likely to invent a private goal/task orchestration model. Later,
the workspace shell, ephemeral UI, canvas, jobs, memory review, and app
generator would either duplicate or migrate around that private model.

Because the project is not production code yet and backward compatibility is
not a priority, this is a good moment to insert the missing substrate rather
than preserve old plan shape.

## Current Repo Map

The current code already has many pieces needed for an objective loop, but they
are not connected by a named objective layer.

Relevant modules and responsibilities:

- `AllbertAssist.Runtime`: receives normalized user/channel input, creates
  input/response signals, persists conversation messages, calls the intent
  agent, records traces, and returns channel-renderable responses.
- `AllbertAssist.Agents.IntentAgent`: primary agent facade. It still contains
  deterministic route predicates, then uses `AllbertAssist.Intent.Engine` for
  registry-aware candidate ranking and metadata.
- `AllbertAssist.Intent.Decision`: inert selected-route contract. It describes
  selected skill/action/surface/resource posture, user/session/app context, and
  approval handoff. It should not become objective state.
- `AllbertAssist.Intent.Engine`: collects and ranks candidates from actions,
  skills, surfaces, jobs, channels, memory, and refusals. It is proposal
  infrastructure, not authority and not a durable planner.
- `AllbertAssist.Intent.Candidate` and `AllbertAssist.Intent.Ranker`: bounded,
  redacted proposal/ranking data.
- `AllbertAssist.Actions.Runner`: required action execution boundary for
  lifecycle signals, permission decisions, redaction, and Security Central.
- `AllbertAssist.Jobs`: durable recurring/background execution, but not a
  general objective/task graph.
- `AllbertAssist.Conversations`: SQLite thread/message history, but not
  outcome/progress state.
- `AllbertAssist.Session.Scratchpad`: volatile session context and
  `active_app`, but not durable objectives.
- `AllbertAssist.Trace`: records what happened, but does not manage objective
  progress.
- `AllbertAssist.Memory`: markdown source of truth plus derived index and
  retrieval, but not objective state.
- `StockSage`: first proving app. It has local domain records, queue, actions,
  plugin/app registration, and v0.22 bridge plans. It should consume the
  shared objective model rather than invent a private one.

## External Research Summary

The research direction supports separating intent, objective, planning,
execution, observation, and model providers.

Key takeaways:

1. LLMs are useful proposal, reasoning, and language interfaces, but they
   should not be the architecture. ReAct shows the value of interleaving
   reasoning and action. Tree of Thoughts shows deliberate span-out/search and
   evaluation over possible reasoning paths. LLM-agent planning surveys frame
   the field around task decomposition, plan selection, tools, feedback, and
   memory.
2. Objective state is older than LLM agents. BDI work separates beliefs,
   desires/goals, intentions, and plans. Allbert does not need to import BDI
   wholesale, but it should preserve the separation between what is known,
   what outcome is desired, what commitment is active, and what plan/step is
   executing.
3. World models are not "better GPTs." A world model predicts or simulates how
   state may change under actions. It can support counterfactual evaluation,
   planning, risk estimation, or simulated rollouts. It is distinct from an
   LLM that proposes, summarizes, critiques, or translates.
4. The "Language Models, Agent Models, and World Models" framing is useful for
   Allbert: language models, agent models, and world models are separate
   provider roles. The Allbert architecture should reserve extension points for
   all three.
5. Skill libraries, reflection, and memory matter. Voyager, Reflexion, and
   Generative Agents point toward reusable skills, feedback loops, reflection,
   and memory/planning integration. Allbert already has skills, memory, traces,
   jobs, actions, plugins, and surfaces; the missing shared layer is durable
   objective/step state.

Sources reviewed or identified:

- ReAct: https://arxiv.org/abs/2210.03629
- Tree of Thoughts: https://arxiv.org/abs/2305.10601
- Understanding the planning of LLM agents:
  https://arxiv.org/abs/2402.02716
- World Models: https://arxiv.org/abs/1803.10122
- DreamerV3: https://arxiv.org/abs/2301.04104
- Genie: https://arxiv.org/abs/2402.15391
- A Path Towards Autonomous Machine Intelligence:
  https://openreview.net/pdf/315d43ba26f55357a84cec9a7ed15a6610094f79.pdf
- Language Models, Agent Models, and World Models:
  https://arxiv.org/abs/2312.05230
- Voyager: https://arxiv.org/abs/2305.16291
- Reflexion: https://arxiv.org/abs/2303.11366
- Generative Agents: https://arxiv.org/abs/2304.03442
- BDI model discussion:
  https://turing.cs.pub.ro/ai_mas/papers/bdi.pdf
- PDDL/HTN planning families should be researched further if Allbert adopts a
  stronger formal planner vocabulary.
- Soar cognitive architecture:
  https://soar.eecs.umich.edu/soar_manual/02_TheSoarArchitecture/
- Hierarchical Task Network planning overview:
  https://arxiv.org/abs/1403.7426
- Agent Workflow Memory:
  https://arxiv.org/abs/2409.07429
- Memory for Autonomous LLM Agents:
  https://arxiv.org/abs/2603.07670
- From Agent Loops to Structured Graphs:
  https://arxiv.org/abs/2604.11378
- OpenAI Agents SDK guardrails:
  https://openai.github.io/openai-agents-python/guardrails/
- LangGraph graph/state docs:
  https://docs.langchain.com/oss/python/langgraph/graph-api
- LangGraph "Thinking in LangGraph":
  https://docs.langchain.com/oss/python/langgraph/thinking-in-langgraph
- Jido docs via Context7:
  `/agentjido/jido` and `/agentjido/jido_signal`

## Research Update: More Than Intent, Objective, Action

The last pass framed Allbert as:

```text
intent recognition -> objective recognition/creation -> action creation/execution
```

That is directionally right but still too coarse. The research suggests a
finer architecture:

- LLM-agent planning surveys split the problem into task decomposition, plan
  selection, external modules, reflection, and memory.
- Soar separates working memory, operator proposal, operator selection,
  operator application, impasses, and subgoals. The important Allbert lesson is
  that "no operator," "too many operators," and "cannot apply operator" are
  first-class impasses, not weird errors.
- HTN planning is useful as a vocabulary for high-level tasks decomposing into
  lower-level tasks, but Allbert should not adopt a formal HTN planner in
  v0.23. It should reserve hierarchy and decomposition semantics.
- Workflow-memory research suggests repeated action trajectories can become
  reusable workflows. Allbert's skills and markdown memory are not enough by
  themselves; objective traces should later be compilable into workflow
  candidates.
- Memory-agent research emphasizes write/manage/read loops coupled to
  perception and action. Allbert's v0.21 memory review/index work fits this,
  but objective work should explicitly decide what observations are candidates
  for memory, workflow memory, or no durable storage.
- Structured graph approaches and LangGraph-style systems reinforce that
  long-running agent work benefits from explicit state, nodes/steps, edges,
  checkpoints, and migrations rather than an opaque "agent loop" over a growing
  context window.
- Guardrail systems distinguish checks at input, output, and tool boundaries.
  Allbert already has Security Central at the action boundary; v0.23 should
  add objective-stage guard hooks without weakening action-boundary policy.
- Jido gives Allbert a native substrate for this: agents with lifecycle hooks,
  actions with schemas, signals as CloudEvents-like lifecycle records, and
  directives for emitting signals, scheduling, spawning child agents, or
  stopping work.

Conclusion: Allbert needs an objective runtime, but it also needs named stage
boundaries and hook points. The hooks should be explicit and inspectable, but
most should begin as signal/trace extension points, not public plugin APIs with
side effects.

## Expanded Cognitive Runtime Pipeline

This is the current recommended pipeline for v0.23+ design.

### 1. Intake / Perception

Purpose: receive user, channel, job, app, or internal input and normalize it
into an Allbert request.

Concrete today:

- `Runtime.submit_user_input/1`
- channel adapters
- scheduled jobs
- action callbacks and confirmations

Future objective role:

- Attach or derive `objective_id` only when the input resumes or creates
  durable work.
- Preserve raw input, normalized text, channel, user, thread, session,
  active_app, and metadata.

Hooks:

- `before_intake_normalize`
- `after_intake_normalize`
- `intake_rejected`

Jido substrate:

- input signals such as `allbert.input.received`
- pure normalizer modules for shape checks
- optional guard actions only if validation becomes effectful

### 2. Guard / Safety Preflight

Purpose: reject or downgrade unsafe input before expensive planning, model
calls, or objective creation.

This is not a replacement for Security Central. It is an early tripwire layer
for malformed, spoofed, impossible, or explicitly disallowed requests.

Hooks:

- `before_intent_guard`
- `after_intent_guard`
- `guard_tripwire`

Jido substrate:

- signals for rejected input
- settings-backed guard configuration
- no execution authority

### 3. Orientation / Context Assembly

Purpose: assemble the local situation before interpreting intent: user,
thread, recent messages, active app, session scratchpad, channel context,
memory snippets, plugin/app registry context, and existing objective state.

Concrete today:

- `Conversations`
- `Session.Scratchpad`
- `App.Registry`
- `Plugin.Registry`
- `Memory.Index`
- `Trace`

Hooks:

- `before_context_assembly`
- `context_provider`
- `after_context_assembly`

Jido substrate:

- pure context providers where possible
- read-only registered actions when provider access is runtime-facing or
  observable
- `allbert.context.assembled` signal later if useful

### 4. Intent Interpretation

Purpose: determine what the user appears to mean now. This remains about the
current input, not the whole work outcome.

Concrete today:

- `IntentAgent`
- `Intent.Engine`
- `Intent.Decision`
- `Intent.Candidate`
- `Intent.Ranker`

Hooks:

- `before_intent_recognition`
- `candidate_provider`
- `intent_classifier`
- `after_intent_recognition`

Jido substrate:

- `Intent.Engine` remains candidate infrastructure
- `Intent.Decision` remains inert selected interpretation/route
- model classifiers are advisory and bounded

### 5. Objective Framing / Resumption

Purpose: decide whether the input should create, resume, update, or avoid a
durable objective.

Examples:

- "hello" probably has no durable objective.
- "remember that I prefer concise release notes" is an action with maybe no
  durable objective.
- "analyze AAPL and compare it to MSFT" should create or resume a StockSage
  objective.
- "continue that analysis" should resume the current or referenced objective.

Hooks:

- `before_objective_frame`
- `objective_candidate_provider`
- `objective_resume_resolver`
- `after_objective_frame`

Jido substrate:

- `AllbertAssist.Objectives.Engine`
- objective-created/updated signals
- SQLite objective row for durable work

### 6. Objective Admission / Constraint Check

Purpose: decide whether the objective is admissible before planning begins.
This checks scope, user ownership, active app, background permissions,
resource posture, max depth, max steps, cost/rate budgets, and whether the
system should ask the user to clarify.

Hooks:

- `before_objective_admission`
- `objective_policy`
- `objective_clarification_needed`
- `after_objective_admission`

Jido substrate:

- pure policy modules for local checks
- registered actions only for runtime-visible policy changes
- objective status can become `blocked`

### 7. Span-Out / Operator And Step Proposal

Purpose: propose possible next steps, operators, specialist agents, app
actions, workflows, or questions.

This stage should produce proposal data. It should not execute.

Possible providers:

- deterministic rules
- app-provided planner hints
- skills
- prior objective traces
- workflow memory
- LLM planner proposals
- world-model predictions
- StockSage domain planner

Hooks:

- `before_span_out`
- `step_proposer`
- `workflow_provider`
- `specialist_agent_provider`
- `after_span_out`

Jido substrate:

- candidate step records with `status: proposed`
- `allbert.objective.step.proposed` signals
- Jido agents may propose, but proposed steps must validate against known
  action/app/skill/surface contracts

### 8. Retrieval / Working Context Enrichment

Purpose: retrieve or compile support context for proposed steps. This is
separate from intent context because it is objective/step-specific.

Examples:

- relevant memory entries
- prior workflow traces
- StockSage existing analysis records
- queue state
- recent errors
- app settings
- thread excerpts

Hooks:

- `before_step_context_retrieval`
- `step_context_provider`
- `after_step_context_retrieval`

Jido substrate:

- read-only actions where provider access should be observable
- pure modules for local derived artifacts
- trace section for retrieved context summaries, never unbounded content

### 9. Evaluate / Simulate / Score

Purpose: evaluate proposed steps before committing. This includes policy,
resource risk, expected cost, feasibility, likely progress, world-model
prediction, and whether the user must be asked.

This is where future world models fit.

Hooks:

- `before_step_evaluation`
- `step_evaluator`
- `world_model_provider`
- `risk_evaluator`
- `cost_evaluator`
- `after_step_evaluation`

Jido substrate:

- world-model providers are behaviours/plugins that return predictive
  metadata only
- Security Central still owns actual permission at action execution
- prediction signals must be labeled as simulated/counterfactual

### 10. Consolidate / Span-In

Purpose: merge duplicates, prune unsafe or irrelevant proposals, rank
remaining proposals, explain the tradeoffs, and select one or more next steps.

This stage corresponds to the user's "span-in" language.

Hooks:

- `before_consolidation`
- `step_ranker`
- `conflict_resolver`
- `after_consolidation`

Jido substrate:

- deterministic ranking first
- model-assisted ranking optional later, advisory only
- `allbert.objective.step.selected` signal

### 11. Commitment / Dispatch Decision

Purpose: commit to a next step, ask a question, wait for external input, or
block on confirmation.

Step kinds:

- `action`
- `ask_user`
- `wait`
- `delegate_agent`
- `surface`
- `observe`
- `evaluate`

Hooks:

- `before_step_commit`
- `after_step_commit`
- `on_impasse`

Jido substrate:

- objective step moves from `proposed` to `selected`, `blocked`, or
  `cancelled`
- impasses are first-class events, not silent failures
- Jido directives may schedule, emit, spawn agent children, or stop work

### 12. Authorization / Confirmation / Resource Binding

Purpose: bind a selected action step to real authority checks.

Concrete today:

- `Actions.Runner`
- `Security Central`
- `ResourceAccess`
- `Confirmations`

Hooks:

- `before_action_authorization`
- `after_action_authorization`
- `confirmation_created`
- `confirmation_resolved`

Jido substrate:

- registered actions only
- Security Central at action boundary
- no objective/world-model/model/provider hook can bypass this

### 13. Execution

Purpose: execute exactly the selected, authorized action or agent step.

Hooks:

- `before_action_execute`
- `after_action_execute`
- `action_failed`

Jido substrate:

- `Actions.Runner.run/3`
- Jido actions for effectful work
- Jido agents for bounded decision loops or specialist coordination
- action lifecycle signals

### 14. Observation / Result Assimilation

Purpose: turn action results, channel replies, job outcomes, bridge responses,
or user feedback into objective-relevant observations.

Hooks:

- `before_observation_record`
- `observation_normalizer`
- `after_observation_record`

Jido substrate:

- objective event row
- trace linkage
- `allbert.objective.observed` signal

### 15. Reflection / Consolidation / Learning

Purpose: decide what should be remembered, summarized, converted to workflow
memory, or left only in traces.

This is not automatic memory mutation. It is candidate generation and review.

Hooks:

- `before_reflection`
- `reflection_provider`
- `memory_candidate_provider`
- `workflow_memory_candidate_provider`
- `after_reflection`

Jido substrate:

- memory writes remain registered actions with confirmation where needed
- workflow memory begins as derived candidate artifacts, not executable trust
- trace sections capture reflection proposals

### 16. Progress Evaluation / Continuation

Purpose: compare current state to objective acceptance criteria and decide
whether to continue, complete, block, fail, or ask the user.

Hooks:

- `before_progress_evaluation`
- `objective_evaluator`
- `completion_verifier`
- `after_progress_evaluation`

Jido substrate:

- objective status transition
- bounded repeat loop
- max step/depth/cost/time controls
- `allbert.objective.completed`, `blocked`, `failed`, or `updated` signals

## Hook Taxonomy

Not all hooks are the same. v0.23 should name the categories even if only a
few are implemented.

- Guard hooks: may block or downgrade a stage before expensive or unsafe work.
- Enrichment hooks: add bounded context or metadata.
- Proposal hooks: generate candidate intents, objectives, steps, workflows, or
  surfaces.
- Evaluation hooks: score risk, cost, feasibility, or predicted progress.
- Consolidation hooks: merge, rank, prune, deduplicate, or explain candidates.
- Observation hooks: normalize what happened.
- Reflection hooks: propose memory, workflow, or trace consolidation.
- Rendering hooks: shape what a channel or surface should show, without owning
  domain logic.

Authority rule: a hook can produce proposal data, diagnostics, warnings,
scores, predictions, or renderable summaries. A hook cannot grant permission,
execute effects, mark simulated state as real, or bypass action boundaries.

## Hook Lifecycle Shape

Recommended generic event vocabulary:

```text
allbert.stage.started
allbert.stage.completed
allbert.stage.rejected
allbert.stage.blocked
allbert.stage.failed
allbert.hook.started
allbert.hook.completed
allbert.hook.rejected
allbert.hook.failed
```

Each stage signal should include:

- `stage`
- `objective_id` when applicable
- `step_id` when applicable
- `user_id`
- `thread_id`
- `session_id`
- `active_app`
- `trace_id`
- `source_signal_id`
- bounded diagnostics

Each hook result should include:

- `hook_id`
- `hook_type`
- `provider`
- `status`
- `proposals` or `diagnostics`
- `redaction_applied`
- `simulated?` when applicable
- `authority`: always `proposal_only` unless it is an existing action runner
  or Security Central boundary

## Jido Substrate Mapping

Jido should not be treated as just a tool-calling wrapper. It maps well to the
expanded pipeline:

- Jido signals represent stage, hook, action, objective, observation, and trace
  lifecycle events. Jido Signal's CloudEvents-style fields give Allbert a good
  shape for causality and source metadata.
- Jido agents own bounded decision loops: intent interpretation, objective
  planning, specialist StockSage analysis roles, reflection, or diagnostics.
- Jido actions remain the only effectful capability boundary. A proposed
  objective step becomes executable only when it resolves to a registered
  action and passes Security Central.
- Jido Agent lifecycle hooks such as `on_before_cmd/2` and `on_after_cmd/3`
  are useful for invariant checks, state mirroring, validation, and audit
  inside a particular agent. They should not become the whole Allbert hook
  system by themselves, because Allbert needs cross-agent, cross-stage,
  signal-visible hooks.
- Jido directives can emit signals, spawn child agents, schedule work, or stop
  work. These should be used for objective lifecycle orchestration only after
  objective/step state has been recorded.
- Jido Signal Bus middleware and future journal support can host cross-cutting
  concerns such as logging, redaction checks, causality, and dispatch, but
  Security Central still belongs at the action boundary.

Proposed Allbert layer on top of Jido:

```text
AllbertAssist.Objectives.Engine        # runs the stage state machine
AllbertAssist.Objectives.Hooks         # internal hook dispatcher
AllbertAssist.Objectives.HookProvider  # future plugin/app contribution behaviour
AllbertAssist.Objectives.Stage         # stage names, statuses, bounds
AllbertAssist.Objectives.Event         # durable objective event records
AllbertAssist.Objectives.WorldModelProvider
```

v0.23 should probably implement the engine, stage names, event records, and a
small internal hook dispatcher. Public plugin/app hook contribution can be
deferred until the internal shape is proven, but the interfaces should leave
room for it.

## Proposed Architecture Change

Add an objective runtime layer between intent selection and action execution.

Intent remains responsible for understanding the immediate user input and
selecting/annotating possible routes.

Objectives become responsible for durable outcome state:

- what the system is trying to accomplish
- why this objective exists
- acceptance criteria
- constraints
- current status
- current and historical steps
- blocked confirmations or questions
- progress summaries
- links to traces, jobs, messages, memory, app context, and action results

Actions remain responsible for execution. No objective, planner, LLM, world
model, app, plugin, skill, or surface can bypass `Actions.Runner.run/3`,
Security Central, confirmations, resource access posture, traces, or audits.

## Proposed v0.23 Insert

Recommendation: finish v0.22 without derailing it, then insert a new v0.23.

New v0.23:

```text
v0.23: Objective Runtime Foundation
```

Move the current native Jido trading agents plan from v0.23 to v0.24, and bump
subsequent milestones:

- v0.22: StockSage Python Bridge, unchanged except handoff notes.
- v0.23: Objective Runtime Foundation.
- v0.24: Native Jido Trading Agents, formerly v0.23.
- v0.25: Agentic Workspace Surface And Ephemeral UI, formerly v0.24.
- v0.26: StockSage LiveViews, formerly v0.25.
- v0.27: Security Hardening And Evals, formerly v0.26.
- v0.28: StockSage Polish, Outcomes, Trends, Memory Namespaces, formerly v0.27.
- v0.29: StockSage Canvas Integration, formerly v0.28.
- v0.30: Plugin And App Generator, formerly v0.29.

The reason to insert rather than defer: native StockSage agents are the first
real multi-step agent workflow. They should use the shared Allbert objective
runtime from the beginning.

## Proposed v0.23 Scope

Possible modules:

```text
AllbertAssist.Objectives
AllbertAssist.Objectives.Objective
AllbertAssist.Objectives.Step
AllbertAssist.Objectives.Event
AllbertAssist.Objectives.Engine
AllbertAssist.Objectives.Stage
AllbertAssist.Objectives.Hooks
AllbertAssist.Objectives.HookProvider
AllbertAssist.Objectives.Planner
AllbertAssist.Objectives.Evaluator
AllbertAssist.Objectives.WorldModelProvider
AllbertAssist.Actions.Objectives.ListObjectives
AllbertAssist.Actions.Objectives.ShowObjective
AllbertAssist.Actions.Objectives.CancelObjective
AllbertAssist.Actions.Objectives.ContinueObjective
```

Possible SQLite tables:

```text
objectives
objective_steps
objective_events
```

Objective fields:

- `id`
- `user_id`
- `thread_id`
- `session_id`
- `active_app`
- `status`: `open`, `running`, `blocked`, `completed`, `cancelled`, `failed`
- `title`
- `objective`: bounded plain-language outcome
- `acceptance_criteria`
- `constraints`
- `source_intent`
- `parent_objective_id`
- `current_step_id`
- `progress_summary`
- `last_observation_summary`
- `world_model_summary`
- `loop_count`
- `created_at`
- `updated_at`
- `completed_at`

Step fields:

- `id`
- `objective_id`
- `parent_step_id`
- `kind`: `span_out`, `consolidate`, `action`, `evaluation`, `ask_user`,
  `wait`, `observe`, `delegate_agent`, `surface`, `reflect`
- `status`: `proposed`, `selected`, `running`, `blocked`, `completed`,
  `cancelled`, `failed`
- `stage`
- `provider`
- `candidate_action`
- `action_params`
- `candidate_agent`
- `candidate_surface`
- `candidate_workflow`
- `result_summary`
- `observation_summary`
- `evaluation_summary`
- `world_model_prediction`
- `trace_id`
- `confirmation_id`
- `resource_access`
- `created_at`
- `updated_at`

Signals:

```text
allbert.objective.created
allbert.objective.updated
allbert.objective.step.proposed
allbert.objective.step.selected
allbert.objective.step.running
allbert.objective.step.completed
allbert.objective.step.failed
allbert.objective.observed
allbert.objective.reflected
allbert.objective.blocked
allbert.objective.completed
allbert.objective.cancelled
allbert.objective.impasse
```

Settings placeholders:

```text
objectives.enabled
objectives.max_depth
objectives.max_steps_per_turn
objectives.max_loop_count
objectives.max_parallel_steps
objectives.allow_parallel_steps
objectives.default_persistence
objectives.require_confirmation_for_background_continuation
objectives.trace_detail
objectives.hooks_enabled
objectives.hook_timeout_ms
objectives.world_model_provider
objectives.world_model_enabled
```

The settings above should be conservative by default. Any background
continuation, parallelism, or external provider behavior must have explicit
permission, confirmation, and trace policy.

Recommended v0.23 implementation line:

- Implement durable objective, step, and event storage.
- Implement stage names and objective event signals.
- Implement internal hooks for guard, enrichment, proposal, evaluation,
  consolidation, observation, reflection, and rendering, but keep effectful
  hook execution disabled unless the hook is an existing registered action.
- Implement `WorldModelProvider` as an inert behaviour plus settings
  placeholders and trace vocabulary.
- Implement no public plugin hook contribution until one internal objective
  loop is proven.

## World Model Provider Hook

v0.23 should reserve the interface but keep it inert.

Possible behaviour:

```elixir
defmodule AllbertAssist.Objectives.WorldModelProvider do
  @callback predict_transition(objective, proposed_step, context) ::
              {:ok, prediction} | {:error, reason}

  @callback evaluate_risk(objective, proposed_step, context) ::
              {:ok, risk_assessment} | {:error, reason}

  @callback summarize_state(objective, context) ::
              {:ok, state_summary} | {:error, reason}
end
```

Rules:

- No learned model is implemented in v0.23.
- No simulator execution is implemented in v0.23.
- No external provider calls are implemented in v0.23.
- World-model output is predictive/counterfactual data, not observed fact.
- Simulated state must be labeled as simulated.
- World-model output cannot authorize, execute, create actions, grant
  permissions, or write memory/domain truth.
- Any future provider must run behind explicit Settings Central config,
  Security Central posture, redaction, traces, and evals.

This hook exists so Allbert can later support world models, simulators,
domain-specific predictive models, planning evaluators, or app-provided
forecast engines without treating LLMs/GPTs as the only intelligence source.

## Coding Policies To Add

If accepted, add these to `AGENTS.md`, `DEVELOPMENT.md`, and possibly a new ADR:

- Multi-step work must be represented as objectives and steps, not private
  app, channel, LiveView, job, or plugin loops.
- LLM/model output may propose intents, objectives, steps, critiques, or
  evaluations, but cannot authorize or execute.
- World-model output is predictive/counterfactual, not observed fact.
- Simulated state must be labeled and cannot be written as memory/domain truth
  without observation or operator confirmation.
- Apps/plugins must not implement private durable goal loops.
- Every objective step that mutates, fetches, sends, spends, executes,
  analyzes, imports, installs, or contacts external systems must ground to a
  registered action and Security Central.
- Objective loops must have step, time, cost, confirmation, cancellation, and
  trace bounds.
- Objective state is not authorization. `objective_id` never grants
  permission.
- `active_app` may scope ranking and objective context, but not permission.
- Stage hooks are proposal/diagnostic infrastructure unless they explicitly
  call an existing registered action. Hook output must be bounded, redacted,
  traceable, and labeled by provider.
- Apps/plugins may contribute objective context or candidate steps only
  through declared hook/provider contracts. They must not subscribe to raw
  signals and mutate objective state privately.
- Impasses are first-class. If Allbert has no candidate step, too many
  unresolved candidates, insufficient context, or an unexecutable selected
  step, it should record an impasse and ask, retrieve, defer, or block rather
  than spin.
- Every loop must show why it continued. Repeating an objective cycle without
  new observation, new context, new approval, or changed ranking should be a
  test failure.

## Docs That Need Updating If Accepted

Immediate doc changes:

- `docs/plans/allbert-jido-vision.md`
  Add a major "Intent, Objectives, And World Models" section. Update Product
  Shape and North Star.

- `docs/plans/roadmap.md`
  Insert v0.23 Objective Runtime Foundation and renumber v0.23+.

- `docs/plans/future-features.md`
  Replace the rough "Intents vs Objective" note. Move Objective Runtime
  Foundation into "Already Planned Elsewhere" if v0.23 is accepted. Add a
  separate unassigned entry for future real world-model providers and
  simulation.

- `docs/adr/0021-intent-objective-and-world-model-boundary.md`
  New ADR. It should define intent, objective, step, observation,
  planner/evaluator, world model, and action authority boundaries.

- `docs/adr/0019-cross-surface-intent-enrichment.md`
  Add a note that ADR 0021 supersedes any implication that intent ranking is
  the full work-management layer.

- `AGENTS.md`
  Add a compact non-negotiable about objective/step state for multi-step work.

- `DEVELOPMENT.md`
  Add objective runtime to the architecture contract.

- `docs/developer/agent-context-map.md`
  Add routing guidance for objective/task work.

Plan changes:

- `docs/plans/v0.22-plan.md`
  Add a handoff note: v0.22 remains a single action/bridge execution path and
  does not implement a private objective loop. v0.23 will add shared objective
  state before native agents.

- `docs/plans/v0.23-plan.md`
  Replace current Native Jido Trading Agents plan with Objective Runtime
  Foundation.

- New `docs/plans/v0.23-request-flow.md`
  Describe runtime/user flow, not implementation details: ask, frame
  objective, propose steps, execute one registered action, observe result,
  continue/block/complete.

- Move current `docs/plans/v0.23-plan.md` to `v0.24-plan.md` content and
  expand native trading agents to consume objective/step state.

- Bump `v0.24` through `v0.29` plans and update cross-references.

## Settings UI Implication

"Full Settings UI Polish" should not be treated as only visual polish anymore.

Settings UI should eventually explain settings by runtime layer:

- identity/session
- intent
- objectives/planning/world-model hooks
- actions/security
- jobs
- channels
- plugins/apps
- memory
- surfaces/canvas

The future Settings UI should show which subsystem consumes a setting, whether
the value came from defaults/operator/project/plugin/request layers, whether it
affects authority, and where its audit trail lives.

Needed before Full Settings UI Polish is planned:

- stable objective settings schema
- objective trace/debug UI
- app/plugin settings grouping
- security posture explanation per setting
- secret entry and redaction UX
- search and validation
- accessibility and mobile behavior

## What Not To Do

- Do not turn `Intent.Decision` into a large objective record.
- Do not let `Intent.Engine` become the planner/executor/evaluator.
- Do not let StockSage native agents create a private durable task graph.
- Do not let workspace LiveViews own objective logic.
- Do not treat world-model predictions as truth.
- Do not introduce autonomous background loops without explicit operator
  controls.
- Do not add broad compatibility layers for old pre-production plans. Prefer
  clean renumbering and direct migration while the project is still local and
  unreleased for production use.

## Open Questions

1. Should v0.23 store objective state in SQLite immediately, or begin with
   trace/session-linked ephemeral objective records? Current recommendation:
   SQLite, because jobs, confirmations, traces, and multi-turn work need
   durable linkage.
2. Should every user input create an objective, or only multi-step/non-trivial
   requests? Current recommendation: only create durable objectives for
   multi-step, background, app-scoped, confirmed, resumable, or explicitly
   tracked work. Simple direct answers can remain objective-free or use
   ephemeral trace-only objectives.
3. Should objective framing be deterministic first, model-assisted later?
   Current recommendation: deterministic first with optional model proposal
   hooks behind settings, redaction, and validation.
4. Should StockSage analyses become objectives or actions within objectives?
   Current recommendation: `RunAnalysis` remains the action boundary; a
   StockSage analysis objective may contain steps that call `RunAnalysis` and
   later native sub-agent steps.
5. How should objective completion be verified? Current recommendation:
   bounded acceptance criteria plus explicit action results; model evaluation
   is advisory only.
6. How much world-model abstraction should be included in v0.23? Current
   recommendation: behaviour, settings placeholder, trace vocabulary, and
   explicit non-goals only. No provider implementation.
7. Which stages should be durable in v0.23 versus signal/trace-only? Current
   recommendation: persist objectives, selected/proposed steps, observations,
   impasses, and status transitions. Keep most hook internals as bounded event
   metadata unless they affect selected steps or user-visible state.
8. Should hooks be public plugin APIs in v0.23? Current recommendation: no.
   Implement internal hook dispatch and provider vocabulary first; expose
   plugin hook contribution only after the objective runtime has one proven
   Allbert-owned loop and one StockSage loop.
9. Should stage ordering be a fixed pipeline or graph? Current recommendation:
   a fixed conservative state machine in v0.23 with graph-like stage events and
   room for later workflow graphs. This avoids importing LangGraph-style
   flexibility before Allbert has safety/eval coverage.
10. How does objective workflow memory differ from markdown memory and skills?
    Current recommendation: objective traces may compile into workflow-memory
    candidates after review. They are not trusted skills and not executable
    until promoted through explicit skill/app/action workflows.
