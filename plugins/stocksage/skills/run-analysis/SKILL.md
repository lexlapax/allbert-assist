---
name: run-analysis
description: Run a StockSage analysis for a ticker through the supervised Python bridge.
allowed-tools: allbert:action:run_analysis
metadata:
  allbert.kind: native_action
  allbert.version: "0.22.0"
  allbert.actions: run_analysis
  allbert.permissions: stocksage_analyze
  allbert.confirmation: required
  allbert.app: stocksage
examples:
  - "analyze AAPL for 2026-05-01"
  - "run StockSage analysis for TSLA on 2026-05-14"
  - "queue analysis for MSFT for 2026-05-01"
---

## Workflow

1. Validate the ticker symbol and ISO-8601 analysis date.
2. Evaluate `:stocksage_analyze` through Security Central.
3. When confirmation is required (the default), create a durable confirmation
   record and stop. Do not call the bridge yet.
4. On the approved resume path, call `StockSage.TraderBridge.analyze/1` with the
   validated params and persist the analysis result.
5. When a queue entry id is provided, update the queue entry status and record
   a queue run row linking it to the analysis.

## Safety

- The Python bridge makes external market-data API calls. The operator
  confirmation covers analysis as a whole; per-source confirmations arrive in
  v0.26.
- Raw TradingAgents output is never surfaced in traces, CLI list summaries, or
  signals. Only bounded structured metadata is shown.
- `:stocksage_analyze` has a `needs_confirmation` safety floor; no setting can
  lower it to `allowed`.
