# allbert_composition

The composition host. It assembles the kernel and the packs into one running
product, and owns nothing that a capability would want to call.

## Why this exists

ADR 0098 allows exactly two steady-state capability categories — the kernel, or
a named pack. A host that depends on both to build a product is **not** a third
tier, and this application exists to make that distinction structural rather
than stated: it is **descriptorless**. It declares no Pack descriptor, so it can
never be mistaken for a capability, and nothing can contribute through it.

Its dependency direction is the opposite of the kernel's. It depends on
`allbert_kernel` *and* `allbert_assist`, which is exactly what a host is allowed
to do and exactly what the kernel is forbidden to do.

## What is in it

- **`AllbertAssist.Pack.CompositionCoordinator`** — composes the product. It
  awaits both bootstraps, takes a snapshot of the app and plugin registries,
  builds a candidate, binds the readiness epoch, finalizes the Pack registry,
  binds the kernel contracts, and opens readiness.
- **`AllbertAssist.Pack.CandidateBuilder`** (plus `candidate_builder/`) — turns
  registry metadata into the candidate: action assembly, channel rows, metadata
  rows, row families, test-lane rows, compatibility evidence.
- **`AllbertAssist.Pack.ProductBootstrap`** and **`ProductCli`** — product entry
  points.
- **`AllbertComposition.GateOwnerManifest`** — declared via
  `env: [allbert_gate_owner_manifests: ...]`, so the gate discovers this
  application's owned test lanes without a kernel-side list.

## How it starts, and why it restarts

`AllbertComposition.Application` supervises one child, the coordinator, with
**`max_restarts: 50` in 5 seconds** rather than OTP's default of 3.

That is load-bearing and worth understanding before changing it. Under ADR 0098
a controlled restart *is* the coordinator's designed response to a metadata
generation changing beneath it, and any app or plugin registration changes one.
The default intensity therefore makes the designed response fatal: a fourth
registration inside the window ends the application permanently, readiness never
reopens, and every later action fails closed with `:product_not_ready`. That was
measured directly, not inferred.

Two consequences a caller should know:

- Composition is not instant. A registry change closes readiness while the
  catalog recomposes, and reopening is dominated by the behaviour-digest
  computation. Code that mutates a registry and then immediately performs an
  effect must expect `:product_not_ready` in between.
- The coordinator reads the app and plugin registries in sequence. A
  registration landing between those two reads yields a torn pair, which
  `build_candidate/4` reports as `:metadata_generation_moved` rather than as a
  false verdict about the candidate's contents.

## Testing

`mix test` in this application runs `allbert.ecto.migrate` first, guarded by an
application-env flag so the migration happens once per test run rather than per
invocation.

## Related

- `docs/adr/0098-kernel-application-pack-contract-tier-model.md` §1 — composition
  hosts are not a capability tier.
- `apps/allbert_kernel/README.md` — the contracts this host binds.
