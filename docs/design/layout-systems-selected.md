# Selected Layout System — D (Sidebar-primary)

Status: v0.61 M2 design artifact and M3-M9 build input. This document records the
operator's canonical **layout choice**, its rubric rationale, the definitive per-surface
layout spec for all nine IA surfaces, and the build handoff. It is design only: no
runtime authority, no Settings key, no capability. It mirrors
`docs/design/visual-language-selected.md`'s role for the visual language.

## Chosen layout

**CHOSEN_LAYOUT: d** — **Layout system D "Sidebar-primary"**
(`docs/design/layout-systems-explored.md`).

The operator reviewed the four rendered candidate layout systems — **A** Focused canvas,
**B** Workbench, **C** Progressive shell, and **D** Sidebar-primary — side-by-side across
all nine IA surfaces in Direction C (the committed composites in
[`layout-systems/`](layout-systems/README.md)) and **chose layout D (Sidebar-primary)**
as the canonical layout v0.61 builds.

Layout D is a fixed left sidebar (brand + persistent vertical navigation + actions) with
a single content pane filling the rest — the conventional, immediately-legible
productivity-app shell (Linear/Slack/Notion-familiar).

## Rubric rationale (why D)

Scored against the v0.60b `visual-language-brief.md` "does it feel 1.0" rubric axes,
applied to layout:

- **Deciding axis — Fit to IA / journey / persona / navigability.** With **nine** IA
  surfaces (Start / Work / Operate / Extend / Trust groups), a **persistent vertical
  sidebar** scales to the full surface set far better than a top-appbar row (which runs
  out of horizontal room), a focused single canvas (A, which hides navigation), or a
  button-grid (C, which trades persistent nav for minimal chrome). The technical-prosumer
  persona gets an immediately-legible, always-visible map of the whole product — the
  lowest-friction way to move across all nine surfaces.
- **Feels 1.0 / ultra-modern (accepted):** the sidebar is a conventional pattern, but in
  Direction C (tonal violet depth, rounded geometry, soft elevation) it reads as a modern
  product shell, not a dated admin panel. The operator accepted "familiar and legible"
  over the higher-novelty focus (A) or density (B) ceilings.
- **Implementability:** strong — a fixed-sidebar shell is a standard, well-understood
  responsive pattern over the existing shell markup and token scales; the smallest build
  risk of the four.
- **A11y:** strong — a persistent vertical nav gives stable, predictable keyboard focus
  order and a consistent landmark across every surface.
- **Accepted trade-offs:** less single-task focus than A (the sidebar always occupies
  ~15rem) and less information density than B (single content pane, not multi-pane). The
  operator judged navigability and familiarity across nine surfaces the higher priority.

The selection was made from rendered pixels (the `/preview/layout/d/*` previews and the
committed side-by-side composites), not prose.

## Canonical per-surface layout spec

Layout D applies one composition paradigm — **fixed left sidebar + single content pane**
— to every surface; the sidebar carries the grouped IA navigation, the content pane
carries the surface's zones. Per-surface spec (all nine surfaces):

| Surface | Sidebar (persistent) | Content pane (D layout) |
|---|---|---|
| **launch** | brand + full IA nav + primary action | landing/resume hero + setup status in the pane |
| **onboarding** | brand + IA nav (wizard step reflected as active) | QuickStart/Advanced wizard seat filling the pane |
| **workspace** | brand + IA nav (Workspace active) | chat-primary hero + composer filling the pane |
| **objectives** | brand + IA nav (Objectives active) | objective list/detail in the pane |
| **jobs** | brand + IA nav (Jobs active) | job cards + run history in the pane |
| **models** | brand + IA nav (Models active) | model-readiness + policy in the pane |
| **channels** | brand + IA nav (Channels active) | channel cards + policy in the pane |
| **settings** | brand + IA nav (Settings active) | settings + surface-policy + intents in the pane |
| **trust** | brand + IA nav (Trust active) | trace + confirmation + approval in the pane |

Responsive spine: below the mobile breakpoint the sidebar collapses to a stacked
top-appbar + mobile shellbar (validated in the M1 previews); the content pane goes
full-width.

## M3-M9 build handoff

- **M3 (Direction C tokens & variants):** promotes the disposable
  `[data-visual-direction="c"]` preview CSS to first-class tokens/variants; the sidebar
  shell in M4 is dressed in those tokens, not the preview delta.
- **M4 (IA & Navigation Implementation):** implements the **D sidebar shell** as the real
  operator shell — a fixed left sidebar carrying the grouped IA navigation (Start / Work /
  Operate / Extend / Trust) with active-group/active-route states, and the responsive
  collapse — replacing the disposable layout-preview mechanism.
- **M5 (Redesigned Core Screens):** fills each surface's content pane with the real
  redesigned screen per the per-surface spec above.
- **M6-M9:** brand/landing, motion, visual-hierarchy, and OS-dark-mode/suggested-action
  passes apply over the D shell.
- The disposable `/preview/layout/*` routes, `LayoutPreviewLive`,
  `LayoutSystemManifest`, and the `[data-layout-system]` CSS are exploration only and are
  removed/not-promoted; M4 re-implements the D layout as the production shell.
