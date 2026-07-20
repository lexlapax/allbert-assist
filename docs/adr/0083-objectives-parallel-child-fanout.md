# ADR 0083: Objectives Parallel Child Fan-Out

## Status

Proposed (v1.1 planning, 2026-07-18). Binding on the v1.1 M1–M3 build once
Accepted; Accepted only in M3 after the child model, fair scheduler/full
lifecycle executor, crash recovery, and delivery-before-start contract are
proven together.

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

1. **A fan-out frames CHILD objectives.** A decomposition becomes one parent
   plus one child per task. Children copy origin attribution and carry
   `parent_objective_id` plus additive `fanout_role`. Durable fields also
   record delivery state/receipt digest, queue position, run-attempt count,
   review reason, and `join_outcome`. Objectives is authoritative: no queue,
   retry counter, delivery state, or result exists only in process memory.
2. **Kickoff delivery or its protocol-specific durable equivalent precedes
   execution for every Runtime caller.** Framing
   returns the additive kickoff response plus an opaque, identity-bound,
   single-use start receipt and starts no child. Remote chat acknowledges
   after transport success, web/TUI after render/print, non-streaming public
   HTTP protocols after durable server-side kickoff recording, SSE after the
   kickoff event flushes successfully, CLI after output, and Jobs after a
   durable kickoff event. Acknowledgement is idempotent and
   non-authoritative. Failure leaves
   the fan-out blocked for retry or cancellation. A caller without this
   contract fails closed to the existing single-turn path. OpenAI-compatible
   and ACP requests HOLD until join (plan Locked Decision 17, restored third
   pass 2026-07-18; clarified 2026-07-19): durable kickoff recording
   satisfies the non-streaming start precondition, children run, and the
   response completes with the join report bounded by the request timeout
   (timeout ⇒ ack + receipt, report via `pending_reports`). SSE starts only
   after the kickoff event flushes. Disconnect-before-record/flush never
   starts work; disconnect after durable recording retains the pending
   report. No wire-format change.
3. **Each child runs in a supervised, temporary, Registry-addressed
   process.** One global `Objectives.Runs.Supervisor` DynamicSupervisor starts
   temporary `RunServer` and `Coordinator` GenServers; the unique Registry
   uses `{:run, objective_id}` / `{:fanout, parent_objective_id}`. RunServer
   is a plain GenServer under the pragmatic-substrate rule, documented in its
   `@moduledoc`, and executes propose → evaluate → authorize →
   `Actions.Runner.run/3` → observe → advance directly against Objectives,
   not the serialized Engine.Agent.
4. **Join uses monitors plus durable reduction, never polling.** Each
   Coordinator monitors its runs; terminal child state is durable before
   reduction. Parent status/outcome reduces as: all completed →
   `completed/success`; any completed plus failed or cancelled →
   `completed/partial`; no completed and any failed → `failed/failed`; all
   cancelled → `cancelled/cancelled`. Reports always enumerate every child.
5. **Crash recovery never guesses about effects.** The Coordinator applies
   one restart per child from the persisted attempt count. A second crash is
   terminal failed. Boot rehydration reconstructs coordinators within the
   existing window. Registered actions declare optional
   `retry_safety: :safe | :unsafe | :unknown`, default `:unknown`; only
   `:safe` auto-resumes. M2 sweeps the shipped action catalog so read-only/
   idempotent actions carry `:safe` from day one — auto-resume must be real,
   not vacuously absent. A possibly committed external effect with
   no durable observation becomes `blocked`/`uncertain_effect`; explicit
   retry or skip is required.
6. **Backpressure is fair and reconstructible.** A permanent supervised
   `Objectives.Runs.Scheduler` grants capacity round-robin across fan-outs,
   preserves durable FIFO within each, monitors/restarts temporary
   Coordinators, and reconstructs from Objectives. DynamicSupervisor
   `max_children` bounds the global executor; each fan-out starts at most
   `objectives.fanout.max_concurrent_runs`. Queued children remain durable
   `open`, with visible positions. No GenStage/Flow.
7. **Decomposition is broad, advisory, and grants nothing.** Stage 0 may fan
   out any prompt judged to contain at least two independent tasks; explicit
   parallel language is unnecessary. Single-task, uncertain, unsupported,
   and nested proposals use the existing single-turn path. A proposal above
   `max_children` clarifies before framing and never drops/merges tasks. Output is
   delivered or durably recorded before execution and never bypasses action
   confirmation, permission, or Security Central. A background confirmation
   parks only that child.
8. **A supervised process has no authority by virtue of supervision.** Run
   processes carry the inline runner's context/identity rules. Report-back
   authority remains ADR 0084 and cancellation semantics remain ADR 0085.

## Consequences

- Channels stop owning turn latency for decomposable work: the fan-out turn
  returns an ack quickly and the OTP tree carries the work. The
  `streaming: "turn_complete"` parity contract hardcoded at
  `channels/channel_parity.ex:98` must be renegotiated per channel (v1.1 M5).
- Objectives gains a second execution mode; the serialized engine agent stays
  authoritative for interactive continue/advance, so existing single-objective
  behavior is unchanged (proved by the objectives suites and `release.v1`).
- The additive schema change (`fanout_role`, `join_policy`, `join_outcome`,
  delivery/queue/attempt/review fields, index on `parent_objective_id`) stays
  inside the additive-migration envelope; the
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
  delivery/queue/attempt reconstruction, and every join-outcome reduction
  proven by focused objectives suites;
  existing objectives suites green unchanged.
- v1.1 M2: full-lifecycle/fair-scheduler proofs — concurrent runs make independent
  progress (no serialization through the engine agent); forced
  `Process.exit(pid, :kill)` of a run
  process yields the bounded-restart path and a correct join; BEAM restart
  mid-fan-out rehydrates and completes; `max_concurrent_runs` backpressure
  observable; round-robin across fan-outs and FIFO within each; Scheduler and
  Coordinator crash reconstruction; Registry keys unique per run; no polling loop anywhere (signal/monitor driven, asserted via the
  signal taxonomy in `docs/plans/v1.1-request-flow.md`).
- v1.1 M3: every Runtime caller proves no execution before acknowledgement;
  duplicate acknowledgement is idempotent; delivery failure remains blocked;
  retry/status reuses the receipt after uncertainty; overflow clarifies with
  no task loss; OpenAI/ACP hold-until-join proves report-in-band with the
  timeout fallback to ack + `pending_reports`; an uncertain
  external effect never auto-replays. ADR flips Accepted here.
- Release: `release.v1` stays green (Tier-1/Tier-2 untouched; runtime
  response gains only additive fields per ADR 0029) and `release.v11` binds
  the fan-out eval rows.
