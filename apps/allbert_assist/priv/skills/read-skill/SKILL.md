---
name: read-skill
description: Read one trusted and enabled skill declaration by name. Use when the user asks to read, show, or describe a specific skill.
compatibility: Allbert v0.03+. Descriptive wrapper for the built-in read_skill action.
allowed-tools: allbert:action:read_skill
metadata:
  allbert.kind: native_action
  allbert.version: "0.3.0"
  allbert.actions: read_skill
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_registry_diagnostics
---

## Workflow

1. Resolve the requested name using canonical kebab-case names and snake-case aliases.
2. Return the trusted skill declaration, source, trust state, kind, activation mode, and diagnostics.
3. Do not execute scripts, shell commands, package installs, external tools, network calls, or the described action.
