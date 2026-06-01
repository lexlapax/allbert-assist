# Allbert Jido Vision

Allbert is a personal assistant runtime that grows with its user. It should not be
just a chatbot with tools attached. It should listen, remember, route intent,
invoke capabilities safely, learn from traces, and become more useful as its
relationship with the user deepens.

This document translates the origin note from April 30, 2026 into an
Elixir/OTP and Jido-centered direction. The core idea is still a small kernel,
but in Elixir that kernel should be a supervised runtime: processes with clear
responsibilities, explicit messages, durable state, observable failures, and
restartable components.

## Current Grounding

The project is already shaped as a Phoenix umbrella with the runtime in
`allbert_assist` and the web surface in `allbert_assist_web`. The application
starts `AllbertAssist.Jido`, a `Jido.Signal.Bus`, Phoenix PubSub, and the repo
under OTP supervision. `AllbertAssist.Agents.IntentAgent` is a lightweight
`Jido.Agent`-compatible deterministic router over the registered Allbert action
surface, while dedicated runtime coordinators use `Jido.Agent` through the
shared `AllbertAssist.JidoBacked` substrate. Model aliases remain in config so
future AI-backed agent code can speak in terms like `:fast`, `:capable`, and
`:thinking` instead of hard-coding provider model names.

The Jido versions in this foundation are:

- `jido 2.2.0`
- `jido_action 2.2.1`
- `jido_signal 2.1.1`
- `jido_ai 2.1.0`

That is enough to treat Jido as the first real substrate rather than as an
experiment bolted onto the side.

## Workspace Direction

Allbert is becoming a personal AI workspace, not just a single assistant
surface. The workspace is the operating environment: Allbert owns identity,
memory, settings, security, signals, agents, actions, app registration, and
operator surfaces. Domain apps plug into that environment through public
contracts rather than private hooks.

StockSage is the first proving app. It enters through `./plugins/stocksage`
and normal umbrella applications, registers actions and skill paths through
Allbert, stores local-first domain records, and eventually contributes
LiveViews and canvas components through the app/surface contract.

The workspace path carries several grounding decisions:

- SQLite remains the default local data store for Allbert and StockSage.
  PostgreSQL, hosted auth, and role/account models are deferred until there is
  a real hosted deployment need.
- Background work should prefer OTP/Jido supervisors, SQLite-backed queues,
  and supervised workers before adding Oban or another scheduler dependency to
  the local path.
- `user_id` is a stable local string, defaulting to `"local"`, not a foreign
  key to an accounts table. Existing `operator_id` is a compatibility alias.
- Conversation history is SQLite-backed `Thread` and `Message` data; markdown
  memory remains the durable, operator-edited source of truth.
- Session scratchpad state is volatile ETS data keyed by `{user_id,
  session_id}`. It may carry `active_app`, but it is not durable memory and not
  a security boundary.
- Python StockSage and TradingAgents remain the behavioral baseline at first.
  A supervised bridge gets useful analysis into Allbert early; native
  financial specialist agents become the v0.25 operational engine. The Python
  bridge then remains only as an explicitly requested comparison/reference
  harness, never a persistent default or automatic fallback. Those agents are
  reusable delegate agents, not a one-for-one Python graph translation.
- The older Rust Allbert experiment is prior art for identity, sessions,
  daemon jobs, memory, and retrieval. It is not an active sibling runtime for
  this roadmap.

## Design Posture

Allbert should think in the Elixir way:

- Keep the core small and explicit.
- Model durable responsibilities as supervised processes.
- Let channels, jobs, sensors, and agents communicate with messages.
- Put side effects behind named, validated actions.
- Prefer observable failure and recovery over defensive sprawl.
- Keep user-owned knowledge readable, portable, and inspectable.

The user should interact with Allbert naturally through text and, later, other
media. The user should not have to program the system to improve it. Skills,
memory, prompts, preferences, and traces can be stored as markdown and config,
but the runtime should compile and index those materials into faster operational
forms.

## Jido Vocabulary

Jido gives Allbert a clean architecture language:

- `Jido.Agent` and `Jido.AI.Agent` define bounded agents with state,
  instructions, tools, and signal routes. Agents are the decision loops, not the
  place where arbitrary side effects hide.
- `Jido.Action` defines executable capabilities with schemas, validation,
  descriptions, structured results, and AI tool conversion. Actions are the
  boundary between intent and side effect.
- `Jido.Signal` gives Allbert a CloudEvents-style event language. Channels,
  jobs, sensors, tools, and agents should emit and consume signals rather than
  coupling directly to each other.
- `Jido.Signal.Bus` and Jido's OTP runtime pieces let the system stay eventful,
  supervised, and observable as it grows.

In practice, this means the assistant loop should not be "LLM receives text and
runs whatever it wants." It should be "input becomes a signal, intent is routed
through an agent, capabilities are selected as actions, permissions are checked,
results and traces are recorded, and follow-up signals continue the loop."

### Jido.Agent vs. GenServer: When To Reach For Each

The components above are guidance about *what* belongs where. The question
of *how* a state-bearing module is implemented — `Jido.Agent` vs. plain
`GenServer` — is a pragmatic per-component decision.

Through v0.22, only `AllbertAssist.Agents.IntentAgent` was a `Jido.Agent`,
and no module used `on_before_cmd`/`on_after_cmd` lifecycle hooks. Most
state-bearing modules (Settings, Confirmations.Store, Memory, Sessions,
Jobs.Scheduler, Trace) were plain `GenServer` modules. v0.23 Jido
State-Machine Convergence converts `Confirmations.Store` and
`Jobs.Scheduler` to `Jido.Agent` because both are state-machine
components with plausible successor-agent stories. v0.24 adds
`AllbertAssist.Objectives.Engine` as the next Jido.Agent.
The v0.23 conversions share `AllbertAssist.JidoBacked`, a small substrate
that standardizes AgentServer child specs, private command routing, restart
rehydration, and the optional `allbert.jido.debug_trace` diagnostic gate.

The pragmatic rule for new state-bearing modules:

- Use `Jido.Agent` when one or more is plausibly useful: a state machine
  with named transitions, documented lifecycle hooks such as
  `on_before_cmd/2` and `on_after_cmd/3`, Skill composition, or a successor
  agent with better algorithms later.
- Use plain `GenServer` when the module is stateful storage and the test
  "can you imagine a useful v2 with better algorithms?" answers no.

Concretely after v0.24: IntentAgent, Confirmations.Store, Jobs.Scheduler,
and Objectives.Engine are Jido.Agents. Settings, Trace, Memory storage
IO, Session.Scratchpad, Memory.Compiler, and Memory.Promotion are plain
GenServers. New state-bearing modules document their substrate choice in
the module `@moduledoc` so reviewers can see the reasoning.

Internal `Jido.Action` modules used as commands inside a Jido-backed state
machine are private implementation details. They are not registered Allbert
capability actions, not intent candidates, and not permission grants. The
capability boundary remains `AllbertAssist.Actions.Runner.run/3` plus
Security Central and confirmations.

## Subsystem Vision

### Kernel

The kernel is the supervised Allbert runtime. It owns the Jido instance, signal
bus, registries, task pools, memory services, security gate, and scheduled work.
It should remain small enough to reason about and strong enough to restart parts
of the system independently.

The kernel is not an all-knowing module. It is the place where lifecycle,
supervision, routing, permissions, and durability meet.

### Agents

Allbert should start with one primary intent agent. Its job is to understand the
user's request, choose the right skill or action, decide when to ask for
confirmation, and hand work to specialist agents when useful.

Specialist agents should be narrow and purposeful: coding, memory curation,
research, scheduling, operator-supervised skill drafting, diagnostics, and
later channel-specific assistants. Background agents can respond to scheduled
signals, summarize traces, prune memory, and prepare daily context.

The important rule is that agents coordinate and decide. They do not become
unbounded bags of side effects.

### Intent, Objectives, And World Models

Allbert separates three layers of state across the runtime:

- **Intent** captures what the user appears to mean *now*. It is per-turn,
  inert (`AllbertAssist.Intent.Decision`), and proposal-shaped. Intent
  ranking through `Intent.Engine` is candidate-ranking infrastructure
  (ADR 0019). Intent never grants authority.
- **Objective** captures what Allbert is trying to accomplish *across one or
  more steps, confirmations, channels, jobs, and turns*. Objectives are
  durable SQLite rows (`objectives`, `objective_steps`, `objective_events`)
  with acceptance criteria, constraints, status, and links to traces.
  `AllbertAssist.Objectives.Engine` (introduced in v0.24) is a
  `Jido.Agent` that implements a seven-stage state machine for receiving
  input, interpreting intent, framing/resuming objectives, proposing and
  evaluating steps, authorizing the selected step, executing, and
  observing/advancing. Objectives never grant authority either; ADR 0021
  records the binding rules.
- **Action** captures the executable capability. `Actions.Runner.run/3` +
  Security Central + confirmations + resource access posture remain the
  only effectful boundary. Every step that mutates, fetches, sends,
  executes, or contacts external systems grounds here.

Across all three layers, hooks and advisory providers (LLM proposers,
world-model predictors, diffusion proposers, market allocators,
probabilistic critics, agent-behavior simulators) may **propose**, rank,
predict, score, or summarize. They may not **authorize**, execute, mark
simulated state as observed truth, or short-circuit operator confirmation.
A future agent-model provider that predicts the user is likely to approve
a step never replaces the confirmation; "the user usually says yes" is
not equivalent to the user saying yes this time.

World models, when they arrive, are advisory providers — not the
architecture and not the umbrella for all future intelligence. ADR 0021
reserves vocabulary for `WorldModelProvider`, `DiffusionProposalProvider`,
`MarketAllocatorProvider`, `ProbabilisticInferenceProvider`,
`CriticEvaluatorProvider`, `ResourceDecisionProvider`,
`CapabilityProvider`, `RouteProvider`, and `IntentProvider` without
implementing any of them. The first behaviour extraction waits until at
least two providers of the same role exist. The research summary lives
in `docs/research/objective-runtime-research.md`.

### Actions And Skills

Actions are the executable capability layer. Shell commands, file reads,
website serving, memory writes, search, notifications, and integration calls
should each become named `Jido.Action` modules with schemas, descriptions,
permission metadata, structured results, and observable errors.

Skills are the user-readable bundles around those capabilities. A skill can
declare its purpose, prompts, examples, required actions, security posture, and
expected outputs. v0.38 makes supervised creation deterministic through vetted
templates, and v0.45 plans reviewed marketplace-lite discovery. The v0.46 safe
precursor can suggest trace-to-skill drafts when repeated operator patterns
appear, but the drafts remain inert until reviewed, validated, and explicitly
enabled by the operator.

The security gate belongs at this boundary. Before an action mutates files,
runs commands, spends money, contacts outside services, or sends messages,
Allbert should know which skill requested it, which agent selected it, which
permission applies, and what trace will be recorded.

### Plugins

Plugins are the package and discovery layer for developer extensions. A plugin
can contribute a channel adapter, a workspace app, a skill pack, a small set of
actions, settings schema entries, supervised children, or a combination of
those pieces.

Plugins do not replace the lower-level contracts. They feed them. A
plugin-contributed app still implements `AllbertAssist.App`; a
plugin-contributed channel still behaves as a delivery adapter around the
runtime; a plugin-contributed action still executes through the action runner
and Security Central; a plugin-contributed skill still follows skill trust and
enablement policy.

The plugin registry is the contribution index. Channel descriptors are
registered there and consumed by the shared channel substrate; apps and
surfaces still use the app/surface contracts. The registry should not become
an authorization system or a second runtime.

The default local plugin roots are `./plugins` for source-tree
project/developer plugins and `<ALLBERT_HOME>/plugins` for user-owned plugin
folders. Allbert's own Telegram and email channels move into
`./plugins/allbert.telegram` and `./plugins/allbert.email` first so shipped
features use the same package shape as later developer extensions. Code-bearing
source-tree plugins are compiled only by explicit project/release
configuration. Home plugins may contribute manifests and skill roots first,
but Allbert should not compile or load arbitrary code from
`<ALLBERT_HOME>/plugins` at startup.

### Workspace Apps

Apps are first-class workspace participants. An app should be able to declare
identity, validation, child supervision, registered actions, skill paths,
signals, settings, navigation surfaces, and eventually canvas components
without reaching around Allbert's public boundaries.

The minimal app contract registers identity, actions, skills, child specs, and
navigation. The full contract adds signal subscriptions, settings/schema
validation, memory namespace declaration, `AllbertAssist.App.SurfaceProvider`,
and the native `AllbertAssist.Surface` DSL. Namespace-consuming memory writes
remain explicit app actions. App registration never grants permission:
registered actions still run through the action runner, Security Central,
confirmation workflow, traces, and audits.

`active_app` is session context, not magic global routing. When the user is in
StockSage, `active_app: :stocksage` lets intent ranking prioritize StockSage
actions and skill paths. Neutral Allbert context should not route into app
actions without explicit session evidence.

### Memory

Memory should be markdown-first and runtime-compiled.

The source of truth should remain inspectable files: notes, preferences, traces,
skill records, summaries, durable priorities, and personality/context material.
Those files give Allbert posterity and transferability. A future Allbert should
be able to move machines by carrying its memory folder, not by depending on an
opaque database alone.

For runtime speed, the system should compile and index memory into queryable
forms: embeddings, summaries, topic maps, recency windows, and agent-specific
context packs. Memory pruning should be deliberate: preserve the durable record,
compress repetitive traces, and promote stable preferences into higher-signal
files.

v0.39b Active Memory is the implemented safe precursor for this direction:
deterministic direct-answer retrieval over reviewed `:kept` memory, scoped by
thread, active app, and identity namespace. It is not nightly training,
personality distillation, or a generated system model. Small-model retraining
and learned system-memory distillation remain post-v1.0 research until memory
capture, retrieval, review, pruning, deletion, and eval quality are
trustworthy.

Allbert also needs structured conversation history, but it is a different
artifact. SQLite `Thread` and `Message` rows preserve ordered turns,
pagination, app/thread context, user isolation, and trace links. They are not
markdown memory entries, and they are not automatically promoted into durable
memory. Selective promotion, such as extracting a useful lesson from a thread,
should be an explicit confirmed action.

### Allbert Home And Settings

Allbert needs a canonical local home directory and a domain settings engine
separate from Phoenix deployment config.

`ALLBERT_HOME` should be the durable local root for settings, encrypted
secrets, markdown memory, the local database, user skills, imported caches, and
temporary runtime data. If it is not set, Allbert should default to
`~/.allbert`; `ALLBERT_HOME_DIR` can be accepted as an alias. Eventually,
backing up or moving this directory should be the simple mental model for
moving Allbert's local life between machines.

`config.exs` and environment variables should remain responsible for boot-time
application configuration, infrastructure, Allbert Home overrides, and
secret-store master-key bootstrap. User/operator settings and user-supplied
provider credentials should live in an inspectable, validated, auditable
Allbert settings subsystem that can be reached through CLI, LiveView, future
channels, jobs, skills, and actions. API keys should be encrypted at rest and
redacted everywhere they are surfaced.

Settings should cover operator profile, provider profiles, model profiles,
trace defaults, skill scan paths and trust decisions, plugin paths and
enablement, permission policy, confirmation behavior, job defaults, channel
preferences, and memory review policy. Settings should be layered so Allbert
can explain whether a value came from built-in defaults, deployment config,
operator settings, project settings, plugin settings, channel settings, or a
request override.

### Channels And Jobs

All input and output surfaces should become channel adapters around the same
signal-driven core.

The first channels are CLI/REPL and Phoenix LiveView. v0.16 proves the first
additional remote channels with Telegram (Bot API long polling, inline buttons)
and email (IMAP polling, SMTP replies, typed-command confirmations). Both
adapters share the same channel substrate, identity mapping posture, durable
event dedupe model, and Approval Handoff rendering contract. v0.17 moves
Telegram and email into shipped source-tree channel plugins so later channels
can arrive through the same extension path. The v1.0 arc now makes that path
concrete after the capability-first arc: Discord and Slack land in v0.49;
WhatsApp, Signal, and Matrix land in v0.50. SMS, iMessage, native packaged UI,
hosted channel fan-out, and
other broad distribution paths remain parked until after the channel packs
prove the substrate. Each channel should translate external input into signals
and render agent output back into the medium without owning the agent logic.

Scheduled work should follow the same pattern. Cron-like jobs, recurring
summaries, memory maintenance, health checks, and daily briefings should emit
signals into the bus. They should not become a second private runtime.

### Agentic Workspace Surface

As of v0.26, the Phoenix `/agent` surface has evolved from a prompt box into a
signal-driven operator workspace. LiveView renders runtime state, approval
handoffs, traces, memory review, jobs, canvas tiles, and ephemeral surfaces
without owning agent logic, security policy, execution, or memory semantics.

Canvas is the persistent work surface for artifacts, traces, approvals, memory
review, and active tasks. Ephemeral UI is the task-scoped surface Allbert can
open when text is too thin: a validated, declarative interface generated from
runtime state and discarded when it is no longer useful. v0.26 ships the
per-thread canvas/ephemeral substrate, signed Fragment emission, offline
text/markdown editing, and internal AG-UI semantic mappings.

The boundary is important. Allbert should prefer declarative surface data,
known component catalogs, provenance, redaction, fallback text, and registered
action bindings over arbitrary model-generated UI code.

The app/surface contract exists so the workspace shell does not invent app
discovery or arbitrary node shapes. `AllbertAssist.App.Registry` provides app
navigation and lookup. `AllbertAssist.Surface` defines validated component
nodes. `AllbertAssist.App.SurfaceProvider` lets apps produce task surfaces as
signals or registered action results. After the v0.41 insertion, only MCP server
mode remains in the 1.0 arc as v0.50b; OpenAI-compatible API, ACP server mode,
and public AG-UI/A2UI bridge remain parked post-1.0. MCP Apps iframe
compatibility remains parked; Allbert's primary stance is still declarative,
catalog-bound surfaces over arbitrary remote UI code.

StockSage LiveViews start as standard app surfaces. v0.27 proves real
StockSage renderers in StockSage-owned `/stocksage/...` surfaces. After the
core canvas substrate has been audited, v0.30 can emit those same proven
components into durable `/agent` canvas tiles without changing the StockSage
domain model. v0.31 consolidates the runtime/UI substrate first, then v0.32
collapses operator navigation into `/workspace`, where StockSage dashboards,
queues, trends, and Settings Central render as host-composed panels instead of
separate app shells.

### StockSage

StockSage proves Allbert's app model with a concrete financial-analysis
workflow:

- Plugin/app package: `./plugins/stocksage` contributes `StockSage.Plugin`,
  `StockSage.App`, skill roots, local actions, and app metadata through the
  same plugin/app contracts used by other extensions.
- Domain storage: analyses, analysis details, outcomes, queue entries, queue
  runs, and memory entries with string `user_id` and optional thread/request
  context. These use the existing local Allbert SQLite repo with `stocksage_*`
  tables unless a later hosted milestone changes the data boundary.
- Skill pack: local `SKILL.md` files for running analysis, fetching trends,
  and queueing analysis through registered Jido actions.
- Python bridge: a supervised Port or equivalent JSON boundary around the
  existing TradingAgents baseline.
- Native agents: reusable financial specialist agents under the v0.24
  objective/delegate-agent contract. They adapt the Python baseline's role
  intent, result fields, and fixtures, but they are designed as Elixir/OTP/Jido
  agents callable by the wider Allbert runtime, not as a one-for-one
  TradingAgents class graph. v0.25 ships LLM-capable Jido.AI specialist
  packets through the plugin-owned coordinator graph, records each specialist
  turn as an objective step, and keeps Python only as explicit
  comparison/parity reference. Deterministic advisory mode remains available
  for tests/operator smoke when native LLM generation is explicitly disabled.
- Web surfaces: v0.27 starts with workspace, analysis, queue, and trends
  LiveViews mounted through the app contract, setting `active_app: :stocksage`
  when the user is in StockSage context. v0.32 moves dashboard/list/queue/trend
  workflows into `/workspace` panels and reserves `/apps/stocksage/...` only
  for page-shaped detail flows that genuinely need a route.
- Memory namespace: v0.27 declares the StockSage namespace so v0.28 can audit
  ownership before v0.29 adds explicit lesson/reflection sync.
- Canvas integration: chart and analysis tiles only after the Allbert canvas
  substrate, StockSage renderers, and security posture are proven.

Financial workflows are security-sensitive. Market-data API calls must flow
through Resource Access Security Posture and confirmations; a remembered grant
for a general external service must not automatically authorize financial
analysis calls.

## Product Shape

The user's experience should feel natural:

- Ask Allbert to do something.
- When text is too thin, Allbert can open the right workspace surface.
- Allbert understands the intent and picks a skill or capability.
- If the action is sensitive, Allbert explains the permission and asks.
- Allbert runs the work through validated actions.
- The result, cost, trace, and memory impact are recorded.
- If something fails, tracing can be turned on and used for diagnosis.
- The user can inspect and steer work through declarative, validated surfaces
  instead of trusting opaque generated code.

That loop should work the same whether the user is in the terminal, the web UI,
or a future messaging channel. The v1.0 arc widens what can happen inside that
loop: provider control, MCP tools, tool discovery, everyday integrations,
browser research, Plan/Build review, media resources, more channels,
marketplace-lite discovery, protocol interop, and operator-supervised
self-improvement all arrive over the same authority boundary.

## Unified Release Sequence

The post-v0.10 roadmap uses one v0.xx stream. The older D-track labels are
historical aliases only and remain in old reference notes for continuity.

- v0.11: execution-aware intent, Approval Handoff, and Resource Access
  Security Posture consumers.
- v0.12: local workspace identity and SQLite conversation history.
- v0.13: scheduled jobs.
- v0.14: ETS session scratchpad and `active_app` context.
- v0.15: minimal app registration contract.
- v0.16: Telegram/email channel adapters and channel foundation.
- v0.17: plugin contract and shipped source-tree channel plugins.
- v0.18: app/surface contract and `AllbertAssist.Surface` DSL; the remaining
  memory namespace layer is split so declaration lands in v0.27 and
  namespace-consuming writes land in v0.29. `CoreApp` becomes the first
  `SurfaceProvider` (declaring `/agent` as the built-in chat surface), runtime
  turns default to `active_app: :allbert` when no known app context exists, and
  v0.20 StockSage implements the same app/surface contract from day one as the
  second `SurfaceProvider`.
- v0.19: cross-surface intent enrichment using jobs, channels, existing
  memory/trace metadata, scratchpad, app registry context, plugin provenance,
  and registered surface metadata; v0.21 reviewed-memory retrieval plugs in
  later.
- v0.20: StockSage shipped plugin app and SQLite-first domain.
- v0.21: markdown memory review and retrieval, distinct from conversation
  history.
- v0.22: StockSage Python bridge.
- v0.23: Jido State-Machine Convergence — converts `Confirmations.Store` and
  `Jobs.Scheduler` from plain `GenServer` to `Jido.Agent` so the runtime
  substrate is consistent before the v0.24 objective runtime. Pure
  refactor; codifies the pragmatic substrate rule. Inserted by the
  project-direction rethink (`docs/plans/project-direction-rethink-01.md`).
- v0.24: Objective Runtime Foundation — adds the durable multi-step work
  substrate. `Objectives.Engine` as a `Jido.Agent`;
  `objectives`/`objective_steps`/`objective_events` SQLite tables;
  `objective_id`/`step_id` threaded through confirmations, jobs, and
  StockSage `RunAnalysis`; ADR 0021 records intent / objective / capability /
  advisory provider boundaries. Inserted by the project-direction rethink.
- v0.25: native financial specialist agents, consuming objective state from day
  one through the delegate-agent path; Python bridge remains available only for
  explicit comparison/reference runs and is never automatic fallback. `mix
  allbert.delegate` proves cross-app delegate-agent reuse.
- v0.26: shipped the upgrade of `CoreApp`'s declared `/agent` surface (from
  v0.18) into a signal-driven workspace shell; canvas and ephemeral UI are
  additive. Built after both analysis engines, objective state, memory review,
  and intent enrichment are in place.
- v0.26c: workspace UX closeout for deferred `0.26.1` polish only: tile
  inspector, thread switcher, and multi-tab verification. No new platform
  contract.
- v0.27: App Surface Contract - StockSage LiveViews built on
  `AllbertAssist.App.SurfaceProvider` from day one; real StockSage renderers
  replace v0.26 stubs in `/stocksage/...`; `RunAnalysis` emits validated
  Surface nodes; and StockSage declares its memory namespace for later audit.
- v0.28: security hardening and evals, including cross-user/thread leakage,
  app-scoped routing, objective-scope coverage, Surface DSL/SurfaceProvider
  coverage, namespace ownership, bridge safety, and financial authorization.
- v0.29: App Memory + Outcomes Contract - StockSage polish, outcomes, trends,
  reflections, reruns, and explicit namespace-scoped memory sync.
- v0.30: App Canvas Contract - StockSage canvas integration; proven v0.27
  components become durable `/agent` canvas tiles through audited canvas ops.
- v0.31: Runtime And UI-Substrate Consolidation — action DSL, typed runtime
  responses, shared path/redaction/audit/persistence facades, unified Surface
  catalog and extension registry, and settings fragments. Behavior-preserving;
  it changes substrates before the UI and generation arc.
- v0.32: Workspace-Only App UI And Settings Central — `/workspace` becomes the
  operator home, old operator routes are removed without compatibility
  redirects, apps contribute panels into host-owned zones, StockSage becomes
  panel-based inside the workspace, and Settings Central moves into the
  workspace utility drawer.
- v0.33: Conversational App Intent Handoff And Direct Answer Foundation —
  neutral workspace requests can propose explicit app handoff or ask targeted
  clarification while preserving the rule that app actions never execute
  silently.
- v0.34: Workspace UX Refresh — launcher polish, Canvas destination registry,
  and workspace affordance cleanup make `/workspace` the durable operator
  surface before theming and layout overrides.
- v0.35: User Theming And Layout Overrides — operators retheme and re-layout
  `/workspace` from Allbert Home using token YAML, opt-in sanitized CSS
  snippets, and validated layout data.
- v0.36: Elixir/OTP Sandbox And Gate Runner — Allbert can compile and test
  generated Elixir/OTP drafts in a default-off OS sandbox and return redacted
  reports without loading generated modules into the core node.
- v0.37: Dynamic Code & Config Generation And Live Capability Integration —
  Allbert can generate Elixir/OTP code/config for capability gaps and integrate
  only after the v0.36 gate plus operator confirmation.
- v0.38: Allbert plugin and app generator / templated creation.
- v0.39: First-run onboarding and provider control. Guided setup over
  registered objective + Settings Central, and a provider doctor with explicit
  branches for credentialed-remote and local-endpoint providers.
- v0.39b: Identity slot and Active Memory. Optional inert `identity` memory
  namespace plus deterministic recency-weighted direct-answer retrieval over
  reviewed `:kept` entries scoped to `{thread, active_app, identity}`. Split
  from v0.39 so the algorithm has room to land carefully (see
  `docs/research/active-memory-retrieval.md`).
- v0.40: MCP Client Integration. MCP servers become configured resources and
  tools under Allbert's action, Resource Access, confirmation, trace, and audit
  boundaries.
- v0.41: Developer Velocity And Parallel Test Methodology. The development loop
  catches up with the OTP/concurrency vision: precommit becomes a gate matrix,
  async eligibility is proven by resource ownership, SQLite-backed tests get a
  partition-isolation contract, serial lanes stay explicit instead of
  accidental, and future implementation plans annotate parallel workstreams,
  serial barriers, gate evidence, and rejoin points. No operator-facing
  assistant capability.
- v0.42 (implemented as `0.42.2`): Tool Discovery + MCP-first Integration Pack 1. Allbert gains
  `find_tools`, a capability search that fans out to local tools (actions,
  skills, connected MCP servers) and to internet MCP registries; a discovered
  server connects only through a confirmation-gated consent that shows the exact
  command/URL, captures a live connected-server trust baseline, and an opt-in,
  paused-by-default background scan writes
  suggestions to a passive surface (no unprompted messaging, no auto-connect).
  Calendar, mail, GitHub, and notes/files ship as **MCP-server-configured
  workspace panels**. The notes/files surface also ships as a native reference
  plugin to give plugin authors a starter scaffold; StockSage remains the depth
  reference. Closeout adds submitted effect forms and the deterministic v0.42
  release gate. Native plugins for the other integrations are post-1.0
  follow-on.
- v0.43 (implemented as `0.43.0`): Browser And Web Research. Browser sessions
  are Resource Access resources at `browser://session/<id>`, owned by the `./plugins/allbert.browser/`
  plugin supervisor (core spawns no browser), with operational control through
  the reviewed local Playwright/Chromium bridge. Per-domain remembered grants
  authorize navigation against the navigated URL, not the session URI; the
  six browser operation classes (`:browser_navigate`, `:browser_extract`,
  `:browser_screenshot`, `:browser_interact`, `:browser_form_fill`,
  `:browser_download`) have per-class safety floors; form-fill and download
  default to denied and can only be opted into confirmation. Research,
  extraction, screenshots, the browser results panel, `mix allbert.browser
  research`, the real browser external-smoke lane, and the deterministic
  `release.v043` gate are the v0.43 surface; broader account operation,
  authenticated workflows,
  persistent profiles, multi-tab orchestration, and JS evaluation are
  deferred to v0.43.x or later. Page content is descriptive evidence, never
  authority; nothing auto-promotes to memory.
- v0.44: Plan/Build Mode And Operator Workflow YAML. Plan/Build adds a
  pinnable workspace panel over the v0.24 Objective Runtime, plus
  operator-authored workflow YAML under
  `<ALLBERT_HOME>/workflows/<workflow-id>.yaml` that expands into objective
  steps. The schema is derived at compile time from the action registry +
  step-kind module so docs and runtime cannot drift; expressions use a
  closed function table (no `eval`, no `${secrets.x}`, no `${env.x}`, no
  dynamic action names). The runtime never executes YAML; expansion
  produces step attrs that flow through `Actions.Runner.run/3`, Security
  Central, and confirmations unchanged. Subagent delegation events render
  inline under the parent step. YAML `confirm: true` may only upgrade an
  action's confirmation floor, never downgrade.
- v0.45: Marketplace Lite — data shape + Allbert-author seeds only. Catalog
  schema, install path, provenance/hash/version/rollback metadata, with
  Allbert-author bundles seeding the catalog. Community-submission governance
  is parked. Drafting begins on ADR 0046 for settings schema migration.
- v0.46: Operator-Supervised Self-Improvement. Trace-to-skill, workflow,
  template, and dynamic capability draft suggestions consume v0.45 marketplace
  metadata plus v0.40-v0.44 traces; reviewed memory/workflow draft facades are
  the only new dynamic delegate expansion.
- v0.47: Voice Modality. Voice input/output composes with existing channels as
  audio resources and registered STT/TTS actions. Discord voice is deferred
  until after Discord exists.
- v0.48: Vision And Image Generation. Image and screenshot resources plus
  provider-backed image generation expand workspace media capability.
- v0.49: Channel Pack 1 - Discord And Slack. Team/community chat reach expands
  through the existing channel adapter and plugin contracts; v0.49 also amends
  ADR 0016 to lock the channel approval-primitive contract before mobile
  channels need it.
- v0.50: Channel Pack 2 - WhatsApp, Signal, and Matrix. iMessage parked
  (macOS-only platform constraint).
- v0.50b: MCP Server Mode. Allbert exposes registered actions as MCP tools and
  memory namespaces as MCP resources. Single protocol surface. OpenAI-compatible
  API, ACP server mode, and public AG-UI/A2UI bridge are parked post-1.0.
- v0.51: Hardening, Export/Import, Settings Migration, And Final RC. No new
  user-facing capability; portability, settings schema migration tool per ADR
  0046, security evals including self-improvement and MCP server, and
  release-candidate evidence.
- v1.0: Stability Release And **Tiered Public Contract Freeze**. No new
  features. Tier 1 freezes Runtime, Actions/permissions, Plugin, App, Settings
  Central schema shape, Allbert Home layout, Channel adapter boundary, and
  Resource Access URI/grants. Tier 2 freezes SurfaceProvider, Surface DSL with
  additive-only carve-out, and workspace canvas/ephemeral substrate minus
  single-consumer components. ADR 0021 advisory-provider vocabulary is
  reserved but not frozen.

The v0.39-to-v1.0 arc is capability delivery over the safety substrate already
proven through v0.37 and accelerated by v0.38. The goal is not a rewrite; it is
to make Allbert reachable and useful while preserving the action/security
authority boundary that makes it inspectable.

## Planned Capability Arc And Research Backlog

The origin note names several powerful future directions. They should stay in
view, but they now split into three categories instead of one vague deferred
bucket.

### Graduated Into The v1.0 Arc

- Dynamic capability work now has a supervised spine: v0.36 sandbox/gate
  reports, v0.37 operator-confirmed dynamic code/config integration, and
  v0.38 deterministic templates. This is the safe precursor to the
  self-recompilation idea, not autonomous self-rewriting.
- Active Memory in v0.39b is the safe precursor to system memory: reviewed
  retrieval before replies, not model training or distillation.
- Capability reach lands through planned, authority-bounded surfaces: MCP,
  tool discovery, everyday integrations, browser research, Plan/Build,
  marketplace-lite discovery, self-improvement, voice, vision, channels, and public
  protocol interop. Tool discovery may search internet MCP registries but
  connects a server only through a confirmation-gated consent; discovered
  metadata is never authority.

### Planned v0.46: Operator-Supervised Self-Improvement

Early in the 1.0 capability arc, while operators are first generating rich
trace patterns from MCP, integrations, browser research, Plan/Build, and
marketplace-lite discovery, Allbert adds operator-supervised
draft creation from observed use:

- Trace-to-skill draft suggestions from repeated prompts, repeated action
  chains, failed intents, corrections, or manually marked examples.
- Workflow/intention suggestions that turn common multi-step objective patterns
  into inert workflow YAML or v0.38 template inputs.
- Dynamic capability review loops that connect capability-gap detection to the
  existing v0.36 sandbox, v0.37 gate/loader, and v0.38 templates.
- Reviewed memory promotion/update draft facades and objective/workflow
  draft-write facades. These are draft-only paths, not settings, secrets,
  shell, package, confirmation-decision, trust-control, or live
  workspace/canvas write authority.

These suggestions are advisory only. They do not enable skills, grant
permissions, install packages, compile arbitrary folders, publish plugins, or
load code. Review, validation, sandbox/gate evidence where relevant, and
operator confirmation remain mandatory. The planning home is
`docs/plans/v0.46-plan.md`.

### Still Research / Explicitly Not v1.0

- Nightly small-model training, personality distillation, learned system
  memory, and any generated model that becomes hidden runtime authority.
- Fully autonomous skill creation, auto-enable, auto-publish, or broad
  execution permissions derived from traces.
- Unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation that bypasses the v0.36/v0.37/v0.38 review path.
- Complex distributed multi-node operation, hosted multi-user authorization,
  broad remote sync, or cluster behavior beyond explicit local API/protocol
  surfaces.

## North Star

Allbert should become a compact, personal, inspectable assistant runtime:

- Small kernel.
- Supervised processes.
- Signal-driven coordination.
- Jido agents for intent and delegation.
- Jido actions for safe capability execution.
- Markdown memory for human ownership.
- Compiled runtime views for speed.
- Traceable cost, behavior, and failure.
- Channels that feel natural instead of programmable.
- Canvas and ephemeral UI surfaces that make agent work inspectable,
  steerable, and safe.

The system should grow by adding plugins, skills, agents, memory, apps, and
channels around a stable core. The user should feel that Allbert is becoming
more personal and more capable without becoming less understandable.
