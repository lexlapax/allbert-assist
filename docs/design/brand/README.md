# Allbert brand assets (v0.61 M5.1 / M6)

The v0.61 brand identity design record. See `../brand-identity-selected.md` for the
chosen mark, its Direction C rationale, and the M6 asset-build handoff.

## Candidate + selected renderings (M5.1 design record)

Sanitized renderings of the candidate marks reviewed and the selected mark, committed
for posterity (Direction C: rounded geometry, `--allbert-accent` violet, tonal surface):

| Rendering | File | Disposition |
|---|---|---|
| Candidate 1 — filled violet monogram | `candidate-1-monogram-filled.svg` | **chosen** |
| Candidate 2 — outline monogram | `candidate-2-monogram-outline.svg` | rejected (lower contrast at favicon size) |
| Candidate 3 — chat-dots glyph | `candidate-3-dot-glyph.svg` | rejected (reads as "typing", not a brand) |
| Selected mark + wordmark lockup | `selected-mark-lockup.svg` | the built identity |

## Asset inventory

| Asset | Source | Use |
|---|---|---|
| Brand mark | `apps/allbert_assist_web/priv/static/images/allbert-mark.svg` | shell sidebar brand, landing, SVG favicon, app icon |
| OG image | `apps/allbert_assist_web/priv/static/images/allbert-og.svg` | `og:image` / `twitter:image` |
| Wordmark | live text (`--allbert-font-family`, weight 700, `--allbert-text-strong`) | shell + landing; no fetched font |

All assets are Direction C (rounded geometry, `--allbert-accent` violet, tonal
surfaces) and system-local (no web-font fetch). The stock Phoenix `logo.svg` is retired.
