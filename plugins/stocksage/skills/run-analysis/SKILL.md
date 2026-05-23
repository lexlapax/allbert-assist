---
name: run-analysis
description: Run a StockSage analysis for a ticker through the native engine or explicit Python comparison.
allowed-tools: allbert:action:run_analysis
metadata:
  allbert.kind: native_action
  allbert.version: "0.31.0"
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
4. On the approved resume path, run the native StockSage specialist-agent graph
   by default. Only call the Python bridge when the operator explicitly
   requested `engine: "python"` or `engine: "both"`.
5. Persist the returned analysis in the local StockSage domain tables, including
   parity diff JSON for explicit `engine: "both"` requests.
6. When a queue entry id is provided, update the queue entry status and record
   a queue run row linking it to the analysis.

## Safety

- Native evidence actions and explicit Python bridge runs may make external
  market-data API calls. The operator confirmation covers analysis as a whole;
  evidence calls still preserve Resource Access posture.
- Raw TradingAgents output is never surfaced in traces, CLI list summaries, or
  signals. Only bounded structured metadata is shown.
- `:stocksage_analyze` has a `needs_confirmation` safety floor; no setting can
  lower it to `allowed`.
