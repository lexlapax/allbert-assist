---
name: get-trends
description: Summarize local StockSage outcome trends for the current user.
allowed-tools: allbert:action:get_trends
metadata:
  allbert.kind: native_action
  allbert.version: "0.34.0"
  allbert.actions: get_trends
  allbert.permissions: read_only
  allbert.confirmation: not_required
---

## Workflow

1. Read local StockSage outcome records.
2. Summarize bounded trends for the current `user_id`.
3. Do not fetch prices or calculate new market outcomes.
