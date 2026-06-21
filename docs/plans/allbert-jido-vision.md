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

> **Stability note.** This is the timeless vision and guiding principles — the
> north star. It carries no version scope or release sequence; that lives in
> `docs/plans/roadmap.md`. Treat this document as stable: do not edit it during
> normal version work. Change it only during deliberate vision-level planning
> that revises a principle or adds durable scope (as the 2026-06-21 replan did
> when it added the Pi-mode coding surface direction).

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

Jido is treated as the first real substrate rather than an experiment bolted
onto the side. Exact dependency pins live in `mix.exs`, and the current release
state lives in `docs/plans/roadmap.md`; this document tracks neither.

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
  financial specialist agents become the operational engine. The Python
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

Minimalism is a property of the inner loop and tool surface; structure is a
property of the authority spine. The two are not in tension: run a minimal inner
loop — a small system prompt, a few default tools, lazy disclosure of the rest —
on a structured runtime where every side effect still resolves through a
validated action. Hold a standing minimalism budget against accretion: for each
new capability, ask whether it belongs in the kernel or behind a
contract/plugin/skill.

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

Jido-agent components share `AllbertAssist.JidoBacked`, a small substrate
that standardizes AgentServer child specs, private command routing, restart
rehydration, and the optional `allbert.jido.debug_trace` diagnostic gate.

The pragmatic rule for new state-bearing modules:

- Use `Jido.Agent` when one or more is plausibly useful: a state machine
  with named transitions, documented lifecycle hooks such as
  `on_before_cmd/2` and `on_after_cmd/3`, Skill composition, or a successor
  agent with better algorithms later.
- Use plain `GenServer` when the module is stateful storage and the test
  "can you imagine a useful v2 with better algorithms?" answers no.

Concretely, IntentAgent, Confirmations.Store, Jobs.Scheduler,
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
  (ADR 0019). Intent never grants authority. The selector deepens into a
  local-first **two-stage intent router** (embedding prefilter → constrained
  LLM disambiguation → confidence gate; ADR 0060/0061): a better *selector*
  within the same registry-validated candidate set that reaches the existing
  approval gate (it removes the app-handoff channel dead-end) — while the
  authority model is unchanged (selection is advisory; the runner, permission,
  and `confirmation`/`ConfirmationCallback` gates remain the only authority
  boundary).
- **Objective** captures what Allbert is trying to accomplish *across one or
  more steps, confirmations, channels, jobs, and turns*. Objectives are
  durable SQLite rows (`objectives`, `objective_steps`, `objective_events`)
  with acceptance criteria, constraints, status, and links to traces.
  `AllbertAssist.Objectives.Engine` is a
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
expected outputs. Supervised skill creation is deterministic through vetted
templates, and discovery follows a reviewed marketplace-lite model. A safe
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

Active Memory is the safe precursor for this direction:
deterministic direct-answer retrieval over reviewed `:kept` memory, scoped by
thread, active app, and identity namespace. It is not nightly training,
personality distillation, or a generated system model. Small-model retraining
and learned system-memory distillation remain research until memory
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

The first channels are CLI/REPL and Phoenix LiveView. The first additional
remote channels are Telegram (Bot API long polling, inline buttons)
and email (IMAP polling, SMTP replies, typed-command confirmations). Both
adapters share the same channel substrate, identity mapping posture, durable
event dedupe model, and Approval Handoff rendering contract. Telegram and email
ship as source-tree channel plugins so later channels can arrive through the
same extension path. Discord, Slack, WhatsApp, Signal, and Matrix extend that
path, along with the custody, daemon, trust-class, signed-webhook, and
phone-redaction constructs those channels force. Channel adapters are validated
against real providers, not just stubs — stub-green is not provider-green, so
every channel reaches real-provider parity rather than relying on stub tests.
SMS, iMessage, native packaged UI, hosted channel fan-out, and
other broad distribution paths remain parked until after the channel packs
prove the substrate. Each channel should translate external input into signals
and render agent output back into the medium without owning the agent logic.

Scheduled work should follow the same pattern. Cron-like jobs, recurring
summaries, memory maintenance, health checks, and daily briefings should emit
signals into the bus. They should not become a second private runtime.

### Agentic Workspace Surface

The Phoenix `/agent` surface is a signal-driven operator workspace rather than a
prompt box. LiveView renders runtime state, approval
handoffs, traces, memory review, jobs, canvas tiles, and ephemeral surfaces
without owning agent logic, security policy, execution, or memory semantics.

Canvas is the persistent work surface for artifacts, traces, approvals, memory
review, and active tasks. Ephemeral UI is the task-scoped surface Allbert can
open when text is too thin: a validated, declarative interface generated from
runtime state and discarded when it is no longer useful. The substrate provides
a per-thread canvas/ephemeral surface, signed Fragment emission, offline
text/markdown editing, and internal AG-UI semantic mappings.

The boundary is important. Allbert should prefer declarative surface data,
known component catalogs, provenance, redaction, fallback text, and registered
action bindings over arbitrary model-generated UI code.

The app/surface contract exists so the workspace shell does not invent app
discovery or arbitrary node shapes. `AllbertAssist.App.Registry` provides app
navigation and lookup. `AllbertAssist.Surface` defines validated component
nodes. `AllbertAssist.App.SurfaceProvider` lets apps produce task surfaces as
signals or registered action results. Allbert exposes public protocol surfaces:
an MCP server mode, an OpenAI-compatible API, and an ACP server mode.
Public AG-UI/A2UI bridge exposure and MCP Apps iframe compatibility remain
parked; Allbert's primary stance is still declarative, catalog-bound
surfaces over arbitrary remote UI code.

StockSage LiveViews start as standard app surfaces. Real StockSage renderers
live in StockSage-owned `/stocksage/...` surfaces. Once the core canvas
substrate has been audited, those same proven components emit into durable
`/agent` canvas tiles without changing the StockSage domain model. With the
runtime/UI substrate consolidated, operator navigation collapses into
`/workspace`, where StockSage dashboards, queues, trends, and Settings Central
render as host-composed panels instead of separate app shells.

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
- Native agents: reusable financial specialist agents under the
  objective/delegate-agent contract. They adapt the Python baseline's role
  intent, result fields, and fixtures, but they are designed as Elixir/OTP/Jido
  agents callable by the wider Allbert runtime, not as a one-for-one
  TradingAgents class graph. LLM-capable Jido.AI specialist
  packets run through the plugin-owned coordinator graph, record each specialist
  turn as an objective step, and keep Python only as explicit
  comparison/parity reference. Deterministic advisory mode remains available
  for tests/operator smoke when native LLM generation is explicitly disabled.
- Web surfaces: workspace, analysis, queue, and trends
  LiveViews mount through the app contract, setting `active_app: :stocksage`
  when the user is in StockSage context. Dashboard/list/queue/trend
  workflows move into `/workspace` panels, reserving `/apps/stocksage/...` only
  for page-shaped detail flows that genuinely need a route.
- Memory namespace: StockSage declares its namespace so ownership can be audited
  before explicit lesson/reflection sync is added.
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

A gated coding surface is part of this shape, not an exception to it: a terminal
coding loop can feel as direct as a single-user dev tool while still running
every read/write/edit/bash through the same validated action boundary, trace,
and memory. The minimal inner loop is welcome; the authority boundary stays.

## Release Sequence

The version-by-version release sequence is **not** maintained here. It lives in
`docs/plans/roadmap.md`, the single source of truth for what ships when. This
document stays version-agnostic on purpose (see the stability note at the top).

## Explicit Non-Goals (Durable)

These stay out of scope by design, independent of any version:

- Nightly small-model training, personality distillation, learned system
  memory, or any generated model that becomes hidden runtime authority.
- Fully autonomous skill creation, auto-enable, auto-publish, or broad
  execution permissions derived from traces.
- Unsupervised self-recompilation, compiler-loop bootstrapping, or runtime
  mutation that bypasses the supervised sandbox/gate/template review path.
- Complex distributed multi-node operation, hosted multi-user authorization,
  broad remote sync, or cluster behavior beyond explicit local API/protocol
  surfaces.
- YOLO-by-default execution, or any coding/agent surface that weakens the action
  boundary, Security Central, or confirmations. A minimal inner loop is welcome;
  an absent authority boundary is not, and the model never decides it is "done"
  for effectful or generated-code work — deterministic acceptance rules.

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
