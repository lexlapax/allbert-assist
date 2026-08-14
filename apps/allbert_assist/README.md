# allbert_assist

The **transitional residual**. Everything that was Allbert before v1.4 and has
not yet been extracted into the kernel or a named pack.

## Contract

- Pack id: `allbert_assist`, `capability_tier: :native`, `registry_order: 100`
- Catalog `startup_role`: `native_effectful`
- Pack descriptor: `AllbertAssist.Pack.Residual`
  (`lib/allbert_assist/pack/residual.ex`)
- Settings: 44 `FragmentOwner` modules under
  `AllbertAssist.Settings.FragmentOwners.*`
- Kernel contracts answered: 11, listed in `Residual.kernel_contracts/0`

## What "residual" means, and what it forbids

ADR 0098 allows exactly two steady-state capability categories: the kernel, or a
named pack. This application is neither a third category nor a second kernel —
it is **treated as a native pack** for dependency and contribution purposes, and
that is the whole of its status.

The consequence is a rule, not a description:

> It may receive compatibility fixes required to preserve frozen behavior, but
> **no new capability may choose it as its architectural home.**

Its closeout inventory is an extraction queue for later named packs, and its
`registry_order: 100` reserves the slot immediately after the kernel so that
extractions can be numbered outward from it (notes_files `200`, telegram `300`,
… stocksage `1400`) without renumbering anything.

Do not read the `AllbertAssist.` module prefix as ownership by this
application. Module names are independent of application names on the BEAM,
which is exactly what let v1.4 relocate `AllbertAssist.Security` into
`allbert_kernel` and `AllbertAssist.Runtime.Attach.TUISession` into
`allbert_tui` without renaming either.

## Dependency direction

This application depends on `allbert_kernel` and **nothing else in the
umbrella**. That single edge is the point: it is a pack like any other, and it
is compile-enforced by `in_umbrella: true`.

**The kernel must not depend on any pack** — including this one. A violating
edge is a build failure rather than a review finding, which is the reason
umbrella applications were chosen over separate repositories.

Every named pack depends on this application, and `allbert_composition` depends
on it too. Nothing here may depend back on a pack: a residual-to-pack edge is
the specific illegal shape that shaped several v1.4 milestones, including why
telegram, email and the other channels had to take their CLI surfaces with
them, and why `Attach.Server` and `TUIProtocol` could not follow the rest of the
TUI out (see `apps/allbert_tui/README.md`).

## What is in it

Roughly 1,000 modules under `lib/allbert_assist/`. The largest concerns:

- **Runtime and turn handling** — `runtime.ex`, `session/`, `conversations/`,
  `execution/`, `intent/`, `agents/`, and the `AllbertAssist.JidoBacked`
  substrate.
- **Objectives** — `objectives/`, the durable objective runtime for multi-step
  and cross-turn work. `AllbertAssist.Objectives` is the public lifecycle facade
  for list/get/frame/advance/cancel/continue; all effectful objective steps
  still execute through registered actions, Security Central, resource posture,
  and durable confirmations.
- **Actions and authority glue** — `actions/`, `approval/`, `resources/`, and
  `confirmations/`. Confirmation records live under
  `<ALLBERT_HOME>/confirmations` with `pending/`, `resolved/` and `audit/`
  children; approval and denial are registered actions through
  `AllbertAssist.Actions.Runner.run/3`, and approval re-checks Security Central.
- **Workspace** — `workspace/`. `AllbertAssist.Workspace` is the public facade
  for per-thread canvas tiles, per-thread ephemeral surfaces, signed runtime
  Fragments, browser/offline reconciliation, and internal AG-UI semantic
  mappings. Workspace mutations use the same registered action, Security
  Central, Settings Central, trace, and Allbert Home boundaries as the rest of
  the runtime.
- **Settings, memory, skills, jobs, models** — `settings/`, `memory/`,
  `skills/`, `jobs/`, `models/`, each with its own store and public facade.
- **Channel and plugin substrate** — `channels/`, `plugin/`, `extensions/`.
  This is where the registries and adapters that every extracted pack registers
  *through* still live.
- **CLI** — `cli/`. `AllbertAssist.CLI` owns command classification and
  rendering; `allbert_composition`'s `ProductCLI` delegates downward into it
  rather than the other way around.
- **Pack seam** — `pack/`. `Pack.Residual` is the descriptor;
  `Pack.ResidualEffectSupervisor` and `Pack.Contracts.*` are how this
  application answers the kernel's sealed contracts and hosts plugin-contributed
  children.
- **Release and gate tooling** — `dev_gates/`, `licenses.ex`, plus
  `priv/licenses/catalog.json`, the sealed component manifest whose `pack` rows
  are the authority for every pack's id, `registry_order` and `startup_role`.

## How it starts, and how it is discovered

`mix.exs` names `mod: {AllbertAssist.Application, []}`. That supervisor starts
the shared substrate eagerly — `Phoenix.PubSub`, the Jido signal bus, the task
supervisor, the process and objective registries, projections — and then an
`AllbertAssist.Pack.ActivationGate` whose effect children
(`residual_effect_children/0`, hosted by
`AllbertAssist.Pack.ResidualEffectSupervisor`) stay dormant until the
composition coordinator opens the readiness barrier. That is what
`native_effectful` means, and it is also where `AllbertAssist.Plugin.ChildSupervisor`
lives, so plugin-contributed children from the passive packs start there too.

The descriptor is discovered through the generated `.app` specification's
`env: [allbert_pack: AllbertAssist.Pack.Residual]` entry, reconciled against the
sealed component row in `priv/licenses/catalog.json`. Unlike the named packs
this application ships no `priv/allbert_plugin.json`: it is not a plugin, it is
what the plugins were extracted *from*.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` §1 — the
  residual's status as a transitional native pack, and the rule against
  choosing it as a home.
- `apps/allbert_kernel/README.md` — the one application this one depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel and
  packs into one running product.
- `docs/developer/how-to-create-an-allbert-app.md` — app/surface authoring.
