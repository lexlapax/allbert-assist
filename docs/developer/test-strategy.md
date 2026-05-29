# Allbert Test Strategy

This is the developer contract for test isolation, lane classification, and
future precommit parallelization. It also defines the planning annotations that
make implementation milestones safe to parallelize.

Status: introduced for v0.41 planning. The taxonomy below is binding; the exact
Mix aliases and tag migrations land in the v0.41 implementation milestones
(M6-M9), each validated against the v0.40 regression oracle.

## Current Baseline

The v0.40 closeout gate showed the problem clearly (preliminary; M1 replaces
these with an authoritative census):

- full `mix precommit` passed but took roughly 22 minutes locally, as a
  monolithic serial sequence (compile, format, Credo, then four `mix test`
  invocations for core, web, StockSage, and telegram/email); it does not run
  Dialyzer
- core app suite: 1146 tests, 0 failures, 2 skipped; web: 107; plugin/channel:
  197 and 2 — across ≈233 `*_test.exs` files (≈180 core, 16 web, 37 plugin)
- async is almost always explicit (≈195 of 196 app test files) but skewed serial:
  ≈160 `async: false` vs 35 `async: true`. The migration flips proven-safe
  modules; it does not add missing tags.
- ≈623 `Application.put_env` sites in tests; temporary Allbert Home roots; ≈21
  named-process spawns; `Ecto.Adapters.SQL.Sandbox` in `:manual` mode
  (`shared: not tags[:async]`); filesystem cleanup
- partition-readiness is partial, not greenfield: `config/test.exs` already
  derives `DATABASE_PATH` from env vars; `MIX_TEST_PARTITION` is only a comment

The v0.40 closeout commit on current `main` (`f81d13d`) is the regression
oracle: its full `mix precommit` green set (1146 + 107 + 197 + 2, 0 failures) is
what every migration batch must reproduce through the full release gate, and the
monolithic v0.40 serial precommit stays runnable as the fallback gate for flake
triage.

M1 of v0.41 must replace this preliminary baseline with an authoritative
inventory containing file path, owner, case template, async setting, tags, timing,
and resource classes.

The authoritative M1 inventory is recorded in
`docs/developer/v0.41-test-inventory.csv`. It is a heuristic file-level census,
not a final async-safety proof; promotion still requires the ownership checks in
this document.

## Benchmark Records And Reorder Log

v0.41 treats developer efficiency as release evidence. Benchmark records are
kept here during implementation so humans and agents can compare deltas without
reconstructing terminal scrollback.

Required cadence:

- **M1 BEFORE baseline:** v0.40-equivalent serial release run, fast-local
  equivalent, per-lane breakdown, and slowest-module/test reports.
- **After M6, M7, M8, and M9:** benchmark delta versus the previous
  implementation milestone and versus M1.
- **M9 closeout:** after-done benchmark versus M1, plus the target-met or
  target-gap decision.

Each benchmark record must capture:

- milestone or batch id, commit SHA, date/time, operator/machine label, OS,
  CPU/core count, Elixir/Erlang versions, and warm/cold cache note
- exact command(s), including `ALLBERT_HOME`, `DATABASE_PATH`, partition count,
  lane filters, and any `--slowest`/`--slowest-modules` values
- wall-clock time, test counts, failures, skips, lane counts, and top slowest
  modules/tests
- planned efficiency share for the milestone and the actual delta
- interpretation: effective, ineffective, or correctness-blocked

Use this template for each entry:

```md
### v0.41 <M#/batch> Benchmark - YYYY-MM-DD

- Commit:
- Machine:
- Cache state:
- Commands:
- Release wall-clock / counts:
- Fast-local wall-clock / counts:
- Lane breakdown:
- Slowest modules/tests:
- Planned share:
- Actual delta:
- Decision:
- Follow-up/reorder:
```

### Reorder Log

Record any milestone or batch reorder here. A reorder is required when the latest
benchmark misses its planned share without shrinking its targeted hotspot, or
when `--slowest-modules` shows that the dominant hotspot is not scheduled next.
Reorders may change batch order only inside the correctness constraint: every
batch must still reproduce the v0.40 oracle green set through the full release
gate before it is accepted.

### v0.41 M1 Benchmark Attempt 1 - 2026-05-29

- Commit: `89af6d5`
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: cold dependency compile after local runtime change.
- Rerun command shape:
  - `/usr/bin/time -p env ALLBERT_HOME=/private/tmp/allbert_v0_41_m1_89af6d5_home DATABASE_PATH=/private/tmp/allbert_v0_41_m1_89af6d5_db/allbert_test.db mix precommit`
- Release wall-clock / counts: failed before test execution at `real 54.21`
  seconds (`user 74.64`, `sys 63.46`). No test counts collected.
- Failure: dependency compile stopped in `deps/memento/lib/memento/table/table.ex`
  because `:memento` 0.5.0 defines `@type record :: struct()`, and Elixir 1.19
  reports `record/0` as a built-in type that cannot be redefined.
- Fast-local wall-clock / counts: not run; release oracle failed before a
  correctness baseline existed.
- Lane breakdown: not timed. Static heuristic inventory at this commit found
  233 `*_test.exs` files: owners `core:180`, `web:16`, `stocksage:35`,
  `telegram:1`, `email:1`; templates `AllbertAssist.DataCase:48`,
  `StockSage.DataCase:21`, `ConnCase:14`, `SecurityEvalCase:13`,
  `ExUnit.Case:137`; primary-lane estimate `pure_async_candidate:14`,
  `db_serial:47`, `app_env_serial:30`, `home_fs_serial:2`,
  `global_process_serial:23`, `liveview_serial:12`,
  `security_eval_serial:16`, `external_runtime_serial:89`.
- Slowest modules/tests: unavailable because the suite did not compile.
- Planned share: not set; M1 cannot set an efficiency target without a green
  BEFORE baseline.
- Actual delta: correctness-blocked.
- Decision: at this attempt, M1 remained blocked. Do not advance to M2/M6 until
  the release oracle and BEFORE benchmark run on a compatible recorded
  toolchain, or until dependency compatibility work is explicitly moved into
  v0.41 scope and then re-benchmarked.
- Follow-up/reorder: no milestone reorder yet. The next work item was
  environment/toolchain recovery, not test-lane migration. ADR 0050 records the
  later compatibility unblock.

### v0.41 M1 Dependency Unblock And Release Benchmark - 2026-05-29

- Commit: v0.41 M1 memento unblock commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm Allbert build after dependency compatibility probing; the
  release command still recompiled the local `memento` path override.
- Compatibility work: Jido stack updated to `jido` 2.3.0, `jido_action` 2.3.0,
  `jido_signal` 2.2.0, and `jido_ai` 2.2.0. Because `jido_signal` 2.2.0 still
  depends on `memento ~> 0.5.0`, ADR 0050 adds a local `vendor/memento` path
  override that renames the conflicting `Memento.Table.record/0` typespec to
  `Memento.Table.memento_record/0` without runtime behavior changes.
- Commands:
  - `/usr/bin/time -p env ALLBERT_HOME=/private/tmp/allbert_v041_m1_unblock_precommit_home DATABASE_PATH=/private/tmp/allbert_v041_m1_unblock_precommit_db/allbert_test.db mix precommit`
- Release wall-clock / counts: passed at `real 1221.01` seconds (`user 25.61`,
  `sys 16.03`). Core app: 1146 tests, 0 failures, 2 skipped, 695.7 seconds.
  Web: 107 tests, 0 failures, 298.8 seconds. StockSage: 197 tests, 0 failures,
  194.5 seconds. Telegram/email plugin lane: 2 tests, 0 failures, 0.03 seconds.
- Fast-local wall-clock / counts: not yet recorded; M1 still owes the
  fast-local-equivalent baseline after the dependency unblock commit.
- Lane breakdown: release gate still uses the v0.40 monolithic precommit shape:
  compile, unused-dep unlock check, format, Credo, core tests, web tests,
  StockSage tests, and telegram/email tests. Static heuristic inventory remains
  233 `*_test.exs` files from Attempt 1 until the file-level inventory is
  materialized.
- Slowest modules/tests: not yet recorded; M1 still owes `--slowest-modules` and
  `--slowest` reports after this unblock.
- Planned share: not set; this was a correctness unblock, not an efficiency
  milestone.
- Actual delta: effective for correctness. The release oracle now reaches and
  passes Allbert tests on the current Elixir/OTP toolchain.
- Decision: dependency compatibility work is accepted into v0.41 M1 scope via
  ADR 0050. M1 may continue to fast-local baseline, slowest reports, inventory,
  target setting, and planned-share assignment. Do not begin M6-M9 test-lane
  migrations until those remaining M1 baseline artifacts are recorded.
- Follow-up/reorder: no efficiency reorder yet. Next work is M1 baseline
  completion, not lane migration.

### v0.41 M1 Baseline Inventory And Slowest Report - 2026-05-29

- Commit: `f670f99`.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after the Memento/Jido dependency unblock.
- Commands:
  - `/usr/bin/time -p env MIX_ENV=test ALLBERT_HOME=/private/tmp/allbert_v041_m1_fast_static_home DATABASE_PATH=/private/tmp/allbert_v041_m1_fast_static_db/allbert_test.db mix do compile --warnings-as-errors + format --check-formatted + credo --strict`
  - core async subset: `/usr/bin/time -p env MIX_ENV=test ALLBERT_HOME=/private/tmp/allbert_v041_m1_fast_core_home DATABASE_PATH=/private/tmp/allbert_v041_m1_fast_core_db/allbert_test.db /bin/zsh -lc 'mix test $(rg -l "use .*async: true" test | rg "_test\\.exs$")'`
  - web async subset: same shape in `apps/allbert_assist_web`.
  - plugin async subset: same shape from `apps/allbert_assist` against
    `../../plugins/stocksage/test`, telegram, and email.
  - slowest reports:
    `mix test --slowest-modules 20 --slowest 20` for core, web, and plugin
    lanes. The green web rerun used shared core migration prep first because a
    fresh web-only database misses StockSage plugin tables.
- Release wall-clock / counts: M1 release oracle remains the dependency-unblock
  run: `real 1221.01` seconds. Counts: core 1146 tests, 0 failures, 2 skipped;
  web 107 tests, 0 failures; StockSage 197 tests, 0 failures; channel plugin
  2 tests, 0 failures.
- Fast-local wall-clock / counts: existing `async: true` fast-local equivalent
  passed 211 tests. Sequential component sum was `real 34.46` seconds: static
  4.34s, core async 15.57s / 172 tests, web async 7.64s / 10 tests, plugin async
  6.91s / 29 tests. Projected parallel-after-static lower bound is about
  19.91s, before any v0.41 gate implementation.
- Lane breakdown: 233 test files recorded in
  `docs/developer/v0.41-test-inventory.csv`. Owners: core 180, web 16,
  StockSage 35, telegram 1, email 1. Templates: `AllbertAssist.DataCase` 48,
  `AllbertAssistWeb.ConnCase` 14, `AllbertAssist.SecurityEvalCase` 13,
  `StockSage.DataCase` 21, plain `ExUnit.Case` 137. Async declarations:
  180 false, 39 true, 14 unspecified. Primary lane census:
  `pure_async` 26, `db_serial` 66, `app_env_serial` 57, `home_fs_serial` 6,
  `global_process_serial` 19, `liveview_serial` 12,
  `security_eval_serial` 14, `external_runtime_serial` 33.
- Slowest modules/tests:
  - Core slowest run: 1146 tests, 0 failures, 2 skipped, `real 837.39`.
    Slowest modules: `AllbertAssist.Agents.IntentAgentTest` 154.5s,
    `AllbertAssist.RuntimeIntentAgentTest` 69.3s,
    `AllbertAssist.Execution.SkillScriptSpecTest` 63.3s,
    `AllbertAssist.Intent.EngineTest` 44.8s,
    `AllbertAssist.Security.DynamicCodegenEvalTest` 35.1s.
  - Web slowest run: 107 tests, 0 failures, `real 319.78`. Slowest modules:
    `AllbertAssistWeb.WorkspaceLiveTest` 265.0s,
    `AllbertAssistWeb.ThemeControllerTest` 19.5s,
    `AllbertAssistWeb.Workspace.AccessibilityTest` 15.2s.
  - Plugin/channel slowest run: 199 tests, 0 failures, `real 220.55`.
    Slowest modules: `StockSage.ObjectiveRuntimeTest` 81.6s,
    `StockSage.ActionsTest` 48.5s,
    `StockSage.Actions.RunAnalysisTest` 29.1s,
    `StockSage.Actions.RunAnalysisNativeTest` 18.6s,
    `StockSage.Agents.NativeCoordinatorTest` 16.7s.
- Planned share: M1 sets the target. M6 must reduce the existing fast-local
  command shape from 34.46s to <=25s by making the gate explicit and parallel
  where already safe. M7 may have 0s planned wall-clock share because it is
  metadata classification; it is effective only if reconciliation is complete
  and lane filters select the intended files. M8 must make a high-coverage
  partitioned local gate possible and attack the measured core/plugin hotspots,
  targeting <=10 minutes for static + all non-security/non-external lanes. M9
  must include LiveView partitioning/tuning and close with fast-local <=8 minutes
  or document the remaining gap.
- Actual delta: M1 records the baseline; no efficiency delta yet.
- Decision: M1 is complete. The dominant hotspot order is core intent/runtime
  serial tests, web `WorkspaceLiveTest`, then StockSage objective/action tests.
  M8/M9 must prioritize partitioning those lanes before less expensive cleanup.
- Follow-up/reorder: M5 sequencing is adjusted from the preliminary order:
  after M6/M7, attack high-cost core intent/runtime and StockSage
  objective/action partition-safety before broad low-cost filesystem cleanup;
  keep web LiveView as the M9 target because it is large but has the heaviest
  ConnCase/sandbox coupling.

## Lane Taxonomy

Every test file gets one primary lane.

| Lane | Meaning | Default execution |
| --- | --- | --- |
| `pure_async` | Pure or locally-owned tests with no global runtime resources. | Async in one VM. |
| `db_serial` | Uses shared Repo/SQLite sandbox or database-backed contexts. | Serial unless partition-isolated. |
| `db_partition_safe` | Database-backed tests proven safe with per-partition database/home roots. | OS-process partitions only. |
| `app_env_serial` | Mutates `Application` env, config, or compile/runtime app state. | Serial within a VM; parallel across OS partitions (separate BEAM = separate app env). |
| `home_fs_serial` | Mutates Allbert Home, settings, secrets, memory, sandbox, plugin, or tmp roots. | Serial within a VM; parallel across OS partitions with per-partition roots. |
| `global_process_serial` | Uses fixed process names, registries, PubSub topics, supervisors, or singleton restart behavior. | Serial within a VM; parallel across OS partitions (separate BEAM = separate process namespace). |
| `external_runtime_serial` | Uses Docker, browser drivers, stdio ports, provider endpoints, real MCP servers, package managers, or OS resources. | Explicit smoke lane (shared OS resources may collide even across partitions). |
| `liveview_serial` | Uses Phoenix LiveView/ConnCase with Repo ownership or shared process trees. | Serial within a VM; parallel across OS partitions (`server: false`, per-partition DB/home). |
| `security_eval_serial` | Uses `SecurityEvalCase`, eval inventory, adversarial fixtures, or cross-boundary security assertions. | Serial/release lane by default. |

Secondary blockers should be recorded separately. Example: a test may be primary
`db_serial` with secondary `home_fs_serial`. "Serial" lanes are serial *within a
VM*; see "Partitioning And The Two Concurrency Axes" for how they parallelize
across OS partitions.

## Tagging Convention

Lanes are applied at the case-template boundary first, to avoid editing every
file:

- Primary lane tags are boolean module tags named exactly after the lane:
  `@moduletag :pure_async`, `@moduletag :db_serial`,
  `@moduletag :db_partition_safe`, `@moduletag :app_env_serial`,
  `@moduletag :home_fs_serial`, `@moduletag :global_process_serial`,
  `@moduletag :external_runtime_serial`, `@moduletag :liveview_serial`, and
  `@moduletag :security_eval_serial`.
- Each shared case template sets a default lane and `async` default in one place:
  `DataCase → db_serial`, web `ConnCase → liveview_serial` (or `db_serial` when no
  LiveView), `SecurityEvalCase → security_eval_serial`, and channel/plugin cases →
  their owning lane. `SecurityEvalCase` already accepts `async:`; the other
  templates gain the same option.
- A test file declares `@moduletag <lane>` only to OVERRIDE the template default
  (e.g. promoting a `DataCase` test to `pure_async`) or when it uses no shared
  template (the plain-`ExUnit.Case` tail).
- Secondary blockers are recorded as additional `@moduletag`s. A file is excluded
  from any async/partition lane if it carries ANY blocker tag.
- Gates select lanes with `mix test --only <lane>` / `--exclude <lane>`; the lane
  tag values are the filter keys.

Reconciliation rule: after tagging, lane test-counts must sum to the full suite
total — zero unclassified files, no file double-counted.

The M2 taxonomy lock freezes this default mapping:

| Case/template | Default primary lane | Default async | Override path |
| --- | --- | --- | --- |
| `AllbertAssist.DataCase` | `db_serial` | `false` | `use AllbertAssist.DataCase, async: true, lane: :db_partition_safe` only after partition ownership is proven. |
| `StockSage.DataCase` | `db_serial` | `false` | Same as core DataCase, with plugin table cleanup remaining serial within a partition. |
| `AllbertAssistWeb.ConnCase` | `liveview_serial` | `false` | `lane: :db_partition_safe` only for non-LiveView controller tests with DB partition proof. |
| `AllbertAssist.SecurityEvalCase` | `security_eval_serial` | `false` | No async promotion in v0.41; evals stay release/serial. |
| Plain `ExUnit.Case` | explicit per file | declared by file | Add exactly one primary `@moduletag` before the file can join a named lane. |

Secondary blockers use the same tag names only as blockers, and must be called
out in the inventory or benchmark note. A file carrying any serial blocker is
not eligible for `pure_async` even when it currently says `async: true`.

### Plugins And Channels

Plugin and channel suites are in scope. StockSage's Python-bridge tests are
`external_runtime_serial` (a stdio Port to a real interpreter); channel adapter
tests (telegram/email) follow their own resource ownership. The umbrella runs
these via `do --app allbert_assist cmd mix test ../../plugins/...`; the gate
matrix keeps that invocation for the plugin/channel lanes rather than assuming a
single umbrella `mix test`.

## Async-Safe Rule

A test may be `async: true` only when it proves all touched resources are owned
or absent:

- no shared database writes or shared Sandbox owner
- no `Application.put_env/delete_env` unless scoped by a helper that serializes
  or restores safely
- no shared default `ALLBERT_HOME`, `ALLBERT_HOME_DIR`, or `DATABASE_PATH`
- no fixed global process, registry, PubSub, ETS, or table names
- no shared Req/Mox/provider stub that can receive another test's call
- no broad `File.rm_rf!` outside an owned temp root
- no external runtime dependency

If any item is uncertain, keep the test serial and record the blocker.

## Partitioning And The Two Concurrency Axes

Allbert tests parallelize on two distinct axes; conflating them causes flakes.

1. **In-VM async** (`--max-cases`): only `pure_async` tests. They own or avoid all
   global state, so ExUnit runs them concurrently in one BEAM VM. The concurrent
   case count derives from the measured core count, not a fixed value.
2. **Cross-VM partitioning** (`--partitions N`): the mechanism for every
   VM-global lane. Each partition is a separate OS process — a separate BEAM VM —
   so `Application` env, named processes, registries, ETS/PubSub, Allbert Home
   roots, and the SQLite file are all isolated per partition. Because test config
   sets `server: false`, there is no endpoint-port collision, so LiveView/Conn
   tests partition too. The lane runs serial *within* a partition; the
   parallelism is the partition count.

SQLite is one instance of the VM-global rule, with an extra constraint: it is
single-writer, so DB tests stay serial inside a partition (its own file) — the
speedup comes from partition count, never from async-within-partition.
`busy_timeout` masks brief contention but does not make concurrent writers safe.
`DataCase`/`ConnCase` are serial by default in one VM for this reason.

Every VM-global lane parallelizes the same way, given per-partition roots (one
invocation per partition `1..N`; `N` derives from the measured core count):

```sh
# DB lane (separate file per partition)
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only db_partition_safe

# Any other VM-global lane — same lane-agnostic harness, own roots per partition
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only app_env_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only home_fs_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only global_process_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only liveview_serial
```

The implementation may wrap this in a Mix alias or script, but the invariant is
fixed and lane-agnostic: every partition has its own database, Allbert Home,
migrated schema, and derived runtime roots. `external_runtime_serial` stays an
explicit smoke lane — it touches shared OS resources (ports, Docker, real
endpoints) that can collide even across partitions.

## Ownership Contract

Async or partition-safe tests must satisfy these ownership rules:

- derive all durable local roots from an owned `ALLBERT_HOME`
- derive database path from owned `DATABASE_PATH` or owned home
- keep settings, secrets, memory, sandbox, plugins, and tmp roots inside owned
  home
- name processes with a unique test id or let `start_supervised` own anonymous
  processes
- restore global app env in `on_exit`
- keep HTTP stubs local to the test module/process where the library supports it
- delete only owned temp roots

No test may write to a real operator `~/.allbert`.

The M3 isolation lock freezes these root derivations for helpers and gates:

| Resource | Required test derivation |
| --- | --- |
| `MIX_TEST_PARTITION` | `"0"` when unset; otherwise the partition id supplied by `mix test --partitions N`. |
| `ALLBERT_HOME` / `ALLBERT_HOME_DIR` | A temp root containing the lane and partition id, for example `/private/tmp/allbert_v041/<lane>/p1/home`. Set both aliases only to that owned home. |
| `DATABASE_PATH` | Inside the same owned partition root, for example `/private/tmp/allbert_v041/<lane>/p1/db/allbert_test.db`. |
| Settings, secrets, memory, sandbox, plugin, and tmp roots | Derived from the owned Allbert Home unless the test explicitly overrides them inside the same owned root. |
| Process names | Anonymous supervised processes by default; fixed names only in serial lanes, or unique names containing the test module, test name, and partition id. |
| Ports and external runtimes | `external_runtime_serial` unless the runtime has a documented per-partition port/path ownership story. |

Cleanup is constrained to owned roots. Helpers may remove the generated
partition root on exit, but must never remove a parent such as `/private/tmp`,
the repository, or any path derived from a real operator home. Tests that need
to mutate `Application` or `System` env restore the previous value in `on_exit`.

Partition helpers must run the same Allbert and StockSage migrations before the
test lane starts. The M1 web slowest rerun proved why this is required: a fresh
web-only DB setup misses StockSage plugin tables even though the v0.40
monolithic precommit order hides that by migrating through the core app first.

## Gate Matrix

| Gate | Use | Evidence |
| --- | --- | --- |
| Docs | Docs-only changes. | `git diff --check` and link/reference checks. |
| Focused | Every implementation milestone. | Explicit test files named in the plan/request-flow doc. |
| Static | Code changes. | compile warning gate, formatter check, Credo strict, Dialyzer when required. |
| Fast local | Daily development feedback. | Static checks plus proven async/partition-safe lanes. |
| Serial core | VM-global lanes (DB, app env, home, process, LiveView). | Serial *within* a partition, parallel *across* OS partitions (N from cores). Security evals + external smokes stay single-VM / opt-in. |
| Release | Manual validation/release handoff. | Full precommit-equivalent coverage plus Dialyzer and security evals. |
| External smoke | Machine-dependent integrations. | Docker, browser, real MCP/provider checks, explicitly opt in. |

Fast local gates are not release evidence. Release gates remain authoritative.
The release gate is a superset of the v0.40 `mix precommit`: it adds Dialyzer
(which today's precommit does not run) and must reproduce the v0.40 oracle green
set.

## Implementation Plan Annotations

Every implementation-ready milestone plan must include a development-lane
annotation. This keeps concurrency decisions visible before coding starts.

Required fields:

- **Parallel workstreams**: units that can proceed independently, such as docs,
  request-flow updates, pure modules, UI shell work, focused tests,
  browser/manual validation, or external smoke preparation.
- **Serial barriers**: resources or evidence that force ordering, such as
  SQLite/Repo ownership, app env mutation, shared Allbert Home roots, named
  processes, LiveView/Repo ownership, security evals, migrations, external
  runtimes, or release gate evidence.
- **Gate evidence**: focused test files, static checks, serial-lane commands,
  external smokes, and whether full precommit is required before commit or at
  release closeout.
- **Rejoin point**: when parallel work must be integrated, request-flow docs
  updated, drift checked against the milestone plan, and gate evidence reviewed.

If a milestone does not have this annotation, treat the plan as not
implementation-ready. Do not infer parallel safety from small scope.

## Migration Order

0. Apply case-template default lanes (the bulk classification) and reconcile lane
   counts to the suite total before any async promotion.
1. Produce the inventory and slowest-module report.
2. Convert obvious `pure_async` candidates only.
3. Add unique-home helpers for filesystem-only tests.
4. Add the lane-agnostic per-partition database/home/roots harness; prove it on
   the DB lane first.
5. Extend partitioning to the other VM-global lanes (app_env, home_fs,
   global_process), then LiveView, once the harness is stable.
6. Keep security evals single-VM serial and external smokes opt-in until proven
   safe.

Work in reviewable batches. Each batch must reproduce the v0.40 oracle green set
through the full release gate, and run its async/partition lane repeatedly within
a flake-rerun budget, before it is accepted.

Each batch also records the efficiency benchmark (release + fast-local
wall-clock, per-lane breakdown, top-N slowest modules) before and after. If a
batch does not improve `fast-local` effectively, re-prioritize the remaining
batches toward the dominant hotspot in the latest `--slowest-modules` report and
record the reorder here. Efficiency reordering never weakens coverage: every
batch still reproduces the v0.40 oracle.

If a converted lane flakes, re-run the suspect module under the v0.40 serial
fallback gate: if it passes serially the defect is parallelism/ownership (fix the
contract or move the module back to serial); if it fails serially it is a real
regression and blocks. Move flaky lanes back to serial first, then fix ownership
before retrying.

## Milestone Requirements

Every milestone plan must name:

- focused tests
- whether full precommit is required before commit or release closeout
- any serial lane touched
- any external smoke required for confidence
- why a narrower gate is acceptable, when it is acceptable
- parallel workstreams and serial barriers for implementation work
- the rejoin point for docs, tests, validation, and drift review

Do not hand off with known warnings, formatter drift, Credo findings, Dialyzer
warnings, focused-test failures, or release-gate failures.
