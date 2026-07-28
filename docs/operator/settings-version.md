# Settings Version Contract

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

Every Settings Central fragment carries a `schema_version`. The contract is
fail-closed: Allbert does not silently load a forward or invalid fragment.

## Check A Home

Stop other runtimes using the Home, then run:

```sh
export ALLBERT_HOME="/path/to/home"
allbert admin settings doctor
allbert admin trust status
```

PASS: status is `ok`, all fragments are current, `forward=0`, `invalid=0`, and
there are no diagnostics.

## Interpret Diagnostics

- `pending` — the stored Home is older than the running Allbert. Follow the
  release's documented migration/upgrade path.
- `forward` — the Home was written by a newer runtime. Stop and use that newer
  version, or restore a backup compatible with the current runtime.
- `invalid` — a fragment version is malformed. Treat this as corruption or an
  unsafe manual edit and restore from backup before continuing.

Do not repair these states by editing a settings fragment in place.

## Export And Import Interaction

`allbert admin home export` preserves fragment versions in its redacted
envelope. `allbert admin home import --dry-run` validates them against the
target runtime and applies nothing:

```sh
export ALLBERT_EXPORT_DIR="$HOME/allbert-export"
export ALLBERT_HOME="/path/to/target-home"

allbert admin home import --dry-run \
  --in "$ALLBERT_EXPORT_DIR/home.envelope.json" \
  --evidence-out "$ALLBERT_EXPORT_DIR/import-diagnostic.json"

rg '"status": "ok"|"dry_run": true|"applied": false' \
  "$ALLBERT_EXPORT_DIR/import-diagnostic.json"
rg 'settings_version_contract|current|pending|forward|invalid' \
  "$ALLBERT_EXPORT_DIR/import-diagnostic.json"
```

Keep diagnostics outside the target Home and prove the Home is byte-identical
before and after the dry run. See [Export/import](export-import.md).
