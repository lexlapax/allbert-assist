# Artifacts Central Operator Guide

Introduced in v0.50; current as of v0.63. This guide covers operating the core artifact
store. The browsing panel, detail page, and `mix allbert.artifacts` CLI ship in
the v0.50b/`0.50.1` Artifacts Browser sidecar; see
`docs/operator/artifacts-browser.md`.

## Operator Posture

Artifacts Central stores durable local artifacts under Allbert Home as
content-addressed bytes:

```text
<ALLBERT_HOME>/artifacts/objects/<first2>/<next2>/<sha256>
<ALLBERT_HOME>/artifacts/index/<first2>/<next2>/<sha256>.md
artifact://sha256/<hex>
```

Artifact identifiers are inert. A valid `artifact://sha256/<hex>` URI does not
grant read, write, delete, thread, memory, export, or provider authority.

Retention is default-off. Durable artifact writes require both:

```sh
mix allbert.settings set artifacts.enabled true
mix allbert.settings set artifacts.retention_enabled true
```

Artifact reads and writes use registered action permissions:

```sh
mix allbert.settings set permissions.artifact_read allowed
mix allbert.settings set permissions.artifact_write allowed
mix allbert.settings set permissions.artifact_delete needs_confirmation
```

Delete remains confirmation-gated. Do not lower
`permissions.artifact_delete` below `needs_confirmation`.

## Retained Media

v0.50 migrates the retained branch of prior media features into Artifacts
Central:

- v0.48 retained audio under `voice.audio.retention_root`
- v0.49 retained vision uploads under `vision.media.retention_root`
- v0.49 retained generated images under `image.generation.retention_root`

The legacy roots are backfill inputs only. New retained workspace voice,
workspace image, and generated-image writes go through the supervised artifact
ingestion sensor and the registered `put_artifact` action. Transient scratch
paths remain scratch and are not migrated.

Historical Browser cache files are not migrated by v0.50. Browser-found
artifacts can become durable only through approved artifact write flows; the
operator browsing repository ships in v0.50b as Artifacts Browser.

## Bounds

Useful settings:

```text
artifacts.max_bytes
artifacts.allowed_mime
artifacts.allowed_types
artifacts.gc.enabled
artifacts.gc.delete_orphans
```

Bounds are enforced before writes. Rejected bytes are not stored.

## Validation

Primary release validation:

```sh
mix allbert.test release.v050
```

Expected evidence:

```text
<ALLBERT_HOME>/release_evidence/v050/release-v050-<ts>.json
```

The gate uses local fixtures only and covers CAS identity, metadata sidecars,
permissions, redaction, delete confirmation, retained-media backfill, the
supervised ingestion sensor, workspace retained media, thread links, and the
eight v0.50 artifact-store security eval rows.
