# Browser Plugin Developer Notes

The v0.43 browser plugin is under `plugins/allbert.browser/`.

Runtime authority stays at the registered action boundary:

- `AllbertBrowser.Session` owns driver state as a plain GenServer.
- `AllbertBrowser.Driver` is the behaviour; release tests use
  `AllbertBrowser.Driver.Stub`. Its callbacks cover navigate, click, fill,
  download, extract, screenshot, and close.
- `AllbertBrowser.NavigationPolicy` reuses `External.HttpPolicy` for top-level
  URL preflight.
- `AllbertBrowser.NetworkPolicy` bounds subresources.
- `AllbertBrowser.Extractors.*` are local bounded parsers/converters.
- `AllbertBrowser.Cache` writes content-addressed artifacts under Allbert Home.
- `AllbertBrowser.App` contributes workspace surfaces and inert intent handoff
  descriptors. Browser driver actions remain plugin-owned.

Do not call the driver from LiveView, app panels, descriptors, or model output.
Use `AllbertAssist.Actions.Runner.run/3` with the browser actions.

The Playwright driver is intentionally exercised only by external-smoke work.
Release tests stay on the stub driver and must not install packages, launch
external browsers, or fetch the network.

`browser_fill` and `browser_download` are registered so workflows and evals can
see the complete v0.43 surface, but both default to denied. Their opt-in path
requires the matching `browser.*.enabled` setting and a permission policy of
`needs_confirmation`; they cannot be configured to unconditional allow.
