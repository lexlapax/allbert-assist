# Allbert Notes/Files Reference Plugin

`allbert.notes_files` is the v0.42 native reference plugin. It is intentionally
small: one app, one memory namespace declaration, three registered actions, two
workspace panels, a settings fragment, and two skill entries.

Registration is inert contract data. The plugin does not grant file access,
memory promotion, or confirmation bypasses by being present. Reads are bounded
to the configured notes root. Writes create a durable confirmation request with
`write_local_path` resource refs and only touch disk after approval.

## Contract

- Plugin entrypoint: `AllbertNotesFiles.Plugin`
- App entrypoint: `AllbertNotesFiles.App`
- App id and memory namespace: `:notes_files`
- Actions:
  - `search_notes` is read-only.
  - `read_note` is read-only.
  - `write_note` uses `:notes_file_write` and requires confirmation.
- Settings:
  - `apps.notes_files.notes_root`
  - `apps.notes_files.max_results`

The namespace declaration is read-only on purpose. Note files are not promoted
to Allbert memory automatically; memory promotion remains a separate confirmed
memory action.
