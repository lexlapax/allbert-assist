# ADR 0081: Tier-2 → Tier-1 Contract Promotion Process

## Status

Accepted at v1.0.2 M6 (2026-07-16, docs-only). Changes no code and no current
tier assignment; `public-contract-freeze.md` references this process and
records that v1.0.2 promotes no contract.

## Context

The v1.0 freeze (`docs/developer/public-contract-freeze.md`, `release.v1` gate)
defined two tiers: **Tier 1 — frozen public contracts** (exact-name existence
enforced by the `:v1` sweep; changes require a major version) and **Tier 2 —
stabilizing contracts** (frozen with carve-outs; evolve additively only). The
freeze deliberately left the promotion path undefined: how does a Tier-2
contract that has proven stable become Tier-1, with the stronger guarantee and
the sweep row that enforces it? The roadmap parks "Tier-2→Tier-1 promotion ADR
(docs)" on the 1.0.x train; the operator scoped it into v1.0.2.

## Decision

1. **Promotion criteria.** A Tier-2 contract is eligible for promotion when ALL
   hold:
   - it has shipped unchanged across at least **two released minors**. Unchanged
     means no rename, removal, semantic narrowing, incompatible shape change, or
     dependency on undocumented behavior. Additive growth does not reset the
     clock unless it changes the core proposed for promotion. Earlier promotion
     requires its own ADR with explicit equivalent stability evidence; an
     undocumented operator waiver is not sufficient;
   - it is exercised by at least one **gate-bound** proof (an eval row,
     sweep assertion, or release-gate step that fails on rename/removal);
   - no open intake entry in `future-features.md` proposes redesigning it;
   - promoting it does not depend on another Tier-2 contract staying mutable
     (promote dependency-first or together).
2. **Promotion mechanics — one change, three artifacts.** A promotion ships as
   a single reviewed change containing:
   - a **dedicated ADR per contract or inseparable contract group** naming the
     exact frozen names, behaviors/shapes, and eligibility evidence; this ADR's
     ledger indexes that promotion ADR;
   - the **freeze-sweep row(s)**: the `:v1` exact-name sweep
     (`test/security/v1_sweep_eval_test.exs`) gains exact-name assertions plus
     behavioral/shape assertions wherever name existence alone would not enforce
     the promoted guarantee;
   - the **`public-contract-freeze.md` move**: the contract's entry relocates
     from the Tier-2 section to Tier-1 verbatim, with the promotion date and
     ADR reference.
3. **Post-promotion rules.** The promoted contract immediately inherits Tier-1
   semantics: any breaking change (rename, removal, shape change) requires a
   **major version** and its own ADR. Additive extension remains allowed where
   the contract's own definition permits it.
4. **No demotion.** Tier-1 → Tier-2 movement does not exist; retiring a Tier-1
   contract is a breaking change gated on a major version. Tier-2 contracts
   that turn out wrong are redesigned additively or superseded via intake, not
   silently mutated.
5. **Cadence.** Promotion review is not scheduled busywork: it happens when a
   release plan touches a Tier-2 contract, or when the operator requests a
   sweep. Each promotion is recorded in the ledger below.

## Promotion Ledger

| Date | Contract | Evidence | Sweep rows | Release |
|---|---|---|---|---|
| — | (none yet) | | | |

## Consequences

- Tier-2 contracts have a defined, evidence-based path to the stronger
  guarantee; consumers can see exactly when and why a contract hardened.
- The `release.v1` gate remains the single enforcement point — a promotion is
  not real until its sweep row exists.
- The major-version rule gains teeth incrementally: each promotion enlarges
  the surface that forces a major on breaking change, which is the intended
  ratchet toward a stable 1.x platform.

## Validation

Docs-only at v1.0.2: `mix allbert.test docs` green;
`public-contract-freeze.md` reconciled to reference this process. The first
actual promotion validates the mechanics end-to-end (ADR + sweep row + freeze
doc move in one change, `release.v1` green before and after).
