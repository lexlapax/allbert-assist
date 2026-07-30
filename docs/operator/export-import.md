# Allbert Home Export And Dry-Run Import

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

Allbert can export a redacted portability envelope and validate it against a
different Home. Import is deliberately preview-only: it applies no changes and
has no automatic rollback runner.

## Export

Stop any runtime using the source Home, then run:

```sh
export ALLBERT_HOME="/path/to/source-home"
export ALLBERT_EXPORT_DIR="$HOME/allbert-export"
mkdir -p "$ALLBERT_EXPORT_DIR"

allbert admin home export \
  --out "$ALLBERT_EXPORT_DIR/home.envelope.json"
```

A successful envelope reports its version, fragment/file/reference counts, and
`redacted=true`. It contains redacted user settings, per-fragment schema
versions, secret-reference status, and a hashes-only Home file manifest. It
excludes secret values, `settings/secrets.yml.enc`,
`settings/.settings_key`, caches, and temporary files.

The complete `<ALLBERT_HOME>/projections/` tree is also excluded. Search and
Memory SQLite generations are disposable derivatives, not authoritative Home
data. After a full backup restore, the managed `search-rebuild` and
`memory-index-rebuild` paths recreate them from canonical conversation rows and
Markdown claim streams. Do not copy an old projection into a destination Home
or treat its absence as lost user data.

## Validate Against A Target Home

Keep the evidence path outside the target Home:

```sh
export ALLBERT_HOME="/path/to/target-home"
export ALLBERT_HOME_DIR="$ALLBERT_HOME"

allbert admin home import --dry-run \
  --in "$ALLBERT_EXPORT_DIR/home.envelope.json" \
  --evidence-out "$ALLBERT_EXPORT_DIR/import-diagnostic.json"
```

PASS requires:

```text
status=ok
dry_run=true
applied=false
settings_version_contract.counts.current=<count>
secret_references.required=<count>
secret_references.missing=<count>
inert_import_plan.applied_changes=none
```

The target Home must remain byte-identical before and after the dry run. If
`--evidence-out` is omitted, the diagnostic is printed to stdout.

## Restore Missing Secret References

The envelope carries references, never secret values. Tier-1 macOS Keychain or
Linux Secret Service values live outside Allbert Home and must be reprovisioned
on the destination. Tier-2 encrypted values are also excluded from this
redacted envelope.

Use the interactive vault-backed path so a key is not placed in shell history:

```sh
export ALLBERT_HOME="/path/to/target-home"
allbert admin settings providers set-key openai

allbert admin home import --dry-run \
  --in "$ALLBERT_EXPORT_DIR/home.envelope.json" \
  --evidence-out "$ALLBERT_EXPORT_DIR/import-diagnostic-after-secrets.json"
```

PASS: the relevant reference changes from `target_status=missing` to
`target_status=configured`. Never paste a secret into the envelope, diagnostic,
chat, release evidence, or a positional command argument. See the
[Secret Vault](security-hardening.md#secret-vault-three-tier).

## Recovery

Because import applies nothing, normal rollback is proof that the target Home
did not change. If a future operator-applied migration modifies a Home:

1. Stop every Allbert runtime using that Home.
2. Preserve the modified Home under a clearly named recovery path.
3. Restore the operator backup that matches the runtime version.
4. Start Allbert and run:

   ```sh
   allbert admin trust status
   allbert admin settings doctor
   ```

Do not delete or overwrite either Home until the restored runtime and its data
have been verified.
