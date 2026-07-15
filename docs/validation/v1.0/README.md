# v1.0 DIT Evidence Matrix (Freeze Prerequisites)

DIT = direct integration test: operator-attested evidence that the checkout-bound
`release.v1` gate cannot prove and that must run against real hosts, real packaged
artifacts, or real configured providers before the v1.0 freeze
(`docs/plans/archives/v1.0-handoff.md` §DIT Milestones). This directory records that evidence;
it inherits and links the v0.66 evidence (`docs/validation/v0.66/`) rather than
rewriting it.

`Status`: `PASS` (attested here) · `INHERITED` (proven in v0.66, still current) ·
`PENDING-OPERATOR` (needs a host/provider not available in this checkout) · `BLOCKED`.

| DIT | What it proves | Status | Evidence |
|---|---|---|---|
| DIT-1: Cross-host install | WSL2 install/serve walkthrough; macOS + Linux `0.66.0` current | SCOPED-OUT (WSL2) / INHERITED (macOS+Linux) | operator decision 2026-07-14: no Windows host available for the v1.0 closeout; WSL2 walkthrough deferred to the first post-1.0 opportunity (the installer path itself is exercised on Linux by the CI rehearsal). macOS: `../v0.66/m2-macos-artifact-smoke.log`; Linux: CI linux-rehearsal PASS |
| DIT-2: No-docs first-run | true non-developer: install → QuickStart → **one-click model download from an empty cache** → first useful chat, no dev docs; QuickStart enables direct answers first | PASS (2026-07-14) | `dit2-no-docs.md` — three attempts; the stumbles became fixed+regression-tested defects (R1-R3 first pass; R10-R15 second pass, plan M7.1-M7.6); final attempt met every criterion incl. the go-signal and both item-11 rechecks; keyless-local first chat also INHERITED (`../v0.66/m7-first-chat-keyless-local.log`) |
| DIT-3: Model-backed local knowledge | a later model-backed chat recalls only `:kept` memory; note-grounded answers/writes | PASS (recall) | `dit3-model-backed-recall.log` — packaged binary + local Ollama recalled the `:kept` "Falcon-9271" into a direct answer; `:kept`-only exclusion in the recall path is gate-proven (`v066_local_knowledge`) |
| DIT-4: Live advanced-surface regression | browser research + delegate, configured remote channels (in/out), MCP/OpenAI/ACP, Plan/Build approval | **PASS (2026-07-15, locally rebuilt 1.0.1)** | `dit4-advanced.md` §"v1.0.1 M4.2.4 class (a) closure" — sixth packaged §I pass proved one consent in thread + live queue, one approval, durable URL-prefix grant, zero further confirmations, completed thread-attributed objective, assistant summary/source, and both Output tiles. Combined with the earlier fix re-attestation where (b) Telegram, (c) MCP/OpenAI/ACP, and (d) Plan/Build passed, this closes all four DIT-4 classes. |
| DIT-5: Home portability + teardown | real `v0.66.0` packaged Home → v1.0 upgrade on a second host/Home + envelope export/dry-run import, then uninstall preserves Home | PASS (2026-07-14) | operator-attested per the corrected runbook step 4 (envelope export `--out` + file-level Home move → v1.0 local build against the v0.66.0 Home → dry-run import + health + notes/memory verified → confirmation-gated service uninstall → binary uninstall → Home preserved); transcript → `dit5-upgrade-uninstall.log`; export/import dry-run also gate-proven (`v066_portability`, `product-rc-export-import-upgrade-001`). Original runbook commands were unexecutable pre-correction (plan M7.2 R6) |
| DIT-6: Source/release-line parity | `v0.66.0` is the packaged artifact line; `origin/main` is the freeze-prep source | PASS (recorded) | `v0.66.0` remains GitHub Latest (cosign-signed, tap→0.66.0); `origin/main` carries the v1.0 freeze source (release.v1 gate + `:v1` sweep). If a source tag is needed pre-v1.0, use a docs/source point tag with `[skip-artifacts]` so `v0.66.0` stays Latest. |

## Freeze-blocking summary

Attestable in this checkout and done: **DIT-3** (model-backed `:kept` recall),
**DIT-6** (source parity). Inherited from v0.66 and current: macOS/Linux install, keyless
first chat, gate-proven contract halves.

**No DIT row blocks the freeze.** DIT-2/3/4/5/6 are PASS; DIT-1's WSL2 leg carries an
explicit operator SCOPED-OUT decision (no Windows host; macOS/Linux legs INHERITED).
Both item-11 usability caveats were rechecked clean inside DIT-2 (no reconnect toast on
packaged assets; QuickStart enabled direct answers before the first real question).

The two validation passes (2026-07-14) surfaced findings R1-R15, all fixed and
regression-tested under `docs/plans/archives/v1.0-plan.md` M7.1-M7.6. Phase A closes with the
matrix commit; the Release Closeout (version bump, tag, publish, tap) follows per
`v1.0-request-flow.md`.
