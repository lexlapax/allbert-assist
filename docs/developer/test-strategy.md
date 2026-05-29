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
