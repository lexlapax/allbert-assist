# allbert_browser

The supervised browser session runtime and its registered actions, as a native
umbrella pack.

## Contract

- Pack id: `allbert_browser`, `capability_tier: :native`, `registry_order: 600`
- Catalog `startup_role`: `native_passive`
- Legacy plugin id: `allbert.browser` (`kind: "app"`, version `0.43.0`)
- Apps: `AllbertBrowser.App`
- Actions: thirteen, from `AllbertBrowser.Actions.Doctor` and `StartSession`
  through `Navigate`, `Extract`, `Screenshot`, `AnalyzeScreenshot`, `Click`,
  `Fill`, `Download`, `ListSessions`, `CloseSession`, `SweepCache`, to
  `ResearchHandoff`
- Settings: the `browser.*` schema, owned by `AllbertBrowser.SettingsFragment`
- Surfaces: workspace surfaces through `AllbertBrowser.SurfaceProvider`

## Why it exists

Driving a real browser is the single most dangerous capability in the product:
it reaches the network, renders untrusted content, and holds state across turns.
Isolating it behind its own application with its own settings schema, navigation
policy, and network policy means the blast radius is inspectable in one place.

Operational control runs through the reviewed Playwright/Chromium bridge staged
from `priv/playwright_bridge`. Deterministic release tests bind the **stub
driver** instead, so the gate never depends on a live browser.

Before v1.4 this code lived under `plugins/allbert.browser/` and was
path-injected into `allbert_assist` through `elixirc_paths/1` — a contribution
boundary, not a compilation one. M13 extracted it into this OTP application.

## Authority

Consent is gated up front and navigation grants are durable and reviewable. The
pack does not grant network authority by being registered: every action still
resolves through `AllbertAssist.Actions.Registry` and executes through
`AllbertAssist.Actions.Runner.run/3`, under Security Central and confirmations.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`), the residual
(`allbert_assist`), and **one other pack: `allbert_research`**. It is the only
pack-to-pack edge in the tree.

The direction is worth stating precisely, because it is the reverse of what the
capability story suggests. `AllbertBrowser.Actions.ResearchHandoff` calls
`AllbertResearch.DelegateObjective` and `AllbertResearch.Runtime`, so the compile
edge runs **browser → research**. `allbert_research` references nothing in this
pack, so the edge is acyclic. While both were path-injected into the residual
that edge was invisible; extracting research alone made it a warning, and under
warnings-as-errors a gate failure — which is exactly the kind of thing ADR 0098
exists to surface.

The rule the whole tier model rests on runs the other way again: **the kernel
must not depend on any pack**, and a violating edge is a build failure rather
than a review finding. Pack-to-pack edges are permitted when explicit and
acyclic, which is what makes the browser → research edge legal; composition
hosts may depend downward on both.

## What is in it

- `AllbertBrowser.Pack` — the pack descriptor, declaring one settings fragment
  and one test-lane owner.
- `AllbertBrowser.Plugin`, `AllbertBrowser.App` — the ADR 0017 entry point and
  the contributed app. `Plugin.settings_schema/0` returns `[]`; the schema moved
  to the pack `FragmentOwner` in M13 and declaring it twice would produce the
  fragment twice.
- `AllbertBrowser.Session`, `AllbertBrowser.Supervisor`, `AllbertBrowser.Cache`
  — the supervised session runtime.
- `AllbertBrowser.NavigationPolicy`, `AllbertBrowser.NetworkPolicy` — what the
  browser may reach.
- `AllbertBrowser.Driver` and `Driver.Playwright` / `Driver.Stub` — the driver
  seam release tests bind to.
- `AllbertBrowser.Actions` and `actions/` — the thirteen registered actions.
- `AllbertBrowser.Extractors` and `extractors/` (`html`, `markdown`, `pdf`,
  `text`) — content extraction.
- `AllbertBrowser.Doctor` — operator diagnosis.
- `AllbertBrowser.SurfaceProvider`, `AllbertBrowser.Panels.Results` — workspace
  surfaces.
- `Mix.Tasks.Allbert.Browser` (`lib/mix/tasks/allbert.browser.ex`) — the
  operator task.

## How it starts, and how it is discovered

The pack is `native_passive`: `mix.exs` declares no `mod:` application callback,
so the application itself starts nothing. `AllbertBrowser.Plugin.child_spec/1`
returns `AllbertBrowser.Supervisor.child_spec([])`, and the residual's
`AllbertAssist.Plugin.Bootstrap` starts that child under
`AllbertAssist.Plugin.ChildSupervisor` — which is itself hosted by
`AllbertAssist.Pack.ResidualEffectSupervisor`, and therefore only after the
readiness barrier opens. No browser process exists before then.

`allbert_composition` depends on this application, so it is loaded and started
through the normal OTP boot.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertBrowser.Pack]` entry, reconciled against the sealed
component row in `apps/allbert_assist/priv/licenses/catalog.json`. The retained
`priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that same
descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_research/README.md` — the one pack this one depends on.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
