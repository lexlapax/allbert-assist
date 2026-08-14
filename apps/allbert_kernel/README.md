# allbert_kernel

The kernel tier. One OTP application inside the umbrella, holding the contracts
and mechanisms every capability depends on — and nothing that is itself a
capability.

## Why this exists

Before v1.4 the architecture was four hand-maintained lists inside
`allbert_assist`. Adding any capability meant editing a kernel file: an alias
list of 251 entries, a registry table, a settings roster. That is not a boundary,
it is a bottleneck with a compile step.

ADR 0098 replaced it with two steady-state categories and no middle tier: this
kernel, and named packs under `apps/allbert_<name>`. There is deliberately no
`allbert_core` beside it — that becomes the drawer everything lands in and
rebuilds the monolith with an extra hop.

## The invariant

**The kernel must not depend on any pack.** This is compile-enforced, not
reviewed: umbrella siblings are declared with `in_umbrella: true`, so an edge
from here into a pack is a build failure. That enforcement is the reason the
umbrella was chosen over separate repositories, which remain open later.

Pack-to-pack dependencies are permitted when explicit and acyclic. Only
kernel-to-pack is forbidden. A composition host may depend downward on both.

`mix.exs` therefore declares exactly four external libraries, each admitted by
the M7.1 closure ledger from a real call or struct match rather than discovered
after the fact: `exqlite` for the single-writer lock, `jason` for external
request encoding, and `jido_action` / `jido_signal` for the Capability Plane
contracts.

## What is in it

Roughly 66 modules under `lib/allbert_assist/`, in these groups:

- **`pack/`** — the Pack contract itself: `Registry`, `Readiness`, `Descriptor`,
  `EffectGuard`, `ActivationGuard`, `Projection`, `RowSchemas`, `Canonical`.
  This is the machinery a pack is declared and admitted through.
- **`kernel/contract*`** — the sealed contract catalog. A closed set of named
  contracts bound atomically to a finalized Registry generation and a Readiness
  barrier, failing closed on a missing, duplicate, malformed, stale, or lost
  binding.
- **`security*`**, **`actions/`**, **`action.ex`** — the authority surface and
  action contract that every capability is checked against.
- **`paths.ex`**, **`config_context.ex`**, **`registry_context.ex`**,
  **`validation.ex`**, **`maps.ex`** — shared context and validation primitives.
- **`external/`**, **`runtime/`** — outbound request and runtime seams.

Module names are independent of application names on the BEAM, which is why
`AllbertAssist.Security` lives here without being renamed. Do not read the
`AllbertAssist.` prefix as ownership by `apps/allbert_assist`.

## How it starts

`AllbertKernel.Application` supervises two children `:one_for_one`:

- `AllbertAssist.Kernel.Contract.Owner` — holds the sealed contract binding.
- `AllbertAssist.Pack.Supervisor` — the Pack supervision epoch.

The contract owner is a **sibling** of the Pack epoch rather than a child of it.
It is already coupled to that epoch by the monitor it holds on the readiness
barrier — a Registry or Readiness restart kills the barrier and the owner
releases its binding — so it does not also need to share the restart group.
Keeping it outside also lets a test start an isolated `Pack.Supervisor` without
colliding on the one globally named owner.

The application declares `env: [allbert_pack: AllbertAssist.Pack.Kernel]`, which
is how it is discovered as a pack-declaring application.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model, the invariant, and the sequencing this application realizes.
- `apps/allbert_composition/README.md` — the host that assembles kernel and
  packs into a running product.
