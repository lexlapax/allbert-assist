# DIT-4 — Live Advanced-Surface Regression (v1.0 freeze prerequisite)

## v1.0.1 M4.2.3 class (a) closure attempt — 2026-07-15

**Verdict: FAIL — consent, callback, grant, and server-side execution pass, but
the completed research is not delivered to the thread or Research canvas. DIT-4
remains open.** This fifth class-only pass tested source commit `91724342` as a
locally rebuilt `allbert 1.0.1` release plus the live Mix external smokes. It used
the fresh disposable Home `/tmp/allbert-dit4-fifth.vG4i7S/home`; it did not use or
modify the Homebrew `allbert 1.0.0` installation.

The focused regression and both real browser harnesses were green:

```text
$ MIX_ENV=test mix test \
    apps/allbert_assist/test/allbert_assist/actions/browser_research_turn_test.exs
11 tests, 0 failures

$ ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test external-smoke -- browser_research
1 test, 0 failures

$ ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test external-smoke -- browser_research_delegate
1 test, 0 failures
```

The locally rebuilt release was served on port 4148 with `browser.enabled=true`
and `research.enabled=true`. The exact §I prompt produced exactly one up-front
confirmation and no objective before approval:

```text
Research https://elixir-lang.org and report the title of its latest blog post.
Use the browser research capability and include the source URL.

Browser research on https://elixir-lang.org needs your approval (confirmation
conf_1784142257000000_4226). Approving grants navigation on that site's URL prefix
and runs the research once through research.specialist; results land in the
workspace Research app.
Status: needs_confirmation
```

The same pending confirmation appeared both as the thread consent card and in
Settings Central's live queue. The queue described `browser_navigate`, risk high,
the target URL, and resource scope
`url_prefix:https://elixir-lang.org/`. Typing the exact callback in the web
composer was intercepted as a confirmation decision rather than intent-routed:

```text
ALLBERT:APPROVE:conf_1784142257000000_4226
```

The confirmation resolved through `local/live_view`, the pending queue returned
to zero, and Security Central recorded one active remembered grant:

```text
grant_1784142328708004_6530 · active · fetch · browser_navigator
url_prefix:https://elixir-lang.org/
```

The packaged admin surface confirmed that the one approval ran the delegated
research objective server-side with no second confirmation:

```text
obj_7a62ff0f-670d-4bba-8c3f-1b8357096c4f completed app=allbert_research research.specialist

Objective: obj_7a62ff0f-670d-4bba-8c3f-1b8357096c4f
Status: completed
- step_ebb85a68-3d0b-4f79-a8d3-1c174440339e completed delegate_agent
```

Delivery then failed the §I contract. The originating thread still showed only
the consent response and `0 objectives`; it never rendered a completion summary
or source URL. Opening Allbert Research showed `0/64 tiles`, `0 ephemerals`, and
`No canvas tiles yet`. M4.2.3 therefore closes the approval and execution seams,
but class (a) cannot pass until the server-side result is associated back to the
originating thread and materialized as the promised Research canvas output.

## v1.0.1 M4.2.2 class (a) closure attempt — 2026-07-15

**Verdict: FAIL — the two-stage approval flow is present, but the navigation-grant
resume fails and the research objective does not complete. DIT-4 remains open.**
This fourth class-only pass tested source commit `642afc27` as a locally rebuilt
`allbert 1.0.1` release plus the live Mix external smokes. It reused the disposable
Home `/tmp/allbert-dit4-v101.ACjz0J/home`; it did not use or modify the Homebrew
`allbert 1.0.0` installation.

The focused regression and both real browser harnesses were green:

```text
$ MIX_ENV=test mix test \
    apps/allbert_assist/test/allbert_assist/actions/browser_research_turn_test.exs
10 tests, 0 failures

$ ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test external-smoke -- browser_research
1 test, 0 failures

$ ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test external-smoke -- browser_research_delegate
1 test, 0 failures
```

The locally rebuilt release was served on port 4147 and received the exact §I
web-chat prompt:

```text
Research https://elixir-lang.org and report the title of its latest blog post.
Use the browser research capability and include the source URL.
```

It selected `browser_research_handoff`, created objective
`obj_cc0b2b54-0a1c-4010-b057-874b043355c5`, and paused for session confirmation
`conf_1784128002000000_6658`. Approving that confirmation re-drove the delegate
step and produced the expected second pause for navigation-grant confirmation
`conf_1784128067000000_8002`.

The second confirmation was not listed in the web Settings Central pending queue.
Submitting its exact typed callback through the web composer was treated as a new
marketplace intent rather than a confirmation decision, so the packaged admin CLI
was used against the same disposable Home after stopping the server. The approval
recorded successfully, but target execution failed:

```text
$ allbert admin confirmations approve conf_1784128067000000_8002 \
    --reason "DIT-4 navigation grant validation"
conf_1784128067000000_8002 status=approved
Resolver: local/cli
Browser session: session-7810
Browser target URL: https://elixir-lang.org
Browser resource remote_url browser_navigate fetch \
  url_prefix:https://elixir-lang.org/ consumer=browser_navigator
Target: browser_navigate status=failed
```

After restarting the same release and Home, the objective page reported
`failed delegate_agent` and `Objective step failed.` No completed objective,
summary, source URL, or Research tile was produced. M4.2.2 therefore proves that
session approval re-drives the delegate and preserves the navigation floor, but
does not yet satisfy the class (a) end-to-end acceptance contract.

## v1.0.1 M4.2.1 class (a) closure attempt — 2026-07-15

**Verdict: FAIL — routing is fixed, but approval cannot resume the packaged
research objective. DIT-4 remains open.** This class-only rerun tested source commit
`35b775d6` as a locally rebuilt `allbert 1.0.1` release plus the live Mix external
smokes. It reused the disposable Home `/tmp/allbert-dit4-v101.ACjz0J/home`; it did
not use or modify the Homebrew `allbert 1.0.0` installation.

The focused regression and both real browser harnesses are green:

```text
$ MIX_ENV=test mix test \
    apps/allbert_assist/test/allbert_assist/intent/intent_agent_router_test.exs
exit 0

$ MIX_ENV=test mix allbert.test external-smoke -- browser_research
1 test, 0 failures

$ MIX_ENV=test mix allbert.test external-smoke -- browser_research_delegate
1 test, 0 failures
```

The exact packaged §I web-chat prompt now clears the prior routing failure:

```text
Research https://elixir-lang.org and report the title of its latest blog post.
Use the browser research capability and include the source URL.
```

Instead of selecting `external_network_request`, the fixed release selected
`browser_research_handoff`, created objective
`obj_e2ee11d5-1e88-4d62-b2e0-5f740ce046aa`, and rendered an honest approval:

```text
Browser research on https://elixir-lang.org started as objective
obj_e2ee11d5-1e88-4d62-b2e0-5f740ce046aa and is waiting for your approval
(confirmation conf_1784123935000000_5634). After approval it resumes; results land
in the workspace Research app.
Status: needs_confirmation
```

The browser confirmation was then approved. Resume failed:

```text
Confirmation conf_1784123935000000_5634 is adapter_unavailable.
Approved, but not executed: this historical target had no adapter when it was
created. New v0.10 external-network requests use the confirmed Req adapter.
```

Packaged `admin objectives list` subsequently reported:

```text
obj_e2ee11d5-1e88-4d62-b2e0-5f740ce046aa blocked app=allbert_research research.specialist
```

No summary, source URL, completed objective, or Research tile was produced. The
M4.2.1 ladder fix therefore closes the `external_network_request` misroute but not
the end-to-end acceptance contract. The remaining seam is confirmation resume for
the plugin-scoped `browser_research_handoff` target: the UI promises resumption, but
the confirmation resolver has no adapter for that target.

## v1.0.1 fix re-attestation — 2026-07-15

**Verdict: FAIL (3 classes PASS; class (a) still fails through the packaged chat
surface).** This rerun tested source commit `509831b3` in two explicitly different
forms:

- locally built release `_build/prod/rel/allbert` reporting `allbert 1.0.1` for
  packaged TUI, channel-routing, ACP, MCP HTTP, OpenAI-compatible HTTP, and web-chat
  checks; and
- `MIX_ENV=test mix allbert.test external-smoke` for the repository's real browser
  and Telegram provider attestation harnesses.

It did **not** use the Homebrew `allbert 1.0.0` binary and is not Homebrew/tap proof.
All durable state used the disposable Home
`/tmp/allbert-dit4-v101.ACjz0J/home`; provider credentials came from the operator
`.env`, with no credential value printed or retained here.

| Class | Result |
|---|---|
| (a) Browser research + delegate | **FAIL / mixed** — both real Mix smokes pass, but the required locally built release web-chat prompt still routes to `external_network_request` and is denied instead of starting `browser_research_handoff`. |
| (b) Channels — outbound + inbound (Telegram) | **PASS** — packaged natural-language routing reached `send_channel_message`, approval completed, and the outbound marker arrived; the real inbound long-poll smoke received the operator-sent marker and passed. |
| (c) Public protocols — MCP / OpenAI-compatible / ACP | **PASS** — authenticated MCP and OpenAI-compatible calls passed; the new packaged ACP status and real initialize handshake passed with exit 0. |
| (d) Plan/Build approval smoke | **PASS** — the packaged TUI starts without the Req/Finch crash, accepts the workflow request, resolves the typed same-channel approval, resumes, and completes the objective step. |

### (a) Browser research + delegate — Mix PASS, packaged chat FAIL

The real external-smoke harnesses both passed on the fixed source:

```text
$ MIX_ENV=test mix allbert.test external-smoke -- browser_research
1 test, 0 failures

$ MIX_ENV=test mix allbert.test external-smoke -- browser_research_delegate
1 test, 0 failures
```

The locally built release was then run with `browser.enabled=true` and
`research.enabled=true`. In the real web workspace, the exact §I prompt was sent:

```text
Research https://elixir-lang.org and report the title of its latest blog post.
Use the browser research capability and include the source URL.
```

It failed twice, including after a server restart and with the Research app open:

```text
External network request was denied: :external_services_disabled.
Status: denied
```

The Research app remained at `0/64 tiles`, `0 ephemerals`, and `No canvas tiles
yet`. No research objective was created. This is not the old inert
`Browser research handoff proposed.` result, but it still fails the packaged-chat
acceptance contract: the request is routed to `external_network_request` rather than
the now-wired `browser_research_handoff`. The M4.2 action implementation and its Mix
smokes are green; the chat routing seam remains unproven/broken.

### (b) Telegram outbound + inbound — PASS

The locally built release configured the real Telegram token and mapped identity;
`admin channels telegram doctor` reported `status=ok`, `auth_ok=true`, and
`endpoint_ok=true`. The §G request:

```text
Send the exact message ALLBERT-V101-M43-OUTBOUND to my configured Telegram channel.
```

routed correctly:

```text
Status: needs_confirmation
Actions:
- send_channel_message needs_confirmation
```

Approval `conf_1784121959000000_323` resolved as `local/cli`; the target
`send_channel_message` completed, and the marker was visibly received in the mapped
Telegram chat at 06:26. The previous `external_network_request :missing_url`
misroute did not recur.

The real provider harnesses also passed:

```text
$ MIX_ENV=test mix allbert.test external-smoke -- telegram
1 test, 0 failures

$ ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test \
    mix allbert.test external-smoke -- inbound_telegram
marker: allbert-v053-inbound-1784121379 telegram
1 test, 0 failures (142.3s)
```

The operator sent that exact inbound marker from mapped Telegram user `7336421071`.
The retained JSON was copied before cleanup to
`/tmp/allbert-dit4-v101.ACjz0J/evidence/external-smoke-inbound-telegram-1784121379.json`.

### (c) MCP / OpenAI-compatible / ACP — PASS

With per-client tokens created in the disposable Home:

- authenticated MCP HTTP `tools/list` returned exactly `direct_answer`,
  `external_network_request`, and `get_public_call_result`;
- authenticated OpenAI-compatible `/v1/models` returned only `local`;
- a real `/v1/chat/completions` call returned exactly
  `ALLBERT-DIT4-V101-PROTOCOL`; and
- the new packaged ACP commands returned:

```text
acp_server.enabled=true
acp_stdio.enabled=true
acp_protocol_version=1
acp_transport=stdio_jsonrpc_ndjson
acp_prompt_capabilities=text_only
handshake=ok
handshake_result_protocol_version=1
handshake exit=0
```

This closes the v1.0.0 packaged revalidation's ACP proof gap.

### (d) Packaged TUI + Plan/Build same-channel approval — PASS

The empty-Home crash-seam probe exited normally with the designed setup guidance and
no `Req.FinchSupervisor` / `no process` failure:

```text
Allbert TUI is waiting for setup. Start the packaged service or run
`allbert serve --open`, then complete `allbert onboard`.
```

After packaged QuickStart, TUI identity mapping/enabling, and validation of the
one-step `dit4_smoke` workflow, the locally built release accepted a real PTY session.
`help` reached the runtime and returned a response. The default
`two_stage_local` router then produced the required gate:

```text
allbert:default> run workflow dit4_smoke
Approval: conf_1784120938000000_1666 status=pending target=start_plan_run
Result return: same_channel=true channel=tui
- ALLBERT:APPROVE:conf_1784120938000000_1666
- ALLBERT:DENY:conf_1784120938000000_1666
- ALLBERT:SHOW:conf_1784120938000000_1666
```

Typing the exact approval in the same TUI session created objective
`obj_d9d6ab57-1309-4491-9b5c-5277ae159068`, ran and completed its `direct_answer`
step, and printed:

```text
Confirmation conf_1784120938000000_1666 is approved.
Confirmations (1, status=all):
- conf_1784120938000000_1666: status=approved target=start_plan_run
```

`/quit` then exited cleanly. The v1.0.0 packaged TUI startup failure and the earlier
same-channel approval defects did not recur.

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
