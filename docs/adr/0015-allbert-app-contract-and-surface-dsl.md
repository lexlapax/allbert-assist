# ADR 0015: Allbert App Contract And Surface DSL

## Status

Accepted.

## Context

Allbert is becoming a personal AI workspace rather than a single chat surface.
StockSage is the first planned domain app inside that workspace. It needs to
register actions, skills, app navigation, signals, settings, and eventually
canvas components without reaching through private Allbert internals.

The existing core already has important boundaries: registered Jido actions,
the shared action runner, Security Central, Settings Central, Agent Skills
discovery, Phoenix PubSub, and the Jido signal bus. What it lacks is a public
contract for another umbrella app to participate as a first-class Allbert
workspace app.

v0.26 also plans an agentic workspace surface and declarative UI substrate.
That canvas should consume a stable Allbert-native app and surface contract
rather than inventing app discovery, component catalogs, or node shapes inside
the LiveView implementation.

External protocols such as AG-UI and A2UI are useful research references, but
Allbert's local web surface should remain Phoenix LiveView over supervised
Elixir data structures first. Protocol compatibility can be added later as an
adapter after the local contract is proven.

## Decision

Allbert will define an app contract centered on `AllbertAssist.App` and
managed by `AllbertAssist.App.Registry`.

The minimal contract for v0.15, formerly M-AppContract-Lite, includes:

- app identity: `app_id`, display name, and version
- startup validation and child supervision
- registered Jido actions tagged with `app_id`
- app skill paths added to the global skill registry
- navigation surface descriptors for the future Allbert shell

The v0.15 registry is volatile and supervised as one unit: registry ETS
state, app child supervision, and bootstrap registration restart together.
String app ids are normalized through the registry without creating atoms from
operator, model, channel, or job input. v0.15 navigation surface descriptors
are display data only; they do not mount routes, load LiveViews, or define
canvas nodes.

The full contract for v0.24, formerly M-AppContract-Full, expands this into
five layers:

- Identity and OTP lifecycle: validation, child specs, and workspace config
  injection.
- Agents, actions, and signals: registered agents/actions, declared emitted
  and subscribed signal topics, and scoped routing metadata.
- Skills: app-owned `SKILL.md` paths discovered through the existing Agent
  Skills registry.
- UI surface: navigation surfaces, configured routes, surface providers, and
  later canvas component catalogs.
- Data and settings: settings schema declarations and memory namespaces the
  app may write through existing Allbert boundaries.

`AllbertAssist.App.Registry` is the runtime app discovery point. In v0.15,
registered apps provide identity, child supervision, action tags, skill paths,
navigation descriptors, and app lookup for active-app validation. In v0.24,
the same public contract expands to declared signals, settings schemas, memory
namespaces, and interactive surface providers. App registration does not grant
permission by itself; actions still run through the action runner, Security
Central, confirmations, traces, and audits.

Allbert will define `AllbertAssist.App.SurfaceProvider` for apps with
interactive surfaces. Surface events must return Jido signals or route through
registered actions. LiveView renders and collects operator input; it does not
own app domain logic, approval storage, security policy, or resource grants.

Allbert will define `AllbertAssist.Surface` as the native declarative surface
DSL for v0.26 canvas artifacts and task-scoped ephemeral UI. Surface nodes are
Elixir data validated against a known component catalog. Model output cannot
invent arbitrary HTML, JavaScript, LiveView components, actions, permissions,
resource identities, scripts, URLs, or secret-bearing fields.

AG-UI and A2UI remain optional future adapters. The first local substrate uses
LiveView, PubSub, Jido signals, registered actions, and
`AllbertAssist.Surface` directly. Any external protocol encoder must preserve
the same validation, provenance, fallback text, redaction, and action-binding
rules.

StockSage is the first proving app for this contract. It starts with the lite
contract before v0.17, formerly M-D2a, then implements the full contract
before v0.26 canvas work consumes app surfaces.

## Consequences

- StockSage can be added as new umbrella apps without private routing,
  security, or skill-registration shortcuts.
- Intent routing can use `active_app` from session context to prioritize
  app-scoped actions while keeping cross-app routing explicit.
- v0.26 has a concrete app registry and surface DSL to consume for workspace
  shell navigation and canvas component validation.
- Future Allbert apps get a stable contract before generator work begins.
- The app contract does not add new execution authority. Permission decisions
  remain at the action boundary.

## Deferred

- `mix allbert.gen.app` scaffolding, until StockSage proves the contract and
  v0.26 ships.
- AG-UI streaming endpoints, A2UI renderer compatibility, MCP Apps, and
  third-party remote UI execution.
- Dynamic runtime mounting of arbitrary routes or LiveView components from
  untrusted app folders.
- Hosted marketplace publishing of app skill packs.
