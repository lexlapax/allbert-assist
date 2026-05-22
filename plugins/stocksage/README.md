# StockSage

StockSage is Allbert's first shipped source-tree plugin workspace app and the
first proving app for native financial specialist agents.

Current v0.29 capabilities:

- `./plugins/stocksage` contributes `StockSage.Plugin`, `StockSage.App`,
  skills, settings schema entries, local domain actions, evidence actions,
  the supervised Python bridge, and the supervised native agent graph.
- Plugin-owned Ecto schemas and contexts use `AllbertAssist.Repo` and shared
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
- `/stocksage`, `/stocksage/analyses`, `/stocksage/analyses/:id`,
  `/stocksage/queue`, and `/stocksage/trends` are plugin-owned LiveView
  surfaces mounted by the host router and declared by `StockSage.App.surfaces/0`.
- `StockSage.App.surface_catalog/0` declares the four v0.26-reserved StockSage
  app card atoms: `:analysis_card`, `:agent_report_card`, `:parity_card`, and
  `:debate_round_card`.
- StockSage-owned card renderers display persisted native, bridge, and parity
  analysis output inside `/stocksage/*`; the v0.26 workspace stubs remain a
  separate `/agent` canvas concern until v0.30.
- `StockSage.App.memory_namespace/0` declares namespace ownership with
  `writable: true`; Allbert markdown memory writes still require explicit
  `sync_app_lesson` confirmation.
- `StockSage.Progress` streams bounded analysis progress over Phoenix.PubSub on
  `stocksage_progress:<user_id>:<analysis_id>` and catches up from persisted
  objective/analysis state on reconnect.
- `resolve_outcomes`, `generate_reflection`, and StockSage trends/calibration
  support resolved outcome review, local reflections, rating calibration, and
  symbol leaderboards.
- `StockSage.App.memory_namespace/0` is writable in v0.29, but Allbert
  markdown memory writes only happen through the registered
  `sync_app_lesson` action and an explicit confirmation resume. The
  `/stocksage/analyses/:id` reflection card exposes `Sync lesson` to queue that
  confirmation; generating reflections never promotes memory automatically.

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
export ALLBERT_HOME=$(mktemp -d /tmp/allbert-v027-web.XXXXXX)
mix ecto.migrate.allbert
mix phx.server
# Browse /stocksage, /stocksage/analyses, /stocksage/queue, and /stocksage/trends.
```

Every read-by-id path is scoped by `user_id`; another user's durable id returns
not-found. `:stocksage_write` authorizes local StockSage SQLite writes only;
`:stocksage_analyze` remains confirmation-gated; evidence actions flow through
`:stocksage_evidence_fetch` and Resource Access posture.

v0.29 consumes the v0.27 memory namespace through explicit lesson sync. Durable
`/agent` canvas tile emission through `canvas_ops` still lands in v0.30.
