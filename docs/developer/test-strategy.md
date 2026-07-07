# Allbert Test Strategy

This is the developer contract for test isolation, lane classification, and
future precommit parallelization. It also defines the planning annotations that
make implementation milestones safe to parallelize.

Status: introduced for v0.41 planning. The taxonomy below is binding. M6 landed
the developer gate command surface, and M7 lands executable lane classification:
shared case-template defaults plus explicit primary tags for the plain
`ExUnit.Case` tail. M8a/M8b land partitioned local gates for core and
StockSage serial lanes; M9 adds the web `liveview_serial` lane and closeout
evidence. Each batch is validated against the v0.40 regression oracle. v0.45.1
separates commit, prepush, and release command semantics so `mix precommit` is
no longer release evidence.

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

- **2026-05-29 / after M7:** M7 completed its planned classification work but
  did not improve `fast-local` wall-clock (`25.25s` versus M6 `23.56s`) because
  static checks and process startup dominate the small pure lane. M8 is
  re-sequenced to attack measured hotspots first: M8a core intent/runtime
  DB/app-env/process partitioning, M8b StockSage objective/action partitioning,
  M8c low-risk pure cleanup/promotions only where they preserve or improve the
  measured gate. Web LiveView partitioning remains M9 because it has heavier
  ConnCase/process coupling and release-closeout documentation belongs there.
- **2026-05-29 / after M8b:** M8b improved the high-coverage local path for
  StockSage hotspots. The remaining low-risk pure cleanup/promotion batch is
  treated as optional/no-op unless it has a measured target; proceed to M9 web
  partitioning and closeout rather than spending the release on low-value pure
  churn.
- **2026-05-29 / after M9:** M9 improved coverage in the high-coverage local
  gate by adding partitioned web `liveview_serial` files while staying under the
  10 minute local target. The current slowest web report confirms that
  `WorkspaceLiveTest` remains the release long pole, but it stays
  `external_runtime_serial` until a later plan can split or passivate its
  runtime-heavy flows without weakening coverage.

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

### v0.41 M6 Gate Helpers Benchmark - 2026-05-29

- Commit: v0.41 M6 gate helpers commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after M6 task compilation.
- Commands:
  - `env MIX_ENV=test mix compile --warnings-as-errors`
  - `env MIX_ENV=test mix allbert.test inventory --output /private/tmp/v041-m6-inventory-2.csv`
  - `env MIX_ENV=test mix allbert.test partition-smoke --partitions 2`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local`
  - `env MIX_ENV=test ALLBERT_HOME=/private/tmp/allbert_v041_m6_web_alias_home DATABASE_PATH=/private/tmp/allbert_v041_m6_web_alias_db/allbert_test.db mix test test/allbert_assist_web/live/workspace_live_test.exs:1576`
  - `/usr/bin/time -p env MIX_ENV=test mix dialyzer`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test release`
- Release wall-clock / counts: final `mix allbert.test release` passed at
  `real 1268.73` seconds (`user 0.82`, `sys 4.11`). The release command runs
  `mix precommit` and then `mix dialyzer`. Counts: core 1146 tests, 0 failures,
  2 skipped; web 107 tests, 0 failures; StockSage 197 tests, 0 failures;
  channel plugins 2 tests, 0 failures; Dialyzer 0 errors. The first release
  attempt preserved the precommit oracle but failed the new Dialyzer phase on
  generated Jido plugin callback specs and the gate task `usage!/0`; both were
  fixed before the final run.
- Fast-local wall-clock / counts: final post-fix run passed at `real 23.56`
  seconds (`user 0.85`, `sys 4.82`). It ran static checks, migrate-only prep
  for each owned temp DB, and raw ExUnit shards for the current top-level
  `async: true` files: core 32 files / 164 tests, StockSage 5 files /
  29 tests, web 2 files / 10 tests, 0 failures.
- Lane breakdown: M6 intentionally does not retag or promote tests. The
  inventory command reproduces the M1 inventory exactly: 233 files plus header,
  with owner/lane counts unchanged. `fast-local` uses the current top-level
  `async: true` file set until M7 classification lands.
- Slowest modules/tests: not rerun for M6 because no suite migration landed; M1
  slowest evidence remains the sequencing authority for M7-M9.
- Planned share: reduce the M1 fast-local-equivalent sequential component from
  34.46s to <=25s by making the already-safe work one named parallel gate.
- Actual delta: effective. `fast-local` improved by 10.90s versus the M1
  sequential component, a 31.6% reduction, and met the <=25s M6 target.
- Decision: M6 is effective. Proceed to M7 without reordering.
- Follow-up/reorder: no reorder. The next planned work remains M7
  classification, then M8 core/StockSage hotspot partitioning before M9
  LiveView.

### v0.41 M7 Lane Classification Benchmark - 2026-05-29

- Commit: v0.41 M7 lane classification commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after M7 task compilation; docs edited while the final
  release oracle was running.
- Commands:
  - `env MIX_ENV=test mix compile --warnings-as-errors`
  - `env MIX_ENV=test mix allbert.test inventory --check-tags --output docs/developer/v0.41-test-inventory.csv`
  - lane spot checks using `mix do ecto.migrate.allbert --quiet + allbert.test.raw --only <lane> <file>` for `pure_async`, `app_env_serial`, and `db_serial`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test release`
- Release wall-clock / counts: final `mix allbert.test release` passed at
  `real 1347.18` seconds (`user 0.78`, `sys 3.99`). The release command runs
  `mix precommit` and then `mix dialyzer`. Counts: core 1146 tests, 0 failures,
  2 skipped, 830.0 seconds; web 107 tests, 0 failures, 290.5 seconds;
  StockSage 197 tests, 0 failures, 186.9 seconds; channel plugins 2 tests,
  0 failures, 0.03 seconds; Dialyzer 0 errors.
- Fast-local wall-clock / counts: passed at `real 25.25` seconds (`user 0.82`,
  `sys 3.71`). It ran static checks plus the reconciled primary `pure_async`
  lane: core 20 files / 85 tests, StockSage 4 files / 27 tests, web 2 files /
  10 tests, 0 failures.
- Lane breakdown: reconciliation passed for 233 files, zero unclassified, zero
  double-counts. Primary lane census remains `pure_async` 26, `db_serial` 66,
  `app_env_serial` 57, `home_fs_serial` 6, `global_process_serial` 19,
  `liveview_serial` 12, `security_eval_serial` 14,
  `external_runtime_serial` 33. The plain `ExUnit.Case` tail now has explicit
  primary `@moduletag`s, while shared templates provide default tags or
  `lane:` overrides.
- Slowest modules/tests: not rerun for M7 because it is metadata classification.
  M1 slowest evidence remains the sequencing authority.
- Planned share: 0 seconds of wall-clock improvement; M7 is effective if
  reconciliation is complete and lane filters select the intended files.
- Actual delta: classification effective, but not a speedup. `fast-local`
  regressed by 1.69s versus M6 (`25.25s` vs `23.56s`) despite narrower coverage,
  showing that static checks and process startup dominate this small lane.
- Decision: M7 is accepted only with a green release oracle; the reconciliation
  and lane filter evidence are complete.
- Follow-up/reorder: reorder M8 toward measured hotspots: M8a core
  intent/runtime DB/app-env/process partitioning, M8b StockSage objective/action
  partitioning, M8c low-risk pure cleanup/promotions only if the benchmark is
  preserved or improved. M9 remains LiveView/ConnCase partitioning and closeout.

### v0.41 M8a Core Lane Partitioning Benchmark - 2026-05-29

- Commit: v0.41 M8 core lane partitioning commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after M8 task compilation.
- Commands:
  - `env MIX_ENV=test mix compile --warnings-as-errors`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test serial-core --lane db_serial --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test serial-core --lane app_env_serial --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test serial-core --lane global_process_serial --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test serial-core --lane home_fs_serial --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local --core-lanes --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test release`
- Release wall-clock / counts: final `mix allbert.test release` passed at
  `real 1291.04` seconds (`user 0.76`, `sys 4.00`). The release command runs
  `mix precommit` and then `mix dialyzer`. Counts: core 1146 tests, 0 failures,
  2 skipped, 763.3 seconds; web 107 tests, 0 failures, 304.1 seconds;
  StockSage 197 tests, 0 failures, 184.8 seconds; channel plugins 2 tests,
  0 failures, 0.03 seconds; Dialyzer 0 errors.
- Fast-local wall-clock / counts:
  - quick default passed at `real 23.86` seconds (`user 0.78`, `sys 3.42`):
    static checks plus reconciled `pure_async` lane, 122 tests, 0 failures.
  - high-coverage core form passed at `real 263.84` seconds (`user 0.88`,
    `sys 4.12`): static checks, 122 pure-lane tests, and partitioned core
    `db_serial`, `app_env_serial`, `home_fs_serial`, and
    `global_process_serial` lanes, 830 executed tests, 0 failures.
- Lane breakdown:
  - `db_serial --partitions 4`: passed at `real 105.69`; partition counts
    56 / 48 / 141 / 41 tests, 0 failures.
  - `app_env_serial --partitions 4`: passed at `real 101.89`; partition counts
    99 / 37 / 98 / 62 tests, 0 failures.
  - `global_process_serial --partitions 4`: passed at `real 16.49`;
    partition counts 23 / 36 / 4 / 26 tests, 0 failures.
  - `home_fs_serial --partitions 4`: first exposed Mix's `--only` empty-shard
    failure; after `serial-core` accepted empty partition output, passed at
    `real 18.13`; partition counts 10 / 25 / 0 / 2 tests, 0 failures.
- Slowest modules/tests: M1 slowest evidence remains the sequencing authority.
  M8a directly targeted the core DB/app-env/process hotspots rather than
  producing a fresh slowest report.
- Planned share: M8a must make a high-coverage local core gate possible under
  the M8 <=10 minute target and measurably shrink the core slowest hotspot lane.
- Actual delta: effective. The quick gate improved 1.39s versus M7 (`23.86s`
  vs `25.25s`), and the high-coverage core gate covers 830 local tests in
  4.4 minutes instead of relying on the 22+ minute release oracle for those
  lanes.
- Decision: M8a is accepted only with a green release oracle; proceed to M8b
  StockSage objective/action partitioning without reordering.
- Follow-up/reorder: no reorder. The measured startup/build-lock and transient
  SQLite connection noise remain optimization signals, but they did not fail the
  partitioned lanes.

### v0.41 M8b StockSage Lane Partitioning Benchmark - 2026-05-29

- Commit: v0.41 M8 StockSage lane partitioning commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after M8b task compilation.
- Commands:
  - `env MIX_ENV=test mix compile --warnings-as-errors`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local --stocksage-lanes --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local --core-lanes --stocksage-lanes --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test release`
- Release wall-clock / counts: final `mix allbert.test release` passed at
  `real 1436.02` seconds (`user 0.74`, `sys 3.59`). The release command runs
  `mix precommit` and then `mix dialyzer`. Counts: core 1146 tests, 0 failures,
  2 skipped, 900.0 seconds; web 107 tests, 0 failures, 309.7 seconds;
  StockSage 197 tests, 0 failures, 187.7 seconds; channel plugins 2 tests,
  0 failures, 0.03 seconds; Dialyzer 0 errors.
- Fast-local wall-clock / counts:
  - StockSage high-coverage form passed at `real 131.32` seconds (`user 1.46`,
    `sys 4.50`): static checks, 122 pure-lane tests, and partitioned StockSage
    `db_serial`, `app_env_serial`, and `global_process_serial` lanes, 229
    executed tests, 0 failures.
  - combined core + StockSage high-coverage form passed at `real 374.05`
    seconds (`user 1.47`, `sys 4.80`): static checks, 122 pure-lane tests,
    partitioned core `db_serial`, `app_env_serial`, `home_fs_serial`, and
    `global_process_serial`, plus partitioned StockSage `db_serial`,
    `app_env_serial`, and `global_process_serial`, 937 executed tests,
    0 failures.
- Lane breakdown:
  - StockSage `db_serial --partitions 4`: partition counts 36 / 20 / 15 / 13
    tests, 0 failures. Slowest partition was 63.7 seconds in the focused
    StockSage run and 63.3 seconds in the combined run.
  - StockSage `app_env_serial --partitions 4`: partition counts 5 / 3 / 5 / 0
    tests, 0 failures. The empty explicit-file partition is accepted as green
    after path validation.
  - StockSage `global_process_serial --partitions 4`: partition counts
    3 / 2 / 5 / 0 tests, 0 failures. The empty explicit-file partition is
    accepted as green after path validation.
  - Exact plugin file selection removed the earlier support-file warnings from
    `plugins/stocksage/test/support/*`.
- Slowest modules/tests: M1 and M8a slowest evidence remains the sequencing
  authority. M8b targeted StockSage objective/action DB hotspots rather than
  producing a fresh slowest report.
- Planned share: M8b must make StockSage local serial hotspots available through
  the high-coverage local gate while keeping the combined core+StockSage gate
  under the M8 <=10 minute target.
- Actual delta: effective. The combined high-coverage local gate covers 937
  local tests in 6.2 minutes, below the M8 target and far below the 21+ minute
  release oracle. The full release gate is slower than M8a (`1436.02s` versus
  `1291.04s`), so release wall-clock remains a closeout optimization signal
  rather than the daily-loop win. StockSage local serial coverage is now
  benchmarkable without running the whole release gate.
- Decision: M8b is accepted with a green release oracle. Proceed to M9
  web/closeout; do not spend M8c on pure cleanup unless a measured regression
  appears.
- Follow-up/reorder: no reorder. Keep startup/build-lock waits and transient
  SQLite connection logs as M9 optimization signals, but do not block M8b on
  them because isolated DB/home roots and partition tests remained green.

### v0.41 M9 Web Lane Closeout Benchmark - 2026-05-29

- Commit: v0.41 M9 web lane closeout commit.
- Machine: `Darwin Sandeeps-Mac-Studio.local 25.5.0` on Apple M1 Ultra;
  20 physical / 20 logical CPUs.
- Runtime: Elixir 1.19.5 (compiled with Erlang/OTP 28), running on
  Erlang/OTP 29.0.1.
- Cache state: warm build after M9 task compilation.
- Commands:
  - `env MIX_ENV=test mix compile --warnings-as-errors`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local --web-lanes --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions 4`
  - `/usr/bin/time -p env MIX_ENV=test ALLBERT_HOME=/private/tmp/allbert_v041_m9_web_slowest_home DATABASE_PATH=/private/tmp/allbert_v041_m9_web_slowest_home/db/allbert_test.db mix test --slowest-modules 10 --slowest 10` from `apps/allbert_assist_web` after the shared core migration prep.
  - `/usr/bin/time -p env MIX_ENV=test mix allbert.test release`
- Release wall-clock / counts: final `mix allbert.test release` passed at
  `real 1263.32` seconds (`user 0.77`, `sys 4.47`). The release command runs
  `mix precommit` and then `mix dialyzer`. Counts: core 1146 tests, 0 failures,
  2 skipped, 717.3 seconds; web 107 tests, 0 failures, 306.0 seconds;
  StockSage 197 tests, 0 failures, 197.9 seconds; channel plugins 2 tests,
  0 failures, 0.03 seconds; Dialyzer 0 errors.
- Fast-local wall-clock / counts:
  - quick default passed at `real 22.94` seconds (`user 0.77`,
    `sys 3.15`): static checks plus reconciled `pure_async` lanes, 122 tests,
    0 failures.
  - web high-coverage form passed at `real 55.44` seconds (`user 1.03`,
    `sys 3.73`): static checks, 122 pure-lane tests, and partitioned web
    `liveview_serial`, 160 executed tests, 0 failures.
  - final combined local high-coverage form passed at `real 393.79` seconds
    (`user 1.65`, `sys 4.86`): static checks, 122 pure-lane tests, partitioned
    core DB/app-env/home/process lanes, partitioned StockSage DB/app-env/process
    lanes, and partitioned web `liveview_serial`, 975 executed tests,
    0 failures.
- Lane breakdown:
  - web `liveview_serial --partitions 4`: passed at `real 55.44`; partition
    counts 7 / 5 / 12 / 14 tests, 0 failures.
  - combined high-coverage local gate adds those 38 web tests to the M8b
    937-test local gate while remaining under the M8/M9 <=10 minute target.
- Slowest modules/tests: current web slowest report passed 107 tests,
  0 failures at `real 307.60` seconds. Slowest modules:
  `AllbertAssistWeb.WorkspaceLiveTest` 256.6s,
  `AllbertAssistWeb.ThemeControllerTest` 18.3s, and
  `AllbertAssistWeb.Workspace.AccessibilityTest` 14.2s. Slowest tests:
  Settings Central approve/deny/revoke 20.5s, settings destination 14.8s,
  provider key storage 10.9s, three-tab tile fanout 10.6s, layout override
  10.4s, AppBar Canvas destination links 10.0s, and runtime approval handoffs
  9-10s.
- Planned share: M9 must add web partition-safe coverage, record the after-done
  benchmark, keep quick fast-local under the M1 <=8 minute closeout target, and
  keep the combined non-security/non-external local gate under the M8/M9
  <=10 minute target.
- Actual delta: effective. Quick `fast-local` closes at 22.94s versus the M1
  34.46s fast-local-equivalent baseline. The final combined local gate covers
  975 local tests in 6.6 minutes, still well below the target; adding the web
  lane costs about 20 seconds versus M8b while improving local coverage.
- Decision: M9 is accepted with a green release oracle. v0.41 can close; future
  web efficiency work should split or passivate `WorkspaceLiveTest` under a new
  plan rather than smuggling it into fast-local.
- Follow-up/reorder: no reorder. The remaining release long pole is documented
  as `external_runtime_serial` web work, not a v0.41 fast-local blocker.

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
- Secondary blockers are recorded in the inventory resource classes and
  benchmark notes. Do not add a second primary lane tag for a blocker; a file
  with two primary lane tags fails reconciliation.
- Gates select lanes with `mix test --only <lane>` / `--exclude <lane>`; the lane
  tag values are the filter keys.

Reconciliation rule: after tagging, lane test-counts must sum to the full suite
total — zero unclassified files, no file double-counted.

The M2 taxonomy lock freezes this default mapping:

| Case/template | Default primary lane | Default async | Override path |
| --- | --- | --- | --- |
| `AllbertAssist.DataCase` | `db_serial` | `false` | `use AllbertAssist.DataCase, async: true, lane: :db_partition_safe` only after partition ownership is proven. |
| `StockSage.DataCase` | `db_serial` | `false` | Same as core DataCase, with plugin table cleanup remaining serial within a partition. |
| `AllbertAssistWeb.ConnCase` | `liveview_serial` | `false` | Use an explicit `lane:` only when a narrower non-LiveView resource class is proven. |
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
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only db_serial

# Any other VM-global lane — same lane-agnostic harness, own roots per partition
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only app_env_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only home_fs_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only global_process_serial
MIX_TEST_PARTITION=1 ALLBERT_HOME=/tmp/allbert-p1 DATABASE_PATH=/tmp/allbert-p1.db mix test --partitions N --only liveview_serial
```

The implementation wraps this in `mix allbert.test` so owner-specific test
support loads from the right app: core/StockSage serial lanes run from the core
app, while web `liveview_serial` runs from the web app via
`mix allbert.test fast-local --web-lanes --partitions N`. The invariant is fixed:
every partition has its own database, Allbert Home, migrated schema, and derived
runtime roots. `external_runtime_serial` stays an explicit smoke lane — it
touches shared OS resources (ports, Docker, real endpoints) that can collide even
across partitions.

Sparse lanes may produce an empty partition. Mix intentionally exits non-zero
when `--only <lane>` runs no tests; `mix allbert.test serial-core` treats that
specific empty-partition output as green because the shard is valid, while real
test failures still fail the lane.

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
| Docs | Docs-only changes. | `mix allbert.test docs` (`git diff --check` and reference checks when configured). |
| Focused | Every implementation milestone. | `mix allbert.test focused -- <files...>` using explicit files named in the plan/request-flow doc. |
| Static | Code changes. | compile warning gate, formatter check, Credo strict, Dialyzer when required. |
| Commit | Fast commit-time confidence. | `mix allbert.test commit`; `mix precommit` is a compatibility shortcut for this gate after v0.45.1. Not release evidence. |
| Prepush | High-coverage local handoff before sharing. | `mix allbert.test prepush`; uses partitioned local lanes and gate timing evidence. |
| Fast local | Daily development feedback. | `mix allbert.test fast-local`: static checks plus proven pure async lanes. After M9, `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions N` adds partitioned core DB/app-env/home/process lanes, StockSage DB/app-env/process lanes, and web `liveview_serial`. |
| Serial core | VM-global lanes (DB, app env, home, process, LiveView). | `mix allbert.test serial-core --lane <lane> --partitions N`; serial *within* a partition, parallel *across* OS partitions. Security evals + external smokes stay single-VM / opt-in. |
| Release | Manual validation/release handoff. | `mix allbert.test release`: explicit full-suite phases plus Dialyzer and timing/evidence. |
| External smoke | Machine-dependent integrations. | `mix allbert.test external-smoke -- <smoke-name>` for explicitly opted-in smokes. M6 implements Docker sandbox smokes; later browser/MCP/provider smokes must add their concrete command before use. |

### External Smoke Evidence Taxonomy

Plans that depend on package managers, Docker, browser drivers, provider
endpoints, real MCP servers, TTYs, or OS services must name which evidence class
they require. "External smoke" is a lane label, not a single proof strength.

| Evidence class | Proves | Does not prove |
| --- | --- | --- |
| Source gate | Checkout compiles, tests, migrations, evals, and release-specific source checks pass. | Published artifacts or package-manager installs execute. |
| Remote artifact matrix | CI-built archives boot and pass binary smoke on target runners. | Tap formula correctness, local package-manager install, or TTY interaction. |
| Package-manager install | Homebrew/curl install path fetches, verifies, installs, starts, tests, and uninstalls the packaged binary. | Real-host Linux service/vault behavior unless run on that host. |
| Containerized Linux package smoke | Linux artifacts install/start/attach/uninstall in Docker for a requested `--platform`. | Desktop Secret Service, user systemd, login-session, or distro-specific host policy unless explicitly provided inside the container. |
| Real-host OS service/vault | launchd/systemd and Keychain/Secret-Service behavior on the actual operator host. | Cross-architecture artifact coverage by itself. |
| TTY/TUI transcript | Interactive terminal behavior from a real packaged launcher. | Noninteractive CI readiness or provider/model quality. |

Evidence records must distinguish current-head/current-release proof from
historical proof. Historical runs can justify confidence and regression analysis,
but a release closeout row must record the current tag/commit/artifact id or say
why that row is intentionally historical.

M6 implements these gates in `Mix.Tasks.Allbert.Test`. The internal
`mix allbert.test.raw` task bypasses child-app `test` aliases only after the
outer gate has created an owned temp home/database and run migrations; developer
and release workflows should call `mix allbert.test ...`, not the raw helper
directly.

Plain `mix test` setup follows the same ownership model: the umbrella root
prepares the test database once through `mix ecto.migrate.allbert`, then child
app test aliases observe that preparation instead of rerunning migrations. Direct
child-app `mix test` still prepares its own database through the same Allbert
migration task. Do not add a separate `ecto.create` before test migrations:
SQLite database creation is handled by the Allbert migration path, which runs
with a single migration connection to avoid startup write-contention noise.

M7 extends `mix allbert.test inventory` with `--check-tags`, which verifies that
the committed inventory, shared case-template defaults, explicit lane overrides,
and plain-`ExUnit.Case` `@moduletag`s reconcile to exactly one primary lane per
test file.

Fast local, commit, and prepush gates are not release evidence. Release gates
remain authoritative. After v0.45.1, `mix precommit` is a compatibility shortcut
for `mix allbert.test commit`; release evidence is `mix allbert.test release` or
the active plan's version-specific release gate. The release gate remains a
superset of the v0.40 oracle green set and includes Dialyzer.

## v0.45.1 Gate Semantics Benchmark - 2026-06-02

- Purpose: complete the v0.41 semantic split by removing
  `release -> precommit -> dialyzer` delegation and making long gates timed and
  diagnosable.
- Commands implemented:
  - `mix allbert.test commit`
  - `mix allbert.test prepush [--partitions N]`
  - `mix allbert.test release` direct phase runner
  - `mix precommit` compatibility shortcut to the commit gate
- Diagnostic evidence: release/prepush evidence keeps bounded redacted JSON
  tails for summary readability and full redacted per-phase logs for failure
  triage. Failed Mix test phases also snapshot relevant `.mix_test_failures`
  manifests and record ExUnit seeds when present in output.
- Focused evidence:
  `MIX_ENV=test mix test apps/allbert_assist/test/mix/tasks/allbert_test_task_test.exs`
  passed with 6 tests, 0 failures.
- Commit-gate evidence:
  `MIX_ENV=test mix precommit` passed through the new commit gate in about 6s.
- Prepush evidence:
  `MIX_ENV=test mix allbert.test prepush` passed in 377s; the high-coverage
  partitioned fast-local phase passed in 370s.
- Version-specific release evidence:
  `MIX_ENV=test mix allbert.test release.v045` passed with deterministic v0.45
  marketplace evidence.
- Release wall-clock / counts: final `MIX_ENV=test mix allbert.test release`
  passed at 778s. Phase timings: static compile 2s, deps-unused 0s, format 2s,
  Credo 4s, core tests 364s, web tests 305s, StockSage tests 83s,
  channel/plugin tests 7s, Dialyzer 11s. Counts: core 1,339 tests, 0 failures,
  3 skipped; web 119 tests, 0 failures; StockSage 197 tests, 0 failures;
  channel/plugin 12 tests, 0 failures; Dialyzer 0 errors.
- Remaining long poles: core tests and web LiveView tests remain the dominant
  release phases. v0.45.1 makes them explicit and timed; it does not split
  those suites further.

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
3. Add the lane-agnostic per-partition database/home/roots harness; prove it on
   a small DB smoke and then on the expensive core intent/runtime DB and
   app-env lanes identified by M1.
4. Move StockSage objective/action lanes onto partition-safe DB/home roots once
   the core harness is stable.
5. Add unique-home helpers for low-cost filesystem-only tests opportunistically,
   but do not let them jump ahead of the measured hotspots.
6. Extend partitioning to LiveView/ConnCase last; the M1 report shows this is
   worth doing, but it has the heaviest sandbox/process coupling.
7. Keep security evals single-VM serial and external smokes opt-in until proven
   safe.

M5 locked the first implementation batch order after the M1 evidence. M7's
benchmark did not improve `fast-local`, so the M8 rows below are the
post-M7 reordered order:

| Batch | Target | Acceptance |
| --- | --- | --- |
| M6 | Gate commands, inventory command, and partition root helper. | Release gate reproduces v0.40 oracle; partition smoke proves owned DB/home roots. |
| M7 | Case-template default lane tags and plain-`ExUnit.Case` reconciliation. | Inventory has zero unclassified files and lane filters select expected files. |
| M8a | Core intent/runtime DB/app-env/process hotspots. | Partitioned local lane shrinks the core slowest hotspot without flakes. |
| M8b | StockSage objective/action DB hotspots. | Partitioned plugin lane shrinks StockSage slowest hotspot without flakes. |
| M8c | Existing `pure_async` lane cleanup and small pure promotions, only where the benchmark stays green or improves. | Optional/no-op after M8b unless a measured regression appears; avoid low-value churn. |
| M9 | Web LiveView/ConnCase partitioning, final metrics, and closeout docs. | Final fast-local target met; remaining `WorkspaceLiveTest` release long pole documented for a future plan. |

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
