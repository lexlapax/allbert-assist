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
under OTP supervision. There is also a sample `Jido.AI.Agent` wired to a
validated `Jido.Action`, plus model aliases in config so agent code can speak in
terms like `:fast`, `:capable`, and `:thinking` instead of hard-coding provider
model names.

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
  A supervised bridge gets useful analysis into Allbert early; native Jido
  trading agents become default only after parity tests prove they are close
  enough.
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
research, scheduling, skill creation, diagnostics, and later channel-specific
assistants. Background agents can respond to scheduled signals, summarize
traces, prune memory, and prepare daily context.

The important rule is that agents coordinate and decide. They do not become
unbounded bags of side effects.

### Actions And Skills

Actions are the executable capability layer. Shell commands, file reads,
website serving, memory writes, search, notifications, and integration calls
should each become named `Jido.Action` modules with schemas, descriptions,
permission metadata, structured results, and observable errors.

Skills are the user-readable bundles around those capabilities. A skill can
declare its purpose, prompts, examples, required actions, security posture, and
expected outputs. Over time, Allbert should be able to discover skills, suggest
them, and help create new ones when no existing skill fits.

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
validation, memory namespaces, `AllbertAssist.App.SurfaceProvider`, and the
native `AllbertAssist.Surface` DSL. App registration never grants permission:
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

Nightly distillation or small-model retraining can remain a future research
track. First, Allbert needs trustworthy memory capture, retrieval, review, and
pruning.

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
can arrive through the same extension path. Later channels can include Discord,
WhatsApp-style chat, SMS, browser/search capture, and native UI surfaces. Each
channel should translate external input into signals and render agent output
back into the medium without owning the agent logic.

Scheduled work should follow the same pattern. Cron-like jobs, recurring
summaries, memory maintenance, health checks, and daily briefings should emit
signals into the bus. They should not become a second private runtime.

### Agentic Workspace Surface

The Phoenix surface should evolve from a prompt box plus settings page into a
signal-driven operator workspace. LiveView should render runtime state,
approval handoffs, traces, memory review, jobs, and channel context without
owning agent logic, security policy, execution, or memory semantics.

Canvas is the persistent work surface for artifacts, traces, approvals, memory
review, and active tasks. Ephemeral UI is the task-scoped surface Allbert can
open when text is too thin: a validated, declarative interface generated from
runtime state and discarded when it is no longer useful.

The boundary is important. Allbert should prefer declarative surface data,
known component catalogs, provenance, redaction, fallback text, and registered
action bindings over arbitrary model-generated UI code.

The app/surface contract exists so the workspace shell does not invent app
discovery or arbitrary node shapes. `AllbertAssist.App.Registry` provides app
navigation and lookup. `AllbertAssist.Surface` defines validated component
nodes. `AllbertAssist.App.SurfaceProvider` lets apps produce task surfaces as
signals or registered action results. AG-UI, A2UI, MCP Apps, and similar
protocols are research references and future adapters, not hard dependencies
for the first local LiveView substrate.

StockSage LiveViews start as standard app surfaces. After the core canvas
substrate exists, StockSage can register chart and analysis-card components
with the catalog so an analysis result can produce canvas operations without
changing the StockSage domain model.

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
- Native agents: a later Jido analysis topology that matches the Python
  baseline within documented variance before becoming default.
- Web surfaces: workspace, analysis, queue, and trends LiveViews mounted
  through the app contract, setting `active_app: :stocksage` when the user is
  in StockSage context.
- Canvas integration: chart and analysis tiles only after the Allbert canvas
  substrate and full app contract are proven.

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
or a future messaging channel.

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
- v0.18: StockSage plugin, umbrella app, and SQLite-first domain.
- v0.19: markdown memory review and retrieval, distinct from conversation
  history.
- v0.20: StockSage Python bridge.
- v0.21: full app contract and `AllbertAssist.Surface` DSL, before any
  plugin-contributed app web surfaces are built; `AllbertAssist.App.SurfaceProvider`
  available to all apps from this point forward.
- v0.22: cross-surface intent enrichment using jobs, channels, memory,
  scratchpad, app registry context, and registered surface metadata.
- v0.23: native Jido trading agents.
- v0.24: StockSage LiveViews built on `AllbertAssist.App.SurfaceProvider`
  from day one; component catalog declared as the foundation for v0.28 canvas.
- v0.25: security hardening and evals, including cross-user/thread leakage,
  app-scoped routing, Surface DSL/SurfaceProvider coverage, bridge safety, and
  financial authorization.
- v0.26: StockSage polish, outcomes, and trends; completes memory namespace
  registration as the final deferred layer of the v0.21 app contract.
- v0.27: agentic workspace surface and ephemeral UI substrate. This cannot
  start until v0.24 and v0.25 are complete.
- v0.28: StockSage canvas integration.
- v0.29: Allbert plugin and app generator.

## Deferred Until The Foundation Settles

The origin note names several powerful future directions. They should stay in
view, but not lead the first architecture pass:

- Self-recompilation and bootstrapping through compiler workflows.
- Nightly small-model training or personality distillation.
- Fully autonomous skill creation with broad execution permissions.
- Complex distributed multi-node operation.

These ideas become safer once the supervised runtime, signal model, memory
system, actions, permissions, traces, and basic channels are boring and solid.

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
