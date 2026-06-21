# ADR 0043: Marketplace Lite Trust Tier

## Status

Accepted for v0.45 Marketplace Lite (`docs/plans/v0.45-plan.md`).
M1 implements the substrate vocabulary, settings fragment, URI
scheme, and locked decisions that make this decision binding for
implementation. M6 closeout reconfirms the shipped state and records
release evidence; it does not re-open the decision.

## Context

Allbert needs reviewed skill and template discovery before 1.0. The
existing skill surface (`AllbertAssist.Skills.Registry` from v0.03,
`:online_skill_import` from v0.10, `Skill.Parser` from v0.03) supports
local + import-from-URL skills but does not provide a curated catalog
operators can browse, install per-version, verify by hash, and
rollback.

A full marketplace with arbitrary remote code-bearing plugin install
(npm, vsix, browser extension web store, etc.) requires:

- a signing scheme operators can verify;
- a dependency resolution model;
- a sandbox for untrusted code execution (beyond ADR 0037's gate
  runner);
- provenance attestations that survive supply-chain attacks
  (SLSA-like);
- rollback semantics for stateful installs;
- governance for who reviews community submissions;
- ecosystem moderation policy;
- abuse / takedown / appeal process.

That's a v1.x+ scope. v0.45 takes a deliberately narrower step:
**Marketplace Lite** ships the data shape and Allbert-author seed
bundles only, parking community submissions and code-bearing remote
install for post-1.0 governance.

## Decision

### Marketplace Lite permits:

- **Reviewed skill discovery and install** into Allbert Home from a
  shipped catalog. Installed skills register through the existing
  v0.03 `Skills.Registry` with `source_scope: :marketplace_install,
  status: :disabled, trust: :untrusted`. The `:marketplace_install`
  value is a new `:source_scope` enum entry added at v0.45 M1
  (sibling of v0.10's `:imported_cache`); the v0.03 substrate gets
  a one-value additive schema change. Enabling and trusting the
  skill is a separate operator action through the existing v0.03 +
  v0.06 paths.
- **Reviewed-source plugin index metadata** (descriptive only). The
  catalog can advertise reviewed plugins by id + repo URL + review
  date, but the marketplace never fetches plugin code, never compiles
  plugin modules, and never installs plugin manifests beyond the
  descriptive entry.
- **Template catalog metadata for `workspace:create`.** The v0.38
  templated-creation registry consumes installed template bundles;
  the marketplace never executes templates.
- **Provenance, hash, version, and rollback metadata.** Per-bundle
  SHA-256 hash; per-entry provenance (scheme + source git commit +
  review date); per-version immutable bundle directories;
  rollback-by-removal.

### Marketplace Lite explicitly does NOT permit:

- Arbitrary remote code-bearing plugin install (parked at "Code-
  Bearing Remote Plugin Distribution" in future-features.md).
- Remote dependency resolution.
- Marketplace-provided permission grants. The
  `:marketplace_install` permission authorizes the install action
  itself (which writes inert state); it does not authorize execution
  of installed bundles.
- Marketplace theme/snippet distribution.
- MCP Apps iframe execution.
- Workflow YAML files installed into `<ALLBERT_HOME>/workflows/`
  (parked at "Remote Workflow Distribution / Marketplace Workflows"
  in future-features.md; forward-pinned in `v0.45-plan.md` §"v0.44
  Workflow Forward-Pin").
- Community-submission governance (parked at "Marketplace Community
  Submission / Review Governance" in future-features.md).
- Bundle signing at v0.45. The `provenance.scheme` field is
  forward-compatible for future signing schemes (e.g., Sigstore,
  in-toto), but v0.45 single-vendor scope makes signing
  unnecessary — the Allbert release itself is the trust anchor.

## Trust Tier Definition

At v0.45, "reviewed" means:

- The bundle was committed to the Allbert source tree
  (`priv/marketplace/bundles/<entry-id>-<version>/`) by an Allbert
  maintainer.
- The maintainer recorded a `provenance.review_date` and the
  source git commit hash in `priv/marketplace/index.json`.
- The bundle ships immutably as part of an Allbert release; updates
  ship with new Allbert releases.

This is a deliberately weak trust tier. It establishes the data
shape and operator-visible surface without committing the project to
a community moderation policy. Operators get a small curated catalog
they can audit by reading `priv/marketplace/`.

Community submissions (parked) would require a stronger trust tier:

- Submission workflow (PR against the source tree, hosted form, or
  dedicated registry).
- Reviewer ownership and rotation policy.
- Provenance and signing requirements distinct from "shipped with
  Allbert."
- A separate trust tier for community-reviewed vs Allbert-author-
  reviewed bundles.

That governance work is post-1.0 per `future-features.md`
"Marketplace Community Submission / Review Governance."

## Provenance Model

`provenance.scheme: "shipped"` at v0.45 means:

- The bundle was committed to the Allbert source tree.
- `provenance.source_git_commit` is the git commit hash of the
  source tree the catalog index was built from.
- `provenance.review_date` is the date the Allbert maintainer
  recorded the bundle as reviewed (ISO-8601).
- No external signature verification is required at v0.45.

The catalog's top-level `source_git_commit` field carries the same
hash, allowing operators to verify catalog integrity by inspecting
the corresponding Allbert release.

Future schemes (forward-compatible via the `provenance.scheme`
enum):

- `"signed"` — Sigstore or in-toto attestation.
- `"community_reviewed"` — community submission with reviewer
  signature.
- `"vendor_published"` — third-party vendor with their own signing
  authority.

These schemes are reserved and inert at v0.45.

## Hash Model

SHA-256 (`:crypto.hash(:sha256, basis)`). Matches v0.42 R9
`AllbertAssist.Tools.Discovery.stable_hash` precedent.

`bundle_hash` is the recursive SHA-256 of bundle contents:

```
sha256(
  sort(files).map(f => f.path + "\0" + sha256(file_content)).join("\n")
)
```

The bundle manifest's `files[].sha256` entries provide per-file
hashes for spot-check without recomputing the whole bundle hash.

Hash verification runs at three points:

- `marketplace_doctor` (full catalog walk).
- `install_marketplace_bundle` (before write).
- `verify_marketplace_bundle_hash` (on-demand, post-install).

Hash mismatch fails closed with a structured `error_category`
diagnostic. No partial install.

### Doctor error_category enum

Per the v0.43 R6 lesson, `marketplace_doctor` and the install /
rollback action failure modes use a documented `error_category`
atom enum. The v0.45 set:

- `:already_installed` — same-id same-version reinstall while the
  entry is installed.
- `:bundle_hash_mismatch` — recursive SHA-256 does not match the
  manifest's `bundle_hash`.
- `:bundle_manifest_invalid` — `bundle.json` parse / shape fails,
  including file-list/hash drift, manifest-entry drift, invalid
  install metadata, and the workflow-YAML forward-pin code
  `:workflow_yaml_forward_pin_violation`.
- `:bundle_manifest_missing` — `bundle.json` is missing.
- `:catalog_entry_not_found` — requested entry/version is absent
  from the shipped catalog.
- `:catalog_invalid` — catalog index JSON parse or shape fails,
  including unknown keys, required-field misses, invalid entry ids,
  unsupported source/kind, duplicate ids, invalid generated_at, and
  custom cache path outside Allbert Home.
- `:catalog_missing` — shipped catalog index file is missing.
- `:catalog_schema_version_unsupported` — catalog `schema_version`
  is not `1`.
- `:catalog_unknown_provenance_scheme` — `provenance.scheme` is not
  in `["shipped"]`.
- `:install_target_exists` — install target already exists before a
  write.
- `:install_target_invalid` — manifest or configured install target
  resolves outside the allowed Allbert Home-rooted marketplace
  boundary.
- `:install_write_failed` — install write failed after validation.
- `:installed_bundle_hash_mismatch` — installed bundle's recursive
  hash has drifted from the manifest's `bundle_hash`.
- `:installed_state_invalid` — `installed.json` parse or shape fails.
- `:marketplace_disabled` — `marketplace.enabled=false` disabled the
  marketplace action before read/write work.
- `:marketplace_schema_version_mismatch` — settings
  `marketplace.schema_version` does not match the expected fragment
  version (preview of ADR 0046's v0.59 runtime migration
  semantics).
- `:marketplace_schema_version_unavailable` — settings
  `marketplace.schema_version` could not be read.
- `:not_installed` — rollback or verify requested an entry that is
  not installed.
- `:orphan_install` — entry in `installed.json` but the
  `install_target` directory is missing.
- `:plugin_index_not_installable` — browse-only plugin index entry
  was sent through install.
- `:rollback_failed` — rollback file/state mutation failed.
- `:template_metadata_invalid` — installed template metadata cannot
  be read or validated.
- `:version_conflict_requires_rollback` — same-id different-version
  install while another version is installed; operator must roll
  back first.
- `:unknown_marketplace_doctor_error` — catch-all for unexpected
  internal failures.

Notable diagnostic `code` values under those categories include
`:installed_state_path_invalid` under `:installed_state_invalid`,
`:unknown_provenance_scheme` under
`:catalog_unknown_provenance_scheme`, and
`:workflow_yaml_forward_pin_violation` under
`:bundle_manifest_invalid`.

Operator + developer docs at M6 mirror this enum.

## Single-Vendor Decision Rationale

v0.45 ships single-vendor (Allbert-author bundles only) because:

- Operators get reviewed discovery value immediately, without
  waiting for governance.
- The data shape (catalog schema, install pipeline, rollback,
  provenance, hash) can land + stabilize before community
  submissions need to consume it.
- Governance debate (who reviews community submissions? how is
  abuse handled? what's the appeal process?) is deferred to a
  separate post-1.0 decision.
- The trust anchor at v0.45 is the Allbert release itself —
  operators trust the Allbert maintainer publication chain, which
  they already trust by running Allbert.

Forward-compatibility: the catalog schema, bundle manifest, URI
scheme (`marketplace://entry/<author>/<name>`), permission class
(`:marketplace_install`), and ADR 0046 schema_version convention
are all designed so community submissions can plug in later
without breaking v0.45 installs.

## URI Identity

`marketplace://entry/<author>/<name>` is added to ADR 0013's initial URI
mappings at v0.45 (see `v0.45-plan.md` §"ADR 0013 amendment").

Per-entry URI provides:

- Stable identity for trace/audit (the URI appears in event
  metadata).
- Reference target for v0.47 self-improvement trace mining.
- Workflow YAML descriptor reference (workflow can advertise "this
  entry is example workflow for `marketplace://entry/foo/bar`" —
  descriptive only).

The URI is not authority. Install authority comes from the
`:marketplace_install` permission, not the URI itself.

## Settings Fragment Convention

`marketplace.*` is the first new settings fragment under the
post-v0.37 planning policy that v0.45 adopts the ADR 0046 draft
`schema_version` convention for. `marketplace.schema_version: 1` is
declared at the fragment schema layer and is read-only at v0.45.

ADR 0046 (Settings Central Schema Migration Policy) drafts the
convention at v0.45 but accepts the migration runner at v0.59. v0.45
only adopts the field convention; the runtime migration semantics
ship with the accepted ADR.

The v0.44 `workflows.schema_version: 1` (at `schema.ex:1077, :2245`)
retroactively follows the same convention.

## Install + Rollback Semantics

Install:

- `install_marketplace_bundle` is `:marketplace_install`-permissioned
  (default `:allowed`, floor `:allowed`). Operators may tighten the
  permission to `:needs_confirmation` or `:denied` through Settings
  Central, but v0.45 does not require a confirmation prompt by
  default because installs write inert disabled/untrusted state.
- Writes bundle files to
  `<ALLBERT_HOME>/marketplace/<kind>/<entry-id>/` for installable
  bundle kinds (`skill` and `template`).
- Updates `<ALLBERT_HOME>/marketplace/installed.json` with
  entry-id + version + installed_at + install_state
  (`"disabled_untrusted"`) + install_target + bundle_hash. The
  update uses the write-temp + rename pattern
  (`installed.json.tmp` → `installed.json`) for atomic persistence
  — same-filesystem rename is POSIX-atomic and survives crashes
  mid-write. Concurrent install / rollback actions serialize on a
  per-Allbert-Home advisory lock to prevent lost updates.
- For skill kind, registers with `Skills.Registry` as
  `source_scope: :marketplace_install, status: :disabled, trust:
  :untrusted`. The `:marketplace_install` value is a new
  `:source_scope` enum entry added at v0.45 M1 (sibling of
  v0.10's `:imported_cache`).
- For template kind, registers with the v0.38 templated-creation
  registry as descriptive metadata.
- For plugin_index kind, install rejects. Plugin index entries are
  catalog metadata only: browseable and inspectable, never installed,
  copied, compiled, or registered as code.
- Hash mismatch fails closed; no partial install (see §"Doctor
  error_category enum" for the failure-mode list).
- **Same-id behavior.** If the same entry-id is already installed
  at the requested version, install rejects with `error_category:
  :already_installed`. If a different version of the same entry-id
  is installed, install rejects with `error_category:
  :version_conflict_requires_rollback` — the operator must roll
  back the existing version before installing the new one.
  Upgrade is a deliberate two-step operator action; v0.45 does not
  ship auto-upgrade because in-place upgrade requires explicit
  state-preservation semantics that are out of scope.

Rollback:

- `rollback_marketplace_install` is `:marketplace_install`-
  permissioned (same authority as install — operators who can
  install can roll back).
- Removes `<ALLBERT_HOME>/marketplace/<kind>/<entry-id>/`
  recursively.
- Updates `installed.json` to remove the entry.
- For skill kind, deregisters from `Skills.Registry`.
- No previous-version restore is required because the shipped
  catalog is always re-installable from `priv/marketplace/`.

If multiple versions of the same entry-id are installed (e.g.,
operator installed v1.0.0 then v1.1.0), rollback removes only the
most recently installed version. Operators re-install if a prior
version is needed.

## Cross-ADR References

- **ADR 0011** (confirmed external capability adapters): v0.10
  online_skill_import precedent for "import + disable" pattern.
- **ADR 0012** (resource access security posture): marketplace
  install operations participate in the resource access posture
  (install writes Allbert Home; no remote fetch).
- **ADR 0013** (URI-first resource identity): v0.45 amendment
  registers `marketplace://entry/<author>/<name>`.
- **ADR 0017** (plugin contract): plugin_index entries reference
  v0.17 plugin descriptor shape; install does not compile plugin
  code.
- **ADR 0031** (settings schema fragments): `marketplace.*`
  fragment composes through the v0.31 substrate, with
  `schema_version: 1` per ADR 0046 draft.
- **ADR 0046** (settings schema migration policy): drafted at v0.45;
  accepted at v0.59. v0.45 adopts the `schema_version` field
  convention only.
- **ADR 0047** (provider doctor contract): `marketplace_doctor`
  follows the ADR 0047 redacted shape (matches v0.40 MCP doctor,
  v0.43 browser doctor, v0.44 plan-build runtime advancement).

## Consequences

Operators can discover reviewed capabilities while Allbert keeps
code authority local, explicit, and reviewable before 1.0. The
marketplace data shape and install pipeline stabilize before
community submissions need them.

ADR 0046 schema_version convention gets its second user
(`marketplace.schema_version: 1` joins v0.44's
`workflows.schema_version: 1`), establishing the field as a stable
convention before v0.59 ships the runtime migration tool.

v0.47 self-improvement gets a stable trace pattern source
(marketplace entries + install state) for trace-to-skill draft
suggestions.

v1.0 freeze gets a catalog data shape that survives without
governance changes; community submissions can be added post-1.0
without breaking v0.45 installs.

## Non-Goals

- No arbitrary remote code-bearing plugin install.
- No dependency resolution from marketplace metadata.
- No marketplace-provided permission grants.
- No marketplace-installed workflow YAML files.
- No bundle signing at v0.45 (forward-compatible field reserved).
- No community submissions in v1.0 (governance parked).
- No automatic skill/template enablement on install.
- No multi-author scope namespace at v0.45 (entries are
  `allbert/*` only; future community submissions can add scopes
  per the entry id pattern).

## Deferred

Tracked in `docs/plans/future-features.md`:

- "Marketplace Community Submission / Review Governance" (post-1.0).
- "Remote Workflow Distribution / Marketplace Workflows"
  (post-1.0; same governance umbrella).
- "Code-Bearing Remote Plugin Distribution" (post-1.0).
- Bundle signing schemes (Sigstore, in-toto) — reserved via
  `provenance.scheme` enum.
- OS-level package manager integration (apt, brew, scoop) — not in
  scope.
- Theme/snippet distribution — parked.
- MCP Apps iframe execution — parked.
- Multi-vendor scope namespace — `<author>/<name>` shape is
  forward-compatible.
