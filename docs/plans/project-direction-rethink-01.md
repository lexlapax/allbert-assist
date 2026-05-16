# Project Direction Rethink 01

Status: working analysis draft. Not an ADR, not a plan, not binding.

Purpose: capture the rethink that Allbert should be organized around
human-understandable objective loops — understand intent, frame outcomes,
inventory available capabilities and resources, generate possible routes,
evaluate tradeoffs, choose or ask, execute through registered actions,
observe, and learn. The architecture should leave room for deterministic,
probabilistic, stochastic, diffusion-style, market/resource-allocation,
world-model, language-model, and future advisory model providers without
making any of them authority.

This document is intentionally root-level and temporary while the project
direction is being questioned. It is a coordination artifact for the human
operator and future agents, not project law.

## Doc Posture And Target End State

This document is **exploration**, not implementation guidance. The doc is
intentionally long while the rethink is being shaped; the intent is that it
shrinks substantially once the operator chooses a direction.

Sections in this file are tagged in their headers:

- **(decision-grade)** — recommendations the operator should evaluate and
  commit to or reject. Once accepted, they move to an ADR or plan.
- **(exploratory)** — brainstorming. May be cut, deferred, or moved to a
  research note before this file is retired.

Target end state after the operator decides:

| Content | Destination |
|---------|-------------|
| Intent-vs-objective decision, authority and boundary rules | `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md` (new ADR) |
| Concrete v0.23 implementation, milestones, tests, exit signal | `docs/plans/v0.23-plan.md` (rewritten) + `docs/plans/v0.23-request-flow.md` (new) |
| Citations, literature, future provider roles (world models, diffusion, market allocators, JEPA) | `docs/research/objective-runtime-research.md` (new) |
| Coding policy non-negotiables | `AGENTS.md` additions |
| Roadmap renumbering and milestone bumps | `docs/plans/roadmap.md` |
| Vision updates for objective layer and provider model | `docs/plans/allbert-jido-vision.md` |
| Parking-lot updates | `docs/plans/future-features.md` |
| Subsystem routing for objective work | `docs/developer/agent-context-map.md` |

Once those land, this file shrinks to a short historical preface and a
pointer to the ADR + plan + research note. It is not a permanent reference.

## Decisions Locked In (2026-05-16)

The operator chose these positions from the open questions:

- **Alternative A.** v0.23 becomes Objective Runtime Foundation.
  v0.23–v0.29 renumber to v0.24–v0.30. Native Jido Trading Agents move to
  v0.24, consuming objective state from day one.
- **Engine substrate: Jido.Agent + lifecycle hooks.**
  `AllbertAssist.Objectives.Engine` is implemented as a `Jido.Agent` and
  uses `on_before_cmd`/`on_after_cmd` for stage transitions. This is a
  deliberate departure from the current pattern (everything except
  `IntentAgent` is a plain `GenServer`).
- **Signal model: coexist.** `allbert.objective.*` signals are emitted
  alongside existing `allbert.action.*` and `allbert.runtime.turn.*`
  events. Trace renders objective state as wrapper context.
- **Cancellation: cooperative only.** `cancel_objective` transitions
  status to `:cancelled`, blocks new step creation, and lets in-flight
  registered actions complete normally. Mid-action interruption is
  deferred — see numbering note below; the deferral target shifts from
  v0.24+ to v0.25+ once the Convergence milestone is inserted.
- **Jido convergence scope: state-machine fits only.** Convert
  `Confirmations.Store` and `Jobs.Scheduler` to Jido.Agents (both have
  pending→resolved state machines and plausible successor-agent
  stories). `Settings`, `Trace`, `Memory` storage IO, and
  `Session.Scratchpad` stay as plain GenServers — they are storage with
  fixed algorithms; no useful "v2 with better algorithms" exists.
  `Memory.Compiler` and `Memory.Promotion` stay as GenServers for the
  same reason.
- **Convergence timing: dedicated mini-milestone before Objective
  Runtime.** v0.23 = Jido State-Machine Convergence. v0.24 = Objective
  Runtime Foundation (formerly proposed as v0.23). v0.25 = Native Jido
  Trading Agents (was v0.23 originally). v0.23–v0.29 from the original
  roadmap renumber downstream to v0.25–v0.31 — a +2 shift instead of
  the +1 shift in the earlier rethink decision.
- **Rule wording: pragmatic "agents where it helps" soft rule.** New
  components author chooses Jido.Agent or plain GenServer based on
  plausible value (state machine, lifecycle hooks, successor-agent
  story). No hard rule. Reviewers judge case-by-case.

**Honest note on numbering shift.** References below to "v0.23 =
Objective Runtime Foundation" should now be read as v0.24. The earlier
text in this file remains to preserve the historical reasoning of each
decision; cascade artifacts (ADR 0021, new plan files, roadmap updates)
use the final numbering: v0.23 = Convergence, v0.24 = Objective Runtime,
v0.25 = Native Trading Agents, v0.26–v0.31 = the downstream sequence.

**Honest note on the soft rule.** The pragmatic "agents where it helps"
rule does not give reviewers a hard test for whether a new component is
correctly classified. This is intentional — Allbert is small enough that
case-by-case judgment is workable — but it means classification can
drift over time as different authors apply different thresholds. If
drift becomes an issue, tightening to the decision-making vs storage
hard rule remains an option (the v0.23 Convergence converts the two
clear state-machine fits regardless; only the going-forward rule for
new components is soft).

**Honest note on the Jido.Agent choice.** This is the bigger of the two
engine options and increases the Jido surface area Allbert maintains.
The repo as of v0.22 uses `Jido.AI.Agent` only in `IntentAgent` and uses
no `on_before_cmd`/`on_after_cmd` callbacks anywhere; choosing this path
means the objective engine establishes the pattern for future Jido
agents (delegated planners, evaluators, StockSage specialist agents) and
becomes the load-bearing example developers learn from. The upside is a
consistent agent pattern as the system grows; the downside is that stage
transitions now run through Jido's lifecycle machinery rather than plain
GenServer callbacks, and developers reading the code need to understand
both patterns (GenServer for Settings/Confirmations/Trace/Jobs;
Jido.Agent for IntentAgent/Objectives.Engine and future specialists).
v0.23 must include a developer-facing note in `DEVELOPMENT.md` and a
worked example in the v0.23 plan covering: state shape, schema
validation, `on_before_cmd`/`on_after_cmd` semantics for stage
transitions, directive emission, signal correlation, and how the engine
agent supervises (or is supervised alongside) the SQLite-backed
objective row store. The plan should also be explicit that
`Actions.Runner.run/3` + Security Central remain the only authority
boundary; Jido.Agent state mutations through `cmd` do not bypass that.

## Instructions For Future Agents

Read this file as a living architecture notebook, not as binding project law.
When asked to continue the rethink:

1. Separate facts from proposals. Sections tagged (decision-grade) are
   recommendations; (exploratory) are still being shaped.
2. Verify current repo state before making claims. Read at least:
   `docs/plans/allbert-jido-vision.md`, `docs/plans/roadmap.md`,
   `docs/plans/future-features.md`, the active milestone plan, relevant ADRs,
   and the current code around runtime, intent, actions, jobs, traces, memory,
   and StockSage.
3. Use web research when the user asks for research or when current AI-agent,
   planning, world-model, or framework terminology matters. Prefer primary
   papers, official docs, and reputable technical sources. New material goes
   into the research note, not into this file.
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

## Current Claim (decision-grade)

Allbert should not be organized only around "intent routes to action." That is
too flat for agentic work.

The system should distinguish:

- **Intent**: what the user appears to mean or request right now.
- **Objective**: the outcome Allbert is trying to achieve across one or more
  actions, steps, agents, surfaces, jobs, and confirmations.
- **Step**: a bounded unit of work inside an objective.
- **Observation**: an actual result from the environment, runtime, action,
  channel, job, memory, trace, or user.
- **Capability inventory**: what Allbert can currently do through registered
  actions, plugins, skills, channels, apps, jobs, providers, settings,
  credentials, local resources, and operator-approved access.
- **Capability gap**: what Allbert cannot currently do, but could ask the user
  to configure, research, install, implement, generate, schedule, or decline.
- **Route**: a proposed way to pursue an objective using available or
  acquirable capabilities.
- **Resource decision model**: advisory logic that prices routes by cost,
  latency, risk, scarcity, trust, user burden, reversibility, maintenance,
  and probability of success.
- **Acquisition option**: a proposed investment in new capability, such as
  requesting a credential, changing a setting, installing a plugin,
  generating an app scaffold, writing code, or asking the user to choose a
  different path.
- **World model**: a future predictive or counterfactual model of how state
  may change under proposed actions. Not the same as an LLM.
- **Planner/evaluator**: proposal and assessment logic that may use
  deterministic rules, LLMs, world models, traces, memory, or app-specific
  context.
- **Hook**: a bounded extension point before, after, or around a stage.
  Hooks can guard, enrich, propose, evaluate, consolidate, observe, reflect,
  or render. Hooks are not authority.
- **Impasse**: a first-class blocked-thinking state — no viable step, too
  many unresolved steps, missing context, pending confirmation, or selected
  step unavailable.

The user's framing was: **intent first, objective after or in parallel,
then span-out, span-in, hierarchy, consolidate, and repeat until the actual
outcome is reached.**

**Critical refinement.** Not every concept above needs to become a durable
database row in v0.23. The durable v0.23 records should stay small:
objectives, objective steps, and objective events. Capability inventory,
resource decisions, and advisory model outputs can start as event types,
trace sections, and hook contracts before becoming durable subsystems.

## Why This Matters Now (decision-grade)

Allbert is almost done with v0.22, the StockSage Python bridge. The next
planned milestone is native Jido trading agents. That is the first real
multi-agent domain workflow.

If native StockSage agents are implemented before a shared objective runtime,
StockSage is likely to invent a private goal/task orchestration model. Later,
the workspace shell, ephemeral UI, canvas, jobs, memory review, and app
generator would either duplicate or migrate around that private model.

Because the project is not production code yet and backward compatibility is
not a priority, this is a good moment to insert the missing substrate rather
than preserve old plan shape.

## Evidence Of Present-Day Breakage (decision-grade)

The argument for inserting an objective layer should rest on observed friction,
not only on what StockSage native agents might do later. Four current seams
already point at the missing layer:

1. **v0.07 confirmation resume.** A confirmation record carries selected
   skill, action, params, origin/resolver channel, and Security Central
   decisions. It does not carry a first-class field for "what larger work
   is this in service of?" When `mix allbert.confirmations list` returns
   multiple pending records, the operator infers their purpose from action
   name and params, not from a shared continuation handle.

2. **v0.13 scheduled job → confirmation handoff.** A scheduled job that
   triggers a high-risk action creates a pending confirmation. The job
   `run_id` and the confirmation id are linked through trace metadata, but
   there is no durable record that says "job J created confirmation C in
   pursuit of objective O." Each cross-record join is reconstructed by hand.

3. **v0.20 StockSage queue.** `stocksage_analysis_queue` and `_queue_runs`
   already store `status` (`pending`/`running`/`cancelled`/...), `queued_at`,
   `started_at`, `completed_at`, and `user_id`/`thread_id`. This is a
   domain-specific objective table by another name. Without a shared
   primitive, v0.23/v0.24 native trading agents will either duplicate this
   pattern in a second app or invent something incompatible with it.

4. **v0.22 `RunAnalysis` confirmation flow.** Confirmed analysis runs the
   bridge, persists analyses + details, and returns. There is no
   operator-visible record that says "this `RunAnalysis` was step 2 of a
   4-step analysis-and-compare workflow you asked for." A second
   `analyze MSFT` from the user starts cleanly but disconnected.

Together, these are weak signals — none individually justify a foundation
milestone — but they do suggest the project is already paying the cost of
an implicit objective concept. The question is whether to make it explicit
now, before native agents and workspace shell calcify around the implicit
version.

## Alternatives Considered (decision-grade)

Four ways to address the gap:

- **A. Insert v0.23 Objective Runtime Foundation as a new milestone.**
  Renumber existing v0.23–v0.29. Build minimal objective/step/event tables,
  stage state machine, internal hook dispatcher, and one proven loop in
  StockSage `RunAnalysis` before native agents land.
  - Cost: 6 milestone plan files renumbered, cross-references updated,
    CHANGELOG references old numbers, native trading agents slip by one
    release.
  - Benefit: native agents consume shared objective state from day one;
    workspace shell builds on the same primitive; future apps inherit.

- **B. Build minimal scaffolding inside v0.23 native agents; factor later.**
  Keep v0.23 = Native Jido Trading Agents. Let StockSage define
  `StockSage.Objective` + `StockSage.Objective.Step` and prove the shape in
  one app. Extract a shared `AllbertAssist.Objectives` layer in v0.24 or
  v0.25 once a second consumer (workspace shell, second app) shows up.
  - Cost: StockSage will likely shape the abstraction around trading
    workflows; later extraction is a refactor rather than a clean library;
    cross-cutting hooks (Security Central, traces, redaction, audit) get
    wired through StockSage code first.
  - Benefit: avoids speculative shared layer; renumbering avoided; one app
    proves the shape before the abstraction.

- **C. Extend confirmations + jobs as the durable spine; no new entity.**
  Add `objective_id` (or `intent_thread_id`) as a string field to
  confirmations and jobs. Treat a Thread + linked confirmations/jobs as the
  implicit objective. Render multi-step views over the join. No new table.
  - Cost: cross-record joins remain manual; no first-class "what is Allbert
    pursuing right now" answer; impasse and progress semantics get bolted
    onto existing tables; reflection/memory-promotion candidate generation
    has no home.
  - Benefit: zero new state; no renumbering; smallest blast radius.

- **D. Defer entirely.** Finish v0.22 and v0.23 as planned. Revisit the
  rethink after native agents and workspace shell expose real pain.
  - Cost: by the time pain shows up, StockSage native agents and the
    workspace shell will have shaped private continuation patterns; later
    extraction is more expensive.
  - Benefit: zero speculative work; let real usage drive the design.

**Recommendation:** A or C, depending on appetite. A is the cleaner
long-term substrate but pays a renumbering tax now. C is a much smaller
change that defers the hard call and may suffice for v0.23–v0.25. **B is
the worst option** because it puts the shape inside one app where security
and cross-cutting concerns are hard to wire correctly. **D is reasonable**
if the operator believes evidence of breakage is too weak.

This is question #1 below.

## Current Repo Map

The current code already has many pieces needed for an objective loop, but
they are not connected by a named objective layer.

- `AllbertAssist.Runtime` — receives normalized user/channel input, creates
  input/response signals, persists conversation messages, calls the intent
  agent, records traces, returns channel-renderable responses.
- `AllbertAssist.Agents.IntentAgent` — primary agent facade. Contains
  deterministic route predicates, uses `AllbertAssist.Intent.Engine` for
  registry-aware candidate ranking and metadata. **The only `Jido.AI.Agent`
  in the codebase.**
- `AllbertAssist.Intent.Decision` — inert selected-route contract.
  Describes selected skill/action/surface/resource posture,
  user/session/app context, and approval handoff. Should not become
  objective state.
- `AllbertAssist.Intent.Engine` — collects and ranks candidates from
  actions, skills, surfaces, jobs, channels, memory, and refusals. Proposal
  infrastructure; not authority and not a durable planner.
- `AllbertAssist.Intent.Candidate` / `Intent.Ranker` — bounded, redacted
  proposal/ranking data.
- `AllbertAssist.Actions.Runner` — the only action execution boundary;
  emits lifecycle signals; integrates Security Central, permission
  decisions, redaction, and confirmation resume.
- `AllbertAssist.Jobs` — durable recurring/background execution; not a
  general objective/task graph.
- `AllbertAssist.Conversations` — SQLite thread/message history; not
  outcome/progress state.
- `AllbertAssist.Session.Scratchpad` — volatile session context and
  `active_app`; not durable objectives.
- `AllbertAssist.Trace` — records what happened; does not manage objective
  progress.
- `AllbertAssist.Memory` — markdown source of truth plus derived index,
  retrieval, review/correction/promote/prune actions (v0.21); not
  objective state.
- `AllbertAssist.Confirmations` — durable approval workflow records with
  resume metadata, channel origin/resolver, target rerun (v0.07).
- StockSage — first proving app. Local domain records, queue, actions,
  plugin/app registration, v0.22 bridge plans. Should consume the shared
  objective model rather than invent a private one.

**Verified state of Jido usage in this repo (by `rg`):**

- 1 module uses `Jido.AI.Agent` (`IntentAgent`). 0 use `Jido.Agent`.
- 0 modules use `on_before_cmd`/`on_after_cmd` lifecycle hooks.
- Most long-lived state-bearing modules are plain `GenServer` (Settings,
  Confirmations, Memory, Sessions, `Jobs.Scheduler`, `Trace`).
- Jido's load-bearing value to Allbert is **`Jido.Signal` + `Jido.Signal.Bus`**
  for CloudEvents-style events and **`Jido.Action`** for the registered-
  action boundary. The agent abstraction is barely used.

This matters for the rethink. See the Jido Substrate Mapping section below.

## Comparison To Adjacent Systems

Three live systems and several classical references inform this rethink.
None of them is a model Allbert should clone, but each names a problem
Allbert will hit.

### Hermes Agent (Nous Research)

Hermes uses a `/goal` command to set a persistent objective the agent
pursues across turns until the operator pauses it or the agent decides
it's done. Persistence is via SQLite session storage (FTS5 indexed) plus
markdown memory files (`SOUL.md`, `MEMORY.md`, `USER.md`), **not a
dedicated "objective" table**. The agent loop is largely LLM-driven: a
synchronous `AIAgent` builds a prompt, calls the model, runs tool calls,
persists state. **No dedicated judge model** — completion is whatever the
model emits as the final response. Sub-agent delegation is a registered
tool; the child gets the parent's session history but a restricted tool
registry. Tools self-register via a central registry (70+ tools, ~28
toolsets).

**What Allbert can borrow from Hermes:**

- The verb. A `/goal` (or `/objective`) command is a clear operator surface
  for the "tell me what you're working on" affordance Allbert is missing.
- Restricted tool scope on delegation. A future `delegate_agent` step kind
  should hand the child agent a narrower action registry, not the parent's
  full surface.
- Lazy tool/skill metadata in prompts. Hermes is converging on the same
  pattern Allbert already uses (v0.03 progressive disclosure).

**What Allbert should not borrow from Hermes:**

- The `execute_code` meta-tool. Hermes lets the model write Python that
  calls other Hermes tools via a local RPC bridge. This collapses many tool
  calls into one model turn but is exactly the kind of authority
  concentration Allbert's action/Security Central boundary is designed to
  prevent.
- LLM-as-completion-judge. Hermes lets the model decide it's done. Allbert's
  confirmation/Security Central posture requires more explicit acceptance
  criteria than "the model said it's done."

### OpenClaw

OpenClaw is a hub-and-spoke local agent platform: a single Gateway brokers
multiple chat front-ends (WhatsApp, iMessage, Slack, macOS app, web, CLI)
to one Agent Runtime. Sessions are append-only event logs under
`~/.openclaw/sessions/`, keyed by trust boundary
(`agent:<id>:main`, `:dm:<id>`, `:group:<id>`). **The main session runs
tools natively on the host; DM and group sessions run inside Docker by
default.** Tools are lazily loaded — only skills relevant to the current
turn are injected into the model's prompt, with `SKILL.md` files read on
demand. Memory is SQLite-stored embeddings plus structured markdown
(`MEMORY.md`, `memory/YYYY-MM-DD.md`). The system implements
**per-session serial queues by default**, opting into parallelism only
when provably safe.

**What Allbert can borrow from OpenClaw:**

- **Per-session serial execution by default.** OpenClaw runs serial within
  a session, opting into parallelism only when provably safe. This is the
  right default for Allbert's `objectives.max_parallel_steps` /
  `allow_parallel_steps` question: default 1 (serial); require explicit
  per-objective opt-in for parallelism.
- **Trust-tiered runtime sandboxing per session type.** Main sessions run
  natively; channel-originated sessions run sandboxed. Allbert's v0.16
  channel adapters map external identities to local `user_id` but do not
  isolate runtime per channel. v0.26 security hardening should consider
  this, and v0.23 objective `source_channel`/`source_session_type` fields
  should leave room for a per-session-type policy.
- **Conversation compaction.** OpenClaw automatically summarizes older
  session segments. Allbert's v0.21 memory `compile_memory_index` is
  similar in spirit for markdown memory; v0.12 threads have no equivalent
  and may need one before objectives accumulate long turn histories.

**What Allbert already does that matches OpenClaw:**

- Lazy `SKILL.md` reading via v0.03 progressive disclosure.
- Local-first SQLite storage.
- Multi-channel routing via v0.16 channel adapters + v0.17 plugin
  contribution.

**What Allbert should not borrow:**

- Docker-by-default for non-main sessions. v0.08 explicitly defers
  container isolation; v0.26 should evaluate this on workflow evidence,
  not as a hard requirement.

### Classical references (brief)

- **BDI (Belief–Desire–Intention).** Separates beliefs (what is known),
  desires (what outcomes are wanted), intentions (active commitments),
  plans (how to act). Allbert maps cleanly: memory/index ≈ beliefs;
  objective ≈ desire + intention; step ≈ plan element. Allbert does not
  import BDI wholesale.
- **Soar.** Names "no operator," "tie," and "cannot apply" as first-class
  impasses, not silent failures. Allbert adopts this vocabulary even
  without adopting Soar's chunking.
- **ReAct.** Interleave reasoning and acting. Allbert's flat intent →
  action loop is already a ReAct-shaped pattern; objectives are how to
  span multiple turns of the same interleave.
- **HTN planning.** Tasks decompose into subtasks. Allbert reserves
  hierarchy (`parent_objective_id`, `parent_step_id`) but does not adopt a
  formal HTN planner in v0.23.
- **Tree of Thoughts.** Deliberate span-out over candidate reasoning paths
  with evaluation. Useful vocabulary for the proposal / evaluation /
  consolidation stages, not a runtime to import.
- **Workflow Memory.** Repeated trajectories become reusable workflows.
  Allbert's traces can become workflow candidates after explicit operator
  review, never automatically.

A full citation list and notes on JEPA, diffusion planners, market
allocation, world models, LangGraph state patterns, OpenAI Agents SDK
guardrails, and Jido reference material belongs in
`docs/research/objective-runtime-research.md` (planned). That note is
research material; it is not load-bearing for v0.23.

## Boundary With Existing Durable Layers (decision-grade)

If v0.23 adds an `objectives` table, it must answer these existing-state
questions before module work starts:

- **vs. Threads (v0.12).** A Thread is durable conversation. An objective
  is durable work. One thread may host zero, one, or many objectives across
  time. An objective may reference one or more threads (the original ask,
  later check-ins). Recommendation: `objective.source_thread_id` (nullable);
  no join table in v0.23.

- **vs. Confirmations (v0.07).** A confirmation is the durable
  approve/deny/expire record for one risky action. When an objective creates
  a step that requires confirmation, the confirmation record gains
  `objective_id` + `step_id` for join visibility. Confirmation status
  transitions emit objective step events; the objective engine listens.
  Recommendation: confirmations remain authoritative for permission;
  objectives reflect that state in trace and summary.

- **vs. Jobs (v0.13).** A job is a durable scheduled or background
  execution. A job may execute a single action (no objective needed),
  advance an existing objective (job carries `objective_id`), or start one
  (job creates the objective on first run). Recommendation:
  `job.objective_id` (nullable); cron-driven work that creates new
  objectives goes through the same admission check operator-initiated
  requests do.

- **vs. Memory promotion (v0.21).** `promote_conversation_turn` is already
  a confirmed action with bounded body, ownership check, and trace
  section. An objective `reflect` step may **propose** a promotion
  candidate, but the registered action remains the only path that writes.
  Recommendation: reflection produces candidates; operator (or a confirmed
  follow-up) promotes. v0.21 memory review surface does not change in v0.23.

- **vs. Surface/SurfaceProvider (v0.18).** Surfaces render. They do not own
  objective state. A surface may show an objective view or accept an
  operator action that advances one (cancel, continue, confirm a step),
  but the surface holds no objective truth.

- **vs. StockSage queue (v0.20).** This is the hardest boundary. Today the
  queue is a domain-specific objective table. Options:
  - (i) Keep the StockSage queue as-is; thread an `objective_id` through it.
  - (ii) Migrate StockSage queue records to objective steps in v0.23.
  - (iii) Define the queue as a *view* over objectives + steps.
  - **Recommendation: (i) for v0.23, (iii) later.** Do not migrate queue
    data in v0.23; it ships in v0.20 and v0.22 is already pinned to it.

This boundary section is bedrock for whether v0.23 is small (adds one row
type + a few signals) or large (re-homes existing data).

## What Shrinks (decision-grade)

A rethink is only worth the cost if some things consolidate. Candidates:

- `Intent.Decision.execution_mode` partially overlaps with objective step
  `kind`. Once objectives carry continuation semantics, `execution_mode`
  may collapse into step kind and confirmation state.
- `Session.Scratchpad.active_app` carry across turns can shrink: if there
  is an active objective, `active_app` is implied by `objective.active_app`.
  Scratchpad still owns short-lived volatile state.
- Synthetic-intent patterns inside `IntentAgent` (e.g., detecting
  "this is a resume-from-confirmation") collapse into explicit objective
  resumption.
- The current ad-hoc "what is this in service of?" rendering across
  `mix allbert.confirmations show`, `/settings` confirmation cards, and
  trace headers consolidates into one objective summary block.
- `Intent.Engine.collect_candidates/1` gains `:objective` as a first-class
  candidate kind — replacing several `:memory` candidates that are really
  "you have an open objective for this."

**If none of these consolidate, v0.23 is net bloat.** The minimum viable
v0.23 should ship with at least the first two.

## Concrete StockSage Migration Sketch (decision-grade once Alternative is chosen)

Today's `RunAnalysis` happy path:

1. User: "analyze AAPL" (with `active_app: :stocksage`).
2. Intent agent → `RunAnalysis` candidate.
3. Security Central → `:needs_confirmation`.
4. Confirmation record created.
5. Operator approves.
6. Confirmation resumes; `Actions.Runner.run/3` executes `RunAnalysis`.
7. `TraderBridge` runs; results persist to `stocksage_analyses`.
8. Response renders to user.

Proposed v0.23 path under Alternative A:

1. User: "analyze AAPL".
2. Intent agent ranks `RunAnalysis` candidate.
3. Objective engine **frames** an objective: title "Analyze AAPL",
   acceptance criteria "one completed analysis for AAPL on today's date",
   `active_app: :stocksage`, `source_thread_id`.
4. Engine proposes one step: kind `action`, candidate `RunAnalysis`.
5. Step admission → Security Central → `:needs_confirmation`.
6. Confirmation record created — now with `objective_id` + `step_id`.
7. Operator approves.
8. Step transitions `selected → running`.
9. `RunAnalysis` executes through existing path.
10. Result becomes objective observation.
11. Engine evaluates progress: acceptance criteria met → objective
    `completed`.
12. Response renders with objective summary.

Proposed multi-step path: "analyze AAPL and compare to MSFT" produces a
two-step objective with sequential execution; second step references the
first's observation.

**To fill in once Alternative A vs. C is chosen** (in the v0.23 plan, not
in this rethink doc): the exact schema mapping, exact step kinds used,
exact engine state-machine, exact admission policy interaction, and exact
migration story for the v0.20 queue.

## Authority And Privacy Rule (decision-grade)

One rule the rest of this document does not weaken:

**Advisory output is never authority.** This applies to LLM proposals,
world-model predictions, diffusion trajectories, market/auction bids,
probabilistic scores, JEPA-style latent predictions, generative-agent
simulations of user behavior, app-provider hints, and plugin-contributed
hook output. Advisory output may:

- propose, rank, predict, score, summarize, critique, explain;
- influence which step is selected by the engine;
- be rendered in trace, diagnostics, and surfaces.

Advisory output **may not**:

- authorize execution;
- bypass `Actions.Runner.run/3`, Security Central, confirmations, resource
  access posture, or audit;
- mark simulated state as observed truth;
- short-circuit operator confirmation, including confirmations the operator
  typically accepts.

**Specifically for user-behavior predictions.** A future agent-model
provider may predict that the user is likely to approve a given step. That
prediction is rendering data and trace metadata. **It is never a reason to
skip the confirmation.** The fact that the user "usually says yes" is not
equivalent to the user saying yes this time. This rule holds regardless of
confidence score, calibration history, or recency.

## Cognitive Runtime Pipeline (decision-grade for 7-stage shape; exploratory for detailed breakdown)

Recommended target shape for v0.23+: a **seven-stage** state machine, not
a sixteen-stage one. Five of the seven already exist in some form; v0.23
adds three and threads `objective_id` through the rest.

| # | Stage | What runs today | What changes |
|---|-------|-----------------|--------------|
| 1 | Receive | Runtime intake, channel adapter, scheduled job | Attach `objective_id` if resuming |
| 2 | Interpret intent | `IntentAgent`, `Intent.Engine` | Adds `:objective` candidate kind |
| 3 | Frame/resume objective | new | Decide create / resume / no-objective |
| 4 | Propose and evaluate steps | new | One deterministic proposer in v0.23; advisory providers later |
| 5 | Authorize selected step | `Actions.Runner` + Security Central + Confirmations | Step records reflect confirmation state |
| 6 | Execute | `Actions.Runner.run/3` | Unchanged |
| 7 | Observe and advance | `Trace`, response render | Observation becomes objective event; engine evaluates progress |

### Detailed sixteen-stage breakdown (appendix, exploratory)

The longer pipeline below is brainstorming retained from an earlier draft.
It is **not** a v0.23 commitment. Most stages should remain conceptual
stage-events emitted into the trace, not separate hook dispatch points
with named pre/post hooks. Each one-liner is the goal of that stage; full
hook lists are not reserved.

1. Intake / Perception — normalize external input into an Allbert request.
2. Guard / Safety Preflight — reject malformed or impossible input cheap.
3. Orientation / Context Assembly — assemble user/thread/app/memory context.
4. Intent Interpretation — pick most likely intent and candidate routes.
5. Objective Framing / Resumption — create, resume, or skip durable work.
6. Objective Admission / Constraint Check — admit if scope/budget allow.
7. Capability Inventory / Gap Analysis / Resource Routing — what's available.
8. Span-Out / Operator And Step Proposal — propose candidate next steps.
9. Retrieval / Working Context Enrichment — context for proposed steps.
10. Evaluate / Simulate / Price / Score — score proposed steps.
11. Allocate / Consolidate / Span-In — merge, prune, select.
12. Commitment / Dispatch Decision — commit, ask, wait, or block.
13. Authorization / Confirmation / Resource Binding — Security Central.
14. Execution — registered action runs.
15. Observation / Result Assimilation — turn results into observations.
16. Reflection / Consolidation / Learning — memory and workflow candidates.

Treat these as brainstorming. If the operator accepts the 7-stage shape,
this appendix is moved to the research note when the rethink doc is
retired.

## Hook Taxonomy (decision-grade for categories; exploratory for hooks)

Eight categories of stage extension points:

- **Guard hooks** may block or downgrade a stage before expensive work.
- **Enrichment hooks** add bounded context or metadata.
- **Proposal hooks** generate candidates: intents, objectives, steps,
  workflows, surfaces.
- **Evaluation hooks** score risk, cost, feasibility, predicted progress.
- **Consolidation hooks** merge, rank, prune, deduplicate, explain.
- **Observation hooks** normalize what happened.
- **Reflection hooks** propose memory, workflow, or trace consolidation.
- **Rendering hooks** shape what a surface or channel shows.

**Authority rule (re-stated for emphasis).** A hook can produce proposal
data, diagnostics, warnings, scores, predictions, or renderable summaries.
A hook cannot grant permission, execute effects, mark simulated state as
real, or bypass action boundaries. A hook is never authority.

Named hook points for v0.23 (intentionally minimal):

- `before_objective_frame` (guard / enrichment)
- `after_objective_frame` (observation)
- `step_proposer` (proposal)
- `step_evaluator` (evaluation)
- `on_impasse` (observation / rendering)

Other hook names that appeared in earlier drafts of this document are
**not reserved**. v0.23 should not pre-name 60+ hook points without
consumers. New hook points are added when a real consumer appears.

## Hook Lifecycle Shape (decision-grade)

Generic stage and hook event vocabulary (kept minimal):

```text
allbert.stage.started
allbert.stage.completed
allbert.stage.rejected
allbert.stage.blocked
allbert.stage.failed
```

Each stage signal includes: `stage`, `objective_id` (when applicable),
`step_id` (when applicable), `user_id`, `thread_id`, `session_id`,
`active_app`, `trace_id`, `source_signal_id`, bounded diagnostics.

Each hook result includes: `hook_id`, `hook_type`, `provider`, `status`,
`proposals` or `diagnostics`, `redaction_applied`, `simulated?` (when
applicable), `authority` (always `proposal_only` unless it is an existing
action runner or Security Central boundary).

`allbert.hook.*` signals are deferred until v0.23 has at least one
non-trivial hook consumer. Bounded hook output appears in objective trace
metadata in v0.23, not as a separate signal namespace.

## Jido Substrate Mapping (decision-grade, corrected)

**Important correction.** Earlier drafts of this document treated Jido as
if it were a deeply-integrated substrate. The actual current state, by
repo grep:

- 1 module uses `Jido.AI.Agent` (`IntentAgent`).
- 0 modules use `Jido.Agent`.
- 0 modules use `on_before_cmd`/`on_after_cmd` lifecycle hooks.
- Long-lived state-bearing modules are plain `GenServer`: Settings,
  Confirmations, Memory, Sessions, `Jobs.Scheduler`, `Trace`.
- Jido's load-bearing value to Allbert is `Jido.Signal` + `Jido.Signal.Bus`
  (CloudEvents-style events) and `Jido.Action` (registered-action
  boundary).

Implications for the objective design (with operator decision applied):

- **The objective engine is implemented as a `Jido.Agent` using
  `on_before_cmd`/`on_after_cmd` lifecycle hooks for stage transitions.**
  This is the operator's accepted choice (see Decisions Locked In above).
  The engine becomes the first non-`IntentAgent` consumer of `Jido.Agent`
  in the codebase and the first user of `on_before_cmd`/`on_after_cmd`
  anywhere. It establishes the pattern that future specialist agents
  (delegated planners, evaluators, StockSage analysts) will follow.
- The Jido agent owns engine state; **objective rows in SQLite remain
  authoritative for durable state.** The engine agent's state is a
  bounded in-memory projection used for the current turn; persistence
  goes through registered actions, not through agent-state side effects.
- Signal vocabulary uses `Jido.Signal` — already the right substrate.
- Registered Jido actions remain the only effectful capability boundary.
  A proposed objective step becomes executable only when it resolves to
  a registered action and passes Security Central. Jido.Agent `cmd`
  invocations on the engine itself are state-machine transitions, not
  capability execution; they do not bypass `Actions.Runner.run/3` or
  Security Central.
- Jido directives (emit, spawn, schedule, stop) are usable for objective
  lifecycle orchestration once objective/step state has been recorded;
  the v0.23 plan should pin down which directives are in scope (likely
  emit + schedule; spawn/stop deferred until specialist sub-agents
  arrive in v0.24).
- Developers will encounter two patterns in the codebase
  (plain `GenServer` for Settings/Confirmations/Trace/Jobs; `Jido.Agent`
  for IntentAgent/Objectives.Engine). `DEVELOPMENT.md` and the v0.23
  plan must document when to use each.

## Proposed Architecture Change (decision-grade)

Add an objective runtime layer between intent selection and action
execution.

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

Actions remain responsible for execution. No objective, planner, LLM,
world model, app, plugin, skill, or surface can bypass
`Actions.Runner.run/3`, Security Central, confirmations, resource access
posture, traces, or audits.

## Proposed v0.23 Insert (decision-grade)

Recommendation: finish v0.22 without derailing it, insert a new v0.23, and
bump native trading agents to v0.24.

### Renumbering cost-benefit

Renumbering v0.23-v0.29 → v0.24-v0.30 has real costs:

- 6 plan files renamed.
- All cross-references in roadmap, future-features, ADRs, request-flow
  docs, CHANGELOG, and READMEs updated.
- Outsiders reading old git commits or commit messages see "v0.23 = native
  agents," which is no longer current.
- Operator-facing release notes need a note explaining the renumbering.

Benefits:

- Clean v0.23 = foundation; v0.24 = native agents (consuming foundation).
- Future readers don't see a foundation milestone hidden as a sub-version.
- Matches the dependency order in the roadmap.

Alternative: keep v0.23 = Native Jido Trading Agents, land objective
foundation as v0.22a / v0.22.5 / v0.23-pre. This avoids renumbering
downstream milestones but creates an awkward sub-version structure that
will itself be renumbered later.

**Recommendation: bite the renumbering once.** This is question #3 below.

Final sequence (after both the Jido-Convergence insertion AND the
Objective-Runtime insertion — see Decisions Locked In):

- v0.22: StockSage Python Bridge, unchanged except handoff notes.
- v0.23: **Jido State-Machine Convergence (NEW).** Converts
  `Confirmations.Store` and `Jobs.Scheduler` to Jido.Agents. No new
  user-visible features; pure architectural refactor.
- v0.24: **Objective Runtime Foundation.** What the earlier rethink
  framing called "v0.23." Ships `Objectives.Engine` as a Jido.Agent
  built on top of the Convergence.
- v0.25: Native Jido Trading Agents, formerly v0.23 in the roadmap.
- v0.26: Agentic Workspace Surface And Ephemeral UI, formerly v0.24.
- v0.27: StockSage LiveViews, formerly v0.25.
- v0.28: Security Hardening And Evals, formerly v0.26.
- v0.29: StockSage Polish, Outcomes, Trends, Memory Namespaces,
  formerly v0.27.
- v0.30: StockSage Canvas Integration, formerly v0.28.
- v0.31: Plugin And App Generator, formerly v0.29.

## Proposed v0.23 Scope (decision-grade for minimum slice; exploratory for reserved)

The earlier draft of this section listed 16+ modules, 17 signal types, 15
settings keys, two provider behaviours, and a 9-type advisory provider
umbrella. That is approximately two milestones of work and should not
all ship in v0.23. The scope below splits *what ships* from *what is
reserved as vocabulary*.

### Minimum implementation slice (ships in v0.23)

Modules:

```text
AllbertAssist.Objectives
AllbertAssist.Objectives.Objective
AllbertAssist.Objectives.Step
AllbertAssist.Objectives.Event
AllbertAssist.Objectives.Engine               # Jido.Agent + on_before_cmd/on_after_cmd
AllbertAssist.Objectives.Stage                # stage names and bounds
AllbertAssist.Actions.Objectives.ListObjectives
AllbertAssist.Actions.Objectives.ShowObjective
AllbertAssist.Actions.Objectives.CancelObjective
AllbertAssist.Actions.Objectives.ContinueObjective
```

SQLite tables:

```text
objectives
objective_steps
objective_events
```

Objective fields (minimal):

- `id`, `user_id`, `source_thread_id`, `session_id`, `active_app`
- `status`: `open`, `running`, `blocked`, `completed`, `cancelled`, `failed`
- `title`, `objective` (bounded plain-language outcome),
  `acceptance_criteria`, `constraints`
- `source_intent`, `parent_objective_id`, `current_step_id`
- `progress_summary`, `last_observation_summary`
- `loop_count`
- `created_at`, `updated_at`, `completed_at`

Step fields (minimal):

- `id`, `objective_id`, `parent_step_id`
- `kind`: `action`, `ask_user`, `wait`, `observe`, `reflect`
  (only 5 kinds in v0.23; others are reserved)
- `status`: `proposed`, `selected`, `running`, `blocked`, `completed`,
  `cancelled`, `failed`
- `stage`, `provider`
- `candidate_action`, `action_params`
- `result_summary`, `observation_summary`
- `trace_id`, `confirmation_id`, `resource_access`
- `created_at`, `updated_at`

Signals (minimal set):

```text
allbert.objective.created
allbert.objective.updated
allbert.objective.step.proposed
allbert.objective.step.selected
allbert.objective.step.completed
allbert.objective.step.failed
allbert.objective.observed
allbert.objective.blocked
allbert.objective.completed
allbert.objective.cancelled
allbert.objective.impasse
```

Settings (minimal set, conservative defaults):

```text
objectives.enabled                       # default true
objectives.max_steps_per_turn            # default 3
objectives.max_loop_count                # default 5
objectives.default_persistence           # default :ephemeral_unless_multi_step
```

### Reserved vocabulary (named, not shipped in v0.23)

The following modules and concepts are **named** in this document so
later milestones can plug in without renaming, but are **not shipped**:

```text
AllbertAssist.Objectives.Hooks            # dispatcher for the 5 named hooks
AllbertAssist.Objectives.HookProvider     # plugin/app contribution behaviour
AllbertAssist.Objectives.Capability       # capability-inventory view
AllbertAssist.Objectives.CapabilityGap
AllbertAssist.Objectives.Route
AllbertAssist.Objectives.AcquisitionOption
AllbertAssist.Objectives.AdvisoryProvider
AllbertAssist.Objectives.WorldModelProvider
AllbertAssist.Objectives.Planner
AllbertAssist.Objectives.Evaluator
```

Step kinds reserved but not implemented in v0.23: `capability_inventory`,
`capability_gap`, `route`, `span_out`, `consolidate`, `evaluation`,
`acquisition`, `delegate_agent`, `surface`.

Settings reserved, not implemented in v0.23:

```text
objectives.max_parallel_steps             # reserved default 1
objectives.allow_parallel_steps           # reserved default false
objectives.hooks_enabled
objectives.hook_timeout_ms
objectives.capability_inventory_enabled
objectives.resource_decision_provider
objectives.resource_decision_timeout_ms
objectives.world_model_provider
objectives.world_model_provider_type
objectives.world_model_enabled
objectives.world_model_timeout_ms
objectives.require_confirmation_for_background_continuation
objectives.trace_detail
objectives.route_trace_detail
```

The capability inventory, route proposal, acquisition option, advisory
provider, world-model provider, diffusion provider, market allocator, and
probabilistic-inference provider vocabularies are reserved as research
notes. They are implemented only when a concrete consumer arrives.

### Implementation guardrails

- Conservative defaults. Background continuation, parallelism, and external
  provider behavior require explicit permission, confirmation, and trace
  policy.
- Effectful hook execution disabled by default. The only hooks that can
  run effects are existing registered actions, which already go through
  Security Central.
- No public plugin hook contribution in v0.23. Implement internal hook
  dispatch first; expose plugin contribution after one Allbert-owned loop
  and one StockSage loop are proven.
- No JEPA model, learned world model, simulator, vector store, robot
  runtime, or external provider call.
- No marketplace, autonomous installer, dynamic code loader, spend policy,
  provider bidding runtime, or automatic capability acquisition.

## Exit Signal For v0.23 (decision-grade)

v0.23 ships when:

- Operator can run
  `mix allbert.ask --user local "analyze AAPL and compare to MSFT"` and see
  one objective with two steps in `mix allbert.objectives list`, each
  linked to its confirmation.
- Operator can run `mix allbert.objectives show <id>` and see status,
  acceptance criteria, current step, observation summary, and trace link.
- Operator can run `mix allbert.objectives cancel <id>` to stop in-flight
  work cooperatively: any registered action that is currently executing
  completes; no new step starts; status transitions to `:cancelled` with
  an audit event.
- LiveView `/agent` renders an "open objective" badge on the current
  thread and links to the objective view.
- StockSage `RunAnalysis` carries `objective_id` + `step_id` through
  Security Central, confirmation, trace, and audit metadata.
- Step / objective records appear under per-user isolation.
- Objective loops are bounded by `max_steps_per_turn` and
  `max_loop_count`; exceeding either records an `impasse`, not a silent
  failure.
- Full warning gate + precommit + dialyzer pass.

## Developer Experience Impact (decision-grade)

For one-shot capabilities: **nothing changes.** A plugin developer adds a
`Jido.Action`, registers it, and ships. No objective vocabulary required.

For multi-step capabilities (only): the developer learns three concepts:

1. How to declare acceptance criteria for an objective (free-text plus
   optional verifier).
2. How to propose a next step from a domain-specific proposer (returns a
   `Candidate` with kind `:action` plus action name + params).
3. How to read objective state in a surface (read-only).

The advisory provider behaviour, world-model provider behaviour, hook
contribution, and capability inventory are **not** part of the day-one
developer surface. They are kernel-internal until a real consumer
demonstrates the shape.

## Advisory Provider And World Model Vocabulary (exploratory)

World models are one advisory provider family, not the umbrella for all
future intelligence. **In v0.23, no provider behaviour is shipped.** The
broader interface is reserved as vocabulary only.

Reserved provider roles (named so future milestones can implement without
renaming):

- `IntentProvider`, `RouteProvider`, `CapabilityProvider`,
  `ResourceDecisionProvider`, `WorldModelProvider`,
  `DiffusionProposalProvider`, `ProbabilisticInferenceProvider`,
  `MarketAllocatorProvider`, `CriticEvaluatorProvider`.

These are roles, not Elixir behaviours, in v0.23. The first behaviour
extraction should wait until at least two providers of the same role
exist. Until then, the engine has one deterministic proposer and one
deterministic evaluator; that is the entire planner surface.

The detailed callback signatures for `AdvisoryProvider` and
`WorldModelProvider` previously sketched in this document (with
`encode_state`, `predict_latent_transition`, `compare_prediction_to_
observation`, etc.) are research notes. They belong in
`docs/research/objective-runtime-research.md` along with the JEPA, PSI,
generative agents, BEHAVIOR-1K, and diffusion-as-optimizer citations.

**Hard rules that survive even when these providers do ship later:**

- No advisory output authorizes execution.
- World-model output is predictive / counterfactual data, not observed
  fact. Simulated state must be labeled as simulated.
- Predictions about user behavior never short-circuit confirmation.
- All effectful work flows through `Actions.Runner.run/3`, Security
  Central, confirmations, resource access posture, traces, and audits.
- Settings Central config, Security Central posture, redaction, traces,
  and evals gate any future provider call.

## Coding Policies To Add

If accepted, add these to `AGENTS.md`, `DEVELOPMENT.md`, and the ADR:

- Multi-step work must be represented as objectives and steps, not private
  app, channel, LiveView, job, or plugin loops.
- LLM/model output may propose intents, objectives, steps, critiques, or
  evaluations, but cannot authorize or execute.
- World-model output is predictive / counterfactual, not observed fact.
  Simulated state must be labeled and cannot be written as memory/domain
  truth without observation or operator confirmation.
- Apps/plugins must not implement private durable goal loops.
- Every objective step that mutates, fetches, sends, spends, executes,
  analyzes, imports, installs, or contacts external systems must ground
  to a registered action and Security Central.
- Objective loops must have step, time, cost, confirmation, cancellation,
  and trace bounds.
- Objective state is not authorization. `objective_id` never grants
  permission. `active_app` may scope ranking and objective context, but
  not permission.
- Stage hooks are proposal/diagnostic infrastructure unless they explicitly
  call an existing registered action. Hook output must be bounded,
  redacted, traceable, and labeled by provider.
- Apps/plugins may contribute objective context or candidate steps only
  through declared hook/provider contracts. They must not subscribe to
  raw signals and mutate objective state privately.
- Capability acquisition is never silent. Installing/importing/enabling a
  plugin, requesting credentials, writing code, generating an app
  scaffold, spending money, calling a paid/external provider, or
  granting resource access must go through an operator-visible registered
  action path.
- Resource decision, market-allocation, model-routing, diffusion,
  probabilistic, and world-model providers may propose, price, predict,
  rank, or critique routes. They cannot authorize, execute, spend,
  install, grant trust, mutate objective truth, or bypass Security
  Central.
- Predictions about user behavior never short-circuit confirmation.
- Impasses are first-class. If Allbert has no candidate step, too many
  unresolved candidates, insufficient context, or an unexecutable
  selected step, it should record an impasse and ask, retrieve, defer,
  or block rather than spin.
- Every loop must show why it continued. Repeating an objective cycle
  without new observation, new context, new approval, or changed ranking
  should be a test failure.

## Docs That Need Updating If Accepted

Immediate doc changes:

- `docs/plans/allbert-jido-vision.md` — add a major "Intent, Objectives,
  And World Models" section; update Product Shape and North Star; note the
  corrected Jido usage state (Signal + Action are load-bearing; Agent
  abstraction is barely used).
- `docs/plans/roadmap.md` — insert v0.23 Objective Runtime Foundation and
  renumber v0.23+ (under Alternative A).
- `docs/plans/future-features.md` — replace the rough "Intents vs
  Objective" note; move Objective Runtime Foundation into "Already
  Planned Elsewhere"; add a separate unassigned entry for future real
  world-model providers and simulation.
- `docs/adr/0021-intent-objective-capability-and-advisory-boundary.md` —
  new ADR. Defines intent, objective, step, observation, capability
  inventory, capability gap, route, acquisition option, resource decision
  model, planner/evaluator, world model, advisory provider, and action
  authority boundaries.
- `docs/adr/0019-cross-surface-intent-enrichment.md` — add a note that
  ADR 0021 supersedes any implication that intent ranking is the full
  work-management layer.
- `AGENTS.md` — add a compact non-negotiable about objective/step state
  for multi-step work.
- `DEVELOPMENT.md` — add objective runtime to the architecture contract.
- `docs/developer/agent-context-map.md` — add routing guidance for
  objective/task work.

Plan changes:

- `docs/plans/v0.22-plan.md` — add a handoff note: v0.22 remains a single
  action/bridge execution path and does not implement a private objective
  loop. v0.23 will add shared objective state before native agents.
- `docs/plans/v0.23-plan.md` — replace current Native Jido Trading Agents
  plan with Objective Runtime Foundation.
- New `docs/plans/v0.23-request-flow.md` — describe runtime/user flow:
  ask, frame objective, propose steps, execute one registered action,
  observe result, continue/block/complete.
- Move current `docs/plans/v0.23-plan.md` content to `v0.24-plan.md` and
  expand native trading agents to consume objective/step state.
- Bump `v0.24` through `v0.29` plans and update cross-references.

New research note:

- `docs/research/objective-runtime-research.md` — collects the literature
  review currently inlined in this rethink doc: ReAct, Tree of Thoughts,
  World Models, DreamerV3, Genie, JEPA family, PSI, Stanford NeuroAI,
  Language Models / Agent Models / World Models, Voyager, Reflexion,
  Generative Agents, HAI human-behavior simulation, BEHAVIOR-1K,
  resource-rational analysis, Bounded-Optimal Agents, Language Model
  Cascades, FrugalGPT, RouterBench, RouteLLM, Diffusion Policy,
  MetaDiffuser, Diffusion-as-Optimizer, Hayek, Coase, auction-based MAS,
  BDI discussion, Soar, HTN, Workflow Memory, Memory for Autonomous LLM
  Agents, From Agent Loops to Structured Graphs, OpenAI Agents SDK
  guardrails, LangGraph docs, Jido docs, **Hermes Agent (Nous Research)**,
  **OpenClaw**.

## Settings UI Implication

Full Settings UI Polish should not be treated as only visual polish anymore.

Settings UI should eventually explain settings by runtime layer:

- identity/session
- intent
- objectives / planning / capability inventory / resource decisions /
  advisory hooks
- actions / security
- jobs
- channels
- plugins / apps
- memory
- surfaces / canvas

The future Settings UI should show which subsystem consumes a setting,
whether the value came from defaults/operator/project/plugin/request
layers, whether it affects authority, and where its audit trail lives.

Prerequisites for planning Full Settings UI Polish:

- stable objective settings schema
- stable capability inventory and resource decision settings schema (later)
- objective trace/debug UI
- app/plugin settings grouping
- security posture explanation per setting
- secret entry and redaction UX
- search and validation
- accessibility and mobile behavior

## What Not To Do (consolidated)

One list, not repeated across sections:

- Do not turn `Intent.Decision` into a large objective record.
- Do not let `Intent.Engine` become the planner/executor/evaluator.
- Do not let StockSage native agents create a private durable task graph.
- Do not let workspace LiveViews own objective logic.
- Do not implement the objective engine as a `Jido.Agent` "to fit Jido"
  when the rest of Allbert uses plain `GenServer`.
- Do not pre-name 60+ hook points without consumers.
- Do not ship an `AdvisoryProvider` umbrella behaviour before two
  providers of the same role exist.
- Do not treat world-model predictions as truth.
- Do not treat provider bids, route scores, market prices, cost estimates,
  or model-routing choices as authority.
- Do not let predictions about user behavior short-circuit confirmations.
- Do not silently acquire capabilities. Missing capabilities should
  become explicit options, confirmations, refusals, or implementation
  work.
- Do not implement Hermes-style `execute_code` meta-tools that let a
  model call multiple Allbert tools in one untraced sequence.
- Do not introduce autonomous background loops without explicit operator
  controls.
- Do not introduce a marketplace, autonomous installer, dynamic code
  loader, spend policy, provider bidding runtime, or automatic capability
  acquisition in v0.23.
- Do not migrate v0.20 StockSage queue records to objective steps in
  v0.23.
- Do not add broad compatibility layers for old pre-production plans.
  Prefer clean renumbering and direct migration while the project is
  still local and unreleased for production use.

## Open Questions

Existing (carried forward from the earlier draft):

1. Should v0.23 store objective state in SQLite immediately, or begin
   with trace/session-linked ephemeral objective records?
   Current recommendation: **SQLite**, because jobs, confirmations,
   traces, and multi-turn work need durable linkage.
2. Should every user input create an objective, or only multi-step /
   non-trivial requests?
   Current recommendation: **only durable objectives for multi-step,
   background, app-scoped, confirmed, resumable, or explicitly tracked
   work.** Simple direct answers remain objective-free or use ephemeral
   trace-only objectives.
3. Should objective framing be deterministic first, model-assisted later?
   Current recommendation: **deterministic first** with optional model
   proposal hooks behind settings, redaction, and validation.
4. Should StockSage analyses become objectives or actions within
   objectives?
   Current recommendation: **`RunAnalysis` remains the action boundary**;
   a StockSage analysis objective may contain steps that call
   `RunAnalysis` and later native sub-agent steps.
5. How should objective completion be verified?
   Current recommendation: **bounded acceptance criteria plus explicit
   action results**; model evaluation is advisory only.
6. How much world-model abstraction should be included in v0.23?
   Current recommendation: **none**. No behaviour, no null provider,
   only reserved vocabulary in this rethink doc and the research note.
7. Which stages should be durable in v0.23 versus signal/trace-only?
   Current recommendation: **persist objectives, selected/proposed steps,
   observations, impasses, and status transitions.** Most hook internals
   remain bounded event metadata unless they affect selected steps or
   user-visible state.
8. Should hooks be public plugin APIs in v0.23?
   Current recommendation: **no.** Implement internal hook dispatch and
   provider vocabulary first; expose plugin hook contribution only after
   the objective runtime has one proven Allbert-owned loop and one
   StockSage loop.
9. Should stage ordering be a fixed pipeline or graph?
   Current recommendation: **a fixed conservative state machine in v0.23**
   (the 7-stage version) with graph-like stage events and room for later
   workflow graphs.
10. How does objective workflow memory differ from markdown memory and
    skills?
    Current recommendation: **objective traces may compile into
    workflow-memory candidates after review.** They are not trusted skills
    and not executable until promoted through explicit skill/app/action
    workflows.
11. Should v0.23 include a first inert `ResourceDecisionProvider`
    contract, or only route/capability vocabulary in traces?
    Current recommendation: **vocabulary only**, no provider contract,
    until a simple objective loop proves what the engine actually needs.
12. How should Allbert represent a capability gap that might require code?
    Current recommendation: **acquisition option with status
    `requires_review`**, never automatic code generation or dynamic module
    loading.
13. Should market metaphors become literal auctions between providers?
    Current recommendation: **no for v0.23.** Keep bid-like fields
    (cost, latency, confidence, required permissions, missing resources)
    as explanatory metadata. Do not implement provider competition as
    authority.

Resolved 2026-05-16 (see Decisions Locked In near the top):

14. ~~Alternative A / B / C / D for v0.23.~~ **Resolved: Alternative A.**
    v0.23 = Objective Runtime Foundation; v0.23–v0.29 renumber to
    v0.24–v0.30.

15. ~~Objective engine implementation.~~ **Resolved: Jido.Agent +
    `on_before_cmd`/`on_after_cmd`.** Engine becomes the first non-
    IntentAgent Jido.Agent in the codebase; objective rows in SQLite
    remain authoritative for durable state.

16. ~~Signal vocabulary.~~ **Resolved: coexist.** `allbert.objective.*`
    signals emit alongside existing `allbert.action.*` and
    `allbert.runtime.turn.*`. Trace volume bounded by
    `objectives.trace_detail`.

17. ~~Cancellation semantics.~~ **Resolved: cooperative only.**
    `cancel_objective` transitions to `:cancelled`, blocks new step
    creation, lets in-flight registered actions complete normally. Mid-
    action interruption is a v0.24+ concern.

Still open after the locked decisions:

18. **Should StockSage `RunAnalysis` retroactively gain `objective_id` in
    v0.22, or should that field only appear once v0.23 ships?** Current
    recommendation: do not modify v0.22; thread `objective_id` through
    `RunAnalysis` as part of v0.23 work. v0.22 ships clean.

19. **Should the v0.23 engine ship with one deterministic step proposer
    (just enough to turn intent candidates into objective steps), or
    also include the first LLM-assisted proposer behind a setting?**
    Current recommendation: deterministic only in v0.23. LLM-assisted
    proposer is v0.24 or later, behind explicit Settings Central config,
    redaction, and validation.

20. **Should `mix allbert.objectives` be the CLI namespace, or should
    objective inspection live under existing namespaces (`mix allbert.ask`
    flags, `mix allbert.confirmations` extensions)?** Current
    recommendation: dedicated `mix allbert.objectives` namespace with
    `list`, `show`, `cancel`, `continue` subcommands.

## Research Pointer

A future `docs/research/objective-runtime-research.md` will collect the
full citation list previously embedded in this document, including
primary sources for ReAct, Tree of Thoughts, BDI, Soar, HTN, JEPA family,
diffusion planners, FrugalGPT, RouterBench, RouteLLM, world model
surveys, OpenAI Agents SDK guardrails, LangGraph state and graph
patterns, Jido reference, Hermes Agent (Nous Research), and OpenClaw.
That note is research material; it is not load-bearing for v0.23.
