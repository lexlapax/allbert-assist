# Browser Plugin Developer Notes

The v0.43 browser plugin is under `plugins/allbert.browser/`.

Runtime authority stays at the registered action boundary:

- `AllbertBrowser.Session` owns driver state as a plain GenServer.
- `AllbertBrowser.Driver` is the behaviour; release tests use
  `AllbertBrowser.Driver.Stub`. The operational driver is
  `AllbertBrowser.Driver.Playwright`, which talks JSON over stdio to the
  plugin-owned Node bridge in `priv/playwright_bridge/`. Its callbacks cover
  navigate, click, fill, download, extract, screenshot, and close.
- `AllbertBrowser.NavigationPolicy` reuses `External.HttpPolicy` for top-level
  URL preflight.
- `AllbertBrowser.NetworkPolicy` bounds subresources.
- `AllbertBrowser.Extractors.*` are local bounded parsers/converters.
- `AllbertBrowser.Cache` writes content-addressed artifacts under Allbert Home.
- `AllbertBrowser.SurfaceProvider` and `AllbertBrowser.Panels.Results`
  contribute workspace surfaces and inert intent handoff descriptors through
  `AllbertBrowser.App`. Browser driver actions remain plugin-owned.

Do not call the driver from LiveView, app panels, descriptors, or model output.
Use `AllbertAssist.Actions.Runner.run/3` with the browser actions.

Deterministic release tests stay on the stub driver and must not install
packages, launch external browsers, or fetch the network. Operational browser
evidence comes from `mix allbert.test external-smoke -- browser_research`,
which uses `AllbertBrowser.Driver.Playwright` against a local fixture. The
bridge has a checked-in `package-lock.json`; dependency installation is a
developer/operator setup step, not plugin discovery or action execution.

Session and cache bounds are part of the runtime contract. `AllbertBrowser.Session`
enforces max lifetime, idle timeout, and max-concurrent settings. The browser
supervisor contributes the paused cache sweep job idempotently, and cache
writes enforce `browser.cache.max_bytes` with oldest-first eviction.

`browser_fill` and `browser_download` are registered so workflows and evals can
see the complete v0.43 surface, but both default to denied. Their opt-in path
requires the matching `browser.*.enabled` setting and a permission policy of
`needs_confirmation`; they cannot be configured to unconditional allow.
