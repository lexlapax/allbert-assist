---
name: append-memory
description: Save explicit user-approved memory and low-risk personal preference heuristics as durable markdown. Use when the user asks Allbert to remember a fact, preference, or local project note.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in append_memory action.
allowed-tools: allbert:action:append_memory
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: append_memory
  allbert.permissions: memory_write
  allbert.confirmation: not_required
  allbert.memory-effects: writes_markdown_memory
  allbert.trace-effects: records_selected_skill,records_permission_decision
---

## Workflow

1. Confirm the memory is explicit or a low-risk preference/identity heuristic.
2. Use the `append_memory` Allbert action for the actual write.
3. Report the saved markdown category and path.
4. Do not store secrets, credentials, financial identifiers, or sensitive personal data.
