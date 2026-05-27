# Allbert Template Patterns

Status: v0.38 implementation in progress. M1 implemented the registry and
deterministic renderer. M2 implemented the `plugin` and `app` developer
scaffolds. M3 implemented the `llm_tool`, `flow`, and `objective` scaffolds
plus `mix allbert.gen.tool` and `mix allbert.gen.flow`.

Template patterns are vetted, parameterized skeletons that produce Allbert
plugin/app/action/objective artifacts. They are an accelerator over the
hand-written source-tree workflow in
`docs/developer/how-to-create-an-allbert-app.md`. Templates and their
parameters are **metadata** — they grant no authority by themselves.

## Source Documents

- `docs/plans/v0.38-plan.md`
- `docs/plans/v0.38-request-flow.md`
- `docs/adr/0036-templated-creation-and-pattern-registry.md`
- `docs/adr/0035-codegen-agents-and-live-integration-loader.md` (v0.37 engine
  reused by templated live integration)
- `docs/adr/0037-elixir-otp-sandbox-backend-and-gate-runner.md` (v0.36 sandbox
  reused by templated live integration)
- `docs/adr/0017-allbert-plugin-contract.md`
- `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

## `TemplatePattern` Behaviour

A pattern is an Elixir module that implements `AllbertAssist.Templates.Pattern`
and is registered in `AllbertAssist.Templates.Registry`. A pattern declares:

- `id/0` — stable string slug, e.g. `"plugin"`, `"app"`, `"llm_tool"`,
  `"flow"`, `"objective"`.
- `label/0` and `description/0` — short human-readable gallery metadata.
- `parameter_schema/0` — validated parameter schema; values are data and
  cannot become atoms or filesystem paths without explicit normalization.
- `files/0` — the static, in-tree file set the pattern is allowed to render.
  Files outside this set are never written.
- `target_shapes/0` — declared output shapes (action, app, panel,
  settings_fragment, memory_namespace, objective_wiring, jobs, route_page, child
  process). Used to compute effective `live_integration?` against v0.37 loader
  scope.
- `live_integration?/0` — boolean. Patterns whose target shapes the v0.37
  loader rejects must declare `false`.
- `validation_profile/0` — optional reviewed validation/gate profile for the
  generated artifact (e.g. `mix allbert.validate_app`).
- `normalize_params/1` — optional pattern-specific normalization layered on top
  of common slug/display/module-name derivation.

## Parameter Schema And Normalization

- Schemas use deterministic validators. Unknown keys fail closed.
- Raw parameters are **never** turned into atoms with `String.to_atom/1`.
  Identifier-bearing parameters route through normalization helpers that
  validate against existing atoms / registry entries (app id, destination id,
  schedule id) or generate fresh, bounded slugs.
- Template file paths route through the deterministic renderer's safe relative
  path checks, and developer scaffold target roots reject parent traversal
  before writing. Only files declared by the reviewed pattern are written.
- Module namespaces are reviewed and bounded — generated modules live under
  `AllbertAssist.DynamicPlugins.Generated.*` (operator drafts) or the
  developer-chosen plugin namespace (developer scaffolds).

## Deterministic Rendering

- Rendering is reviewed-template substitution. If EEx (or an equivalent
  templating engine) is used, only the in-tree reviewed template files are
  evaluated; parameter values are escaped/normalized data, never executable
  template code.
- Two renders of the same `(pattern, params)` pair produce byte-identical
  output (modulo timestamps, which are recorded in `metadata.yaml` only for
  operator drafts).
- Output is inert by default. Generated theme/snippet/layout stubs respect
  v0.34/v0.35 constraints and remain disabled.

## Output Modes And `live_integration?`

| Mode | Where output lands | Authority grant |
|---|---|---|
| Developer scaffold | `--target` (default `./plugins/<name>/`) | None. Inert source for human review/compile/test. |
| Operator templated draft | `<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` | None until v0.36 gate + v0.37 loader + Security Central confirmation. |

Operator templated drafts enter the v0.37 lifecycle at `:draft` with
`producer: "template_pattern"` and the pattern id in `metadata.yaml`. Live
integration is available only for patterns whose `live_integration?` is `true`.

v0.38 shipped pattern status:

| Pattern id | Status | `live_integration?` | Reason |
|---|---|:-:|---|
| `plugin` | implemented | false | v0.37 loader rejects generated plugin manifests/apps/settings fragments. |
| `app` | implemented | false | v0.37 loader rejects generated apps, panels, settings fragments, memory namespaces, and objective wiring. |
| `llm_tool` | implemented | true | Action artifacts are the only v0.37.5 live-loadable shape. |
| `flow` | implemented | false | Jobs and objective wiring are deferred v0.37 live targets. |
| `objective` | implemented | false | Objective wiring is a deferred v0.37 live target. |

When a future milestone widens v0.37 loader scope, individual patterns can
flip `live_integration?` to `true` without ADR change.

## LLM-Tool Pattern And Delegated Effects

The LLM-tool pattern produces a reviewed dynamic action scaffold with an
instruction-bearing read-only path and bounded delegated-effect variants:

- **Read-only** generated actions do not delegate and pass the v0.37 trusted
  validator without extra facade settings.
- **Memory-write** and **external-network** generated actions must route
  through
  `AllbertAssist.DynamicPlugins.Delegate.run/3` to an operator-allowlisted
  reviewed facade (v0.37.3 ceiling: `external_network_request` and
  `append_memory`). Delegated-effect validation runs in the v0.37 trusted
  validator before in-core compile. The reviewed developer scaffold is still
  inert until a human compiles it or the v0.36/v0.37 live path accepts it.

## Adding A Future Pattern

Checklist for adding a future templated pattern without granting authority:

- [ ] Implement `AllbertAssist.Templates.Pattern` with a stable `id`.
- [ ] Add a reviewed file set under the templates source root. Files outside
      this set are not rendered.
- [ ] Define a parameter schema with explicit validators and normalization;
      reject unknown keys.
- [ ] Decide `live_integration?` honestly against current v0.37 loader scope.
- [ ] If `live_integration?: true`, run the v0.37 trusted validator against
      generated source for every supported variant of the parameter schema.
- [ ] Add focused tests: registry/list, parameter validation, deterministic
      rendering, traversal/size denial, no-overwrite-without-force,
      live-integration eligibility.
- [ ] Add a security eval row for the new pattern.
- [ ] Document the pattern in this file and in the v0.38 plan / request-flow.

## Inspection And Operator Surfaces

- `mix allbert.gen.plugin NAME [--target PATH] [--force]` — implemented M2.
- `mix allbert.gen.app NAME [--target PATH] [--force]` — implemented M2.
- `mix allbert.gen.tool NAME [--target PATH] [--force]
  [--permission read_only|memory_write|external_network]` — implemented M3.
- `mix allbert.gen.flow NAME [--target PATH] [--force]` — implemented M3
  scheduled/chron flow scaffold.
- `mix allbert.gen.flow NAME --pattern objective [--target PATH] [--force]`
  — implemented M3 objective-workflow scaffold.
- `mix allbert.validate_app APP_ID_OR_MODULE` — first-run app validation after
  the generated module is compiled; safe app-id lookup does not create atoms
  from raw input.
- `mix allbert.dynamic list/show/disable` — inspects templated drafts beside
  v0.37 codegen drafts; `producer: "template_pattern"` distinguishes them.
- `workspace:create` — operator Canvas destination. Gated by
  `templates.create.enabled` (default off). Operator live integration also
  requires `dynamic_codegen.enabled`,
  `dynamic_codegen.live_loader_enabled`, and `sandbox.elixir.enabled`. The
  `dynamic_codegen.integration_approval_surfaces` allowlist (default
  `["cli","liveview"]`) excludes Telegram, email, and cross-channel approval.

## Authority Invariants

- Templates and parameters grant no authority.
- Developer scaffolds never integrate live.
- Operator templated integration is **exactly** the v0.36 + v0.37 gated path —
  no parallel sandbox, no parallel loader, no parallel confirmation surface.
- Generated actions cannot shadow static/plugin/app actions, cannot replace
  core modules, cannot exceed the v0.37.3 permission ceiling, and cannot
  bypass `AllbertAssist.DynamicPlugins.Delegate.run/3` for `:memory_write`
  or `:external_network` effects.
