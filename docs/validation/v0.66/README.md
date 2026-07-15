# v0.66 Product RC — Attested Evidence Matrix

Two-layer verification (`docs/plans/archives/v0.66-plan.md` Locked Decision 1). The
deterministic `mix allbert.test release.v066` gate proves contract/routing/boundary
invariants; **this directory holds the operator-attested second layer** — scripted
host smokes against a built binary, real-browser web smoke + the item-11 usability
audit, cross-platform/WSL2 installs, and real-egress model/advanced-surface runs.

Each row below is an attested-only or mixed evidence id from
`docs/plans/archives/v0.66-request-flow.md`. Fill `Status`, `Evidence`, and `Commit/Artifact`
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
| `product-rc-install-serve-onboard-local-knowledge-first-chat-001` | M1/M5 | attested | PARTIAL (macOS install+serve PASS on 0.66.0; onboard/first-chat PENDING model+browser) | `m2-macos-artifact-smoke.log` for install→serve; onboard→first-chat needs a configured model | local prod release `allbert-0.66.0`, 2026-07-12 |
| `product-rc-web-usability-audit-item11-001` | M3 | attested (human audit) | PASS | `item11-usability-audit.md` — 5 surfaces smoked, 0 console errors, 1 explicit-v1.0-caveat (transient reconnect toast) | dev server, disposable home, 2026-07-11 |
| `product-rc-uninstall-preserves-home-001` | M9 | attested (host smoke) | PENDING-OPERATOR | uninstall log + Home-preserved listing (deterministic contract in `InstallPathTest`; real host uninstall needs an installed binary to remove) | |
| `product-rc-no-docs-validation-001` | M3 | attested (fresh non-dev walk) | PENDING-OPERATOR | no-docs walkthrough notes | |
| `product-rc-consumer-default-oneclick-model-no-key-first-chat-001` | M7 | gate + attested | PASS | gate: `v066_security_sweep` + `v066_routing_first_model`; attested: `m7-first-chat-keyless-local.log` — packaged `bin/allbert` detected `local_ready` and answered via local Ollama qwen2.5 with **no API key**. One-click *download* itself (from empty) still PENDING-OPERATOR | macOS, disposable home |
| `product-rc-web-smoke-no-console-error-001` | M3 | gate + attested | PASS | gate: `v066_security_sweep` + `v066_web_render_dispatch`; attested: `item11-usability-audit.md` (/, /workspace, /jobs, /objectives, workspace:notes — 0 console errors) | |
| `product-rc-cli-tui-no-mix-needed-001` | M4 | gate + attested | PASS | gate: `v066_security_sweep` + `v066_cli_tui_dispatch`; attested: `m4-packaged-cli-smoke.log` — packaged `bin/allbert` version/--help(grouped)/admin status/admin health all toolchain-free | macOS `allbert-0.66.0`, disposable home |
| `product-rc-local-files-notes-memory-policy-bounded-001` | M5/M8 | gate + attested | PASS (gate) / PENDING-OPERATOR ([model] recall-in-chat) | gate: `v066_security_sweep` (floors) + `v066_local_knowledge` (root-bounding fail-closed, :kept-only recall, review transitions — 22 tests); attested [model]: recall influencing a real later chat needs a configured model | deterministic core proven; `scripts/smoke/v066_product_rc.sh` core 8/8 |
| `product-rc-advanced-surfaces-no-regression-001` | M6 | gate + attested | PASS (gate) / PENDING-OPERATOR (live per-class) | gate: `v066_security_sweep` (agent/internal capability sets disjoint, advanced actions registered) + `v066_advanced_surfaces` (public-protocol/channel/MCP/browser exposure evals, 35 tests); live per-class needs configured providers/servers/model | `m6-external-smoke-selectors.log` |
| `product-rc-export-import-upgrade-001` | M9 | gate + attested | PASS (gate) / PENDING-OPERATOR (real cross-version upgrade) | gate: `v066_security_sweep` (export ref+status, import dry-run blocks) + `v066_portability` (full export/import test, 4 tests); real v0.58/v0.59→v0.66 Home upgrade needs an old-version home | |

Gate-only rows (`product-rc-profile-no-authority-regression-001`,
`product-rc-packaging-no-authority-regression-001`,
`product-rc-conversational-routing-no-misroute-001`,
`product-rc-evidence-secret-scan-001`, `product-rc-v1-handoff-current-001`) are
proved entirely by `release.v066` and need no row here; their evidence is the gate's
`release_evidence/v066/release-v066-*.json`.

## Cross-platform install matrix (M2)

| Platform | Harness | Status | Evidence |
|---|---|---|---|
| macOS (arm64) | `scripts/smoke/artifact_smoke.sh` | PASS | `m2-macos-artifact-smoke.log` — 8/8 against `allbert-0.66.0`: toolchain-free boot, live `/health` (runtime up, db ok, 8 channels), attach round-trip, no Mix in image, portable crypto linkage. Built via `MIX_ENV=prod mix release allbert --overwrite`. |
| Linux (curl installer / systemd) | `scripts/smoke/linux_rehearsal.sh` | PASS (CI) | the v0.66.0 release-artifacts workflow `linux-rehearsal` job (ubuntu-22.04) passed against the built linux-x64 artifact; both linux-x64 + linux-arm64 tarballs built + published |
| Windows / WSL2 | manual (no scripted harness) | PENDING-OPERATOR | fully manual install/serve walk on WSL2 |

## Advanced-surface regression classes (M6, Locked Decision 6)

Gate contract for every class is proven by `v066_advanced_surfaces` (35 exposure/floor
tests). The rows below are the **live** exercise (Locked Decision 6 bar). No channel
provider, MCP server, Docker daemon, or model is configured in the implementation
checkout, so live runs are `PENDING-OPERATOR` with the exact commands — not scoped out.

| Class | Live command | Status | Evidence |
|---|---|---|---|
| Browser research | `mix allbert.test external-smoke -- browser_research` | PENDING-OPERATOR | needs browser + model |
| Browser research (delegate) | `mix allbert.test external-smoke -- browser_research_delegate` | PENDING-OPERATOR | needs browser + model |
| Remote channels | per-provider `external-smoke` selectors (telegram/email/matrix/slack/discord/whatsapp/signal, + inbound) | PENDING-OPERATOR | needs provider creds; ≥1 outbound + ≥1 inbound class |
| Public protocols (MCP/OpenAI/ACP) | v0.51 command set | PENDING-OPERATOR | needs a running MCP/OpenAI/ACP client |
| Plan/Build approval | v0.44 workflow smoke | PENDING-OPERATOR | needs a model to drive a plan run |
| Export/import | portability dry-run (gate, M9) + real round-trip | PASS (dry-run gate, see M9) / PENDING-OPERATOR (real round-trip) | M9 `v066_portability` |

## Deterministic core (this checkout)

`scripts/smoke/v066_product_rc.sh` runs the model-free product-RC core (onboarding
state machine + local files/notes/memory loop) on a disposable home. Record the
`smoke:<id>` transcript here when run.

2026-07-12 post-audit rerun: PASS outside the sandbox. The sandboxed run failed
before product checks because Mix/PubSub local socket creation returned `:eperm`;
the unsandboxed run passed `onboard-state-fresh`, notes root connect/fail-closed,
notes search/read, memory candidate, and review-keep.
