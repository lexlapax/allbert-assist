---
name: write-note
description: Create or update a local Notes/files note after operator confirmation.
allowed-tools: allbert:action:write_note
metadata:
  allbert.kind: capability
  allbert.version: "0.42.1"
  allbert.actions: write_note
  allbert.permissions: notes_file_write
  allbert.confirmation: required
  allbert.memory-effects: none
  allbert.trace-effects: records_selected_skill,records_permission_decision
---

Use `write_note` only when the operator explicitly asks to create or update a
local note. The action is confirmation-gated. Do not claim the note was written
until the confirmation has been approved and the resumed action completes.
