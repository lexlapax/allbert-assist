# Artifact Store Developer Guide

Status: v0.50 implemented. This guide summarizes the core Artifacts Central
code seams. v0.50b/`0.50.1` owns the operator browser surfaces; see
`docs/developer/artifacts-browser.md`.

## Storage

Artifacts Central is an in-tree content-addressable store over BEAM and the
filesystem. It adds no third-party CAS dependency.

Important modules:

- `AllbertAssist.Artifacts`
- `AllbertAssist.Artifacts.Store`
- `AllbertAssist.Artifacts.MetadataIndex`
- `AllbertAssist.Artifacts.Bounds`
- `AllbertAssist.Artifacts.Config`
- `AllbertAssist.Artifacts.GC`

Objects are addressed by lowercase SHA-256 and stored below
`Paths.artifacts_root/0`:

```text
objects/<first2>/<next2>/<sha256>
index/<first2>/<next2>/<sha256>.md
```

The markdown sidecar stores allow-listed metadata only. Raw bytes never belong
in traces, logs, LiveView assigns, CLI output, or sidecar metadata.

## Identity And Permissions

The Resource Access URI is:

```text
artifact://sha256/<hex>
```

`ResourceURI.derived_fields/1` derives `origin_kind: :artifact_store`.
The URI is an identifier only and never grants permission.

Registered actions:

- `put_artifact`
- `get_artifact`
- `list_artifacts`
- `artifact_threads`
- `delete_artifact`
- `artifact_doctor`

All runtime-facing access resolves through `AllbertAssist.Actions.Registry` and
executes through `AllbertAssist.Actions.Runner.run/3`. Direct store calls are
for internal storage helpers and tests at that layer only.

Permission classes:

- `:artifact_read` floor `:allowed`
- `:artifact_write` floor `:allowed`
- `:artifact_delete` floor `:needs_confirmation`

`delete_artifact` is confirmation-gated and resumable.

## Provenance

`artifact_thread_links` is the SQLite join table for conversation provenance.
It records `{artifact_sha256, user_id, thread_id, message_id, role}` edges with
deterministic ids. The same content hash can appear in multiple threads.

Thread links are provenance only. By-thread listing and reverse lookup still
run through `:artifact_read`.

Relevant modules:

- `AllbertAssist.Artifacts.ThreadLink`
- `AllbertAssist.Artifacts.ThreadLinks`
- `AllbertAssist.Actions.Artifacts.ListArtifacts`
- `AllbertAssist.Actions.Artifacts.ArtifactThreads`

## Retained Media And Sensor

Retained media writes use:

- `AllbertAssist.Artifacts.MediaRetention`
- `AllbertAssist.Artifacts.Backfill`
- `AllbertAssist.Artifacts.IngestionSupervisor`
- `AllbertAssist.Artifacts.IngestionConsumer`
- `AllbertAssist.Artifacts.IngestionSensor`

The ingestion sensor is the codebase's first supervised `Jido.Sensor` path. It
runs under `Jido.Sensor.Runtime`, emits redacted
`allbert.artifact.ingest_requested` signals, and has an explicit dispatch
target. It never writes the store and never grants authority. After dispatch is
confirmed, the retained-media caller invokes `Runner.run("put_artifact", ...)`
so settings, permissions, bounds, redaction, and provenance stay on the action
boundary.

## Tests

Focused v0.50 surfaces:

```sh
mix test apps/allbert_assist/test/allbert_assist/artifacts
mix test apps/allbert_assist/test/allbert_assist/actions/artifact_actions_test.exs
mix test apps/allbert_assist/test/security/v050_artifact_store_eval_test.exs
mix allbert.test release.v050
```
