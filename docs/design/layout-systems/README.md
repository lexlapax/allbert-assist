# v0.61 Layout-System Screenshots

Status: v0.61 M2 design record (present). The operator chose **layout D
(Sidebar-primary)** as `CHOSEN_LAYOUT`; the selected-layout captures are committed
(`selected-layout-d-<surface>.png`, nine surfaces). See
`docs/design/layout-systems-selected.md`.

This directory is the committed, sanitized screenshot record for the v0.61
layout-system exploration and operator choice. Raw browser evidence, console logs,
and temporary captures stay under `$HOME/.allbert-release-evidence/v061` and are
not committed.

Captures present (M1) — four layout systems (a=Focused canvas, b=Workbench,
c=Progressive shell, d=Sidebar-primary) × nine IA surfaces, all rendered in Direction
C, plus one side-by-side composite per surface:

- `layout-<system>-<surface>.png` — one screenshot for every layout system and
  every IA surface (36 total).
- `<surface>-side-by-side.png` — one comparison composite per IA surface, showing the
  four candidate systems side by side (9 total).
- `selected-layout-<system>-<surface>.png` — added in M2: one final selected-layout
  screenshot per IA surface after `CHOSEN_LAYOUT` is formalized.

Captured static-HTML (JS disabled) at 1200px wide from the local preview server; the
composites are HTML contact sheets of the four per-system captures.

Surfaces:

- `launch`
- `onboarding`
- `workspace`
- `objectives`
- `jobs`
- `models`
- `channels`
- `settings`
- `trust`

The screenshots are posterity artifacts for design review only. They do not grant
authority, replace automated proof, or document raw operator data.
