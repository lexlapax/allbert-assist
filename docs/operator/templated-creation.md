# Operator Guide: Templated Creation

Status: released and tagged as v0.38.1 on 2026-05-27 after operator manual
verification.
Developer scaffolds, Mix tasks, registered template actions, the `/workspace`
`workspace:create` operator surface, LLM-tool dynamic-draft creation, and
security eval coverage are implemented. `CreateFromTemplate` creates a v0.37
draft only after the template, dynamic-codegen, live-loader, and sandbox
switches are all enabled; sandbox trial, gate, and confirmed integration remain
explicit v0.37 actions.

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
| Developer scaffold | `--target` (default `./plugins/<name>/`); disposable smoke mode uses `<ALLBERT_HOME>/template-smoke/<name>/` | None. Inert source for human review/compile/test. |
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
   show the live-integration toggle as disabled and continue through the
   developer-scaffold path.
3. Pick a pattern. The Canvas renders a parameter form. Validation is
   bounded; unknown keys, traversal-laden names, oversize input, and
   parameter values that would create new atoms are denied with a
   short diagnostic.
4. Preview the generated tree and validation status.
5. Choose output:
   - **Developer scaffold** — Allbert renders to the default
     `./plugins/<name>/` target from the workspace surface and stops, or to
     `<ALLBERT_HOME>/template-smoke/<name>/` when the server process has
     `ALLBERT_TEMPLATE_SMOKE=1`. Inert. Existing roots are denied in the
     workspace surface. `--target` and `--force` are CLI-only Mix task
     controls.
   - **Operator live integration** (LLM-tool only in v0.38) — Allbert writes
     the draft under `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with
     `producer: "template_pattern"` and `template_pattern_id: "llm_tool"`.
     It returns the next explicit actions:
     `run_dynamic_draft_trial`, `run_dynamic_draft_gate`, and
     `integrate_dynamic_draft`.
6. Run the v0.36 sandbox trial/gate for live integration, then request
   integration through the v0.37 dynamic loader.
7. Approve the v0.37 confirmation record from a
   permitted surface (`cli` or `liveview`); Telegram/email/cross-channel
   approval is denied.
8. On approval, the v0.37 loader integrates the action live, audits the
   event, and exposes the new capability through the normal action runner.
9. Rollback remains available through `RollbackIntegration` and is also
   gated to permitted approval surfaces.

## Developer Flow Through Mix

```sh
export ALLBERT_TEMPLATE_SMOKE=1
mix allbert.gen.plugin my_plugin
mix allbert.gen.app my_app
mix allbert.gen.tool my_tool
mix allbert.gen.tool remember_preference --permission memory_write
mix allbert.gen.flow morning_brief
mix allbert.gen.flow nightly_review --pattern objective
```

`--target PATH` overrides the default `./plugins/<name>/`. `--force` is
required to overwrite an existing target root and triggers preview/diff
confirmation. `--smoke` or `ALLBERT_TEMPLATE_SMOKE=1` sends disposable
validation scaffolds to `<ALLBERT_HOME>/template-smoke/<name>/`; `--target`
still wins when both are supplied. Developer scaffolds never integrate live.
`mix allbert.validate_app my_app` works after the generated app module is
compiled; the task resolves loaded app modules by safe app id or by module
name.

## Inspecting Templated Drafts

Templated drafts that enter the v0.37 lifecycle are inspectable through the
existing dynamic-plugin tooling:

```sh
mix allbert.dynamic drafts list
mix allbert.dynamic drafts show <slug>
mix allbert.dynamic drafts discard <slug>
mix allbert.security review --recent --limit 25
```

`mix allbert.dynamic drafts list` shows the `producer` field for each draft.
Templated drafts show `template_pattern`; v0.37 LLM-authored drafts show
`codegen_llm`.

## Manual Smoke

v0.38.1 was accepted with this disposable manual-validation path. Use one
temporary Allbert Home for both CLI and Phoenix validation. Do not set
`DATABASE_PATH` for this dev-server run; `config/dev.exs` derives the SQLite
path from `ALLBERT_HOME`, and app startup creates and migrates a missing or
empty canonical Allbert Home database before runtime tables are used. Set
`ALLBERT_DEV_AUTO_MIGRATE=1` to also run pending migrations for an existing
dev database, or `ALLBERT_DEV_AUTO_MIGRATE=0` to disable the dev bootstrap.

Terminal A:

```sh
cd <repo-root>

export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v038-manual.XXXXXX)"
export ALLBERT_TEMPLATE_SMOKE=1

echo "$ALLBERT_HOME"

mix phx.server
```

Terminal B:

```sh
cd <repo-root>

export ALLBERT_HOME="/tmp/allbert-v038-manual.XXXXXX"
export ALLBERT_TEMPLATE_SMOKE=1
```

Replace the `ALLBERT_HOME` value with the one printed by Terminal A.

CLI generator smoke:

```sh
mix allbert.gen.plugin cli_plugin_smoke
mix allbert.gen.app cli_app_smoke
mix allbert.gen.tool cli_tool_smoke
mix allbert.gen.tool cli_remember_preference_smoke --permission memory_write
mix allbert.gen.flow cli_morning_brief_smoke
mix allbert.gen.flow cli_nightly_review_smoke --pattern objective
```

Expected:

```sh
test -d "$ALLBERT_HOME/template-smoke/cli_plugin_smoke"
test -d "$ALLBERT_HOME/template-smoke/cli_app_smoke"
test -d "$ALLBERT_HOME/template-smoke/cli_tool_smoke"
test ! -d plugins/cli_plugin_smoke
test ! -d plugins/cli_app_smoke
test ! -d plugins/cli_tool_smoke
```

Web disabled-state smoke:

1. Open `http://localhost:4000/workspace?destination=workspace:create`.
2. Confirm the Create surface says template creation is disabled.
3. In Terminal B run `mix allbert.settings set templates.create.enabled true`.
4. Refresh the browser and confirm the gallery, parameter form, preview, and
   validation panels render.

Web developer-scaffold smoke:

1. Select each pattern and keep **Developer scaffold** selected.
2. Use these names: `web_plugin_smoke`, `web_app_smoke`, `web_tool_smoke`,
   `web_flow_smoke`, and `web_objective_smoke`.
3. Click **Create** for each pattern.
4. Confirm preview targets include `template-smoke/<name>`.
5. Confirm live integration is disabled for plugin, app, flow, and objective
   patterns and enabled only for the LLM-tool pattern.

Expected:

```sh
test -f "$ALLBERT_HOME/template-smoke/web_plugin_smoke/allbert_plugin.json"
test -f "$ALLBERT_HOME/template-smoke/web_app_smoke/allbert_plugin.json"
test -f "$ALLBERT_HOME/template-smoke/web_tool_smoke/dynamic_manifest.json"
test -f "$ALLBERT_HOME/template-smoke/web_flow_smoke/priv/jobs/web_flow_smoke.json"
test -f "$ALLBERT_HOME/template-smoke/web_objective_smoke/priv/objectives/web_objective_smoke.json"

test ! -d plugins/web_plugin_smoke
test ! -d plugins/web_app_smoke
test ! -d plugins/web_tool_smoke
```

Web live-draft smoke:

```sh
mix allbert.settings set dynamic_codegen.enabled true
mix allbert.settings set dynamic_codegen.live_loader_enabled true
mix allbert.settings set sandbox.elixir.enabled true
```

In the browser, select **LLM tool**, set the name to `web_live_tool_smoke`,
choose **Live integration**, and click **Create**.

Expected:

```sh
mix allbert.dynamic drafts list
mix allbert.dynamic drafts show web_live_tool_smoke
test -d "$ALLBERT_HOME/dynamic_plugins/drafts/web_live_tool_smoke"
test ! -d plugins/web_live_tool_smoke
```

Final pollution check:

```sh
git status --short
find plugins -maxdepth 1 -type d \( -name '*smoke*' -o -name my_app -o -name my_plugin -o -name my_tool -o -name morning_brief -o -name nightly_review -o -name remember_preference \) -print
```

Both commands should produce no generated validation artifacts. Stop Phoenix
with `Ctrl-C` twice, then clean up:

```sh
rm -rf "$ALLBERT_HOME"
unset ALLBERT_TEMPLATE_SMOKE
unset ALLBERT_HOME
```

## Authority Invariants

- Templates and parameters grant no authority.
- Developer scaffolds never integrate live.
- Operator templated integration is exactly the v0.36 + v0.37 gated path; no
  parallel sandbox, no parallel loader, no parallel approval surface.
- Existing project roots cannot be overwritten without explicit `--force` plus
  preview/diff confirmation; existing dynamic draft roots are denied rather
  than overwritten.
- Live integration in v0.38 covers only the LLM-tool (action) pattern;
  plugin/app/flow/objective patterns are developer-scaffold-only until a
  future milestone widens v0.37 loader scope.
