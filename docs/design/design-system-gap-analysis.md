# Design-System Gap Analysis

Status: v0.60 M7 design artifact and ADR 0074 v0.61 input. This document maps
the v0.58 token/component/pattern substrate against the M2 information
architecture and the M6 walking skeleton. It is a v0.61 backlog, not a v0.60
implementation request.

## Method

Inputs reviewed:

- `docs/design/information-architecture.md` composition rules and preview-route
  manifest.
- M6 `/preview/*` walking skeleton route set and shell behavior.
- `docs/developer/web-design-system.md` v0.58 token, variant, pattern, shell, and
  catalog contracts.
- ADR 0074 and its proposed v0.61 Presentation Layer Overhaul amendment.

The analysis below names gaps only when the v0.61 overhaul needs a reusable
design-system extension rather than a one-off page patch.

## Token Gaps

| Gap | Required by composition rule / skeleton screen | Current substrate | v0.61 owner |
|---|---|---|---|
| Semantic surface-depth scale | Product shell, workspace primary area, utility drawer, ephemeral layer; screens `workspace`, `settings`, `trust`. | Global elevation/focus tokens exist, but v0.61 needs named depth roles for shell, primary work, secondary rail, drawer, modal, and transient trust surfaces. | Add semantic elevation/depth tokens and map shell/drawer/modal/card layers to them. |
| Surface-tone hierarchy | Navigation groups Start / Work / Operate / Extend / Trust; all M6 screens. | Color tokens exist, but the IA needs semantic surface tones for product start, work, operations, extensions, and trust without creating one-off palettes. | Add surface-tone aliases and group-aware neutral/accent usage guidance. |
| Density scale | Daily-use scanning in `jobs`, `objectives`, `models`, `settings`, and `trust`; compact vs roomy product states. | Spacing tokens exist, but component density is not consistently expressed as compact/default/comfortable variants. | Add density tokens and component-level density props for panels, lists, cards, nav, and status rows. |
| First-run emphasis scale | `launch`, `onboarding`, and first useful chat empty states. | Type and spacing tokens exist, but first-run needs a restrained emphasis scale distinct from marketing hero styling. | Add first-run/empty-state emphasis tokens for title, support copy, and suggested-action density. |
| Motion roles | Route transitions, drawer opening, skeleton loading, wizard step transition, reduced-motion fallback. | Duration/easing and reduced-motion tokens exist, but there are no semantic motion roles. | Add named motion roles: route, drawer, modal, wizard-step, skeleton, status-change, all gated by reduced motion. |
| Responsive shell breakpoints | Desktop appbar/rail and mobile shellbar for the M2 IA groups. | Responsive CSS exists per shell/component, but no documented breakpoint roles for grouped navigation and preview-to-production promotion. | Define shell breakpoint roles and nav overflow behavior for v0.61 screens. |
| Brand/identity tokens | `launch`, `workspace`, and future landing surface. | ADR 0074 amendment calls out absent brand identity. | Add logo/wordmark placement, brand accent, and product mark spacing tokens without changing authority or route scope. |

## Component-Variant Gaps

| Gap | Required by composition rule / skeleton screen | Current substrate | v0.61 owner |
|---|---|---|---|
| Grouped navigation variant | M2 Navigation Model groups Start, Work, Operate, Extend, Trust; all M6 screens. | `operator_shell/1` can accept custom `nav_items`, but group labels, overflow, and mobile grouping are not first-class variants. | Add grouped-nav component variants for shell/appbar/mobile shellbar with active group and active route states. |
| Empty-state variants | First-run, onboarding, first useful chat, no jobs, no objectives, no trust events. | `empty_state` exists as a catalog atom, but all empty states share one generic shape. | Add `empty_state` variants: first_run, quickstart, first_chat, no_data, blocked_repair, post_success. |
| Suggested-action affordance | `launch`, `workspace`, `onboarding`, `models`; M1 first useful chat follow-on action. | Button/action variants exist, but suggested actions are not a distinct non-authority affordance. | Add suggested-action card/list variants that visually separate inert suggestion, confirmed action, and disabled repair. |
| Model/readiness status variants | `models`, `onboarding`, `workspace`; M3 first-model-state. | `status_badge` tones exist, but model readiness states are not encoded as reusable variants. | Add model-state badges/cards for local_ready, runtime_missing, runtime_unhealthy, model_missing, below_hardware_floor, byok_ready, blocked. |
| Profile/persona choice card | `onboarding`; M4 persona model. | Generic cards/lists exist; no reviewed-profile seed card or seed-diff variant. | Add persona choice and profile review variants with seed-only/no-authority framing. |
| Trust posture compact card | `workspace`, `trust`, `settings`; first useful chat authority context. | Trace/confirmation/approval cards exist, but no compact no-authority/trust posture card for ordinary screens. | Add trust-posture card variant for local/BYOK/egress state, confirmation floor, and trace availability. |
| Operator table/list density variants | `jobs`, `objectives`, `settings`, `trust`. | Table/list primitives exist, but scanning density and row actions are not uniformly variant-driven. | Add table/list density and row-state variants that preserve redaction and confirmation boundaries. |
| Wizard progress indicator | `onboarding`; QuickStart vs Advanced. | No shared wizard progress atom beyond generic tabs/status. | Add wizard progress/stepper variant compatible with web and CLI/TUI copy. |

## Pattern Gaps

| Gap | Composition rule / skeleton screen | Why it matters | v0.61 owner |
|---|---|---|---|
| Launch/resume first-run pattern | M2 Start group; M6 `launch`. | First-run must not degrade into a raw settings grid or a thin landing page. | Define launch/resume pattern with Home state, local-first posture, setup status, and resume action. |
| QuickStart onboarding shell pattern | M6 `onboarding`; M4 wizard. | v0.63 needs a seated wizard surface; v0.61 must provide the shell and first-run empty-state affordance. | Add reusable wizard shell pattern, step header, progress, review block, and repair callout shape. |
| First useful chat checkpoint pattern | M6 `workspace`; M1/M3 first-value definition. | The first chat must show provider/model/trust context and a safe next action. | Add chat-empty/first-chat pattern with model status, prompt suggestion, trace/trust compact card, and non-effectful suggestion list. |
| Model setup repair pattern | M6 `models`; M3 first-model-state. | Runtime missing, model missing, hardware floor, BYOK fallback, and blocked states need one repair language. | Add model-readiness repair pattern with status, next step, fallback, and egress warning slots. |
| Profile review diff pattern | M6 `onboarding`; M4 persona model. | Personas must remain seed-only and reviewable before settings writes. | Add settings/profile review diff pattern with setting keys, suggested apps/channels/intents, model-purpose mapping, and no-authority statement. |
| Grouped daily-use navigation pattern | All M6 screens. | The IA needs grouped nav that works on desktop and mobile without duplicating page-local nav. | Promote grouped navigation to a documented shell pattern. |
| Trust/audit summary pattern | M6 `trust`, `settings`, `workspace`. | Trust state should be inspectable without making confirmations look pre-approved. | Add trust summary pattern for confirmation status, trace availability, policy status, and no-authority copy. |
| Channel/app extension pattern | M6 `channels`; daily-use Extend group. | Channels are post-setup extensions, not first-run blockers. | Add extension setup pattern with disabled/unconfigured/configured/blocked states and explicit confirmation affordances. |
| Evidence-safe placeholder-to-real promotion pattern | All M6 screens. | v0.61 needs to replace previews with real screens without losing no-live-data test clarity during build. | Define promotion checklist: route ownership, live data source, registered actions, redaction, a11y, and skeleton removal criteria. |

## v0.61 Work Packages

1. **Shell and navigation variants.** Group-aware nav, active group/route,
   overflow/mobile behavior, and semantic shell depth.
2. **First-run and empty-state system.** Launch/resume, onboarding seat,
   first-chat checkpoint, suggested actions, and blocked repair states.
3. **Model and trust affordances.** First-model-state cards/badges, BYOK/local
   posture, no-authority trust card, and trace/confirmation summary patterns.
4. **Density and scanning.** Compact/default/comfortable variants for jobs,
   objectives, settings, trust, and model readiness lists.
5. **Motion and responsive roles.** Named transition roles and reduced-motion
   fallbacks for route, drawer, modal, wizard, and status changes.
6. **Brand/product surface tokens.** Product mark, restrained first-run emphasis,
   and landing/workspace brand application on top of ADR 0074.

## Guardrails

- v0.61 extends the token/variant/pattern system; it must not hand-roll per-page
  HEEx outside the catalog/shell boundary.
- Suggested actions and personas are not authority. The visual language must
  distinguish suggestion, confirmed action, disabled repair, and effectful action.
- Hosted/BYOK states must carry visible egress posture.
- Dark mode, high contrast, reduced motion, keyboard order, and focus states are
  validation requirements for every new variant/pattern.
- No v0.60 implementation is requested here. This is the ADR 0074 v0.61 input.
