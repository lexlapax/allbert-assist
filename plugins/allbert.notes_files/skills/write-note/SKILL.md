---
name: write-note
description: Create or update a local Notes/files note after operator confirmation.
capability:
  action: write_note
  permission: notes_file_write
---

Use `write_note` only when the operator explicitly asks to create or update a
local note. The action is confirmation-gated. Do not claim the note was written
until the confirmation has been approved and the resumed action completes.
