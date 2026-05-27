# Operator Guide: Templated Creation

Status: v0.38 implementation in progress. Developer scaffolds and Mix tasks
are implemented for plugin, app, LLM-tool, scheduled-flow, and objective
patterns. The `/workspace` `workspace:create` operator surface is implemented
as a view/compose panel with gallery, parameter form, preview, validation, and
bounded create-attempt diagnostics. Effectful scaffold writes and live
integration land behind registered template actions in a later v0.38
milestone.

## What It Is

Templated creation is the curated, deterministic creation experience: vetted
patterns produce inert reviewed source. Developers reach it through Mix tasks;
operators reach it through the `workspace:create` Canvas destination in
`/workspace`. Templates and their parameters grant **no authority**. Live
integration of templated artifacts goes through exactly the v0.36 sandbox and
v0.37 operator-confirmed loader, with no new authority.

## Two Output Modes

| Mode | Where output lands | Authority |
|---|---|---|
| Developer scaffold | `--target` (default `./plugins/<name>/`) | None. Inert source for human review/compile/test. |
| Operator live integration | `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` | None until v0.36 gate + v0.37 loader + Security Central confirmation. Available only for the LLM-tool pattern in v0.38. |

## What Each Pattern Does

| Pattern | Live integration in v0.38 | Notes |
|---|:-:|---|
| Plugin | no | Source-tree plugin skeleton. Inert source only. v0.37 loader does not accept generated plugin manifests/apps. |
| App | no | Full app contract (panels, settings fragment, intent descriptor, memory namespace, objective/canvas hooks, theming/layout docs). Inert source only. |
| LLM tool | **yes** | Jido.AI-backed action. The only pattern whose artifact shape is live-loadable today. |
| Scheduled/chron flow | no | Jobs + objective wiring. Inert source only — v0.37 does not accept jobs or objective wiring as live targets. |
| Objective workflow | no | Objective scaffold. Inert source only — same reason as the flow pattern. |

When live integration is unavailable, the developer-scaffold output is the
intended path: export the scaffold, review the source, compile it into your
plugin tree, and commit it like any other reviewed app.

## Settings

Templated creation is **default off** at the operator surface. Enable only
when you intend to use it. Disable for emergency posture.

| Key | Default | Meaning |
|---|---:|---|
| `templates.create.enabled` | `false` | Master switch for the operator `workspace:create` Canvas destination. |
| `templates.allowed_patterns` | reviewed defaults | Subset of patterns exposed in the gallery. |
| `dynamic_codegen.enabled` | `false` | Required for operator live integration (templated path reuses v0.37). |
| `dynamic_codegen.live_loader_enabled` | `false` | Required for operator live integration. |
| `sandbox.elixir.enabled` | `false` | Required for operator live integration (v0.36 sandbox/gate). |
| `dynamic_codegen.integration_approval_surfaces` | `["cli","liveview"]` | Approval surfaces allowed for integration/rollback. Telegram, email, and cross-channel approval are denied. |

Emergency disable:

```sh
mix allbert.settings set templates.create.enabled false
mix allbert.settings set dynamic_codegen.live_loader_enabled false
mix allbert.settings set dynamic_codegen.enabled false
mix allbert.settings set sandbox.elixir.enabled false
mix allbert.security review --recent --limit 25
```

## Operator Flow Through `/workspace`

1. Open `/workspace` and pick the **Create** destination.
2. Browse the template gallery. Patterns whose `live_integration?` is `false`
   show the live-integration toggle as disabled with a short tooltip pointing
   to the developer-scaffold path.
3. Pick a pattern. The Canvas renders a parameter form. Validation is
   bounded; unknown keys, traversal-laden names, oversize input, and
   parameter values that would create new atoms are denied with a
   short diagnostic.
4. Preview the generated tree and validation status.
5. Choose output:
   - **Developer scaffold** — Allbert renders to `--target` (default
     `./plugins/<name>/`) and stops. Inert. Existing roots require explicit
     `--force` plus preview/diff confirmation.
   - **Operator live integration** (LLM-tool only in v0.38) — Allbert writes
     the draft under `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with
     `producer: "template_pattern"`, runs the v0.36 sandbox trial/gate, and
     records evidence.
   The M4 surface is preview-only; choosing **Create** reports the action
   boundary required for the selected mode and writes no project files or
   dynamic draft files.
6. For live integration, approve the v0.37 confirmation record from a
   permitted surface (`cli` or `liveview`); Telegram/email/cross-channel
   approval is denied.
7. On approval, the v0.37 loader integrates the action live, audits the
   event, and exposes the new capability through the normal action runner.
8. Rollback remains available through `RollbackIntegration` and is also
   gated to permitted approval surfaces.

## Developer Flow Through Mix

```sh
mix allbert.gen.plugin my_plugin
mix allbert.gen.app my_app
mix allbert.gen.tool my_tool
mix allbert.gen.tool remember_preference --permission memory_write
mix allbert.gen.flow morning_brief
mix allbert.gen.flow nightly_review --pattern objective
mix allbert.validate_app my_app
```

`--target PATH` overrides the default `./plugins/<name>/`. `--force` is
required to overwrite an existing target root and triggers preview/diff
confirmation. Developer scaffolds never touch Allbert Home and never integrate
live. `mix allbert.validate_app my_app` works after the generated app module is
compiled; the task resolves loaded app modules by safe app id or by module
name.

## Inspecting Templated Drafts

Templated drafts that enter the v0.37 lifecycle are inspectable through the
existing dynamic-plugin tooling:

```sh
mix allbert.dynamic list
mix allbert.dynamic show <slug>
mix allbert.dynamic disable <slug>
mix allbert.security review --recent --limit 25
```

`mix allbert.dynamic list` shows the `producer` field for each draft.
Templated drafts show `template_pattern`; v0.37 LLM-authored drafts show
`codegen_committee`.

## Manual Smoke

- Disposable Allbert Home: `export ALLBERT_HOME="$(mktemp -d /tmp/allbert.XXXXXX)"`.
- Run `mix allbert.gen.plugin my_plugin` → confirm inert tree under
  `./plugins/my_plugin/` and `--force`-only overwrite.
- Run `mix allbert.gen.app my_app` then `mix allbert.validate_app my_app` →
  confirm first-run validation pass.
- Run `mix allbert.gen.tool my_tool` and confirm the output contains
  `dynamic_manifest.json` plus `source/lib/action.ex`; `--permission
  memory_write` and `--permission external_network` must route through
  `AllbertAssist.DynamicPlugins.Delegate.run/3`.
- Run `mix allbert.gen.flow morning_brief` and `mix allbert.gen.flow
  nightly_review --pattern objective`; confirm both outputs are inert and mark
  their generated job/workflow JSON as disabled.
- Enable `templates.create.enabled=true` and open `/workspace` Create → confirm
  gallery renders, parameter form validates, live-integration toggle is
  disabled for plugin/app/flow/objective patterns.
- Pick the LLM-tool pattern, render a draft, run the sandbox trial/gate, and
  confirm integration from CLI or LiveView.
- Confirm Telegram and email approval are denied for the same draft.
- Roll back the integration and confirm capability is removed.
- Disable `templates.create.enabled` and confirm the Create destination is
  denied with a bounded diagnostic.

## Authority Invariants

- Templates and parameters grant no authority.
- Developer scaffolds never integrate live.
- Operator templated integration is exactly the v0.36 + v0.37 gated path; no
  parallel sandbox, no parallel loader, no parallel approval surface.
- Existing project/draft roots cannot be overwritten without explicit
  `--force` plus preview/diff confirmation.
- Live integration in v0.38 covers only the LLM-tool (action) pattern;
  plugin/app/flow/objective patterns are developer-scaffold-only until a
  future milestone widens v0.37 loader scope.
