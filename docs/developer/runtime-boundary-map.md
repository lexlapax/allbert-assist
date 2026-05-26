# Runtime Boundary Map

This map is the v0.31 M1 inventory for Runtime And UI-Substrate
Consolidation. It names the public facades that callers may use today, the
planned facades later v0.31 milestones will introduce, and the compatibility
shims that survive only with explicit retirement criteria.

Machine-readable companion: `AllbertAssist.Boundary`.

## Rules

- Public facades are the only modules downstream plans should target.
- Internal helpers may move without downstream coordination.
- Compatibility shims stay callable only until their owning milestone retires
  or reclassifies them.
- Metadata, generated files, plugin manifests, settings fragments, and Surface
  catalog entries never grant authority by themselves.
- v0.31 is behavior-preserving. Route removal, app-intent handoff, theming,
  dynamic drafts, and the generator belong to v0.32-v0.37.

## Current Public Facades

| Subsystem | Public facade today | Notes |
|---|---|---|
| Runtime | `AllbertAssist.Runtime` | Operator/channel input enters here. |
| Actions | `AllbertAssist.Actions.Registry`, `AllbertAssist.Actions.Runner`, `AllbertAssist.Actions.Capability` | Current action discovery, execution, and metadata path. |
| Security | `AllbertAssist.Security` | Permission decision authority. |
| Settings | `AllbertAssist.Settings` | Operator configuration authority. |
| Paths | `AllbertAssist.Paths` | Current Allbert Home path facade. |
| Redaction | `AllbertAssist.Security.Redactor` | Current redaction helper for security-facing values. |
| Trace | `AllbertAssist.Trace` | Current trace facade. |
| Surface | `AllbertAssist.Surface` | Current Surface DSL and validation facade. |
| Workspace | `AllbertAssist.Workspace`, `AllbertAssist.Workspace.Catalog` | Current workspace context and tree/catalog facade. |
| Apps | `AllbertAssist.App.Registry` | Current app contribution registry. |
| Plugins | `AllbertAssist.Plugin.Registry` | Current plugin contribution registry. |
| Resources | `AllbertAssist.Resources` | Resource grants and Resource Access facade. |
| Objectives | `AllbertAssist.Objectives` | Objective lifecycle facade. |
| Intent | `AllbertAssist.Intent.Engine` | Current intent routing facade. |

## Planned v0.31 Facades

| Milestone | Planned facade | Replaces or wraps |
|---|---|---|
| M1 | `AllbertAssist.Boundary` | New machine-readable inventory only. |
| M3 | `AllbertAssist.Runtime.Paths` | Implemented wrapper over `AllbertAssist.Paths` without changing paths. |
| M3 | `AllbertAssist.Runtime.Redactor` | Implemented runtime-facing facade over current redaction policy without weakening output. |
| M4 | `AllbertAssist.Runtime.Audit` | Implemented shared audit facade over existing audit writers and Security Central audit metadata. |
| M4 | `AllbertAssist.Runtime.Persistence` | Implemented shared persistence facade for hybrid metadata/body stores and Fragment body codecs. |
| M4 | `AllbertAssist.Runtime.Trace` | Implemented shared trace facade over the existing markdown trace writer. |
| M5 | `AllbertAssist.Action` | Implemented thin Allbert-facing wrapper over `Jido.Action`; registered action modules now declare capability metadata directly. |
| M6 | `AllbertAssist.Runtime.Response` | Implemented typed runtime response helpers used by Runtime, Runner, PermissionGate status mapping, and representative objective branches. |
| M7 | `AllbertAssist.Extensions.Registry` | Implemented unified compiled plugin/app contribution facade. |
| M7 | `AllbertAssist.Surface.Catalog` | Implemented single Surface component/catalog/renderer authority. |
| M8 | `AllbertAssist.Settings.Fragment` | Implemented per-context/app/plugin settings schema fragment contract. |
| M8 | `AllbertAssist.Settings.Fragments` | Implemented settings schema fragment registry and composition facade. |
| v0.36 | `AllbertAssist.Sandbox` | Implemented report-only facade for doctor, bundle, command, gate, source-policy enforcement, audit, and cleanup. |
| v0.37 | `AllbertAssist.DynamicPlugins` | Implemented facade for file-backed dynamic draft generation, gate evidence, trusted validation, loader integration, rollback, and read-only status. |
| v0.37 | `AllbertAssist.DynamicPlugins.Codegen.Agent` | Implemented JidoBacked coordinator for explicit source-bearing capability-gap draft requests. |
| v0.37 | `AllbertAssist.DynamicPlugins.ActionsOverlay` | Implemented runtime overlay merged by `Actions.Registry`; collision denial, no shadowing. |
| v0.37 | `AllbertAssist.DynamicPlugins.TrustedValidator` | Implemented trusted-phase AST/body validator before in-core compile. |

## Post-v0.38 Planned Facades

The v0.39-to-v1.0 arc is planned future work. The names below are routing
anchors for planning only; they are not current public facades until their
milestones implement and document them.

| Milestone | Planned boundary | Notes |
|---|---|---|
| v0.39 | Onboarding and model/profile control | Expected to wrap Objective Runtime, Settings Central, provider profiles, and reviewed memory retrieval. |
| v0.40 | MCP client facade | Expected to consume `mcp://` resources through registered MCP actions and ADR 0038 trust-tier policy. |
| v0.42 | Browser/research facade | Expected to live in a plugin-owned browser boundary with `browser://session/<id>` Resource Access. |
| v0.44 | Plan/Build surface and workflow YAML parser | Expected to produce objective steps only; not an execution engine. |
| v0.45-v0.46 | Media resource facades | Expected to model audio, image, and screenshot resources plus registered provider-backed actions. |
| v0.48 | Marketplace/protocol facades | Expected to expose marketplace-lite metadata plus API, ACP, MCP-server, and AG-UI/A2UI bridges under shared auth/CSP/redaction policy. |
| v0.49 | Self-improvement suggestion facade | Expected to produce inert trace-derived suggestions and draft handoffs only; not authority, enablement, or live integration. |

## Compatibility Shims And Exit Criteria

| Shim | Owning milestone | Exit criteria |
|---|---|---|
| `AllbertAssist.Security.PermissionGate` | post-v0.31 | Retire only after all runtime-facing callers use `AllbertAssist.Security` directly and security eval parity is explicit. |
| `AllbertAssist.Settings.Schema` compatibility facade | M8 | Every key is owned by registered fragments with unchanged defaults, validation, secret handling, and safe-write policy. |

M2 removed the obsolete `AllbertAssist.Workspace.Catalog.component_renderer/1`
membership probe. Workspace component membership remains available through
`AllbertAssist.Workspace.Catalog.known_components/0`, which now delegates to
`AllbertAssist.Surface.Catalog`.

M3 added the runtime-facing `AllbertAssist.Runtime.Paths` and
`AllbertAssist.Runtime.Redactor` facades. Existing compatibility modules remain
callable, but new runtime-facing code should target the `Runtime.*` facades.

M4 added `AllbertAssist.Runtime.Audit`, `AllbertAssist.Runtime.Persistence`,
and `AllbertAssist.Runtime.Trace`. Runtime-facing audit writers, Security
Central audit metadata, trace recording, workspace body persistence, and
Fragment body decoding now route through the runtime facades while preserving
the existing markdown/YAML/SQLite formats.

M5 added `AllbertAssist.Action` and migrated registered runtime-facing core and
StockSage action modules from raw `use Jido.Action` to
`use AllbertAssist.Action`. The action registry now derives capability metadata
from modules instead of a duplicate central map. Raw `Jido.Action` remains
allowed for unregistered/private/test-only commands such as the `Multiply`
fixture.

M7 added `AllbertAssist.Surface.Catalog`,
`AllbertAssistWeb.Surface.Renderer`, and `AllbertAssist.Extensions.Registry`.
The v0.30 StockSage pass-through workspace adapters and
`StockSageWeb.Components.SurfaceRenderer` are retired; workspace and
StockSage-owned app surfaces now dispatch through the same catalog-backed
renderer path while preserving the v0.30 DOM handles.

M8 added `AllbertAssist.Settings.Fragment` and
`AllbertAssist.Settings.Fragments`. `AllbertAssist.Settings.Schema` remains as
the public compatibility facade used by current callers, but its schema,
defaults, and safe-write key assembly now come from core/app/plugin fragments.
`AllbertAssist.Security.PermissionGate` remains a compatibility shim over
Security Central until a future parity pass migrates the remaining live callers.

v0.36 adds `AllbertAssist.Sandbox` as the public sandbox/gate-runner facade.
Runtime gate commands are reviewed `mix` profiles only, SourcePolicy runs in
the facade before backend resolution, and sandbox lifecycle events append
bounded audit records under Allbert Home. Sandbox reports are evidence only;
they do not load modules, register actions, grant permissions, enable skills,
mutate routing context, or authorize v0.37 live integration.

v0.37 adds `AllbertAssist.DynamicPlugins` as the public dynamic-draft facade.
The draft store is file-backed under Allbert Home and is producer-agnostic;
ordinary plugin discovery never scans dynamic draft or integrated roots.
`DynamicPlugins.Codegen.Agent` is a JidoBacked coordinator for explicit
capability-gap draft requests; `Codegen.Producer` can write source-bearing
read-only and delegated memory/network action drafts through Jido.AI structured
generation plus objective observations. The producer uses bounded Planner,
Author, TrialAuthor, Critic, and Repair packets. The trusted loader is the only
path that may compile reviewed generated source in core, and only after gate
evidence plus Security Central confirmation. Dynamic actions merge through
`Actions.Registry` via the actions overlay, never shadow static or source-tree
plugin/app actions, and route generated memory/network effects through reviewed
facades.

## Internal Modules

Internal modules are still tested and may remain public in Elixir visibility
terms, but downstream plans should not target them as contracts. Examples:

- `AllbertAssist.Settings.Store`, `Settings.Secrets`, `Settings.YamlCodec`,
  and lower schema helpers.
- `AllbertAssist.Plugin.Entry`, `Plugin.Manifest`, `Plugin.Discovery`, and
  validators behind `Plugin.Registry`.
- `AllbertAssist.DynamicPlugins.MetadataStore`, staging helpers, loader step
  helpers, and generated manifest parsers behind `AllbertAssist.DynamicPlugins`.
- `AllbertAssist.App.Validator`, app bootstrap helpers, and dynamic supervisor
  helpers behind `App.Registry`.
- `AllbertAssist.Workspace.Fragment.*`, body stores, signing secrets, and
  canvas row structs behind `AllbertAssist.Workspace`.
- `AllbertAssist.Security.Policy`, risk helpers, audit writers, and context
  normalizers behind `AllbertAssist.Security`.
- Private Jido command modules under agent state machines. They are not
  Allbert capability actions and must not appear in intent candidates.

## M1 Acceptance

M1 is complete when:

- `AllbertAssist.Boundary` exposes current facades, planned facades,
  compatibility shims, and deletion candidates.
- Tests prove current facades and shims still load.
- This map and `docs/plans/v0.31-request-flow.md` record M1 status.
