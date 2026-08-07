# ADR 0046: Settings Central Schema Migration Policy

## Status

Accepted at v0.59 Hardening (export/import + settings-
migration substrate), where the version contract, additive-only enforcement, the
fail-closed boot check, and export/import version preservation ship. **Re-scoped
2026-06-29 (v0.59 readiness review):** v0.59 ships the *version contract and
enforcement substrate*, not a runtime migration-runner engine — see "v0.59 scope
vs deferred" below. (The v0.59 RC label is historical; the integrated product RC
moved to v0.64 in the 1.0 rescope.) The ADR was originally proposed during
v0.45 Marketplace Lite because Marketplace added new settings fragments.

**v1.4 amendment (operator decision 2026-08-06):** v1.4 admits the deferred
runner only as a paired unit with at least one proven, real non-additive
per-fragment migration. The admission remains conditional: if no legitimate
consumer satisfies this ADR, the release does not fabricate one merely to ship
the engine. The runner remains explicit and operator-confirmed; boot never
applies or rolls back a migration automatically. This amendment fixes the
locking, preimage, atomicity, audit, interruption, and recovery contract below.

**v1.4 admission result (operator decision 2026-08-06):** M0 found no eligible
consumer. Telegram/email changes preserve stored identity; the two proposed
intent destinations cross fragment ownership without a qualifying versioned
deprecation edge; all production fragments remain at version 1; and the sole
annotation-only deprecated Memory key has no scheduled replacement. The
operator selected option A: v1.4 ships no runner, migration actions, journal,
preimage, or maintenance projection. The future safety contract below remains
Accepted but deferred until a qualifying carrier has a real consumer.

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
  no `mix allbert.settings.migrate` task, and no generic `mix allbert.settings
  doctor` subcommand**. They are greenfield — though `mix allbert.settings
  model-doctor` + `Settings.ModelDoctor`/`Settings.DoctorDiagnostics` already exist
  as the precedent the new settings-doctor read surface should extend.

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

**v1.3 annotation-only clarification (2026-07-30).** A preserved compatibility
key may acquire `deprecated?: true` plus a non-empty `deprecation_reason`
without a fragment-version bump only when those two annotations are the entire
schema diff, the stored key remains readable/writable with the identical type,
default, validation, and safety floor, its behavior is already inert, and no
removal or replacement is scheduled by that change. This makes an existing
no-authority contract visible without fabricating a data migration. Changing or
removing either annotation later is non-additive; any future key removal still
requires the ordinary versioned deprecation/migration path above.

### 4. Fail-closed boot check (ships in v0.59)

On boot, Settings Central compares each fragment's stored `schema_version` against
the known maximum and **fails closed on an unknown/forward version** (stored
version > known): it surfaces an operator-visible diagnostic (through the settings
doctor surface and `mix allbert.security status`) rather than silently loading
settings it cannot interpret. A stored version *behind* the known version is
recorded as a pending migration (see the deferred runner).

### 5. Runtime migration runner — admitted only with a real migration

The `Settings.Migration` behaviour, migration registry, and explicit runner may
ship only with the first real non-additive consumer. A fragment ownership
move, metadata-only version bump, annotation-only deprecation, still-readable
compatibility alias, empty migration, or fixture used only by tests does not
satisfy that entry condition. The consumer must independently satisfy §2 and
§3; runner demand does not shorten the deprecation window.

The release evidence identifies the affected fragment and keys, the deprecation
history, the exact `from_version` and `to_version`, why persisted data must
change, and successful forward and rollback runs over operator-authored values.
If the inventory finds no qualifying consumer, the runner remains deferred and
the active plan returns to the operator for scope disposition rather than
inventing an intent-key or application-ownership migration.

v1.4 exercised that admission rule, found no qualifying consumer, and records
the approved deferral above. The remainder of §5 is the binding contract for a
future qualifying carrier; it does not describe shipped v1.4 behavior.

#### Step identity and planning

- A reviewed Elixir migration module declares one `{fragment_id, from_version,
  to_version}` edge. Edges are contiguous, have one unambiguous successor, and
  cannot span fragments. The registry rejects gaps, forks, duplicate edges, an
  unknown fragment, and a target newer than the registered fragment schema.
- The runner computes a plan independently for each stored fragment. A stored
  version ahead of the running release remains the §4 fail-closed case. `--all`
  confirms a sequence of independent fragment plans; it does not turn them into
  an undeclared cross-fragment transaction.
- Preview is the default first phase. It names each step and affected keys and
  shows a redacted before/after summary. It never prints a secret or an
  unredacted operator value. Preview is read-only: it computes the plan,
  prospective transform, and persisted-state digest in memory and creates no
  journal, preimage, audit, or other durable file.

#### Explicit invocation and boot behavior

- In the first qualifying carrier, `allbert admin settings migrate` is the packaged operator surface. A source
  Mix task, if retained, dispatches the same registered action and runner rather
  than implementing a second path.
- The runner is a deterministic Settings service invoked by registered Jido
  actions, not a Jido.Agent. Durable truth lives in the journal and protected
  preimage, never process memory. If a supervised process is required to own
  in-node lock/snapshot state, it is a plain GenServer and its `@moduledoc`
  records why the pragmatic substrate rule selects it.
- Every forward or rollback operation requires an explicit operator invocation
  and confirmation for the displayed plan; `--all` is bulk confirmation for
  that displayed plan only. Model output, pack metadata, and boot state cannot
  provide confirmation.
- Normal boot may detect and report a pending or interrupted migration, but it
  never invokes the runner. A fragment whose old representation cannot be
  interpreted safely fails closed and identifies the explicit recovery command.
  The administrative command starts through a minimal migration mode that can
  resolve Allbert Home, Settings Central, Security Central, the migration
  registry, and audit storage without starting consumers of the affected
  settings. That future carrier must bind a closed maintenance topology before
  implementation: only migration status/plan/apply/resume/rollback plus named
  dependencies may resolve, execution still uses `Actions.Runner.run/3`, and
  product readiness remains false. It is not a second executor or a permission
  bypass. ADR 0098 supplies no such v1.4 maintenance projection.

#### Lock, preimage, and atomic commit

- Before preview becomes an apply operation, the runner acquires the Settings
  Central migration lock for the exact Allbert Home. The lock excludes normal
  settings writes, a second runner, and service startup that would consume a
  required-pending fragment. After acquiring it, the runner re-reads fragment
  versions and the persisted-state digest; a stale preview is rejected and must
  be regenerated.
- After the confirmed apply has rechecked the preview under the lock, it
  transforms and validates an in-memory copy and computes the expected
  postimage digest. Before atomic replacement, the runner stages and fsyncs a
  restricted preimage of every affected persisted value plus the fragment
  version/state digest and a `prepared` record that references that integrity-
  tagged preimage and includes the expected postimage digest. It atomically
  publishes them as one write-ahead bundle; an unpublished staging residue is
  not journal state and grants no recovery authority.
  The preimage is recovery data, not audit output: it is never rendered in CLI,
  trace, or audit text and receives at least the same filesystem protection as
  the settings it preserves. Secret-store contents remain out of scope.
- The step transforms a copy, validates the complete target fragment against the
  target schema, and commits the affected values and fragment version as one
  Settings Central atomic operation. Migration modules never write the store
  directly. Failure before commit leaves the original state and version intact;
  failure after commit is handled from the durable journal and preimage.
- `--all` commits one fragment step at a time. A failure stops the sequence; a
  completed earlier step remains a completed, auditable step and is not silently
  rolled back as part of a cross-fragment transaction.

#### Journal, audit, and recovery

- The durable journal records a monotonic state machine for each attempt:
  `prepared -> applied -> verified -> complete`; an explicit rollback from an
  eligible `prepared` state or an applied/verified/complete postimage transitions
  to `recovery_required -> rolled_back`. It includes migration identity, versions, state digests,
  timestamps, actor/provenance, an idempotency/attempt id, and the preimage
  reference, never raw values. `complete` and `rolled_back` are written only
  after their corresponding redacted audit entry is durably present.
- Every journal transition and preimage manifest carries a domain-separated
  integrity tag from the existing per-Home integrity secret. A checksum detects
  accidental byte drift; the integrity tag prevents modified recovery metadata
  from being treated as trusted state. A missing or invalid tag is the hard-stop
  case below and never grants recovery authority.
- After atomic commit, the runner records `applied`, re-reads and validates the
  target fragment, records `verified`, and idempotently appends the redacted
  operator audit record under its existing `<ALLBERT_HOME>/settings/audit/`
  authority before recording `complete`. The restricted journal and preimages are separate recovery state
  under `<ALLBERT_HOME>/settings/migrations/`; they never use the audit log as a
  recovery store.
- On interruption, boot reports the exact journal state and fails closed for the
  affected fragment. It does not auto-resume and does not auto-rollback. An
  explicit resume first compares the persisted digest with both journaled
  digests. A `prepared` record with current bytes equal to the preimage may
  recompute the deterministic transform and apply only if it matches the
  expected postimage digest; a `prepared` record with current bytes already
  equal to the expected postimage advances to `applied` without transforming
  again. An `applied` state verifies, and a `verified` state idempotently
  appends/confirms audit before completing. Any other digest is refused.
  Explicit rollback first records `recovery_required` and converges to the exact
  protected preimage. From `prepared` with current bytes equal to the preimage,
  it performs no Settings write, verifies the original bytes/version, audits an
  idempotent `no_commit_to_restore` outcome, and records `rolled_back`. From
  `prepared` with current bytes equal to the expected postimage, or from an
  applied, verified, or complete postimage, it atomically restores and verifies
  the preimage/prior fragment version, audits, and records `rolled_back` without
  forcing a resume first. Neither digest is a hard stop. A repeated rollback
  from `recovery_required` resumes by digest; a repeated rollback from
  `rolled_back` returns the terminal result without another write or audit.
- A journal or preimage that is missing, malformed, mismatched, or not writable
  is a hard stop. The runner never guesses, skips the step, or advances the
  stored version.
- Downgrade requires explicit rollback by the newer binary before the older
  binary is started. The older binary never interprets a newer fragment or
  guesses an inverse migration. The first qualifying carrier's acceptance
  starts with a real packaged predecessor Home clone, migrates it with the new
  carrier, rolls it back with that carrier, and proves the packaged predecessor
  can read the restored Home.
- Backup/restore preserves the restricted journal and preimages whenever a
  migration is prepared, recoverable, or still inside the release rollback
  window. The qualifying carrier performs no automatic preimage pruning. A later explicit,
  confirmed prune may remove only terminal records that are no longer needed
  for supported rollback and must retain the redacted operator audit.

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
- v1.4 applied the admission rule, found no real non-additive consumer, and
  leaves the runner deferred. A future qualifying carrier must prove the
  explicit recovery contract end to end without making boot a write authority.

## Non-Goals

- No automatic migration, resume, or rollback on boot. Migrations require an
  explicit operator command and confirmation.
- No LLM-authored migration steps.
- No silent removal of operator-set values.
- No cross-fragment migration coordination beyond independent per-fragment steps.
- **No migration of secrets store contents.** Secrets remain in the encrypted
  Settings Central secret store, currently
  `<ALLBERT_HOME>/settings/secrets.yml.enc`, with its own migration policy. Note
  that v0.62's plaintext/encrypted-credentials → OS-secret-vault move is a
  separate operator migration **outside** this ADR's scope.

## Implementation Timing

- **v0.45 Marketplace Lite**: draft begins; `marketplace.schema_version: 1`
  adopts the convention as a schema row.
- **v0.47-v0.58**: each new fragment SHOULD declare `schema_version: 1` (as a
  schema row, since the first-class field does not exist yet).
- **v0.59 Hardening**: ADR 0046 accepted; first-class fragment `schema_version`
  field + backfill of every registered fragment (inventory from
  `registered_fragments/0`); additive-only enforcement; fail-closed boot check;
  export/import version preservation; documented manual migration path. The
  runtime runner is deferred.
- **v1.4**: admission inventory found no real non-additive consumer; the operator
  approved deferral, so the runtime runner and all recovery machinery remain
  unimplemented.
- **First future qualifying carrier, unslotted**: only with a real consumer, the
  packaged `allbert admin settings migrate` surface + `Settings.Migration`
  contract + registry, locking, atomic commit, journal, audit, and explicit
  recovery ship together.
- **v1.0**: the version/additive-only contract is frozen as Tier 1; individual
  keys continue to evolve under the additive-only rule.

## Relates To

- Refines: ADR 0031 (settings fragments and Settings Central authority).
- Constrains: ADR 0098 pack-owned fragments. Application ownership moves do not
  qualify as schema migrations, and pack-contributed steps use this runner and
  recovery contract.
