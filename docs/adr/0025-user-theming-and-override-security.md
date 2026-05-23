# ADR 0025: User Theming And Override Security

## Status

Proposed for v0.33 User Theming And Layout Overrides
(`docs/plans/v0.33-plan.md`). This ADR pins how operators retheme and
re-lay-out the Allbert UI from `<ALLBERT_HOME>` without editing core code, and
the security posture for serving operator-supplied styling. It pairs with ADR
0024, which owns the `/workspace` route, workspace zones, and utility drawer
that the layout-override layer reorders. ADR 0025 does not block v0.31 or
v0.32.

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
`<ALLBERT_HOME>/themes` (and `themes_snippets_root/0` →
`<ALLBERT_HOME>/themes/snippets`), both created by `ensure_home!/0`, hold
operator styling. A new
`AllbertAssistWeb.ThemeController` serves it (because `Plug.Static` cannot reach
the home dir). Each layer is gated by Settings Central `workspace.theme.*`:

1. **Design tokens (default, safe).** `themes/<name>.yaml` is a constrained
   token map (colors, spacing, fonts, radii). The host emits a `:root` variable
   block served at `/theme/user.css`, linked after `app.css`. Reassigns existing
   `--allbert-*`/`--color-*` tokens; retints the whole UI with no rebuild.
   Selected via `workspace.theme.active`.
2. **CSS snippets (opt-in).** `themes/snippets/*.css`, enabled per-file via
   `workspace.theme.enabled_snippets`, gated by
   `workspace.theme.snippets_enabled` (default false). Served last, outside
   Tailwind layers, at `/theme/snippets/<name>.css`.
3. **Layout override (data, validated).** `workspace/layout.yaml`
   enables/disables/reorders ADR 0024 zones and pins panels. It is a selection
   of catalog-allowed atoms and registered zones — never code — validated
   against the catalog and registered surfaces. Gated by
   `workspace.layout.override_enabled`.

### 2. Strip-and-warn sanitization for snippets

`AllbertAssist.Theme.Sanitizer` processes snippet CSS before serving: it
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

## Consequences

- Operators can fully retheme and re-lay-out the UI from their home dir with no
  rebuild and no core edits.
- The powerful, riskier paths (raw CSS, layout) are opt-in and bounded;
  unsanitized CSS is never served, and CSP backs the sanitizer.
- For a local single-user app the residual CSS risk is mostly self-inflicted;
  the sanitizer + CSP + opt-in keep it from becoming a regression as channels
  and multi-user scenarios arrive.
- New `workspace.theme.*` / `workspace.layout.*` Settings Central keys and a new
  served route surface (`/theme/*`) are added; both are covered by v0.28 eval
  additions (sanitizer bypass, CSP regression, exfiltration attempts).
- A future milestone may add a file watcher for live reload and an OS-keychain/
  remote theme source; v0.33 recomputes on request with a version stamp.

## Relates To

- Pairs with: ADR 0024 (App UI Contribution And Workspace Zones) — the
  layout-override layer reorders the zones ADR 0024 defines.
- Builds on: ADR 0023 (workspace substrate, `#workspace-shell` token scope), the
  Allbert Home / v0.31 runtime path precedence model, and Settings Central.
- Constrained by: ADR 0006 (Security Central) redaction/audit posture and the
  "no arbitrary model-generated HTML/JS" rule from ADR 0023.
- New net work: not previously parked in `docs/plans/future-features.md`.
