# ADR 0098: Kernel Application, Pack Contract, And Tier Model

## Status

Proposed (v1.4). Binding on `docs/plans/v1.4-plan.md` M1, M5, M7, M8, M9, M12,
and M16, and on every release that adds capability code after v1.4.

Sourced from `docs/plans/archives/overall-allbert-kernel-redo-analysis.md`
(archived 2026-08-06 once this ADR made its decisions binding), accepted by
operator decision 2026-08-06. That document is analysis; this ADR is the
decision. Where they disagree, this ADR wins — and they do disagree in two
places, recorded in Consequences.

Amends **ADR 0017** (plugin contract) and **ADR 0031** (settings schema
fragments and authority). Supersedes neither. Carries the re-baselined public
contract freeze that replaces the v1.0 inventory (see §6).

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

### 1. Two categories only: the kernel, or a named pack

`apps/allbert_kernel` is an umbrella application. Every other capability is a
pack — also an umbrella application, `apps/allbert_<name>`.

There is no middle tier. An `allbert_core` beside `allbert_kernel` is two names
for one idea and becomes the drawer everything lands in, reconstructing the
monolith with an extra hop.

### 2. The invariant is compile-enforced, not linted

**The kernel must not depend on any pack.** Sibling dependencies in an umbrella
are declared (`in_umbrella: true`), so a violation is a build failure rather
than a review finding. This is the whole reason umbrella applications were
chosen over separate repositories, which remain available later and are not
foreclosed.

Pack-to-pack dependencies are **permitted**. Only kernel-to-pack is forbidden.

### 3. Relocation, not greenfield — and module names do not change

Module names are independent of application names on the BEAM, so
`AllbertAssist.Security` moves without renaming.

**A relocation that changes a module's content is not a relocation.** v1.4 M8
requires zero content diff on any relocated module: a pure `git mv` plus a
dependency declaration. This makes the largest structural change in the project
mechanically verifiable rather than review-dependent.

### 4. The kernel holds no list of what exists

Discovery is `Application.loaded_applications/0` plus a pack-module lookup. The
kernel holds no registry list, no `@shipped_modules`, no
`@reserved_app_owners`; the release manifest holds what ships, which is correct
rather than a compromise — the license generator already requires knowing
exactly what ships.

**Registry inversion is a provable no-op and must be executed as one.** 246
action modules already `use AllbertAssist.Action` and 248 already declare
`exposure:`; the kernel's list duplicates metadata that already exists
per-module, and `registry.ex` records the duplication in a comment about keeping
`agent_modules/0` in agreement with capability exposure. The method is therefore:
derive, **assert the derived set equals the current list element-for-element**,
then delete the list. A divergence is a latent bug found before shipping — and
v1.3's first authoritative release attempt was stopped by exactly that class,
"registry listed a destructive action as agent-exposed", caught only after 1,384
tests. This decision retires that class structurally.

### 5. Packs own their settings; the kernel ships only its own keys

Settings Central owns the layered *resolver*, provenance, validation, migration
runner, and secret vault. It does **not** own the schema. A pack declaring a
settings key must not require editing a kernel file. This inverts ADR 0031's
mechanism without changing its intent, and preserves every key name and
semantic.

### 6. Tier tokens name the capability axis

`:kernel` / `:native` / `:declared` — what a tier may contribute, not where it
came from. Provenance becomes orthogonal metadata, so an operator may author a
`:native` pack and a vendor a `:declared` one.

Rejected: `:project` (collides with Mix and the umbrella), `:core` (collides
with kernel), `:extension` (vacuous), `:layer1` (opaque).

`<ALLBERT_HOME>/plugins` becomes `packs` for the `:declared` tier, with
`plugins` retained as a compatibility scan path.

### 7. The public contract freeze re-baselines at v1.4

v1.0's tiered inventory describes a structure this release replaces. The new
inventory is taken at **v1.4 closeout**, from the release's final shape, and
supersedes v1.0's from v1.5 onward.

Until closeout the v1.0 freeze remains **enforced as a regression signal, not a
veto**: a milestone that genuinely needs to break a v1.0 contract records the
decision and proceeds. Retiring it at the start would leave the largest
mechanical change in the project's history with no contract regression check at
all, which is the opposite of what a re-baseline is for.

ADR 0081's Tier-2-to-Tier-1 promotion process carries forward unchanged and
applies to the new tiers.

### 8. Gate inversion precedes relocation

Gate definitions name test paths under `apps/allbert_assist/test/`, and umbrella
applications own their own tests, so relocating a module relocates its test and
breaks every gate list naming it. The order is inversion first, relocation
second — v1.4 M7 before M8, without exception.

## Consequences

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

Two of the source analysis's recommendations were **overridden** by the
2026-08-06 operator decision, and this ADR records the override rather than the
proposal:

- The foundation work **merges into the spine release** rather than becoming its
  own. Param-contract enforcement, envelope consolidation, and registry
  inversion share the same ~285 action modules, and the sweep must be paid once.
- **Relocation is not deferred.** Deferring it was proposed on risk grounds and
  rejected, because the next two releases would then build in the monolith.

The `plugins/` directory retires as each becomes `apps/allbert_<name>`. Data
staging moves to each application's `priv/`, which OTP releases handle natively,
removing the custom `stage_plugins` release step.

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
its call sites are in packs, so it is a cross-pack migration.

**Leaving the boundary as documentation.** This is the status quo, and it is what
produced four hand-maintained kernel lists, a fifth found late, and a
coupling-repayment ladder. A boundary a compiler does not check is a boundary
that regrows.
