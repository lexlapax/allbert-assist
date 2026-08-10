# allbert.artifacts — Artifacts Browser

Operator browsing surfaces for Artifacts Central.

## What it is

A shipped source-tree plugin of `kind: "app"`, entered through
`AllbertArtifacts.Plugin` and contributing one app, `AllbertArtifacts.App`.

## Why it exists, and what it deliberately is not

Artifacts Central owns artifact storage, permissions, settings, and scheme
authority. This plugin owns none of that — it contributes *browsing surfaces*
over what Central already governs. Registration is inert contract data: the
plugin grants no access by being present.

Keeping the browser separable from the store is the point. A surface can change,
break, or be removed without touching the authority that decides what an
operator may see.

## Contents

- `allbert_artifacts/plugin.ex` — plugin entrypoint and contribution declaration.
- `allbert_artifacts/app.ex` — the contributed app.
- `allbert_artifacts/surface_provider.ex`, `panels/browser.ex` — workspace
  surfaces.
- `allbert_artifacts_web/` — LiveViews for the web workspace.
- `mix/tasks/allbert.artifacts.ex` — operator task.

## How it is loaded

Like every directory under `plugins/`, this is **not** a separate Mix project.
Its `lib` is injected into `apps/allbert_assist` through `elixirc_paths/1`, so it
compiles into that application. `allbert_plugin.json` is discovery metadata, not
a runtime code-loading instruction. See the repository `plugins/` tier note in
`docs/adr/0098-kernel-application-pack-contract-tier-model.md`.
