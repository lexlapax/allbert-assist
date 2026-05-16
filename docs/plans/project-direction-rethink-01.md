# Project Direction Rethink 01

Status: working analysis draft.

Purpose: capture the current rethink that Allbert should be organized around
human-understandable objective loops: understand intent, frame outcomes,
inventory available capabilities and resources, generate possible routes,
evaluate tradeoffs, choose or ask, execute through registered actions,
observe, and learn. The architecture should leave room for deterministic,
probabilistic, stochastic, diffusion-style, market/resource-allocation,
world-model, language-model, and future advisory model providers without
making any of them authority.

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
- Capability inventory: what Allbert can currently do through registered
  actions, plugins, skills, channels, apps, jobs, providers, settings,
  credentials, local resources, and operator-approved access.
- Capability gap: what Allbert cannot currently do, but could ask the user to
  configure, research, install, implement, generate, schedule, or decline.
- Route: a proposed way to pursue an objective using available or acquirable
  capabilities.
- Resource decision model: advisory logic that prices routes by cost, latency,
  risk, scarcity, trust, user burden, reversibility, maintenance, and
  probability of success.
- Acquisition option: a proposed investment in new capability, such as
  requesting a credential, changing a setting, installing a plugin, generating
  an app scaffold, writing code, or asking the user to choose a different
  path.
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
  -> inventory capabilities/resources
  -> identify capability gaps
  -> span-out: propose possible routes/operators/steps/workflows/acquisitions
  -> retrieve: memory, workflow memory, app/domain context
  -> evaluate/simulate/price: policy, risk, resources, cost, feasibility,
     prediction, scarcity, trust, latency, and user burden
  -> allocate/consolidate: compare, prune, merge, rank, and explain routes
  -> commit: choose the next bounded step, ask, acquire, defer, decline, or block
  -> authorize: Security Central, resource posture, confirmation
  -> execute through registered actions only
  -> observe action/runtime/user/environment result
  -> update capability/resource estimates
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
small: objectives, objective steps, and objective events. Capability
inventory, resource decisions, and advisory model outputs can start as event
types, trace sections, and hook contracts before becoming durable subsystems.

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
6. Resource decisions are first-class. Bounded optimality and resource-rational
   analysis argue that intelligent systems should account for limited
   computation, time, money, attention, information, and hardware. Allbert
   should not only ask "what action matches this intent?" It should ask
   "which route is worth taking with the capabilities and resources available
   now, and which missing capability is worth acquiring?"
7. Model routing and cascades are a practical near-term version of this
   problem. FrugalGPT, Language Model Cascades, RouterBench, and RouteLLM all
   treat model choice as a cost/quality/latency tradeoff. Allbert should
   generalize that idea beyond LLMs: route between local rules, small models,
   remote models, plugins, jobs, memory, actions, app providers, or user
   questions.
8. Market and contract metaphors are useful, but dangerous if over-literal.
   Hayek's knowledge problem, Coase's transaction-cost boundary, Contract Net,
   and auction-based multi-agent allocation all point to the same lesson:
   providers may expose local bids, costs, scarcity, and expected value, but
   Allbert must keep the market inside audited contracts rather than letting
   autonomous providers spend, install, call, or execute on their own.

### JEPA And Predictive World Models

JEPA stands for Joint-Embedding Predictive Architecture. The important
architectural lesson is not "use Meta's model" or "replace GPT." It is that a
future Allbert world-model provider may predict latent representations of
state, action consequences, or surprise rather than generate text or pixels.

I-JEPA and V-JEPA are non-generative predictive architectures: they learn by
predicting abstract representations in an embedding space. V-JEPA 2 makes the
planning relevance explicit: a world model can encode current and target
states, predict how candidate actions change the latent state, and score which
candidate appears closer to a goal. For Allbert, that maps to the
`evaluate/simulate/score` stage as bounded prediction metadata.

Stanford's PSI work reinforces the same non-language direction from a
different angle. Its world model extracts and reintegrates intermediate
structures such as optical flow, depth, and object segmentation through
counterfactual prediction. That is evidence that "world model" should not mean
"LLM with a longer prompt." It should mean a provider that can expose
predictive structure and counterfactual handles, sometimes in modalities that
are not text at all.

Human and social simulations are another provider family. Stanford/Google
Generative Agents and Stanford HAI's later human-behavior simulation work show
agent models that simulate attitudes, behaviors, memory, planning, and social
interaction. These are not authority either; they are advisory models for
"what may happen if..." questions and require strong privacy, consent, and
over-reliance guardrails.

Embodied AI and robotics world models are a further future branch. Stanford's
BEHAVIOR-1K is a useful grounded example because it frames long-horizon
activities in realistic simulated environments. Allbert should leave room for
embodied providers, but v0.23 should not implement a robot runtime, simulator,
video model, vector store, or external provider call.

Immediate Allbert implication: the objective runtime should be model-agnostic.
It should be able to call LLM-style language providers, JEPA-style latent
predictors, deterministic domain models, probabilistic simulators, and
human/agent simulators through the same advisory world-model/provider
contract, while preserving Jido actions and Security Central as the only
effectful authority boundary.

### Resource Decision, Markets, And Model-Agnostic Routing

The broader rethink is not just "future world models." It is that Allbert
needs a human-readable decision economy around objectives.

The core unit should be a route: a proposed way to advance an objective. A
route may use an existing action, combine several existing capabilities, ask
the user, wait for a job, retrieve memory, call a provider, request a
credential, install a plugin, generate a scaffold, write code, or decline the
objective. The route is still only proposal data until it reaches the existing
authorization and action boundaries.

Resource decision models should evaluate routes using explicit dimensions:

- capability availability
- capability gap and acquisition effort
- expected quality or probability of success
- latency and wall-clock time
- money, token, CPU, memory, network, and battery cost
- Security Central risk and resource access posture
- credential or secret availability
- trust, provenance, and plugin/app ownership
- user attention burden
- reversibility and blast radius
- maintenance burden if new code or configuration is created

This should stay legible to an operator. The system can eventually host
stochastic, probabilistic, diffusion-style, market-allocation, or
model-routing providers, but the explanation should remain plain:

```text
I can do this three ways:
1. use an existing local action, slower but already trusted
2. ask you for a missing credential, faster after setup
3. create a new plugin/app scaffold, more work and requires review
```

Diffusion models belong in this broader provider story too. Diffusion Policy,
MetaDiffuser, and diffusion-as-optimizer work show diffusion models being used
for trajectory generation, planning, action policies, and optimization rather
than only image generation. For Allbert, that means a future diffusion
provider might propose candidate route trajectories or optimize step sequences.
It must still remain advisory.

Market-style allocation also belongs here. A future Allbert planner might ask
several providers for bids: local deterministic rule, small local model,
remote LLM, StockSage domain planner, memory/workflow provider, or plugin
agent. Each bid can include cost, confidence, expected latency, required
permissions, and missing resources. The final selection stays inside
Allbert's objective engine and authorization path, not inside a provider.

Immediate v0.23 implication: reserve vocabulary for capability inventory,
capability gaps, routes, acquisition options, and resource decision providers.
Do not implement a public marketplace, autonomous installer, dynamic code
loader, spend policy, or provider bidding runtime yet.

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
- I-JEPA:
  https://arxiv.org/abs/2301.08243
- V-JEPA:
  https://ai.meta.com/blog/v-jepa-yann-lecun-ai-model-video-joint-embedding-predictive-architecture/
- V-JEPA 2:
  https://ai.meta.com/blog/v-jepa-2-world-model-benchmarks/
- Stanford PSI:
  https://arxiv.org/abs/2509.09737
- Stanford NeuroAI Lab publications:
  https://neuroailab.stanford.edu/publications.html
- Language Models, Agent Models, and World Models:
  https://arxiv.org/abs/2312.05230
- Voyager: https://arxiv.org/abs/2305.16291
- Reflexion: https://arxiv.org/abs/2303.11366
- Generative Agents: https://arxiv.org/abs/2304.03442
- Stanford HAI human-behavior simulation brief:
  https://hai.stanford.edu/policy/simulating-human-behavior-with-ai-agents?sf225800334=1
- BEHAVIOR-1K:
  https://arxiv.org/abs/2403.09227
- Resource-rational analysis:
  https://www.cambridge.org/core/journals/behavioral-and-brain-sciences/article/abs/resourcerational-analysis-understanding-human-cognition-as-the-optimal-use-of-limited-computational-resources/586866D9AD1D1EA7A1EECE217D392F4A
- Provably Bounded-Optimal Agents:
  https://arxiv.org/abs/cs/9505103
- Language Model Cascades:
  https://arxiv.org/abs/2207.10342
- FrugalGPT:
  https://arxiv.org/abs/2305.05176
- RouterBench:
  https://arxiv.org/abs/2403.12031
- RouteLLM:
  https://arxiv.org/abs/2406.18665
- Diffusion Policy:
  https://arxiv.org/abs/2303.04137
- MetaDiffuser:
  https://arxiv.org/abs/2305.19923
- Diffusion Models as Optimizers for Efficient Planning:
  https://arxiv.org/abs/2407.16142
- Hayek, The Use of Knowledge in Society:
  https://www.mercatus.org/sites/default/files/d7/the_use_of_knowledge_in_society_-_hayek.pdf
- Coase transaction-cost theory of the firm overview:
  https://www2.sjsu.edu/faculty/watkins/coase.htm
- Auction-based multi-agent task allocation:
  https://arxiv.org/abs/2107.00144
- Reactive multi-agent coordination using auction-based allocation and
  behavior trees:
  https://arxiv.org/abs/2304.01976
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

Research caution: do not overclaim every robotics or diffusion-policy example
as Stanford-originated unless a primary source says so. The Stanford-specific
embodied source verified in this pass is BEHAVIOR-1K.

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

### 6A. Capability Inventory / Gap Analysis / Resource Routing

Purpose: determine what Allbert can use right now, what is missing, and
whether the next route should use existing capability, acquire capability, ask
the user, defer, or decline.

Capability inventory includes:

- registered actions and their permissions
- app and plugin contracts
- skills and skill scripts
- channels and delivery status
- jobs and background execution state
- settings, configured credentials, and secret status
- memory and derived indexes
- surfaces and workspace capabilities
- provider/model profiles
- local files, caches, and resource grants
- app/domain-specific context such as StockSage queue state

Capability gaps include:

- missing setting or credential
- disabled plugin or app
- untrusted or unavailable skill
- unsupported route or missing action
- unavailable provider/model profile
- missing resource grant
- missing data or domain record
- code that would need to be written or generated
- work that should be declined rather than acquired

Route decision options:

- use an existing capability
- combine existing capabilities
- ask the user for missing input
- request a credential, setting, or resource grant
- install/import/enable a plugin after explicit review
- generate a scaffold for reviewed code
- schedule or defer background work
- decline or refuse the objective

Hooks:

- `before_capability_inventory`
- `capability_provider`
- `capability_gap_provider`
- `route_provider`
- `resource_decision_provider`
- `after_capability_inventory`

Jido substrate:

- inventory and route proposals are bounded data, not execution
- provider bids can be represented as signals and trace sections
- Jido actions remain the only boundary for changing settings, installing,
  importing, writing, executing, spending, or contacting external systems
- capability acquisition is never silent; it requires operator-visible
  confirmation or a specific registered action path

### 7. Span-Out / Operator And Step Proposal

Purpose: propose possible next steps, operators, specialist agents, app
actions, workflows, acquisition options, or questions.

This stage should produce proposal data. It should not execute.

Possible providers:

- deterministic rules
- app-provided planner hints
- skills
- prior objective traces
- workflow memory
- LLM planner proposals
- world-model predictions
- diffusion-style trajectory or step-sequence proposals
- resource decision models
- market/allocation-style provider bids
- StockSage domain planner

Hooks:

- `before_span_out`
- `step_proposer`
- `route_proposer`
- `workflow_provider`
- `specialist_agent_provider`
- `acquisition_option_provider`
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

### 9. Evaluate / Simulate / Price / Score

Purpose: evaluate proposed steps before committing. This includes policy,
resource risk, expected cost, feasibility, capability gaps, scarcity, latency,
trust, user burden, likely progress, diffusion/trajectory proposals,
world-model prediction, and whether the user must be asked.

This is where future world models, diffusion providers, probabilistic
inference, resource decision models, and market-style allocators fit.

Hooks:

- `before_step_evaluation`
- `step_evaluator`
- `world_model_provider`
- `diffusion_proposal_provider`
- `resource_decision_provider`
- `market_allocator_provider`
- `risk_evaluator`
- `cost_evaluator`
- `after_step_evaluation`

Jido substrate:

- advisory providers are behaviours/plugins that return proposal, prediction,
  pricing, or evaluation metadata only
- Security Central still owns actual permission at action execution
- prediction signals must be labeled as simulated/counterfactual
- provider pricing or bids are not permission grants and cannot spend,
  install, write code, call external services, or execute

### 10. Allocate / Consolidate / Span-In

Purpose: merge duplicates, prune unsafe or irrelevant proposals, rank
remaining proposals, explain the tradeoffs, and select one or more next
routes or steps.

This stage corresponds to the user's "span-in" language.

Hooks:

- `before_consolidation`
- `step_ranker`
- `route_allocator`
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
- World-model providers should run as supervised OTP children or external
  workers with bounded queues, timeouts, backpressure, and circuit breakers.
  Heavy model runtimes should be isolated behind explicit provider processes
  rather than smuggled into pure planning code.
- Jido signals should record provider calls, prediction summaries, failures,
  timeouts, and observation deltas. Prediction signals must be labeled
  simulated/counterfactual so they cannot be confused with observed state.
- Plugin and app providers may contribute predictions only through declared
  contracts. They must not subscribe to raw objective signals and mutate
  objective state privately.

Proposed Allbert layer on top of Jido:

```text
AllbertAssist.Objectives.Engine        # runs the stage state machine
AllbertAssist.Objectives.Hooks         # internal hook dispatcher
AllbertAssist.Objectives.HookProvider  # future plugin/app contribution behaviour
AllbertAssist.Objectives.Stage         # stage names, statuses, bounds
AllbertAssist.Objectives.Event         # durable objective event records
AllbertAssist.Objectives.Capabilities  # inventory and gap vocabulary
AllbertAssist.Objectives.Routes        # route and acquisition proposals
AllbertAssist.Objectives.AdvisoryProvider
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
AllbertAssist.Objectives.Capability
AllbertAssist.Objectives.CapabilityGap
AllbertAssist.Objectives.Route
AllbertAssist.Objectives.AcquisitionOption
AllbertAssist.Objectives.Planner
AllbertAssist.Objectives.Evaluator
AllbertAssist.Objectives.AdvisoryProvider
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
- `capability_summary`
- `route_summary`
- `loop_count`
- `created_at`
- `updated_at`
- `completed_at`

Step fields:

- `id`
- `objective_id`
- `parent_step_id`
- `kind`: `capability_inventory`, `capability_gap`, `route`, `span_out`,
  `consolidate`, `action`, `evaluation`, `acquisition`, `ask_user`, `wait`,
  `observe`, `delegate_agent`, `surface`, `reflect`
- `status`: `proposed`, `selected`, `running`, `blocked`, `completed`,
  `cancelled`, `failed`
- `stage`
- `provider`
- `candidate_action`
- `action_params`
- `candidate_agent`
- `candidate_surface`
- `candidate_workflow`
- `candidate_route`
- `capability_gaps`
- `acquisition_options`
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
allbert.objective.capabilities.inventoried
allbert.objective.capability_gap.detected
allbert.objective.route.proposed
allbert.objective.route.selected
allbert.objective.acquisition.proposed
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
objectives.capability_inventory_enabled
objectives.resource_decision_provider
objectives.resource_decision_timeout_ms
objectives.route_trace_detail
objectives.world_model_provider
objectives.world_model_provider_type
objectives.world_model_enabled
objectives.world_model_timeout_ms
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
- Reserve capability inventory, capability gap, route, acquisition option, and
  resource decision provider vocabulary. Keep it internal and trace-oriented
  until the first objective loop proves the shape.
- Implement `WorldModelProvider` as an inert behaviour plus a null provider,
  settings placeholders, signal vocabulary, and trace shape.
- Implement no JEPA model, learned model, simulator, vector store, robot
  runtime, or external provider call in v0.23.
- Implement no marketplace, autonomous installer, dynamic code loader, spend
  policy, provider bidding runtime, or automatic capability acquisition in
  v0.23.
- Implement no public plugin hook contribution until one internal objective
  loop is proven.

## Advisory Provider And World Model Hooks

World models are one advisory provider family, not the umbrella for all future
intelligence. v0.23 should reserve the broader interface but keep it inert.

Advisory provider taxonomy to reserve:

- `AllbertAssist.Objectives.IntentProvider`
- `AllbertAssist.Objectives.RouteProvider`
- `AllbertAssist.Objectives.CapabilityProvider`
- `AllbertAssist.Objectives.ResourceDecisionProvider`
- `AllbertAssist.Objectives.WorldModelProvider`
- `AllbertAssist.Objectives.DiffusionProposalProvider`
- `AllbertAssist.Objectives.ProbabilisticInferenceProvider`
- `AllbertAssist.Objectives.MarketAllocatorProvider`
- `AllbertAssist.Objectives.CriticEvaluatorProvider`

Possible umbrella behaviour:

```elixir
defmodule AllbertAssist.Objectives.AdvisoryProvider do
  @callback provider_type() ::
              :intent
              | :route
              | :capability
              | :resource_decision
              | :world_model
              | :diffusion_proposal
              | :probabilistic_inference
              | :market_allocator
              | :critic_evaluator

  @callback propose(stage, objective, context) ::
              {:ok, proposals} | {:error, reason}

  @callback evaluate_route(route, context) ::
              {:ok, evaluation} | {:error, reason}

  @callback explain(result, context) ::
              {:ok, explanation} | {:error, reason}
end
```

The umbrella provider is deliberately proposal-shaped. It should not expose
callbacks for executing, installing, granting, spending, writing files, or
mutating objective truth.

World-model provider types to reserve:

- `:language_model` for proposal, explanation, critique, summarization, and
  translation.
- `:embedding_predictive` for JEPA-style latent prediction and surprise/error
  comparison.
- `:symbolic_domain` for deterministic Elixir or app-domain rules.
- `:probabilistic_simulator` for counterfactual rollout and uncertainty-aware
  scoring.
- `:agent_model` for human, operator, social, or multi-agent behavior
  simulation.
- `:embodied_world_model` for future robotics, physical-world, video, or
  sensor-grounded providers.

Possible behaviour:

```elixir
defmodule AllbertAssist.Objectives.WorldModelProvider do
  @callback encode_state(context) ::
              {:ok, state_representation} | {:error, reason}

  @callback predict_latent_transition(state_representation, proposed_step, context) ::
              {:ok, latent_prediction} | {:error, reason}

  @callback compare_prediction_to_observation(prediction, observation, context) ::
              {:ok, comparison} | {:error, reason}

  @callback predict_transition(objective, proposed_step, context) ::
              {:ok, prediction} | {:error, reason}

  @callback evaluate_risk(objective, proposed_step, context) ::
              {:ok, risk_assessment} | {:error, reason}

  @callback summarize_state(objective, context) ::
              {:ok, state_summary} | {:error, reason}
end
```

The JEPA-oriented callbacks are intentionally representation-shaped, not
text-shaped. `state_representation` may later be an opaque local reference, a
bounded summary, or a redacted derived artifact. v0.23 should not persist raw
embeddings or add vector retrieval; it should only reserve the vocabulary.

Rules:

- No learned model is implemented in v0.23.
- No simulator execution is implemented in v0.23.
- No vector store, robot runtime, or JEPA runtime is implemented in v0.23.
- No external provider calls are implemented in v0.23.
- World-model output is predictive/counterfactual data, not observed fact.
- Simulated state must be labeled as simulated.
- World-model output cannot authorize, execute, create actions, grant
  permissions, or write memory/domain truth.
- World-model output cannot bypass Jido action execution, Security Central,
  confirmation, resource access posture, traces, or audits.
- Any future provider must run behind explicit Settings Central config,
  Security Central posture, redaction, traces, and evals.

These hooks exist so Allbert can later support resource routers, diffusion
proposal models, market-style allocators, world models, simulators,
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
- Capability acquisition is never silent. Installing/importing/enabling a
  plugin, requesting credentials, writing code, generating an app scaffold,
  spending money, calling a paid/external provider, or granting resource access
  must go through an operator-visible registered action path.
- Resource decision, market-allocation, model-routing, diffusion, probabilistic,
  and world-model providers may propose, price, predict, rank, or critique
  routes. They cannot authorize, execute, spend, install, grant trust, mutate
  objective truth, or bypass Security Central.
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

- `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md`
  New ADR. It should define intent, objective, step, observation, capability
  inventory, capability gap, route, acquisition option, resource decision
  model, planner/evaluator, world model, advisory provider, and action
  authority boundaries.

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
- objectives/planning/capability inventory/resource decisions/advisory hooks
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
- stable capability inventory and resource decision settings schema
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
- Do not treat provider bids, route scores, market prices, cost estimates, or
  model-routing choices as authority.
- Do not silently acquire capabilities. Missing capabilities should become
  explicit options, confirmations, refusals, or implementation work.
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
   recommendation: behaviour, null provider, settings placeholder, trace
   vocabulary, and explicit non-goals only. No provider implementation.
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
11. Should v0.23 include a first inert `ResourceDecisionProvider` contract, or
    only route/capability vocabulary in traces? Current recommendation:
    include the vocabulary and internal null provider shape, but do not expose
    public plugin/provider contribution until a simple objective loop proves
    what the engine actually needs.
12. How should Allbert represent a capability gap that might require code?
    Current recommendation: treat it as an acquisition option with status
    `requires_review`, never as automatic code generation or dynamic module
    loading.
13. Should market metaphors become literal auctions between providers?
    Current recommendation: no for v0.23. Keep bid-like fields such as cost,
    latency, confidence, required permissions, and missing resources as
    explanatory metadata. Do not implement provider competition as authority.
