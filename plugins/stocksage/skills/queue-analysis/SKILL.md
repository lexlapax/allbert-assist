---
name: queue-analysis
description: Queue a StockSage analysis request as a local durable row without running analysis.
allowed-tools: allbert:action:queue_analysis
metadata:
  allbert.kind: native_action
  allbert.version: "0.33.1"
  allbert.actions: queue_analysis
  allbert.permissions: stocksage_write
  allbert.confirmation: not_required
---

## Workflow

1. Normalize the requested ticker symbol.
2. Create a local StockSage queue row.
3. Do not run Python, call market data, or start an analysis worker.
