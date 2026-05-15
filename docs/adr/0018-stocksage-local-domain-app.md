# ADR 0018: StockSage Local Domain App Boundary

## Status

Proposed.

## Context

StockSage is the first real app that should prove Allbert's plugin and app
contracts. It needs to be concrete enough to store useful financial-analysis
domain data and import the existing Python `stocksage.db` baseline, but it must
not accidentally pull later milestones forward.

The surrounding decisions are already established:

- ADR 0014 defines local string `user_id`, optional `thread_id` and
  `session_id`, and no hosted accounts/roles.
- ADR 0015 defines `AllbertAssist.App` as the app contract.
- ADR 0017 defines plugins as the package/discovery boundary, not authority.
- `allbert-jido-vision.md` keeps SQLite as the local default and defers
  PostgreSQL, hosted auth, Oban-as-hard-dependency, Python bridge execution,
  native trading agents, and StockSage LiveViews to later milestones.

Without a binding decision, v0.20 could accidentally create a second database
boundary, run Python during import, bypass the plugin registry, or make
StockSage a special case instead of the first normal app.

## Decision

StockSage lands in v0.20 as a source-tree plugin-contributed app:

- `./plugins/stocksage` is the plugin package.
- `StockSage.Plugin` is the plugin entrypoint.
- `StockSage.App` implements the v0.18 app/surface contract from day one.
- `apps/stocksage` contains the domain contexts, schemas, local actions, Mix
  tasks, and tests.
- `apps/stocksage_web` is a compile-ready placeholder for later LiveViews, but
  v0.20 mounts no routes.

StockSage uses the existing `AllbertAssist.Repo` and the existing local SQLite
database. v0.20 does not add `StockSage.Repo`. StockSage migrations live in
the central Allbert migration path and create `stocksage_*` tables.

StockSage tables store string `user_id` and optional Allbert request context
fields such as `thread_id`, `session_id`, `app_id`, `input_signal_id`, and
`trace_id`. These fields are data provenance and routing context, not hosted
authorization.

The first domain records are:

- analyses
- analysis details
- outcomes
- analysis queue entries
- queue runs
- StockSage memory entries

StockSage memory entries are local StockSage domain records. They are not
markdown Allbert memory entries and are not auto-promoted to markdown memory.

The v0.20 legacy import path reads a local SQLite database and maps rows into
StockSage domain records with provenance. Import is idempotent and read-only
against the source database. It does not execute Python, fetch market data, run
package managers, import skills, or promote memory.

The first StockSage actions may read local imported data and create local queue
entries. They do not run analysis. `StockSage.Actions.RunAnalysis` belongs to
the Python bridge milestone.

`AllbertAssist.App.StockSageStub` is removed from default app registration
when `StockSage.App` is registered. The `:stocksage` app id remains valid
through the real app.

## Consequences

- StockSage proves the plugin/app path without private Allbert bootstrapping.
- All local data stays in one SQLite database, so backup/export and test setup
  remain simple.
- Future StockSage milestones can reuse the same queue, analysis, detail,
  outcome, and memory records.
- v0.22 can add the Python bridge without redesigning persistence.
- v0.23 can add native Jido agents without introducing a second queue model.
- v0.25 can build LiveViews on `AllbertAssist.App.SurfaceProvider` using the
  v0.18 app/surface contract as the foundation from day one.
- v0.26 security evals can target concrete financial and plugin-domain
  boundaries.

## Deferred

- `StockSage.Repo` or a separate database.
- PostgreSQL, Oban-as-hard-dependency, hosted accounts, roles, or teams.
- Python bridge execution and `StockSage.Actions.RunAnalysis`.
- Native trading agents.
- Market-data API calls.
- LiveViews, dynamic routes, Surface DSL, canvas components, or `canvas_ops`.
- Automatic promotion of StockSage memory records to markdown Allbert memory.
