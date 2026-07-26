# ADR 0083: Objectives Parallel Child Fan-Out

## Status

Accepted (v1.1 M3, 2026-07-22), including the implemented M12.15 atomic terminal
reduction, M12.16 pre-effect start recovery, M12.17 attended-turn isolation,
M12.18 report-acknowledgement isolation, M12.19 serialized SQLite persistence,
and M12.20 fail-closed missing-run recovery amendments. FV-01 passed against
`b74a3405` on 2026-07-26 in one fresh disposable Home: three children
completed, one steer applied exactly once, the parent joined/reported once, and
the same TUI accepted an independent turn. The later static audit found that a
failed uncertain-effect/retry-exhausted write could still be followed by a
second join path that restarted the durable `running` child. M12.20 now routes
boot, worker-down, terminal-persistence, and join recovery through one
retry-safety/attempt policy; transition failures retry persistence without
granting execution, and pending steering settles review-blocked. Focused
Coordinator, steering, TUI, persistence, production-shaped pool-1, lane, and
manifest proofs are green. The expanded `release.v11`, frozen `release.v1`,
pre-push, and authoritative release gates remain barriers at the final clean
pushed SHA. M12.21 additionally makes the attached Web join projection one
idempotent canonical conversation message across joined-signal, missed-signal
next-turn, and remount paths without changing decomposition, scheduling,
steering, or atomic fan-in authority; its focused/static rejoin is green and
bounded WV-01 remains open.

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
   `parent_objective_id` plus additive `fanout_role`. Exact additive columns
   are `fanout_role`, `join_policy`, `join_outcome`,
   `kickoff_delivery_state`, `fanout_start_receipt_digest`,
   `report_delivery_state`, `report_delivery_receipt_digest`,
   `origin_thread_ref_id`, `origin_thread_ref_digest`,
   `origin_receiver_account_ref`, `queue_position`, `run_attempt_count`, and
   `review_reason`. Kickoff states are `pending | blocked | acknowledged |
   cancelled`; report states are `not_ready | pending | delivered`. Receipt
   digests are uniquely indexed when non-null and acknowledgement is a
   compare-and-set transition. The origin digest covers channel + opaque
   receiver-account ref + provider-thread key, never an external user id or
   free-text address. Objectives is authoritative: no queue,
   retry counter, delivery state, or result exists only in process memory.
2. **Kickoff delivery or its protocol-specific durable equivalent precedes
   execution for every Runtime caller.** Framing
   returns the additive kickoff response plus an opaque, identity-bound,
   single-use start receipt and starts no child. Remote chat acknowledges
   after transport success, Web after the exact response marker mounts in the
   browser, TUI after every kickoff line is written, non-streaming public HTTP
   protocols after durable server-side kickoff recording, SSE after the kickoff
   event flushes successfully, CLI after output, and Jobs after a durable
   kickoff event. An absent, stale, or forged Web marker leaves kickoff
   `pending`; a returned TUI output error, exception, exit, or partial write
   records `blocked`. Neither acknowledges the receipt or starts children, and
   both remain retryable or cancellable. Acknowledgement is idempotent and
   non-authoritative. A caller without this
   contract fails closed to the existing single-turn path. OpenAI-compatible
   and ACP requests HOLD until join (plan Locked Decision 17, restored third
   pass 2026-07-18; clarified 2026-07-19): durable kickoff recording
   satisfies the non-streaming start precondition, children run, and the
   response completes with the join report bounded by the request timeout
   (timeout ⇒ kickoff, report retained behind an unconsumed delivery receipt
   in `pending_reports`). SSE starts only
   after the kickoff event flushes. Disconnect-before-record/flush never
   starts work; disconnect after durable recording retains the pending
   report. Public callers await/subscribe through an additive fan-out
   continuation API outside `submit_user_input/1`; OpenAI SSE becomes truly
   chunked, and ACP prompt execution is concurrent with its stdio reader so
   `session/cancel` remains serviceable. No existing request field or terminal
   response shape is removed.
   Pending next-turn reports are non-destructive reads with identity-bound,
   idempotent delivery receipts; transport failure cannot consume a report.
3. **Each child runs in a supervised, temporary, Registry-addressed
   process.** One global `Objectives.Runs.Supervisor` DynamicSupervisor starts
   temporary `RunServer` and `Coordinator` GenServers; the unique Registry
   uses `{:run, objective_id}` / `{:fanout, parent_objective_id}`. RunServer
   is a plain GenServer under the pragmatic-substrate rule, documented in its
   `@moduledoc`, and executes propose → evaluate → authorize →
   `Actions.Runner.run/3` → observe → advance through a new
   `Objectives.Lifecycle` transactional/CAS facade, not the serialized
   Engine.Agent or private Jido command modules. Failure to start a fresh
   RunServer occurs before any child effect: the Coordinator releases the
   scheduler slot and retries with bounded backoff. It does not apply the
   uncertain-effect crash policy reserved for a worker that actually existed
   and may have crossed an effect boundary.
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
   `Objectives.Runs.Scheduler` grants `max_concurrent_runs_global` capacity
   round-robin across fan-outs,
   preserves durable FIFO within each, monitors/restarts temporary
   Coordinators, and reconstructs from Objectives. Each fan-out starts at most
   `max_concurrent_runs_per_fanout`; `max_children_per_fanout` only bounds
   decomposition size. DynamicSupervisor uses a static safety ceiling above
   Scheduler capacity and does not count Coordinators as run slots. Queued children remain durable
   `open`, with visible positions. No GenStage/Flow.
7. **Decomposition is broad, advisory, and grants nothing.** Stage 0 may fan
   out any prompt judged to contain at least two independent tasks; explicit
   parallel language is unnecessary. Single-task, uncertain, unsupported,
   and nested proposals use the existing single-turn path. A proposal above
   `max_children_per_fanout` clarifies before framing and never drops/merges tasks. Output is
   delivered or durably recorded before execution and never bypasses action
   confirmation, permission, or Security Central. A background confirmation
   parks only that child.
8. **A supervised process has no authority by virtue of supervision.** Run
   processes carry the inline runner's context/identity rules. Report-back
   authority remains ADR 0084 and cancellation semantics remain ADR 0085.

### M12.15 amendment — atomic terminal reduction and durable report work

The original Decisions 4 and 6 are refined as follows. This is a correction of
their durability/reconstruction intent, not a new fan-out architecture or
authority class.

1. **A fan-out child terminal transition and its possible parent join share one
   database transaction.** The authoritative transition writes the child's
   terminal state and lifecycle event, reduces all siblings, and, when the set
   is terminal, compare-and-set finalizes the parent with its deterministic
   status/outcome, one `fanout_joined` event, one report receipt, and
   `report_delivery_state=pending`. Whichever child terminalizes last closes
   the parent. A committed all-terminal child set with a `not_ready` parent is
   forbidden for new transitions. Parent compare-and-set is the primary
   idempotency rule. Upgrade-safe insert/update guards prevent every new
   duplicate `fanout_joined` event while preserving append-only evidence in an
   older Home that may already contain duplicates; no migration rewrites that
   history merely to make a unique index fit.
2. **Every production fan-out terminal writer uses that boundary.** Normal
   completion/failure/cooperative cancellation, registered-action cancellation
   after scoped cleanup, retry exhaustion, and stale abandonment cannot update
   fan-out children through an alternate terminal path. Terminal children are
   monotonic and cannot reopen or consume another attempt. Non-fan-out engine
   behavior is unchanged. Approval of a confirmation-blocked fan-out child
   resumes Scheduler/RunServer/Lifecycle rather than executing or terminalizing
   that child through the generic confirmation/interactive Engine path. New
   confirmation records carry objective-binding contract v2 with an internally
   stamped kind: `ordinary`, `objective`, or `fanout_child`. Ordinary records
   lack a complete objective/step pair and do not query Objectives. Objective
   records durably prove that the pair is not a fan-out child before generic
   resumption. Fan-out-child creation requires complete trusted child, step,
   parent, and user context; approval then validates those rows plus the stored
   target action and owner exactly before resolving. The short-lived local
   version-1 transition shape remains readable and retains its complete-pair
   classification. An unversioned record from the pushed first candidate also
   keeps exact complete-provenance classification. An older unversioned record
   without complete provenance may recover through only one durable
   `Step.confirmation_id` link; duplicates fail ambiguous and the confirmation
   remains pending. A target-policy denial runs this same classification before
   resolution: a valid fan-out child resolves denied and wakes its Scheduler so
   Lifecycle can cancel the child and reduce the parent; stale or ambiguous
   records remain pending and cannot wake another run. Binding metadata routes
   validation but is never authority.
3. **Coordinator messages and signals are advisory projections.** They release
   capacity, update attached surfaces quickly, and wake delivery consumers, but
   neither is required for durable join/report truth. A lost `run_terminal`,
   Coordinator exit, or lost `fanout.joined` signal cannot strand a parent or
   discard completion work.
4. **Reconciliation is idempotent and common to live and boot recovery.** It
   returns joined-now, already-joined, or not-terminal distinctly. Permanent
   durable-parent absence retires the Coordinator and frees capacity without
   retry. Only known transient database ownership/connection and message-
   qualified SQLite busy/locked failures receive bounded redacted retry.
   Programming, schema, query, throw, and exit faults remain crash-visible.
   Scheduler recovery selects every
   acknowledged parent whose report state is `not_ready`, including an
   all-terminal/open historical row. Coordinator initialization reconciles the
   parent before scheduling children. Boot and in-process recovery use this
   same predicate and repair historical stranded rows without operator action.
   The canonical `parent_projection` accepts joined truth only when the durable
   delivery marker, deterministic report receipt, join event, and child
   reduction agree; otherwise operators see recovering/finalizing or
   inconsistent state and the runtime wakes repair. Correctness-sensitive
   steering/session-cancellation discovery uses dedicated scoped active-row
   queries, not the human list command's display limit.
5. **The pending parent report is the durable completion outbox.** ADR 0084's
   unique delivery ledger is still reserved before remote transport and remains
   its authority/idempotency boundary. The joined signal is a low-latency
   wakeup; notification-consumer restart, SignalBus-only restart, and
   re-subscription also reconcile pending authorized completion work. A
   pre-send `reserved` completion may resume; an interrupted `sending` delivery
   becomes uncertain and is not retried; a delivered ledger row idempotently
   acknowledges a still-pending parent. Default-OFF rows remain pending for
   next-turn delivery. Successful recovery creates no global startup chatter
   and never duplicates a normal completion report.
6. **Steering and terminalization serialize on durable state.** Directive
   recording re-reads an owned active child in an immediate transaction.
   Non-cancellation terminalization refuses while an unapplied directive
   exists, and Lifecycle rechecks at its final boundary. Either the directive
   commits first and is applied, or terminalization commits first and the steer
   receives a terminal-target result. With several active parents, an ordinal
   target is parent-local and therefore clarifies until the parent/title or an
   exact child is named; read-only status may aggregate every parent.
7. **Scheduler recovery cannot leak capacity or collapse unrelated runtime
   children.** A Registry-proved live
   RunServer is monitored before Coordinator recovery and occupies one
   reconstructed global slot. If it exits or disappears during rehydration,
   that monitor releases the slot; stale process memory cannot permanently
   reduce global fan-out capacity. Boot rehydration reads the complete durable
   parent/child snapshot before installing monitors, so transient mid-snapshot
   failure cannot accumulate duplicate monitors. Live recovery and the entire
   boot path contain transient database unavailability with capped backoff.
   Repeated Coordinator crashes retain capped Scheduler backoff until the
   current Coordinator reports successful reconciliation; they cannot hot-loop
   the top supervisor or take Settings/channel registries down with it.

## Consequences

- Interactive channels stop owning execution latency for decomposable work:
  the fan-out turn returns an ack quickly and the OTP tree carries the work.
  OpenAI/ACP intentionally await through the separate bounded continuation.
  The
  `streaming: "turn_complete"` parity contract hardcoded at
  `channels/channel_parity.ex:98` must be renegotiated per channel (v1.1 M5).
- The raw TUI also cannot put foreground Runtime latency in the Adapter mailbox.
  Its ordinary turns are ordered through one supervised worker/FIFO; this is
  concurrency at the surface boundary, not concurrent Runtime turns within one
  conversation. The Adapter remains the attachment/lifecycle owner, the
  `InputDriver` remains the sole raw-terminal writer, and durable Runtime,
  Objectives, delivery, and receipt contracts stay unchanged.
- Objectives gains a second execution mode; the serialized engine agent stays
  authoritative for interactive continue/advance, so existing single-objective
  behavior is unchanged (proved by the objectives suites and `release.v1`).
- The additive schema change (`fanout_role`, `join_policy`, `join_outcome`,
  kickoff/report receipt, exact-origin, queue/attempt/review fields, indexes
  and unique receipt constraints) stays
  inside the additive-migration envelope; the
  1.5-horizon migration-runner cluster is not pulled forward.
- SQLite write serialization becomes a shared resource across concurrent
  runs. M12.16 operator evidence disproved the earlier claim that ordinary
  step cadence makes contention negligible: all three fresh child-start
  transactions can lose the write boundary at once. A durably open attempt-0
  child proves no effect began, so transient SQLite/DBConnection failure at
  that boundary releases capacity and retries with capped backoff; it is never
  parked as `uncertain_effect`. Post-`run_started` recovery retains Decision 5.
- Delegate-agent dispatch (`AgentRegistry`) is unchanged for existing
  consumers; a run process may still use `:delegate_agent` steps, and that
  call blocks only its own run.
- A permanent structural tax: new objective-executing code must decide
  whether it belongs to the interactive engine path or the run-executor path,
  and both must keep durable state authoritative.

## Validation

- v1.1 M1: additive migration round-trip; child-set framing, join reduction,
  kickoff/report receipt + exact-origin/queue/attempt reconstruction, receipt
  uniqueness, and every join-outcome reduction
  proven by focused objectives suites;
  existing objectives suites green unchanged.
- v1.1 M2: full-lifecycle/fair-scheduler proofs — concurrent runs make independent
  progress through `Objectives.Lifecycle` (no serialization through the engine
  agent or private command modules); forced
  `Process.exit(pid, :kill)` of a run
  process yields the bounded-restart path and a correct join; BEAM restart
  mid-fan-out rehydrates and completes; global/per-fanout run limits remain
  independent from decomposition size; round-robin across fan-outs and FIFO
  within each; Scheduler and
  Coordinator crash reconstruction; Registry keys unique per run; no polling loop anywhere (signal/monitor driven, asserted via the
  signal taxonomy in `docs/plans/v1.1-request-flow.md`).
- v1.1 M3: every Runtime caller proves no execution before acknowledgement;
  duplicate acknowledgement is idempotent; delivery failure remains blocked;
  retry/status reuses the receipt after uncertainty; overflow clarifies with
  no task loss; OpenAI/ACP continuation-based hold-until-join proves
  report-in-band, true SSE + cancellable ACP prompt handling, and timeout
  fallback to kickoff + unconsumed report receipt; failed next-turn transport
  retains the report; exact-origin cross-account denial; an uncertain
  external effect never auto-replays. ADR flips Accepted here.
- v1.1 M12.15 focused: concurrent last-child transitions produce one parent
  join/outbox; every terminal source converges on the boundary; terminal versus
  steering races have no orphaned directive; live/boot historical repair,
  Scheduler slot monitoring, control-query depth, multi-parent ambiguity,
  cancellation truth, canonical CLI/ACP/TUI/web projections, and attended
  exact-receipt ACK behavior are green. The derived `release.v11` inventory is
  expanded to retain these core, channel/TUI, and web/OpenAI suites. The final
  five-file confirmation/fan-out/Plan-Build matrix passes 77 / 0, including
  unversioned compatibility and policy-denial recovery; its affected
  four-partition `app_env_serial` lane passes 665 / 0. The lifecycle correction
  additionally proves missing-parent retirement, transient DB/SQLite recovery,
  programming-error visibility, single-monitor snapshot retry, persistent-crash
  backoff, and ACP/OpenAI quiescence: core/ACP 46 / 0, OpenAI 10 / 0 at seed
  `122487`, and the exact ACP → Sandbox → Settings replay 94 / 0 with two skips
  at seed `19746`. The complete `external_runtime_serial` replacement lane
  passes 617 / 0 with 12 skips at seed `97040`; the live manifest contains
  3,479 rows.
- v1.1 M12.16 focused: lifecycle-returned SQLite contention and a monitored
  DBConnection-closed exit both recover from durable attempt 0 without a
  `run_blocked` event, then start/complete/join once. Inter-prompt type-ahead
  and lifecycle-output redraw preserve the exact steering line. Exact
  regressions pass 4 / 0; TUI + supervision pass 64 / 0; isolated fan-out,
  Lifecycle, Scheduler, and Runtime caller suites pass 21 / 0, 12 / 0, 5 / 0,
  and 20 / 0. Static/Hex/Dialyzer gates are clean, and the 3,482-row manifest
  reconciles 550 files without a lane finding. Derived `release.v11` remains
  the clean-SHA pre-FV barrier; the authoritative release gate follows FV-01
  by explicit operator sequencing and is still required before closeout.
- v1.1 M12.17 implemented: a public raw-Adapter tracer holds one foreground
  Runtime turn, submits another complete line, interleaves lifecycle output,
  and proves immediate prompt/input acceptance plus FIFO non-concurrent
  execution when the first turn is released. Companion rows prove exact
  pre-acknowledgement attachment handoff, monitored worker-failure advancement,
  bounded queue rejection/shutdown cleanup, and Pi-mode transition compatibility.
  The six-row focused slice passes 6 / 0, complete TUI passes 41 / 0, the
  acknowledgement/caller plus steering matrix passes 34 / 0, static/Hex/
  Dialyzer checks are clean, and the 3,486-row manifest reconciles 550 files.
  Clean-SHA `release.v11` passes all 14 steps at pushed implementation
  candidate `28ee2d86`; evidence is `release-v11-1785027587.json`.
- v1.1 M12.18 implemented/focused-green: post-render receipt persistence cannot own or terminate
  an attended surface. Known recursive DBConnection and Exqlite busy/locked
  failures share one classifier and receive bounded idempotent retry through
  the Runtime receipt boundary; identity/receipt errors do not retry and
  unknown programming failures remain visible. After complete TUI stdout, one
  deduplicated task linked only to the application TaskSupervisor records the
  receipt while the Adapter and unrelated attended FIFO worker remain alive.
  Retry never reprints output. Exhaustion leaves the joined parent pending for
  honest later redelivery; no new durable outbox or retry daemon is introduced.
  Runtime retry encloses only the idempotent receipt transition/lookup, never
  scheduling. Scheduler and Coordinator consume the same closed classifier for
  raised and exited database failures, while unknown errors remain
  crash-visible. TUI acknowledgement workers and in-session suppression claims
  are each capped at 32. The focused cross-surface rejoin passes 176 / 0 and
  the 3,492-row manifest reconciles 551 files. Clean pushed implementation
  candidate `516fc7b9` passed all 14 `release.v11` steps; evidence is
  `release-v11-1785033817.json`, satisfying the pre-FV barrier.
- v1.1 M12.19 implemented: development/production converge on one Repo
  connection with immediate, effect-free durable phases; atomic idempotent
  inbound admission prevents a message-without-reference partial commit;
  action execution stays outside Repo transactions; and channel/TUI failures
  are bounded. Pushed candidate `2892940e` passed all 14 then-current
  `release.v11` steps (`release-v11-1785038793.json`). FV-01 against `b74a3405`
  passed in one fresh disposable Home with exactly one steer, join, and report
  plus a responsive independent turn.
- v1.1 M12.20 implemented/focused-green: all unmonitored durable `running`
  children now pass through one retry-safety/attempt disposition. A failed
  uncertain-effect or retry-exhausted transition installs a non-execution hold
  and retries only that persistence intent; pending steering applies before
  the child settles review-blocked; permanent errors stay log-visible without
  granting execution. TUI progress coalescing resets on durable
  `run.started`. The release gate now binds the five omitted regression files
  plus a real Allbert, non-Sandbox pool-1 subprocess step. Focused results are
  supervision 33/0, TUI 46/0, fan-in/steering/lifecycle 47/0, newly bound files
  42/0, and topology 5/0; 553 files reconcile to a 3,509-row manifest.
- Release: `release.v1` stays green (Tier-1/Tier-2 untouched; runtime
  response gains only additive fields per ADR 0029) and `release.v11` binds
  all eleven fan-out authority rows plus the M12.15 focused suites. Candidate
  `5601e67e` passed both versioned gates and pre-push, but its authoritative
  release failed from the leaked Coordinator described above. That partial
  cascade is superseded diagnostic evidence; all four gates remain pending at
  the final committed implementation SHA.
