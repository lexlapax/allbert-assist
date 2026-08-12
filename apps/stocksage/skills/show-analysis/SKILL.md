---
name: show-analysis
description: Show one local StockSage analysis for the current user.
allowed-tools: allbert:action:show_analysis
metadata:
  allbert.kind: native_action
  allbert.version: "0.20.0"
  allbert.actions: show_analysis
  allbert.permissions: read_only
  allbert.confirmation: not_required
---

## Workflow

1. Read the requested local StockSage analysis by id.
2. Treat another user's analysis id as not found.
3. Return bounded details only.
