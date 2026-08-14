# stocksage

StockSage is Allbert's proving workspace app for native financial specialist
agents — the first capability shipped as a source-tree plugin, and since v1.4
M13 a native umbrella pack.

## Contract

- Pack id: `allbert_stocksage`, `capability_tier: :native`,
  `registry_order: 1400`
- Catalog `startup_role`: `native_passive`
- Legacy plugin id: `stocksage` (`kind: "app"`)
- Apps: `StockSage.App`
- Settings: owned by `StockSage.SettingsFragment`
- Surfaces: `surface_id: "stocksage"`, rendered by `StockSageWeb.AnalysisLive`

The pack id is deliberately **not** `stocksage`. ADR 0098 §9 keeps each legacy
manifest as an identity-equivalent deprecated alias of its pack, and every other
pack's two names differ by construction — pack `allbert_notes_files` against
plugin `allbert.notes_files`. StockSage is the one plugin whose id carries no
dotted prefix, so an application-named pack id would be byte-identical to its
plugin id and composition would reject the pair as `duplicate_identity`.

## Why it exists

StockSage is where Allbert proves that a substantial domain capability — durable
stores, a supervised Python bridge, a graph of LLM-capable specialist agents,
and its own workspace surfaces — can live entirely outside the core without
being granted anything the core would not grant any other pack. Every effect
still crosses `AllbertAssist.Actions.Runner.run/3`, Security Central,
confirmations, and Allbert Home. It is the largest single test of whether the
pack boundary is real.

Before v1.4 this code lived under `plugins/stocksage/` and was path-injected into
`allbert_assist` through `elixirc_paths/1` — a contribution boundary, not a
compilation one. M13 extracted it into this OTP application.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`), the residual
(`allbert_assist`), and `allbert_assist_web`. It also declares `ecto_sql`,
`exqlite`, `decimal`, `jason`, `jido`, `jido_action`, `jido_signal` and
`jido_ai` directly — mirroring what the residual declares for the same imports,
because a pack that does not declare what it directly calls works only while
something else happens to pull it in.

The `allbert_assist_web` edge is the shape worth understanding. This pack
contributes a routed LiveView, so it must depend on the application that owns
the router — and `allbert_assist_web` in turn depends on `allbert_composition`.
If `allbert_composition` also depended on this pack, the loop
`web -> composition -> pack -> web` would close. So `stocksage` is deliberately
**absent** from `allbert_composition`'s dependency list, and sits *above* Web
instead: it is started by the root `mix.exs` release `applications:` list, and
its metadata reaches the Pack projection through the application roster read
from `.app` files, which needs no dependency edge. `allbert_artifacts` is the
only other application with this shape.

The rule the whole tier model rests on: **the kernel must not depend on any
pack**, and a violating edge is a build failure rather than a review finding.
Pack-to-pack edges are permitted when explicit and acyclic; composition hosts
may depend downward on both.

## How it starts, and how it is discovered

The pack is `native_passive`: `mix.exs` declares no `mod:` application callback,
so the application itself starts nothing. `StockSage.Plugin.child_spec/1`
returns `StockSage.Supervisor.child_spec/1`, and the residual's
`AllbertAssist.Plugin.Bootstrap` starts that child — the Python bridge and the
native agent graph — under `AllbertAssist.Plugin.ChildSupervisor`, which is
itself hosted by `AllbertAssist.Pack.ResidualEffectSupervisor` and therefore
only after the readiness barrier opens. No bridge subprocess exists before then.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: StockSage.Pack]` entry, reconciled against the sealed
component row in `apps/allbert_assist/priv/licenses/catalog.json`. The retained
`priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that same
descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## What is in it

Capabilities as of v0.32:

- `./apps/stocksage` contributes `StockSage.Plugin`, `StockSage.App`,
  skills, settings schema entries, local domain actions, evidence actions,
  the supervised Python bridge, and the supervised native agent graph.
- Pack-owned Ecto schemas and contexts use `AllbertAssist.Repo` and shared
  SQLite `stocksage_*` tables.
- `mix stocksage.import_sqlite` imports a representative legacy SQLite file
  read-only and idempotently.
- `mix stocksage.analyses list/show` and `mix stocksage.queue create/list`
  provide bounded operator inspection and queue creation.
- `mix stocksage.analyze` runs the native engine by default, creates durable
  confirmations for `:stocksage_analyze`, and persists native results under
  `stocksage_analyses`.
- Explicit `--engine python` and `--engine both` are comparison/reference
  modes only; Python is never an automatic fallback.
- `mix stocksage.agents list|show|smoke` inspects or smokes the registered
  native specialist agents.
- `mix allbert.delegate <agent_id>` lives in Allbert core and proves
  StockSage specialists can be called outside StockSage through the shared
  `delegate_agent` registered action.
- `StockSage.App.surfaces/0` declares dashboard, recent analyses, queue, and
  trends as catalog-validated `/workspace` panel surfaces. The old
  `/stocksage`, `/stocksage/analyses`, `/stocksage/queue`, and
  `/stocksage/trends` routes are intentionally absent.
- `/apps/stocksage/analyses/:id` remains the retained page-shaped analysis
  detail route for long-form review, progress, rerun controls, reflections,
  and explicit lesson-sync confirmation.
- `StockSage.App.surface_catalog/0` declares the four v0.26-reserved StockSage
  app card atoms: `:analysis_card`, `:agent_report_card`, `:parity_card`, and
  `:debate_round_card`.
- StockSage-owned card renderers display persisted native, bridge, and parity
  analysis output inside `/workspace` panels and durable `/workspace` canvas
  tiles.
- `StockSage.App.memory_namespace/0` declares namespace ownership with
  `writable: true`; Allbert markdown memory writes still require explicit
  `sync_app_lesson` confirmation.
- `StockSage.Progress` streams bounded analysis progress over Phoenix.PubSub on
  `stocksage_progress:<user_id>:<analysis_id>` and catches up from persisted
  objective/analysis state on reconnect.
- `resolve_outcomes`, `generate_reflection`, and StockSage trends/calibration
  support resolved outcome review, local reflections, rating calibration, and
  symbol leaderboards.
- `/apps/stocksage/analyses/:id` exposes explicit Native, Python, and Parity
  rerun controls. Reruns reuse `run_analysis`, queue the normal confirmation,
  and carry `source_analysis_id` so new runs remain linked to the source
  analysis.
- The analysis detail surface renders native/Python/parity run-context
  affordances and bounded empty states for outcomes, reflections, and progress.
- `StockSage.App.memory_namespace/0` is writable in v0.29, but Allbert
  markdown memory writes only happen through the registered
  `sync_app_lesson` action and an explicit confirmation resume. The
  `/apps/stocksage/analyses/:id` reflection card exposes `Sync lesson` to queue
  that confirmation; generating reflections never promotes memory
  automatically.

The native graph includes LLM-capable Jido.AI specialists for market context,
news/sentiment, fundamentals, bull thesis, bear thesis, three risk
perspectives, research-manager handoff, trader-plan handoff, and decision
synthesis, plus a deterministic quality gate. Multi-round bull/bear/risk
debate is bounded by Settings Central and each specialist turn is recorded as
an objective step. Set
`stocksage.native_llm_enabled=false` only for deterministic smoke/tests.

v0.25 parity hardening moved native closer to the Python TradingAgents
research/trader/portfolio-manager shape, but exact parity is not promised:
future work should tune evidence-source coverage and agent prompts without
ticker-specific overrides or deterministic rating floors.

## Local Commands

```sh
mix stocksage.import_sqlite path/to/legacy_stocksage.db --user local --dry-run
mix stocksage.import_sqlite path/to/legacy_stocksage.db --user local
mix stocksage.analyses list --user local
mix stocksage.queue create AAPL --user local
mix stocksage.queue list --user local
mix stocksage.analyze AAPL 2026-05-15 --user local --engine native --evidence-mode fixture
mix stocksage.analyze AAPL 2026-05-15 --user local --engine both --evidence-mode fixture --force-stub
mix stocksage.agents smoke stocksage.market_context --ticker AAPL --analysis-date 2026-05-15 --fixture --user local
mix allbert.delegate stocksage.market_context '{"ticker":"AAPL","analysis_date":"2026-05-15","evidence_mode":"fixture","fixture":true}' --user local
mix allbert.validate_app StockSage.App
```

Local web smoke:

```sh
export ALLBERT_HOME=$(mktemp -d /tmp/allbert-v032-web.XXXXXX)
mix ecto.migrate.allbert
mix phx.server
# Browse /workspace?app_id=stocksage.
# Open /apps/stocksage/analyses/<analysis_id> for retained detail review.
```

Every read-by-id path is scoped by `user_id`; another user's durable id returns
not-found. `:stocksage_write` authorizes local StockSage SQLite writes only;
`:stocksage_analyze` remains confirmation-gated; evidence actions flow through
`:stocksage_evidence_fetch` and Resource Access posture.

v0.29 consumes the v0.27 memory namespace through explicit lesson sync. v0.30
emits durable canvas tiles through the audited
`AllbertAssist.Workspace.Fragment` path; v0.32 renders those tiles and the
StockSage dashboard/recent/queue/trends panels inside `/workspace`. StockSage
does not write workspace canvas tables directly.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_artifacts/README.md` — the only other pack that sits above Web.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
