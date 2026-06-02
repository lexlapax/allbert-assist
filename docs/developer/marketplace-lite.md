# Marketplace Lite Developer Notes

Marketplace Lite is a v0.45 core-owned facade for reviewed local catalog
metadata and disabled/untrusted installs. It is a plain-module subsystem; it
does not own a GenServer or Jido agent.

## Module Surface

| Module | Responsibility |
|---|---|
| `AllbertAssist.Marketplace` | Public facade for catalog, install, rollback, verify, installed list, and doctor. |
| `Marketplace.Catalog` | Parses `priv/marketplace/index.json`, validates entries, verifies bundle hashes, mirrors the shipped index into the configured Allbert Home-rooted cache. |
| `Marketplace.Bundle` | Reads `bundle.json`, validates manifest shape, enumerates content files, computes SHA-256 bundle hashes. |
| `Marketplace.Install` | Installs `skill` and `template` bundles into the configured Allbert Home-rooted per-kind targets and writes `installed.json`. |
| `Marketplace.Rollback` | Removes installed targets and state entries. |
| `Marketplace.Installed` | Owns atomic `installed.json` reads/writes and the install lock. |
| `Marketplace.Templates` | Lists installed template metadata for `workspace:create`; it does not extend executable template patterns. |
| `Marketplace.Doctor` | ADR 0047-style redacted catalog/install health check. |
| `Marketplace.SurfaceProvider` | Workspace Marketplace Catalog surface registration. |

Action modules live under `AllbertAssist.Actions.Marketplace.*` and must run
through `AllbertAssist.Actions.Runner.run/3`.

## Schemas

Catalog index:

- `schema_version: 1`
- `catalog_version`
- `source: "shipped"`
- `generated_at`
- `source_git_commit`
- `entries`

Entry ids must match `<author>/<name>` using lowercase alphanumeric,
underscore, and dash. Supported kinds are `skill`, `template`, and
`plugin_index`.

Bundle manifests use `schema_version: 1`, `files`, `bundle_hash`, and for
installable kinds `install_target` plus `install_state:
"disabled_untrusted"`. Hashes are deterministic SHA-256 summaries of content
files, excluding `bundle.json`.

Installed state:

```json
{
  "schema_version": 1,
  "installed": [
    {
      "entry_id": "allbert/research-helpers",
      "version": "1.0.0",
      "installed_at": "2026-06-01T00:00:00Z",
      "install_state": "disabled_untrusted",
      "install_target": "<ALLBERT_HOME>/marketplace/skills/allbert-research-helpers",
      "bundle_hash": "sha256:..."
    }
  ]
}
```

## Authority Rules

- Catalog metadata is never permission authority.
- `marketplace://entry/<author>/<name>` is trace/audit identity only.
- `marketplace.enabled=false` disables every marketplace action before catalog
  or install work.
- `:marketplace_install` authorizes install and rollback actions; installed
  files still remain disabled/untrusted.
- Custom marketplace cache/install paths must stay under Allbert Home.
- Templates are metadata-only until a later milestone explicitly adds a
  reviewed execution path.
- `plugin_index` entries are browse-only and cannot install code.
- Workflow YAML distribution remains parked; v0.45 installs no `.yaml` or
  `.yml` workflow files.
- Marketplace cache mirrors are advisory. The shipped index remains catalog
  authority in v0.45.

## Actions And CLI

Registered actions:

- `list_marketplace_entries`
- `inspect_marketplace_entry`
- `install_marketplace_bundle`
- `rollback_marketplace_install`
- `list_installed_marketplace_bundles`
- `verify_marketplace_bundle_hash`
- `marketplace_doctor`

CLI:

```sh
mix allbert.marketplace list [--kind KIND]
mix allbert.marketplace show ENTRY_ID
mix allbert.marketplace install ENTRY_ID [--version VERSION]
mix allbert.marketplace installed
mix allbert.marketplace rollback ENTRY_ID
mix allbert.marketplace verify ENTRY_ID
mix allbert.marketplace mirror
mix allbert.marketplace doctor
```

## Doctor

`Marketplace.Doctor.run/1` returns an ADR 0047-style local endpoint envelope
with additive marketplace fields:

- `schema_version`
- `expected_schema_version`
- `catalog`
- `installed`
- `checks`
- `checked_at`
- `last_verified_at`
- `live_check_status`

It persists the same redacted result to
`<ALLBERT_HOME>/marketplace/doctor/state.json`.

## Testing

Focused implementation gates:

```sh
mix allbert.test focused -- apps/allbert_assist/test/allbert_assist/marketplace/catalog_install_test.exs
mix allbert.test focused -- apps/allbert_assist/test/allbert_assist/marketplace_test.exs apps/allbert_assist/test/allbert_assist/marketplace/templates_test.exs apps/allbert_assist/test/mix/tasks/allbert_marketplace_test.exs
mix allbert.test focused -- apps/allbert_assist/test/allbert_assist/marketplace/surface_provider_test.exs apps/allbert_assist/test/allbert_assist/intent/marketplace_routing_test.exs
mix allbert.test focused -- apps/allbert_assist/test/security/v045_marketplace_eval_test.exs apps/allbert_assist/test/security/security_eval_case_test.exs
```

Release validation:

```sh
mix allbert.test release.v045
```

The release gate writes JSON evidence under
`<ALLBERT_HOME>/release_evidence/v045/`.

## Future Direction

Community submissions, remote workflow distribution, remote code-bearing
plugin install, dependency resolution, and bundle signing stay parked in
`docs/plans/future-features.md`. v0.45 intentionally ships only the data
shape, action boundaries, seed catalog, and release evidence contract.
