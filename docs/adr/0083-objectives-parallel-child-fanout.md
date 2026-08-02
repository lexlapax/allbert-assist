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
manifest proofs are green. M12.21 additionally makes the attached Web join
projection one idempotent canonical conversation message across joined-signal,
missed-signal next-turn, and remount paths without changing decomposition,
scheduling, steering, or atomic fan-in authority. Bounded WV-01 passed at `9ca0e3fd`, and
final implementation candidate `f81a49de` passed expanded `release.v11`,
pre-push, and the uninterrupted authoritative release cascade on 2026-07-26.

The v1.3 M9.b.3 supplied-text amendment below narrows deterministic
decomposition to explicit counted orchestration protocols. M9.b.4/M9.b.5 then
supersede its interim Stage-0 model-classifier placement: the primary intent
manager owns the advisory decision to propose parallel work, Objectives remains
the durable authority, clean DirectAnswer children use bounded one-turn
Jido.Agent-backed workers, and
a durable main-model composition must finish before a report becomes pending.
M9.b.5's selected-report authority and recovery contract is implemented at
`b7ea776d`. After the first attended FOV-4 exposed a false single-turn result,
M9.b.4 commit `1b4d3014` clarified and implemented the manager boundary as one
structured provider assessment plus deterministic local Jido-owned
adjudication, with an optional second provider call only for malformed or
internally inconsistent output. The same remediation adds content-free
manager/admission facts to the existing conversation action-log diagnostics;
it creates no new authority or observability subsystem. M9.b.4.2/M9.b.5.2 now
accept the bounded semantic-quality and advisory-synthesis refinements in the
amendment below; their executable evidence remains tracked by the active v1.3
plan rather than inferred from the earlier commits. M9.b.4.3/M9.b.5.3 commit
`c3baec24` supersedes the combined Worker review/revision and synthesis self-
review new-write paths with the phase-separated protocol recorded below.
Historical durable carriers keep only their explicit replay compatibility.

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

### v1.3 M9.b.3 amendment — supplied text and counted orchestration

Decision 7's broad eligibility is retained, but deterministic parsing is now
limited to two explicit, counted operator protocols:

1. `Do N things/tasks: <task list>. Work on them in parallel[ and report back].`
2. `Do these N tasks in parallel: <semicolon-delimited task list>.`

For either protocol, `N` is required, must parse within the configured fan-out
bound, and must equal the complete parsed child count. A missing or mismatched
count, ambiguous delimiter structure, or incomplete child returns to the
advisory path; it never truncates, merges, or deterministically frames a
partial list. These exact protocols remain available offline so an operator
can request fan-out without depending on a model.

Every other semicolon, numbered or bulleted list, `then`/`and then` chain,
parallel word, conjunction, and uncounted orchestration phrase is only a cheap
plausibility signal. It may select the existing bounded structured
`Intent.Decomposer.ReqLLMProposer`; it is not itself evidence that the outer
operator request contains multiple tasks. The proposer must classify only the
operator's outer request. Quoted, embedded, or otherwise supplied text is data
owned by that request, so separators, imperative sentences, and numbered items
inside it do not become children. A request to summarize, extract, translate,
acknowledge, explain, critique, or otherwise transform one supplied item stays
one turn even when that item looks action-shaped.

The structured result remains advisory and is normalized by the existing
child-count, uniqueness, non-empty, overflow, and nested-fan-out guards.
Unavailable providers, timeouts, malformed output, a `single` decision, or
fewer than two valid proposed tasks fail closed to the ordinary single-turn
pipeline. A proposal above the configured maximum still clarifies with the
complete list.

This amendment adds no permission, confirmation path, action exposure, or
execution authority. Its statement that the Decomposer remains the Stage-0
classification module describes the M9.b.3 implementation only and is
superseded by the M9.b.4/M9.b.5 amendment below. Runtime and Objectives retain
the accepted framing/delivery contract, and every effectful child still reaches
registered Jido actions through the normal Engine, Registry, Runner, Security
Central, and confirmation gates.

### v1.3 M9.b.4/M9.b.5 amendment — manager planning, selective workers, and durable composition

The broad adaptive intent in Decision 7 remains accepted, but punctuation and
list-shape heuristics no longer decide whether an ordinary turn may frame
durable children. The implementation deepens the existing fan-out Module at
three seams while preserving the shipped Objectives scheduler and authority
model:

1. **The qualified conversational manager owns bounded adaptive admission.**
   After steering, Search commands, notification callbacks, and the two exact
   counted offline protocols are handled, a turn that reaches the clean
   DirectAnswer route makes one qualified model call that returns one useful
   answer, explicit closed evidence for the admission rules, and zero or more
   inert candidate children. The manager Interface is not a
   registered Allbert action, intent candidate, permission, or authority grant.
   The model sees the original typed operator turn plus Allbert-authored rules;
   it does not receive punctuation regex output as semantic evidence. v1.3 does
   not replace the existing action router: uncounted mixed/effectful compound
   work stays on the ordinary route, and the exact counted protocol remains the
   explicit force path for it.
2. **An adaptive plan is typed, bounded, and inert.** One declarative rule
   catalog derives both the system-role assessment instructions and Allbert's
   local decision criteria. A private Jido Agent owns the lifecycle transition
   from model-backed `assess` to model-off `adjudicate`; Jido state records the
   phases and result, while deterministic `FanoutManager.Policy` derives answer
   versus admission from the closed evidence. This is one provider call in the
   valid path, not one planning call followed by an LLM judge. The model
   proposal contains only bounded ordered children with title, objective, and
   expected result; the compiler, not the model, assigns plan version and
   source. The model cannot name an Allbert action,
   agent module, permission, identity, confirmation result, worker
   implementation, dependency graph, or delivery route. The manager evaluates
   semantic independence, supplied-text ownership, full coverage, and material
   parallel leverage. A deterministic compiler then validates schema, original-
   request binding, bounds, non-empty unique children, and forbidden authority
   fields; code does not pretend to prove prose semantics. The model supplies
   bounded semantic claims; Allbert owns structural validity, deterministic
   policy, source binding, compilation, and authority. One bounded repair
   provider call is permitted only after malformed or internally inconsistent
   evidence; a valid answer decision does not get repaired merely because it
   declines fan-out. A
   dependency, ambiguous scope, planner timeout, malformed output, disagreement
   after repair, or fewer than two valid children returns to the same-call
   answer or ordinary DirectAnswer path; it never partially frames work.
3. **The exact counted protocols remain the offline force Adapter.** Their
   declared count and complete parse are deterministic and model-independent.
   They enter the same canonical plan type, structural bounds, digest, and
   durable framing Interface, but explicit operator orchestration satisfies
   admission: this source does not invoke model planning, critique/repair, or a
   semantic independence judge. A malformed/mismatched count or incomplete
   child still creates nothing. These protocols do not use the former broad
   Stage-0 classifier path, and their existence does not let punctuation or
   uncounted orchestration bypass manager planning.
4. **Objectives is the durable system of record.** The original parent objective
   plus its ordered child rows are the canonical compiled plan; compact version,
   source, and digest provenance uses existing bounded metadata and the
   `fanout_proposed` event rather than duplicating the plan in another JSON
   column. Child Objectives remain the queue, retry, cancellation, confirmation,
   terminal-state, and recovery authority. Worker selection is deterministically
   derived after the existing Engine proposal is validated. Existing Scheduler, Coordinator, RunServer,
   acknowledgement, fair-capacity, atomic terminal reduction, and report-outbox
   contracts remain. Jido child-process tracking and awaits are live execution
   aids only and never substitute for durable Objectives state.
5. **The Worker Interface has two real Adapters.** The ordinary Adapter
   preserves the current Lifecycle implementation for a non-DirectAnswer
   registered action. A clean DirectAnswer child uses one temporary, bounded
   Jido worker which delegates to that same registered action, preserving its
   model resolution, disclosure, Active Memory, prompt envelope, redaction, and
   failure policy rather than recreating a second prompt stack. For an
   unchanged digest-verified child, its bounded Allbert-authored task envelope
   contains the child objective plus expected-result guidance; that guidance is
   not action authority. The worker also receives only child-scoped original
   request context and explicit budgets. Every effect still
   resolves through Registry and executes through Runner, Security Central,
   and confirmations. Effect selection is validated against the original
   operator text/source spans, never against model-authored child prose alone;
   generated plans do not amplify authority. Conversation-manager children are
   DirectAnswer-only. Exact-counted children may select an action only from an
   exact span of the digest-verified operator request. Selection and recovered
   action/parameter validation for v1.3 children are deterministic and model-
   off; legacy ordinary Objectives retain their existing model-assist behavior.
   When a registered action normalizes a resumable confirmation packet, the
   action-owned packet is canonically digested into the durable step when it is
   parked. Approval and pre-Runner recovery both recheck that binding; they do
   not require the normalized packet to equal the pre-confirmation input, and
   they do not trust mutable confirmation YAML by itself.
   Missing or inconsistent v1.3 provenance cannot be reclassified as legacy or
   escape the frozen budget. The one-turn Jido worker has no iterative tool loop
   and cannot spawn a nested fan-out in v1.3.
   M9.b.4.2 deepens that private Jido worker for conversation-manager, exact-
   counted, and verified operator-steered DirectAnswer children to
   `draft` → `review_and_revise` → `accepted` or `unresolved`. One source-bound,
   versioned quality contract is derived from the digest-verified original
   request, compiled child objective, expected-result guidance, the existing
   DirectAnswer rule catalog, and a small task-neutral child-coverage/completion
   extension. After the existing three-field FanoutPlan/child binding is
   verified, Allbert adds a typed completion obligation: requirements are the
   union of child objective and expected-result guidance, every explicit result
   must be present and supported, and missing required evidence leaves the child
   unresolved.
   It derives both the prompt and closed review evidence; no domain
   keyword/regex, prompt-specific fact, formatting oracle, or exact-answer
   check is production policy. The registered DirectAnswer action remains the
   first call and disables its own model failover only for this grounded worker
   context. A model-backed draft then receives exactly one advisory
   review-and-revise call through the existing `fanout_synthesis` task chain;
   its provider result carries the final answer and one catalog-keyed Boolean
   violation judgment per rule, not an aggregate verdict, rule ids/order, or a
   failed-rule list. Allbert normalizes catalog order and Jido accepts only when
   no rule is violated;
   non-model draft outcomes spend no reviewer call, and a malformed, negative,
   unavailable, or unresolved review fails the child in that attempt. Corrupt
   provenance fails before quality completion; non-DirectAnswer children keep
   the existing registered-action/effect-receipt path without review. The
   existing two-call reservation is unchanged and never refunded; ordinary
   DirectAnswer failover is unchanged.
   This M9.b.4.2 combined review/revise topology is implementation history and
   is superseded for new work by the M9.b.4.3/M9.b.5.3 amendment below.
   A verified steering directive replaces the compiled child objective but not
   its historical acceptance text. The derived contract therefore uses one
   fixed task-neutral Allbert completion instruction and binds hashes of the
   exact directive and directive-event id; it never judges steered work against
   stale model-authored guidance.

   Quality task-contract/rule-catalog writes use version 2 and a v2 digest
   domain. The receipt envelope remains version 1; new receipts name catalog
   version 2, while verification retains valid catalog-v1 receipt replay and
   rejects unknown future versions. The canonical contract binds the catalog,
   but provider user data carries task fields, the completion obligation, and
   catalog version/digest; catalog-derived system rules appear once.
   Catalog-v1 reconstruction uses pinned DirectAnswer-policy version 1 rather
   than the mutable current catalog. Lifecycle's pre-commit validator accepts
   only current catalog-v2 receipts for new events; recovery/report readers
   retain the replay-permissive v1/v2 validator.

   Local code validates the closed result and normalizes the accepted answer at
   the existing 2,000-character Objective-summary boundary. The worker records
   the exact 0/1/2 provider-call outcome in ephemeral Jido state; only an
   accepted two-call result
   creates the content-free typed quality receipt. That receipt binds
   Objective/step identity, task and rule versions, reviewer configuration,
   call count, closed verdict and failed-rule ids, and the exact normalized-
   answer digest. Lifecycle verifies it before the existing terminal transaction
   writes the exact transient `state.step.id` to
   `Objective.current_step_id`, finalizes that Step, appends the correlated
   `run_completed` payload, and then performs final parent reduction/report-input
   freeze in the same immediate transaction. Report code never reconstructs the
   missing binding. Recovery verifies its digest before admitting
   a completed child to a new report snapshot. Drafts and critique are not
   persisted. The receipt records
   review provenance only: it cannot select an action, grant permission, claim
   an effect, alter state, or create work, and all original-source action rules
   above remain unchanged.
   Every Lifecycle terminal path first requires the transient Step's
   `objective_id` to equal the child Objective id before it may persist
   `current_step_id` or finalize that Step. This applies even when another child
   is still active; a later final-parent report freeze is not a substitute for
   write-boundary ownership validation.
   For a reviewed completion, that event payload contains only the receipt and
   existing atomic Step id/status correlation; answer prose remains on the
   Objective/Step and post-commit signal. This avoids duplicating untrusted text
   into the existing bounded event payload and adds no persistence mechanism.
6. **Terminal reduction precedes semantic composition, and composition precedes
   delivery.** The last terminal child transaction still freezes the complete
   child/result/status snapshot and parent join outcome, but it leaves
   `report_delivery_state=not_ready` and atomically marks additive
   `report_composition_state=queued`. A recoverable composer invokes a closed
   `fanout_synthesis` task chain initially bound to the same qualified profile
   used for the originating ordinary conversation
   with the original request, frozen plan, and bounded durable child result
   envelopes. It makes exactly one structured-output call whose only model-
   authored value is a content-free list of relationship sections. Each
   section contains one closed relationship enum (`complementary | contrasting
   | sequential | supporting | independent`) and ordered completed-child queue
   positions. Allbert's local compiler stamps layout version 1, rejects extra
   fields, requires an exact partition of every completed child once, requires
   a non-independent multi-child section when at least two children completed,
   and enforces singleton `independent` versus multi-child relationship
   cardinality. Failed, cancelled, and abandoned children never enter the
   model-controlled partition. They remain in deterministic local status and
   attention sections. The model therefore selects grouping and order only; it
   writes no prose, fact, status, failure, observation, or effect claim. Allbert
   deterministically renders every word and the complete authoritative child
   appendix. Child detail is labelled as an observation; only a durable effect
   receipt reference is effect evidence. Composition cannot change child
   status, hide failures, execute an action, or create another fan-out.
   That description is the layout-v1 compatibility contract. M9.b.5.2 makes
   layout v1 validated read/replay only; every new selection writes layout v2.
   `ReportComposer` remains the durable plain-GenServer owner of queueing,
   claiming, compare-and-swap storage, recovery, and delivery readiness. A
   private ephemeral Jido synthesis lifecycle runs only inside a claimed row:
   deterministic baseline, one `fanout_synthesis` structured provider call,
   then `accepted | unresolved`. The result contains relationship sections, one
   bounded advisory synthesis paragraph, and closed rule/queue-position review
   evidence. That one call performs review and revision together; there is no
   second judge/repair call, queue, service, action, table, or setting. One pure
   `Fanout.Report.SynthesisPolicy` module is the single immutable catalog for
   the versioned ordered rules consumed by provider schema/prompt, local
   validation, and selection provenance.
   This M9.b.5.2 combined synthesis/self-review topology is implementation
   history and is superseded for new work by the M9.b.4.3/M9.b.5.3 amendment
   below.

   Worker QualityPolicy and SynthesisPolicy share the pure
   `AllbertAssist.Models.ClosedRuleEvidence` transport/normalization boundary.
   It emits a closed raw JSON Schema whose `rule_violations` object requires one
   Boolean property per policy-owned rule and rejects additions. Raw JSON Schema
   is only ReqLLM/provider transport encoding: each policy retains rule meaning
   and applicability, and Allbert derives ordered results, failed ids, and the
   aggregate verdict locally before Jido can advance.

   Transport v2 correlates each closed schema key with the same stable rule id
   rendered beside its policy-owned prompt instruction. Every required Boolean
   describes the same polarity explicitly: `true` means the rule remains
   violated in the returned final output after revision; `false` means satisfied
   or not applicable. The Worker reviewer-configuration v2 digest also binds
   this transport version and the exact response schema. This is an additive
   provider-contract clarification; Jido transitions, local verdict derivation,
   durable replay, report authority, and call bounds do not change.
   Focused configured-provider gates expose only closed, allowlisted failure
   stages, reasons, and counts. Raw prompts, provider/model output, answers,
   arbitrary nested errors, and failed-rule identifiers do not enter
   TestMetrics.

   Layout-v2 input binds the complete bounded original request, parent-only
   join guidance, every reviewed DirectAnswer observation plus its verified
   quality-receipt digest, and every non-DirectAnswer result plus its existing
   effect receipt. A pre-contract DirectAnswer completion remains readable but
   forces deterministic `legacy_unreviewed_children` fallback instead of model
   synthesis. A fan-out with no completed child has no accepted observation to
   synthesize and therefore makes no provider call; it stores deterministic v2
   fallback reason `no_completed_children` with outcome `not_run`. A persisted
   non-DirectAnswer action must resolve through the central Action Registry
   before v2 calls it `registered_action`; an unknown action fails v2 freeze,
   while already-selected v1 replay remains byte-exact and does not acquire the
   new dependency. A completed observation requires exact current-Step
   ownership and a completed Step. For cancelled, failed, or abandoned children,
   cancellation, stale abandonment, and retry recovery may leave any valid
   active or terminal Step state; v2 verifies ownership/status, rejects
   completion and quality-receipt authority, Registry-resolves any persisted
   non-DirectAnswer action identity, and excludes that child from synthesis. A
   missing Step is allowed only with a nil `current_step_id`. That non-completed
   child's appendix row renders terminal detail and explicitly says that no
   completed result exists; the persisted action path does not turn that detail
   into a registered-action result, and a non-completed DirectAnswer row does not
   by itself require deterministic fallback. Additive recovery
   recognizes only the known pre-fix v1.3 completion payloads
   `{summary}`, `{summary, step_id}`,
   `{summary, step_id, step_status=completed}`, and
   `{summary, step_id, step_status=completed, quality_receipt}` when
   `current_step_id` is nil. When the payload names a Step, recovery must load
   that exact Step and verify child ownership, completed status, durable result-
   summary equality, and any receipt binding. The summary-only shape must exactly
   match the existing 500-character projection of the durable Objective summary
   and establishes no Step, action, or receipt authority. Recovery then preserves
   the child only as `legacy_unreviewed_advisory` and forces deterministic
   fallback. It never reconstructs reviewed or registered-
   action authority, rewrites history, or accepts empty/extra/unknown payloads.
   A completed registered-action child additionally consumes the existing exact
   Lifecycle completion event—`summary` equal to the existing 500-character
   Lifecycle projection of `child.last_observation_summary`, with that durable
   Objective summary byte-equal to the completed Step's `result_summary`, plus
   matching `step_id` and `step_status=completed`—with no quality-receipt field;
   report validation does not create a summary-only parallel contract or let
   mismatched prose inherit registered-action authority.
   The 16 KiB canonical model-input allocator keeps the complete bounded parent
   request fixed, then allocates the largest common cap across every completed
   observation while optional child objective/expected-result fields remain at
   their explicit marker floor. An accepted observation of at most 64 UTF-8
   bytes remains complete; a longer observation retains at least a readable
   64-byte content prefix plus its shortening marker, never only the marker.
   Only afterward may the
   remaining bytes expand those optional task fields under their own common cap;
   if all evidence prefixes cannot fit, no provider call occurs and composition
   falls back as `composition_input_too_large`. Allbert alone renders
   status/attention truth, headings, receipt
   language, and the ordered authoritative appendix. Those deterministic parts
   have first claim on the 32 KiB report; advisory synthesis is one
   anti-spoofed paragraph bounded to 4,096 UTF-8 bytes and cannot displace an
   otherwise complete child appendix. The exact reviewed paragraph must fit
   unchanged after that allocation; otherwise the selection is an unresolved
   deterministic fallback, not truncated prose with accepted provenance.
   Allocation first computes the deterministic-fallback child representation.
   Model-selected relationship sections and synthesis may not worsen any
   child's title/objective/detail shortening vector versus that baseline; a
   selection that would displace otherwise fitting authoritative child truth is
   rejected in favor of fallback.
   The normalized synthesis is rendered inside one fixed Markdown blockquote
   beneath its Allbert-owned advisory label. That frame—not a substring or regex
   inventory—is the visual authority boundary; the closed synthesis-rule review
   owns semantic no-spoof quality. The stored digest continues to bind the exact
   inner paragraph, and extraction validates the exact frame.
   Model synthesis is inspected for Redactor-detectable secret material on its
   exact raw returned bytes before whitespace/control normalization. A detected
   secret fails composition to deterministic fallback; Allbert never silently
   redacts or otherwise mutates model prose and then preserves the locally
   derived review verdict or digest as if it covered those changed bytes.
   Invalid, negative, unavailable,
   timed-out, or deadline-exhausted synthesis stores the truthful deterministic
   fallback with no model prose and opens delivery; it never masquerades as
   healthy synthesis. `ReportComposer` owns one killable Task around the entire
   private Jido lifecycle, capped by the already-authorized effective composer
   timeout; Jido `cmd timeout: 0` is permitted only inside that Task. Once the
   Task starts, expiry terminates it and records `synthesis_timeout/unresolved`,
   while pre-dispatch exhaustion remains `deadline_exhausted/not_run`.
   Unexpected Task exit stays crash-visible and restart recovery records
   `recovery_after_restart/unresolved`; no provider or Jido child survives the
   attempt. The v2 authoritative appendix also renders the closed
   authority class for every child: reviewed advisory rows carry their quality-
   receipt digest and explicitly deny effect-evidence meaning, completed
   registered-action rows mark semantic review not applicable and retain the
   separate effect-receipt line, non-completed rows expose terminal detail and
   the absence of a completed result, and completed legacy-unreviewed rows
   expose the absent receipt/fallback condition. Layout v2 treats the
   operator-derived parent title and every
   rendered child title, objective, and observation/detail as untrusted display
   data: ordinary, fallback, attention, relationship, appendix, and emergency
   paths deterministically JSON-string encode every occurrence before
   Allbert-owned status/authority/receipt syntax. Embedded newlines cannot forge
   a report boundary. Layout-v1 body bytes do not change.
7. **The composed report is itself durable.** Additive parent fields store
   bounded `report_body`, `report_source`, `report_input_digest`, and
   `report_selection_digest`, with
   `report_composition_state=not_ready | queued | composing | ready | fallback`.
   Redacted `fanout_report_selected` event metadata carries the body/input
   digests and exact normalized, content-free selection provenance. For a model
   selection that provenance is exactly profile, provider, model, layout
   version, and normalized sections; for deterministic fallback it is exactly
   fallback reason and layout version. The selection digest domain binds the
   selected source plus that complete normalized provenance, so changing a
   source, provenance field, section, or fallback reason is detectable rather
   than cosmetic. A successful composition transaction stores the report and
   opens the existing delivery outbox by moving delivery to `pending`.
   Unavailable/model-failed/
   exhausted composition durably stores the existing deterministic complete-
   child renderer as the fallback and then moves delivery to `pending`; no
   completed child result is withheld indefinitely for model quality. Recovery
   claims queued work idempotently and converts a stranded composing row to the
   deterministic fallback, and delivery consumers read only the stored report
   selected by this transition. Every central projection—including TUI and its
   subscriptions, Notify/DM, Web, and public protocols—emits those exact stored
   bytes for both model and deterministic-fallback selections; no surface
   reconstructs a body or accepts a weaker terminal-event/provenance shape.
   Rehydration re-freezes the authoritative input,
   validates the input and selection digests, normalizes the exact event
   provenance, and deterministically re-renders the selected layout. An unknown
   layout version, extra or missing provenance field, or any input, source,
   provenance, body, event, or digest tamper fails closed to an inconsistent
   projection: no pending report is rendered or acknowledged.
   Layout v1 retains those exact domains and provenance byte-for-byte for
   compatibility reads. Layout v2 binds the receipt-bearing snapshot under
   `allbert:fanout-report-input:v2\0` and the exact `source` plus normalized
   provenance under `allbert:fanout-report-selection:v2\0`. Model provenance
   binds profile/provider/model, layout and synthesis-contract versions,
   sections, accepted review, reviewed queue positions, and the exact advisory-
   paragraph digest. Fallback provenance binds only its closed reason, layout
   and contract versions, and `not_run | unresolved`; it contains no model
   prose. Rehydration rejects a new v1 write, unknown version, missing or extra
   provenance, a version-crossed snapshot/selection, any receipt/input/section/
   synthesis/body mismatch, or event/digest tamper before delivery. An
   unselected queued or composing v1 digest is verified and compare-and-swap
   rebound in the existing immediate transaction to an authority-bearing v2
   digest before claim or recovery selection; selected/pending/delivered v1
   state is never rebound. The append-only `fanout_joined` event is not rewritten
   by that CAS: projection verifies its old digest against the exact frozen v1
   snapshot while parent/selection/body independently verify v2; any other old-
   event mismatch remains inconsistent. `recovery_after_restart` records
   `unresolved`, since
   a stranded `composing` row cannot prove whether its one provider call ran.
   Historical pending/delivered v1 state remains on its explicit byte-exact
   compatibility path. The same explicit integrity-error classifier lets
   queue scan and recovery aggregate and leave one corrupt parent untouched while
   continuing to later valid parents; unclassified storage/operational failures
   still abort. Both paths cursor through deterministic 100-row batches. At most
   one bounded content-free diagnostic per typed reason per batch retains its
   count, first/last id, and complete ordered `parent_ids` list; the batch cap
   bounds that aggregate without reducing failures to only a count or id range.
   Before querying Steps or events for a v2 candidate, the queue boundary
   validates parent shape, terminal child shape, and the absolute 16-child
   limit. An oversized/corrupt parent therefore becomes a classified per-parent
   integrity skip and cannot exceed SQLite bind limits or abort later work.
8. **Automatic fan-out stays balanced and operator-visible.** Independent
   advisory/read-only work may start under the existing automatic rollout after
   truthful kickoff custody. Uncounted effectful or mixed work stays on the
   ordinary single-turn action route; the exact-counted protocol is the
   explicit force path and still encounters each action's ordinary permission,
   confirmation, and provider-use policy. There is no new blanket fan-out
   confirmation. Existing global/per-fan-out child caps are joined by bounded
   fan-out-owned planning, selection, DirectAnswer, composition, retry, token,
   and elapsed-time budgets resolved from Settings Central. A registered
   action's own downstream provider work remains governed by that action's
   existing budget and authority contract rather than an invented generic
   model-call ledger. A failed admission or composition does not become an
   operator-facing clarification unless the existing overflow or action
   contract already requires one.

9. **Manager and admission observability reuses the conversation action log.**
   Each ordinary manager result may append one bounded, content-free
   `fanout_manager` diagnostic containing only the closed result/outcome/policy/
   join values, attempt and work-unit counts, and reviewed flag. Runtime
   framing may append one `fanout_admission` diagnostic containing only
   admitted, rejected, single-turn-fallback, or shadow-only plus a closed reason
   where applicable. A sanitizer rebuilds these facts from an allow-list before
   response signals, traces, or `conversation_messages.action_log` persistence.
   It discards operator/model text, answers, candidate children, profile or
   provider payloads, and raw errors. DirectAnswer action results carry only
   their ordinary used-status diagnostic before Runner publishes
   `allbert.action.completed`; the full manager structure remains transient for
   Runtime admission/provenance and is removed from both top-level and nested
   action responses before persistence. Manager result/outcome pairs and
   policy/join classifications are closed enums, repeated sanitization
   preserves only bounded booleans/counts, and an answer's effective join role
   is always `none`. This adds no database migration, event family, log service,
   or authority-bearing state; Objectives remains the only durable truth for
   admitted work.

Manager planning runs inside the qualified DirectAnswer turn. Composition uses
the separate closed `model_preferences.tasks.fanout_synthesis` task, initially
configured to the same qualified profile so one conversation model owns both
sides without coupling their task-chain policy. This amendment creates no
surface-private planner, worker, join, or report implementation: TUI, Web, DMs,
CLI, and public protocols keep using the central Runtime/Objectives Interfaces.
The selection transaction is authoritative before its joined signal is
published. Signals remain low-latency wake-ups: an API waiter rechecks the
durable projection at its timeout boundary, the attached TUI monitors and
re-subscribes to SignalBus then reconciles only its bounded owned attachment
set, and notification recovery reconciles its durable completion outbox. A
failed publication or SignalBus-only restart can delay the wake-up but cannot
strand, duplicate, or consume the pending report.

### v1.3 M9.b.4.3/M9.b.5.3 amendment — phase-separated critics and verified generation

This amendment is accepted and implemented at `c3baec24`. It supersedes the
M9.b.4.2 Worker `review_and_revise` call and the M9.b.5.2 combined synthesis/
self-review call for all new work. It preserves their task/rule meanings,
durable Objective/report authority, layout-v2 rendering, historical replay,
and deterministic fallback contracts.

1. **Generation, criticism, revision, and verification are separate phases.**
   A DirectAnswer Worker first produces one immutable draft through the
   registered `direct_answer` action. Exactly two non-empty policy-owned groups
   form a disjoint exact cover of the fourteen ordered `QualityPolicy` rules.
   Two transient private Jido Critic Agents, each hosted in its own owner-linked
   and monitored Task, separately assess those groups. Allbert validates and
   merges their closed results in catalog order. An all-satisfied first round
   accepts the unchanged draft. If a complete first round instead contains
   violated/unresolved rules, the registered DirectAnswer path may revise once
   from those deterministic rule ids, after which a fresh pair of Critic Agents
   verifies the exact revised bytes. A critic
   never generates or revises an answer, and no first-round critic verifies a
   revision it caused.
2. **The composer uses the same protocol under its existing durable owner.**
   `ReportComposer` remains the only durable queue/claim/recovery/selection/
   delivery owner. Its private Synthesis Agent generates relationship sections
   and one bounded advisory paragraph through `fanout_synthesis`. Exactly two
   policy-owned groups cover all seven ordered `SynthesisPolicy` rules and are
   assessed by separate `fanout_review` critics. A complete first round with
   violated/unresolved evidence permits one separate `fanout_synthesis`
   revision and a fresh critic pair.
   Allbert still validates the exact completed-child partition, relationship
   enum/cardinality, child/receipt/status truth, appendix, byte allocation,
   framing, and surface bytes. Partial or unresolved review selects the
   existing truthful deterministic fallback rather than unverified prose.
3. **Assessment transport is closed and source-bound.** Each critic sees only
   its assigned rules, the exact candidate, and closed source handles bound to
   whole-source digests. It returns only `satisfied | violated | unresolved`
   per owned rule and a non-empty subset of allowed handles. Missing,
   duplicate, extra, wrong-group, foreign-handle, malformed, or unresolved
   evidence fails closed. The pure review compiler owns group catalogs and
   aggregate verdicts; model output owns neither. Raw task/candidate text,
   handle assignments, critic prose, and provider errors remain outside
   receipts, selections, metrics, traces, and persisted diagnostics.
4. **Calls and budgets match the physical topology.** Accepted unchanged
   Worker and composer paths each record `1/2/0/0/3`; accepted revised paths
   each record `1/2/1/2/6`. Budget v2 reserves
   `manager_attempts + child_count * 6 + 6` provider calls and
   `manager_attempts * 1024 + child_count * 3072 + 4096` output tokens before
   framing. The existing Settings limits now default to 64 calls and 32,768
   tokens; explicit operator values and allowed ranges remain authoritative.
   The plan retains one 300,000 ms hard deadline and no refund or hidden
   semantic-retry ledger.
5. **One counted call means one physical attempt.** ReqLLM 1.18.0 honors
   caller `max_retries: 0`; every fan-out-owned manager, DirectAnswer draft/
   revision, critic, and synthesis generation/revision request and enclosing
   Jido command sets that limit. Structured fan-out requests also disable JSON
   repair. The DirectAnswer worker marks automatic retry unsafe after dispatch.
   Timeout, cancellation, owner death, or the first infrastructure failure
   brutally stops remaining critic siblings. Restart never replays a call
   whose dispatch is uncertain.
6. **Roles are independently selected and disclosed.** Manager planning
   resolves only the closed `model_preferences.tasks.fanout_manager` chain.
   DirectAnswer draft/revision remains the registered `direct_answer` route.
   Every critic resolves `model_preferences.tasks.fanout_review`; synthesis
   generation/revision resolves `model_preferences.tasks.fanout_synthesis`.
   Runtime, not the manager, rechecks all downstream role callability from one
   Settings snapshot before durable framing and crosses Disclosure for each
   exact effective transport. Missing readiness returns the same ordinary
   single answer with a closed role-specific reason, no auto-pull, no repeated
   per-turn confirmation, and no fan-out rows.
7. **Configuration and protocol provenance are exact but non-authoritative.**
   Domain-separated role digests bind selected profile/provider/model,
   configured and effective endpoint identity, hashed secret-reference
   identity, profile contract, response schema, sampling/output/timeout/retry
   controls, and the exact phase/catalog fields. Manager repair binds an
   ordered set of per-attempt digests. Raw URLs, credentials, prompts, source
   contents, and provider output are excluded. These digests make drift and
   endpoint changes detectable; they do not grant egress, permission, semantic
   truth, or effect authority.
8. **New durable evidence is additive and replay-safe.** Worker writes use
   quality-receipt v2 with review-protocol and group-catalog versions, exact
   frozen group-catalog digest, reviewer-configuration and assessment digests,
   candidate/answer binding, and exact phase/provider counts. Model report
   selections use synthesis-contract v2 with parallel phase evidence. Replay
   recomputes catalog digests, exact keys, phase arithmetic, candidate/source
   bindings, and selection/body/event digests. Receipt-v1 and synthesis-
   contract-v1 rows remain byte-exact historical replay only and cannot
   authorize new phase-separated success.
9. **Upgrade and recovery fail closed without new calls.** Nonterminal Budget-
   v1 DirectAnswer children transition idempotently to failed/unresolved with
   `quality_protocol_upgrade_required`; Budget-v1 joined/composing parents use
   the complete-child deterministic fallback with
   `review_protocol_upgrade_required`. Both make zero provider calls, mint no
   replacement receipt, and tolerate repeated compare-and-set recovery without
   duplicate events, reports, or delivery. An operator retry creates a new
   Budget-v2 plan rather than rebinding history.
10. **No authority or durable subsystem is added.** Critic Agents are private
    ephemeral Jido FSMs, not Objectives, registered actions, services, queues,
    or permissions. The protocol adds no table, store, event family, surface-
    private loop, or action exposure. Objectives/Lifecycle and ReportComposer
    retain durable state; Registry/Runner, Security Central, confirmations,
    exact operator-source provenance, and effect receipts retain execution and
    effect authority. Critic and synthesis evidence remains advisory quality
    evidence only.

### M12.15 amendment — atomic terminal reduction and durable report work

The M12.15 wording below records the pre-M9.b.5 transition. Where it says the
last child moves report delivery directly to `pending`, the later accepted
M9.b.5 amendment above supersedes it with composition `queued` plus delivery
`not_ready`; only a stored composed or deterministic fallback report becomes
delivery `pending`.

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
  signal taxonomy in `docs/plans/archives/v1.1-request-flow.md`).
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
  cascade is superseded diagnostic evidence. Final implementation candidate
  `f81a49de` subsequently passed expanded `release.v11`
  (`release-v11-1785097379.json`), pre-push
  (`prepush-2026-07-26T20_32_10Z.json`), and the uninterrupted authoritative
  release gate (`release-2026-07-26T20_48_52Z.json`).
