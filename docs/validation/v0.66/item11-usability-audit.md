# v0.66 M3 — Browser Web Smoke + Item-11 Non-Developer Usability Audit

Operator-attested evidence (two-layer model, plan Locked Decision 1 / 3). This is
the human, non-`AssertBinding` layer that complements the gate-proved render/dispatch
contract (`product-rc-web-smoke-no-console-error-001`).

- **Session:** 2026-07-11, macOS (arm64), Chrome via browser automation.
- **Build:** dev server (`mix phx.server`) on a disposable `ALLBERT_HOME` (fresh,
  not-yet-onboarded), port 4066, `/health` green (runtime up, db ok, 8 channels).
- **Scope:** render/console smoke of `/`, `/workspace`, `/jobs`, `/objectives`, and
  the `workspace:notes` destination + a non-developer walk of the first-run surface.

## Rubric (item-11 bar)

A finding is scored:

- **blocking-defect** — a non-developer cannot complete the primary launch path, is
  shown a broken/error state, or is led to a disabled/demo capability as if it were
  the product. Must be fixed in the owning capability area before v1.0.
- **explicit-v1.0-caveat** — a rough edge that does not block the launch path; recorded
  with a rationale and re-verified against the packaged build.
- **pass** — clear, self-explanatory, no developer knowledge required.

## Browser smoke results

| Route / surface | Render | Console errors | Notes |
|---|---|---|---|
| `/` (landing) | PASS | none | Direction-C hero, full nav rail, "Open workspace" / "Set up a model" CTAs, 3 value cards (Runtime-bound / Chat-primary / Inspectable). |
| `/workspace` | PASS | none | Chat-primary shell; onboarding panel **auto-opens on first run** with Guided setup (Start QuickStart / Advanced) and the trust-spine explainer (confirmation, permission, traces, local-first, egress, secrets, memory review). Docked-canvas + conversation rail present. |
| `/jobs` | PASS | none | Scheduled Jobs list with a seeded paused job, Run/Resume actions, shared shell/tokens, theme toggle. |
| `/objectives` | PASS | none | Clean empty-state ("No objectives yet") with a "Go to workspace" CTA. |
| `workspace:notes` | PASS | none | Docked Notes panel (ready) with search + a helpful empty-state that points a non-developer to onboarding or `allbert admin notes set-root PATH` and the `.md`/`.txt` requirement. Chat stays primary. |

Server log across the session: no `[error]`, no GenServer crash, no LiveView
terminate. Console across all routes: no errors/exceptions; only normal LiveView
lifecycle logs (`mount`, `join: 0 consecutive reloads`).

## Findings

1. **Transient "Something went wrong! Attempting to reconnect" toast on the
   `/` → `/workspace` transition** — *explicit-v1.0-caveat.* Navigating from the
   dead/controller landing (`/`, no live socket) into the LiveView workspace shows
   the default Phoenix reconnect banner for a moment during the socket handshake,
   then self-heals (console: `join: 0 consecutive reloads`, clean `mount`; no server
   error). It reads as a failure to a first-time user even though nothing failed.
   **Action:** re-verify against the packaged/prod build (faster asset serving changes
   the timing) before deciding whether to suppress the banner on the first
   dead→live transition. Not a launch-path blocker: `/workspace` renders fully.

2. **First-run surface is self-explanatory** — *pass.* On a fresh home, `/workspace`
   auto-opens onboarding, the trust spine is stated in plain language, and the notes
   empty-state names the exact next step. A non-developer is not required to read
   developer docs to know what to do next.

## Attested-only ids covered here

- `product-rc-web-usability-audit-item11-001` — this report.
- `product-rc-web-smoke-no-console-error-001` (attested half) — the render/console
  table above; the gate half is the `v066_security_sweep` + `v066_web_render_dispatch`
  steps.

## Not covered in this session (PENDING-OPERATOR)

- `product-rc-no-docs-validation-001` — a genuinely fresh non-developer completing the
  **full** launch path (install → model download → first useful chat) with a configured
  model. This session used a disposable dev home with no model, so first-chat value and
  the one-click model-download flow are attested in M7 against a configured model.
- `workspace:memory` destination render is covered by the `v066_web_render_dispatch`
  gate step (`workspace_live_test.exs`); a live browser capture is deferred to the
  packaged-build operator pass.
