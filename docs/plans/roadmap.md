# Allbert Roadmap (post-1.0)

The 0.x -> 1.0 roadmap is archived at [archives/1.0-roadmap.md](archives/1.0-roadmap.md)
(including the canonical 1.0 Acceptance Matrix). This roadmap covers the 1.x line.

## Release Model (1.x)

Every packaged product release is a **binary release**: tagged, CI-built,
cosign-signed, published as a GitHub Release, Homebrew tap filled. An explicitly
operator-approved `[skip-artifacts]` source point tag is not a packaged release;
its changes reach operators in the next named binary and the packaged Latest/tap
do not move. A point-release plan may ship one or more point tags that
accumulate toward the next minor. A minor plan uses warning-free exact-clean-SHA
milestone checkpoints during implementation and publishes the minor's `.0` tag
only after release acceptance; it does not publish numerically later point tags
before the minor tag. A signed `-rc.N` prerelease is used only when an
intermediate artifact must be externally qualified. Minors carry one flagship
feature each, foundational-first.
Plans follow the established triad convention (plan + request-flow, ADRs as needed);
the prioritization inventory is [future-features.md](future-features.md), which
holds only work with **no** ladder slot. This roadmap is the single source of
truth for sequencing; future-features no longer mirrors a release ladder.

## The Ladder

1. **1.0.1 — SHIPPED** (tagged `v1.0.1` 2026-07-15, source/docs point tag with
   `[skip-artifacts]` by operator decision — `v1.0.0` stays the packaged Latest;
   the fixes reach the artifact line with the next binary release): R15
   digest-manifest cache-busting, `btn` drift, offline service-worker guard,
   DIT-5 transcript, DIT-4 remediation M4.1–M4.5 (TUI launch, browser research
   end-to-end behind one consent gate, channel-send routing, packaged ACP
   handshake, cross-surface confirmation conformance), and the first standing
   dependency refresh (vendored `:memento` removed, ADR 0050 superseded).
   Plan: [archives/v1.0.1-plan.md](archives/v1.0.1-plan.md) +
   [archives/v1.0.1-request-flow.md](archives/v1.0.1-request-flow.md).
2. **1.0.2 — SHIPPED** (implementation evidence SHA `1d41956c`; the
   administrative closeout commit is source/docs tag `v1.0.2` and carries
   `[skip-artifacts]`; operator audit accepted 2026-07-19) — Test Suite Speed
   & Isolation phase 1
   (residue de-flake, registry injection seams per ADR 0082, lane
   conversions, the WorkspaceLiveTest web split, cost-packed partitions,
   measured decide-turn remediation), v0.58 cleanup tails A+B,
   Tier-2->Tier-1 promotion ADR 0081, and the queued dependency refresh.
   The post-implementation audit's M8.9-M8.12 closed no-loss, metrics
   provenance, release-state reconciliation, and clean-SHA proof at the
   implementation evidence commit. No v1.0.2 binary artifacts were produced;
   the binary moved to 1.0.3.
   Plan: [v1.0.2-plan.md](archives/v1.0.2-plan.md) +
   [v1.0.2-request-flow.md](archives/v1.0.2-request-flow.md).
3. **1.0.3 — PUBLISHED, BINARY ACCEPTANCE NOT CLOSED** (tagged `v1.0.3`
   at `329b9d28` on 2026-07-20; CI run `29797899746`; tap commit
   `28ef6c2`) — Test Suite Speed &
   Isolation phase 2 **and the attempted catch-up binary release** (operator final scope
   disposition 2026-07-20): the five ADR 0086 conversion contracts (sandbox
   ownership, app-env context, named-process injection, per-test homes,
   external-runtime partitioning go/no-go), four red-first pilots, retirement
   of both known monolith-only failure classes at their ownership roots,
   measured decide-turn remediation, bounded dependency refresh, then the
   transferred M10 catch-up publication —
   tag → CI/cosign → tap 1.0.0→1.0.3 → packaged validation; the artifact
   line carries the v1.0.1 + v1.0.2 + v1.0.3 source fixes together. Publication
   and tap fill succeeded, but the macOS packaged-browser row failed because
   the artifacts contained the bridge manifests without `node_modules` or a
   Chromium payload. The immutable tag is not moved; the operator transferred
   the unmet binary acceptance to immediate hotfix v1.0.4 on 2026-07-20. The bounded
   conversion waves shipped no lane move: M5(a) was parked and M5(b) stopped
   with zero conversions; their production prerequisites and the unrun 2-VM
   external-runtime experiment remain intake candidates pending later operator
   disposition, with no v1.0.3 lane-floor claim. Plan:
   [archives/v1.0.3-plan.md](archives/v1.0.3-plan.md) +
   [archives/v1.0.3-request-flow.md](archives/v1.0.3-request-flow.md) + ADR 0086.
4. **1.0.4 PUBLISHED, BINARY ACCEPTANCE NOT CLOSED -> 1.0.5 SHIPPED**
   (stable tag `v1.0.5` at `1d4d5634` on 2026-07-22; CI run
   `29952510231`; tap commit `faabb0f`) — Packaged Browser Recovery. v1.0.4 is immutable at
   `337e3ddb` (CI `29841331741`; tap `5a970b9`): its artifacts correctly keep
   Node, Playwright, Chromium, and caches external, and both published Linux
   rehearsals passed. Its macOS packaged doctor failed when BEAM port option
   `:hide` caused OS Chrome to abort in `TransformProcessType`; direct Chrome,
   direct Playwright, the packaged bridge, and the same BEAM port without
   `:hide` passed. The operator approved v1.0.5 on 2026-07-21 to apply `:hide`
   only on Windows. On the same date the operator placed real-host Linux and
   WSL2 ahead of stable publication: signed GitHub prerelease
   `v1.0.5-rc.1` supplies the binary, remains non-Latest, and does not move the
   tap. Host failures remain v1.0.5 work and produce immutable `rc.2+`
   candidates; stable `v1.0.5` is built/cosigned/published and moves the tap
   only after those rows pass or receive explicit operator disposition.
   RC.1 is immutable at `032d3a12` (CI `29856150356`) and its WSL2 row failed
   on 2026-07-21 after exposing cross-process Settings YAML, confirmed systemd
   lifecycle, and configured Windows-host Ollama readiness/onboarding/TUI
   defects. The signed install, real model marker, and safe uninstall remain
   diagnostic evidence, not a carried acceptance PASS. v1.0.5 M8.1-M8.5 now
   repair those roots, wire permanent `release.v105` regressions, and publish
   RC.2 before repeating macOS, both Linux artifacts, WSL2, and real-host Linux.
   RC.2 and RC.3 exposed and repaired the packaged-TUI bootstrap and
   self-terminating service-uninstall roots. RC.4 is accepted at `1d4d5634`:
   workflow `29931185956`, macOS, both Linux artifact rows, WSL2, and Arch Linux
   real-host acceptance all passed without policy SKIP. Stable v1.0.5 was then
   freshly built, cosigned, published as Latest, installed from the filled tap,
   and revalidated on macOS plus both Linux artifact architectures from that
   exact accepted product SHA. The newer mainline commits are documentation-only
   release administration. Neither prior immutable tag was moved, and this
   corrective line contains no feature scope.
   Plan:
   [archives/v1.0.4-plan.md](archives/v1.0.4-plan.md) +
   [archives/v1.0.4-request-flow.md](archives/v1.0.4-request-flow.md) + amended ADR 0040. Later
   1.0.x: intent-pipeline refinements (opportunistic), technical-debt
   train. (The vendored `:memento` removal landed early at 1.0.1's M5
   refresh — ADR 0050 superseded.)
5. **1.1 — SHIPPED — Asynchronous Background Agent Fan-Out With In-Channel
   Steering.** (Stable annotated tag `v1.1.0` at `fdd52e53`, workflow
   `30222827984`, tap commit `090e59a`, 2026-07-26. Operator intake 2026-07-18,
   inserted
   foundational-first. **Implementation
   and atomic invariant/fault remediation through M12.16 are complete;
   validation-only product/harness scaffolding is removed, pre-effect database
   start failures recover without false uncertain-effect state, and one
   raw-terminal owner preserves type-ahead through lifecycle redraw. Candidate
   `6b00b784` passed derived `release.v11`; its focused FV-01 retry proved
   three-child completion, one durable join/report, and post-report usability,
   then exposed a remaining 16.7-second synchronous TUI steering turn. M12.17
   implements one bounded, supervised ordered attended-turn FIFO so the Adapter
   remains responsive without concurrent Runtime turns; its focused, complete
   TUI, static, Dialyzer, and 3,486-row no-loss-manifest rejoin is green. The
   clean-SHA `release.v11` gate passed all 14 steps at pushed implementation
   candidate `28ee2d86`; evidence is `release-v11-1785027587.json`. FV-01
   against documentation-closeout candidate `c8c4598e` then proved fan-out,
   steering, durable status, and one joined report, but exposed a post-render
   receipt failure that restarted the TUI Adapter and stranded an unrelated
   admitted turn. M12.18 implements the systemic correction: one shared
   transient database classifier and bounded idempotent receipt retry across
   Runtime callers, plus bounded deduplicated TUI acknowledgement linked only
   to the application TaskSupervisor after stdout. Its exact overlap and
   cross-surface suites pass 176 / 0; static/docs/Hex/Dialyzer are clean; and
   the 3,492-row manifest reconciles 551 files without a finding. Clean pushed
   implementation candidate `516fc7b9` passed all 14 `release.v11` steps
   (`release-v11-1785033817.json`). FV-01 against documentation descendant
   `386a6650` then proved the M12.18 survival/redelivery contract but exposed
   production-shaped multi-connection SQLite contention: the steering message
   partially committed, its provider reference and directive did not, the
   channel event stayed `received`, and a raw stack reached the TUI. M12.19
   implements the systemic correction: one production/dev SQLite connection,
   immediate effect-free transactions, atomic idempotent inbound admission,
   bounded operator errors, measured prompt/line responsiveness during active
   fan-out output, and a non-Sandbox concurrency proof. Its focused/static
   rejoin is clean, the 3,500-row manifest reconciles 552 files, and pushed
   implementation candidate `2892940e` passed all 14 `release.v11` steps
   (`release-v11-1785038793.json`). FV-01 against documentation descendant
   `b74a3405` then passed in one fresh disposable Home: three children
   completed, the first child was steered exactly once, the parent joined once
   with `success`, its result report was durably `delivered`, and the same TUI
   remained responsive for the final independent turn. The expanded
   `release.v11` definition covers the
   invariant/fault, exact-receipt, attended-surface, autonomous-channel,
   public-protocol, and operator-control paths. A static post-implementation
   audit at `41857507` then found one fail-open recovery asymmetry: when a
   blocked/failed safety transition does not persist, the post-worker join path
   can restart a durable `running` child without the boot path's retry-safety or
   attempt-ceiling checks. Approved M12.20 paused the final cascade and now makes that
   recovery fail closed, binds five recent regression files into `release.v11`,
   and adds actual pool-1 Allbert integration evidence. Its focused Coordinator,
   TUI, steering, persistence, topology, lane, and 3,509-row manifest rejoin is
   green. FV-01 remains accepted because no happy-path contract changed.
   Candidate `bbc69b90` then passed all 14 `release.v11` steps, pre-push, and
   the uninterrupted 12-phase authoritative release cascade. A bounded
   real-provider Web parity walkthrough proved the same decomposition,
   concurrency, steering, join, acknowledgement, and post-report usability,
   but found that the joined report is ephemeral in chat history after the next
   turn/remount, alongside misleading kickoff/active-count labels and weak
   child-result affordances. M12.21 now makes the Web report one canonical
   idempotent conversation message across joined-signal, next-turn, and remount
   paths, preserves exact browser-render acknowledgement, and corrects those
   bounded presentation projections. Its 63 / 0 core/security, 19 / 0 delivery,
   34 / 0 Web, static, Hex, Dialyzer, lane, and 3,521-row manifest rejoin is
   green. Real-provider WV-01 passed at pushed candidate `9ca0e3fd` with one
   exact steer, one canonical remount-stable report, three completed linked
   children, and a delivered successful parent. Final clean pushed
   implementation candidate `f81a49de` passed expanded `release.v11`, pre-push,
   and the uninterrupted 12-phase authoritative release cascade in 3,997
   seconds. On 2026-07-26 the operator authorized the stable `v1.1.0` binary
   release sequence: annotated tag without `[skip-artifacts]`, CI build/cosign,
   GitHub Latest, checksum-derived tap fill, packaged install rehearsal, and
   post-artifact documentation/archive closeout. All steps passed: published
   checksums and cosign identity verified, strict Homebrew audit/style and
   `brew test` passed, and the installed 1.1.0 package passed disposable-Home
   version/status/health/attach checks:**
   `docs/plans/archives/v1.1-plan.md` + archived request-flow + ADR 0083/0084/0085.) On a prompt
   that decomposes into multiple tasks, Allbert delivers a kickoff receipt,
   then fans out background agents/actions, streams their status, joins on
   completion, and reports to the originating caller — chat channels stay
   open, and mid-flight input is contextually routed as steering vs a new
   request. The two-phase receipt/start contract applies to every Runtime
   caller; work never starts before the caller confirms that the kickoff was
   delivered or durably recorded. OpenAI/ACP requests hold until join —
   through an additive continuation outside the Runtime turn; OpenAI SSE is
   truly chunked and ACP remains cancellable while prompting. On timeout the
   kickoff returns and the report remains pending until its delivery receipt
   is acknowledged; no existing request or terminal response shape is removed.
   Builds on the delegate-agent substrate, Objectives channel attribution, and
   the intent engine; later minors' background jobs build on it. Carries the
   merged mid-action interruption + child-process cancellation enablers and
   the app-registry action-boundary membership check (operator-pulled,
   2026-07-18).
6. **1.2 — Zero-Click First Run.** (**SHIPPED 2026-07-27:** stable annotated
   tag `v1.2.0` at `af7b8848`; workflow `30332220900`; tap `6970688`;
   published macOS arm64 and Linux x64/arm64 rehearsals passed. Archived
   [plan](archives/v1.2-plan.md) +
   [request flow](archives/v1.2-request-flow.md) + ADR 0087
   (detection-based enablement consent) / ADR 0088 (model catalog/chooser +
   fallback policy); ADR 0078/0069 amended.) Chat-ready default with an
   auto-detected provisioned provider; onboarding optional and
   step-addressable; TUI first-run scope folded in. The shared catalog and
   opt-in bounded fallback shipped. `llama3.2:3b` remains the 8 GB default;
   Qwen stays operator-selectable because the only completed primary bakeoff
   row did not meet the frozen cross-platform promotion threshold.
7. **1.2.6 — Foundational Binary Enablers.** (**SHIPPED 2026-07-29:** annotated
   tag `v1.2.6` at `f457b1fe`; source workflow `30491295028`; protected
   promotion `30492163551`; tap `7ce955c`; dedicated milestones M0.a1–M0.c3 in
   `docs/plans/archives/v1.3-plan.md` + request-flow, ADR 0076 amendment, and ADR 0091.)
   This binary point release lands two independent foundations before v1.3
   schema work begins: a small deterministic final-artifact license generator
   with packaged notices/manifests and an offline `allbert licenses` viewer;
   and the daemon-backed TUI, where one daemon owns Runtime/Repo/identity and
   `allbert tui` is a thin authenticated terminal client. License and TUI work
   may proceed in parallel but rejoin at one frozen three-target artifact shape,
   a structurally verified (but not yet executed) `release.v121` definition,
   exact-SHA focused/static/security and packaged smokes, and binary publication.
   Per the train-wide operator constraint, aggregate execution is deferred to
   the final v1.3 M9.b `release.v13`/authoritative rejoin. The
   license promise is a best-effort inventory of known shipped components, not
   a universal scanner or SBOM guarantee; it fails closed only at managed seams,
   commits one cross-platform union plus per-target manifests, and carries one
   narrow file-scoped MPL-2.0 exception for the Castore/Mozilla CA payload with
   proven source availability. The TUI extends Attach v1 additively,
   permits one session per Home initially, and never silently boots a second
   runtime when attach fails. Three further pieces ride this stage because the
   binary needs them: **release publication splits from the build** — a product
   tag builds each target once, downstream jobs qualify those exact bytes, and a
   separately dispatched promotion behind a protected environment signs and
   publishes them with no rebuild and no `--clobber`; **one exact toolchain
   contract** replaces the floating macOS Homebrew path, pinned by full action
   SHA with recorded resolved versions and a one-time macOS requalification that
   keeps the OpenSSL patch only on measured evidence; and **one per-Home system
   integrity secret** with a domain-separated HMAC helper, first consumed by the
   TUI input-receipt gate that stops ambiguous reconnects from double-executing,
   then reused by every v1.3 Memory/Search/delete domain. Web asset digests are
   cleaned and rebuilt so no historical file survives into an artifact.
8. **1.3 — Long-Term User Memory + Search Central.** (**SHIPPED 2026-08-05:**
   immutable v1.3.0 release `365684798`; annotated tag object `075b467b` peels
   to accepted source `bc584c29`; official Homebrew tap `715d4d5`; archived
   `docs/plans/archives/v1.3-plan.md` + request-flow + amended ADR 0002 and ADR 0089 +
   new ADR 0092 and ADR 0093, milestones M1–M9.b.
   **Build started after v1.2.6 binary closeout.**) Long-Term User Memory
   remains the flagship: verified operator-authored conversation turns can
   produce reviewable proposals; only operator-kept append-only bi-temporal
   claims enter prompt context. Claims are authenticated immutable Markdown
   streams with valid-time and knowledge-time axes, per-claim
   expected-tail appends, hash-chain plus integrity-tag forgery quarantine,
   grandfathered legacy entries that upgrade lazily, and one complete
   disposable SQLite projection. Review is frozen, partially successful, and
   crash-resumable; reversible Archive and a separately confirmed,
   tombstone-first Forget are distinct acts. A canonical `Conversations.Corpus`
   boundary supplies both Memory and the independent Search Central consumer.
   Search owns one disposable SQLite FTS5 projection and typed API used by Web,
   TUI, CLI, and mapped DMs; it never feeds Memory. **Third readiness pass
   (operator-signed):** v1.3 also absorbs the legacy memory
   subsystems it would otherwise have shipped beside (memory search, the
   compiled index and its managed job, `prune_nominated`, the auto-promote
   setting, and the v0.47 memory drafts) behaviorally and without deleting
   public shapes; adds span provenance, the missing confirmed canonical
   conversation delete, writer ownership for all three databases, and the
   retained-searchable-conversation clause in the Forget disclosure; Search
   defaults on for local surfaces while Memory collection stays default-off.
   Stage closeout and triad archive are distinct events (plan LD 63). Existing
   Jobs remains the sole
   recurring engine for consolidation and visible managed search ingestion,
   maintenance/pruning, and on-demand rebuild entries. M1 calibrates quality,
   fixtures, and budgets only; it does not reopen the locked architecture.
   The fourth pass origin-scopes Memory/Search grants, routes Search dirty
   wakeups through Jobs.Managed, makes review/Forget restart-safe and
   tombstone-first, binds Search repair/paging/query privacy, and fixes the
   confirmed canonical delete target to message or thread. Mapped DMs default
   to the current canonical thread intersected with each message's verified
   channel/account/provider-thread origin; one confirmed, expiring query/cursor
   chain may broaden scope without Search-owned durable raw-query state.
   **Fifth readiness pass (operator-signed):** names the two feature switches
   and their deliberately opposite defaults (`search.enabled` true,
   `memory.consolidation.enabled` false) and the frozen origin scopes; names
   `AllbertAssist.Projection.PromoteProtocol`, the one promote sequence the
   Memory and Search projections share; excludes the Memory projection from
   authoritative export/backup on the same footing as Search; gates Purpose's
   bounded-latency promise on measured numbers; and gives canonical
   conversation deletion its own home in **ADR 0093** — a Corpus-owned
   destructive capability with exact cascade, live-dependency blocking, and
   best-effort survivor disclosure — rather than leaving it inside the search
   ADR. Deletion and Forget ship as a deliberate pair: Forget removes what
   Allbert concluded, deletion removes what was said, and each disclosure names
   the other. STM gains its documented data-safety contract and nested patch
   semantics without becoming persistent.
   Horizon items remain free-form provider URLs, non-local bind hardening,
   semantic/fuzzy search, automatic canonical-history retention, and automatic
   cross-app prompt mixing.
8b. **1.3.1 — Answering-Head Qualification And v1.3 Corrective Hardening.**
   (**SHIPPED SOURCE-ONLY 2026-08-05:** annotated `[skip-artifacts]` tag
   `v1.3.1` peels to accepted implementation SHA `7a27a9cc`; attended source
   validation, the eight-step delta gate, and one 12-phase aggregate passed;
   no GitHub Release, package, Latest, or tap movement. Archived
   [plan](archives/v1.3.1-plan.md) +
   [request flow](archives/v1.3.1-request-flow.md) + ADR 0097, with bounded ADR
   0089/0092 corrections. **v1.3 predecessor cleared.**) Carries
   v1.3 M9.b.8, deferred by operator decision after
   attended validation recorded two independent failures of the shipped
   answering head — a factual error (`rest_for_one` described as
   `one_for_one`, where `mistral-small3.1:24b` is wrong the same way and
   parameter count predicts nothing) and a rule-following error (an
   acknowledgment answered as a future commitment, absent in thirty-six retries
   but reproduced in a later independent session). v1.3 ships the head unchanged, both
   limits disclosed, and `intent.direct_answer_model_profile` as the opt-in
   seam; this release supplies the evidence that opt-in lacks. A frozen,
   digest-bound corpus covering **both** failure families — a facts-only
   corpus would have passed the head on the acknowledgment row — scored by
   closed deterministic predicates over the production request path, run five
   times per row against a 5/5 floor frozen before any head is measured. No
   model judges another model (v1.3 M9.b.6), no runtime rule enforcement
   (ADR 0021), no change to the shipped default: the bar produces the
   evidence, raising the default stays an operator decision. The operator also
   assigned two non-blocking v1.3 validation findings here: rename the derived
   last-full-build Memory watermark instead of adding an O(n) incremental scan,
   and enforce the existing central invariant that a paused managed job retains
   dirty intent with no effective due timestamp. The opt-in real-model matrix is
   in no aggregate or CI path and records content-free evidence. By explicit
   operator decision, v1.3.1 is an annotated `[skip-artifacts]` source point tag:
   no GitHub Release, package build, Homebrew movement, or packaged FV; v1.3.0
   remains packaged Latest and v1.4 carries these source corrections into the
   next binary. Focused tests and attended source validation precede one short
   delta gate and, because projection machinery is shared code, exactly one
   final authoritative aggregate—never an aggregate per fix.
> **Resequenced 2026-08-06 (operator decision).** The 1.x ladder was reordered
> so foundation ships first, the knowledge flagship follows, and adaptive
> profiling lands last. Version numbers were reassigned to match ship order —
> a 1.4.0 tag after 1.8.0 would break `brew upgrade` semantics, GitHub Latest
> resolution, and changelog ordering, so content moved between numbers rather
> than shipping out of sequence. Three decisions drove it: the kernel-redo
> analysis was **accepted** and merges into the spine sweep; preflight and
> `model_roles` were **unbundled** from profiling because everything depended on
> them and nothing depends on profiling; and knowledge ships before connectivity.
> What each number now means is below; the pre-resequencing mapping was
> spine 1.5→1.4, knowledge 1.7→1.5 and 1.8→1.6, connectivity 1.6→1.7,
> profiling 1.4→1.8.

### 1.x foundational dependency and carrier map

This table is the canonical ownership statement; downstream plans link here
rather than assigning the same foundation to a later release.

| Foundation | Source owner | First binary carrier | Required consumers |
| --- | --- | --- | --- |
| offline answering-head qualification, bounded Memory full-build metadata, paused-managed-due correction | v1.3.1 | v1.4 | v1.4 packaged FV proves the shipped source-only corrections before they first reach installed operators |
| preflight, exact-state attestation, owner-CWD load, fixture sentinels, fail-closed scope | v1.3.2 | v1.4 | every v1.4+ release; v1.4 structurally preserves owner-CWD load plus tag/manifest reconciliation and repeats both inventory checks in `release.v14` |
| `model_roles.fast|capable|thinking` resolution | v1.3.2 | v1.4 | v1.6 Knowledge Central (`capable`), v1.7 hosted-provider consumers, v1.8 confirmed remaps |
| role-remap suggestion, confirmation, and egress guard | v1.8 | v1.8 | adaptive profiling/customization only; it consumes but does not redefine role resolution |

9. **1.3.2 — SHIPPED — Foundational enablers.** (Source-only annotated
   `[skip-artifacts]` tag `v1.3.2` at accepted SHA `28dc39e0d`, 2026-08-06;
   [archived plan](archives/v1.3.2-plan.md) +
   [request flow](archives/v1.3.2-request-flow.md); no new ADR — preflight is
   release tooling and `model_roles` ships the resolution half of ADR 0090 §4.
   Independent review, attended validation, `release.v1`, `release.v132`, and
   the one aggregate passed. No GitHub Release or tap movement; packaged Latest
   stays at v1.3.0.) Two things
   extracted from the profiling release because every later release depends on
   them and nothing depends on profiling:
   `mix allbert.test preflight` (cheapest-first gate under two minutes, its
   exact-state attestation, separate owner-CWD load/tag/manifest checks, the
   bounded immutable second-Elixir compatibility probe, executable fixture
   sentinels, and the fail-closed `scope --base` selector), and
   `model_roles.fast|capable|thinking` as an additive naming layer over the ADR
   0088 catalog for Settings.Models-owned task chains.
   **Sequencing rationale:** preflight is what makes 1.4's generated action-roster
   sweep cheap to fail, and `model_roles` is a hard dependency of Knowledge Central
   (1.6) and a consumer for hosted-provider OAuth (1.7). Bundling them behind a
   flagship feature was the single largest constraint on this ladder. Source-only
   means both reach packaged operators at 1.4.

10. **1.4 — Spine enablers and kernel foundation.** (**Planned — foundational
   flagship: the kernel application and Pack contribution boundary; triad
   `docs/plans/v1.4-plan.md` + request-flow; governed by ADR 0046 and ADR 0065,
   plus ADR 0098 for the kernel inversions.**) The settings and action spine,
   sequenced first because every later release builds on it: one explicit,
   previewed, confirmed, preimage-backed per-fragment migration runner shipped
   with its first proven non-additive migration; verification of the already
   central cross-action param-contract inventory; and direct retirement of the
   `PermissionGate` compatibility facade after callers move to Security Central.
   Parameter validation and authorization remain separate contracts. The re-triage of
   the ADR 0076 packaging-trust exceptions rides here as an absorbed backlog
   item.
   **The kernel-redo analysis was accepted 2026-08-06 and merges into this
   release**: `apps/allbert_kernel`, registry inversion, settings inversion,
   gate inversion, deletion of the hand-maintained kernel lists, dependency
   closure/inversion before pure relocation of Home/Paths, Security Central
   with `HttpPolicy`, and the Capability plane, and
   **three proven pack extractions** (`notes_files`, then telegram and email).
   Relocation is deliberately **not** deferred: the next two releases build new
   subsystems, and without the kernel boundary they would land in the monolith
   and need moving later. **This release also records a generated
   topology/ownership supplement to the public-contract freeze.** The v1.0
   Tier-1/Tier-2 obligations and `release.v1` remain binding throughout 1.x;
   moving an implementation between OTP applications does not waive a frozen
   name or shape. ADR 0098 covers the pack contract, kernel application
   boundary, capability-tier model, and the additive topology supplement.
   **Sequencing rationale (one coordinated sweep):** the generated action roster
   is re-measured at M0; registry ownership, response-envelope consolidation,
   param-contract verification, and facade retirement overlap many of the same
   action files and therefore use one exclusive action-spine workstream rather
   than concurrent edits. **Hard ordering constraint inside this
   release** (analysis §13.3): gate inversion must precede module relocation,
   because the gate definitions name test paths and relocating a module
   relocates its test. Risk is bounded by exact-clean-SHA milestone checkpoints,
   explicit handoff packets, and proven revert/rollback boundaries. The only
   stable binary tag is `v1.4.0` unless an externally qualified
   `v1.4.0-rc.N` artifact is specifically required.

11. **1.5 — Knowledge Stage 1 (derived wiki over claims).** (**Proposed — intake
   closed 2026-07-30:** ADR 0094 + ADR 0095; triad at `docs/plans/v1.5-plan.md`
   + request-flow.) A derived, interlinked markdown page graph over v1.3 kept
   claims: page model, relative-markdown links with written backlinks,
   `index.md`, deterministic lint (contradictions, orphans, unresolved links,
   stale and under-populated pages), digest-based edit detection with promotion
   into a claim proposal or a connected-root note, workspace tile, and an
   `allbert knowledge` CLI group with TUI parity. No documents, no LLM, no
   egress, no new source policy, no new permission class, no fourth database.
   `knowledge.enabled` default false.
   **Sequencing rationale:** its product model consumes the shipped v1.3 Memory
   spine, but its implementation is architecturally dependent on v1.4's named
   pack contribution/settings/gate contract: new Knowledge capability must land
   as `allbert_knowledge`, not regrow the residual monolith. It remains
   independent of v1.7 connectivity and turns the Memory investment operators
   already made into something visible.

12. **1.6 — Knowledge Central (LLM Wiki flagship).** (**Proposed — intake closed
   2026-07-30:** same ADRs; triad at `docs/plans/v1.6-plan.md` + request-flow.)
   Stage 2: document ingest substrate, durable synthesis cache, source-summary
   pages, `log.md`, the operator-authored schema document with a confirmed
   review path, LLM-assisted lint, budgeted managed ingestion with named egress,
   and composite query across Memory, Search, and pages with every fact labelled
   by its origin layer. A guided "Research assistant" persona follows in a 1.6
   point release once the loop is proven with real operators.
   **Accepted consequence of shipping before connectivity:** ingest runs before
   1.7 consolidates the SSRF `private_ip?` table and hardens non-local bind, so
   this plan must bound its named egress on the un-consolidated path rather than
   assume that hardening.

13. **1.7 — Connectivity enablers.** (**Planned — triad
   `docs/plans/v1.7-plan.md` + request-flow + ADR 0096** (delegated OAuth
   authority).) Everything outward-facing: one OAuth substrate serving both
   email XOAUTH2 (Gmail/Microsoft) and OAuth-authenticated hosted LLM providers
   (subscription plans, not just API keys); MCP 2025-11-25 spec parity; and
   network hardening — non-local bind hardening plus free-form provider
   URLs/probe targets through the external-network approval path.
   **ADR 0098 placement:** new OAuth logic lands in the named `allbert_oauth`
   pack, email consumes it from the v1.4-extracted `allbert_email` pack, and the
   MCP client is extracted to `allbert_mcp` before its protocol delta; no new
   connectivity capability is authored in residual `allbert_assist`.
   **Sequencing rationale (code reuse):** the two OAuth consumers share an
   entire substrate (authorization-code flow, tier-vault token storage, refresh,
   revocation) and were previously tracked as unrelated entries; bind hardening
   and free-form provider URLs both touch `HttpPolicy`, so the SSRF
   `private_ip?` table currently triplicated across `external/http_policy.ex`,
   `voice/provider_http.ex`, and `settings/model_doctor.ex` is consolidated
   here. The v1.4 readiness review left that behavior change in v1.7: v1.4 moves
   `HttpPolicy` as kernel substrate but does not alter the table. Three copies
   of a security guard means fixing one leaves two holes, so v1.7 proves parity
   before deleting either duplicate.

14. **1.8 — Adaptive Usage Profiling.** (**Triad
   `docs/plans/v1.8-plan.md` + request-flow + ADR 0090 + the ADR 0084
   amendment. Readiness resets:** it was implementation-ready as v1.4, but
   unbundling removed M0.5/S5 and its anchors now sit six releases upstream, so
   it needs a fresh readiness pass when it comes up.) System usage memory +
   distill/suggest jobs + one-click CONFIRMED customizations (allowlisted,
   safety-floor-pinned) + observed-outcome feedback that makes no causal claim +
   prompt-rule variant tuning. Proactive suggestion notifications ride here, and
   by operator decision 2026-07-24 **Mobile-Ready Web stage 1** rides as
   non-flagship scope (Dynamic Mobile Breakpoints folds in; stages 2–4 remain
   the operator-owned responsive-information-architecture, offline-capable-PWA,
   and native-shell horizon).
   **Sequencing rationale:** nothing depends on it. Once preflight and
   `model_roles` were extracted to 1.3.2, the flagship became free to land last,
   which is where the least-depended-upon work belongs.
15. **Beyond — System Memory Distillation.** The parked learned/model-trained
   memory route. Knowledge Central does not replace it, and absorbing its slot
   is the recorded fallback if the ladder needs compression. Detail moved here
   from future-features.md on 2026-08-06 under the backlog lifecycle rule.

   Class: Must-candidate (confirmed 2026-07-14; co-flagship candidate for the 1.2/1.3 horizon, after the deterministic adaptive loop proves out) · Effort: L

   Status: parked.

   v0.39b ships the deterministic precursor: an inert `identity` system memory
   namespace (declared via the non-app system-namespace declarer and surfaced as
   a 5th `Memory` category under
   `<ALLBERT_HOME>/memory/identity/`) plus deterministic recency-weighted
   lexical Active Memory retrieval over reviewed `:kept` entries scoped to
   `{thread_id, active_app, identity_namespace}`. Replayable from traces.
   No embeddings; no learned ranking.

   v0.47 ships operator-supervised trace-derived draft suggestions. Neither
   v0.39b, v0.47, nor the v0.47b/`0.47.1` handoff draft release trains,
   distills, or creates a learned system-memory
   authority.

   Still parked:

   - nightly memory/personality distillation;
   - small local model training from operator history;
   - learned system-memory models that influence runtime behavior;
   - deletion, reproducibility, privacy, and eval policy for any trained memory
     artifact.

   The v0.31–v0.40 sweep confirms embedding-backed Active Memory retrieval and
   memory pinning are also parked under this entry (no separate section).

   Knowledge Central (LLM Wiki) does **not** replace this entry. That feature is the
   deterministic, projection-backed route; this one remains the learned/model-trained
   route and stays parked. Absorbing this slot is the recorded fallback if the
   release ladder later needs compression.

   The Won't-now cluster stays in future-features.md with its review cadence.
16. **2.0 — Turn Engine consolidation and remaining pack extraction.**
   (**Proposed** by the kernel-redo analysis §13.3, accepted 2026-08-06; no
   triad yet.) The one change on this ladder that genuinely needs a major:
   response shapes and signal names. Everything else the analysis proposes is
   1.x-legal — registry inversion preserves `modules/1` and `resolve/2`,
   settings inversion preserves key names and semantics, gate inversion is
   internal tooling, and module relocation preserves module names. Carries the
   remaining pack extraction and accumulated Tier-1 cleanup. Deliberately a
   **bounded** major, not a renumbering event that absorbs the 1.x remainder.

17. **2.1 horizon — Self-Hosting Development.** Allbert develops Allbert
   (pi-mode target on its own checkout; plan/build/test/document roles
   in-product, supervised). Its OAuth hosted-LLM providers sub-capability
   (Claude/OpenAI/Gemini subscription plans, not just API keys) lands earlier on
   the v1.7 connectivity train. **Moved from the 2.0 slot** by the kernel-redo
   analysis §13.3, which reserves 2.0 for Turn Engine consolidation and argues
   self-hosting is far more tractable against a small kernel and named packs
   than against a single 181,000-line application. Detail moved here from
   future-features.md on 2026-08-06.

   Class: Must-candidate (operator intake 2026-07-15) · Effort: XL · Slice: 2.0 horizon (post-1.3/1.4); sub-capabilities may land in earlier trains

   Allbert as the development environment for itself, for an Allbert developer:
   the workflow the operator runs today with an external assistant — planning
   LLM, developer LLM, tester, documenter roles over this repo — runs directly
   inside Allbert, via TUI, web workspace, or any channel, likely as a pi-mode
   target pointed at the Allbert checkout. Supervised, operator-driven
   development (plan → build → test → document with confirmations), NOT
   autonomous self-modification: the Won't-now self-recompilation boundary
   stays; this is Allbert as agent-harness/IDE for its own codebase. Builds on
   pi-mode (ADR 0068 coding trust tier), plan/build, delegate agents, and the
   v0.47 supervised-draft machinery. Freeze note: release.v1 must stay green
   under any self-hosted change flow — the gates become part of the loop.

   Sub-capability (separately shippable, earlier train): OAuth-Authenticated
   Hosted LLM Providers (Models & Memory).

   Deferred at: operator intake (post-1.0 planning, 2026-07-15).

## Working Rules

- **v1.4 adds a topology supplement; it does not re-baseline away the v1.0
  contract freeze.** `mix allbert.test release.v1` remains a stop condition on
  every 1.x change, including every v1.4 milestone. The closeout inventory
  records new OTP-application ownership, pack provenance, and additive
  contracts while carrying every v1.0 Tier-1/Tier-2 obligation forward. Tier-2
  changes stay additive; Tier-1 changes need a major. ADR 0081's promotion
  process is unchanged.
- Operator intake items enter future-features.md with class + effort + provenance,
  then slot into the ladder here.
- Upstream dependency refresh (confirmed 2026-07-15): every binary release plan
  carries a dependency-refresh milestone — review available updates across the tree
  (Jido stack, Phoenix/LiveView, Req, tooling), apply bounded updates, absorb the
  code changes, gates prove the result. A major/breaking upgrade may be scoped out
  to its own milestone or the next release with the reason recorded in the plan;
  an emergency hotfix release may skip the apply step (review still runs) with the
  skip recorded. (The rule's first standing checkpoint — the vendored `:memento`
  exit, ADR 0050 — resolved at the v1.0.1 M5 refresh.)
- Backlog lifecycle (operator decision 2026-08-06): an item is removed from
  future-features.md **when it enters this ladder**, not when its plan ships.
  Its detail lives here from that point on. In the roadmap ⇒ not in
  future-features; in future-features ⇒ no roadmap slot. Only an unplanned
  remainder stays parked there, with its provenance.
