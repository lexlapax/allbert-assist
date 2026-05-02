---
name: read-recent-memory
description: Read recent markdown-backed memory entries. Use when the user asks what Allbert remembers, asks for recent memory, or asks to recall a preference.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in read_recent_memory action.
allowed-tools: allbert:action:read_recent_memory
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: read_recent_memory
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: reads_markdown_memory
  allbert.trace-effects: records_selected_skill
---

## Workflow

1. Read recent markdown-backed memory through the Allbert memory boundary.
2. Summarize the relevant entries without inventing missing memory.
3. Keep the action read-only.
