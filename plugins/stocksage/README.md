# StockSage

StockSage is Allbert's first shipped source-tree plugin workspace app and the
first proving app for native financial specialist agents.

Current v0.25 capabilities:

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

The native graph includes LLM-capable Jido.AI specialists for market context,
news/sentiment, fundamentals, bull thesis, bear thesis, three risk
perspectives, and decision synthesis, plus a deterministic quality gate.
Multi-round bull/bear/risk debate is bounded by Settings Central and each
specialist turn is recorded as an objective step. Set
`stocksage.native_llm_enabled=false` only for deterministic smoke/tests.

## Local Commands

```sh
mix stocksage.import_sqlite plugins/stocksage/test/fixtures/stocksage_fixture.db --user local --dry-run
mix stocksage.import_sqlite plugins/stocksage/test/fixtures/stocksage_fixture.db --user local
mix stocksage.analyses list --user local
mix stocksage.queue create AAPL --user local
mix stocksage.queue list --user local
mix stocksage.analyze AAPL 2026-05-15 --user local --engine native --evidence-mode fixture
mix stocksage.analyze AAPL 2026-05-15 --user local --engine both --evidence-mode fixture --force-stub
mix stocksage.agents smoke stocksage.market_context --ticker AAPL --analysis-date 2026-05-15 --fixture --user local
mix allbert.delegate stocksage.market_context '{"ticker":"AAPL","analysis_date":"2026-05-15","evidence_mode":"fixture","fixture":true}' --user local
```

Every read-by-id path is scoped by `user_id`; another user's durable id returns
not-found. `:stocksage_write` authorizes local StockSage SQLite writes only;
`:stocksage_analyze` remains confirmation-gated; evidence actions flow through
`:stocksage_evidence_fetch` and Resource Access posture.
