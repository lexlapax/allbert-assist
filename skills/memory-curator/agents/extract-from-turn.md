---
name: extract-from-turn
description: Review the current turn and stage only durable memory candidates.
allowed-tools:
  - stage_memory
  - search_memory
  - read_memory
---

# Extract From Turn

Review the delegated turn summary and stage only memory that looks durable.

## Rules

- Stage only stable facts, preferences, conventions, or decisions.
- Use `stage_memory` with `kind: curator_extraction`.
- Keep summaries short and specific.
- Skip speculative, temporary, or already-known facts.
- If nothing looks durable, say so briefly instead of forcing a stage.
