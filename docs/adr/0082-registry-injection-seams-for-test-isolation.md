# ADR 0082: Registry Injection Seams For Test Isolation

## Status

Proposed for v1.0.2 M2 (accepted when the seam lands; binding on M2/M3 and on
all future registry-reading code).

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

Both registries already expose per-server seams (`server(opts)` at
`app/registry.ex:579-580` / `plugin/registry.ex:314-315`; `name:` start options)
and `DynamicPlugins.ActionsOverlay` / `Extensions.Registry` read functions are
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

1. **Registry-reading production functions accept an optional registry
   context** — an `opts` keyword (`:app_registry`, `:plugin_registry`, and
   where applicable `:actions_overlay`) naming the server(s) to read —
   **defaulting to the global singletons**. The initial thread-through covers
   `Actions.Registry.agent_modules/internal_capabilities/plugin_actions`, the
   `Intent.Engine` read sites, and `Skills.Registry`; any NEW code that reads a
   registry must accept and propagate the same context rather than hard-coding
   the global.
2. **Production call sites pass nothing.** The default path must be
   byte-for-byte behavior-identical; the freeze sweep (`release.v1`), Dialyzer,
   and the unchanged existing suites prove each thread-through.
3. **Tests own private registries instead of mutating the global.** A test
   starts supervised, uniquely-named `App.Registry`/`Plugin.Registry` instances,
   registers exactly the fixture set it needs (upholding the ADR 0015/0031
   invariant inside its private world), and passes the context through the
   seam. Global clear+register+restore is deprecated for new tests and burned
   down lane-by-lane in existing ones.
4. **The seams grant nothing.** Registry context selects WHERE registrations
   are read from; it must never be used to bypass registration, permission, or
   confirmation authority (Security Central remains the authority boundary;
   registration still happens through the same registration paths inside the
   private instance). Passing a registry context through any public protocol,
   channel, or operator surface is forbidden.
5. **Lane demotion follows isolation, not the reverse.** A file's primary lane
   tag changes only after it provably owns all its global state (registry
   context + owned home/settings + no fixed-name processes); the
   `inventory --check-tags` reconciliation and solo/batch determinism runs are
   the proof.

## Consequences

- Serial-lane files whose only global dependency is the registries become
  convertible to `pure_async` (v1.0.2 M3 converts the first wave; the
  remainder burns down on the Test Suite Speed & Isolation track).
- The five documented residue failures lose their shared root cause; new
  registry-dependent tests have a sanctioned isolated pattern from day one.
- A small, permanent API tax: registry-reading functions carry an `opts`
  parameter and new readers must propagate it. This is the accepted cost of a
  concurrent suite.
- No production behavior change; no new authority; ADR 0015/0031 untouched.

## Validation

- v1.0.2 M2: compile `--warnings-as-errors`, Credo strict, Dialyzer, the
  `release.v1` freeze sweep, and all existing suites green with zero
  production call-site changes; one proof-test converted to the private-registry
  pattern.
- v1.0.2 M3: converted files green solo, in-batch, and full-lane;
  `inventory --check-tags` reconciles; timings recorded against the M0
  baseline.
