# ADR 0080: Navigation Consolidation & Workspace Shell Presentation

Status: Accepted (v0.61b). The operator signed off the v0.61b plan's M0
shell-spec/sign-off section at the request-flow S2 review on 2026-07-02
(`S2 sign-off: accepted, 2026-07-02` recorded in the plan); the as-built
reconciliation is recorded after the S4 early live shell review and the final
validation pass.
Date: 2026-07-02
Related: ADR 0077 (Product Experience Design & IA — 0077 fixed the surface
inventory, journey, and navigation groups; 0080 revises the *presentation* of that
navigation model: one sidebar instead of two columns, no persistent top bars, and
a docked — not floating — workspace tool pane. The IA's surface inventory, journey,
and trust structure are untouched), ADR 0074 (web design system & UX language —
0080 supersedes the "workspace keeps its own shell beside the product sidebar"
as-built deviation recorded in 0074's v0.61 amendment; tokens/variant registry/
pattern catalog are unchanged and remain the rendering substrate), ADR 0079
(Direction C visual language — held; 0080 changes composition, not the aesthetic),
ADR 0030 (Surface DSL catalog) and ADR 0073 (cross-surface contract — the
rendering and read-through-action boundary, unchanged), ADR 0006 (Security
Central — the authority boundary, unchanged).
Anchors the v0.61b UX Refinement point release (0.61.1).

## Context

v0.61 shipped the Presentation Layer Overhaul correct-as-built and gate-green, and
the operator's manual validation (2026-07-01, captured in
`v0.61_manual_operator_feedback.md`, folded into `docs/plans/v0.61b-plan.md`)
confirmed the product works — and surfaced a coherent critique of the shipped
**shell composition**, distinct from any functional defect:

1. **Two navigation columns.** `/workspace` renders the shared product sidebar
   (`Layouts.product_sidebar/1`) *and* a second workspace-local submenu column
   (NavRail + ThreadList + AppLauncher surface nodes) side by side. The operator
   questioned the premise: "I don't see why workspace has to have its own nested
   view" — the workspace sections could nest as contextually-expanding submenus
   under the Workspace entry of the one product sidebar.
2. **Per-shell top bars.** The workspace appbar (`workspace-header`, a surface
   node) and the operator-shell topbar (`Layouts.operator_shell/1`) each spend a
   persistent horizontal band on brand/title/chips. The operator: those contexts
   "should be folded under the correct left panel contextual menu. This gives more
   space for chat, canvas etc."
3. **Floating tool panels.** The `workspace:*` destination panels (Settings,
   Models, Channels, Trust/Surface Policy) render inside the canvas region, which
   is CSS-positioned as a fixed drawer floating **over** the chat pane
   (`position: fixed` overlay, `z-index: 35`), occluding messages and the
   composer while the left half of the canvas sits empty.
4. **No desktop collapse.** Neither column has a desktop collapse affordance
   (only mobile shellbar/launcher variants exist), so the operator cannot reclaim
   horizontal space.
5. **A navigating status chip.** The chat-header objective chip is labeled with a
   run state ("running") but navigates to `/objectives/:id` — the label promises a
   state, the control delivers a navigation.

These items revise decisions two prior ADRs recorded: ADR 0077 asserted the IA and
navigation model are closed after v0.60 ("v0.61 chooses layout without changing
v0.60's IA"), and ADR 0074's v0.61 amendment locked the as-built two-shell
composition (workspace's own shell beside the sidebar as a left column). Shipped
reality has now been operator-evaluated and found wanting on composition. Leaving
the revision implicit in a plan would leave both ADRs contradicted by the code;
recording it as scattered amendments would split one coherent shell decision
across two files. Hence a new ADR, with pointer notes in 0077/0074.

External grounding (surveyed 2026-07; sources and product-observation boundaries
in the v0.61b plan's Research Grounding section): NN/g supports visible or
partially visible desktop navigation, left-side primary navigation for
applications, current-location cues, clear labels, submenu signifiers, and
click-activated rather than hover-only submenus. That grounds the expanded
sidebar default, icon-rail-first collapse, contextual Workspace disclosures,
active highlighting, and destination-naming rule. Radix scale-role guidance
grounds the dark-mode token pass. AI/workspace products (ChatGPT Canvas, Claude
Artifacts, Slack, Linear, VS Code, Notion, GitLab) are used only as contemporary
pattern observations for docked panes, single sidebars, rails, and slim per-view
headers.

## Decision

1. **One product sidebar owns navigation and context.** The workspace-local
   submenu column is retired. Its sections — Conversations (thread list + new
   conversation), Output, Apps, and the Workspace destinations — nest as
   disclosure sections under the **Workspace** entry of the product sidebar,
   auto-expanded and active-highlighted when the operator is on `/workspace`
   (collapsed to their section header elsewhere). Maximum two visible levels;
   sub-items are visually subordinate (indented, smaller), per the disclosure-nav
   pattern. The sidebar remains the one shared navigation component on every
   surface.
2. **Per-shell top bars are retired.** The workspace appbar and the operator-shell
   topbar are removed as persistent horizontal bands. Each view carries a **slim
   per-view header line** inside the content area — context/title left, view
   actions right. Global affordances relocate into the sidebar: brand stays as the
   sidebar header, theme toggle and overflow move to the sidebar footer, and the
   workspace context/status chips move to the per-view header, pane header, or
   chat header according to the v0.61b relocation map.
   Vertical space returns to chat/canvas.
3. **Workspace tool panels dock; nothing floats over chat.** The canvas region
   (which hosts the `workspace:*` destination panels and canvas tiles) becomes a
   **right-docked, resizable split pane** beside the chat pane: a draggable
   divider with min-width constraints, a collapse control on the divider, a
   keyboard toggle, and a persisted width. Chat is never occluded. Pane tenancy
   is replace-and-restore (operator decision 2026-07-02): the pane shows exactly
   one of canvas content or one destination panel; opening a destination
   replaces the canvas, closing it restores the canvas — no tab strip. Floating
   overlays are reserved for transient, self-dismissing content (menus, pickers,
   the rail flyout), which dismiss on Escape with focus return.
4. **The sidebar collapses to an icon rail, with an optional full hide.** A
   chevron toggle at the sidebar edge collapses the expanded sidebar to a narrow
   icon-only rail (top-level destinations stay visible; the workspace sections
   open from the Workspace rail icon as a click-activated flyout — operator
   decision 2026-07-02); a second stage (from the
   rail) fully hides it for maximum focus, with a persistent reopen affordance.
   Keyboard shortcut, `aria-expanded` on the toggle, focus return, and collapsed
   state persisted client-side. Expanded is the default; collapse is operator
   opt-in, never the default.
5. **Navigating controls name their destination.** A bare status chip must not
   navigate. Chat-header objective chips become **labeled link-chips** whose
   visible labels name status + the truncated objective title (for example,
   "Running · Ship weekly digest"). With three or more active objectives, the
   header shows the two most recent chips plus a "+N more" link to `/objectives`.
   Link affordances (hover underline, focus ring) are required, and the accessible
   name is of the form "View objective <title> — status: running". This is a
   general UX-language rule for the product, recorded here and in
   `docs/developer/web-design-system.md`.

Within-contract refinements shipped alongside (recorded in the v0.61b plan, not
decisions of this ADR): the chat-message type-scale fix (ADR 0074's typographic
contract, correctly applied), the subtler dark-mode token pass (within ADR 0079's
Direction C), and renamable conversation threads (a persisted operator-editable
title through the existing `:conversation_write` permission; the v0.58
no-internal-rename invariant holds).

## Guardrails

- **No new authority.** No new capability class, permission, confirmation-floor
  change, egress grant, or Settings Central key. Security Central is unchanged.
  Thread rename uses the existing `:conversation_write` permission through the
  registered-action path (Runner + PermissionGate, ADR 0073 identity pinned
  server-side).
- **The catalog stays the rendering boundary.** Sidebar consolidation, the docked
  pane, and per-view headers are catalog/shell/component-variant work; no
  model-generated or data-generated markup, no new rendering mechanism.
- **No internal rename.** `Conversations.Thread` modules/schema/atoms/topics/keys
  and `Session.Scratchpad` are untouched; the thread title is an existing
  persisted field gaining a write path, surfaced in UI strings only.
- **Direction C holds.** Tokens, elevation, motion roles, and the aesthetic are
  ADR 0079's chosen language; 0080 recomposes the shell, it does not restyle it.
  The dark-mode subtlety pass adjusts token *values* within the language and must
  keep every theme × high-contrast × reduced-motion × OS-preference cell readable
  (status tokens ≥ AA).
- **IA surface inventory and journey unchanged.** No screen or route is added or
  removed (additive-only carve-out untouched); navigation *presentation* changes,
  navigation *targets* do not. Deep-linkable `?destination=workspace:*` params
  keep working.
- **A11y axes hold.** Keyboard reachability, focus management, `aria-expanded`
  state, focus return on collapse/close, and the dark/high-contrast/
  reduced-motion axes are gate-checked (`:v061b` eval rows), not best-effort.
- **One spine.** All writes route through registered actions; the shell reads
  through the established renderer context; nothing reaches `Settings.Store` or
  business logic directly.
- **Layout preferences stay client-local.** The docked pane reuses the existing
  `WorkspaceSplitResizer` hook and key; sidebar collapse state uses a small
  `LayoutPrefs` hook. Neither path creates a Settings Central key or synced
  policy.

## Consequences

- The operator gets one navigation home, more horizontal and vertical space for
  chat and canvas, an unoccluded chat while tool panels are open, and control
  over how much chrome is visible.
- `docs/design/information-architecture.md` (navigation model / composition
  sections) and `docs/developer/web-design-system.md` (IA & navigation, screen
  composition, shell coverage, UX language) must be reconciled to the
  consolidated shell; ADR 0077 and ADR 0074 carry pointer notes to this ADR.
- The workspace surface tree changes shape: the NavRail/ThreadList/AppLauncher
  submenu nodes and the Header appbar node retire; the sidebar gains contextual
  workspace sections fed by the same renderer context (threads, destinations).
  Canvas-drawer CSS (`position: fixed` overlay) is replaced by a two-pane grid.
  The retired node atoms stay **registered-but-unused** in `Surface.Catalog`
  (operator decision 2026-07-02): the tree stops emitting them; the catalog
  list, type union, and their exact-list tests are untouched; pruning is a
  deliberate later pass. They are single-emitter atoms the v1.0 component
  carve-out exempts from name-freezing.
- The `:v061` proof suite is reconciled, not held verbatim: proofs that pin
  literal dark token values or the pre-consolidation nav structure are updated
  as deliberate, reviewed edits by the milestone that changes them, then the
  suite re-runs green in the `release.v061b` gate.
- v0.62's packaging scope is unchanged; its former M7 UX carryover moves to
  v0.61b (v0.62 plan reconciled). v0.63 onboarding and the v1.0
  presentation-contract freeze consume the consolidated shell as the baseline.
- Risk: the shell recomposition is the largest post-v0.61 UI change before the
  freeze; it is de-risked by the S2 plan sign-off and the S4 early live review
  checkpoints (operator sees the consolidated shell early and can send it back)
  rather than by candidate-direction fan-out (the pattern research points one
  way; a v0.60b-style multi-candidate pass is not warranted for composition).
