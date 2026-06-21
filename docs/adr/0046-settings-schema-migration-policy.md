# ADR 0046: Settings Central Schema Migration Policy

## Status

Proposed (draft begins during v0.45 Marketplace Lite because marketplace adds
new settings fragments). Accepted at v0.59 Hardening + Export/Import + Final
RC where the migration tool ships.

### v0.45 vs v0.59 split

v0.45 adopts the **`schema_version` field convention only**: every new
plugin-owned or feature-owned settings fragment declares
`<namespace>.schema_version: <integer>` (always `1` at v0.45). The
field validates at the fragment schema layer and is read-only.

- v0.44 retroactively shipped `workflows.schema_version: 1` (at
  `schema.ex:1077, :2245`).
- v0.45 ships `marketplace.schema_version: 1` as the first new
  fragment to adopt the convention from M1.

v0.59 ships the **runtime migration tool** + bump semantics +
fail-closed handling for unknown schema versions at boot. The ADR
flips to Accepted then.

## Context

Through v0.37, Settings Central has accumulated schema fragments across many
releases (v0.02 base, v0.05 security, v0.06 skill-write, v0.07 confirmations,
v0.08 execution, v0.10 external/package/online-import, v0.13 jobs, v0.15 apps,
v0.16 channels, v0.21 memory, v0.24 objectives, v0.26 workspace, v0.31
settings-fragment substrate, v0.32 panels/zones, v0.34 launcher, v0.35
theming, v0.36 sandbox, v0.37 dynamic codegen, v0.38 templated creation).

v0.31 introduced `AllbertAssist.Settings.Fragment` so per-app and per-plugin
schema declarations could be registered into the central schema. But the
fragment substrate does not include a policy for:

- how to evolve a fragment's schema between releases without breaking
  installed Allbert Homes;
- how to deprecate a key without operators discovering the deprecation only
  when their settings stop working;
- how to remove or rename a key safely;
- how to migrate operator settings across breaking changes.

The v0.39-v1.0 arc adds ~12 more settings fragments (onboarding, providers,
mcp, integrations, browser, channels, plan/build, marketplace, self-
improvement, voice, vision, mcp-server). Without a policy, each release risks
silently breaking operator settings.

The v1.0 acceptance matrix (per `docs/plans/roadmap.md`) requires
disposable-home export/import on a second machine. That requirement implies
a migration policy because export from v0.40 + import on v0.59 must work.

## Decision

Settings Central schema fragments adopt the following migration policy:

### 1. Per-fragment schema_version integer

Every registered settings fragment declares an integer `schema_version`.
v0.31 substrate is `schema_version: 1` for all existing fragments. The v0.38
template fragment (`templates.create.enabled`, `templates.allowed_patterns`)
also enters this policy at `schema_version: 1`. New fragment schema changes
increment the version.

```elixir
defmodule Allbert.Settings.Fragment.Mcp do
  use AllbertAssist.Settings.Fragment
  schema_version 1
  # ... keys ...
end
```

### 2. Additive-only between minor releases

Between two minor releases (e.g., v0.40 → v0.42), schema fragments MAY add
keys (with safe defaults) but MUST NOT:

- rename existing keys;
- remove existing keys;
- change the type of an existing key;
- change the default of an existing key in a way that alters runtime
  behavior;
- change the safety floor of an existing permission key.

Additive changes do not bump `schema_version`.

### 3. Deprecation window

Removals and renames require a deprecation cycle:

- The release that introduces the deprecation marks the key with `@deprecated
  reason` metadata AND ships a `schema_version` bump for the fragment.
- The release boots with both the deprecated key and the replacement key
  active. The deprecated key emits a one-time per-boot operator warning in
  `mix allbert.settings doctor` output.
- The **next** minor release removes the deprecated key. The migration tool
  rewrites operator-set values from the deprecated key into the replacement
  key as part of the migration step.

Operators thus get one full minor-release cycle of warnings before a key
disappears.

### 4. Migration tool

`mix allbert.settings.migrate`:

- inspects each fragment's current `schema_version` against the operator's
  stored settings;
- enumerates pending migrations as `{fragment_id, from_version, to_version}`
  triples;
- shows the operator a redacted preview of what each migration will do;
- requires explicit confirmation per migration (or `--all` for batch);
- writes migrated settings back through registered settings actions (so
  audit/trace path is preserved);
- records each migration in a new `<ALLBERT_HOME>/audit/settings_migrations/`
  audit log with timestamps, fragment id, from_version, to_version, and
  affected key list.

Pending migrations are also surfaced in `mix allbert.security status` and the
workspace Settings panel so operators see them on boot, not only when they
remember to run the migration command.

### 5. Migration steps are explicit Elixir modules

Each `{fragment_id, from_version, to_version}` migration step is an explicit
module:

```elixir
defmodule Allbert.Settings.Migrations.Mcp.V1ToV2 do
  use AllbertAssist.Settings.Migration
  fragment :mcp
  from_version 1
  to_version 2
  def migrate(settings), do: # ...
end
```

Migration modules are reviewed code, not LLM-authored or operator-authored
config. They live under `lib/allbert_assist/settings/migrations/`.

### 6. Export/import preserves schema_version

v0.59 export/import preserves each fragment's `schema_version` so a profile
exported from v0.43 and imported on v0.59 is correctly identified as needing
migrations and runs through `mix allbert.settings.migrate` before the second
machine accepts the profile.

### 7. v1.0 freeze: schema shape, not schema content

Per `docs/plans/v1.0-plan.md`, the v1.0 Tier 1 freeze covers the **Settings
Central schema shape** (the fragment substrate, registration contract,
migration policy) but not the **schema content** (individual keys). Post-1.0
releases continue to add keys (additive-only) and may deprecate keys with the
one-release warning cycle.

## Consequences

- Operators upgrading across multiple minor releases see a coherent pending-
  migration list rather than mysterious settings failures.
- Plugin and app authors who register settings fragments inherit the
  deprecation policy automatically.
- The migration audit trail is operator-inspectable and exports cleanly.
- v0.59 export/import has a binding contract for what schema_version metadata
  to include.
- v1.0 contract freeze covers the migration policy itself, not the
  ever-evolving key list.

## Non-Goals

- No automatic migration on boot. Migrations require operator confirmation.
- No LLM-authored migration steps.
- No silent removal of operator-set values.
- No cross-fragment migration coordination beyond independent per-fragment
  steps (cross-fragment is left for a future ADR if it becomes necessary).
- No migration of secrets store contents (secrets remain in the encrypted
  secret store with its own migration policy under `<ALLBERT_HOME>/secrets/`).

## Implementation Timing

- **v0.45 Marketplace Lite**: draft ADR 0046 begins because marketplace
  introduces new fragment keys and is a good test case for the policy.
- **v0.47-v0.58 milestones**: each new fragment SHOULD declare
  `schema_version: 1` and add deprecation metadata for any key changes per
  this policy (even if the migration tool does not yet exist).
- **v0.59 Hardening**: ADR 0046 accepted; `mix allbert.settings.migrate`
  implemented; export/import preserves `schema_version`; doctor shows pending
  migrations.
- **v1.0**: migration policy frozen as Tier 1 contract; individual keys
  continue to evolve under the additive-only rule.
