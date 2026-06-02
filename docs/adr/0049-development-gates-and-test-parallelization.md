# ADR 0049: Development Gates And Test Parallelization

## Status

Proposed for v0.41 Developer Velocity And Parallel Test Methodology
(`docs/plans/v0.41-plan.md`). Accepted before any Mix alias, test helper, or
test tag migration lands. Amended by v0.45.1 Gate Transparency And Precommit
Decomposition (`docs/plans/v0.45.1-plan.md`).

## Context

Allbert is built on Elixir/OTP because supervised concurrency, cheap processes,
and explicit resource ownership are core to the product vision. The development
loop should reflect that same discipline.

As of v0.40, the release gate is strict but slow. `mix precommit` is a
monolithic serial sequence over compile, format, Credo, core tests, web tests,
and plugin/channel tests. During v0.40 closeout it passed, but took roughly 22
minutes locally. The suite is not slow because Elixir cannot run work
concurrently; it is slow because many tests touch resources that are currently
global or single-writer:

- SQLite through `Ecto.Adapters.SQL.Sandbox`
- shared `Application` environment
- shared Allbert Home and derived settings/secrets/memory/tmp roots
- named processes, registries, supervisors, and PubSub topics
- global HTTP/test stubs such as Req/Mox-style adapters
- filesystem cleanup and generated fixture roots
- LiveView tests with Repo ownership and process trees
- security evals and external runtime smokes

Making every test `async: true` would create flakes and hide real isolation
problems. Keeping every test serial makes iteration increasingly expensive.

The same problem exists one level higher in implementation planning. A milestone
plan that lists work sequentially gives a coding agent no principled way to
split implementation, docs, tests, browser/manual checks, and serial resources
into safe parallel lanes. Implementation-ready plans need explicit concurrency
annotations, not just feature checklists.

## Decision

### 1. Precommit is a gate matrix, not one undifferentiated concept

Allbert keeps a full release gate, but development docs and future Mix aliases
must distinguish:

- docs-only gate
- focused milestone gate
- fast local gate
- serial core gate
- full release gate
- opt-in external smoke gate

Milestone plans must name focused tests and serial-resource exposure. A full
release gate remains required for release closeout and any milestone whose blast
radius crosses shared runtime/security behavior.

### 2. Async eligibility is proven by owned resources

A test module may be `async: true` only when it owns or avoids every resource it
touches:

- no shared database writes
- no global app-env mutation
- no shared Allbert Home or default database path
- no fixed global process name or registry key
- no shared HTTP/provider stub
- no unbounded filesystem cleanup
- no external runtime dependency

Tests that cannot prove ownership stay serial. Speed alone is not evidence.

### 3. VM-global tests parallelize by OS-process partition, not in-VM async

Tests parallelize on two axes. Pure tests run `async: true` concurrently in one
BEAM VM (`--max-cases`). VM-global tests — those touching `Application` env,
named processes/registries/PubSub, shared Allbert Home roots, the SQLite
database, or LiveView/Repo trees — are NOT in-VM-async-safe; they parallelize
across OS-process partitions, where each partition is a separate BEAM VM that
isolates all of that state. Each partition owns its:

- `MIX_TEST_PARTITION`
- `DATABASE_PATH`
- `ALLBERT_HOME` / `ALLBERT_HOME_DIR`
- migrated database
- derived settings, secrets, memory, sandbox, and tmp roots

The harness is lane-agnostic: the same per-partition roots make any VM-global
lane partition-parallel, not only DB. With `server: false` in test config there
is no endpoint-port collision, so LiveView/Conn tests partition too. SQLite is a
special case with an added constraint — it is single-writer, so DB tests stay
serial within a partition (its own file); the speedup is partition count, never
async-within-partition. This follows ExUnit's partitioning model instead of
pretending one SQLite file is a safe multi-writer async substrate.

### 4. Serial lanes are explicit, not shameful

Some tests should remain serial because they validate global behavior:

- Security eval harnesses
- LiveView process/Repo ownership flows
- global settings and startup behavior
- supervised singleton restart behavior
- external runtime smokes such as Docker, browser drivers, real MCP servers, or
  provider endpoints

Serial here means serial *within* a VM or partition. Per §3, most of these lanes
still parallelize across OS partitions when each partition owns its roots;
security eval harnesses and external runtime smokes stay single-VM / opt-in until
separately proven. The goal is not "everything async"; the goal is high signal,
low flake, and short feedback loops.

### 5. Test strategy is a first-class developer contract

`docs/developer/test-strategy.md` is the canonical test-lane contract. It must
name the lane taxonomy, ownership rules, isolation contract, migration order,
and rollback process. `DEVELOPMENT.md` and `AGENTS.md` route agents and humans
to that contract.

### 6. Implementation plans carry development-lane annotations

When an agent creates, audits, or marks a plan implementation-ready, each
milestone must document:

- parallelizable workstreams, such as docs, schema, pure code, focused tests,
  UI/manual validation, or external smoke setup;
- serial barriers, such as SQLite migrations, global app env, shared Allbert
  Home roots, named processes, LiveView/Repo ownership, security evals, or
  single-release evidence gates;
- the focused test gate, serial lane, external smoke, and release gate evidence;
- ordering constraints between lanes and the point where results must rejoin
  before commit, release closeout, or manual validation.

A plan without these annotations is not implementation-ready after v0.41. The
annotations are guidance for concurrency, not permission to skip the full
release gate. The requirement applies to plans authored or audited after v0.41;
existing downstream plans (v0.42 onward) are back-filled with annotations at the
start of their own implementation, and v0.42 is back-filled during v0.41 as the
worked example.

### 7. v0.41 migrates the existing suite onto the lanes, against a fixed oracle

v0.41 is not only methodology: after the M1-M5 design pass, M6-M9 implement the
gate matrix and isolation helpers and migrate the existing suite onto the lanes.
Because that touches essentially every test, the migration is bounded and
de-risked by two rules:

- **Case-template default classification.** Lanes and `async` defaults are set on
  the shared case templates first; per-file `@moduletag` overrides are reviewed
  exceptions, not the norm. This keeps the change reviewable instead of a blanket
  rewrite of every test file.
- **The v0.40 closeout is the regression oracle.** Current-main commit
  `f81d13d`'s green `mix precommit` set is reproduced through the full release
  gate at every batch before acceptance; the monolithic v0.40 serial precommit
  remains the runnable fallback gate for flake triage and rollback. No batch
  trades coverage for speed.

### 8. Efficiency is benchmarked, and milestone order is adaptive

The velocity win is measured, not assumed. v0.41 records a BEFORE benchmark,
re-runs it after each implementation milestone, and again at closeout. Each
implementation milestone has a planned share of the wall-clock target; a milestone
that does not improve `fast-local` wall-clock effectively — or whose latest
slowest-module report points at an unscheduled hotspot — triggers re-sequencing of
the remaining milestones/batches toward the measured hotspots. Benchmark records
and reorder decisions live in `docs/developer/test-strategy.md` with exact
commands, machine context, counts, wall-clock, slowest modules/tests, planned
share, actual delta, and follow-up. Reordering is bounded by §7: every batch still
reproduces the v0.40 oracle green set, so efficiency is never bought with
coverage.

### 9. v0.45.1 separates commit, prepush, and release command semantics

The v0.41 implementation deliberately preserved the v0.40-style monolithic
`mix precommit` alias as the runnable fallback oracle while the new lane matrix
landed. v0.45.1 completes the semantic split:

- `mix allbert.test commit` is fast commit-time confidence. It is not release
  evidence.
- `mix precommit` is a compatibility shortcut for `mix allbert.test commit`.
  It is no longer documented as release evidence after v0.45.1.
- `mix allbert.test prepush` is high-coverage local handoff before sharing. It
  uses the partitioned local lane machinery and timing evidence.
- `mix allbert.test release` is the authoritative release handoff. It runs
  explicit full-suite phases plus Dialyzer directly and does not delegate to
  `mix precommit`.
- Version-specific gates such as `mix allbert.test release.v045` remain
  deterministic feature-surface release evidence.

This preserves strictness while removing the ambiguous word "precommit" from
release closeout. A release remains blocked until the explicit release gate is
green.

## Consequences

- A later implementation may add Mix aliases or scripts for lane orchestration,
  but this ADR defines the semantics first.
- Existing strictness is preserved: the full release gate remains authoritative.
- Fast local development becomes legitimate without pretending it is release
  evidence.
- Commit-time development becomes legitimate without pretending `mix precommit`
  is release evidence.
- Gate timing and bounded redacted output tails become part of release evidence
  so long runs are diagnosable instead of opaque.
- Async conversion becomes reviewable. A change from `async: false` to
  `async: true` must explain resource ownership or helper isolation.
- Per-partition database/home roots become prerequisite infrastructure before DB
  lanes are parallelized.
- Plan readiness reviews become more concrete: they must identify safe parallel
  development/testing lanes and explicit serial chokepoints before implementation
  starts.
- No extra ADR is required for v0.41 unless implementation changes the gate
  semantics, introduces a persistent test scheduler/CI topology, or adds a new
  authority boundary for development tooling.

## Non-Goals

- No code, alias, helper, or test-tag changes in the v0.41 M1-M5 planning pass;
  those land in the M6-M9 implementation pass, each validated against the v0.40
  oracle.
- No move away from SQLite.
- No weakening of Security Central evals or release gates.
- No hidden external smokes inside normal local precommit.
- No claim that all tests should become async.

## Relates To

- ADR 0005 - Canonical Allbert Home.
- ADR 0006 - Security Central.
- ADR 0012 - Resource Access Security Posture.
- ADR 0037 - Elixir/OTP sandbox backend and gate runner.
- ADR 0046 - Settings schema migration policy.
- ADR 0050 - Vendored Memento compatibility override.
- `DEVELOPMENT.md` milestone workflow.
- `AGENTS.md` agent workflow.
- `docs/developer/agent-context-map.md`.
- `docs/developer/test-strategy.md`.
