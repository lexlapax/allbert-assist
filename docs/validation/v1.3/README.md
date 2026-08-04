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

**Acceptance run: complete contiguous SV-0 through SV-9 on a fresh disposable
Home at `e66674cf9`, daemon 81317, 2026-08-04.** The operator drove every TUI
and Web interaction personally; terminal-2 command steps were agent-run against
the same daemon and Home at the operator's direction. This supersedes the
2026-08-03 targeted re-test, which covered only the M9.b.10/M9.b.11 fixes.

Block results: SV-0–SV-5 setup PASS; SV-5B fan-out PASS (3/3); SV-6A boundary
and seeding PASS with one disclosed known-mode failure recorded; SV-6B
consolidate/keep PASS; SV-6C retrieval PASS; SV-6D archive/restore/Forget PASS;
SV-6E canonical delete PASS; SV-7A three-surface parity PASS (5/5); SV-7B
UNAVAILABLE (verified); SV-8A managed Jobs PASS (6/6); SV-8B UNAVAILABLE
(verified); SV-9 close PASS.

**Both Memory production defects found in the previous run are proven fixed**,
in runbook order, with no manual rebuild at any point:

- **M9.b.10** — the projection bootstrapped at daemon boot, so SV-6C retrieval
  returned the kept claim in place rather than reporting
  `:memory_projection_not_ready`. Before the fix this row could not pass in
  order; the only step that built a generation was SV-8A.5c, far below it.
- **M9.b.11** — archive removed the candidate from the projection itself
  (`Candidate chunks before filter: 0`, not merely a filtered zero), and restore
  made the same claim retrievable again immediately.

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

## Findings from the 2026-08-04 acceptance run

None blocks the release, and **no product code was changed during validation.**
Full text for each is retained in the run's evidence root.

- **`SV-6A.1a.ii` known-mode failure, observed twice.** The disclosed
  acknowledgment-to-commitment mode: asked to *acknowledge* a stated preference,
  the head answered "Status summaries … **will be provided** … starting June 1,
  2026", and at SV-6A.2 similarly "will be kept". All required content was
  present; the defect is the commitment framing. Dispositioned to v1.3.1 by
  M9.b.8 on 2026-08-02. The boundary itself held — verified in the durable
  record, the supplied text was never captured as Memory and no domain action
  fired.
- **Runbook defect, found and fixed mid-run.** SV-6A.1a closed with the literal
  "both supplied-text answers were useful" on a row that *explicitly permits*
  the `.ii` failure and instructs the operator to continue past it. On exactly
  the runs it exists to tolerate, it emitted a PASS contradicting its own
  adjudication. Reworded at `e66674cf9`.
- **`claim_stream_watermark` is stale after consecutive incremental refreshes.**
  It records the digest of the claim set at the last *full build*, and
  `refresh_claim/2` does not advance it, so after keep/archive/restore it
  described an empty stream while the projection held claims. Inert today — the
  field is write-only and nothing reads it back — and it self-heals at the next
  rebuild. Must not have drift detection wired to it as-is. v1.3.1 intake.
- **A paused job repopulates `Next due`.** After `jobs pause`, `search-index`
  showed `Next due: none`, then a concrete timestamp while still paused and
  still not running. The adjacent case is handled correctly: disabling
  `memory.consolidation.enabled` set `Next due: none` and held it. Two "will not
  run now" states presented inconsistently on an operator-facing surface.
  Cosmetic, v1.3.1 intake.
- **One PASS line in the transcript was retracted.** The agent-run adaptation of
  SV-8A.2 rewrote the runbook's `set -e` assertion chain as
  `grep … && echo OK || echo FAIL` and gated the final PASS on an unrelated
  check, so it printed PASS while `jobs pause` had crashed and left the job
  active. Harness error, not a product finding; the crash itself was a shared
  `_build` tree between the agent's `MIX_ENV=test` gate runs and the operator's
  `MIX_ENV=dev` session. Every later block ran under `set -Eeuo pipefail`, and
  SV-8A.2 genuinely passed on re-run.

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

## Exact candidate construction and packaged qualification

Current K5 replacement completed on 2026-08-04 from one frozen clean pushed
executable source SHA; the prior unpublished generation was discarded whole
and no target was retained:

| Binding | Exact value |
| --- | --- |
| source SHA | `c7df6e7e5e9f1baab2719c31c481702e1456ad68` |
| candidate generation | `v13-20260804T194722Z-c7df6e7e5e9f` |
| macOS arm64 archive SHA-256 | `3149a38249df1d893810a647b2fc7cc17d8f465bb096aa770897198056aaf396` |
| Linux x64 archive SHA-256 | `07d6f735db689834a4616254f162826078be8430a960391a9f5438da82e65e5f` |
| Linux arm64 archive SHA-256 | `ce3a29807ab89f19afa8aa452a16c40ef675fc71f783f4c4cfd392e22b1cd7e9` |
| unpublished draft release | `365113275` — 13 assets, immutable `false` |
| candidate manifest | asset `501751833`, digest `e6ef8b42a569b1234abcbdb65200142aaecaadecbdefd57ace4b22901a23159c` |
| no-build qualification | run `30945495378` — all three targets passed |
| qualification manifest | artifact `8906942033`, digest `c8e640e329d5c76fd630f8a1bd9433110dce9e53c01851cd17fe2c123de558b2` |

Each native builder passed its SHA/generation/toolchain, package, sealed-license,
and runtime smoke. Both Linux outputs came from native architecture execution
of the same pinned Debian multi-architecture image digest. Homebrew installed
the actual macOS candidate under `umask 077`; `brew test`, packaged
`allbert licenses --json`, all sealed evidence `0644`/`0755` modes, and exact
archive-versus-install hashes for both relocation-managed Mach-O payloads
passed. This is the successful proof of M9.b.14; the draft remains unpublished.

## Packaged native latency and ADR 0092

The exact macOS arm64 and Linux x64 archives ran the frozen Memory and Search
workloads through their packaged executables. Results are separate—not averaged
across host or consumer—and are ingested into
`docs/validation/test-metrics/summary.md`:

| Host | Consumer | Frozen scale | p95 ms | p99 ms | Result |
| --- | --- | --- | ---: | ---: | --- |
| macOS arm64 | Memory | 10,000 claims / 200 measured queries | 53.267 | 54.257 | PASS |
| macOS arm64 | Search | 25,000 messages / 250 threads / 300 measured queries | 64.283 | 67.128 | PASS |
| Linux x64 | Memory | 10,000 claims / 200 measured queries | 38.470 | 38.870 | PASS |
| Linux x64 | Search | 25,000 messages / 250 threads / 300 measured queries | 47.709 | 51.556 | PASS |

Every row carries the full candidate SHA, its exact archive digest, a complete
warm pass, the frozen threshold, clean provenance, and `status=passed`. Combined
with the loaded-Exqlite capability smoke in all three native packages, these
rows satisfy ADR 0092's last flip condition. ADR 0092 is Accepted. Source-tree
rehearsals and the prior mixed-SHA portability builds are not used as this
evidence.

PV-0 through PV-8 were not repeated for this compatibility-metadata/test-
fixture correction. Their accepted feature observations are inherited under
the active plan's narrow re-run rule and are not relabelled as observations of
the current package; current identity, integrity, Homebrew/package smoke,
qualification, and all four packaged latency cells did rerun.

## Final K6 aggregate closeout

The isolated detached checkout at exact executable candidate SHA
`2b9cb986fdb1ad7a9750b4b4b9e5c165e7f425bd` passed the structural-prefix
proof before either aggregate started. Evidence:
`/tmp/allbert-v13-k6-final.dlOVjJ/home/release_evidence/v13/release-structure-v13.json`;
SHA-256
`e22761eff2c1de324895e862b2f828debebdadf7f0504841d23e092b647028c2`.
The final `release.v13` run is now authorized in that same checkout. The
authoritative cross-version `release` aggregate remains blocked until all 32
version steps pass, and promotion remains blocked pending both green aggregates
and explicit operator approval of the exact candidate bindings above.

The resulting `release.v13` diagnostic completed 31/32. Its sole failure was
`v11_runtime_fanout`, seed `161591`, in the Budget-v1 pending-steering recovery
fixture; all later steps passed. Evidence:
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v13/p0-14339/home/release_evidence/v13/release-v13-1785869464.json`.
The row passed alone at the same seed. Under the full loaded step, queued
pre-acknowledgement steering wakeups allowed the default coordinator to close
the two historical children before the test's injected coordinator owned the
transition. Both durable outcomes were correct, but the private injected-hook
counter remained zero. This is a test-control race, not a product-behavior
failure. The plan requires a pre-acknowledgement Scheduler mailbox barrier,
focused loaded proof, whole unpublished-candidate replacement, and a fresh K6
rejoin. No authoritative `release` aggregate started from this red run.

The focused repair makes the fixture cross a synchronous Scheduler mailbox
barrier while kickoff is still blocked and proves Registry ownership remains
empty before acknowledgement. Production code is unchanged. At the original
seed `161591`, the exact row passed 12/12 independent runs, the complete
Supervision owner passed 40/40, and the exact loaded `v11_runtime_fanout` step
passed 332/332 in 407.4 seconds. Test and development warnings-as-errors
compiles, formatter, docs, and diff hygiene also passed. This is focused
remediation evidence only; the unpublished candidate must still be replaced
whole and the final K6 sequence rerun.

That whole replacement is now complete at candidate SHA
`c7df6e7e5e9f1baab2719c31c481702e1456ad68` with the exact construction,
qualification, and latency bindings above. The source change from the prior
candidate is test-only. PV feature observations remain inherited without being
relabelled; current identity, integrity, Homebrew/package smoke, qualification,
and all four latency cells reran. Final K6 must now start in a fresh detached
checkout of this SHA.

## Packaged operator validation

The operator explicitly delegated execution of PV-0 through PV-8 on 2026-08-04.
The completed run used the installed Homebrew candidate bound to source SHA
`a3cd5781617b3a9ee511425b687ff359bdfcb0c7`, generation
`v13-20260804T071638Z-a3cd5781617b`, and macOS archive SHA-256
`8400ae64b991cc97d428dd058a21dcfb5eff5a2379f1b3deb363055e3ec10588`.
It used a fresh disposable Home and the real configured local Ollama profiles;
no fake provider or source-tree executable substituted for the installed
package.

| Row | Redacted outcome |
| --- | --- |
| PV-0–PV-4 | PASS — fixed port free, exact candidate bound, fresh Home/key, both real profiles available, packaged daemon and attach healthy |
| PV-5 | PASS — all three configured route disclosures preceded attach; TUI identity, real-provider arithmetic answer, and health were correct |
| PV-6 | PASS — CLI and TUI reached the same packaged daemon/Home; durable disclosure state contained exactly primary, fan-out manager, and fan-out synthesis usages |
| PV-7.1 | PASS with `PV-7.1-ack KNOWN-MODE FAIL` — supplied-text routing boundary held, only explicit Memory was stored, and explicit recall succeeded |
| PV-7.2 | PASS — Search became available in 62 seconds, CLI/TUI named the same canonical source, and all five managed jobs were unique |
| mapped DM | UNAVAILABLE — every non-TUI channel was disabled, missing credentials, and unmapped; no fixture substituted |
| PV-8 | PASS — TUI detached, daemon stopped, port 4137 free, shared environment pointer removed |

The acknowledgment result is the same future-commitment failure already
disclosed and accepted for v1.3 by M9.b.8; it is not reclassified as a clean
answer. The first attempt also found two runbook defects—an incomplete route-
disclosure literal and a packaged hard stop that contradicted M9.b.8. They were
reconciled systemically for source and packaged validation at `da077bb3b`, the
docs gate passed, and the complete run restarted with a new Home. Candidate
bytes, tag binding, staging, qualification, and packaged latency evidence were
unchanged, and no aggregate gate ran. Raw prompts, Memory values, Search
snippets, credentials, and generated identifiers are excluded from this record.
