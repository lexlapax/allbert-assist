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
| DIT-1: Cross-host install | WSL2 install/serve walkthrough; macOS + Linux `0.66.0` current | PENDING-OPERATOR (WSL2) / INHERITED (macOS+Linux) | `../v0.66/m2-macos-artifact-smoke.log`; CI linux-rehearsal PASS; WSL2 needs a Windows host |
| DIT-2: No-docs first-run | true non-developer: install → QuickStart → **one-click model download from an empty cache** → first useful chat, no dev docs; QuickStart enables direct answers first | PENDING-OPERATOR | needs a clean host + a true non-developer; keyless-local first chat itself is INHERITED (`../v0.66/m7-first-chat-keyless-local.log`) |
| DIT-3: Model-backed local knowledge | a later model-backed chat recalls only `:kept` memory; note-grounded answers/writes | PASS (recall) | `dit3-model-backed-recall.log` — packaged binary + local Ollama recalled the `:kept` "Falcon-9271" into a direct answer; `:kept`-only exclusion in the recall path is gate-proven (`v066_local_knowledge`) |
| DIT-4: Live advanced-surface regression | browser research + delegate, configured remote channels (in/out), MCP/OpenAI/ACP, Plan/Build approval | PENDING-OPERATOR | no provider creds / MCP servers / Docker configured; contract half gate-proven (`v066_advanced_surfaces`, `product-rc-advanced-surfaces-no-regression-001`) |
| DIT-5: Home portability + teardown | real `v0.66.0` packaged Home → v1.0 upgrade/import on a second host, then uninstall preserves Home | PENDING-OPERATOR | needs a real v0.66.0 Home + second machine; export/import dry-run is gate-proven (`v066_portability`, `product-rc-export-import-upgrade-001`) |
| DIT-6: Source/release-line parity | `v0.66.0` is the packaged artifact line; `origin/main` is the freeze-prep source | PASS (recorded) | `v0.66.0` remains GitHub Latest (cosign-signed, tap→0.66.0); `origin/main` carries the v1.0 freeze source (release.v1 gate + `:v1` sweep). If a source tag is needed pre-v1.0, use a docs/source point tag with `[skip-artifacts]` so `v0.66.0` stays Latest. |

## Freeze-blocking summary

Attestable in this checkout and done: **DIT-3** (model-backed `:kept` recall),
**DIT-6** (source parity). Inherited from v0.66 and current: macOS/Linux install, keyless
first chat, gate-proven contract halves.

**Still blocking the freeze (operator-attested on real hosts/providers):**
- DIT-1 WSL2 install
- DIT-2 true-non-developer no-docs first-run + one-click download from an empty cache
- DIT-4 live advanced-surface exercise (channels/MCP/browser/Plan-Build)
- DIT-5 real `v0.66.0` → v1.0 Home upgrade + uninstall-preserves-Home

The one recorded usability caveat (transient reconnect toast; ensure QuickStart reaches
the direct-answer enable step) is rechecked here at closeout. These are the items the
post-implementation audit hands to the operator before the v1.0 tag.
