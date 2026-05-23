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
- v0.31 is behavior-preserving. Route removal, theming, dynamic drafts, and the
  generator belong to v0.32-v0.35.

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
| M4 | `AllbertAssist.Runtime.Audit` | Shared audit facade over existing audit writers. |
| M4 | `AllbertAssist.Runtime.Persistence` | Shared persistence facade for hybrid metadata/body stores. |
| M5 | `AllbertAssist.Action` | Thin Allbert-facing wrapper over `Jido.Action`. |
| M6 | `AllbertAssist.Runtime.Response` | Typed runtime response helpers. |
| M7 | `AllbertAssist.Extensions.Registry` | Unified compiled plugin/app contribution facade. |
| M7 | `AllbertAssist.Surface.Catalog` | Single Surface component/catalog/renderer authority. |
| M8 | `AllbertAssist.Settings.Fragment` | Per-context/app/plugin settings schema fragments. |

## Compatibility Shims And Exit Criteria

| Shim | Owning milestone | Exit criteria |
|---|---|---|
| `AllbertAssist.Security.PermissionGate` | M8 | All runtime-facing callers use `AllbertAssist.Security` directly and security eval parity is explicit. |
| `AllbertAssist.Settings.Schema` monolith | M8 | Every key is owned by registered fragments with unchanged defaults, validation, secret handling, and safe-write policy. |
| `StockSageWeb.Components.SurfaceRenderer` | M7 | StockSage app surfaces dispatch through the shared catalog/renderer path. |
| `AllbertAssistWeb.Workspace.Components.*Card` StockSage adapters | M7 | Workspace renderer dispatches StockSage card renderers directly through the shared catalog. |

M2 removed the obsolete `AllbertAssist.Workspace.Catalog.component_renderer/1`
membership probe. Workspace component membership remains available through
`AllbertAssist.Workspace.Catalog.known_components/0`; renderer dispatch remains
in `AllbertAssistWeb.Workspace.Renderer` until M7 moves dispatch into
`AllbertAssist.Surface.Catalog`.

M3 added the runtime-facing `AllbertAssist.Runtime.Paths` and
`AllbertAssist.Runtime.Redactor` facades. Existing compatibility modules remain
callable, but new runtime-facing code should target the `Runtime.*` facades.

## Internal Modules

Internal modules are still tested and may remain public in Elixir visibility
terms, but downstream plans should not target them as contracts. Examples:

- `AllbertAssist.Settings.Store`, `Settings.Secrets`, `Settings.YamlCodec`,
  and lower schema helpers.
- `AllbertAssist.Plugin.Entry`, `Plugin.Manifest`, `Plugin.Discovery`, and
  validators behind `Plugin.Registry`.
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
