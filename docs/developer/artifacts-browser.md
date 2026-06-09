# Artifacts Browser Developer Guide

Status: v0.50b implemented as the `0.50.1` sidecar release.

Artifacts Browser is a shipped plugin/app wrapper over the v0.50 core artifact
actions. It contributes operator surfaces only; it does not own the store,
permissions, scheme, settings root, ingestion sensor, or filesystem paths.

## Plugin Shape

Important modules:

- `AllbertArtifacts.Plugin`
- `AllbertArtifacts.App`
- `AllbertArtifacts.SurfaceProvider`
- `AllbertArtifacts.Panels.Browser`
- `AllbertArtifactsWeb.ArtifactLive`
- `AllbertArtifactsWeb.Live`
- `Mix.Tasks.Allbert.Artifacts`

The plugin id is `allbert.artifacts`; the app id is `:allbert_artifacts`.

Plugin authority contract:

```elixir
AllbertArtifacts.Plugin.actions() == []
AllbertArtifacts.Plugin.channels() == []
AllbertArtifacts.Plugin.settings_schema() == []
AllbertArtifacts.App.actions() == []
AllbertArtifacts.App.memory_namespace() == nil
```

## Store Access

All browser surfaces call `AllbertAssist.Actions.Runner.run/3`:

- `list_artifacts`
- `get_artifact`
- `artifact_threads`
- `artifact_doctor`
- `delete_artifact`

The plugin must not call:

- `AllbertAssist.Artifacts.Store`
- `AllbertAssist.Artifacts.MetadataIndex`
- `AllbertAssist.Runtime.Paths.artifacts_root/0`
- raw filesystem APIs for artifact objects or sidecars

Tests may call store/index modules only when they are asserting persistence or
confirmation behavior at the test boundary.

## Workspace Panel

`AllbertArtifacts.App.surfaces/0` declares one `:canvas_panels` surface. Runtime
hydration flows through `workspace_panel_surfaces/1`, which delegates to
`AllbertArtifacts.SurfaceProvider` and `AllbertArtifacts.Panels.Browser`.

Panel filters are passed through the workspace context as
`:artifacts_browser_filters`. Supported normalized fields:

```text
mime
origin
thread_id
since
retention
lifecycle
limit
```

The panel renders host catalog nodes only. Raw bytes must never enter assigns,
surface props, logs, or CLI output.

## Detail Route

The core web router owns the host route:

```elixir
live "/apps/artifacts/:sha", AllbertArtifactsWeb.ArtifactLive, :show
```

The LiveView module is plugin-owned. It validates lowercase 64-character
SHA-256 before invoking actions. Invalid paths render a redacted not-found
state and do not probe the store.

## CLI

`mix allbert.artifacts` is a thin CLI over action calls:

```sh
mix allbert.artifacts list [--type MIME] [--origin ORIGIN] [--thread THREAD_ID] [--since DATE_OR_ISO] [--retention VALUE] [--lifecycle VALUE] [--limit N]
mix allbert.artifacts show <sha|artifact://sha256/sha>
mix allbert.artifacts threads <sha|artifact://sha256/sha>
mix allbert.artifacts doctor
mix allbert.artifacts rm <sha|artifact://sha256/sha>
```

`rm` must return `:needs_confirmation` unless the core confirmation context has
approved the delete.

## Release Gate

Focused tests:

```sh
mix test \
  ../../plugins/allbert.artifacts/test/allbert_artifacts/plugin_test.exs \
  ../../plugins/allbert.artifacts/test/allbert_artifacts/app_panels_test.exs \
  ../../plugins/allbert.artifacts/test/mix/tasks/allbert_artifacts_test.exs

mix test \
  test/security/v050b_artifacts_browser_eval_test.exs \
  test/security/security_eval_case_test.exs \
  test/mix/tasks/allbert_test_task_test.exs
```

Authoritative sidecar release gate:

```sh
mix allbert.test release.v050b
```

The release lane seeds a deterministic browser fixture through
`scripts/v050b_artifacts_browser_smoke.exs --seed-only` and records the fixture
SHA/thread/URLs in the evidence JSON.
