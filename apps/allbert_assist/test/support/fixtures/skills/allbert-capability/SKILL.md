---
name: allbert-capability
description: Save user-approved memory through Allbert's markdown memory path.
allowed-tools:
  - allbert:action:append_memory
metadata:
  allbert.kind: capability
  allbert.version: "0.3.0"
  allbert.actions: append_memory
  allbert.permissions: memory_write
  allbert.confirmation: not_required
  allbert.memory-effects: writes_markdown_memory
  allbert.trace-effects: records_selected_skill
---

## Workflow

Use this as inert capability metadata only in v0.03.
