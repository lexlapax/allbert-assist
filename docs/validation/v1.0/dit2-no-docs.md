# DIT-2 — True Non-Developer, No-Docs First Run (v1.0 freeze prerequisite)

**PASS** — operator-attested 2026-07-14, after three attempts across the second
validation pass. Environment: macOS host, locally built packaged binary
(`MIX_ENV=prod mix release allbert` from the freeze source on `origin/main` — no
released artifact carries the M7.x fixes), fresh disposable Home, **empty Ollama model
cache**, real non-developer at the keyboard (decision lock honored), no developer docs.

## Attempt log (each stumble = a blocking defect, fixed before the next attempt)

1. **Attempt 1 (failed):** capability question ("Help me understand what Allbert can
   do locally.") deflected to `show_app` demanding an "app id" (**R10**, router
   override of the deterministic ladder — fixed M7.3); no signal that first chat was
   unlocked (**R11** — go-signal added, M7.3).
2. **Attempt 2 (prep, failed):** two competing first-run entry points — Onboard
   panel "Start QuickStart" vs. main-panel "Set up your first model" hero (**R12** —
   single guided-setup entry point pre-onboarding, M7.4). Also surfaced en route:
   the curated model was hard-coded (**R13** → `first_model.curated_model` settings
   default, M7.5).
3. **Attempt 3 (PASS):** onboarding auto-opened → QuickStart → one-click download of
   the curated model from an EMPTY cache (no API key) → "You're ready to chat"
   go-signal appeared → capability question answered with the skills list (substantive,
   plain-language) → first useful chat reached. QuickStart enabled direct answers
   before the first real question.

## Post-pass recheck

- The long skills answer initially could not scroll in the chat pane (composer pushed
  off-screen). Live diagnosis: stale browser-cached CSS (**R15** — same-version
  rebuilds reuse the version-stamped stylesheet URL; hard reload required) stacked on
  a real height-chain break at the unclassed surface-renderer wrapper (**R14** — fixed
  M7.6, verified live via injected styles, then re-verified by the operator on a
  rebuilt binary after a hard reload).
- Item-11 caveat rechecks (packaged assets): no transient reconnect toast on the
  `/` → `/workspace` transition; QuickStart reached the direct-answer enable step
  before the first real question (both criteria in the runbook step 3 block).

## Bar assessment

All DIT-2 criteria met on the final attempt: true non-developer, no docs, one-click
model download from an empty cache, observable readiness (badge + step list +
go-signal), and a first *useful* chat. The five defects the attempts surfaced
(R10-R15, with R13 operator-requested) are fixed and regression-tested under plan
M7.3-M7.6 — exactly the launch-path hardening this DIT exists to force.
