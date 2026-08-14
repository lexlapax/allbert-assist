# allbert_artifacts

Operator browsing surfaces for Artifacts Central, as a native umbrella pack.

## Contract

- Pack id: `allbert_artifacts`, `capability_tier: :native`,
  `registry_order: 1300`
- Catalog `startup_role`: `native_passive`
- Legacy plugin id: `allbert.artifacts` (`kind: "app"`, version `0.50.1`)
- Apps: `AllbertArtifacts.App`
- Actions: none
- Surfaces: `surface_id: "artifacts"`, rendered by
  `AllbertArtifactsWeb.ArtifactLive`

## Why it exists, and what it deliberately is not

Artifacts Central owns artifact storage, permissions, settings, and scheme
authority. This pack owns none of that — it contributes *browsing surfaces* over
what Central already governs. Registration is inert contract data: the pack
grants no access by being present.

Keeping the browser separable from the store is the point. A surface can change,
break, or be removed without touching the authority that decides what an
operator may see.

Before v1.4 this code lived under `plugins/allbert.artifacts/` and was
path-injected into `allbert_assist` through `elixirc_paths/1` — a contribution
boundary, not a compilation one. M13 extracted it into this OTP application.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`), the residual
(`allbert_assist`), and `allbert_assist_web`.

That third edge is the shape worth understanding, and it is why this pack sits
where it does in the DAG. It contributes a routed LiveView, so it must depend on
the application that owns the router — and `allbert_assist_web` in turn depends
on `allbert_composition`. If `allbert_composition` also depended on this pack,
the loop `web -> composition -> pack -> web` would close. So `allbert_artifacts`
is deliberately **absent** from `allbert_composition`'s dependency list, and sits
*above* Web instead: it is started by the root `mix.exs` release `applications:`
list, and its metadata reaches the Pack projection through the application roster
read from `.app` files, which needs no dependency edge. `stocksage` is the only
other application with this shape.

The rule the whole tier model rests on: **the kernel must not depend on any
pack**, and a violating edge is a build failure rather than a review finding.
Pack-to-pack edges are permitted when explicit and acyclic; composition hosts
may depend downward on both.

## What is in it

- `AllbertArtifacts.Pack` — the pack descriptor, declaring one surface and one
  test-lane owner. Every other contribution callback returns `[]`, including
  `settings_fragments/0`: this pack owns no settings.
- `AllbertArtifacts.Plugin` — the ADR 0017 entry point, contributing
  `AllbertArtifacts.App` and nothing else.
- `AllbertArtifacts.App` — the contributed app: a read surface over the core
  artifact actions, contributing no artifact store internals and no new
  authority.
- `AllbertArtifacts.SurfaceProvider`, `AllbertArtifacts.Panels.Browser` —
  workspace surfaces and the panel's fallback text.
- `AllbertArtifactsWeb.ArtifactLive` (`lib/allbert_artifacts_web/`) — the
  LiveView for the web workspace.
- `Mix.Tasks.Allbert.Artifacts` (`lib/mix/tasks/allbert.artifacts.ex`) — the
  operator task.

## How it starts, and how it is discovered

The pack is `native_passive`: `mix.exs` declares no `mod:` application callback,
`AllbertArtifacts.Plugin` contributes no `child_spec/1`, and the pack starts no
processes at all. It is loaded and started from the release `applications:` list
described above, and everything it contributes is registration data rendered on
demand.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertArtifacts.Pack]` entry, reconciled against the
sealed component row in `apps/allbert_assist/priv/licenses/catalog.json`. The
retained `priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that
same descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/stocksage/README.md` — the only other pack that sits above Web.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
