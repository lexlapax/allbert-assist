# ADR 0025: User Theming And Override Security

## Status

Accepted for v0.35 User Theming And Layout Overrides
(`docs/plans/v0.35-plan.md`). This ADR pins how operators retheme and
re-lay-out the Allbert UI from `<ALLBERT_HOME>` without editing core code, and
the security posture for serving operator-supplied styling. It pairs with ADR
0024, which owns the `/workspace` route, panel contribution contract, and
v0.34 launcher/Canvas destination model that the layout-override layer
reorders. ADR 0025 does not block v0.31 or v0.32, and it does not change the
v0.33 app-intent handoff contract or v0.34 handoff-only routing context.
It was accepted in v0.35 M1 before token-theme implementation began.

## Context

All Allbert styling today is host-side: Tailwind v4 plus daisyUI compiled from
`apps/allbert_assist_web/assets/css/app.css`, with workspace tokens scoped to
`#workspace-shell` (`--allbert-*`) and a client-side `data-theme` toggle synced
from `localStorage`. Plugins ship no CSS. There is no way for an operator to
change colors, fonts, spacing, or layout without editing core source and
rebuilding assets, and `Plug.Static` only serves the web app's `priv`, so files
under `<ALLBERT_HOME>` cannot be served at all.

Mature apps solve this with one safe primitive: the host defines design tokens
as CSS custom properties, and the user override only reassigns those variables
(VS Code `colorCustomizations`, Obsidian `.obsidian/snippets`, Home Assistant
YAML themes, Discourse CSS custom properties, Jupyter `custom.css`). Tailwind v4
compiles `@theme` tokens to runtime `:root` variables and organizes output into
cascade layers, so a stylesheet loaded after Tailwind and outside its `@layer`s
wins by cascade precedence with no rebuild.

Raw operator CSS is a genuine attack surface even for a local app: CSS data
exfiltration (attribute selectors plus `background-image: url(...)` / `@import`)
can leak tokens and form values to a remote server with no JavaScript (OWASP
CSS injection, PortSwigger inline-style exfiltration). Jupyter's opt-in
`--custom-css` flag is the precedent: ship the powerful path off by default.

## Decision

### 1. Three override layers under `<ALLBERT_HOME>`

A new `AllbertAssist.Runtime.Paths.themes_root/0` →
`<ALLBERT_HOME>/themes` (and `theme_snippets_root/0` →
`<ALLBERT_HOME>/themes/snippets`), both created by `ensure_home!/0`, hold
operator styling. A new
`AllbertAssistWeb.ThemeController` serves it (because `Plug.Static` cannot reach
the home dir). Each layer is gated by Settings Central `workspace.theme.*`:

1. **Design tokens (default, safe).** `themes/<name>.yaml` is a constrained
   token map (colors, spacing, fonts, radii). The host emits a `:root` variable
   block served at `/theme/user.css`, linked after `app.css`. Reassigns existing
   presentational `#workspace-shell` `--allbert-*` tokens only; it does not
   reassign Tailwind/daisyUI `--color-*` tokens, root-grid tracks, AppBar
   geometry, route selectors, or other structural variables. Selected via
   `workspace.theme.active`.
2. **CSS snippets (opt-in).** `themes/snippets/*.css`, enabled per-file via
   `workspace.theme.enabled_snippets`, gated by
   `workspace.theme.snippets_enabled` (default false). Served last, outside
   Tailwind layers, at `/theme/snippets/<name>.css`.
3. **Layout override (data, validated).** `workspace/layout.yaml`
   enables/disables/reorders v0.34 launcher destinations, sets a default
   Canvas destination, and pins panels into allowed destination groups. It is a
   selection of catalog-allowed atoms, registered destinations, retained panel
   zone labels, and registered surfaces — never code — validated against the
   catalog and registered surfaces. Gated by
   `workspace.layout.override_enabled`.

### 2. Strip-and-warn sanitization for snippets

`AllbertAssist.Theme.Snippets` processes snippet CSS before serving: it
**rejects `@import`** outright and **strips `url()` and `image-set()`** values,
emitting an operator-visible warning that names what was removed. A snippet that
is entirely unsafe serves as empty with a warning. Snippet content can never
break the workspace into an unusable state.

### 3. Content-Security-Policy baseline

The `:browser` pipeline gains a CSP (`style-src 'self'`, `img-src 'self'`, no
remote fetch). This is defense-in-depth behind the sanitizer: even if a
dangerous construct were served, the browser blocks remote style/image fetches.
There is no CSP today beyond `put_secure_browser_headers`.

### 4. Opt-in posture and fallbacks

Tokens are the default safe path; snippets and layout override are off by
default. Missing, invalid, or partially invalid files fall back to defaults
per-key with bounded warnings, never a crash. Theming reads only
`<ALLBERT_HOME>`; no remote theme fetching.

### 5. Settings key migration: `workspace.theme` → `workspace.theme.mode`

v0.34 shipped a scalar `workspace.theme` key (light/dark/system mode, reached
from the AppBar `#workspace-theme-toggle`). To let the token/snippet keys share
the `workspace.theme.*` namespace without a scalar-vs-prefix collision, v0.35
renames it to `workspace.theme.mode` with a compatibility read (a legacy stored
`workspace.theme` value normalizes to `workspace.theme.mode`), audited like any
settings change. This is presentational only and changes no routing or domain
behavior. All v0.35 keys (`workspace.theme.mode/active/snippets_enabled/
enabled_snippets`, `workspace.layout.override_enabled`) are owned by the
shipped core `workspace` Settings Central schema fragment (`core:workspace`),
assembled from `AllbertAssist.Settings.Schema` through the v0.31
`AllbertAssist.Settings.Fragments` facade.

### 6. Settings accountability without storing raw override blobs

Settings Central owns and audits the switches/selections that make local
override files active: mode, active token theme basename, snippet master
switch, enabled snippet basenames, and layout override enablement. Raw token
YAML, snippet CSS, and layout YAML remain file-backed operator data under
Allbert Home and are not copied into Settings Central.

The v0.34 Settings Canvas displays read-only accountability status for the
active override files: safe basenames, fingerprints or mtimes, parse/
sanitizer/layout status, and bounded diagnostics. Diagnostics are capped,
redacted, and avoid raw file contents, secrets, and unsafe absolute path
exposure. This preserves Settings Central auditability without turning
operator CSS/YAML into hundreds of settings keys.

### 7. Token theme is a single set over the current mode

The dark/light/system mode sets the base palette; the selected token theme is a
single set that retints on top of whichever mode is active. `/theme/user.css`
loads after `app.css` in both modes; snippets load last. v0.35 adds no per-mode
token variants. The themeable allow-list is the presentational `--allbert-*`
variables only; layout-structural variables (root-grid track sizes, rail/canvas
widths, AppBar geometry), route selectors, and Tailwind/daisyUI `--color-*`
variables are excluded so tokens cannot break the v0.34 shell or globally
retint unrelated UI.

### 8. Layout validates against a pinned source; no lockout; AppBar is fixed

Layout override validates against an enumerable destination/panel source that
v0.35 must add (`Workspace.Catalog.known_destinations/1`, with the grammar
`output` | `app:<id>` | `workspace:<tool>`), registered panel surface ids, and
the catalog's retained zone labels (including the v0.34-demounted
`:utility_drawer` / `:context_rail` labels, which validate but cannot re-mount a
region). `app:allbert` is not a v0.35 layout destination; neutral Allbert
output is represented by `output`. The **AppBar is fixed chrome**: its brand,
context indicator, theme toggle, and destination quick-links are out of scope
for layout override. **Settings and Output are non-hideable** launcher
destinations, and the `workspace.layout.override_enabled` master switch (UI or
CLI) always disables overrides — together preventing self-lockout.

## Consequences

- Operators can fully retheme and re-lay-out the UI from their home dir with no
  rebuild and no core edits.
- The powerful, riskier paths (raw CSS, layout) are opt-in and bounded;
  unsanitized CSS is never served, and CSP backs the sanitizer.
- Settings Central audits gates and selections, while raw override file
  contents remain under Allbert Home. The Settings Canvas surfaces derived
  fingerprints/status/diagnostics for accountability without storing CSS/YAML
  blobs as settings.
- Layout override changes view composition only. It cannot create components,
  routes, action bindings, permissions, or `active_app` routing context, and it
  cannot restore the retired v0.32 utility drawer or context rail as authority
  surfaces.
- For a local single-user app the residual CSS risk is mostly self-inflicted;
  the sanitizer + CSP + opt-in keep it from becoming a regression as channels
  and multi-user scenarios arrive.
- New `workspace.theme.*` / `workspace.layout.*` Settings Central keys and a new
  served route surface (`/theme/*`) are added; both are covered by named v0.28
  eval rows: `theme-snippet-import-reject-001`, `theme-snippet-url-strip-001`,
  `theme-css-exfil-001`, `theme-path-traversal-001`, `theme-csp-regression-001`,
  `layout-override-authority-001`, and `layout-hide-settings-lockout-001`.
- A future milestone may add a file watcher for live reload. Remote theme
  sources or marketplaces remain parked future work and would require a new
  security/design pass; v0.35 recomputes local files on request with a version
  stamp.

## Relates To

- Pairs with: ADR 0024 (App UI Contribution And Workspace Zones) — the
  layout-override layer reorders the v0.34 launcher destinations and Canvas
  destination groups that ADR 0024 defines.
- Builds on: ADR 0023 (workspace substrate, `#workspace-shell` token scope), the
  Allbert Home / v0.31 runtime path precedence model, and Settings Central.
- Constrained by: ADR 0006 (Security Central) redaction/audit posture and the
  "no arbitrary model-generated HTML/JS" rule from ADR 0023.
- Enables: v0.38 Templated Creation scaffolds inert token-theme, snippet,
  and `layout.yaml` stubs from the contracts this ADR pins.
- Bounds with: v0.36/v0.37 dynamic work — theme roots under `<ALLBERT_HOME>` are
  operator styling data, never executable drafts; the v0.36 sandbox and v0.37
  generator must not compile or load them as code.
- Revisit: the CSP baseline must be reconciled with any post-v0.38 external UI
  protocol bridge (AG-UI/A2UI/MCP Apps) before such a bridge is exposed.
- New net work: not previously parked in `docs/plans/future-features.md`.
