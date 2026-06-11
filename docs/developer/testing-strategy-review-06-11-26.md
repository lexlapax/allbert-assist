# Allbert Testing Strategy Review

**Produced for:** v0.52.0
**Based on:** `docs/developer/test-strategy.md`, code audit, benchmark records,
and the June 11, 2026 `release.v052` run
**Scope:** Gap analysis, coverage targets, prioritized recommendations, and example test cases

---

## Current State: What's Working Well

The project has a mature, well-documented testing infrastructure. The highlights:

- **1,667+ tests** across core, web, StockSage, and channel/plugin lanes as of v0.45.1 — zero failures at release
- **Structured lane taxonomy** (v0.41) with 9 lanes (`pure_async`, `db_serial`, `app_env_serial`, `home_fs_serial`, `global_process_serial`, `liveview_serial`, `security_eval_serial`, `external_runtime_serial`, `db_partition_safe`) and full reconciliation (zero unclassified files)
- **Tiered gate matrix**: `fast-local` (~23s), `commit`, `prepush` (~6–7 min high-coverage), and `release` (~778s with Dialyzer) with distinct semantics since v0.45.1
- **Security eval lane**: adversarial `SecurityEvalCase` tests covering dynamic codegen, sandbox execution, marketplace boundaries, MCP integration, and per-milestone eval fixtures — a relatively rare and valuable pattern
- **Static quality gates**: compiler `--warnings-as-errors`, Credo strict, Dialyzer with `error_handling`, `missing_return`, `extra_return`, `underspecs` flags — these catch real defects before runtime
- **Ownership contract enforced**: tests derive isolated `ALLBERT_HOME`, `DATABASE_PATH`, and named-process roots per partition; no writes to the operator's real `~/.allbert`
- **ExCoveralls** configured with 70% minimum, excluding test support and generated layouts
- **291 test files vs 582 source files**: ~1:2 ratio across core alone — respectable for a runtime with significant OTP complexity

---

## Release Long Poles (Performance Gaps)

These are the current bottlenecks that slow the release gate. The original
baseline was ~778 seconds, but the June 11, 2026 `release.v052` run shows that
the web long pole has grown enough to become an operator-readiness problem in
its own right. The baseline items are documented in `test-strategy.md`; the
v0.52 observation below should be treated as current release evidence.

| Module | Lane | Wall-clock | Proposed next step |
|---|---|---|---|
| `AllbertAssistWeb.WorkspaceLiveTest` | `liveview_serial` / release web child | ~256s baseline; 1242.5s in `release.v052` on June 11, 2026 | Split into functional slices or passivate runtime-heavy flows behind fake providers; consider an intermediate testing-strategy release before v0.53 channel expansion |
| `AllbertAssist.Agents.IntentAgentTest` | `external_runtime_serial` | ~154s | Profile which test cases hold real LLM/provider calls; passivate stubs where the test is checking routing logic, not model output |
| `AllbertAssist.RuntimeIntentAgentTest` | `external_runtime_serial` | ~69s | Same as above — runtime routing logic can be exercised without provider round-trips |
| `AllbertAssist.Execution.SkillScriptSpecTest` | `external_runtime_serial` | ~63s | Some script exec cases may be promotable to `global_process_serial` via a sandboxed runner stub |
| `StockSage.ObjectiveRuntimeTest` | `db_serial` | ~82s | Partition-safe after M8b; explore further fixture sharing to reduce setup cost |
| `AllbertAssistWeb.ThemeControllerTest` | `liveview_serial` | ~19s | Likely fixture-heavy; may benefit from shared setup |

The dominant win is in `external_runtime_serial` — 33 files classified there, but not all of them genuinely require a live external runtime. Auditing which tests in that lane are actually provider-free and reclassifying them to `global_process_serial` or `pure_async` would reduce the release gate significantly.

### June 11, 2026 v0.52 release-run observation

The `MIX_ENV=test mix allbert.test release.v052` run completed with passing
status and wrote evidence at
`release_evidence/v052/release-v052-1781187823.json`, but the
`workspace_continuity_web` phase dominated the run:

- `workspace_continuity_web` ran `mix test
  test/allbert_assist_web/live/workspace_live_test.exs` inside
  `apps/allbert_assist_web`.
- The phase passed with 69 tests, 0 failures, but took 1242.5 seconds
  wall-clock. A focused `--trace` diagnostic of the same file took 1268.9
  seconds.
- The release task buffers each child command until it exits, so the operator
  sees no progress for roughly 20 minutes. During remediation this looked like
  a stuck release gate and led to terminating two non-evidence attempts before
  the trace run proved the child was still advancing.
- The phase's redacted output tail included warning noise:
  `workspace fragment persistence unavailable` with `reason=:database_unavailable`,
  `persistence_failed`, `fragment_body_conflict`, `exception`, and one expected
  invalid-signature fragment drop. The tests still passed, but this is dirty
  release evidence and should be triaged separately from assertion failures.

This changes the priority of the testing work. The issue is no longer only
"make release faster"; it is also "make release observable and clean enough to
trust." A small intermediate testing release before v0.53 is reasonable if it
can deliver these without broad product changes:

- Split `WorkspaceLiveTest` into smaller files with explicit ownership and lane
  tags so the release wrapper can report progress at sub-slice granularity.
- Add release-step heartbeat or streaming output for long child commands, or at
  minimum print the child command and elapsed time while waiting.
- Add a dirty-log scanner to release evidence for known high-signal patterns
  such as `database is locked`, `SQLITE_BUSY`, `Exqlite.Connection`,
  `DBConnection.ConnectionError`, `database_unavailable`, and unexpected
  workspace fragment persistence drops.
- Separate expected negative-path warnings from infrastructure noise. For
  example, an intentionally invalid signature fixture should be asserted or
  suppressed as expected evidence, while database-unavailable persistence drops
  should remain actionable.
- Recut the release gate so channel-pack milestones can prove their deterministic
  contract without inheriting the entire historical workspace UI long pole as an
  opaque blocker.

---

## Coverage Gap Analysis

### Subsystems with no dedicated test directory

Comparing `apps/allbert_assist/lib/allbert_assist/` to `apps/allbert_assist/test/allbert_assist/`:

| Subsystem | Lib dir | Test dir | Assessment |
|---|---|---|---|
| `dev_gates` | ✅ exists | ❌ missing | The gate task helpers in `Mix.Tasks.Allbert.Test` do have tests in `test/mix/tasks/`; check whether all `dev_gates/` modules are exercised there or if there are structural helpers with no coverage |
| `sandbox` | ✅ exists | ❌ missing as standalone | Covered indirectly through `security_eval_serial` evals and `dynamic_plugins/` tests; worth a gap pass |

All other core subsystems (`actions`, `agents`, `approval`, `artifacts`, `channels`, `confirmations`, `conversations`, `drafts`, `dynamic_plugins`, `execution`, `extensions`, `external`, `intent`, `jido_backed`, `jobs`, `marketplace`, `mcp`, `memory`, `objectives`, `packages`, `plan_build`, `plugin`, `public_protocol`, `resources`, `runtime`, `self_improvement`, `session`, `settings`, `skills`, `surface`, `templates`, `theme`, `tools`, `voice`, `workflows`, `workspace`) have corresponding test directories.

### Plugin coverage thinness

| Plugin | Test location | Assessment |
|---|---|---|
| `allbert.artifacts` | `plugins/allbert.artifacts/test/` | Has tests; check artifact live view coverage in web lane |
| `allbert.browser` | Playwright-backed, `external_runtime_serial` | Playwright path is necessarily slow; consider a passivated stub mode for the pure Elixir bridge module |
| `allbert.discord` | `test/allbert_assist/channels/discord_test.exs`, `actions/channels/discord_doctor_test.exs` | Two test files for a new v0.52 feature — thin; see recommendations below |
| `allbert.slack` | Same pattern as Discord | Same thin coverage concern for v0.52 cross-channel threading |
| `allbert.research` | No dedicated test directory found in plugins | Unclear coverage — see below |
| `allbert.notes_files` | `plugins/allbert.notes_files/test/` | Has tests |
| `allbert.telegram` | `test/allbert_assist/channels/telegram_test.exs` | Single file; channel plugin lane has only 12 tests total |
| `allbert.email` | Same pattern | Same |

### `allbert.research` plugin coverage

The research plugin (`plugins/allbert.research/`) appears to have no `test/` subdirectory in the plugin directory itself. Research delegate agents are referenced in `docs/developer/delegate-agents.md` and `v046_research_delegate_eval_test.exs` exists as a security eval. However, functional/unit coverage of the research plugin actions and agents themselves likely lives only in the security eval layer, which means it is tested adversarially but not functionally.

**Recommendation:** Add `pure_async` or `app_env_serial` tests for the research plugin's core action dispatch path, independent of provider calls.

### v0.51 Public Protocol surfaces (MCP, OpenAI shim, ACP)

Tests exist at:
- `apps/allbert_assist_web/test/allbert_assist_web/public_protocol/mcp_http_controller_test.exs`
- `apps/allbert_assist_web/test/allbert_assist_web/public_protocol/openai_controller_test.exs`
- `apps/allbert_assist/test/allbert_assist/public_protocol/` (directory exists)

These are relatively new surfaces (v0.51). Ensure:
- All supported MCP tool/resource endpoints have at least one happy-path and one error-path test
- The OpenAI-compatible shim handles `model` field normalization and token counting correctly
- Rate-limiting / auth boundary behavior is tested, not just happy-path dispatch

### v0.52 Discord/Slack cross-channel threading

With Discord and Slack added in v0.52, the cross-channel threading feature is new and has thin coverage. Two channel test files and two doctor tests are present, but integration-level threading scenarios (e.g., message fan-out to multiple channels, thread reply routing, cross-channel identity resolution) are likely not tested.

---

## Coverage Targets

| Area | Current estimate | Recommended target | Priority |
|---|---|---|---|
| Core runtime (actions, agents, intent, objectives) | High (well-exercised by large suite) | Maintain ≥80% line coverage; ensure `pure_async` promotion continues | Hold |
| Security evals | All boundary cases covered per release | Continue per-milestone eval pattern; each new capability needs a `security_eval_serial` fixture | Hold |
| Public protocol surfaces (MCP, OpenAI, ACP) | Partial | ≥75% line coverage; happy + error + auth paths | Raise |
| Discord/Slack plugins | Thin (~2 files each) | Add 5–10 tests per channel covering thread routing, identity, and error paths | Raise |
| Research plugin functional coverage | Near-zero (only security evals) | Add unit tests for dispatch and action layer | New |
| WorkspaceLiveTest split | Single 256s file | Split into ≤4 files of ≤60s each under a new plan | Performance |
| `external_runtime_serial` audit | 33 files | Reclassify ≥10 files to narrower lanes (target: release gate under 600s) | Performance |

The project-wide ExCoveralls minimum of 70% is a floor. The recommendation is to treat 70% as a hard floor and target 80% for all subsystems that carry security-relevant or user-data-touching logic.

---

## Recommendations by Area

### 1. Audit `external_runtime_serial` lane for false positives

Several tests tagged `external_runtime_serial` may not actually require a live external runtime — they may have inherited the tag by proximity or conservative default. For each file in that lane:

- Does it call `Req.get/post`, spawn a Port, invoke Docker, or start a browser?
- If not, what is the real blocker? (Named process? App env? Shared DB?)
- Reclassify to the narrowest correct lane and record in the inventory

Even reclassifying 10–15 files from `external_runtime_serial` to `global_process_serial` or `app_env_serial` makes them available to the partitioned high-coverage local gate, shrinking the release gate.

### 2. Split WorkspaceLiveTest

This single test file accounted for ~33% of the earlier web test wall-clock
(256s of 305s web total), and in the June 11, 2026 `release.v052` run it took
1242.5s as a buffered release child. The recommended approach:

- Profile which test cases in `WorkspaceLiveTest` are slow due to real runtime calls vs. LiveView rendering
- Extract pure UI-rendering assertions into a `pure_async` or `liveview_serial` file with provider stubs
- Keep the runtime-confirming flows in a smaller residual file
- Add release-step visibility for the residual long-running file so operators
  can distinguish slow progress from a real hang
- Treat warning-free output as part of release quality for this slice, not just
  "69 tests, 0 failures"
- This is a separate plan item; do not split without proper lane annotations and a benchmark before/after

### 3. Add functional tests for `allbert.research` plugin

Security evals confirm that the research plugin cannot exceed its authority boundary, but they do not confirm that it dispatches correctly under normal conditions. Add tests that cover:

- `research` action receives a query and returns a structured result (unit, stub provider)
- Delegate agent receives objective step context and passes it to the action correctly
- Error handling when provider call fails mid-research

These are `app_env_serial` or `pure_async` depending on whether they touch the DB.

### 4. Expand Discord/Slack cross-channel threading tests

For v0.52, the threading feature needs tests covering:

- A message sent via Discord arrives at the correct channel thread in the runtime
- A Slack message reply routes to the originating thread, not a new one
- Cross-channel identity mapping (same user, two channels) resolves correctly
- A channel adapter error does not corrupt the session state for the other channel

### 5. Harden public protocol surface test coverage

For the MCP HTTP controller and OpenAI shim:

- Auth failure returns 401, not 500
- Unknown tool name returns a structured JSON error, not a crash
- Large context payloads are handled within configured limits
- The tool/resource list endpoint reflects only registered actions, not unrestricted internal access

### 6. Formalize the `dev_gates` coverage gap

Check whether `apps/allbert_assist/lib/allbert_assist/dev_gates/` contains structural helpers not exercised via `test/mix/tasks/`. If any modules are not indirectly covered, add targeted `pure_async` tests for the helper logic.

---

## Example Test Cases for Gap Areas

### Research plugin — dispatch unit test

```elixir
defmodule AllbertAssist.Research.DispatchTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  describe "research action dispatch" do
    test "returns structured result with stub provider" do
      # Arrange: configure a stub provider that echoes the query
      stub_result = %{summary: "stub result", sources: []}
      # Act: call the research action directly
      result = AllbertAssist.Actions.Registry.run(:research_query,
        %{query: "test topic"}, %{provider: :stub})
      # Assert: result matches the stub shape
      assert {:ok, %{summary: _}} = result
    end

    test "returns error tuple when provider raises" do
      result = AllbertAssist.Actions.Registry.run(:research_query,
        %{query: "test topic"}, %{provider: :failing_stub})
      assert {:error, _reason} = result
    end
  end
end
```

### Discord cross-channel thread routing

```elixir
defmodule AllbertAssist.Channels.DiscordThreadRoutingTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  describe "cross-channel thread routing" do
    test "incoming Discord message routes to existing thread, not new session" do
      user = insert(:user)
      # Seed an open session with an existing thread_id
      {:ok, session} = start_session(user, channel: :discord, thread_id: "T123")
      # Simulate a second message arriving on the same thread
      event = build_discord_message_event(user_id: user.id, thread_id: "T123")
      result = AllbertAssist.Channels.Discord.handle_message(event)
      # Assert the session is the same, not a new one
      assert {:ok, ^session} = result
    end

    test "cross-channel identity resolves the same user for Discord and Slack" do
      user = insert(:user)
      insert(:channel_identity, user: user, channel: :discord, external_id: "D_USER_1")
      insert(:channel_identity, user: user, channel: :slack, external_id: "S_USER_1")
      assert AllbertAssist.Channels.resolve_identity(:discord, "D_USER_1") ==
             AllbertAssist.Channels.resolve_identity(:slack, "S_USER_1")
    end
  end
end
```

### Public protocol — MCP auth boundary

```elixir
defmodule AllbertAssistWeb.PublicProtocol.MCPAuthTest do
  use AllbertAssistWeb.ConnCase, async: false
  @moduletag :liveview_serial

  describe "MCP HTTP controller auth" do
    test "missing bearer token returns 401 with structured error" do
      conn = post(build_conn(), "/mcp/v1/tools/call", %{"name" => "some_tool"})
      assert conn.status == 401
      assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
    end

    test "unknown tool name returns structured error, not 500" do
      conn = authenticated_conn()
        |> post("/mcp/v1/tools/call", %{"name" => "nonexistent_tool"})
      assert conn.status == 404
      body = json_response(conn, 404)
      assert body["error"]["code"] == "tool_not_found"
    end
  end
end
```

### external_runtime_serial audit — reclassification example

Before reclassification, check a candidate file's actual resource use:

```sh
# Identify files in external_runtime_serial that don't reference external calls
mix allbert.test inventory --output /tmp/inventory.csv
grep "external_runtime_serial" /tmp/inventory.csv | \
  while read file; do
    grep -l "Req\.\|Port\.\|Docker\|playwright\|browser_driver" "$file" || echo "CANDIDATE: $file"
  done
```

Files not matching real external call patterns are candidates for reclassification to `global_process_serial` or `app_env_serial`.

---

## Gate Commands Reference

| Goal | Command |
|---|---|
| Quick daily check | `mix allbert.test fast-local` |
| High-coverage local (core + StockSage + web) | `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions 4` |
| Pre-push confidence | `mix allbert.test prepush` |
| Release authority | `mix allbert.test release` |
| Focused test | `mix allbert.test focused -- <file...>` |
| Lane inventory with tag check | `mix allbert.test inventory --check-tags --output docs/developer/v0.41-test-inventory.csv` |
| Specific lane partitioned | `mix allbert.test serial-core --lane db_serial --partitions 4` |
| External smoke (explicit opt-in) | `mix allbert.test external-smoke -- <smoke-name>` |

`mix precommit` is a compatibility shortcut for `mix allbert.test commit`. It is not release evidence.

---

## Implementation Plan Annotation (for the next test-improvement milestone)

If a future milestone addresses any recommendations above, it must include:

- **Parallel workstreams**: reclassification audit (doc-only pass), new plugin test files, public protocol tests
- **Serial barriers**: `WorkspaceLiveTest` split requires ConnCase/LiveView ownership analysis; any DB-touching new tests need DataCase lane assignment
- **Gate evidence**: focused test runs on new files; `mix allbert.test inventory --check-tags` must stay zero-unclassified after additions; release evidence must include per-phase timing and dirty-log scan results
- **Rejoin point**: after all new test files pass focused gates, run full `mix allbert.test release` and record benchmark delta vs. v0.45.1 baseline
- **Coverage target**: run `mix coveralls.json` and confirm no subsystem regresses below 70%; target subsystems above 80% at handoff
