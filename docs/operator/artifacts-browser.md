# Artifacts Browser Operator Guide

Status: v0.50b implemented as the `0.50.1` sidecar release over the v0.50
Artifacts Central store.

Artifacts Browser is the operator browsing repository for durable local
artifacts. It exposes metadata-only browsing through:

- `/workspace?destination=app%3Aallbert_artifacts`
- `/apps/artifacts/<sha>`
- `mix allbert.artifacts list|show|threads|doctor|rm`

The browser owns no store authority. Every read goes through the core
`:artifact_read` actions, and delete goes through the core confirmation-gated
`delete_artifact` action.

## Required Settings

Use a disposable `ALLBERT_HOME` for validation. Durable writes require:

```sh
mix allbert.settings set artifacts.enabled true
mix allbert.settings set artifacts.retention_enabled true
mix allbert.settings set permissions.artifact_read allowed
mix allbert.settings set permissions.artifact_write allowed
mix allbert.settings set permissions.artifact_delete needs_confirmation
```

Do not lower `permissions.artifact_delete` below `needs_confirmation`.

## Workspace Panel

Open:

```text
/workspace?destination=app%3Aallbert_artifacts
```

Useful filter query params:

```text
artifact_type=text/plain
artifact_origin=<origin>
artifact_thread=<thread-id>
artifact_since=2026-06-01
artifact_retention=<value>
artifact_lifecycle=<value>
artifact_limit=25
```

The panel renders artifact metadata only: MIME, short SHA, byte count, origin,
thread id, retention/lifecycle, created time, and redaction status. It must not
render raw bytes or local paths.

## Detail Page

Open:

```text
/apps/artifacts/<64-char-lowercase-sha>
```

The page validates the SHA before reading the store. Invalid SHA paths render a
redacted not-found/error state without probing the object store.

The detail page shows metadata, provenance links, retention state, and a remove
control. Remove queues confirmation; the artifact remains stored until the core
confirmation path approves deletion.

## CLI

List recent artifacts:

```sh
mix allbert.artifacts list
```

Filter by metadata and provenance:

```sh
mix allbert.artifacts list \
  --type text/plain \
  --origin v050b_browser_smoke \
  --thread thread-v050b-artifacts-browser-smoke \
  --since 2026-06-01 \
  --retention retained \
  --lifecycle active \
  --limit 25
```

Inspect one artifact without bytes:

```sh
mix allbert.artifacts show <sha>
mix allbert.artifacts threads <sha>
mix allbert.artifacts doctor
```

Request deletion:

```sh
mix allbert.artifacts rm <sha>
```

Expected delete posture: `artifact delete needs confirmation: <id> <short-sha>`.

## Deterministic Browser Fixture

For browser validation, seed a real artifact fixture through the core
`put_artifact` action:

```sh
mix run scripts/v050b_artifacts_browser_smoke.exs --seed-only
```

Expected output:

```text
ARTIFACT_SHA=<64-hex>
THREAD_ID=thread-v050b-artifacts-browser-smoke
WORKSPACE_URL=/workspace?...
DETAIL_URL=/apps/artifacts/<64-hex>
```

Use the printed SHA and URLs. Do not use `<fixture-sha>` placeholders in
operator evidence.

## Release Validation

Primary release validation:

```sh
mix allbert.test release.v050b
```

Expected evidence:

```text
<ALLBERT_HOME>/release_evidence/v050b/release-v050b-<ts>.json
```

The evidence includes `browser_validation_fixture.artifact_sha256`,
`browser_validation_fixture.thread_id`, `workspace_url`, and `detail_url`.
