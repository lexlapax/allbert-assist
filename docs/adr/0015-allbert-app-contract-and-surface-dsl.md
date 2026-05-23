# ADR 0015: Allbert App Contract And Surface DSL

## Status

Accepted. v0.15 minimal contract implemented. v0.18 full app/surface contract
implemented on 2026-05-15; memory namespace registration is split after the
post-v0.26 roadmap reconciliation: namespace declaration/registration lands in
v0.27, while namespace-consuming memory sync lands in v0.29.
Amended during the v0.26 planning-readiness pass (2026-05-18) to enumerate
the v0.26 catalog expansion from 12 → 42 components — see the "v0.26
Catalog Expansion" subsection under Surface DSL. The catalog expansion is the
substrate ADR 0023 builds on for the workspace canvas + ephemeral surface
implementation, and was confirmed in place during v0.26 M20 closeout.
Extended by ADR 0030 (v0.31): Surface catalog and renderer dispatch consolidate
behind one authority. Extended by ADR 0024 (v0.32): the Surface DSL gains a
`:panel` surface kind
contributed into host-owned `/workspace` zones, the `/apps/<app_id>` page-route
convention for rare app pages, and host structural catalog atoms for the
workspace shell, app launcher, utility drawer, and workspace panels. ADR 0024
also makes `/workspace` the canonical operator route and removes `/agent`,
`/settings`, and `/stocksage/*` compatibility.

## Context

Allbert is becoming a personal AI workspace rather than a single chat surface.
StockSage is the first planned domain plugin app inside that workspace. It
needs to register actions, skills, app navigation, signals, settings, and
eventually canvas components without reaching through private Allbert
internals.

ADR 0017 adds a broader plugin contract. That decision does not replace the
app contract. A plugin is the package/discovery boundary; an app is one
contribution type inside that boundary.

The existing core already has important boundaries: registered Jido actions,
the shared action runner, Security Central, Settings Central, Agent Skills
discovery, Phoenix PubSub, and the Jido signal bus. What it lacks is a public
contract for another local app, including plugin-contributed apps, to
participate as a first-class Allbert workspace app.

v0.26 (formerly v0.24) plans an agentic workspace surface and declarative UI
substrate. That canvas should consume a stable Allbert-native app and surface
contract rather than inventing app discovery, component catalogs, or node
shapes inside the LiveView implementation.

External protocols such as AG-UI and A2UI are useful research references, but
Allbert's local web surface should remain Phoenix LiveView over supervised
Elixir data structures first. Protocol compatibility can be added later as an
adapter after the local contract is proven.

## Decision

Allbert defines an app contract centered on `AllbertAssist.App` and
managed by `AllbertAssist.App.Registry`.

### v0.15 Minimal Contract

The v0.15 minimal contract, formerly M-AppContract-Lite, includes:

- App identity: `app_id/0`, `display_name/0`, and `version/0`.
- Startup validation and child supervision via `validate/1` and `child_spec/1`.
- Registered Jido actions tagged with `app_id` via `actions/0`.
- App skill paths added to the global skill registry via `skill_paths/0`.
- Legacy navigation surface descriptors via `surfaces/0` for the future
  Allbert shell.

The v0.15 registry is volatile and supervised as one unit: registry ETS state,
app child supervision, and bootstrap registration restart together. String app
ids are normalized through the registry without creating atoms from operator,
model, channel, or job input. v0.15 navigation surface descriptors are display
data only; they do not mount routes, load LiveViews, or define canvas nodes.

### v0.18 Full Contract

The v0.18 full contract, formerly M-AppContract-Full, expands the app/surface
contract through these layers. The post-v0.26 roadmap reconciliation splits
memory namespaces into declaration and consumption: apps declare namespaces in
v0.27, and v0.29 is the first StockSage milestone that writes through that
namespace.

- Identity and OTP lifecycle: validation, child specs, and workspace config
  injection.
- Agents, actions, and signals: `agents/0` (declared agent modules),
  `actions/0` (registered actions), and `signals/0` (declared emitted and
  subscribed signal topics).
- Skills: app-owned `SKILL.md` paths discovered through the existing Agent
  Skills registry via `skill_paths/0`.
- Settings: `settings_schema/0` (schema declarations merged into Settings
  Central at runtime, not at compile time). Settings schema entry keys must
  begin with `apps.<app_id>.`.
- UI surface: `surfaces/0` kept as the legacy navigation summary; interactive
  surfaces declared through `AllbertAssist.App.SurfaceProvider`; the native
  `AllbertAssist.Surface` DSL validates nodes and action bindings.
- Memory namespace declaration records the namespaces an app may later write
  through existing Allbert boundaries. Declaration lands in v0.27 so v0.28 can
  audit ownership/isolation before v0.29 adds namespace-consuming writes.

### Registry

`AllbertAssist.App.Registry` is the runtime app discovery point. In v0.15,
registered apps provide identity, child supervision, action tags, skill paths,
navigation descriptors, and app lookup for active-app validation. In v0.18,
the same public contract expands to store declared agents, signals, settings
schemas, SurfaceProvider surfaces, and surface catalogs, and exposes them
through new query functions.

App registration does not grant permission by itself; actions still run through
the action runner, Security Central, confirmations, traces, and audits.

Cross-app duplicate route paths produce registry diagnostics but do not fail
registration. Same-app duplicate surface ids are validation failures.

### Settings Schema Merge

v0.18 wires plugin and app settings schema contributions into Settings Central
at runtime. The static compiled schema is always present. App registry
contributions and plugin registry contributions are merged at read and
validation time. If a registry is unavailable, Settings Central proceeds with
the available sources and logs a warning; it does not crash.

This closes the v0.17 gap where contributions were stored in registries but
never consumed.

### Active App Default

v0.18 adds a resolution rule applied to all request entry points: if no
explicit known app context exists and the session scratchpad has no known
`active_app`, the runtime defaults to `active_app: :allbert`. Unknown app id
strings from channels, model output, or external requests are not atomized;
they fall back to `:allbert` with a diagnostic. The resolution rule lives in
`AllbertAssist.Runtime` and applies to CLI, LiveView, channel adapter, and
job turns.

`active_app` is resolved context, not execution authority.

### SurfaceProvider

Allbert defines `AllbertAssist.App.SurfaceProvider` for apps with interactive
surfaces. Required callbacks are `surfaces/0` and `surface_catalog/0`. An
optional `fallback_surface/1` callback provides text-only fallback when
rendering cannot use nodes.

An app may implement both `AllbertAssist.App` and
`AllbertAssist.App.SurfaceProvider` in the same module. `CoreApp` is the first
`SurfaceProvider` implementation in v0.18; StockSage v0.20 is the second.

Implementation note: v0.18 keeps the legacy `AllbertAssist.App.surfaces/0`
navigation callback for backward compatibility. Because Elixir warns when two
behaviours define the same callback name/arity with different intent,
`use AllbertAssist.App.SurfaceProvider` records a persisted provider marker
attribute instead of adding a second `@behaviour` to modules that already use
`AllbertAssist.App`. The contract module and callback signatures remain the
public documentation boundary; `AllbertAssist.App.Validator` detects the
provider marker and validates provider surfaces/catalogs through the same
rules.

Surface events must return Jido signals or route through registered actions.
LiveView renders and collects operator input; it does not own app domain logic,
approval storage, security policy, or resource grants.

### Surface DSL

Allbert defines `AllbertAssist.Surface` as the native declarative surface DSL
for v0.26 (formerly v0.24) canvas artifacts and task-scoped ephemeral UI.
Surface nodes are
Elixir data validated against a known component catalog. The v0.18 initial
catalog has twelve components: `:route`, `:chat`, `:timeline`, `:composer`,
`:panel`, `:section`, `:text`, `:list`, `:empty_state`, `:button`,
`:action_button`, `:status_badge`.

#### v0.26 Catalog Expansion (42 components total)

v0.26 expands the catalog to support the workspace canvas + ephemeral
surface substrate per ADR 0023. The expansion adds 30 new components
organized in four groups:

**Workspace structural (10)** — the building blocks of the workspace
shell itself:

- `:workspace` — the root of the workspace Surface tree
- `:canvas` — the persistent canvas region
- `:tile` — a persistent unit inside a canvas
- `:ephemeral_surface` — a task-scoped overlay
- `:header` — workspace header region
- `:badge_strip` — horizontal badge container
- `:tabs` — tab container
- `:tab` — single tab entry
- `:tab_panel` — content panel for an active tab
- `:diff` — before/after content diff rendering

**Allbert-domain (12)** — non-app-specific UI primitives:

- `:trace_link` — link to a trace markdown file
- `:trace_viewer` — inline trace markdown viewer
- `:icon` — bounded icon (allowlisted icon library)
- `:link` — local-route link
- `:divider` — horizontal/vertical visual separator
- `:table` — bounded tabular layout
- `:row` — table row
- `:column` — table column
- `:objective_card` — v0.24 objective summary card
- `:confirmation_card` — v0.07 confirmation card with v0.24 objective context
- `:approval_card` — confirmation-approval UI surface
- `:approval_inspector` — bounded confirmation-approval detail view

**Allbert-app cards (4)** — domain cards for built-in apps:

- `:memory_review_card` — v0.21 memory review surface
- `:job_card` — v0.13 scheduled-job summary card
- `:channel_card` — v0.16 channel status card
- `:settings_card` — Settings Central single-key card

**StockSage analysis cards (4 reserved in v0.26; implemented v0.27)**:

- `:analysis_card` — v0.22/v0.25 analysis summary card
- `:agent_report_card` — v0.25 specialist agent report card
- `:parity_card` — v0.25 `--engine both` parity diff card
- `:debate_round_card` — v0.25 bull/bear/risk debate round card

The 4 StockSage cards are PRESENT in the v0.26 catalog (so emitters
can target them) but their rendering modules ship as v0.26 stubs that
display a placeholder + link to the legacy `/stocksage/analysis/:id`
route until v0.27 ships the real rendering modules in StockSage-owned
`/stocksage/...` LiveViews. v0.30 later wires those proven renderers into
durable `/agent` canvas tiles through the workspace canvas mechanism; v0.30
does not introduce a second component shape.

Total catalog after v0.26: **42 components** (12 v0.18 carryover + 30
v0.26 additions).

Validation rules (catalog enforcement, secret-key rejection, raw-HTML
rejection, registered-action-binding enforcement) apply uniformly to
all 42 components without exception. No component is "internal" or
"unvalidated."

Model output cannot invent arbitrary HTML, JavaScript, LiveView components,
actions, permissions, resource identities, scripts, URLs, or secret-bearing
fields. Surface validation enforces:

- Node component atoms must be in the known catalog.
- Prop keys matching secret-like patterns (`*_key`, `*_secret`, `*_token`,
  `*_password`, `*_credential`) are rejected.
- Prop values that are raw HTML strings, script strings, or remote URLs are
  rejected.
- Surface paths must be local routes starting with `/`; no scheme or host.
- Action bindings must reference registered action names present in the
  actions registry.

Action bindings are validated at surface registration time. They carry
permission and confirmation requirement metadata from the actions registry as
display metadata; they cannot grant permission, change confirmation
requirements, or bypass Security Central.

### AG-UI and A2UI Stub

`AllbertAssist.Surface.Encoder.to_a2ui/1` is introduced in v0.18 as the
designated AG-UI adaptation interface. Its type signature documents the
intended translation from `AllbertAssist.Surface` validated nodes to AG-UI
`STATE_SNAPSHOT`-style events. The v0.18 implementation returns
`{:error, :not_implemented}`. AG-UI and A2UI must not become runtime package
dependencies in v0.18 or earlier versions.

### CoreApp

`AllbertAssist.App.CoreApp` is the first `SurfaceProvider` implementation,
established in v0.18. It declares the `/agent` conversation route as the
built-in chat surface — the default surface every local runtime turn lands on
when no other `active_app` is active. Runtime requests default to
`active_app: :allbert` in v0.18 so every turn has a declared home app.
Explicit known app context from request data or the v0.14 scratchpad still
wins. v0.26 (formerly v0.24) upgrades `CoreApp`'s surface from `/agent` into
the full workspace shell; it is `CoreApp`'s surface implementation, not a
separate shell.

### StockSage

StockSage is the second proving app for this contract. v0.20, formerly M-D2a,
implements `StockSage.App` with the v0.18 app/surface contract from day one —
there is no lite-to-full migration. v0.27 (formerly v0.25) builds all
StockSage LiveViews on `AllbertAssist.App.SurfaceProvider` from day one;
there is no stepping-stone static route mounting that later migrates to the
surface contract. v0.27 also adds app memory namespace declaration so v0.28
can audit namespace ownership before v0.29 consumes the namespace through
explicit StockSage lesson/memory sync.

## Consequences

- Every runtime turn has a declared home app from v0.18: `active_app: :allbert`
  by default, overridden when a specific app context is active.
- The built-in chat surface (`/agent`, upgraded to the workspace shell in
  v0.26 (formerly v0.24)) is formally declared through `CoreApp`'s
  `SurfaceProvider`, not an orphan LiveView route.
- StockSage can be added as a shipped plugin app without private
  routing, security, or skill-registration shortcuts.
- Intent routing can use `active_app` from session context to prioritize
  app-scoped actions while keeping cross-app routing explicit.
- v0.26 (formerly v0.24) has a concrete app registry and surface DSL to
  consume for workspace shell navigation and canvas component validation.
  v0.26 is `CoreApp`'s surface upgrade, not a separate shell.
- Future Allbert apps get a stable contract before generator work begins.
- The app contract does not add new execution authority. Permission decisions
  remain at the action boundary.
- Settings schema contributions from apps and plugins participate in Settings
  Central validation and reads; the v0.17 gap is closed.
- App registration for apps with invalid surfaces fails only for those apps;
  the runtime keeps running.
- Cross-app duplicate route paths are observable warnings; they are not boot
  failures.

## Deferred

- Namespace-consuming app memory sync, deferred to v0.29. Namespace
  declaration/registration itself lands in v0.27 so ownership is security-
  auditable before writes exist.
- `mix allbert.gen.plugin` and `mix allbert.gen.app` scaffolding, until
  StockSage proves the plugin/app contract, StockSage SurfaceProvider
  LiveViews, memory namespace declaration plus consumption, and canvas path
  through v0.30, catalog/registry consolidation in v0.31, workspace panels in
  v0.32, app intent descriptors/handoff in v0.33, theming/layout hooks in
  v0.34, and sandboxed dynamic drafts in v0.35. Planned for v0.36.
- AG-UI streaming endpoints, A2UI renderer compatibility, MCP Apps, and
  third-party remote UI execution.
- Dynamic runtime mounting of arbitrary routes or LiveView components from
  untrusted app folders.
- Hosted marketplace publishing of app skill packs.
- Canvas component catalog expansion beyond the 42-component v0.26 catalog.
- Automatic signal subscription wiring from declared `signals/0` metadata.
  v0.18 stores declarations only; Jido signal flow remains the only runtime
  signal path.
