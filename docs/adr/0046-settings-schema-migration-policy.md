# ADR 0046: Settings Central Schema Migration Policy

## Status

Proposed (draft begins during v0.45 Marketplace Lite because marketplace adds
new settings fragments). Accepted at v0.59 Hardening (export/import + settings-
migration substrate), where the version contract, additive-only enforcement, the
fail-closed boot check, and export/import version preservation ship. **Re-scoped
2026-06-29 (v0.59 readiness review):** v0.59 ships the *version contract and
enforcement substrate*, not a runtime migration-runner engine — see "v0.59 scope
vs deferred" below. (The v0.59 RC label is historical; the integrated product RC
moved to v0.63 in the 1.0 rescope.)

### v0.45 vs v0.59 split

v0.45 adopts the **`schema_version` convention only**: every new plugin-owned or
feature-owned settings fragment declares `<namespace>.schema_version: <integer>`
(always `1` at v0.45) as a read-only schema row. v0.59 ships the rest of the
substrate (a first-class per-fragment version, additive-only enforcement, a
fail-closed boot check, and export/import version preservation) and defers the
runtime migration runner.

## Current Code State (verified 2026-06-29)

This ADR was originally written as if every fragment already carried a version;
it does not. The true state v0.59 builds on:

- `AllbertAssist.Settings.Fragment`
  (`apps/allbert_assist/lib/allbert_assist/settings/fragment.ex`) has **no
  `schema_version` field** — its struct is `id, owner, source, group, schema,
  defaults, safe_write_keys, metadata`. A fragment cannot "declare" a version
  today.
- `schema_version` exists only as an ordinary **schema row**, and only for a
  subset of registered namespaces. The static core list includes
  `model_preferences, mcp_server, openai_api, public_protocol, surface_policy,
  acp_server, workflows, voice, vision, image, artifacts, marketplace,
  self_improvement`; plugin/app fragments such as `research.schema_version` may
  also declare row-style versions. v0.59 must generate the exact inventory from
  `AllbertAssist.Settings.Fragments.registered_fragments/0` instead of trusting
  a prose count.
- There is **no `Settings.Migration` behaviour/DSL, no `migrations/` directory,
  no `mix allbert.settings.migrate` task, and no `mix allbert.settings doctor`
  subcommand**. They are greenfield.

The example below (`marketplace`) is one of the 13 namespaces that *does* carry a
`schema_version` row today and has live version checking in
`marketplace/doctor.ex`.

## Context

Through v0.58, Settings Central has accumulated schema fragments across many
releases. The fragment substrate (v0.31) does not include a policy for evolving a
fragment's schema between releases without breaking installed Allbert Homes,
deprecating a key visibly, removing/renaming a key safely, or migrating operator
settings across breaking changes.

The v1.0 acceptance matrix requires disposable-home export/import on a second
machine: an export from an older Allbert imported on a newer one must work, which
implies — at minimum — a version contract so the importing machine can identify
whether stored settings predate the current schema.

## Decision

Settings Central adopts the following migration policy. v0.59 ships the version
contract and enforcement; the runtime migration runner is deferred (below).

### 1. First-class per-fragment `schema_version`

v0.59 adds `schema_version` as a **first-class field on
`AllbertAssist.Settings.Fragment`** (default `1`) and **backfills every currently
registered fragment/namespace to `1`**, replacing the inconsistent schema-row
approach. The release gate generates and checks the exact fragment inventory. An
un-versioned stored fragment (no version present) is treated as version `1`. New
fragment schema changes increment the version.

(If a registration DSL is later introduced, a `schema_version N` macro can wrap
this field; v0.59 sets the field directly on the fragment struct — no new DSL is
required to ship the contract.)

### 2. Additive-only between minor releases

Between two minor releases, schema fragments MAY add keys (with safe defaults) but
MUST NOT rename existing keys, remove existing keys, change a key's type, change a
key's default in a way that alters runtime behavior, or change the safety floor of
a permission key. Additive changes do **not** bump `schema_version`. v0.59 ships a
check (extending the existing settings-bypass Credo/CI posture or a dedicated
schema-diff test) that flags a non-additive change that did not bump the version.

### 3. Deprecation window

Removals and renames require a deprecation cycle: the introducing release marks
the key `@deprecated reason` AND bumps the fragment `schema_version`; it boots
with both the deprecated and replacement keys active and surfaces a one-time
per-boot operator warning; the **next** minor release removes the deprecated key,
and the migration step (when the runner exists) rewrites stored values from the
deprecated key into the replacement. Until the runner ships (deferred), the
rewrite is a documented manual step.

### 4. Fail-closed boot check (ships in v0.59)

On boot, Settings Central compares each fragment's stored `schema_version` against
the known maximum and **fails closed on an unknown/forward version** (stored
version > known): it surfaces an operator-visible diagnostic (through the settings
doctor surface and `mix allbert.security status`) rather than silently loading
settings it cannot interpret. A stored version *behind* the known version is
recorded as a pending migration (see the deferred runner).

### 5. Runtime migration runner — DEFERRED until a real migration exists

The `mix allbert.settings.migrate` runner, the `Settings.Migration` behaviour/DSL,
the `migrations/` registry, and the automated deprecated→replacement rewrite are
**deferred**, because: the policy is additive-only between minors (so cross-minor
data migration is rare by construction), and there are **zero pending migrations
today** (every namespace is at version `1`). Building a runner engine before any
release needs it is premature. The runner ships with the **first real non-additive
migration**; until then, the version contract (§1), additive enforcement (§2), the
boot check (§4), and a **documented manual migration procedure** are sufficient,
and are what the v1.0 freeze actually requires.

When the runner does ship, it follows the original design: `{fragment_id,
from_version, to_version}` steps as reviewed Elixir modules under
`lib/allbert_assist/settings/migrations/`, redacted preview, per-migration
confirmation (or `--all`), writes back through registered settings actions, and an
audit log under `<ALLBERT_HOME>/audit/settings_migrations/`.

### 6. Export/import preserves `schema_version` (ships in v0.59)

v0.59 export/import preserves each fragment's `schema_version` so a profile
exported from an older Allbert and imported on a newer one is correctly identified
as current, pending-migration, or unknown/forward (fail-closed) by the boot check.

### 7. v1.0 freeze: the version contract, not a runner

The v1.0 Tier 1 freeze covers the **Settings Central schema *shape*** — the
fragment substrate, the registration contract, the `schema_version` field, and
the additive-only + deprecation-window policy — but not the **schema content**
(individual keys). It does **not** require the deferred runner. The v1.0 plan's
Tier-1 list names this version/additive contract explicitly.

## Consequences

- The importing machine can always identify whether stored settings predate the
  current schema; unknown/forward versions fail closed instead of corrupting
  state.
- Plugin and app authors who register fragments inherit the additive-only +
  deprecation policy automatically.
- v0.59 export/import has a binding contract for the version metadata to include.
- v1.0 freezes a real, small contract (version field + additive-only policy)
  rather than an engine that does not yet have anything to run.

## Non-Goals

- No automatic migration on boot. (When the runner exists, migrations require
  operator confirmation.)
- No LLM-authored migration steps.
- No silent removal of operator-set values.
- No cross-fragment migration coordination beyond independent per-fragment steps.
- **No migration of secrets store contents.** Secrets remain in the encrypted
  Settings Central secret store, currently
  `<ALLBERT_HOME>/settings/secrets.yml.enc`, with its own migration policy. Note
  that v0.61's plaintext/encrypted-credentials → OS-secret-vault move is a
  separate operator migration **outside** this ADR's scope.

## Implementation Timing

- **v0.45 Marketplace Lite**: draft begins; `marketplace.schema_version: 1`
  adopts the convention as a schema row.
- **v0.47-v0.58**: each new fragment SHOULD declare `schema_version: 1` (as a
  schema row, since the first-class field does not exist yet).
- **v0.59 Hardening**: ADR 0046 accepted; first-class fragment `schema_version`
  field + 43-namespace backfill; additive-only enforcement; fail-closed boot
  check; export/import version preservation; documented manual migration path. The
  runtime runner is deferred.
- **First real non-additive migration (post-v0.59)**: the `mix
  allbert.settings.migrate` runner + `Settings.Migration` DSL + `migrations/`
  registry ship.
- **v1.0**: the version/additive-only contract is frozen as Tier 1; individual
  keys continue to evolve under the additive-only rule.
