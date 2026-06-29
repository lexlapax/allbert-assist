# Settings Version Contract

v0.59 records every Settings Central fragment with a first-class
`schema_version`. The contract is fail-closed: if a Home contains a forward or
invalid fragment version, Allbert refuses to silently load it.

## Check Current Home

```sh
set -euo pipefail
export ALLBERT_HOME="/path/to/home"

MIX_ENV=test mix allbert.settings doctor
MIX_ENV=test mix allbert.security status
```

Expected output:

```text
settings version contract status=ok
forward=0
invalid=0
diagnostics=none
```

Pass condition: status is `ok`, every fragment is current, and no forward or
invalid diagnostics are present.

## Interpret Diagnostics

`pending` means the stored Home is older than the runtime. v0.59 records this as a
manual migration note because no non-additive migration exists yet.

`forward` means the stored Home was written by a newer runtime. Stop and use the
newer Allbert version, or restore a Home backup that matches the current runtime.

`invalid` means a fragment `schema_version` is not a positive integer. Treat this
as Home corruption or a bad manual edit; restore from backup before continuing.

## Export/Import Interaction

`mix allbert.home.export` preserves each fragment version in the envelope.
`mix allbert.home.import --dry-run` validates those versions against the target
runtime and applies nothing.

Operator proof:

```sh
set -euo pipefail
export V059_EVIDENCE_DIR="$HOME/.allbert-release-evidence/v059"
export ALLBERT_HOME="/path/to/target-home"

MIX_ENV=test mix allbert.home.import --dry-run \
  --in "$V059_EVIDENCE_DIR/home.envelope.json" \
  --evidence-out "$V059_EVIDENCE_DIR/import-diagnostic.json"

rg '"status": "ok"|"dry_run": true|"applied": false' \
  "$V059_EVIDENCE_DIR/import-diagnostic.json"
rg 'settings_version_contract|current|pending|forward|invalid' \
  "$V059_EVIDENCE_DIR/import-diagnostic.json"
```

Expected output:

```text
"dry_run": true
"applied": false
settings_version_contract
current/pending/forward/invalid counts
```

The diagnostic file must live outside the target Home. The target Home must remain
byte-identical before and after the dry run.
