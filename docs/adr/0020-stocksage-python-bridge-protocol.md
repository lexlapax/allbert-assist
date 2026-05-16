# ADR 0020: StockSage Python Bridge Protocol

## Status

Proposed. To be accepted during v0.22 M1.

## Context

StockSage needs real analysis results before native Jido trading agents are
built in v0.23. The existing Python TradingAgents baseline can produce those
results today. A supervised bridge around it gives Allbert a working engine
during the v0.22–v0.23 window and lets v0.23 replace the bridge call without
changing the permission, confirmation, or persistence contracts.

Several decisions shape the bridge design:

- ADR 0006: Security Central is the permission and risk boundary. Bridge
  execution is a new capability class; it needs its own permission, not a
  reuse of `:stocksage_write` (local domain writes) or `:command_execute`
  (host shell execution).
- ADR 0007: effectful, security-relevant operations enter through registered
  Jido actions. `StockSage.Actions.RunAnalysis` is the action boundary.
- ADR 0008: sensitive actions that need confirmation create durable pending
  records and do not run the side effect until approved.
- ADR 0009 and ADR 0010: established that subprocess execution in this project
  requires a confirmed, policy-bounded path. The Python bridge is analogous:
  it spawns a subprocess and may call external market-data APIs.
- ADR 0018: `StockSage.Actions.RunAnalysis` belongs to the Python bridge
  milestone; `:stocksage_write` is scoped to local domain writes only.
- The vision keeps SQLite as local storage and defers PostgreSQL; bridge
  results persist into the shared `AllbertAssist.Repo` with `stocksage_*`
  tables already established in v0.20.

Without a binding protocol decision, v0.22 could accidentally use a different
bridge mechanism than v0.23 expects, produce analysis results in a format that
v0.25 LiveViews cannot render, or leave market-data call authorization
undefined when v0.26 security hardening arrives.

## Decision

### Technology: JSON-Over-Stdio Port

The bridge uses a long-lived Erlang Port over JSON-newline-delimited stdio
rather than ErlPort. Reasons:

- No additional dependency: plain `Port.open/2` with `:binary` and
  `{:line, max_bytes}` is standard OTP.
- Python side requires only stdlib (`sys`, `json`); no ErlPort Python package.
- Protocol is language-neutral: v0.23 native agents can mock the same protocol
  shape during transition testing without Python installed.
- ErlPort's type-mapping layer adds complexity without benefit for a
  JSON-structured domain.

The bridge opens one long-lived OS process per `StockSage.TraderBridge`
instance. Requests and responses are matched by a client-supplied request id.

### Protocol Envelope

Request (one JSON object, newline-terminated):

```json
{"id": "<uuid>", "action": "run_analysis", "ticker": "AAPL", "analysis_date": "2026-05-01", "engine": "tradingagents"}
```

Response (one JSON object, newline-terminated):

```json
{"id": "<uuid>", "status": "ok", "result": { ... }}
```

or on error:

```json
{"id": "<uuid>", "status": "error", "reason": "<bounded string>"}
```

Ping/pong for bridge health:

```json
{"id": "<uuid>", "action": "ping"}
{"id": "<uuid>", "status": "ok", "result": "pong"}
```

Rules:

- The `id` field is always required and must be echoed back unchanged.
- The `action` field controls dispatch; unknown actions return `status: "error"`.
- Missing or invalid required params (`ticker`, `analysis_date`) return an
  error before dispatching to TradingAgents.
- The bridge does not accept free-form shell commands, file paths, module
  paths, or escape sequences.
- Response `result` bodies are bounded by `stocksage.bridge_max_output_bytes`
  before the bridge process serializes them; values exceeding the limit are
  truncated with a `truncated: true` field.

### Code Ownership: Plugin, Not Core

All bridge code is plugin-owned and lives under `./plugins/stocksage/`:

- `./plugins/stocksage/lib/stocksage/trader_bridge.ex` — the GenServer
- `./plugins/stocksage/lib/stocksage/bridge/protocol.ex` — JSON encode/decode
- `./plugins/stocksage/priv/python/bridge.py` — the Python process
- `./plugins/stocksage/lib/stocksage/actions/run_analysis.ex` — the action

Nothing in `apps/allbert_assist/` imports or depends on bridge internals.
The only Allbert core contact points are:

- `AllbertAssist.Actions.Runner.run/3` — invokes `RunAnalysis` like any other
  registered action.
- `AllbertAssist.Security` — checks `:stocksage_analyze` permission at the
  action boundary.
- `AllbertAssist.Actions.Registry` — `RunAnalysis` is registered here via the
  plugin's `actions/0` callback; the registry entry is a metadata struct, not
  a code dependency.
- `AllbertAssist.Repo` — persists analysis results into the shared SQLite
  database using the existing connection.

This boundary means a bridge crash, protocol change, or Python dependency
update cannot affect Allbert core stability.

### Supervision: Plugin-Owned Lifecycle

`StockSage.TraderBridge` is a GenServer that owns the Port. It starts under
`StockSage.Supervisor`, which is contributed as a child spec from
`StockSage.Plugin.child_spec/1`. It stops, restarts, and crashes with the
plugin supervisor, not with Allbert core.

When the Port exits unexpectedly:

- The GenServer receives `{:EXIT, port, reason}`.
- All pending callers receive `{:error, :bridge_crashed}`.
- The GenServer restarts the Port on its next call (lazy restart) or fails
  according to the OTP restart strategy configured in `StockSage.Supervisor`.
- Allbert core supervision is not affected.

When `stocksage.bridge_enabled` is `false`, `StockSage.TraderBridge` is not
started and `RunAnalysis` returns `{:error, :bridge_disabled}` before creating
a confirmation record.

### Permission Class: `:stocksage_analyze`

`:stocksage_analyze` is the Security Central permission class for executing
analysis through the Python bridge.

- It is separate from `:stocksage_write` (local domain writes such as queue
  entries) to prevent a write grant from implying execution authority.
- Default setting: `needs_confirmation`.
- Safety floor: `needs_confirmation`. Settings Central cannot lower this to
  `allowed` or `denied_explicit`; the floor is enforced by Security Central.
- Risk tier: `high` (external subprocess, external API calls).

When v0.23 native agents replace bridge dispatch in `RunAnalysis`, they use
the same `:stocksage_analyze` permission, the same confirmation path, and the
same result persistence contract. The permission class does not change.

### Market-Data API Calls: Flagged For v0.26

TradingAgents makes external market-data API calls as part of analysis.
These calls are made inside the Python process and are not individually
governed by Resource Access Security Posture or confirmations in v0.22.
The operator confirmation for `RunAnalysis` covers the analysis action as a
whole, including its knowledge that TradingAgents makes external calls.

This is an acknowledged gap. v0.26 security hardening must:

- Require market-data API calls from StockSage to flow through Resource Access
  Security Posture as registered operation-class consumers.
- Consider whether the Python bridge should return the list of external
  resources contacted so Allbert can produce an audit record.
- Apply remembered-grant eligibility or explicit confirmation to each distinct
  market-data source.

Until v0.26, the confirmation record for `RunAnalysis` must include a
disclosure that TradingAgents external calls are included in the approved
scope and are not individually remembered-granted.

### Result Schema

Bridge results are persisted to `stocksage_analyses` and
`stocksage_analysis_details`. The bridge `result` object shape is defined by
the Python TradingAgents baseline. Allbert stores:

- In `stocksage_analyses`: ticker, analysis_date, engine, status, summary
  (bounded string), user_id, queue_entry_id if applicable, trace_id,
  request_id, bridge_duration_ms.
- In `stocksage_analysis_details`: analysis_id (FK), raw result body
  (bounded by `bridge_max_output_bytes`), truncated flag.

Raw result bodies are not included in traces, CLI list summaries, or signals.
Only bounded summaries and structured metadata are surfaced.

## Consequences

- `StockSage.Actions.RunAnalysis` uses `:stocksage_analyze` and the v0.07
  confirmation workflow. This becomes the stable contract across v0.22 (bridge)
  and v0.23 (native agents); callers do not need to change.
- `StockSage.Bridge.Protocol` encodes and decodes the JSON envelope. This
  module is the test seam for bridge protocol correctness.
- v0.25 StockSage LiveViews render results from `stocksage_analyses` and
  `stocksage_analysis_details`; the table schema established in v0.22 must not
  change shape in v0.25 without a migration.
- v0.26 security hardening adds individual Resource Access Security Posture
  governance for market-data API calls; the current disclosure-in-confirmation
  approach is a temporary placeholder.
- The bridge technology (JSON-over-stdio Port) is not a long-term locked
  decision. If a later milestone (e.g., a hosted deployment) needs a different
  bridge transport, `StockSage.TraderBridge` is the swap point; the action,
  permission, confirmation, and persistence layers do not change.
