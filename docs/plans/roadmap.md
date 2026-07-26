# Allbert Roadmap (post-1.0)

The 0.x -> 1.0 roadmap is archived at [archives/1.0-roadmap.md](archives/1.0-roadmap.md)
(including the canonical 1.0 Acceptance Matrix). This roadmap covers the 1.x line.

## Release Model (1.x)

Every release is a **binary release**: tagged, CI-built, cosign-signed, published as a
GitHub Release, Homebrew tap filled. Each versioned plan covers one or more features and
ships as one or more point tags (1.0.1, 1.0.2, ...) that accumulate toward the next
minor (1.1, 1.2, ...). Minors carry one flagship feature each, foundational-first.
Plans follow the established triad convention (plan + request-flow, ADRs as needed);
the prioritization inventory is [future-features.md](future-features.md) — its Release
Ladder section is the operator-confirmed sequencing and is mirrored here.

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
5. **1.1 — Asynchronous Background Agent Fan-Out With In-Channel Steering.**
   (Operator intake 2026-07-18, inserted foundational-first. **Implementation
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
   channel event stayed `received`, and a raw stack reached the TUI. M12.19 is
   planned as the systemic correction: one production/dev SQLite connection,
   immediate effect-free transactions, atomic idempotent inbound admission,
   bounded operator errors, measured prompt/line responsiveness during active
   fan-out output, and a non-Sandbox concurrency proof. FV-01 is
   blocked until that focused/static/derived-v1.1 rejoin. The expanded
   `release.v11` definition covers the
   invariant/fault, exact-receipt, attended-surface, autonomous-channel,
   public-protocol, and operator-control paths. Its frozen-v1, derived-v1.1,
   pre-push, and authoritative release executions at the final committed SHA.
   M12.18's derived-v1.1 rejoin and flagship operator validation come first;
   the longer release cascade follows them by explicit operator sequencing:**
   `docs/plans/v1.1-plan.md` + request-flow + ADR 0083/0084/0085.) On a prompt
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
6. **1.2 — Zero-Click First Run.** (**Planned — triad ready 2026-07-24:**
   `docs/plans/v1.2-plan.md` + request-flow + ADR 0087 (detection-based
   enablement consent, operator-locked: auto-enable on any detected
   configured provider, local-first) / ADR 0088 (model catalog/chooser +
   fallback policy); ADR 0078/0069 amended. **Build starts after v1.1
   closeout.**) Chat-ready default with an auto-detected provisioned
   provider; onboarding optional and step-addressable; TUI first-run scope
   folded in. Enablers: model chooser/catalog, model fallback/degradation
   policy. Additive-only (migration runner stays at 1.5/1.6).
7. **1.3 — Long-Term User Memory.** (**Planned — research-gated triad ready
   2026-07-24:** `docs/plans/v1.3-plan.md` + request-flow + ADR 0089
   (memory architecture + consent; M1 research resolves LD-R1–R5 with
   operator sign-off). **Build starts after v1.2 closeout.**) Research
   phase first (STM/LTM/usage-history onto the Active Memory substrate),
   then periodic consolidation to a reviewable system-proposed tier and
   prompt-time context for zero-shot answers; only operator-kept entries
   ever enter prompts. Conversation FTS / cross-thread retrieval decided
   in/out at M1. Horizon items: free-form provider URLs, non-local bind
   hardening.
8. **1.4 — Adaptive Usage Profiling.** (**Planned — triad ready
   2026-07-24:** `docs/plans/v1.4-plan.md` + request-flow + ADR 0090
   (profiling + confirmed customization) + ADR 0084 amendment
   (`:suggestion` kind, quiet hours, rate limit). **Build starts after
   v1.3 closeout.**) System usage memory + distill/suggest jobs +
   one-click CONFIRMED customizations (allowlisted, safety-floor-pinned)
   + effectiveness feedback. Per-role model profiles and proactive
   suggestion notifications ride here — and, by operator decision
   2026-07-24, **Mobile-Ready Web stage 1** rides as non-flagship scope
   (Dynamic Mobile Breakpoints folds in; stages 2–4 stay at horizon).
9. **1.5 / 1.6 — enabler releases.** Migration-runner cluster (runner + telegram/email
   settings migration + legacy `intent.*model_profile` removal + automated rollback;
   pulled earlier if any prior release needs a non-additive migration), email OAuth
   (XOAUTH2), MCP 2025-11-25 spec parity, full param-contract enforcement,
   PermissionGate deletion. (Mid-action interruption, child-process
   cancellation, and the app-registry boundary check moved into 1.1.)
10. **Beyond** — System Memory Distillation is the post-profiling co-flagship
   candidate; the Won't-now cluster stays in future-features.md with its review
   cadence.
11. **2.0 horizon — Self-Hosting Development.** Allbert develops Allbert (pi-mode
   target on its own checkout; plan/build/test/document roles in-product, supervised).
   Its OAuth hosted-LLM providers sub-capability (Claude/OpenAI/Gemini subscription
   plans, not just API keys) lands earlier on the 1.5/1.6 enabler train.

## Working Rules

- The v1.0 public-contract freeze holds: `mix allbert.test release.v1` must stay green
  on every release; Tier-2 changes stay additive; Tier-1 changes need a major.
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
- Backlog lifecycle: an item that gains an implementation plan is marked
  `Status: planned — <plan doc>` in future-features.md and its ladder entry here
  links the plan triad. After the plan is implemented and tagged, the item is
  removed from future-features.md (only unplanned remainders stay) and this
  roadmap is updated accordingly (ladder entry marked shipped / re-sequenced).
