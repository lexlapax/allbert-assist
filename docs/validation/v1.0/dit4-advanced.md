# DIT-4 — Live Advanced-Surface Regression (v1.0 freeze prerequisite)

Operator-attested on 2026-07-14 (macOS host, source checkout at the v1.0 freeze source
on `origin/main`, local Ollama). Provider credentials came from the operator `.env`
(exported via `set -a; source .env; set +a`); no credential values appear below.
Findings raised during this exercise are folded into `docs/plans/v1.0-plan.md`
M7.1/M7.2 (R4, R5, R8, R9 as numbered there).

Class results per `docs/plans/v1.0-request-flow.md` §DIT-4:

| Class | Result |
|---|---|
| (a) Browser research + delegate | PASS |
| (b) Channels — outbound + inbound (Telegram) | PASS |
| (c) Public protocols — MCP / OpenAI-compatible / ACP | PASS (+ consent-gate observation) |
| (d) Plan/Build approval smoke | Gate PASS; typed same-channel approval FAIL (R9) — fixed, **operator re-run required** |
| Channel classes not configured | SCOPED-OUT: email, matrix, whatsapp, signal, discord, slack (credentials exist in `.env` for several, but the freeze bar is ≥1 outbound + ≥1 inbound, satisfied by Telegram; remaining channels stay covered by the v0.52/v0.53 channel-pack eval rows) |

## (a) Browser research + delegate

- `mix allbert.test external-smoke -- browser_research` — PASS (live Playwright driver).
- `mix allbert.test external-smoke -- browser_research_delegate` — first run crashed with
  `DBConnection.OwnershipError` (test-harness defect: missing sandbox checkout, fixed as
  M7.1/R4 — the smoke test now checks out a shared sandbox connection like the channel
  smokes). PASS after the fix: delegated CLI research completed and closed its session.

## (b) Channels — Telegram outbound + inbound

- Outbound: `mix allbert.test external-smoke -- telegram` — PASS
  (`1 test, 0 failures`, 1.7s). Evidence JSON was written to the temp gate Home
  (`.../release_evidence/v053/external-smoke-telegram-1784042346.json`).
- Inbound: `mix allbert.test external-smoke -- inbound_telegram` — PASS
  (`1 test, 0 failures`, 193.7s). Marker `allbert-v053-inbound-1784042697` sent from the
  mapped Telegram user in the configured chat and delivered through real long polling.
  Evidence JSON at `.../release_evidence/v053/external-smoke-inbound-telegram-1784042697.json`.
- **Evidence-retention note:** both gate-Home JSONs were purged by the OS temp cleaner
  before they were copied out. The operator terminal transcripts (marker, evidence-path
  printout, pass counts) are the retained record; the runbook now instructs copying the
  JSON immediately after each smoke.
- The inbound smoke lists 3 `manual_followups_required`:
  1. Telegram inline approve/deny/show button from the mapped clicker — SCOPED-OUT for
     v1.0 (inline-button callback path is gate-proven by the v0.52 channel-pack eval
     rows; the v1.0 freeze bar exercises the typed-command path, class (d)).
  2. Email typed approve/deny/show from the mapped sender — SCOPED-OUT (email channel
     not configured for this run; covered by v0.52 channel-pack eval rows).
  3. Unmapped-sender rejection before runtime — attested live during this DIT: unmapped
     TUI input was silently rejected before the runtime (see class (d) notes; same
     enforcement path).

## (c) Public protocols — MCP / OpenAI-compatible / ACP

Run against a disposable Home (`ALLBERT_HOME=/tmp/allbert-dit4-protocols-home`), surfaces
enabled per `docs/operator/public-protocol-surfaces.md`, per-client bearer tokens created
via `mix allbert.public_protocol token create` (tokens burned with the disposable Home).

- MCP stdio: `mix allbert.mcp_server status` → `mcp_server.enabled=true`,
  `mcp_stdio.enabled=true`, protocol versions `2025-06-18,2025-03-26`, `tools=3`;
  `tools list` / `resources list` clean.
- MCP HTTP: authed `POST /mcp {"method":"tools/list"}` returned exactly the 3 allowlisted
  tools (`direct_answer`, `external_network_request`, `get_public_call_result`) — no
  unlisted tool leaked.
- OpenAI-compatible: authed `GET /v1/models` returned only the enabled `local` alias.
  Authed `POST /v1/chat/completions` returned a real local-model completion echoing the
  requested marker (`allbert-dit4-ok`).
- ACP stdio: `mix allbert.acp_server status` → `acp_server.enabled=true`,
  `acp_stdio.enabled=true`, protocol version 1, `text_only` prompt capabilities.
- **Consent-gate observation (positive):** before the operator enabled
  `intent.direct_answer_model_enabled` + `intent.model_assist_enabled` (the flags
  onboarding flips), the authed chat-completions call returned a well-formed completion
  stating "The direct-answer model is disabled" — an authenticated public-protocol
  client cannot reach the model until the operator consent gate is enabled, and the
  refusal leaks nothing.

## (d) Plan/Build approval smoke (`:workflow_run_start` gate)

Workflow `dit4_smoke` (single `direct_answer` step) in the disposable Home;
`mix allbert.workflows list` / `inspect` validated it.

- **Finding (M7.1/R8):** `run workflow dit4_smoke` in the TUI first misrouted to
  `preview_plan` with empty slots (`:missing_plan_source` raw atom shown) — the v0.54
  two-stage router (production default `intent.router_strategy=two_stage_local`)
  overrode the deterministic ladder. Verified NOT gated by `intent.model_assist_enabled`.
  Worked around via `intent.router_strategy=deterministic`; fixed in M7.1 (plan_build
  phrases now bypass the router; regression test added).
- **Gate fired correctly** after the workaround: run paused pending
  `conf_1784047605000000_16962`, printed the exact typed commands
  `ALLBERT:APPROVE/DENY/SHOW:<id>` plus numbered options, `same_channel=true channel=tui`,
  and no button/link/URL affordance — criteria 1, 2 and 4 PASS.
- **Finding (M7.1/R9):** typing `ALLBERT:APPROVE:<id>` was silently ignored; the
  confirmation stayed `pending`. Traced: the confirmation record stamped
  `origin.channel: cli` (context key missing → default) while its own security context
  knew `channel: tui`; `verify_channel` therefore rejected the same-channel approval
  with `:wrong_channel`, and the TUI logged the rejection at debug level only.
  Diagnosis confirmed live: cold `mix allbert.confirmations approve <id>` (CLI channel)
  resolved it (`Resolver: local/cli`) and the resumed run **completed**
  (objective `obj_44ac8a21-1c06-45d6-a24f-d35adf15765d`, status `completed`) — the
  resume → objective → step machinery is healthy; the defect was isolated to the
  origin-channel stamp plus the silent rejection. Both fixed in M7.1 (channel derived
  from the security context; TUI now renders callback rejections; regression test
  covers same-channel typed approval end-to-end).
- **Criterion 3 (same-channel resolution) therefore FAILED as originally exercised.**
  The class closes only after the operator re-runs the smoke on the fixed build
  (single re-run: `run workflow dit4_smoke` → typed approve resolves in-session).

## Environment prerequisites attested along the way

- Fresh-Home TUI silently rejects unmapped input by design (v0.55 posture); identity
  map + `channels.tui.enabled` + `mix allbert.ecto.migrate` are required first (now
  inline in the runbook).
- `mix ecto.migrate.allbert` in `tui-channel.md` was a doc typo for
  `mix allbert.ecto.migrate` (fixed, M7.2/R7).
