---
name: list-skills
description: List trusted and enabled skills known to Allbert's registry. Use when the user asks what Allbert can do, what skills are available, or what capabilities can be inspected.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in list_skills action.
allowed-tools: allbert:action:list_skills
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: list_skills
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_registry_catalog
---

## Workflow

1. Ask the registry for trusted and enabled skills.
2. Show canonical kebab-case skill names, source scope, trust state, and kind.
3. Do not include disabled, invalid, untrusted, or hidden duplicate skills in the model-facing catalog.
