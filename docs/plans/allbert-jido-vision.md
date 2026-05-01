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
trace defaults, skill scan paths and trust decisions, permission policy,
confirmation behavior, job defaults, channel preferences, and memory review
policy. Settings should be layered so Allbert can explain whether a value came
from built-in defaults, deployment config, operator settings, project settings,
channel settings, or a request override.

### Channels And Jobs

All input and output surfaces should become channel adapters around the same
signal-driven core.

The first channels are CLI/REPL and Phoenix LiveView. Later channels can include
Discord, Telegram, WhatsApp-style chat, email, SMS, browser/search capture, and
native UI surfaces. Each channel should translate external input into signals
and render agent output back into the medium without owning the agent logic.

Scheduled work should follow the same pattern. Cron-like jobs, recurring
summaries, memory maintenance, health checks, and daily briefings should emit
signals into the bus. They should not become a second private runtime.

## Product Shape

The user's experience should feel natural:

- Ask Allbert to do something.
- Allbert understands the intent and picks a skill or capability.
- If the action is sensitive, Allbert explains the permission and asks.
- Allbert runs the work through validated actions.
- The result, cost, trace, and memory impact are recorded.
- If something fails, tracing can be turned on and used for diagnosis.

That loop should work the same whether the user is in the terminal, the web UI,
or a future messaging channel.

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

The system should grow by adding skills, agents, memory, and channels around a
stable core. The user should feel that Allbert is becoming more personal and
more capable without becoming less understandable.
