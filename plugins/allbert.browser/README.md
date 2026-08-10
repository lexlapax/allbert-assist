# allbert.browser — Browser / Web Research

The supervised browser session runtime and its registered actions.

## What it is

A shipped source-tree plugin of `kind: "app"`, entered through
`AllbertBrowser.Plugin`, contributing `AllbertBrowser.App`, the `browser.*`
Settings Central schema, registered browser actions, and workspace surfaces.

## Why it exists

Driving a real browser is the single most dangerous capability in the product:
it reaches the network, renders untrusted content, and holds state across turns.
Isolating it behind a plugin boundary with its own settings schema, navigation
policy, and network policy means the blast radius is inspectable in one place.

Operational control runs through the reviewed Playwright/Chromium bridge.
Deterministic release tests use the **stub driver** instead, so the gate never
depends on a live browser.

## Contents

- `plugin.ex`, `app.ex` — entrypoint and contributed app.
- `session.ex`, `supervisor.ex`, `cache.ex` — the supervised session runtime.
- `navigation_policy.ex`, `network_policy.ex` — what the browser may reach.
- `driver.ex` (+ stub) — the driver seam release tests bind to.
- `actions.ex`, `extractors.ex` — registered actions and content extraction.
- `doctor.ex` — operator diagnosis.
- `surface_provider.ex` — workspace surfaces.

## Authority

Consent is gated up front and navigation grants are durable and reviewable; the
plugin does not grant network authority by being registered. `allbert.research`
depends on this capability but holds none of it directly.

## How it is loaded

Not a separate Mix project. Its `lib` is injected into `apps/allbert_assist`
through `elixirc_paths/1`; `allbert_plugin.json` is discovery metadata only.
