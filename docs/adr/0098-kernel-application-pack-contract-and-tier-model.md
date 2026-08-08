# ADR 0098: Kernel Application, Pack Contract, And Tier Model

## Status

Accepted for implementation by operator decision 2026-08-06. Binding on
`docs/plans/v1.4-plan.md` M1, M5, M7, **M7.1**, M8, M9, M12, and M16, and on
every release that adds capability code after v1.4. M7.1 was added to this list
on 2026-08-06: it is the milestone that makes §2's kernel-must-not-depend-on-a-
pack invariant enforceable, proving dependency closure by compile and xref
before any file moves, so binding every other kernel milestone while omitting it
would leave the central invariant unbound. Closeout evidence records the
implemented inventory; it does not reopen the decisions in this ADR.

Implementation sequencing clarification (2026-08-06): M1.a creates the minimal
kernel/composition OTP application shells required to realize §§1–4 and freezes
Pack behavior before the action sweep. M8 later populates that existing kernel
with only the R2-frozen relocation targets. This is the original ownership
decision made executable, not a new tier or scope change.

The v1.4 M0 admission audit found no eligible ADR 0046 consumer, and the
operator selected migration option A on 2026-08-06. Consequently v1.4 realizes
no maintenance projection or runtime migration machinery. The additive
`settings_migrations/0` seam remains reserved, empty, and inert; a future
qualifying carrier must bind its own maintenance topology before use.

Sourced from `docs/plans/archives/overall-allbert-kernel-redo-analysis.md`
(archived 2026-08-06 once this ADR made its decisions binding), accepted by
operator decision 2026-08-06. That document is analysis; this ADR is the
decision. Where they disagree, this ADR wins — and they do disagree in two
places, recorded in Consequences.

Amends **ADR 0017** (plugin contract), **ADR 0031** (settings schema fragments
and authority), and the entry-owner clauses of **ADR 0076** (packaging and
unified CLI); all remain in force outside the stated amendments. Adds application
ownership and pack-contract evidence to the public-contract inventory while
making the v1.4 inventory the successor test authority at release closeout (see
the 2026-08-07 operator amendment in §7).

Related: ADR 0065 (central action param-contract enforcement), ADR 0046
(settings schema migration policy), ADR 0081 (Tier-2 to Tier-1 promotion).

## Context

Allbert's plugin boundary is not a boundary. All 13 directories under
`plugins/` are compiled *into* `allbert_assist` by path injection
(`apps/allbert_assist/mix.exs` lists each plugin's `lib` in `elixirc_paths/1`).
There is no Mix project per plugin, no dependency isolation, no independent
version, and no independent test suite. A plugin is a manifest plus a directory
convention — a real contribution boundary for discovery and metadata, which is
what ADR 0017 promised, but not a compilation, deployment, or blast-radius
boundary.

The consequence is measurable. Adding any capability edits a kernel file,
because four hand-maintained kernel lists are the real architecture:

| Kernel edit-point | Effect |
| --- | --- |
| `Actions.Registry` compile-time alias list | 251 aliases plus two lists; adding a capability edits a kernel file |
| `Settings.Schema` monolith | 463 dotted keys; all settings ownership is central |
| `mix allbert.test` gate task | 43 `release.vNNN` definitions in one 10,117-line module |
| `Runtime` direct subsystem aliases | the fan-in/fan-out loop knows every feature |

A fifth was found later and is the purest instance:
`Plugin.Discovery.@shipped_modules`, a thirteen-entry plugin-id-to-module map.

The settings case deserves precision because the mechanism *looks* solved.
ADR 0031 introduced schema fragments and `Settings.Fragments` does compose them
— but `core_fragments/0` derives fragments by namespace-grouping the central
schema *after the fact*. Genuine external ownership is exercised by exactly one
plugin module, and zero plugin manifests declare a `settings_schema` entry. The
fragment layer is a presentation view over a central schema, not a distribution
of ownership.

**This is not a code-quality problem.** The subsystems are individually well
built. It is a boundary-placement problem, and it regrows every release because
nothing structurally prevents it. The 1.5-through-1.8 ladder was largely a
coupling-repayment schedule before this decision.

The cost is already recorded: v1.0.2 and v1.0.3 were two entire releases spent
on test isolation and suite speed; v1.1 required eight corrective rounds rooted
in resource ownership; v1.3 M9.b burned six authoritative release attempts, none
stopped by a product regression.

## Decision

### 1. Two steady-state capability categories: the kernel, or a named pack

`apps/allbert_kernel` is an OTP application inside the existing Mix umbrella.
Every other capability is a pack — also an OTP application under
`apps/allbert_<name>`.

There is no middle tier. An `allbert_core` beside `allbert_kernel` is two names
for one idea and becomes the drawer everything lands in, reconstructing the
monolith with an extra hop.

v1.4 necessarily has a **transitional residual**: capability code still under
`apps/allbert_assist` after the three proof extractions. The residual is treated
as a native pack for dependency and contribution purposes, not as a second
kernel and not as a third steady-state category. It may receive compatibility
fixes required to preserve frozen behavior, but no new capability may choose it
as its architectural home. Its closeout inventory is an extraction queue for
later named packs.

Composition hosts such as the release and web applications may depend on the
kernel and packs to assemble a product, but they do not thereby become a third
capability tier. v1.4 realizes this role as descriptorless
`allbert_composition`, owner of `AllbertAssist.Pack.CompositionCoordinator`,
`AllbertAssist.Pack.ProductBootstrap`, and
`AllbertAssist.Pack.ProductCLI`. ProductCLI owns only source/packaged entry
orchestration—attach-first selection and fail-closed composition bootstrap—and
delegates command classification and rendering downward through the residual
`AllbertAssist.CLI` plan contract. Neither the kernel nor residual depends
upward on composition. These modules assemble the product; they contribute no
domain capability or Pack descriptor. Domain behavior placed in them or any
other composition host still violates this decision.

### 2. The invariant is compile-enforced, not linted

**The kernel must not depend on any pack.** Sibling dependencies in an umbrella
are declared (`in_umbrella: true`), so a violation is a build failure rather
than a review finding. This is the whole reason umbrella applications were
chosen over separate repositories, which remain available later and are not
foreclosed.

Pack-to-pack dependencies are **permitted**, but must be explicit and acyclic.
Only kernel-to-pack is forbidden; a composition host may depend downward on
both.

### 3. Dependency closure first, then pure relocation

Module names are independent of application names on the BEAM, so
`AllbertAssist.Security` moves without renaming.

The modules selected for `allbert_kernel` currently have direct and transitive
references into `allbert_assist`. A pure move cannot begin while any such edge
would make the kernel depend on the residual pack. v1.4 therefore has a serial
precondition before M8:

1. generate the compile/xref dependency closure for every relocation target,
   including companion protocols, structs, tests, and support modules;
2. classify every outgoing edge as kernel substrate, pack capability, or
   composition-host concern;
3. move a substrate dependency with the target or invert the edge through a
   kernel-owned contract in a separately tested change; and
4. prove `allbert_kernel` compiles and its focused behavior tests pass without a
   dependency on `allbert_assist` or any named pack.

The code-grounded closure includes `AllbertAssist.Actions.Capability`: both the
Registry and Runner depend on that metadata struct, so it moves hash-pure with
the Capability Plane unless an earlier R2-tested kernel-owned inversion removes
both edges. It cannot be left in the residual pack by treating its name as
unrelated to the plane.

That inversion work may change source and therefore is not part of relocation.
**A relocation that changes a relocated module's content is not a relocation.**
Once the dependency-closure gate is green, v1.4 M8 is a pure `git mv` of source
and tests into the M1.a-created kernel plus only move-manifest-approved
dependency/resource deltas. It does not scaffold the application or edit the
Pack files already resident there. Blob equality for moved files and the absence
of kernel-to-pack compile edges are release evidence. The operator decision
keeps relocation in v1.4, with this serial barrier binding.

### 4. Pack identity, discovery, and contribution contract

The kernel holds no registry list, `@shipped_modules`, or
`@reserved_app_owners`. Discovery produces descriptors; the existing central
registries validate and consume their contributions. A pack descriptor is
discovery metadata, never permission or enablement by itself.

#### Compiled native packs

Every descriptor-bearing kernel/native pack is an OTP application and declares
exactly one pack module in the generated `.app` specification's standard `:env` list as
`allbert_pack: Module`. This reserved entry is build metadata, not an
operator-tunable setting. The module uses the `AllbertAssist.Pack` behaviour and
declares a stable canonical string id, owning OTP application, application
version, and capability tier. The loader obtains the existing module atom from
the raw generated `.app` term—not mutable effective application configuration—
and verifies it against the application modules and artifact-sealed Pack
projection. It never creates a module atom from a Home file or manifest string
and never scans arbitrary BEAM modules looking for a callback.

The identity ABI is one required callback, not a loose set of module
attributes:

```elixir
@callback descriptor() :: %AllbertAssist.Pack.Descriptor{
  schema_version: 1,
  id: String.t(),
  application: atom(),
  application_version: String.t(),
  capability_tier: :kernel | :native,
  provenance: %{source: :signed_release, component: String.t()},
  registry_order: non_neg_integer()
}
```

`id` is 1–64 ASCII bytes matching
`\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z`; `application` is the
compile-time atom whose `.app` entry named the module; `application_version`
must equal `.app` `:vsn`; `provenance.component` must equal the artifact-sealed
component-manifest row id; and `registry_order` is a globally unique, owner-carried
stable token. Unknown descriptor keys or schema versions fail closed. The
Descriptor struct and `descriptor/0` shape enter the v1.4 component contract
baseline.

Packaged completeness reuses the existing final-artifact component pipeline
rather than adding a second release manifest. First-party `beam_app` rows in
`apps/allbert_assist/priv/licenses/catalog.json` may carry one strict `pack`
object with exactly `schema_version: 1`, canonical `id`, canonical
`descriptor_module` string, `startup_role` (`kernel_prerequisite`,
`native_passive`, or `native_effectful`), and globally unique
`registry_order`. The final `finalize_license_evidence/1` release step scans the
resolved release closure and raw `.app` files, adds the exact `.app` SHA-256 to
each Pack row, and materializes the projection into
`$RELEASE_ROOT/THIRD-PARTY-MANIFEST.json`. A `pack` field on a non-first-party
or non-`beam_app` row, an unknown Pack key/version/role, a missing descriptor
application, or a Pack-bearing application without exactly one matching row
fails finalization. The outer component inventory retains its existing
best-effort known-component claim; its Pack projection is an exact closed set
for Allbert's descriptor-bearing applications.

For this schema, “first-party” means the catalog row has
`provenance.ecosystem == "allbert"` and the exact Allbert repository identity;
the producer does not infer first-party status from an application-name prefix.

`descriptor_module` is 1–255 ASCII bytes matching
`\AElixir\.[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*\z`; it is retained as a
comparison string only. The materialized Pack object has exactly the five
source keys above plus lowercase-hex `app_sha256`; any additional or missing
key fails. Rows are ordered by `registry_order`, then application string, and
duplicate ids/modules/orders/applications fail before the manifest is written.

Role/tier/lifecycle agreement is exact:

| Pack `startup_role` | Descriptor `capability_tier` | Normalized `.rel` start mode | Readiness behavior |
| --- | --- | --- | --- |
| `kernel_prerequisite` | `:kernel` | `:permanent` | Hosts Registry/Readiness; never subscribes to its own barrier |
| `native_passive` | `:native` | `:permanent` | Starts normally; has no effectful barrier subscriber |
| `native_effectful` | `:native` | `:permanent` | Starts dormant; its effect owner subscribes and activates once |

The validator normalizes an omitted OTP default start mode to `:permanent`.
`:load`, `:none`, `:temporary`, `:transient`, or any other mode is invalid for a
descriptor-bearing application. The mapping is bidirectional: a `:kernel`
descriptor can only be `kernel_prerequisite`, while every `:native` descriptor
is exactly passive or effectful. The `.rel` mode proves release lifecycle, not
whether a native pack owns effects; the source-catalog role and readiness tests
prove that distinction. Composition/support applications have no Pack row and
are classified separately by M0.

That inner manifest is **artifact-sealed**, not independently signed: the
qualified archive, checksums, and cosign bundle bind its bytes. Runtime also
requires exact agreement with the independent OTP record at
`$RELEASE_ROOT/releases/$RELEASE_VSN/allbert.rel` and with the raw packaged
`lib/<application>-<version>/ebin/<application>.app`. The `.rel` supplies
application atoms, versions, and start modes; the `.app` supplies the
application/module atoms, raw `allbert_pack` entry, and bytes whose digest must
match the Pack projection. Manifest strings are compared with string forms of
atoms obtained by consulting those trusted terms and are never atomized.
After `Application.load/1`, any effective `:allbert_pack` environment value
that differs from the raw `.app` value is a forbidden runtime-config override
and fails startup; the coordinator invokes only the raw `.app` module atom.
`descriptor/0` must then agree with all three records.

Source/development/test bootstrap reads the same validated source-catalog Pack
projection and reconciles it with code-path raw `.app` files. A build gate
separately proves the root Mix release application set matches that projection;
Mix project data is never a runtime discovery API. Tests may inject a complete
projection only through the explicit registry test seam. The post-build
`candidate-manifest.json`, qualification manifests, and `SHA256SUMS` are
promotion evidence and never bootstrap runtime discovery.

`Application.loaded_applications/0` is diagnostic, not a completeness source:
OTP returns only application specifications already loaded through the
application controller, whereas release-spec membership is a separate fact.
The artifact-sealed Pack projection therefore enumerates every descriptor-
bearing application and classifies its startup role. The composition
coordinator explicitly calls `Application.load/1` for each expected application
atom obtained from the consulted `.rel` (accepting the already-loaded case),
then validates the raw/effective `:allbert_pack` agreement without starting the
application. The build/package gate reconciles `.rel`, Pack projection, `.app`
files, and component inventory; runtime also rejects an already-loaded Pack
declaration absent from the projection.
Application load order is not composition order. A packaged release with a
missing, unexpected, multiply-declared, or invalid native pack fails its
startup/package check. Tests may inject descriptors only through an explicit
registry test seam, not mutable production application config.

The component manifest remains the packaging, license, and integrity inventory;
it is not copied into a kernel source list. Adding a compiled pack changes its
own application and source-catalog Pack row, not a kernel capability registry.

The kernel-owned pack registry has `collecting` and `finalized` states. v1.4 M0
records the exact acyclic OTP application dependency/start DAG and names the
composition coordinator. Descriptor discovery explicitly loads application
specs named by the reconciled `.rel`/Pack projection and therefore does not require a pack
process to be started, but product readiness requires both a finalized snapshot
and successful start of every required native-pack application. The
`allbert_kernel` descriptor follows the same component-row/`.rel`/raw-`.app`/
`descriptor/0`
validation path, but its already-started application is the prerequisite that
hosts Registry/Readiness rather than a barrier subscriber. Residual
`allbert_assist` and named native packs follow the same descriptor path; passive
packs need no activation subscription, while effectful native children
participate in the Readiness barrier. Composition-host and support applications
declare no Pack descriptor. The coordinator
cannot depend on a pack that depends back on it; extraction stops until such a
cycle is inverted or a different acyclic coordinator is chosen.

Central registries and effectful pack consumers cannot report ready before that
barrier. A pack may start registry-independent local supervision while
collection is open, but it does not activate transports, jobs, provider calls,
or other effects until the finalized/started signal. A missing start, late
native registration, or descriptor/start-DAG mismatch is a startup failure and
requires a controlled restart; it cannot mutate a live catalog ad hoc. Home-pack
install, enable, or disable uses the existing confirmed extension lifecycle to
validate a complete candidate snapshot and swap it atomically, preserving the
same collision and ordering rules.

The kernel-owned `AllbertAssist.Pack.Readiness` is the generic barrier; it does
not contain a shipped-pack list. An effectful pack child starts dormant and
subscribes with its validated pack id after its application supervisor is up.
The coordinator finalizes a descriptor snapshot, starts/verifies the expected
applications in the frozen DAG, then opens the barrier with that snapshot's
digest and expected pack ids. A subscriber receives at most one activation per
barrier epoch; a subscriber arriving during the bounded opening handshake is
included deterministically. Until then it performs no transport, job, provider,
or other effect. M0 froze these behavioral requirements and restart invariant;
M1.a3 freezes the exact call/message/ACK shape, timeout, diagnostics, and
supervision protocol before implementation. Product readiness follows only
after every required gate acknowledges successful activation. Timeout, NACK,
required-subscriber loss, or coordinator/barrier failure keeps or returns
product readiness false and stops/restarts the affected composition/effect
subtrees; it never lets a dormant child infer readiness. Tests prove one-shot
activation per epoch, subscription during opening, acknowledged readiness,
timeout/NACK/loss handling, coordinator restart before and after readiness, zero
collecting-phase effects, only rostered authorizing-boot effects, and zero
surviving effect processes after post-open loss.
Kernel-owned `AllbertAssist.Pack.EffectGuard` validates the exact barrier-pid/
snapshot-digest token at public and steady-state effect boundaries through the
sole public `:allbert_pack_epoch` context/option key. The separate internal
`AllbertAssist.Pack.ActivationContext` is accepted only at generated,
roster-proven boot-completion callsites. Generic kernel
`AllbertAssist.Pack.ActivationGuard` contains no shipped ids or callsite list and
validates only the exact live `:authorizing` pack/gate/barrier/reference/digest
tuple held by Readiness; ACK atomically revokes it. The carrier is rejected at
every public boundary. Surfaces and residual steady-state code carry the ready
token downward; they do not infer readiness or depend on Web admission state.
Both guards are liveness only and never grant Security authority.

The v1.0 freeze forbids turning a missing v1.4 carrier into a ready-phase break
at an existing public facade. Generated compatibility rows therefore preserve
the frozen `AllbertAssist.Actions.Runner.run/3`, its retained pre-v1.4 default-
argument `/2` export, and `AllbertAssist.Runtime.submit_user_input/1`: with no
carrier the owning facade admits one
already-ready epoch and revalidates exactly that epoch at the final boundary,
without starting composition or substituting a replacement epoch. New and
first-party surface paths carry their original admitted epoch; the compatibility
path is not a way for stale E1 work to join E2.

No maintenance exception ships in v1.4. A future carrier that satisfies ADR
0046's admission rule must separately bind a closed maintenance topology; Pack
metadata alone cannot create one or bypass the product readiness barrier.

The snapshot owner is a plain GenServer: it owns bounded lifecycle state and
atomic snapshot replacement, with no model reasoning, Skill composition, or
agent succession. Its `@moduledoc` records that substrate choice. Registered
actions remain the effectful operator boundary; the registry process does not
grant permissions or perform pack effects.

#### Declared Home packs

`<ALLBERT_HOME>/packs` contains manifest-driven `:declared` packs. They are
data-only. The frozen schema-version-1 Home normalization retains identity
(`plugin_id`, `name`, `version`, optional `kind`) plus contained top-level
`skill_paths`; it normalizes executable contribution collections to empty.
They cannot load BEAM code, introduce a new effect, add a supervision child,
define a store or migration, execute a script, or grant a permission. Parsing a
manifest does not enable it; existing trust, enablement, confirmation, and
Security Central rules still apply.

v1.4 deliberately reuses the frozen `allbert_plugin.json` schema and existing
Plugin manifest validator on the new scan root; it does not invent a parallel
`allbert_pack.json` grammar. For a Home source, presence of top-level `module`
or non-empty/non-list `contributions.apps|actions|channels|children` rejects the
manifest. Empty forms normalize away. Other unknown top-level or contribution
keys—including prompt, surface, migration, store, job, script, or callback-like
names—retain the frozen validator behavior: they are ignored/inert, never
resolved into atoms/callbacks, and never become a contribution. Tests prove
both rejection and inert-ignore cases. Supporting any such field later is an
additive evolution of the frozen Plugin contract, not a v1.4 interpretation.

`<ALLBERT_HOME>/plugins` remains a compatibility scan path under §9. Neither
filesystem traversal order nor map iteration order is observable composition
order.

#### Contribution callbacks

All contribution callbacks return inert module references or validated
descriptors and default to an empty list. The standard additive callback set is:

| Callback | Contribution authority |
| --- | --- |
| `apps/0` | frozen `AllbertAssist.App.Registry` contract |
| `actions/0` | `AllbertAssist.Actions.Registry` and Runner |
| `settings_fragments/0` | Settings Central fragment resolver |
| `settings_migrations/0` | reserved ADR 0046 seam; empty and inert in v1.4 |
| `channels/0` | channel registry and delivery runtime |
| `surfaces/0` | ADR 0030 extension/surface registry |
| `skill_roots/0` | skill registry and its trust policy |
| `jobs/0` | the sole Jobs scheduling engine |
| `stores/0` | registered store/projection contracts |
| `home_roots/0` | Paths/Portability typed relative-root and durability policy |
| `prompt_rules/0` | typed prompt-envelope composition |
| `intent_descriptors/0` | intent descriptor registry |
| `cli_groups/0` | public CLI composition registry |
| `release_assets/0` | release staging, license, and integrity inventory |
| `test_lanes/0` | generated test-gate composition |

A gate-owner contribution is a stable record, not a raw path list. It includes
one owner identity, OTP application, execution CWD, production/test/support
roots, allowed primary lanes, aggregate policy, target resolver, and historical
metrics aliases. Owner composition rejects duplicate identities, duplicate or
unowned targets, incompatible lane policy, and roots outside the declared
application. Completeness is reconciled against an independent filesystem and
application census; it is never inferred solely from the contributions being
checked.

A compiled pack owns and supervises its own OTP children; the kernel does not
start arbitrary pack child specs returned as metadata. Adding a future optional
callback is an additive change to this behaviour. Removing one or changing its
meaning follows the public stability rules in §7.

v1.4 wires and proves every callback consumed by the three extracted packs and
the gate/settings/action inversions. `settings_migrations/0` returns empty and
admits no action, runner, or boot behavior. A callback reserved for a later
release may return empty, but future code must use the named contribution seam
instead of adding another kernel list.

Every contribution still enters its existing authority boundary: actions
resolve through `Actions.Registry` and execute through `Actions.Runner.run/3`;
settings write through Settings Central; channels remain adapters; jobs remain
Jobs-owned; and Security Central plus confirmations remain authoritative. Pack
identity, provenance, tier, installation, or enablement never grants authority.

`home_roots/0` descriptors contain a canonical id, a confined relative path,
durability class, and backup/export/rebuild policy. Paths and Portability reject
absolute paths, traversal, duplicate roots, and conflicting policies before
publication. The descriptor makes a path discoverable; it does not grant read,
write, Resource Access, or action authority.

#### Deterministic order and collisions

Composition preserves the established source lanes: kernel/residual/native
contributions form the static/native lane, legacy plugin and declared-pack
adapters use their existing extension lane, and the validated dynamic overlay
retains its explicitly documented final precedence.

Every action in an existing observable Registry order carries a unique stable
global `registry_order` token in its action metadata. M0 freezes the pre-change
module-to-token mapping from the current global sequence and proves that sorting
by the tokens reproduces it element-for-element before any list is deleted. The
token belongs to the action descriptor, not the kernel or its current pack, so a
pure extraction moves it with the unchanged module. A released token is
immutable. New actions receive the next unused token through checked release
tooling; a missing or duplicate token is a Registry assembly failure.

Any other contribution kind with an already-observable global order uses the
same owner-carried stable-order-token rule in its descriptor or compatibility
adapter. Only surfaces with no existing ordering contract use deterministic
configured scan-root precedence followed by canonical pack id and canonical
contribution id. Callback return order, application load order, filesystem
traversal order, and map iteration order are never global ordering fallbacks.
v1.4 records before/after fixtures for every ordered Registry surface.

Pack ids, native application owners, stable order tokens, and contribution
identities are unique.
Duplicate settings keys always fail fragment composition. Duplicate action ids,
module ownership, channel ids, surface ids, job ids, store ids, or other
canonical contribution ids never resolve by last-writer-wins. A shipped native
collision is a release and boot failure. An invalid Home/legacy pack is rejected
as a unit and reported to the operator without activating any of its
contributions. An explicit deprecated compatibility alias may collapse to the
same implementation only when its adapter proves identical authority metadata
and records the alias; it cannot shadow a different contribution. Existing
validated dynamic-overlay replacement semantics remain governed by their own
registry contract rather than being generalized into pack precedence.

**Registry inversion is a provable no-op and must be executed as one.** Action
modules already carry their capability metadata, while the current lists
duplicate it. v1.4 derives the catalog, compares membership, exposure,
capability metadata, resolution, collisions, diagnostics, and every frozen
ordered observation with the pre-inversion Registry, then deletes the kernel
list. A divergence is a latent bug to resolve before proceeding, not a new
precedence rule.

### 5. Packs own their settings; the kernel ships only its own keys

Settings Central owns the layered *resolver*, provenance, validation,
schema-version/additive-only and future migration-policy authority, and secret
vault. It does **not** own the schema. A pack declaring a
settings key must not require editing a kernel file. This inverts ADR 0031's
mechanism without changing its intent, and preserves every key name and
semantic.

The pack's `settings_fragments/0` callback returns complete, first-class ADR
0031 fragments with stable ids, owners, versions, schemas, defaults, safe-write
keys, and metadata. `settings_migrations/0` returns only reviewed ADR 0046
per-fragment steps in a future qualifying carrier; it returns empty throughout
v1.4. Settings Central composes fragments deterministically and rejects a
duplicate fragment id, conflicting ownership claim, or duplicate key before any
consumer starts.

Moving an existing fragment into a pack preserves its fragment id, key names,
schema version, defaults, validation, secrecy, safety floor, and stored values.
Application ownership alone is not a data migration and cannot manufacture a
version bump. Any simultaneous non-additive schema change is a separate ADR
0046 migration with independent evidence.

Installed native-pack fragments remain discoverable to Settings Central even
when the pack's effectful features are disabled, so existing operator data stays
interpretable and the pack can be configured or re-enabled. Enablement controls
consumers, not schema visibility. A data-only declared pack may bind or present
already-registered settings but cannot introduce a new executable validator,
secret backend, schema migration, or permission key.

`AllbertAssist.Settings.Schema` remains the public compatibility facade over the
composed resolver. Callers do not branch on application ownership, and no pack
writes its store directly.

### 6. Tier tokens name the capability axis

`:kernel` / `:native` / `:declared` form the **capability axis**: what a
contribution may contain, not who wrote it or how stable its public API is.

- `:kernel` is compiled substrate inside `allbert_kernel`.
- `:native` is compiled code in a named pack (including the v1.4 residual).
- `:declared` is validated data-only composition from Allbert Home.

Provenance and trust are orthogonal metadata, so an operator may author a
`:native` pack and a vendor may publish a `:declared` pack without changing what
either tier can do. None of the three tokens grants permission.

Public **stability tiers** are a separate axis: Tier 1 and Tier 2 continue to
mean the compatibility obligations in the public-contract freeze. A `:native`
capability may expose a Tier-1 contract, a Tier-2 contract, or no public contract
at all. ADR 0081 governs promotion from stability Tier 2 to stability Tier 1; it
does not promote `:declared` to `:native` or `:native` to `:kernel`.

Rejected: `:project` (collides with Mix and the umbrella), `:core` (collides
with kernel), `:extension` (vacuous), `:layer1` (opaque).

`<ALLBERT_HOME>/packs` is canonical for the `:declared` tier, with `plugins`
retained as a non-destructive compatibility scan path under §9.

### 7. v1.4 succeeds the v1.0 test authority

Operator amendment (2026-08-07): the v1.0 freeze is a migration guard while the
application boundary is built, not the permanent post-v1.4 test architecture.
`mix allbert.test release.v1` remains green through M14 so the re-baseline cannot
hide a regression. M14 then freezes the component/Pack-owned contract inventory,
owner tests, dependency graph, and affected-component selector in
`release.v14`. M16 proves that successor baseline from source and package and,
at accepted release closeout, retires `release.v1` from the default every-change
and release-qualification sequence.

The authority transition is about ownership and test scope. It does not grant a
minor release permission to break observable Tier-1 APIs. Boundary serializers
and compatibility adapters preserve frozen external 1.x names and shapes; an
intentional incompatible public change still requires a major version and ADR.
Internal Tier-2 ownership/topology is re-baselined to the v1.4 component model
rather than carried forever as a monolithic v1.0 test denominator.

v1.4 commits a new **component contract baseline** before R4 artifact generation:
it records the owning OTP application, pack id, contribution kind, compatibility
adapter, owner gate, and affected-component edges for the supported contract
set. It contains source ownership/hashes but no self-referential artifact
digests; external release-validation evidence binds its exact source SHA to the
artifact digests/signatures. Relocating a module changes its source/application
owner but not its BEAM module name or public behavior. The baseline supersedes
v1.0 as test authority only after M16 acceptance.

The compiled `AllbertAssist.Pack` descriptor contract enters the public
inventory as Tier 2 at v1.4 and evolves additively. Declared packs reuse the
already-frozen Plugin manifest contract rather than creating a second public
shape. ADR 0081's Tier-2-to-Tier-1 promotion process carries forward unchanged
on the stability axis described in §6.

### 8. Gate inversion precedes relocation

Gate definitions name test paths under `apps/allbert_assist/test/`, and umbrella
applications own their own tests, so relocating a module relocates its test and
breaks every gate list naming it. The order is inversion first, relocation
second — v1.4 M7 before M8, without exception. The §3 dependency-closure gate is
also green before the pure move begins. Before inversion, M7.0 reconciles an
independent repository census with owner discovery, manifest rows, primary
lanes, and aggregate coverage. After inversion the same independent proof
requires every target to have one owner and execute exactly once; a generated
owner list cannot validate itself.

### 9. Legacy Plugin/App contracts bridge into packs

ADR 0017's compiled Plugin behaviour, plugin ids, enablement settings, manifest
shape, scan roots, provenance, and public Registry observations remain frozen.
v1.4 does not replace them with a second registry. A compatibility adapter
translates each residual compiled plugin contribution into the common pack and
ADR 0030 extension registries while preserving its existing identity, source
lane, enablement, diagnostics, and authority metadata.

When a compiled plugin is extracted into `apps/allbert_<name>`, its native pack
descriptor becomes the contribution owner. Any retained legacy manifest is an
explicit deprecated alias to that same descriptor, not a second registration.
The adapter must prove identical contribution identity and authority metadata
before deduplicating it. Otherwise the collision rules in §4 apply.

For operator data, `<ALLBERT_HOME>/packs` is the canonical new scan root and
`<ALLBERT_HOME>/plugins` continues to be read. Allbert does not move, rewrite,
or delete either tree automatically. If both roots declare the same canonical
pack id, the loader does not silently pick a winner: it rejects the duplicate
pack as a unit, reports both paths, and asks the operator to resolve it.

Extracted native packs stage data from their OTP application's `priv/` tree.
The custom `stage_plugins` path remains, narrowed to the residual legacy-plugin
inventory, until the last such directory has moved and packaged artifact,
license, relocation, and compatibility checks prove parity. Three proof
extractions do not by themselves authorize deleting the compatibility stage.

## Consequences

The M0 implementation audit froze `allbert_composition` as the descriptorless
coordinator host and completed M7.0 at clean SHA `1739a4028`: 652 test files and
4,627 manifest rows reconcile with zero unclassified or double-counted files.
That pass found and repaired six previously omitted Notes Files/Artifacts test
files before any module relocation. The durable M0 ledger owner then advances
the live inventory to 653 files/4,633 rows; that is an append-only evidence
delta, not a correction to the clean M7.0 checkpoint. These are implementation
bindings of the accepted decision, not a new capability category or a change to
ADR status.

New capability code has somewhere correct to go, which is the point. The two
releases immediately after v1.4 build new subsystems; without this boundary they
would land in the monolith and need moving later, which is the coupling regrowth
this ADR exists to stop. v1.4 therefore ships **three proven pack extractions**
(`notes_files`, then telegram and email) rather than inversions alone — a
pattern with no worked example is not a pattern.

Compile times do not improve for a pack that depends on `allbert_assist` while
the monolith is still large. The benefit is boundary enforcement and blast
radius, not build speed, and claiming otherwise would oversell it.

`apps/allbert_kernel` lands at roughly 4,700 LOC after v1.4 — concerns 1, 3, and
4 of the analysis's seven — against an eventual 20,000–25,000 target. That is
expected: this release creates the boundary, not the whole kernel. Turn Engine
consolidation is the one change that genuinely needs a major and is reserved for
2.0.

The boundary lands in two mechanically distinct stages: M1.a creates the small
application shell and kernel-owned Pack substrate so ownership and dependency
direction are compile-enforced during inversion; M8 adds the remaining concerns
through the R2 hash-pure move manifest. Only the latter bytes participate in the
relocation identity proof.

Two of the source analysis's recommendations were **overridden** by the
2026-08-06 operator decision, and this ADR records the override rather than the
proposal:

- The foundation work **merges into the spine release** rather than becoming its
  own. Param-contract enforcement, envelope consolidation, and registry
  inversion share the same M0-proven 281 action modules, and the sweep must be
  paid once.
- **Relocation is not deferred.** Deferring it was proposed on risk grounds and
  rejected, because the next two releases would then build in the monolith.

The `plugins/` directory retires incrementally as each compiled plugin becomes
`apps/allbert_<name>`. Extracted data moves to each application's `priv/`, which
OTP releases handle natively. The narrowed `stage_plugins` release step remains
for the residual inventory until §9's removal evidence is green.

## Alternatives Considered

**Separate repositories per pack.** Rejected for now, not forever. Umbrella
siblings already give compile-enforced dependency direction, and separate repos
would fragment the shared release, cosign, tap, and license machinery. Nothing
here forecloses them.

**A greenfield kernel.** Rejected: module names are independent of application
names, so relocation costs a `git mv` and greenfield costs a rewrite plus a
freeze violation.

**Optional pack compilation.** Rejected as a requirement. `stage_plugins`
already copies data from every directory under `plugins/`, pack code already
compiles in through `elixirc_paths`, and enablement is runtime settings. The
artifact already ships everything; build-time optionality via path dependencies
remains available if it ever becomes a requirement.

**Deleting `PermissionGate` as a core-only edit.** Rejected on measurement: 7 of
its call sites are in packs, so it is a cross-pack migration. ADR 0031 and ADR
0065 govern the accepted direct-facade retirement and keep it independent of
parameter validation.

**Leaving the boundary as documentation.** This is the status quo, and it is what
produced four hand-maintained kernel lists, a fifth found late, and a
coupling-repayment ladder. A boundary a compiler does not check is a boundary
that regrows.
