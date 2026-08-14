# allbert_research

The supervised `research.specialist` delegate agent, as a native umbrella pack.

## Contract

- Pack id: `allbert_research`, `capability_tier: :native`, `registry_order: 500`
- Catalog `startup_role`: `native_passive`
- Legacy plugin id: `allbert.research` (`kind: "delegate_agent"`, version
  `0.46.0`)
- Apps: `AllbertResearch.App`
- Actions: **none**
- Settings: the research schema, owned by `AllbertResearch.SettingsFragment`

## Why it exists, and what it deliberately is not

**It registers no new actions and grants no browser authority.** Its commands
orchestrate *existing* actions through `AllbertAssist.Actions.Runner.run/3`, so
every permission check, confirmation, and audit row that governs those actions
still applies unchanged.

That restraint is the design. A delegate agent is a planner over an existing
authority surface, not a second way to reach the network. If research could
navigate directly, the browser pack's consent gate would be bypassable by
delegation.

Before v1.4 this code lived under `plugins/allbert.research/` and was
path-injected into `allbert_assist` through `elixirc_paths/1` — a contribution
boundary, not a compilation one. M13 extracted it into this OTP application.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`) and the residual
(`allbert_assist`), and on no other pack. It also declares `jido` and
`jido_action` directly: those are its own runtime requirement even though the
residual uses them too, because a pack that does not declare what it needs works
only while something else happens to pull it in.

The edge that matters most here is the one that runs the *other* way.
`allbert_browser` depends on **this** pack — `AllbertBrowser.Actions.ResearchHandoff`
calls `AllbertResearch.DelegateObjective` and `AllbertResearch.Runtime` — and
this pack references nothing in `allbert_browser`, which is what keeps the only
pack-to-pack edge in the tree acyclic. Adding any reference from here into
`allbert_browser` would create a cycle and fail the build.

The rule the whole tier model rests on: **the kernel must not depend on any
pack**, and a violating edge is a build failure rather than a review finding.
Pack-to-pack edges are permitted when explicit and acyclic; composition hosts
may depend downward on both.

## What is in it

- `AllbertResearch.Pack` — the pack descriptor, declaring one settings fragment
  and one test-lane owner. Every other contribution callback returns `[]`.
- `AllbertResearch.Plugin`, `AllbertResearch.App` — the ADR 0017 entry point and
  the contributed app. `Plugin.settings_schema/0` returns `[]`; the schema moved
  to the pack `FragmentOwner` in M13, and returning it here as well would
  produce the same fragment id twice and fail composition with
  `:duplicate_settings_fragment_id`. The schema itself did not move —
  `AllbertResearch.Settings.Fragment` is still its only definition.
- `AllbertResearch.Agent`, `AllbertResearch.Runtime`,
  `AllbertResearch.Supervisor` — the supervised delegate agent.
- `AllbertResearch.Commands.Research`,
  `AllbertResearch.Commands.SummarizeUrl` — the agent's commands.
- `AllbertResearch.DelegateObjective` — objective-side delegation, and the
  entry point `allbert_browser` calls.
- `AllbertResearch.SettingsFragment` — the pack `FragmentOwner`.
- `Mix.Tasks.Allbert.Research` (`lib/mix/tasks/allbert.research.ex`) — the
  operator task.

## How it starts, and how it is discovered

The pack is `native_passive`: `mix.exs` declares no `mod:` application callback,
so the application itself starts nothing. `AllbertResearch.Plugin.child_spec/1`
returns `AllbertResearch.Supervisor.child_spec([])`, and the residual's
`AllbertAssist.Plugin.Bootstrap` starts that child under
`AllbertAssist.Plugin.ChildSupervisor` — which is itself hosted by
`AllbertAssist.Pack.ResidualEffectSupervisor`, and therefore only after the
readiness barrier opens.

`allbert_composition` depends on this application, so it is loaded and started
through the normal OTP boot.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertResearch.Pack]` entry, reconciled against the sealed
component row in `apps/allbert_assist/priv/licenses/catalog.json`. The retained
`priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that same
descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_browser/README.md` — the pack that depends on this one.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
