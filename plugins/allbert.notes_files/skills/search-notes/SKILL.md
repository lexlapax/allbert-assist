---
name: search-notes
description: Search the local Notes/files reference plugin for bounded note summaries.
capability:
  action: search_notes
  permission: read_only
---

Use `search_notes` when the operator asks to find or list local notes. Keep the
query narrow, prefer relative paths in the answer, and use `read_note` before
quoting or relying on a note body.
