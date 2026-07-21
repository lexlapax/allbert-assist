# ADR 0086: Test Global-State Ownership Conversion Contracts

## Status

Accepted at v1.0.3 M1 (2026-07-20, the commit that lands all five contracts
documented in `docs/developer/test-strategy.md` ("v1.0.3 M1 Conversion
Contracts") plus one red-first pilot conversion per convertible class:
contract 1 `objectives/objective_test.exs` → `db_partition_safe` with
non-shared checkout ownership and the `allow_sandbox/2` allowance helper;
contract 2 `intent/eval/gate_test.exs` → `pure_async` through
`AllbertAssist.ConfigContext`; contract 3 `actions/app_actions_test.exs` →
`pure_async` through the ADR 0082 injection seam with the two-context
negative proof; contract 4 `actions/browser_actions_test.exs` converted
within-class to the pid-qualified pre-cleaned owned-root idiom with the
ADR 0031 convert-vs-stay decision recorded as STAY; contract 5 documented
as the executable 2-VM experiment protocol for M6). Binding on v1.0.3
M1–M6 and on all future serial-test conversions.

## Context

Phase 1 (v1.0.2) proved the v0.53 thesis: slowness and flakiness share one
root cause — tests that touch global state are forced into serial lanes,
and the serial lanes are the measured wall-clock floor (packed max
partitions: db_serial 123.8 s / 112 files, app_env_serial 134.3 s / 116,
external_runtime ~8 min single-VM; store-cited). Partition packing (M8.8)
exhausted the assignment lever; further reduction requires changing HOW
tests isolate. The same root cause produces the two remaining monolith-only
failure classes (SidebarConsolidation DBConnection ownership 20/20 seeds;
ListChannels registry propagation 7/20).

The risk of conversion is silent test-feature loss: a test "converted" by
weakening its assertions, retrying, or skipping under composition is a
regression disguised as a speedup. Phase 1's discipline (red-first, measured
pre/post, identical-totals proofs) must bind conversions too.

## Decision

Five class contracts. A serial test converts ONLY through its class
contract — no bespoke per-file isolation inventions. Every conversion
carries: (a) a red-first proof of the pre-conversion serial requirement,
(b) a reviewed test-body diff proving no assertion was removed or weakened,
(c) solo ×3 + both-orders composition green, (d) per-test identity, lane,
skip, and multiplicity equivalence in `inventory --check-manifest`, plus
classification in `--check-tags`, and (e) store-cited pre/post.

1. **Sandbox checkout ownership (db class).** `DataCase` already starts an
   `Ecto.Adapters.SQL.Sandbox` owner per test. The missing contract is
   allowance propagation to every spawned process (LiveView mounts, Tasks,
   agents, delegate calls) plus an empirical SQLite concurrency verdict.
   **VERDICT ANSWERED (v1.0.3 M4, 2026-07-20):** lane concurrency cannot be
   bought by raising `--max-cases` alone — ExUnit schedules only
   `async: true` tests concurrently, and every serial-lane test is
   `async: false`, so a 1-vs-4 A/B over 86 liveview tests measured
   identical walls (1,132 s, `0.00s async`). Conversion to `async: true`
   through this contract is the PRECONDITION; the runner's per-lane
   `--max-cases` lift is a required follow-on for DB-backed lanes and
   applies only to lanes whose files are converted. `pure_async`
   conversions need no lift.
   Repo-backed tests do not become `pure_async`; successful candidates use
   `db_partition_safe` unless the taxonomy and runner are deliberately
   amended with evidence. SQLite's single-writer reality stays respected:
   `busy_timeout` bounds are part of the contract, and a file whose
   semantics require cross-process shared writes records that reason and
   stays serial.
2. **Process-scoped app-env context (app_env class).** Add one internal
   configuration-context shape:
   `config_context: [home: path, settings_root: path, app: keyword]`.
   `home` and `settings_root` override only their corresponding Paths reads;
   `app` is the allowlisted module/key configuration needed by the converted
   path, never arbitrary application state. It is passed explicitly at
   public internal seams and installed process-locally only within a bounded
   test/runtime call; Tasks,
   LiveViews, agents, and supervised children receive it explicitly.
   `Store.with_resolved_settings/1` remains a validated-read snapshot and
   ADR 0082 `RegistryContext` remains registry selection—neither substitutes
   for app-env writes. Production omission preserves current defaults.
   Negative concurrent tests prove two contexts cannot cross-contaminate.
   **RESIDENCY PROOF REQUIRED (amended v1.0.3 M5(a), 2026-07-20).** A
   conversion MUST assert positively that the artifact it writes lands under
   the owned root — e.g. `assert File.exists?(Path.join(owned_root, …))` or
   an equivalent on-disk/DB check — in addition to the behavioural
   assertions. Rationale, paid for by M5(a): the Confirmations gap passes
   solo ×3 AND both-orders composition while writing to the SHARED home,
   because `pending_path/1` is an in-process delegate that reports the owned
   home regardless of where the singleton `Store.Agent` actually writes.
   Behavioural assertions read the delegate and stay green, so the old proof
   set cannot distinguish a correct conversion from silent cross-test
   corruption. Three files were fully "proven" before a probe caught this;
   one sibling went red only on its third solo run. Solo ×3 + composition is
   NECESSARY BUT NOT SUFFICIENT for contract 2.
   A file whose exercised production path still
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
ownership root (for Sidebar: the ownership-LEASE derivation landed at
v1.0.3 M2 — contract 1's allowance propagation is real and used elsewhere,
e.g. the M1 db pilot's engine-agent allowance, but the Sidebar class turned
out to be lease expiry, corrected here after measurement; ShippedRegistries
or private-context convergence plus `ListChannels.run/2` forwarding registry
opts to `Channels.list_channels/1` for ListChannels) — never by
retries, deletions, or monolith-specific skips. The planned 20-seed RC
campaign was not run. By explicit operator acceptance on 2026-07-20, v1.0.3
uses two clean banked monolith seeds plus the two permanent focused guards as
its bounded evidence for these known roots. This is a narrower risk posture,
not evidence equivalent to an exhaustive randomized campaign.

## Consequences

- A successful future conversion grows the `pure_async` group or a deliberately
  concurrent DB lane, and the packer exploits files that leave serial bins.
  v1.0.3's bounded M5 attempts shipped no conversion wave: M5(a) was parked
  after a red concurrency ceiling and no material max-partition movement;
  M5(b) stopped with zero files converted after exposing production seams.
- `DataCase`/case templates gain an ownership-mode axis; existing serial
  tests are untouched until their wave.
- Some files will legitimately never convert (shared-write semantics,
  recorded seam gaps, ADR 0031 boundary) — the contracts make "stays
  serial" an explicit recorded outcome instead of an implicit default, so
  the residual serial set is exactly the honest floor.
- the committed manifest is the no-loss ledger; `check-tags` separately
  proves lane-classification validity.
- The monolith stops being the only composition that reproduces the two
  classes — their minimal-composition repros become permanent regression
  tests in the gate surface.

## Validation

- v1.0.3 M1: all five contracts documented in test-strategy + four
  successful red-first pilots (one per convertible class) green solo ×3 and
  both orders + an executable external-runtime experiment contract; ADR
  flips Accepted.
- v1.0.3 M2/M3: minimal-composition repros for both monolith classes
  red-first, then green; 5-seed spot campaigns without the signatures.
- v1.0.3 M4–M6 actual disposition: M4/M5 recorded the confounded-runner
  correction, the parked app-env patch, the zero-conversion LiveView stop, and
  the no-loss/tree-identity proofs. The production prerequisites and 2-VM
  external-runtime experiment remain intake candidates pending later operator
  disposition; no lane-floor reduction or experiment verdict is claimed for
  v1.0.3.
- v1.0.3 M9: two clean banked monolith seeds plus permanent
  `v103_sidebar_ownership` and `v103_list_channels_context` steps replace the
  planned 20-seed campaign by explicit operator acceptance; `release.v103`
  binds the pilots, repros, inventory reconciliation, and manifest drift guard.
