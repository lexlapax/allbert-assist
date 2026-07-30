# Simplification Opportunities: Dead Code

Survey date: 2026-07-29. Baseline commit: `c7ee5a29`.

This is a findings document, not a milestone plan. It records code that is
unreachable or unreferenced and could be removed. Nothing here has been deleted;
nothing here is scheduled. Scope decisions belong in the roadmap and the active
version plan.

Companion documents:

- `docs/plans/simplification-opportunity-abstractions.md` — duplicate and
  near-duplicate abstractions in production code
- `docs/plans/simplification-opportunity-tests.md` — tests that carry no
  regression value

## Method

1. `mix compile --force --all-warnings` over the umbrella (Elixir 1.19.5,
   OTP 29). One warning total.
2. A reference analyzer over 1,173 modules and 3,384 public functions in
   `apps/*/lib` and `plugins/`, indexing every dotted alias suffix so partial
   aliases (`Backends.MacOSSayTTS`) resolve, and excluding dynamic-dispatch
   surfaces: `@impl` callbacks, OTP callbacks, Phoenix callbacks and function
   components, HEEx `<.component>` references, and the action-registry `run/2`
   contract.
3. Per-candidate verification by direct grep across `.ex`, `.exs`, `.heex`,
   `.eex`, config, and priv.

### Analyzer defect log

The analyzer produced four wrong answers before it produced this one. Recorded
because it calibrates how much to trust the remaining list, and because anyone
re-running this analysis will hit the same traps.

| Defect | False positives produced |
| --- | ---: |
| Trailing `\b` in the identifier regex never matched `foo!` / `foo?` names | 266 |
| Lookbehind excluded `.`-preceded matches, killing every `Module.function` call site | 876 |
| Whole-line skip on `def` lines hid callers inside one-line `def f, do: g()` bodies | 10 |
| `defdelegate ... as: :target` call sites not treated as references | 2 |

Every surviving candidate in section 3 was then verified individually by grep
showing only its own `def` and `@spec` lines. Spot-check before deleting anyway.

## Summary

| Category | Count |
| --- | ---: |
| Modules defined in `lib` | 1,173 |
| Dead modules | **1** |
| Public functions considered | 3,384 |
| Dead public functions | **22** |
| Compiler-flagged unreachable clauses | **1** (needs reconciliation, see §2) |
| Production functions referenced only by tests | 74 |

Dead code is close to nonexistent in this codebase. One module out of 1,173, and
the compile is otherwise warning-clean, which matches the AGENTS.md
warning-free-handoff rule.

---

## 1. Dead module — `StockSage.Agents.DelegatePlugin`

`plugins/stocksage/lib/stocksage/agents/delegate_plugin.ex` — 22 lines.

Declares a `Jido.Plugin` named `"stocksage_delegate"` with signal route
`{"allbert.objectives.delegate.execute", StockSage.Agents.Commands.Execute}`.

**`StockSage.Agents.Specialist` declares the identical route**
(`plugins/stocksage/lib/stocksage/agents/specialist.ex:11`) and is the live path
— a `__using__` macro consumed by eight agent modules: `bull_thesis`,
`bear_thesis`, `quality_gate`, `trader_plan`, `market_context`, `risk_neutral`,
`risk_aggressive`, `decision_synthesizer`.

`DelegatePlugin` is never registered, never referenced, and its plugin name
string `"stocksage_delegate"` appears nowhere else in the repository. It is
superseded duplicate wiring.

### Do not delete: `AllbertAssistWeb.PageHTML`

`apps/allbert_assist_web/lib/allbert_assist_web/controllers/page_html.ex` also
scans as unreferenced. It is alive — Phoenix resolves it from `PageController`
via the `:html` format convention, which no grep can see. Recorded so a future
sweep does not remove it.

---

## 2. Compiler-flagged unreachable clause — UNRESOLVED

`mix compile --force --all-warnings` emitted exactly one warning:

```
warning: the following clause will never match:

    {:error, reason}

because it attempts to match on the result of:

    stream_suppressed?(stream, tombstones)

which has type:

    dynamic({:ok, term()})

 323 │       {:error, reason} -> {:halt, {:error, reason}}

 lib/allbert_assist/memory/projection.ex:323:
 AllbertAssist.Memory.Projection.insert_unsuppressed_candidate/4
```

**This does not reconcile with the source.** Reading
`apps/allbert_assist/lib/allbert_assist/memory/projection.ex` directly,
`insert_unsuppressed_candidate/4` begins at line 320 and its `case` has only two
clauses:

```elixir
defp insert_unsuppressed_candidate(conn, stream, acc, tombstones) do
  case stream_suppressed?(stream, tombstones) do
    {:ok, true} -> skip_candidate(acc, stream.path, :forgotten_value_suppressed)
    {:ok, false} -> insert_candidate(conn, stream, acc)
  end
end
```

No `{:error, reason}` clause is present at line 323 or anywhere in that
function. Possible explanations: a stale build artifact, a line-offset
discrepancy in the diagnostic, or a second similar call site elsewhere in the
file. **Re-run `mix compile --force --all-warnings` and reconcile before
touching this file.**

Note the second reading if the clause does exist: `stream_suppressed?/2`
delegates to `Forget.suppressed_value?/2`, and both its own clauses return
`{:ok, _}`. If the caller was written expecting `{:error, _}`, the defect may be
in `Forget.suppressed_value?/2`'s contract rather than in the caller — deleting
the clause would then paper over a real error path rather than remove dead code.

---

## 3. Dead public functions — 22

Each verified by grep showing only its own `def` and `@spec` lines.

### Core app — 14

| Function | Location |
| --- | --- |
| `Artifacts.ThreadLinks.record_referenced/3` | `artifacts/thread_links.ex:30` |
| `Channels.channel_provider/1` | `channels.ex:189` |
| `CLI.FirstRun.enablement_state/2` | `cli/first_run.ex:55` |
| `Coding.StreamPipeline.emit_stream_response/3` | `coding/stream_pipeline.ex:43` |
| `Health.healthy?/0` | `health.ex:35` |
| `Intent.Engine.annotate_response/1` | `intent/engine.ex:144` |
| `Objectives.Proposer.proposer_for/1` | `objectives/proposer.ex:66` |
| `Paths.search_projection_root/0` | `paths.ex:168` |
| `PublicProtocol.OpenAI.Mapping.sse_payload/1` | `public_protocol/openai/mapping.ex:146` |
| `PublicProtocol.TokenAuth.allowed_surface?/1` | `public_protocol/token_auth.ex:111` |
| `Settings.ModelRuntime.provider_string/1` | `settings/model_runtime.ex:73` |
| `Settings.Models.capable?/2` | `settings/models.ex:60` and `:65` |
| `Surface.Catalog.renderer_components/0` | `surface/catalog.ex:285` |
| `Tools.Finder.find_local/2` | `tools/finder.ex:17` |

**Care point on `Paths.search_projection_root/0`.** Its siblings are not dead:
`memory_projection_root/0` has 16 call sites and `projections_root/0` is called
by both. Only the search half is unused. Removing the projections family
wholesale would break the Memory projection.

### Web — 1

| Function | Location |
| --- | --- |
| `AllbertAssistWeb.CoreComponents.translate_errors/2` | `components/core_components.ex:495` |

Phoenix generator leftover. The singular `translate_error/1` is used; the plural
wrapper never was.

### Channel plugins — 7

| Function | Location |
| --- | --- |
| `Discord.Client.users_me_request/1` | `allbert.discord/lib/.../client.ex:97` |
| `Discord.Client.start_thread_from_message_request/4` | `allbert.discord/lib/.../client.ex:101` |
| `Matrix.Client.whoami_request/1` | `allbert.matrix/lib/.../client.ex:85` |
| `Slack.Client.auth_test_request/1` | `allbert.slack/lib/.../client.ex:59` |
| `WhatsApp.Client.send_buttons_request/5` | `allbert.whatsapp/lib/.../client.ex:94` |
| `WhatsApp.Client.phone_number_request/1` | `allbert.whatsapp/lib/.../client.ex:125` |
| `TUI.Renderer.render_stream_events/2` | `allbert.tui/lib/.../renderer.ex:51` |

Confirmed **not** behaviour callbacks — no `@callback` in the repository
declares any `*_request`. The only `@callback` hits matching that pattern are
type names in `voice/provider_adapter.ex` (`transcribe_request`,
`synthesize_request`) and are unrelated.

These are stragglers inside a live family, not a dead layer: sibling builders in
the same modules (`chat_post_message_request`, `chat_update_request`,
`apps_connections_open_request`, `create_message_request`,
`interaction_callback_request`) all have call sites.

---

## 4. Not dead, but adjacent — 74 test-only production functions

Production functions with zero production callers, exercised only by tests.
Highest concentrations:

| Module | Count | Examples |
| --- | ---: | --- |
| `resources/resource_uri.ex` | 6 | `browser_session!`, `image_capture!`, `screen_capture!`, `workflow!`, `plan_run!`, `marketplace_entry!` |
| `conversations/corpus.ex` | 5 | `rehydrate_and_authorize`, `conversation_context`, `set_origin_grant` |
| `resources/operation_class.ex` | 3 | `origin_kind!`, `access_mode!`, `scope_kind!` |
| `workspace/offline.ex` | 3 | |
| `runtime/response.ex` | 3 | `confirmation_needed` |
| `actions/registry.ex` | 3 | `capabilities_for_app` |
| `boundary.ex` | 2 | `by_subsystem`, `current_facade?` |
| `memory.ex` | 2 | `upsert_system_entry` |
| `resources/grant.ex` | 2 | `from_ref`, `same_authority?` |
| `workspace/canvas.ex` | 2 | |

These are **not** safe to delete on this evidence. Each is either an unfinished
API surface that a planned caller will use, or a test-only convenience that
belongs in `test/support`. The decision differs per function and needs a
separate pass with subsystem-owner input.

Note that `conversations/corpus.ex` appearing here is expected — it is the
canonical Corpus boundary introduced at `0687f4bc` (v1.3 M2) and its callers are
still being migrated.

---

## Residual risk

Two things this analysis cannot settle. Both must be checked before any
deletion.

1. **Runtime-constructed atom dispatch.** All five `apply/3` sites were
   inspected — `cli.ex:329`, `intent/router/optimizer.ex:585`,
   `allbert_assist_web/surface/renderer.ex:52`, `allbert_assist_web.ex:113`,
   `allbert.tui/.../live_region.ex:223` — and each takes its function atom from
   a literal table, which grep coverage catches. However
   `String.to_existing_atom` appears 60 times across `lib`, and those call sites
   were **not** exhaustively traced to confirm none produces a function name.
2. **Plugin API surface.** The seven channel-client functions live in
   separately-directoried packages under `plugins/`. Whether external plugin
   authors are a supported audience determines if removing public functions
   there is a compatibility decision rather than a cleanup. This was not
   resolved during the survey.

---

## Sequencing note

If this work is scheduled, the safe order is:

1. **Reconcile the `projection.ex` warning** (§2). It is either a stale artifact,
   a diagnostic offset, or a latent bug in the `Forget.suppressed_value?/2`
   contract. Resolve which before editing.
2. **Delete `StockSage.Agents.DelegatePlugin`** (§1). Self-contained, no
   callers, superseded by a route that provably exists.
3. **Delete the 15 core and web functions** (§3). Mechanical, each independently
   verified.
4. **Decide the plugin 7 separately** (§3), gated on the plugin-API question in
   the residual-risk section above.
5. **Leave the 74 test-only functions alone** pending their own pass (§4).

Total removable on current evidence: roughly 22 lines of module plus 22 function
definitions. This is a small cleanup. It is documented not because the payoff is
large but because the absence of dead code is itself a useful finding — future
sweeps can start from this baseline rather than re-deriving it, and the analyzer
defect log above prevents repeating four wrong answers.
