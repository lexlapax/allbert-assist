# ADR 0083: Objectives Parallel Child Fan-Out

## Status

Proposed (v1.1 planning, 2026-07-18). Binding on the v1.1 M1/M2 build once
Accepted; Accepted only in the commit that lands the child-objective model,
the supervised run executor, and the crash/rehydration proof together.

## Context

The v1.1 flagship ("Asynchronous Background Agent Fan-Out With In-Channel
Steering", `docs/plans/future-features.md` intake 2026-07-18) requires one
prompt to fan out into multiple concurrently executing background tasks that
survive the originating turn, stream status, join, and report back. Nothing in
the shipped runtime can do this:

- **The turn is synchronous.** `Runtime.submit_user_input/1`
  (`apps/allbert_assist/lib/allbert_assist/runtime.ex:115-138`) runs the whole
  agent turn inline (`run_agent_turn/2`, `runtime.ex:508/:517`) under a 120s
  default deadline (`@default_timeout_ms`, `runtime.ex:44`). Channel adapters
  block on it; only the web workspace escapes via LiveView `start_async`
  (`workspace_live.ex:2566`) — and even that wraps the same blocking call.
- **Objectives are strictly sequential.** The engine is ONE serialized
  JidoBacked agent (`objectives/engine/agent.ex`, signal dispatch with
  `timeout: :infinity` at `:160`) advancing a single `current_step_id`
  (`objectives/objective.ex:32`). `parent_objective_id` exists
  (`objective.ex:31`) but is consumed only by plan/build runs
  (`plan_build.ex:42`, `actions/plan_build/start_plan_run.ex:19`), never for
  concurrent child execution.
- **Delegation blocks the chain.** `AgentRegistry.dispatch/4` is a blocking
  `Jido.AgentServer.call/3` (5s default, `objectives/agent_registry.ex:48-60`);
  the `delegate_agent` action caps it at 900s and waits inline
  (`actions/objectives/delegate_agent.ex:43-44,:155-159`). The registry
  monitors `:DOWN` for eviction only (`agent_registry.ex:112-120`) — there is
  no join, no cancellation, no status channel.
- **Workflow YAML deliberately cannot fan out.** ADR 0041 reserves
  `parallel_steps`/`for_each` and v1 ships sequential-only
  (`future-features.md` "Workflow YAML Loops And Parallel Fan-Out"). Routing
  fan-out through workflow vocabulary would force that promotion prematurely
  and put concurrency semantics in operator-authored YAML — the wrong layer.
- **The non-negotiables constrain the shape.** Multi-step, cross-turn work
  must live in `AllbertAssist.Objectives`; apps/plugins/channels/LiveViews may
  not implement private durable goal loops; OTP supervision is not a security
  boundary; state-bearing modules choose Jido.Agent vs GenServer by the
  pragmatic-substrate rule (AGENTS.md Non-Negotiables).

Two architectures were considered: (a) an in-memory task graph owned by a
coordinator process (fast, but a private goal loop — durable state and the
authority trail would live outside Objectives, violating the non-negotiable
and losing crash recovery), and (b) child objectives under the existing
durable substrate with an OTP executor layered on top. Operator locked (b)
on 2026-07-18.

## Decision

1. **A fan-out frames CHILD objectives.** The Stage-0 decomposition of a
   prompt becomes one PARENT objective plus one child objective per task, each
   child carrying `parent_objective_id`, its own steps, its own
   `source_channel`/`source_surface`/`source_thread_id` attribution (copied
   from the parent), and an additive `fanout_role` column
   (`"parent"`/`"child"`/nil) distinguishing fan-out children from plan/build
   parentage. Durable state in Objectives is authoritative; the OTP tree is
   ONLY the executor. No step graph, queue, or result lives solely in process
   state.
2. **Each child runs in a supervised, temporary, Registry-addressed run
   process.** A `DynamicSupervisor` per run scope
   (`Objectives.Runs.Supervisor`) starts one `Objectives.Runs.RunServer` per
   executing child with `restart: :temporary`; every run registers in an
   Elixir `Registry` (`Objectives.Runs.Registry`, unique keys
   `{:run, objective_id}` / `{:fanout, parent_objective_id}`). Runs are plain
   GenServers by the pragmatic-substrate rule (the per-run lifecycle is a
   thin idle→running→cancelling machine; steering arrives as
   Registry-addressed messages; Jido.Agent's signal routing and skill
   composition buy nothing here) — the choice is documented in the
   `@moduledoc`. Run processes execute the existing step pipeline
   (authorize → `Actions.Runner.run/3` → observe → advance) against the
   Objectives API directly; they do NOT dispatch through the serialized
   `Engine.Agent`, which remains the coordinator for interactive
   single-objective flows.
3. **Join = monitors + durable status reduction, never polling.** A
   `Objectives.Runs.Coordinator` (one per active fan-out, also supervised,
   `restart: :temporary`) holds `Process.monitor/1` refs on its runs; child
   terminal status is written to the child objective row first, then reduced
   into the parent (`progress_summary`, join events). The parent reaches a
   terminal status only when every child is terminal
   (`completed`/`failed`/`cancelled`); the join report always enumerates
   per-child outcomes — partial failure never silently degrades to success.
4. **Crash ⇒ rehydrate from Objectives.** A `:DOWN` for a run marks the child
   objective from its last durable step (crash reason recorded as an
   objective event) and the coordinator applies a bounded restart policy (one
   supervised re-start per child per fan-out; a second crash is a terminal
   `failed`). On application restart, boot-time rehydration (extending the
   engine's existing `rebuild_state/1` projection rebuild) restarts
   coordinators for parents whose children are still `running`/`open` within
   the existing rehydrate window; work resumes from the last durable step.
5. **Backpressure is explicit.** `DynamicSupervisor` `max_children` bounds the
   run scope; the coordinator maintains a FIFO queue of not-yet-started
   children and starts at most `objectives.fanout.max_concurrent_runs`
   (Settings Central) at a time; queued children stay durable in status
   `open`. Overflow is visible (queued positions in status output), never an
   unbounded process spray. No GenStage/Flow — the queue is a few dozen
   entries owned by one coordinator, and the demand model would be
   machinery without a consumer.
6. **Decomposition is advisory and grants nothing.** The Stage-0 decomposer
   may use the local model (the `propose_steps` precedent) or a deterministic
   split; its output is ALWAYS surfaced in-channel before runs start. It
   never short-circuits confirmation, permission, or Security Central —
   `objective_id`/`step_id` are never authority (AGENTS.md). Every child step
   executes through registered actions with their unchanged confirmation
   classes; a background-raised `needs_confirmation` parks that run
   (`step.confirmation_id`, `objectives/step.ex:30`) without blocking
   siblings.
7. **A supervised process has no authority by virtue of being supervised.**
   Run processes carry the same runner context/identity rules as inline
   execution; Security Central decisions are identical whether a step runs
   inline or in a run process. Report-back delivery authority is a separate
   concern (ADR 0084), and cancellation semantics are ADR 0085.

## Consequences

- Channels stop owning turn latency for decomposable work: the fan-out turn
  returns an ack quickly and the OTP tree carries the work. The
  `streaming: "turn_complete"` parity contract hardcoded at
  `channels/channel_parity.ex:98` must be renegotiated per channel (v1.1 M5).
- Objectives gains a second execution mode; the serialized engine agent stays
  authoritative for interactive continue/advance, so existing single-objective
  behavior is unchanged (proved by the objectives suites and `release.v1`).
- The additive schema change (`fanout_role`, `join_policy`, index on
  `parent_objective_id`) stays inside the additive-migration envelope; the
  1.5-horizon migration-runner cluster is not pulled forward.
- SQLite write serialization becomes a shared resource across concurrent
  runs; run processes write through the same Repo pool and the step cadence
  (model + action latency dominated) keeps contention negligible — measured
  at M2 acceptance via the test-metrics store.
- Delegate-agent dispatch (`AgentRegistry`) is unchanged for existing
  consumers; a run process may still use `:delegate_agent` steps, and that
  call blocks only its own run.
- A permanent structural tax: new objective-executing code must decide
  whether it belongs to the interactive engine path or the run-executor path,
  and both must keep durable state authoritative.

## Validation

- v1.1 M1: additive migration round-trip; child-set framing, join reduction,
  and partial-failure enumeration proven by focused objectives suites;
  existing objectives suites green unchanged.
- v1.1 M2: supervised executor proofs — concurrent runs make independent
  progress (no serialization through the engine agent); kill -9 of a run
  process yields the bounded-restart path and a correct join; BEAM restart
  mid-fan-out rehydrates and completes; `max_concurrent_runs` backpressure
  observable (queued children start only as slots free); Registry keys unique
  per run; no polling loop anywhere (signal/monitor driven, asserted via the
  signal taxonomy in `docs/plans/v1.1-request-flow.md`).
- Release: `release.v1` stays green (Tier-1/Tier-2 untouched; runtime
  response gains only additive fields per ADR 0029) and `release.v11` binds
  the fan-out eval rows.
