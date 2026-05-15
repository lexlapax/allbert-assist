# StockSage

StockSage is Allbert's first shipped source-tree plugin workspace app.

v0.20 provides the local data foundation only:

- `./plugins/stocksage` contributes `StockSage.Plugin`, `StockSage.App`,
  skills, settings schema entries, and four safe local actions.
- Plugin-owned Ecto schemas and contexts use `AllbertAssist.Repo` and shared
  SQLite `stocksage_*` tables.
- `mix stocksage.import_sqlite` imports a representative legacy SQLite file
  read-only and idempotently.
- `mix stocksage.analyses list/show` and `mix stocksage.queue create/list`
  provide bounded operator inspection and queue creation.

v0.20 does not execute Python, call market-data APIs, mount StockSage
LiveViews, start native trading agents, or promote StockSage memory records to
markdown Allbert memory.

## Local Commands

```sh
mix stocksage.import_sqlite plugins/stocksage/test/fixtures/stocksage_fixture.db --user local --dry-run
mix stocksage.import_sqlite plugins/stocksage/test/fixtures/stocksage_fixture.db --user local
mix stocksage.analyses list --user local
mix stocksage.queue create AAPL --user local
mix stocksage.queue list --user local
```

Every read-by-id path is scoped by `user_id`; another user's durable id returns
not-found. `:stocksage_write` authorizes local StockSage SQLite writes only.
