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
  rebuild. Must not have drift detection wired to it as-is. Confirmed
  post-release intake candidate pending operator disposition; it is not part of
  the answering-head-only v1.3.1 plan. The preferred repair is to advance the
  watermark in the same incremental transaction and prove consecutive
  keep/archive/restore refreshes against the exact claim-stream digest.
- **A paused job repopulates `Next due`.** After `jobs pause`, `search-index`
  showed `Next due: none`, then a concrete timestamp while still paused and
  still not running. The adjacent case is handled correctly: disabling
  `memory.consolidation.enabled` set `Next due: none` and held it. Two "will not
  run now" states presented inconsistently on an operator-facing surface.
  Cosmetic, confirmed post-release operator-UX intake candidate pending
  operator disposition; it is not part of the answering-head-only v1.3.1 plan.
  The preferred repair keeps `next_due_at` nil while paused and proves pause ->
  dirty kick -> show -> resume without weakening dirty-intent preservation.
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
and all four latency cells reran. A fresh detached checkout of this SHA passed
the K6 structural prefix. Evidence
`/tmp/allbert-v13-k6-final.sHQ98g/home/release_evidence/v13/release-structure-v13.json`
has SHA-256
`ea38b1f4822b396394cf2ac56697fd6ad90694cb80be19c59cfcd7755ef5e27b`.
The one `release.v13` run is next in that same checkout/Home; the authoritative
`release` remains blocked on 32/32 green and promotion remains blocked on both
aggregates plus explicit operator approval.

The exact `release.v13` run then passed 32/32. Evidence
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v13/p0-2243/home/release_evidence/v13/release-v13-1785874157.json`
has SHA-256
`ab4d58aaafbbd795bcccb6629fbe4c9c795439327b2ab7938b0f5d0bf5d41388`;
the 32 step durations total 2,559,206 ms and no row failed. The repaired loaded
fan-out lane passed 332/332 at a new aggregate seed. The one authoritative
cross-version `release` is now authorized in this same checkout/Home;
promotion remains blocked pending that result and explicit operator approval.

The one authoritative cross-version `release` stopped in
`high_coverage_fast_local` after Hex audit, warnings-as-errors compile,
unused-dependency checking, formatter, and Credo passed. Its only red row was
`global_process_serial` partition 3/4, seed `412113`:
`CorpusCompletenessTest` found no positive execute case for the registered,
agent-exposed `set_direct_answer_model_profile` action. Evidence
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-16578/home/release_evidence/gates/release-2026-08-04T20_53_23Z.json`
has SHA-256
`5fe88fda6939fc371cf3f807dd6ceec31f0777c55990190c83c102abc27e81bf`;
the gate ran 941,000 ms. No later release phase ran and the draft remains
unpublished.

The action, DirectAnswer-specific descriptor, registry contract, parameter
contract, and intent-agent owner coverage are present, so this is classified as
committed evaluation-evidence drift rather than a production routing change.
M9.b.16 requires one real positive model-domain corpus case, a frozen-baseline
recapture, focused deterministic corpus/eval proof, then whole unpublished
candidate replacement and one fresh K6 rejoin. It explicitly forbids hiding the
gap in the intentionally-uncovered set or running an aggregate per fix.

Before that replacement, the broader legacy v0.56 security owner was also run
as a bounded stress check. Three rows fail reproducibly because their test setup
predates current contracts: ReqLLM prompts are structured Contexts rather than
strings; remote readiness is unavailable unless the test enables and
credentials the provider; and the promotion gate refuses a deliberately thin
review descriptor that regresses apps-domain routing to 0.5. Production is not
being loosened. M9.b.16 folds Context-aware redaction assertions, explicit
remote-callability setup, and a canonical-equivalent promotion fixture into the
same test-only tranche, followed by isolated rows and complete focused owners
before one whole candidate replacement.

Those focused repairs are green. The new canonical DirectAnswer case and
project-generated baseline record 319/319 cases at 1.0 accuracy (model domain
8/8). At aggregate seed `412113`, the original completeness row passed 1/1;
each repaired security row passed alone; the complete legacy security owner
passed 7/7; and the bounded corpus, current optimizer, and Model Doctor owners
passed 50/50. The recapture's one unrelated confusion entry is an existing
negative channel case now ending in a selection-policy-rejected answer rather
than a wrong action shortlist; neither path executes. Production code remains
unchanged. Test/development warnings-as-errors compiles, whole-project format,
docs, and diff hygiene passed; the draft remains unpublished pending
replacement.

Replacement construction is in progress from exact executable SHA
`d93b4a2a9f10da6051c80afc971bb5291301e03a`, annotated tag object
`504b5ac1990b7e76d617198fea8769ac6d61c81c`, generation
`v13-20260804T213555Z-d93b4a2a9f10`, and empty unpublished draft `365170833`.
All three builder/smoke rows passed and produced exactly 12 files. Archive
SHA-256 values are macOS arm64
`38d2acb580ca1ffbd557f5dd10eee253ee68f322a0b648a75ddd662e53ebb509`,
Linux x64
`bb03c691c8a447a51ea26964dfedca146d5f7021eea0d8f42e686c938b769d6d`,
and Linux arm64
`27dbbb90a3e0cb319e23a2748d51f010afe0880f6d60a207d86b37ea0fe0ed11`.
The real local Homebrew shadow install then passed `brew test`, reported
`allbert 1.3.0`, rendered the packaged JSON license inventory, and restored the
sealed OpenSSL and Exqlite payloads byte-for-byte under operator `umask 077`.
Their installed SHA-256 values are respectively
`643372e6478f280423b2f9536fa1523f1086f806309e9d98eca5ce11e22d3e18` and
`8559739c2ba3e6970b421de7f09650017661e0a278b8653c012bd0ed847031e1`.
Staging, qualification, and latency evidence are not yet claimed.

Complete-generation staging subsequently validated and uploaded the 12 target
files plus candidate manifest asset `501853439`. Draft `365170833` now has
exactly 13 uploaded assets, remains unpublished, and still binds executable
SHA `d93b4a2a9f10da6051c80afc971bb5291301e03a`. The candidate manifest's
release-asset and local SHA-256 are both
`033e3a98879dcd7ff7dda223b44c1310e95a3ac8d451d3745132fb65338b4305`.
No-build qualification run `30953764112` is pending; packaged latency and K6
have not yet run for this replacement generation.

Run `30953764112` subsequently passed exact binding, packaged license, and
protocol-TTY qualification on all three targets. Joined qualification artifact
`8910205764` has Actions ZIP SHA-256
`a6c65095296edced91a3f5b6d7cd609264d76fe38f73b0549271439fb232f1ea`;
qualification-manifest content SHA-256 is
`2474960f3338fd8bc6d43e4c042199b467953e8418b35eba38c141ee19bf0875`.
Promotion was skipped. Packaged latency and K6 remain pending.

The four replacement packaged-latency cells then passed and were ingested:
macOS arm64 Memory p95/p99 `53.285/55.028 ms`, macOS arm64 Search
`64.207/65.948 ms`, Serenity Linux x64 Memory `38.950/39.719 ms`, and Linux
x64 Search `47.334/50.711 ms`. Every row is clean and binds full candidate SHA
`d93b4a2a9f10da6051c80afc971bb5291301e03a` plus its target archive digest;
no host or consumer was averaged. K6 remains pending and promotion is still
prohibited.

K6 structural proof subsequently passed in a fresh detached checkout of exact
candidate SHA `d93b4a2a9f10da6051c80afc971bb5291301e03a`. The evidence at
`/tmp/allbert-v13-k6-d93b4a2a9f10/home/release_evidence/v13/release-structure-v13.json`
has SHA-256
`626265569e4e222dc739ac3272327d3fd568ef3be6c70d7c7c2dc078b5486c6f`.
`release.v13` and the authoritative aggregate remain pending.

The single `release.v13` run then passed all 32 of 32 steps. Its structured
evidence at
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v13/p0-16583/home/release_evidence/v13/release-v13-1785880845.json`
has SHA-256
`8afa7e040dfd5c69e1a4dfecd82cb129744f006530c347f86b7dc81c100b8353`.
The authoritative cross-version aggregate remains pending, and promotion is
still prohibited.

The subsequent one authoritative aggregate at exact candidate SHA
`d93b4a2a9f10da6051c80afc971bb5291301e03a` passed its cheap/static phase,
`high_coverage_fast_local`, and `core_external_runtime_serial`, then stopped in
`core_security_eval_serial` with 3 failures out of 387. Evidence
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-14340/home/release_evidence/gates/release-2026-08-04T22_41_02Z.json`
has SHA-256
`eb64ba4aed059be70a9247dd29a896d3b8ed9176c7a72431c60244635c1f3668`.
The result is diagnostic, not promotable.

Focused remediation updated two stale security expectations and restored the
frozen configured `endpoint_kind` response contract while adding the actual
validated `effective_endpoint_class`. The two failing security owners passed
12/12 at seed `542984`; the affected Model Doctor/action/readiness/CLI owners
passed 53/53; forced development and test warnings-as-errors compiles were
clean; and the complete security-eval lane passed 387/387 at seed `156033` in
391.0 seconds. Because the packaged Doctor output changes additively, PV-3 is
the only attended row invalidated; all other PV rows remain inherited and are
not relabelled. The unpublished generation must be replaced whole before PV-3
and the final K6 rejoin run.

That replacement K5 build is now complete at clean pushed executable SHA
`a302aae61483d76272771011a3e9ec59a46cfad2`, annotated tag object
`0ca7ea3e4aac3d4ca79163079f04397063842220`, empty unpublished draft
`365211382`, and generation `v13-20260804T234212Z-a302aae61483`. The candidate
directory contains exactly 12 target files. macOS arm64 archive SHA-256 is
`6e1b7ed41fb844eb0cf3f602e6c4fe8b02c87ed4a406809512346454dab8b09d`,
Linux x64 is
`b4ec90492889abf48c20515f4407a40bf292713f796a115c833db25a4c046f89`,
and Linux arm64 is
`a6d1ff762e0f996ca20b86323bf2ec10021bb3847bd404c7ebc3c4e04040627b`.
All toolchain and smoke rows bind the exact SHA and generation, all smoke rows
say `passed`, and all three archive sidecars verify. Both Linux targets used
native target execution under pinned image digest
`sha256:d8c7836b5b2b3b90918fb504b9eac563814503957875658528d9ab4581bf1e6b`.
Installed-package proof, whole-generation staging, no-build qualification, the
four latency cells, replacement PV-3, and K6 remain pending; no release has
been published.

The exact macOS candidate also passed the real Homebrew shadow-install row. It
installed and tested as `allbert 1.3.0`, rendered its packaged JSON license
inventory, and retained archive-identical sealed payloads after Homebrew
relocation: OpenSSL SHA-256
`643372e6478f280423b2f9536fa1523f1086f806309e9d98eca5ce11e22d3e18`
and Exqlite SHA-256
`8559739c2ba3e6970b421de7f09650017661e0a278b8653c012bd0ed847031e1`.
Evidence root `/tmp/allbert-v13-homebrew.jNah5F` is retained. The candidate is
installed for replacement PV-3; the draft remains empty and unpublished.

Whole-generation staging then uploaded the validated 12-file set and wrote the
manifest last. Draft `365211382` now contains exactly 13 assets and remains
unpublished/immutable `false`. Candidate-manifest asset ID `501951481` has
matching remote and local SHA-256
`5811e5ff803af7fb568d0782d7c7e68893fca34b817c02a813fa2e594092b92c`.
No-build qualification remains pending; promotion is prohibited.

No-build qualification run `30961472818` then passed separately on macOS
arm64, Linux x64, and Linux arm64, followed by the joined evidence job;
promotion was skipped. Qualification-manifest artifact ID `8913118715` has
Actions ZIP SHA-256
`ba48a084e2bd35b10fc0e923f6f590400d7358f34b326d980011a28063b79249`
and content SHA-256
`99e9525141edcd833cd0922fbbd3ea75735cbd5472cbf92011e2c79e5aff0c18`.
The release remains an unpublished mutable draft. Packaged latency and
replacement PV-3 remain pending; no release has been published.

The four replacement packaged-latency cells then passed and were ingested:
macOS arm64 Memory p95/p99 `48.067/50.489 ms`, macOS Search
`61.090/64.990 ms`, Serenity Linux x64 Memory `38.279/39.417 ms`, and Linux
Search `47.702/51.430 ms`. All four bind exact source SHA
`a302aae61483d76272771011a3e9ec59a46cfad2` and their matching archive digest;
no host or consumer is averaged away. A macOS diagnostic file whose passing
numbers carried the later docs HEAD was rejected and not ingested; the accepted
retry force-recompiled the clean exact-SHA driver before measurement. ADR 0092
now names the replacement generation. Replacement PV-3 and K6 remain pending.

Replacement PV-3 then passed against the Homebrew-installed candidate and real
configured Ollama endpoint in fresh disposable Home
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert-v13-pv3.uV4ElRAv`.
Both the `local` and `direct_answer_local` Doctor rows reported configured
`endpoint_kind=local_endpoint`, validated `effective_endpoint_class=local`,
`endpoint_ok=true`, and `model_available=true`; DirectAnswer selection did not
change the global primary. PV-0–PV-2 and PV-4–PV-8 remain inherited and are not
relabelled. K6 is the only remaining pre-promotion gate.

The fresh detached K6 checkout at exact executable SHA
`a302aae61483d76272771011a3e9ec59a46cfad2` then passed
`release.structure v13` with a clean worktree and all three cumulative prefix
comparisons exact. Evidence
`/tmp/allbert-v13-k6-a302aae61483.xKks08/home/release_evidence/v13/release-structure-v13.json`
has SHA-256
`7b740631b40639c0bb93a61d0816cd9537c4718a0129d34f16c7520af1b5a663`.
The one `release.v13` is next; no aggregate has run for this replacement.

That single `release.v13` then passed 32/32 ordered steps. Structured evidence
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v13/p0-16578/home/release_evidence/v13/release-v13-1785888752.json`
has SHA-256
`3ce292aeb01dfe3482ea7be932494a14f425ec736cbd3663e8e6d9bda397fd26`;
step duration totals 2,331,579 ms. The one authoritative aggregate is now the
only remaining gate before explicit promotion approval.

The one authoritative aggregate then stopped after 92,000 ms in
`high_coverage_fast_local`. Hex audit, forced warnings-as-errors compile,
unused-dependency validation, formatter, strict Credo, and every parallel
non-core suite passed. Core ran 387 tests and had one failure at seed `785475`:
the unavailable-ReqLLM ReportComposer row did not observe its deterministic
fallback selection within the test helper's 500 ms polling window. Evidence
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-16578/home/release_evidence/gates/release-2026-08-05T00_52_51Z.json`
has SHA-256
`5d53e5d5487b8d113e4ff7ad2685f61e8b62c825cba35299fcfceb997699afb5`.
No later aggregate phase ran. The owner row/seed, repeated row, full owner file,
and directly related owners are the bounded diagnostic scope; no aggregate runs
per remediation. Promotion remains prohibited.

Focused diagnosis classified the failure as test fixture ownership. The exact
candidate row passed 100/100 at seed `785475` in isolation and its complete
owner passed 19/19. The test store now emits a unique persisted-selection
receipt after its synchronous Agent update; all nine affected rows, including
crash recovery, wait for that effect instead of polling for 500/1,000 ms. The
repaired row passed 100/100 and the combined ReportSynthesis/ReportComposer/
ReqLLM owner set passed 53/53 at seed `785475`. Test/dev warnings-as-errors
compiles, formatter, docs gate, and diff hygiene are clean with zero warnings.
No production or accepted operator contract changed. Complete candidate
replacement and one fresh K6 rejoin remain required by exact-SHA provenance;
PV-0 through PV-8 remain inherited without relabelling.

The superseded unpublished candidate was discarded whole. Replacement exact
SHA `43859a9ea7f5773ae056208ebb8e687d21f7d91a`, annotated tag object
`72ea5211a0d367f8ebe0dc723d166d471aa591c7`, empty draft `365232611`, and
generation `v13-20260805T010722Z-43859a9ea7f5` bind one 12-file generation.
Archive SHA-256 values are macOS arm64
`06f80c2e687c453bd9f60646808bd19190da2d237be5769162e2fde5ba498ce8`,
Linux x64
`7faa4c7ce3ff6399470f7d93386f77bdd97abecaf30af98388e3400382c71242`,
and Linux arm64
`81b8826395b0ede2c0bd29e6db7ca41a90b1e0ba51e5a09f6c9ffa7646515563`.
Every checksum and source/generation binding verifies, all smoke outcomes are
`passed`, and both Linux targets ran natively under the pinned image/toolchain.
The draft remains empty, unpublished, and mutable; later K5/K6 evidence is
pending and promotion remains prohibited.

The replacement macOS archive passed Homebrew shadow install/test and packaged
license rendering. Homebrew relocation preserved archive-identical sealed
OpenSSL SHA-256
`643372e6478f280423b2f9536fa1523f1086f806309e9d98eca5ce11e22d3e18`
and Exqlite SHA-256
`8559739c2ba3e6970b421de7f09650017661e0a278b8653c012bd0ed847031e1`.
Evidence roots `/tmp/allbert-v13-homebrew.g8mGvo` and
`/tmp/allbert-v13-homebrew-archive.HFsXyT` are retained. The exact candidate is
installed; staging and all later gates remain pending.

The verified generation was staged whole. Draft `365232611` contains exactly
13 assets and remains unpublished/mutable. Manifest asset `502006691`, its API
digest, and the local SHA-256 all equal
`7b8ca10955de5cd574fda49245ad324c82359e47967f64e6b7c1ca6df699e3ef`.
No-build qualification and later gates remain pending; promotion is prohibited.

No-build qualification run `30965999992` passed macOS arm64, Linux x64, Linux
arm64, and joined evidence; promotion was skipped. Qualification manifest
artifact `8914748809` has API/ZIP SHA-256
`39602b62c88237df53b37de85e66b4ed5edc693cf1072079741b5be746e9bfd6`
and content SHA-256
`b84aea7aff3dfa517304fc533c1609ee097fd25ed067810054626d2c13fb4783`.
The draft remains unpublished/mutable with exactly 13 assets. Packaged latency
and K6 remain pending; promotion is prohibited.

Four final packaged-latency rows passed and were ingested for exact source SHA
`43859a9ea7f5773ae056208ebb8e687d21f7d91a`: macOS arm64 Memory
`56.705/65.074 ms` and Search `67.139/70.929 ms`, plus Linux x64 Memory
`39.014/39.750 ms` and Search `47.668/52.413 ms` (p95/p99). Each row binds its
host's archive digest, remains below the frozen consumer-specific bounds, and
is reported separately. Evidence-file SHA-256 values are
`a58338c042e33ab0c1781ed8316bbd4ab0de316c6465264ab3c53490867673bd`
for macOS and
`95bf958312498579f139bc8c19ba82d3229d45771551cf8ed5608436e0c76573`
for Linux. K6 structure, `release.v13`, and authoritative `release` remain;
promotion is prohibited.

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
