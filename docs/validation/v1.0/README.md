# v1.0 DIT Evidence Matrix (Freeze Prerequisites)

DIT = direct integration test: operator-attested evidence that the checkout-bound
`release.v1` gate cannot prove and that must run against real hosts, real packaged
artifacts, or real configured providers before the v1.0 freeze
(`docs/plans/v1.0-handoff.md` §DIT Milestones). This directory records that evidence;
it inherits and links the v0.66 evidence (`docs/validation/v0.66/`) rather than
rewriting it.

`Status`: `PASS` (attested here) · `INHERITED` (proven in v0.66, still current) ·
`PENDING-OPERATOR` (needs a host/provider not available in this checkout) · `BLOCKED`.

| DIT | What it proves | Status | Evidence |
|---|---|---|---|
| DIT-1: Cross-host install | WSL2 install/serve walkthrough; macOS + Linux `0.66.0` current | PENDING-OPERATOR (WSL2) / INHERITED (macOS+Linux) | `../v0.66/m2-macos-artifact-smoke.log`; CI linux-rehearsal PASS; WSL2 deferred 2026-07-14 (no Windows host available) — run or flip SCOPED-OUT + rationale before the tag |
| DIT-2: No-docs first-run | true non-developer: install → QuickStart → **one-click model download from an empty cache** → first useful chat, no dev docs; QuickStart enables direct answers first | PENDING-OPERATOR | maintainer first-pass walkthrough (2026-07-14) surfaced launch-path defects R1/R2/R3 → fixed under plan M7.1/M7.2; the true non-developer run still required on the fixed build; keyless-local first chat INHERITED (`../v0.66/m7-first-chat-keyless-local.log`) |
| DIT-3: Model-backed local knowledge | a later model-backed chat recalls only `:kept` memory; note-grounded answers/writes | PASS (recall) | `dit3-model-backed-recall.log` — packaged binary + local Ollama recalled the `:kept` "Falcon-9271" into a direct answer; `:kept`-only exclusion in the recall path is gate-proven (`v066_local_knowledge`) |
| DIT-4: Live advanced-surface regression | browser research + delegate, configured remote channels (in/out), MCP/OpenAI/ACP, Plan/Build approval | PARTIAL (2026-07-14) | `dit4-advanced.md` — classes (a) browser, (b) telegram out+in, (c) MCP/OpenAI/ACP all PASS live; class (d) gate fired but same-channel typed approval FAILED (plan M7.1 R8/R9, fixed) — one operator re-run of the (d) smoke required on the fixed build |
| DIT-5: Home portability + teardown | real `v0.66.0` packaged Home → v1.0 upgrade on a second host/Home + envelope export/dry-run import, then uninstall preserves Home | PENDING-OPERATOR | original runbook commands were unexecutable (plan M7.2 R6 — no tar/apply-import exists); corrected line-by-line procedure now in `v1.0-request-flow.md` §DIT-5; export/import dry-run remains gate-proven (`v066_portability`, `product-rc-export-import-upgrade-001`) |
| DIT-6: Source/release-line parity | `v0.66.0` is the packaged artifact line; `origin/main` is the freeze-prep source | PASS (recorded) | `v0.66.0` remains GitHub Latest (cosign-signed, tap→0.66.0); `origin/main` carries the v1.0 freeze source (release.v1 gate + `:v1` sweep). If a source tag is needed pre-v1.0, use a docs/source point tag with `[skip-artifacts]` so `v0.66.0` stays Latest. |

## Freeze-blocking summary

Attestable in this checkout and done: **DIT-3** (model-backed `:kept` recall),
**DIT-6** (source parity). Inherited from v0.66 and current: macOS/Linux install, keyless
first chat, gate-proven contract halves.

**Still blocking the freeze (operator-attested on real hosts/providers):**
- DIT-1 WSL2 install (or explicit SCOPED-OUT decision — no Windows host as of 2026-07-14)
- DIT-2 true-non-developer no-docs first-run + one-click download from an empty cache
  (on the M7.1/M7.2-fixed build)
- DIT-4 class (d) re-run: `run workflow dit4_smoke` → same-channel typed approval
  resolves (classes a/b/c already attested in `dit4-advanced.md`)
- DIT-5 real `v0.66.0` → v1.0 Home upgrade + uninstall-preserves-Home (corrected runbook)

The one recorded usability caveat (transient reconnect toast; ensure QuickStart reaches
the direct-answer enable step) is rechecked here at closeout. The first validation pass
(2026-07-14) surfaced findings R1-R9, folded into `docs/plans/v1.0-plan.md` M7.1/M7.2
with fixes; the items above are what remains before the v1.0 tag.
