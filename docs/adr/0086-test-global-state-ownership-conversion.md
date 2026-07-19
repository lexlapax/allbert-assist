# ADR 0086: Test Global-State Ownership Conversion Contracts

## Status

Proposed (v1.0.3 planning, 2026-07-19). Binding on v1.0.3 M1–M6 once
Accepted; Accepted at M1 in the commit that lands all five contracts plus
one red-first pilot conversion per convertible class.

## Context

Phase 1 (v1.0.2) proved the v0.53 thesis: slowness and flakiness share one
root cause — tests that touch global state are forced into serial lanes,
and the serial lanes are the measured wall-clock floor (packed max
partitions: db_serial 123.8 s / 112 files, app_env_serial 134.3 s / 116,
external_runtime ~8 min single-VM; store-cited). Partition packing (M8.8)
exhausted the assignment lever; further reduction requires changing HOW
tests isolate. The same root cause produces the two remaining monolith-only
failure classes (SidebarConsolidation DBConnection ownership 20/20 seeds;
ListChannels registry/SurfacePolicy 7/20).

The risk of conversion is silent test-feature loss: a test "converted" by
weakening its assertions, retrying, or skipping under composition is a
regression disguised as a speedup. Phase 1's discipline (red-first, measured
pre/post, identical-totals proofs) must bind conversions too.

## Decision

Five class contracts. A serial test converts ONLY through its class
contract — no bespoke per-file isolation inventions. Every conversion
carries: (a) a red-first proof of the pre-conversion serial requirement,
(b) unchanged assertions (identity review), (c) solo ×3 + both-orders
composition green, (d) lane-total equivalence in `inventory --check-tags`,
(e) store-cited pre/post.

1. **Sandbox checkout ownership (db class).** `DataCase` gains an
   async-capable mode: explicit `Ecto.Adapters.SQL.Sandbox` checkout per
   test with allowance helpers for every spawned process (LiveView mounts,
   Tasks, agents, delegate calls). The pool is already
   `Ecto.Adapters.SQL.Sandbox` (config/test.exs); what phase 1 never did is
   exercise per-test ownership. SQLite's single-writer reality stays
   respected: `busy_timeout` bounds are part of the contract, and a file
   whose test semantics genuinely require cross-process shared writes
   records that reason and stays serial.
2. **Process-scoped app-env context (app_env class).** Reads move to the
   pinned/context path (`Store.with_resolved_settings/1`, ADR 0082
   `RegistryContext`); writes become per-test pins, never global
   `Application.put_env`. A file whose exercised PRODUCTION path still
   reads a global records the seam gap (the engine `channel_candidates`
   list seeds this) and stays serial — the gap list is the phase-3 intake,
   not a silent skip.
3. **Named-process injection (global_process class).** The ADR 0082
   pattern generalized: test-facing constructors accept a name/registry
   override; tests use pid-qualified unique names. Supervised singletons
   that cannot take an override yet get the seam recorded.
4. **Per-test filesystem homes (home_fs class).** The pid-qualified
   pre-cleaned per-test home idiom (M8.3, swept repo-wide in M8.7) plus
   env-triple ownership. The ADR 0031 global-read boundary (browser_actions
   class) is decided here: convert only if the read can take context
   without weakening the ADR 0031 validation contract; otherwise stay with
   reason.
5. **External-runtime partitioning (external_runtime class).** These tests
   are serial because the runtime is REAL (browser, OS processes, ports) —
   they are never converted to async. The only lever is multi-VM
   partitioning with fully owned envs (per-VM homes/DBs/ports), accepted
   only on three consecutive green runs plus no cross-VM interference
   evidence; otherwise the measured no-go is recorded and the lane stays
   single-VM. Honest floor over flaky split.

**Monolith-class corollary.** The two residual classes are fixed at the
ownership root (contract 1 allowance threading for Sidebar; ShippedRegistries
convergence + contract-2/3 context adoption for ListChannels) — never by
retries, deletions, or monolith-specific skips. Acceptance is the rerun
campaign at zero occurrences.

## Consequences

- The pure_async group grows wave by wave; the packer immediately exploits
  every conversion (converted files leave serial bins entirely) — speed
  gains compound without re-tuning.
- `DataCase`/case templates gain an ownership-mode axis; existing serial
  tests are untouched until their wave.
- Some files will legitimately never convert (shared-write semantics,
  recorded seam gaps, ADR 0031 boundary) — the contracts make "stays
  serial" an explicit recorded outcome instead of an implicit default, so
  the residual serial set is exactly the honest floor.
- check-tags becomes the no-loss ledger: every wave's lane moves are
  visible as re-tags with identical totals.
- The monolith stops being the only composition that reproduces the two
  classes — their minimal-composition repros become permanent regression
  tests in the gate surface.

## Validation

- v1.0.3 M1: contracts documented in test-strategy + four red-first pilots
  (one per convertible class) green solo ×3 and both orders; ADR flips
  Accepted.
- v1.0.3 M2/M3: minimal-composition repros for both monolith classes
  red-first, then green; 5-seed spot campaigns without the signatures.
- v1.0.3 M4–M6: per-wave no-loss proofs + measured lane reductions vs the
  M0 baseline (store-cited); external-runtime experiment verdict recorded
  with evidence either way.
- v1.0.3 M8: 10-seed campaign — retired classes 0/10, no new signatures;
  `release.v103` binds the pilot + repro + no-loss checks.
