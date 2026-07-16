# ADR 0082: Registry Injection Seams For Test Isolation

## Status

Accepted at v1.0.2 M2 (2026-07-16, the commit that landed the complete seam,
side-effect-isolated fixture, and concurrent cross-contamination proof).
Binding on M2/M3 and on all future registry-reading code.

## Context

Virtually the entire core test suite runs in serial lanes (v1.0.2 M0 census:
~291 explicitly serial core files + 127 `DataCase` + 28 `SecurityEvalCase`
versus 21 `pure_async`). The dominant cause is that tests exercising
registry-dependent behavior must mutate the GLOBAL singletons
(`AllbertAssist.App.Registry`, `AllbertAssist.Plugin.Registry`) via
clear+register+restore, which (a) forces them into serial lanes — the dominant
wall-clock cost — and (b) leaks state across serially-ordered files — the
documented order-dependence class (five root-caused residue failures in the
v1.0.1 build, plus the operator-known ~20 full-`mix test` estimate).

Both registries already accept `server:` through their public read/write functions
and accept `name:` at `start_link/1`; their `server/1` helpers are private. A private
instance must also receive a unique `table_name:` because the backing ETS tables are
named. `DynamicPlugins.ActionsOverlay` / `Extensions.Registry` read functions are
already parametric — but the production READ paths break the chain by calling
with defaults and accepting no options: `Actions.Registry.agent_modules/0`,
`internal_capabilities/0`, `plugin_actions/0` (`actions/registry.ex:502/:528/
:674`), the `Intent.Engine` read sites (`intent/engine.ex:816/:904/:1263/:1432`),
and `Skills.Registry` (`skills/registry.ex:279-299`). A private per-test
registry is therefore invisible to the code under test.

ADR 0015/0031 make the registration↔Settings-schema coupling intentional: a
setting is valid iff its owning app is registered; apps register at boot and
stay registered in production. Tests that tear the global down violate that
invariant — the correct fix is per-test isolation, never weakening the
invariant.

## Decision

1. **Registry-reading production functions accept one optional internal
   `RegistryContext` keyword**:
   `app: [server: app_server]`, `plugin: [server: plugin_server]`, and
   `actions_overlay: overlay_server`. Omission means the current global defaults.
   The context is translated to the existing nested `app:` / `plugin:` option
   shape at `Extensions.Registry`. It is never accepted from serialized params,
   channels, public protocols, or operator surfaces.
2. **The initial thread-through is complete for the named conversion targets.**
   It covers `Actions.Registry` module, name, capability, metadata/provenance,
   diagnostics, and agent/internal wrappers; `Intent.Engine` action, descriptor,
   surface, app-normalization, and active-app reads; `Skills.Registry` app/plugin
   root discovery; `Extensions.Registry`; and app/plugin provenance lookups used
   while building capabilities. Adding context to only
   `agent_modules/internal_capabilities/plugin_actions` is insufficient.
3. **Production call sites pass nothing.** The default path must return identical
   values, ordering, diagnostics, provenance, and authority decisions. This is
   proved by focused registry/intent/skills suites, compile warnings-as-errors,
   Credo, Dialyzer, `release.v1`, and the authoritative release gate.
4. **Tests use a reusable private-registry fixture.** Each fixture starts supervised
   App and Plugin registries with unique process names AND unique ETS `table_name`
   values, registers exactly its fixture set, and passes the context explicitly.
   Negative tests start two contexts concurrently and prove that registrations,
   descriptors, capabilities, diagnostics, and provenance do not cross-contaminate.
5. **Private registration is side-effect isolated.** Registry registration gains an
   internal-only `side_effects: false` mode for fixtures. It suppresses global
   registration signals and shared Settings-schema cache invalidation while keeping
   validation and registry-local state identical. The production default remains
   `side_effects: true`. A test is not isolation-safe while its private registration
   still mutates either global facility.
6. **The seams grant nothing.** Registry context selects WHERE registrations
   are read from; it must never bypass registration, permission, confirmation, or
   Settings-schema authority. Registration still uses the same validators and
   local invariant inside the private instance.
7. **Lane demotion follows a complete resource audit, not the reverse.** A file's
   primary lane changes only after it owns registry context, database/home/settings,
   process names, HTTP stubs, and filesystem roots. DB-bound files remain
   `db_serial` or `db_partition_safe`; registry isolation alone never makes them
   `pure_async`.

## Consequences

- Serial-lane files whose only global dependency is the registries become
  convertible to `pure_async` (v1.0.2 M3 converts the first wave; the
  remainder burns down on the Test Suite Speed & Isolation track).
- The registry-dependent residue failures lose their shared root cause. The TUI
  runner/configuration failure remains a separate singleton-resolution issue.
- A small, permanent API tax: registry-reading functions carry an `opts`
  parameter and new readers must propagate it. This is the accepted cost of a
  concurrent suite.
- No production behavior change; no new authority; ADR 0015/0031 untouched.

## Validation

- v1.0.2 M2: focused App/Plugin/Extensions/Actions/Intent/Skills suites, the
  concurrent two-context negative test, compile `--warnings-as-errors`, Credo,
  Dialyzer, `release.v1`, and the authoritative release gate are green. ADR 0082
  becomes Accepted only in the same commit that proves this complete context and
  side-effect contract.
- v1.0.2 M3: converted files green solo, in-batch, and full-lane;
  `inventory --check-tags` reconciles; timings recorded against the M0
  baseline.
