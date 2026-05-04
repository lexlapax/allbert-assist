---
name: unsupported-resource-workflow
description: Explain URL/document/MCP/agent/channel resource workflows that v0.10 intentionally defers instead of partially fetching, reading, summarizing, crawling, importing, or delegating.
compatibility: Allbert v0.10+. Descriptive wrapper for the built-in unsupported_resource_workflow action.
allowed-tools: allbert:action:unsupported_resource_workflow
metadata:
  allbert.kind: native_action
  allbert.version: "0.10.0"
  allbert.actions: unsupported_resource_workflow
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_unsupported_workflow
---

## Workflow

1. Recognize that the user requested a v0.11+ resource workflow.
2. Explain that v0.10 has not fetched, read, summarized, crawled, imported, delegated, or executed anything.
3. Point the user to approved registered v0.10 resource consumers when one exists, and state that v0.11 owns execution-aware intent and Approval Handoff.
