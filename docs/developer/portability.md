# Portability Contract

v0.59 introduces a dry-run-only portability substrate for Allbert Home. It is a
hardening contract for later packaging work, not an applied migration engine.

## Envelope

`AllbertAssist.Portability.Export.build/1` returns a JSON-encodable envelope with:

- `envelope_version` set by `AllbertAssist.Portability.Envelope`.
- `settings.user_settings` redacted at sensitive paths.
- `settings.fragments` from `Settings.VersionContract.inventory/1`.
- `secret_references` rows with refs and configured/missing status only.
- `manifest.home.files` as hashes-only file metadata.
- inert import invariants for self-improvement and media capture.

The envelope must exclude secret-store files and values:

- `settings/secrets.yml.enc`
- `settings/.settings_key`
- plaintext provider keys, tokens, authorization headers, and endpoint values

## Dry-Run Import

`AllbertAssist.Portability.Import.dry_run/2` reads an envelope, validates
`envelope_version`, checks settings fragment versions, reports target secret-ref
status, and returns a diagnostic. It must not write to the target Home.

The diagnostic contract includes:

- `dry_run: true`
- `applied: false`
- `settings_version_contract`
- `secret_references`
- `inert_import_plan.applied_changes: none`

Forward or invalid settings fragment versions return `{:error, diagnostic}` with
`status: "blocked"`.

## Performance Target Rule

The v0.59 perf/CSP gate records disposable-Home baselines and derives thresholds
from them:

- Export and dry-run import: `max(2s, baseline * 1.25)`.
- If the baseline already exceeds `2s`, evidence must include the target and a
  rationale.
- Version boot-check overhead: `max(50ms, baseline * 1.10)`.

The tagged test is:

```sh
MIX_ENV=test mix test apps/allbert_assist_web/test --only perf_csp_baseline
```

It prints measured-vs-target evidence for `perf-and-csp-baseline-001`.

## Test Ownership

Keep portability tests close to the contract:

- Unit coverage: `apps/allbert_assist/test/allbert_assist/portability/`.
- Operator task coverage: `apps/allbert_assist/test/mix/tasks/allbert_home_test.exs`.
- Perf/CSP release evidence:
  `apps/allbert_assist_web/test/allbert_assist_web/perf_csp_baseline_test.exs`.

Do not add an apply/import runner in v0.59. A future applied migration must have a
new ADR or ADR update, operator confirmation, rollback semantics, and release
evidence separate from the dry-run contract.
