# v0.66 Product RC — Attested Evidence Matrix

Two-layer verification (`docs/plans/v0.66-plan.md` Locked Decision 1). The
deterministic `mix allbert.test release.v066` gate proves contract/routing/boundary
invariants; **this directory holds the operator-attested second layer** — scripted
host smokes against a built binary, real-browser web smoke + the item-11 usability
audit, cross-platform/WSL2 installs, and real-egress model/advanced-surface runs.

Each row below is an attested-only or mixed evidence id from
`docs/plans/v0.66-request-flow.md`. Fill `Status`, `Evidence`, and `Commit/Artifact`
as each is exercised. Evidence must come from a disposable or explicitly declared
test `ALLBERT_HOME`, never a real operator home. Redact secrets, tokens, endpoints,
and raw provider bodies before committing anything here. Do not commit raw
screenshots that contain secrets or local evidence directories.

`Status` values: `PASS` (attested, evidence recorded) · `PENDING-OPERATOR` (requires
a host/environment not available in the implementation checkout — a clean machine,
Linux/WSL2, or a configured real model) · `BLOCKED` (a whole class could not be
exercised and is not scoped out) · `SCOPED-OUT` (explicitly deferred with rationale).

## Evidence rows

| Evidence id | Milestone | Layer | Status | Evidence artifact | Commit / Artifact ref |
|---|---|---|---|---|---|
| `product-rc-install-serve-onboard-local-knowledge-first-chat-001` | M1/M5 | attested | PARTIAL (macOS install+serve PASS; onboard/first-chat PENDING model+browser) | `m2-macos-artifact-smoke.log` for install→serve; onboard→first-chat needs a configured model | |
| `product-rc-web-usability-audit-item11-001` | M3 | attested (human audit) | PASS | `item11-usability-audit.md` — 5 surfaces smoked, 0 console errors, 1 explicit-v1.0-caveat (transient reconnect toast) | dev server, disposable home, 2026-07-11 |
| `product-rc-uninstall-preserves-home-001` | M9 | attested (host smoke) | PENDING-OPERATOR | uninstall log + Home-preserved listing | |
| `product-rc-no-docs-validation-001` | M3 | attested (fresh non-dev walk) | PENDING-OPERATOR | no-docs walkthrough notes | |
| `product-rc-consumer-default-oneclick-model-no-key-first-chat-001` | M7 | gate + attested | PENDING-OPERATOR (attested half) | one-click model download → first useful chat | |
| `product-rc-web-smoke-no-console-error-001` | M3 | gate + attested | PASS | gate: `v066_security_sweep` + `v066_web_render_dispatch`; attested: `item11-usability-audit.md` (/, /workspace, /jobs, /objectives, workspace:notes — 0 console errors) | |
| `product-rc-cli-tui-no-mix-needed-001` | M4 | gate + attested | PENDING-OPERATOR (attested half) | packaged-binary CLI/TUI transcript | |
| `product-rc-local-files-notes-memory-policy-bounded-001` | M5/M8 | gate + attested | | recall-in-later-chat transcript | |
| `product-rc-advanced-surfaces-no-regression-001` | M6 | gate + attested | | per-class advanced-surface run logs | |
| `product-rc-export-import-upgrade-001` | M9 | gate + attested | PENDING-OPERATOR (attested half) | real upgrade/import behavior log | |

Gate-only rows (`product-rc-profile-no-authority-regression-001`,
`product-rc-packaging-no-authority-regression-001`,
`product-rc-conversational-routing-no-misroute-001`,
`product-rc-evidence-secret-scan-001`, `product-rc-v1-handoff-current-001`) are
proved entirely by `release.v066` and need no row here; their evidence is the gate's
`release_evidence/v066/release-v066-*.json`.

## Cross-platform install matrix (M2)

| Platform | Harness | Status | Evidence |
|---|---|---|---|
| macOS (arm64) | `scripts/smoke/artifact_smoke.sh` | PASS | `m2-macos-artifact-smoke.log` — 8/8: toolchain-free boot, live `/health` (runtime up, db ok, 8 channels), attach round-trip, no Mix in image, portable crypto linkage. Built via `MIX_ENV=prod mix release allbert`. |
| Linux (curl installer / systemd) | `scripts/smoke/linux_rehearsal.sh` | PENDING-OPERATOR | version-agnostic harness ready; needs a Linux host (curl-install + CLI + vault/systemd rehearsal) |
| Windows / WSL2 | manual (no scripted harness) | PENDING-OPERATOR | fully manual install/serve walk on WSL2 |

## Advanced-surface regression classes (M6, Locked Decision 6)

| Class | Command | Status | Evidence |
|---|---|---|---|
| Browser research | `mix allbert.test external-smoke -- browser_research` | | |
| Browser research (delegate) | `mix allbert.test external-smoke -- browser_research_delegate` | | |
| Remote channels | per-provider `external-smoke` selectors | PENDING-OPERATOR | |
| Public protocols (MCP/OpenAI/ACP) | v0.51 command set | PENDING-OPERATOR | |
| Plan/Build approval | v0.44 workflow smoke | | |
| Export/import | portability dry-run + real round-trip | | |

## Deterministic core (this checkout)

`scripts/smoke/v066_product_rc.sh` runs the model-free product-RC core (onboarding
state machine + local files/notes/memory loop) on a disposable home. Record the
`smoke:<id>` transcript here when run.
