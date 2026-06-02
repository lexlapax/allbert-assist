# Marketplace Lite

Allbert v0.45 ships Marketplace Lite as a local, reviewed seed catalog.
It is not a remote marketplace and it does not grant execution authority.

## Scope

Marketplace Lite contains Allbert-author seed bundles under
`priv/marketplace/`:

- `skill` entries install into
  `<ALLBERT_HOME>/marketplace/skills/<entry-id>/`.
- `template` entries install into
  `<ALLBERT_HOME>/marketplace/templates/<entry-id>/` and appear in
  `workspace:create` as metadata only.
- `plugin_index` entries are browse-only reviewed-source metadata and
  cannot be installed.

Installed bundles always start as `disabled_untrusted`. Enabling a skill,
executing code, loading plugins, or integrating generated capabilities remains
a separate operator action outside v0.45 Marketplace Lite.

## Settings

Marketplace is enabled by default:

```sh
mix allbert.settings get marketplace.enabled
mix allbert.settings get marketplace.schema_version
mix allbert.settings get marketplace.installed_state_path
```

Emergency disable:

```sh
mix allbert.settings set marketplace.enabled false
mix allbert.settings set permissions.marketplace_install denied
```

`marketplace.schema_version` is read-only at `1`. It is the v0.45 preview of
the ADR 0046 schema-version convention; the migration runner is deferred to
v0.51.

`marketplace.catalog.cache_path`,
`marketplace.install.target_dir_skills`, and
`marketplace.install.target_dir_templates` may be customized, but the resolved
paths must remain under Allbert Home. `marketplace.enabled=false` disables all
marketplace actions; `permissions.marketplace_install=denied` is the narrower
write-action lock.

## Browse And Install

```sh
mix allbert.marketplace doctor
mix allbert.marketplace list
mix allbert.marketplace list --kind skill
mix allbert.marketplace show allbert/research-helpers
mix allbert.marketplace verify allbert/research-helpers
mix allbert.marketplace install allbert/research-helpers
mix allbert.marketplace installed
mix allbert.marketplace rollback allbert/research-helpers
```

Install checks the shipped catalog, verifies the bundle hash, writes files
under Allbert Home, and updates
`<ALLBERT_HOME>/marketplace/installed.json`. Rollback removes the installed
directory and the state entry; the shipped catalog remains available for
reinstall.

## Workspace

Open `/workspace` and choose **Marketplace Catalog** to inspect entries,
verify hashes, install installable skill/template entries, and rollback
installed entries.

Open `workspace:create` to see installed marketplace templates. These cards
show `metadata_only` template metadata and installed files; they do not become
executable v0.38 template patterns.

## Doctor

```sh
mix allbert.marketplace doctor
```

The doctor returns an ADR 0047-style redacted envelope and writes
`<ALLBERT_HOME>/marketplace/doctor/state.json`. It verifies:

- shipped `priv/marketplace/index.json` parses;
- shipped bundle hashes match;
- installed bundle hashes still match `installed.json`;
- installed targets still exist;
- `marketplace.schema_version` matches the running code.

Expected clean output includes `live_check_status=ok`. A tampered install
reports `live_check_status=degraded` with
`installed_bundle_hash_mismatch`.

## Troubleshooting

- `plugin_index_not_installable`: the entry is browse-only metadata.
- `bundle_hash_mismatch`: the shipped catalog or bundle contents are not in
  the reviewed state; reinstall from a clean checkout.
- `install_target_outside_marketplace`: the bundle manifest or configured
  target directory tried to write outside the permitted Allbert Home-rooted
  marketplace install area.
- `orphan_install`: `installed.json` names a target directory that no longer
  exists; rollback the entry.
- `installed_bundle_hash_mismatch`: installed files changed after install;
  rollback and reinstall if desired.

Marketplace Lite is single-vendor in v0.45. Community submission, remote
workflow distribution, remote plugin installation, and bundle signing are
parked for later milestones.
