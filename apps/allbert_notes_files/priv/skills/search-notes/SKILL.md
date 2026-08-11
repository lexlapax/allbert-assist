---
name: search-notes
description: Search the local Notes/files reference plugin for bounded note summaries.
allowed-tools: allbert:action:search_notes
metadata:
  allbert.kind: capability
  allbert.version: "0.42.1"
  allbert.actions: search_notes
  allbert.permissions: read_only
  allbert.confirmation: not_required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_permission_decision
---

Use `search_notes` when the operator asks to find or list local notes. Keep the
query narrow, prefer relative paths in the answer, and use `read_note` before
quoting or relying on a note body.
