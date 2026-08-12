---
name: list-analyses
description: List local StockSage analyses for the current user.
allowed-tools: allbert:action:list_analyses
metadata:
  allbert.kind: native_action
  allbert.version: "0.20.0"
  allbert.actions: list_analyses
  allbert.permissions: read_only
  allbert.confirmation: not_required
---

## Workflow

1. Read bounded local StockSage analysis summaries.
2. Filter by the current `user_id`.
3. Do not fetch market data or run analysis.
