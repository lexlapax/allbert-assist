# Allbert Test Strategy

This is the developer contract for test isolation, lane classification, and
future precommit parallelization. It also defines the planning annotations that
make implementation milestones safe to parallelize.

Status: introduced for v0.41 planning. The taxonomy below is binding; the exact
Mix aliases and tag migrations land in the v0.41 implementation.

## Current Baseline

The v0.40 closeout gate showed the problem clearly:

- full `mix precommit` passed but took roughly 22 minutes locally
- core app suite: 1146 tests, 0 failures, 2 skipped
- web suite: 107 tests, 0 failures
- plugin/channel suites: 197 tests and 2 tests, 0 failures
- repository sweep found many serial resources: SQLite sandbox, global app env,
  shared Allbert Home roots, named processes, HTTP stubs, filesystem cleanup,
  LiveView/Repo ownership, and security eval harnesses

M1 of v0.41 must replace this preliminary baseline with an authoritative
inventory containing file path, owner, case template, async setting, tags, timing,
and resource classes.

## Lane Taxonomy

Every test file gets one primary lane.

| Lane | Meaning | Default execution |
| --- | --- | --- |
| `pure_async` | Pure or locally-owned tests with no global runtime resources. | Async in one VM. |
| `db_serial` | Uses shared Repo/SQLite sandbox or database-backed contexts. | Serial unless partition-isolated. |
| `app_env_serial` | Mutates `Application` env, config, or compile/runtime app state. | Serial unless helper scopes and restores ownership. |
| `home_fs_serial` | Mutates Allbert Home, settings, secrets, memory, sandbox, plugin, or tmp roots. | Serial unless roots are unique per test/partition. |
| `global_process_serial` | Uses fixed process names, registries, PubSub topics, supervisors, or singleton restart behavior. | Serial unless names are unique and owned. |
| `external_runtime_serial` | Uses Docker, browser drivers, stdio ports, provider endpoints, real MCP servers, package managers, or OS resources. | Explicit smoke lane. |
| `liveview_serial` | Uses Phoenix LiveView/ConnCase with Repo ownership or shared process trees. | Serial unless separately proven. |
| `security_eval_serial` | Uses `SecurityEvalCase`, eval inventory, adversarial fixtures, or cross-boundary security assertions. | Serial/release lane by default. |

Secondary blockers should be recorded separately. Example: a test may be primary
`db_serial` with secondary `home_fs_serial`.

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

## SQLite And Partitioning

SQLite-backed tests are not async-safe merely because Ecto has a sandbox.
Allbert keeps `DataCase` and `ConnCase` serial by default inside one BEAM VM.

DB parallelism requires OS-process partitioning:

```sh
MIX_TEST_PARTITION=1 DATABASE_PATH=/tmp/allbert-p1.db ALLBERT_HOME=/tmp/allbert-p1 mix test --partitions 4
MIX_TEST_PARTITION=2 DATABASE_PATH=/tmp/allbert-p2.db ALLBERT_HOME=/tmp/allbert-p2 mix test --partitions 4
MIX_TEST_PARTITION=3 DATABASE_PATH=/tmp/allbert-p3.db ALLBERT_HOME=/tmp/allbert-p3 mix test --partitions 4
MIX_TEST_PARTITION=4 DATABASE_PATH=/tmp/allbert-p4.db ALLBERT_HOME=/tmp/allbert-p4 mix test --partitions 4
```

The implementation may wrap this in a Mix alias or script, but the invariant is
fixed: every partition has its own database, Allbert Home, migrated schema, and
derived runtime roots.

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
| Serial core | Shared-resource tests. | DB/app-env/home/process/security lanes, intentionally serial. |
| Release | Manual validation/release handoff. | Full precommit-equivalent coverage plus Dialyzer and security evals. |
| External smoke | Machine-dependent integrations. | Docker, browser, real MCP/provider checks, explicitly opt in. |

Fast local gates are not release evidence. Release gates remain authoritative.

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

1. Produce the inventory and slowest-module report.
2. Convert obvious `pure_async` candidates only.
3. Add unique-home helpers for filesystem-only tests.
4. Add per-partition database/home roots before parallelizing DB tests.
5. Revisit LiveView/process-heavy tests after DB partitioning is stable.
6. Keep security evals and external smokes serial until proven safe.

If a converted lane flakes, move it back to serial first, then fix the ownership
contract before trying again.

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
