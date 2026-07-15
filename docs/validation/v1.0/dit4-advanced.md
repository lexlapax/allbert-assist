# DIT-4 — Live Advanced-Surface Regression (v1.0 freeze prerequisite)

## Packaged v1.0.0 revalidation — 2026-07-15

**Verdict: FAIL.** The source-checkout attestation below is not reproducible from the
Homebrew-installed `allbert 1.0.0` artifact. This second pass used
`/opt/homebrew/bin/allbert` (`brew list --versions allbert` reported `allbert 1.0.0`)
and the disposable Home `/tmp/allbert-dit4-v100.L2QABO`; it did not use the source
checkout's Mix tasks or the operator's real `~/.allbert`.

| Class | Packaged-binary result |
|---|---|
| (a) Browser research + delegate | **FAIL** — the workspace completed the turn with only `Browser research handoff proposed.`; no research tile, delegation run, source URL, or researched answer appeared. |
| (b) Channels — outbound + inbound (Telegram) | **FAIL / incomplete** — live Telegram credential and endpoint checks passed, but the packaged ask path misrouted the outbound request to `external_network_request` and denied it as `:missing_url`; therefore no outbound marker was delivered. A genuine inbound marker was not requested after outbound had already failed. |
| (c) Public protocols — MCP / OpenAI-compatible / ACP | **PARTIAL PASS** — authenticated MCP HTTP and OpenAI-compatible calls passed; ACP was enabled but no packaged wire-level ACP handshake/status command was available, so ACP is not promoted to PASS. |
| (d) Plan/Build approval smoke | **FAIL / BLOCKED** — `allbert tui` crashes before accepting a prompt, so the same-channel approval flow cannot start. |

### Reproduction and retained observations

The disposable Home was onboarded with the packaged QuickStart flow, the TUI identity
was mapped/enabled, `intent.router_strategy=two_stage_local` was set, and the
`dit4_smoke` one-step workflow passed packaged `admin workflows list` and `inspect`.
Both a cold TUI start and a retry while packaged `allbert serve` was warm failed with:

```text
** (exit) exited in: GenServer.call(Req.FinchSupervisor, {:start_child, ...})
    ** (EXIT) no process: the process is not alive or there is no process
    (req) lib/req/finch.ex
    AllbertAssist.FirstModel.Ollama.default_get/2
    AllbertAssist.FirstModel.Ollama.server_version/1
```

This is a packaged-startup failure before the DIT-4(d) prompt, not a failed approval
decision. The apparent seam is that the TUI's first-model Ollama readiness check uses
Req/Finch before `Req.FinchSupervisor` is available.

For class (a), the packaged web workspace at `http://localhost:<port>/workspace`
accepted this real-model prompt:

```text
Research the official Elixir website and report the title of its latest blog post.
Use the browser research capability and include the source URL.
```

The runtime turn reported `Status completed` and the sole assistant result was
`Browser research handoff proposed.` Opening the Research app showed `0/64 tiles`,
`0 ephemerals`, and `No canvas tiles yet`.

For class (b), packaged `admin channels telegram set-token`, identity mapping, and
`admin channels telegram doctor` succeeded against the real configured endpoint:

```text
telegram doctor status=ok
auth_ok=true endpoint_ok=true
poller=disabled
```

The live packaged request
`allbert ask "Send the exact message ALLBERT-DIT4-V100-OUTBOUND to my configured Telegram channel."`
did not route to the channel-send action:

```text
Status: denied
External network request was denied: :missing_url.
Actions:
- external_network_request denied
```

For class (c), the packaged server used per-surface bearer tokens created inside the
disposable Home. Authenticated `/mcp` `tools/list` returned exactly
`direct_answer`, `external_network_request`, and `get_public_call_result`;
authenticated `/v1/models` returned only `local`; and a real
`/v1/chat/completions` request returned the marker `allbert-dit4-v100-ok`. ACP settings
reported enabled stdio, but the packaged CLI exposed token administration only and no
ACP status/handshake command. Tokens and the disposable settings key were not printed
or retained in this document.

This packaged result supersedes the PASS matrix below only for claims about what the
released Homebrew artifact itself proves. The earlier source-checkout record remains
useful as implementation and harness history, but it is not release-artifact proof.

Operator-attested on 2026-07-14 (macOS host, source checkout at the v1.0 freeze source
on `origin/main`, local Ollama). Provider credentials came from the operator `.env`
(exported via `set -a; source .env; set +a`); no credential values appear below.
Findings raised during this exercise are folded into `docs/plans/archives/v1.0-plan.md`
M7.1/M7.2 (R4, R5, R8, R9 as numbered there).

Class results per `docs/plans/archives/v1.0-request-flow.md` §DIT-4:

| Class | Result |
|---|---|
| (a) Browser research + delegate | PASS |
| (b) Channels — outbound + inbound (Telegram) | PASS |
| (c) Public protocols — MCP / OpenAI-compatible / ACP | PASS (+ consent-gate observation) |
| (d) Plan/Build approval smoke | **PASS** (re-run 2026-07-14 post-M7.1/M7.3 on default router config — see below) |
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
- **Criterion 3 (same-channel resolution) FAILED as originally exercised** and the
  class was held open pending the M7.1/M7.3 fixes.
- **Re-run PASS (2026-07-14, post-fix, operator-attested).** Fresh disposable Home,
  `intent.router_strategy=two_stage_local` (production default — also proving the R8
  fix live). Redacted transcript:

  ```
  allbert:default> run workflow dit4_smoke
  Approval: conf_1784059442000000_962 status=pending target=start_plan_run
  Allowed: approve, deny, details
  Result return: same_channel=true channel=tui
  Type one exact command:
  - ALLBERT:APPROVE:conf_1784059442000000_962
  - ALLBERT:DENY:conf_1784059442000000_962
  - ALLBERT:SHOW:conf_1784059442000000_962
  Approval options:
  1. Approve - ALLBERT:APPROVE:conf_1784059442000000_962
  2. Deny - ALLBERT:DENY:conf_1784059442000000_962
  3. Show - ALLBERT:SHOW:conf_1784059442000000_962
  allbert:default> ALLBERT:APPROVE:conf_1784059442000000_962
  Confirmation conf_1784059442000000_962 is approved.
  allbert:default> /confirmations
  Confirmations (1, status=all):
  - conf_1784059442000000_962: status=approved target=start_plan_run
  allbert:default> /quit
  $ mix allbert.plan list
  obj_5d0b8437-1c8b-4a1f-878e-157b6f7c3e05 completed workflow:dit4_smoke:1
  ```

  All four criteria PASS: (1) gate paused and printed the exact typed commands +
  numbered options; (2) typed `ALLBERT:APPROVE:<id>` at the same prompt; (3) the
  resolution printed **in-session** and `/confirmations` shows `approved` (R9 fix
  proven live); (4) no button/link/URL affordance in the terminal handoff. Bonus:
  no misroute on the default two-stage router (R8 fix proven live) and the resumed
  run's objective **completed**.

## Environment prerequisites attested along the way

- Fresh-Home TUI silently rejects unmapped input by design (v0.55 posture); identity
  map + `channels.tui.enabled` + `mix allbert.ecto.migrate` are required first (now
  inline in the runbook).
- `mix ecto.migrate.allbert` in `tui-channel.md` was a doc typo for
  `mix allbert.ecto.migrate` (fixed, M7.2/R7).
