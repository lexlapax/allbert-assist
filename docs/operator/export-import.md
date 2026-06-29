# Allbert Home Export And Dry-Run Import

v0.59 provides a redacted portability envelope and a dry-run import validator. It
does not apply an import and does not include an executable rollback runner.

## Export

```sh
set -euo pipefail
export ALLBERT_HOME="/path/to/source-home"
export V059_EVIDENCE_DIR="$HOME/.allbert-release-evidence/v059"
mkdir -p "$V059_EVIDENCE_DIR"

MIX_ENV=test mix allbert.home.export \
  --out "$V059_EVIDENCE_DIR/home.envelope.json"
```

Expected output:

```text
Exported Allbert Home envelope
Envelope: <path>
envelope_version=1
fragments=<count>
files=<count>
secret_refs=<count>
redacted=true
```

The envelope includes redacted user settings, per-fragment schema versions,
secret-reference status rows, and a hashes-only Home file manifest. It excludes
`settings/secrets.yml.enc`, `settings/.settings_key`, cache files, tmp files, and
secret values. Provider-shaped secret values are redacted even under innocuous
setting names; benign hashes/checksums remain visible unless their setting path is
sensitive.

## Dry-Run Import

```sh
set -euo pipefail
export ALLBERT_HOME="/path/to/target-home"
export ALLBERT_HOME_DIR="$ALLBERT_HOME"

MIX_ENV=test mix allbert.home.import --dry-run \
  --in "$V059_EVIDENCE_DIR/home.envelope.json" \
  --evidence-out "$V059_EVIDENCE_DIR/import-diagnostic.json"
```

The evidence path must be outside the target Home. If `--evidence-out` is omitted,
the diagnostic is written to stdout. The target Home must remain byte-identical
before and after the dry run.

Expected diagnostic fields:

```text
status=ok
dry_run=true
applied=false
settings_version_contract.counts.current=<count>
secret_references.required=<count>
secret_references.missing=<count>
inert_import_plan.applied_changes=none
```

## Secret References

The envelope round-trips secret references only. Secret values stay in the source
Home encrypted secret store and are never exported.

If the diagnostic reports missing target refs, restore those secrets manually in
the target Home and rerun the dry-run import:

```sh
set -euo pipefail
export ALLBERT_HOME="/path/to/target-home"

printf '%s\n' "$OPENAI_API_KEY" | MIX_ENV=test \
  mix allbert.settings providers set-key openai

MIX_ENV=test mix allbert.home.import --dry-run \
  --in "$V059_EVIDENCE_DIR/home.envelope.json" \
  --evidence-out "$V059_EVIDENCE_DIR/import-diagnostic-after-secrets.json"
```

Pass condition: the target ref row changes from `target_status=missing` to
`target_status=configured`. Do not paste secret values into the envelope,
diagnostic, release evidence, chat, or terminal commands with positional secret
arguments.

## Manual Rollback

v0.59 import is dry-run only, so rollback is normally just the proof that no files
changed. For any future operator-applied import, use this manual procedure:

1. Stop Allbert processes that are using the target Home.
2. Move the modified target Home aside:
   ```sh
   mv "$ALLBERT_HOME" "$ALLBERT_HOME.rollback-$(date +%Y%m%d%H%M%S)"
   ```
3. Restore the prior Home directory from the operator backup.
4. Start Allbert with the restored `ALLBERT_HOME`.
5. Run:
   ```sh
   MIX_ENV=test mix allbert.security status
   MIX_ENV=test mix allbert.settings doctor
   ```

The rollback evidence is the pre/post Home hash proof plus the restored security
and settings-version status output. There is no v0.59 command that auto-applies or
auto-rolls-back an import.
