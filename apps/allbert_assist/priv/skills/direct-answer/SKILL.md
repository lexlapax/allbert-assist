---
name: direct-answer
description: Answer plain local-assistant prompts without taking side effects. Use when the user asks a general question that does not require memory writes, shell planning, external network access, or settings changes.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in direct_answer action.
allowed-tools: allbert:action:direct_answer
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: direct_answer
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill
---

## Workflow

1. Answer directly from local context and the current request.
2. Do not claim to remember, execute, browse, install, or call external services.
3. If the user asks for a capability with side effects, select a more specific skill instead.
