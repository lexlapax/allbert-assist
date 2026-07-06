# Selected Brand Identity — Allbert (Direction C)

Status: v0.61 M5.1 design artifact and M6 asset-build input. Records the chosen brand
mark, its Direction C rationale, usage guidance, and the M6 asset-build handoff. It is
design only: no runtime authority, no Settings key, no capability. It mirrors
`docs/design/visual-language-selected.md`'s role for the visual language and
`docs/design/layout-systems-selected.md`'s role for layout.

## Why a brand milestone

The v0.60b visual language (Direction C, ADR 0079) is an art direction — colour, type,
geometry, motion, depth — **not a brand mark**. The v0.60
`design-system-gap-analysis.md` flags brand identity as an **absent** gap: no logo,
wordmark, favicon/app-icon, or OG image existed upstream. M5.1 designs and selects the
mark so M6 implements a chosen identity rather than originating one at asset-build time.

## Chosen mark

**A rounded-square "A" monogram + "Allbert" wordmark**, consistent with Direction C
(Soft Modern Depth):

- **Mark** (`priv/static/images/allbert-mark.svg`): a `--allbert-accent` violet
  (`#7c6cf0` — the brand-asset fill, distinct from the UI `--allbert-accent` text token, deepened to `#6050e0` in v0.62 M0.1) rounded square (radius echoing `--allbert-radius-panel`) carrying a white
  geometric "A" (chevron + crossbar). Pure geometry — **no font dependency**, so it
  renders identically everywhere and needs no web-font fetch (honouring the Direction C
  system-local type constraint). It doubles as the favicon (SVG) and app icon.
- **Wordmark**: "Allbert" set in the Direction C rounded type stack
  (`--allbert-font-family`), `--allbert-text-strong` (`#1c1830`), weight 700. Rendered
  as live text (system-local), not a fetched font.
- **OG image** (`priv/static/images/allbert-og.svg`): the mark + wordmark + product
  tagline ("A personal assistant runtime that grows with you." / "Local-first ·
  inspectable · yours.") on the `--allbert-surface-0` tonal background.

## Direction C rationale

- **Rounded geometry** — the mark's rounded square and rounded-A strokes echo the
  Direction C large-radius scale and rounded type; it reads as soft-modern, not a sharp
  technical glyph.
- **Tonal violet** — the mark uses the exact promoted `--allbert-accent`; the OG surface
  uses the promoted `--allbert-surface-0`, so the brand is drawn from the same tokens the
  product ships, not a parallel palette.
- **System-local** — no web-font, no external fetch; the mark is geometry and the
  wordmark is live text over the system rounded stack. Consistent with the Direction C
  no-web-font constraint and the local-first product posture.

## Usage

- Shell: the sidebar brand shows the mark + "Allbert" wordmark, linking to `/`.
- Landing (`/`): the mark + wordmark headline the marketing hero.
- Favicon / app icon: `allbert-mark.svg` (SVG favicon).
- Social: `allbert-og.svg` as the OG/Twitter image.
- The stock Phoenix `logo.svg` is retired (removed; the service-worker precache and any
  references point at the Allbert mark).

## M6 asset-build handoff

M6 wires these assets: sidebar brand + landing hero use the mark/wordmark; the root
layout head adds the SVG favicon link and the SEO/OG metadata (title, description,
canonical, `og:*`, `twitter:card`, `og:image`) pointing at `allbert-og.svg`; the stock
Phoenix asset is retired. Sanitized brand renderings are recorded under
`docs/design/brand/`.
