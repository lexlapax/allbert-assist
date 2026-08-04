# v1.3 Memory — What A Human Drove, And What Rests On Tests

v1.3 ships the full Memory surface by operator decision on 2026-08-03
(`docs/plans/v1.3-plan.md`, M9.b.13). That decision came with an obligation: an
operator reading the release evidence should be able to tell which parts of
Memory a human actually exercised and which parts rest on unit coverage alone.
This file is that disclosure. It is not a caveat buried in a plan.

## Why this file exists

Five product defects were found in Memory during M9.b, and **not one was caught
by a test**. Four surfaced in attended operator validation; three more came from
the audit that followed. All five reduce to one root — the projection's
consistency with canonical state depended on explicit call sites, and the set was
incomplete — which `Memory.ProjectionSync` and the
`claim_writer_propagation_test` census now close.

Coverage was raised in response: every Memory module now has direct test rows,
down from seven with none. That closes the class going forward. It does not
retroactively turn unit coverage into operator evidence, which is why the
distinction below is stated rather than blurred.

## Operator-exercised, v1.3 attended source validation

Run on a fresh disposable Home at `88c36187e`, daemon 6601, on 2026-08-03. The
setup steps above SV-6D were agent-run, so this is a targeted re-test of the
M9.b.10 and M9.b.11 fixes rather than a full acceptance row; the acceptance run
remains a complete SV-0 through SV-9.

| Subcommand | Row | Result |
| --- | --- | --- |
| `memory consolidate` | SV-6B.2 | PASS — 3 sources scanned, 1 proposal |
| `memory proposals` | SV-6B.3 | PASS — fake credential and assistant guess both absent |
| `memory proposal` | SV-6B.4 | PASS — `context_messages=2`, provenance rehydrates |
| `memory proposal-review` | SV-6B.5 | PASS — revision and digest pinned |
| `memory retrieve` | SV-6C | PASS — current and explicit bi-temporal, same chunk |
| `memory archive` | SV-6D.1/6D.2 | PASS — preview moves nothing; approved archive drops to 0 chunks and 0 candidates |
| `memory restore` | SV-6D.3 | PASS — retrievable again immediately, no rebuild wait |
| `memory forget` | SV-6D.4/6D.5 | PASS — all four disclosure clauses; logically enforced |
| `memory list` | SV-6D | PASS — used as a read-only inspection |
| `memory show` | SV-6B.4 | PASS |
| `memory status` | SV-6D | PASS — reports v0.65 review counts |

Search, Jobs, and canonical deletion around Memory were also operator-exercised:
SV-6E.1–6E.3, SV-7A.1–7A.5, SV-8A.1–8A.6, SV-9. SV-7B and SV-8B are recorded
`UNAVAILABLE` against a verified channel list — every non-TUI channel reads
`enabled=false`, `credentials=missing`, `identities=0`.

## Not operator-exercised — covered by tests only

These nine subcommands ship in v1.3 and were **not** driven by a human during
attended validation. They rest on automated coverage.

| Subcommand | Where its behaviour is covered |
| --- | --- |
| `memory compile-index` | `actions/memory/compile_memory_index.ex` through `Projection.rebuild_with_options/2`; projection rows in `projection_test.exs` |
| `memory delete` | `forget_test.exs` and canonical deletion rows |
| `memory promote-turn` | `promotion_test.exs` |
| `memory proposal-keep-all` | `proposal_review_test.exs` batch rows |
| `memory prune` | `review_test.exs` |
| `memory review` | `review_test.exs`, `review_cadence_sync_test.exs` |
| `memory search` | `retrieval_test.exs`, `index_test.exs` |
| `memory summarize` | `consolidator_test.exs` |
| `memory update` | `claim_stream_test.exs` manual-revision rows |

An operator planning to rely on one of these should know it has not been driven
end to end on a real Home by a person.

## Known deviations, recorded not hidden

These were found while raising coverage and are shipped as-is. Each is stated
with its direction of failure, because a deviation that fails closed is a
different risk from one that fails open.

- **`SecretFilter` refuses `secret://` references.** The labelled-assignment
  pattern carries a lookahead intending to exempt them, but `secret` is itself
  one of the alternation keywords, so the scanner re-anchors on the literal
  `secret:` inside the value and matches. **Fails closed** — it refuses a secret
  *reference*, which is not a secret. Loosening a credential filter to satisfy a
  cosmetic intent was judged the wrong trade.
- **`ConsolidationControl`'s unique constraint raises rather than converts.** The
  schema declares `unique_constraint/3` with the correct index name, but under
  this adapter a scope-tuple violation raises `Ecto.ConstraintError` instead of
  returning `{:error, changeset}`. A caller written against the changeset form
  would crash.
- **Three `ConsolidationControl` fields are `validate_required` with schema
  defaults**, so omitting them is valid. "Required" reads stronger than it
  behaves.
- **The shipped answering head has two disclosed failure modes**, unchanged by
  this milestone and documented in `docs/operator/model-recommendations.md`. The
  qualification bar for selecting a different head is v1.3.1.

## Release gate

`release.v13` is green: **32 of 32 steps passed** at `a16997919` on a clean
tree, evidence `release-v13-1785813865.json`, generated 2026-08-04T04:00:50Z.
That is the confirming run taken after the last intermittent row was diagnosed;
the first green was `1270045b0` / `release-v13-1785810884.json`.

It took four cumulative runs, and each surfaced a different class of problem —
which is the argument for running the gate to green rather than trusting
per-step numbers:

| Run | Result |
| --- | --- |
| 1 | 30 ExUnit failures across seven steps |
| 2 | 0 failing tests, but two **non-test** steps red (`credo_strict`, `v121_lane_inventory`) — these were never part of the thirty, which counted ExUnit failures only |
| 3 | 1 failure: a structural deadlock in the ACP test fixture, invisible in isolation |
| 4 | green |

**No product behaviour was changed by any of it.** Every one of the thirty was a
test that had stopped asserting its own contract — which is worse than a red
test, because it reports green while guarding nothing. The Memory rows this file
documents were unaffected throughout; the failures were in fan-out admission,
first-run onboarding, and test infrastructure.

Two findings worth carrying forward, because both mean the suite was weaker than
its green runs implied:

- **The gate was not hermetic.** `Settings.ModelDoctor` probes the endpoint
  configured in settings, so an onboarding row's result depended on whether the
  machine running it had Ollama up with a matching model. It passed on CI and
  failed on a developer machine. Fixed by pinning the endpoint unreachable and
  giving the file its own `Settings` root.
- **Fixture timing assumptions only held on an idle machine.** The ACP fixture
  polled for 5s to service a hold that waits 120s, so any real contention
  deadlocked the row. The `StoreTuiIdentityBootstrapTest` concurrency row had the
  same shape: it required all twelve racers to win a 5s SQLite lock race, so
  under load nine returned `:settings_lock_timeout`. Both are fixed by asserting
  the property the row is named for instead of a timing coincidence — the
  concurrency row now proves convergence deterministically, after the burst
  settles, and still refuses a torn write, a second bootstrap, a second audit
  row, or any non-timeout failure. Verified 0 failures in 12 runs under the load
  that reproduced it.

All three intermittent-looking failures in this milestone had concrete
structural causes once investigated. None was irreducible, and none required a
product change.
