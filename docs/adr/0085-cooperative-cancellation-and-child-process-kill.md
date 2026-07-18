# ADR 0085: Cooperative Cancellation And Child-Process Kill

## Status

Proposed (v1.1 planning, 2026-07-18). Binding on v1.1 M4 once Accepted;
Accepted only in the commit that lands the cancel-token seam, the
port-based OS spawn with process-group kill, and the orphan-regression proof
together. Merges two operator-slotted 1.1 enablers: Mid-Action Interruption /
In-Flight Kill (deferred at `v0.24-rf:466`) and Child-Process Cancellation
Semantics (deferred at `v0.57-plan:845`) —
`docs/plans/future-features.md:164-185`.

## Context

Allbert cannot stop work it has started:

- **In-flight actions are uninterruptible.** v0.24 deferred mid-action kill;
  since then the only recourse is waiting out the timeout (up to the
  `delegate_agent` 900s cap, `actions/objectives/delegate_agent.ex:155-159`,
  or the 120s turn default, `runtime.ex:44`). The TUI's escape path cancels
  only the coding-turn presentation, not the work.
- **Timeouts orphan OS children.** `Execution.LocalRunner` runs
  `System.cmd/3` inside `Task.async` and, on timeout,
  `Task.shutdown(task, :brutal_kill)`
  (`execution/local_runner.ex:48-57,:59-70`). Killing the BEAM task closes
  the port; the spawned OS process receives stdin EOF and MAY exit — but
  nothing captures an OS pid, nothing kills a process group, and a child that
  ignores EOF (or has grandchildren) survives as an orphan doing unbounded
  work. The same shape exists in `execution/skill_script_runner.ex` and the
  sandbox command backends (`sandbox/backends/command.ex`,
  `container_runner.ex`).
- **v1.1 makes this acute.** ADR 0083 fan-out runs background children for
  minutes-to-hours, and the flagship's steering contract includes cancel
  ("skip that one") as a first-class in-channel verb. A cancel that leaves
  OS processes running — or that can only wait — is a lie in the UI.

Constraints: OTP supervision, BEAM processes, and local child processes are
not OS security boundaries; host execution must stay policy-bounded through
registered actions (AGENTS.md). Cancellation must therefore be an execution
semantics change, not a new authority: cancelling your own work grants
nothing and follows the existing no-confirmation precedent of
`Objectives.cancel/3` (`objectives.ex:111`).

## Decision

1. **Cancellation is tiered, and every cancel reports the tier reached.**
   - **Tier 1 — cooperative:** a per-run `CancelToken`
     (`Objectives.Runs.CancelToken`, Registry-keyed flag) is checked by the
     run executor BETWEEN operations (between steps, and between
     sub-operations inside actions that opt in via the runner context key
     `context[:cancel_token]`). A cooperative cancel completes the current
     operation, records durable state, and stops cleanly.
   - **Tier 2 — supervised shutdown:** if the run does not reach a
     checkpoint within the grace window, the RunServer (and its
     `Task.Supervisor.async_nolink` children, per the
     `CodingTurnSupervisor` template, `coding/turn_supervisor.ex:145-159`)
     is shut down through the supervisor; terminate drains to the last
     durable step.
   - **Tier 3 — OS child-process kill:** any OS processes the cancelled work
     spawned are killed by process group: SIGTERM to the group → grace
     (default 5s, configurable) → SIGKILL. Tier 3 also runs on every
     TIMEOUT path — the current orphan-on-timeout behavior is a bug this
     ADR retires, not a compatibility surface.
2. **OS spawns capture a portable kill handle at spawn time.** A small,
   reviewed C launcher is compiled for macOS and Linux, bundled in every
   binary release/Homebrew artifact, and invoked through an Erlang port by
   `Execution.LocalRunner`, `SkillScriptRunner`, and sandbox command
   backends. Its narrow protocol creates a new process group, reports the
   leader pid/handle, forwards child output and exit status, and accepts
   scoped TERM/KILL escalation. If the helper or handshake fails, execution
   fails closed; there is no fallback to an untracked spawn. Container-backed
   execution uses the container runtime's stop/kill while preserving the same
   scoped-handle contract inside the namespace.
3. **Kill scope is exactly what the run spawned.** Tier 3 addresses ONLY the
   process group(s) captured by that run's executions — never a pattern
   match on process names, never other runs' children, never daemon
   processes owned by channel supervision (ADR 0058 daemons are supervised
   restarts, not cancel targets). This is the scope rule the
   `fanout-cancel-kill-scope-001` eval row proves.
4. **Cancel is not an authority event, and needs no confirmation.**
   `cancel_objective_run` (registered action, `confirmation: :none`) follows
   the `Objectives.cancel/3` precedent: a user/operator cancelling their own
   run is the safety action. What cancel may never do is masquerade as
   approval or run new effectful work; a steer-then-retry after cancel goes
   through the normal action authority. External side effects already
   committed by completed operations are NOT rolled back — cancellation
   stops future work; the objective event records what completed, what was
   interrupted, and the tier reached.
5. **Cooperative checkpoints are the contract for long actions.** Actions
   that run long inner loops (research/browser flows, delegate dispatch
   waits, model streaming) SHOULD poll the context token at natural
   boundaries and return a `:cancelled` result; the runner treats an
   unchecked token as tier-2/3 eligibility after the grace window. New
   long-running actions are reviewed for checkpoint placement; the token is
   advisory to the action but binding on the executor.

## Consequences

- "Cancel" in every surface (steer-by-reply, workspace affordance, TUI
  escape offer) becomes truthful: work stops, including OS children, and the
  user sees which tier it took.
- Timeout behavior tightens everywhere the execution runners are used —
  long-running commands that previously leaked past their deadline now die
  with their process group. Tests that depended on orphan survival (none
  known; M4 proves the current orphan first, red-first) would surface here.
- A small per-spawn overhead (group leadership + pid capture) in exchange
  for a kill handle; measured at M4 and expected to be noise against command
  runtimes.
- Binary builds gain one narrow native artifact. Release CI compiles it for
  each supported macOS/Linux target, packages it, verifies its checksum and
  protocol, and the installed Homebrew binary exercises it in rehearsal.
- Actions gain an optional cooperative contract; existing actions work
  unchanged (tier 2/3 covers them) and can adopt checkpoints incrementally.
- The delegate-agent substrate is unchanged in v1.1: a `:delegate_agent`
  dispatch blocks only its own run and dies with it (tier 2); pushing the
  token INTO delegate agents is future work recorded at closeout intake, not
  scope.
- Platform nuance is contained behind the helper protocol. macOS and Linux
  are equally strong Tier-1 contracts; Windows/WSL2 stays out of scope with
  the standing WSL2 deferral.

## Validation

- v1.1 M4, red-first: (a) the ORPHAN PROOF on pre-fix code — a
  sleeping child/grandchild fixture survives today's timeout path; (b)
  post-fix: the full group is dead after tier-3 cancel AND timeout on macOS
  and Linux; (c) tier-1 checkpoint cancel completes the current operation;
  (d) tier-2 drain preserves the last durable step; (e) a sibling run's group
  survives adjacent cancel; (f) missing, malformed, or crashed helper
  handshakes fail closed; (g) packaged/Homebrew rehearsal locates and runs the
  helper.
- v1.1 M7: end-to-end in-channel cancel against a live fan-out (focused
  integration test + the §J validation matrix row 11: `ps` proves no orphan).
- v1.1 M9: `fanout-cancel-kill-scope-001` gate-bound in `release.v11`;
  sandbox/skill-script/coding suites green unchanged; `release.v1` green.
