# Objective Runtime Research Note

## Purpose

This note collects the primary-source material that motivates the
objective runtime work in `docs/adr/0021-intent-objective-capability-
and-advisory-boundary.md` and `docs/plans/archives/v0.24-plan.md`. It is
research material, not load-bearing for implementation. The
project-direction rethink draft
(`docs/archives/project-direction-rethink-01.md`) previously inlined this
material; moving it here keeps the rethink doc and the ADR focused
on Allbert-specific decisions.

Each section follows the same shape:

- One-paragraph summary of the source's core idea.
- What Allbert can borrow.
- What Allbert should not borrow.
- Primary-source link.

## Live agent systems

### Hermes Agent (Nous Research)

Hermes uses a `/goal` command to set a persistent objective the agent
pursues across multiple turns until the operator pauses it or the
agent decides it's done. Persistence is via SQLite session storage
(FTS5 indexed) plus markdown memory files (`SOUL.md`, `MEMORY.md`,
`USER.md`). There is no dedicated "objective" table. The agent loop
is largely LLM-driven: a synchronous `AIAgent` (in `run_agent.py`)
builds a prompt, calls the model, runs tool calls, persists state.
There is no dedicated judge model; completion is whatever the model
emits as the final response. Sub-agent delegation is a registered
tool (`delegate_tool.py`); the child gets the parent's session
history but a restricted tool registry. Tools self-register via a
central registry (70+ tools, ~28 toolsets).

**What Allbert borrows:**
- The verb. A future `/objective` operator command for "tell me what
  you're working on" matches Hermes's `/goal`.
- Restricted tool scope on delegation. A `delegate_agent` step kind
  should hand the child a narrower action registry, not the parent's
  full surface.
- Lazy tool/skill metadata in prompts. Hermes is converging on the
  same pattern Allbert already uses (v0.03 progressive disclosure).

**What Allbert does not borrow:**
- The `execute_code` meta-tool. Hermes lets the model write Python
  that calls other Hermes tools via a local RPC bridge. This
  collapses many tool calls into one model turn but is exactly the
  kind of authority concentration Allbert's action/Security Central
  boundary is designed to prevent.
- LLM-as-completion-judge. Allbert's acceptance evaluator is
  deterministic in v0.24; future LLM-assisted evaluators remain
  advisory only.

Sources:
- Hermes Agent docs: https://hermes-agent.nousresearch.com/docs/
- Architecture: https://hermes-agent.nousresearch.com/docs/developer-guide/architecture

### OpenClaw

OpenClaw is a hub-and-spoke local agent platform: a single Gateway
brokers multiple chat front-ends (WhatsApp, iMessage, Slack, macOS
app, web, CLI) to one Agent Runtime. Sessions are append-only event
logs under `~/.openclaw/sessions/`, keyed by trust boundary
(`agent:<id>:main`, `:dm:<id>`, `:group:<id>`). The main session runs
tools natively on the host; DM and group sessions run inside Docker
by default. Tools are lazily loaded — only skills relevant to the
current turn are injected into the model's prompt, with `SKILL.md`
files read on demand. Memory is SQLite-stored embeddings plus
structured markdown (`MEMORY.md`, `memory/YYYY-MM-DD.md`).
**Per-session serial queues** are the execution default; parallelism
is opt-in only when provably safe.

**What Allbert borrows:**
- Per-session serial execution by default. Sets the default for
  Allbert's reserved `objectives.max_parallel_steps` (1) and
  `objectives.allow_parallel_steps` (false).
- Trust-tiered runtime sandboxing per session type. Allbert's v0.16
  channel adapters map identities to local `user_id` but do not
  isolate runtime per channel; v0.28 security hardening should
  evaluate this on workflow evidence.
- Conversation compaction. OpenClaw summarizes older session
  segments automatically; Allbert's v0.12 threads have no
  equivalent and may need one before objectives accumulate long
  turn histories.

**What Allbert already matches:**
- Lazy `SKILL.md` reading via v0.03 progressive disclosure.
- Local-first SQLite storage.
- Multi-channel routing via v0.16 channel adapters + v0.17 plugin
  contribution.

**What Allbert does not borrow:**
- Docker-by-default for non-main sessions. v0.08 explicitly defers
  container isolation; the choice should follow real workflow
  evidence rather than be a hard default.

Sources:
- OpenClaw architecture overview: https://ppaolo.substack.com/p/openclaw-system-architecture-overview
- Gateway architecture docs: https://docs.openclaw.ai/concepts/architecture

## Classical references

### BDI (Belief–Desire–Intention)

The BDI architecture (Rao & Georgeff, 1990s) separates four
durable concepts: **beliefs** (what the agent knows), **desires**
(what outcomes it wants), **intentions** (active commitments), and
**plans** (how to act). This separation predates LLM agents by
decades and survives every fashion in AI architecture.

**Allbert mapping:**
- Beliefs ≈ memory/index (v0.21).
- Desires + Intentions ≈ objective state (v0.24).
- Plans ≈ objective steps (v0.24).

Allbert does not import BDI wholesale, but the separation between
"what is known," "what outcome is wanted," "what commitment is
active," and "what is currently executing" is the right axis.

Source:
- BDI model overview: https://turing.cs.pub.ro/ai_mas/papers/bdi.pdf

### Soar

Soar (Laird, Newell, Rosenbloom) is a cognitive architecture with
explicit working memory, operator proposal, operator selection,
operator application, and impasses. The Allbert-relevant lesson is
that "no operator," "tie," and "cannot apply" are **first-class
impasses**, not silent errors. The system records the blocked state
and surfaces it for resolution (in Soar, by subgoaling; in Allbert,
by a `:blocked` status and an `allbert.objective.impasse` event).

**What Allbert adopts:**
- Impasse as a first-class objective event (ADR 0021, v0.24).
- Loop-cap enforcement (`max_loop_count`) that records impasse
  rather than spinning.

Source:
- Soar manual: https://soar.eecs.umich.edu/soar_manual/02_TheSoarArchitecture/

### ReAct

ReAct (Yao et al., 2022) interleaves reasoning and acting in LLM
agents. The agent emits a reasoning step ("I should look up X"),
acts ("call tool look_up(X)"), receives the result, reasons again,
acts again, repeating until done. Allbert's flat intent → action
loop is a degenerate ReAct: one reasoning step (intent
interpretation) and one action. v0.24 objectives generalize this to
multi-turn ReAct, with each step carrying its own intent
interpretation.

**What Allbert borrows:**
- The interleave structure. Each objective step is one
  reason+act cycle.
- Bounded loop counts to prevent runaway sequences (ReAct papers
  use explicit step caps; Allbert uses `max_loop_count`).

Source:
- ReAct paper: https://arxiv.org/abs/2210.03629

### HTN planning

Hierarchical Task Network planning (Nau et al.) decomposes high-
level tasks into lower-level subtasks until each subtask is a
primitive action. HTN planners are formal and rigorous; they can
produce optimal plans but require pre-declared task models.

**What Allbert borrows:**
- Vocabulary for hierarchy: `parent_objective_id`, `parent_step_id`
  are reserved fields.

**What Allbert does not adopt:**
- The formal planner. v0.24 ships a deterministic step proposer,
  not an HTN planner. Future LLM-based or learned planners are
  reserved as advisory provider roles.

Source:
- HTN planning overview: https://arxiv.org/abs/1403.7426

### Tree of Thoughts

Tree of Thoughts (Yao et al., 2023) explores multiple reasoning
branches with explicit evaluation and backtracking. Useful as
vocabulary for the proposal / evaluation / consolidation stages of
the rethink doc.

**What Allbert borrows:**
- The span-out / evaluate / span-in pattern is roughly the
  proposer + evaluator + selection cycle in stages 4 and 7.

**What Allbert does not adopt:**
- Tree search runtime. v0.24's proposer is deterministic; no tree
  exploration.

Source:
- Tree of Thoughts paper: https://arxiv.org/abs/2305.10601

### Workflow Memory

Agent Workflow Memory (Liu et al., 2024) extracts reusable workflows
from agent trajectories so subsequent runs can pattern-match against
proven sequences.

**What Allbert borrows:**
- The idea that objective traces can become workflow-memory
  candidates after explicit operator review. Reserved as future
  capability; not implemented in v0.24.

Source:
- Agent Workflow Memory: https://arxiv.org/abs/2409.07429

## World models and predictive providers

### JEPA family

I-JEPA, V-JEPA, V-JEPA 2 (Meta AI) are joint-embedding predictive
architectures. They learn by predicting abstract representations in
an embedding space, not by generating tokens or pixels. V-JEPA 2
makes the planning relevance explicit: a world model can encode
current and target states, predict how candidate actions change the
latent state, and score which candidate appears closer to a goal.

**What Allbert reserves:**
- The `WorldModelProvider` callback shape with `encode_state`,
  `predict_latent_transition`, and
  `compare_prediction_to_observation` (reserved in ADR 0021;
  not implemented in v0.24).

**Hard rules that apply when a world-model provider eventually
ships:**
- Predictions are predictive/counterfactual data, not observed
  fact.
- Predictions cannot authorize, execute, or grant trust.
- Simulated state must be labeled as simulated.

Sources:
- I-JEPA: https://arxiv.org/abs/2301.08243
- V-JEPA blog: https://ai.meta.com/blog/v-jepa-yann-lecun-ai-model-video-joint-embedding-predictive-architecture/
- V-JEPA 2 blog: https://ai.meta.com/blog/v-jepa-2-world-model-benchmarks/

### Stanford PSI

Stanford's PSI work extracts and reintegrates intermediate
structures (optical flow, depth, object segmentation) through
counterfactual prediction. Evidence that "world model" can mean
non-language predictive structure, not "LLM with a longer prompt."

Source:
- PSI: https://arxiv.org/abs/2509.09737

### Language Models, Agent Models, And World Models

This framing (Andreas, 2023) separates three provider roles in
agent architectures: language models (translate, summarize, reason
in text), agent models (simulate behavior, attitudes), world models
(predict state under actions). Useful conceptually for Allbert's
reserved advisory provider taxonomy.

Source:
- Language Models, Agent Models, and World Models: https://arxiv.org/abs/2312.05230

### Generative Agents and human-behavior simulation

Stanford/Google Generative Agents (Park et al., 2023) and Stanford
HAI's later human-behavior simulation work demonstrate agent models
that simulate attitudes, behaviors, memory, planning, and social
interaction. These are advisory models for "what may happen if…"
questions.

**Hard rule for Allbert (from ADR 0021, Section 5):** predictions
about user behavior never short-circuit confirmation. A simulated
"the user will probably say yes" is rendering data, not a reason to
skip the confirmation.

Sources:
- Generative Agents: https://arxiv.org/abs/2304.03442
- HAI human-behavior simulation: https://hai.stanford.edu/policy/simulating-human-behavior-with-ai-agents

### Embodied world models

BEHAVIOR-1K (Stanford) frames long-horizon embodied activities in
realistic simulated environments. Evidence that future world-model
providers may include embodied predictors, robot runtimes, or
sensor-grounded models.

**Allbert posture:** reserved vocabulary in ADR 0021. v0.24 does
not implement any embodied runtime.

Source:
- BEHAVIOR-1K: https://arxiv.org/abs/2403.09227

## Resource allocation and routing

### Resource-rational analysis

Lieder & Griffiths (Behavioral and Brain Sciences) argue that
intelligent systems should account for limited computation, time,
money, attention, information, and hardware.

**Allbert posture:** the reserved `ResourceDecisionProvider` role
is grounded in this framing. Routes carry cost, latency, risk,
trust, user burden, reversibility, and maintenance metadata.

Source:
- Resource-rational analysis: https://www.cambridge.org/core/journals/behavioral-and-brain-sciences/article/abs/resourcerational-analysis-understanding-human-cognition-as-the-optimal-use-of-limited-computational-resources/586866D9AD1D1EA7A1EECE217D392F4A

### Bounded optimality

Russell & Subramanian's "Provably Bounded-Optimal Agents" (1995)
formalize agents that maximize utility subject to computational
limits. Predates resource-rational analysis but covers the same
ground.

Source:
- Provably Bounded-Optimal Agents: https://arxiv.org/abs/cs/9505103

### Model routing and cascades

FrugalGPT, Language Model Cascades, RouterBench, RouteLLM treat
model choice as a cost / quality / latency tradeoff. Useful as
practical evidence that routing decisions belong in the
infrastructure, not in any single provider.

**Allbert posture:** reserved as `RouteProvider` and
`ResourceDecisionProvider`. v0.24 has one deterministic proposer;
LLM cascades are a future advisory provider, not authority.

Sources:
- Language Model Cascades: https://arxiv.org/abs/2207.10342
- FrugalGPT: https://arxiv.org/abs/2305.05176
- RouterBench: https://arxiv.org/abs/2403.12031
- RouteLLM: https://arxiv.org/abs/2406.18665

### Diffusion as planning

Diffusion Policy, MetaDiffuser, and diffusion-as-optimizer work
show diffusion models being used for trajectory generation,
planning, action policies, and optimization rather than only image
generation. For Allbert, a future `DiffusionProposalProvider` may
propose candidate route trajectories or optimize step sequences.

**Allbert posture:** reserved vocabulary. v0.24 has no diffusion
runtime.

Sources:
- Diffusion Policy: https://arxiv.org/abs/2303.04137
- MetaDiffuser: https://arxiv.org/abs/2305.19923
- Diffusion as Optimizer: https://arxiv.org/abs/2407.16142

### Market and contract metaphors

Hayek ("The Use of Knowledge in Society") and Coase (transaction-
cost theory) are economic frames for distributed decision-making.
Contract Net Protocol and auction-based multi-agent task allocation
are operational implementations.

**Allbert posture:** market metaphors are useful for explaining
why several providers may produce bid-like proposals (cost,
confidence, expected latency, required permissions, missing
resources), but **provider bids are not authority**. The
`MarketAllocatorProvider` role is reserved; v0.24 does not
implement provider competition.

Sources:
- Hayek: https://www.mercatus.org/sites/default/files/d7/the_use_of_knowledge_in_society_-_hayek.pdf
- Coase transaction-cost overview: https://www2.sjsu.edu/faculty/watkins/coase.htm
- Auction-based MAS task allocation: https://arxiv.org/abs/2107.00144
- Reactive multi-agent coordination: https://arxiv.org/abs/2304.01976

## Adjacent agent infrastructure

### OpenAI Agents SDK guardrails

The OpenAI Agents SDK documents input, output, and tool-boundary
guardrails. Allbert's Security Central already operates at the
action boundary; objective stage hooks (guard, enrichment,
proposal, evaluation, consolidation, observation, reflection,
rendering) extend the pattern to objective stages without weakening
the action boundary.

Source:
- OpenAI Agents SDK guardrails: https://openai.github.io/openai-agents-python/guardrails/

### LangGraph state and graph patterns

LangGraph treats agent loops as explicit state graphs with nodes,
edges, and checkpoints. Allbert's seven-stage objective engine is
graph-shaped but implemented as a fixed state machine in v0.24, not
a configurable LangGraph. Future workflow graphs are a reserved
direction.

**Why Allbert doesn't adopt LangGraph wholesale:** LangGraph is a
configurable graph runtime. Allbert wants safety, audit, and eval
coverage before introducing configurable agent topology. v0.24
ships a fixed state machine; later milestones may add graph
configurability.

Sources:
- LangGraph docs: https://docs.langchain.com/oss/python/langgraph/graph-api
- Thinking in LangGraph: https://docs.langchain.com/oss/python/langgraph/thinking-in-langgraph

### From Agent Loops to Structured Graphs

This paper argues that long-running agent work benefits from
explicit state, nodes/steps, edges, checkpoints, and migrations
rather than opaque growing-context loops. Matches the Allbert
direction.

Source:
- From Agent Loops to Structured Graphs: https://arxiv.org/abs/2604.11378

### Memory for autonomous LLM agents

Liu et al. (2026) survey write/manage/read patterns for agent
memory. Allbert's v0.21 review/index/promotion work fits these
patterns; v0.24 reflection steps generate candidates, not writes.

Source:
- Memory for Autonomous LLM Agents: https://arxiv.org/abs/2603.07670

### Voyager, Reflexion

Voyager (Wang et al., 2023) and Reflexion (Shinn et al., 2023)
demonstrate skill libraries and reflection-driven self-improvement
in LLM agents. Allbert's v0.03 skills substrate already does the
library piece; reflection-driven workflow memory is reserved for
future milestones.

Sources:
- Voyager: https://arxiv.org/abs/2305.16291
- Reflexion: https://arxiv.org/abs/2303.11366

### Jido

Allbert is built on Jido (jido 2.2.0, jido_action 2.2.1,
jido_signal 2.1.1, jido_ai 2.1.0). Jido provides:

- `Jido.Signal` + `Jido.Signal.Bus` — CloudEvents-style event
  vocabulary.
- `Jido.Action` — schema-validated capability execution.
- `Jido.Agent` — schema-validated state, command dispatch,
  lifecycle hooks.
- `Jido.AI.Agent` — agent with AI tool conversion.
- `Jido.Skill` — composition of actions, signals, child specs.

**Allbert's current usage (verified by repo grep at v0.22):**
- `IntentAgent` uses `Jido.AI.Agent` (the only Jido.Agent in the
  codebase before v0.23).
- All effectful capabilities are `Jido.Action` modules.
- The signal bus is the runtime event substrate.
- `on_before_cmd`/`on_after_cmd` are not used anywhere yet.

**v0.23 closes the clearest gap:** Confirmations.Store and
Jobs.Scheduler become Jido.Agents.

**v0.24 adds the next Jido.Agent:** Objectives.Engine.

The pragmatic rule from v0.23 (`docs/plans/archives/v0.23-plan.md`) governs
future component substrate choice: use Jido.Agent when state
machines, lifecycle hooks, or successor agents are plausibly
useful; use plain GenServer for storage where no useful "v2 with
better algorithms" exists.

Source:
- Jido docs via Context7: `/agentjido/jido` and
  `/agentjido/jido_signal`.

## Reading order for new agents on the project

If you're new to the Allbert codebase and want to understand the
objective runtime work:

1. Read `docs/adr/0021-intent-objective-capability-and-advisory-
   boundary.md` for the binding decisions.
2. Read `docs/plans/archives/v0.24-plan.md` for the implementation.
3. Read `docs/plans/archives/v0.24-request-flow.md` for the user-visible
   flows.
4. Read this file's Hermes Agent and OpenClaw sections for
   contemporary comparison.
5. Skim the BDI, Soar, and ReAct sections for vocabulary.
6. The world-model, market, and diffusion sections are reserved
   vocabulary; read only when those provider roles become real.
