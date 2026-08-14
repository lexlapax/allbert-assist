# allbert_assist_web

The Phoenix web interface. It renders Allbert; it does not decide anything
Allbert does.

## Tier: none, and that is the point

Under ADR 0098 there are exactly two steady-state capability categories — the
kernel, or a named pack — and this application is **neither**. It is
**descriptorless**: `mix.exs` declares no `allbert_pack` entry, it has no row in
the sealed Pack projection in `apps/allbert_assist/priv/licenses/catalog.json`,
and the v1.4 M0 application census classifies it as a *descriptorless
non-capability interface*.

That is a structural claim, not a stylistic one. Because there is no descriptor,
nothing can contribute *through* this application, and it can never be mistaken
for a capability. Domain behavior placed here would violate ADR 0098 exactly as
it would in `allbert_composition`.

The page owns rendering and browser APIs. It does not own runtime authority.
Workspace effects cross the same boundaries as the CLI: registered actions,
`AllbertAssist.Actions.Runner.run/3`, Security Central, Settings Central,
traces, confirmations, and Allbert Home remain authoritative.

## Dependency direction

`mix.exs` declares `allbert_composition` and `allbert_assist`, plus the Phoenix
stack. It depends on **no pack directly**, and no pack it hosts a surface for
appears in its dependency list.

The rule the tier model rests on runs the other way: **the kernel must not
depend on any pack**, and a violating edge is a build failure rather than a
review finding, because umbrella siblings are declared with `in_umbrella: true`.
A composition host may depend downward on both, which is what this application
and `allbert_composition` do.

Two applications depend *on this one*: `allbert_artifacts` and `stocksage`. Both
contribute a routed LiveView, so both need the application that owns the router.
That is why neither appears in `allbert_composition`'s dependency list — naming
them there would close the loop `web -> composition -> pack -> web`. They sit
above Web in the DAG, started from the root `mix.exs` release `applications:`
list. Before v1.4 M13 their web surfaces were compiled *into* this application
through `elixirc_paths/1`; M13 moved them out.

## What is in it

- `AllbertAssistWeb.Endpoint`, `Router`, `controllers/`, `plugs/` — the HTTP
  surface, including the `public_protocol/` controllers (MCP, OpenAI-compatible,
  and the WhatsApp inbound webhook, which lives here rather than in
  `allbert_whatsapp` because a route belongs to the application that owns the
  router).
- `live/` and `workspace/` — the `/workspace` LiveView, the single operator
  home: chat, persistent per-thread canvas tiles, task-scoped ephemeral
  surfaces, objective/status badges, trace cards, confirmation cards, Settings
  Central, app launcher, mobile tabs, and offline text/markdown tile editors.
- `AllbertAssistWeb.PackSurfaces` — how a pack's routed surface is resolved. The
  read path is deliberately identical to `AllbertAssist.CLI.PackGroups`: take
  each row of the sealed projection and use its trusted `descriptor_module`
  atom. No pack list lives here.
- `AllbertAssistWeb.PackReadiness` (plus `pack_readiness/`) — a web-side
  **observer** of the acknowledged Pack readiness epoch, deliberately not a Pack
  subscriber and not an authority boundary. It admits an HTTP or socket request
  only after it has observed readiness.
- `AllbertAssistWeb.SignalBridge` / `SignalBridgeSupervisor` — bridges objective
  and workspace lifecycle signals from `Jido.Signal.Bus` to `Phoenix.PubSub`.
  Web-only: headless CLI deployments do not need it.
- `AllbertAssistWeb.GateOwnerManifest` — declared through
  `env: [allbert_gate_owner_manifests: ...]`, so the test gate discovers this
  application's owned lanes without a kernel-side list.
- `surface/`, `components/`, `telemetry.ex`, `gettext.ex`.

## How it starts

`mix.exs` names `mod: {AllbertAssistWeb.Application, []}`, which supervises
`Telemetry`, its own `Phoenix.PubSub`, `PackReadiness`,
`SignalBridgeSupervisor`, and `Endpoint`, `:one_for_one`. It is last in the
frozen start DAG: kernel, then residual, then the native packs, then
`allbert_composition`, then Web.

## Running it locally

```sh
export ALLBERT_HOME=/tmp/allbert-web-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Then open:

```text
http://localhost:4000/workspace
http://localhost:4000/workspace?app_id=stocksage
http://localhost:4000/apps/stocksage/analyses/<analysis_id>
http://localhost:4000/jobs
```

`/workspace` is the only operator home. The pre-v0.32 `/agent`, `/settings` and
`/stocksage/*` routes are absent rather than redirected; the retained StockSage
long-form route is `/apps/stocksage/analyses/:id`, and its dashboard, recent
analyses, queue and trends render as catalog-validated `/workspace` panels
declared by `StockSage.App.surfaces/0`.

The browser-side Yjs + IndexedDB editor stores local drafts and sends bounded
snapshots to the workspace facade; server-side reconciliation records canvas
revisions and surfaces conflict/revert UI. Rejected or corrupt local drafts are
retained in browser storage with fallback-shell recovery metadata rather than
discarded.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` §1 —
  composition and interface hosts are not a capability tier.
- `apps/allbert_composition/README.md` — the host this application starts after.
- `apps/allbert_assist/README.md` — the residual whose facades every surface
  here calls.
