# Information Architecture

Status: v0.60 M2 design artifact. This document is the concrete IA, navigation,
screen-composition, and preview-route manifest for ADR 0077. It is a design and
walking-skeleton contract; v0.60 preview routes are placeholders only.

## Scope

The v0.60 information architecture turns the current flat operator utility
inventory into a product hierarchy that supports the journey in
`docs/design/product-experience-spec.md`:

- install and first-run land in a start surface, not a raw config page.
- onboard is a guided product flow, not a settings subsection.
- first-value happens in a chat-primary workspace.
- daily-use groups work, operations, extensions, and trust surfaces by operator
  intent.

The IA uses the existing v0.58 surface catalog and app shell. It adds no new
rendering mechanism, Settings key, authority surface, capability, or live data
read. M6 may render placeholder previews for these routes; v0.61 owns the real
presentation implementation.

## Sitemap

```text
Allbert product shell
  Start
    /preview                  Launch and resume
    /preview/onboarding       Guided setup and first useful chat path

  Work
    /preview/workspace        Chat-primary workspace
    /preview/objectives       Objectives and multi-step work

  Operate
    /preview/jobs             Jobs, runs, and background activity
    /preview/models           Provider and model readiness

  Extend
    /preview/channels         Channel and app connections

  Trust
    /preview/settings         Settings, models policy, and surface policy
    /preview/trust            Confirmations, traces, and audit posture
```

Target live paths are owned downstream. The `/preview/*` namespace is a v0.60
walking-skeleton namespace, not the final route contract. Existing live routes
(`/`, `/workspace`, `/jobs`, `/objectives/:id`) stay in place while the skeleton
proves the redesigned hierarchy separately.

## Screen Inventory

| route_id | Screen | Product job | Current source relationship | Journey stage | Downstream owner |
|---|---|---|---|---|---|
| launch | Launch and resume | Explain local-first product posture, resume work, or start onboarding. | Reframes current thin `/` landing and workspace empty state. | first-run, daily-use | v0.61 screen composition; v0.62 first-run detection; v0.63 onboarding launch. |
| onboarding | Guided setup | Choose QuickStart or Advanced, review profile defaults, and move toward first useful chat. | Designs over ADR 0069/0075 without building wizard state. | onboard, first-value | v0.63 builds; v0.61 seats the surface; v0.62 supplies model hooks. |
| workspace | Workspace | Make chat the primary work surface with timeline, composer, status, and safe next actions. | Re-describes `/workspace` as product home rather than utility dashboard. | first-value, daily-use | v0.61 builds real chat-primary layout. |
| objectives | Objectives | Inspect durable goals, steps, acceptance, and resumable work. | Reframes `/objectives/:id` and objective cards as a work surface. | daily-use | v0.61 presentation hierarchy; existing Objectives substrate remains. |
| jobs | Jobs | Inspect scheduled/background activity without leaving product context. | Reframes `/jobs` under Operate. | daily-use | v0.61 presentation hierarchy. |
| models | Models | Show local/BYOK readiness and repair actions without hiding trust posture. | Pulls model/provider readiness out of undifferentiated settings. | first-run, onboard, daily-use | v0.61 presentation; v0.62 packaging hooks; v0.63 onboarding. |
| channels | Channels | Connect external surfaces after setup while preserving the same trust model. | Groups app/channel panels as extensions, not first-run prerequisites. | daily-use | v0.61 presentation; channel runtimes remain unchanged. |
| settings | Settings and policy | Keep operator-tunable configuration, model settings, intents, and surface policy understandable. | Reorganizes current operator panels without moving authority. | daily-use | v0.61 presentation; Settings Central remains authority for settings values. |
| trust | Trust and audit | Make confirmations, traces, grants, and policy evidence inspectable. | Collects existing confirmation/trace concepts into a first-class trust surface. | first-value, daily-use | v0.61 presentation; Security Central remains unchanged. |

## Navigation Model

The product navigation has five stable groups:

- Start: launch/resume and onboarding.
- Work: workspace and objectives.
- Operate: jobs and models.
- Extend: channels.
- Trust: settings/policy and audit posture.

Navigation rules:

- The shell exposes the same groups on desktop and mobile. Desktop may use an
  appbar plus rail; mobile may use a compact shellbar or grouped menu.
- Each screen has one `route_id`, one `active_key`, one title, and one nav group.
  These values must match the Preview Route Manifest so tests can compare docs to
  code.
- Workspace is the primary daily-use screen after onboarding. Launch and
  onboarding are start surfaces, not permanent dashboard tabs.
- Ephemeral surfaces are modals or temporary panels anchored to the current task.
  They are not primary navigation destinations.
- Effectful commands, provider setup, and external channel actions appear as
  confirmed actions later. In v0.60 previews they are inert placeholders only.
- The live `/workspace`, `/jobs`, and `/objectives/:id` routes remain unchanged
  until v0.61 implements the presentation overhaul.

## Workspace Composition

The workspace is chat-primary. Its stable zones are:

- Product shell: `workspace_shell` plus `nav_rail` present the IA groups, active
  route, and operator context.
- Primary work area: `chat`, `timeline`, and `composer` own the first useful chat
  and daily-use conversation loop.
- Context area: `thread_list`, `objective_card`, `status_badge`, and supporting
  panels explain current work without taking over the screen.
- Utility drawer: `utility_drawer`, `settings_panel`, `models_panel`,
  `surface_policy_panel`, and `intents_panel` expose secondary operator controls.
- Ephemeral layer: `ephemeral_surface`, `approval_card`, `confirmation_card`, and
  `trace_viewer` render temporary trust or inspection tasks without becoming nav
  roots.

Screen-composition rules:

- Every screen is anchored by the product shell and has one primary task.
- A screen may preview secondary panels, but the primary task must remain
  visually and semantically first.
- Onboarding surfaces explain choices before settings are seeded.
- Model/provider readiness belongs in the Models surface and onboarding path, not
  in a hidden setup note.
- Trust context appears wherever first useful chat or effectful next actions are
  shown.
- Placeholders in M6 use known catalog atoms only and must not read business
  state, call providers, submit actions, or imply permission.
- High contrast, reduced motion, keyboard navigation, and focus order apply to
  every placeholder screen because v0.61 inherits this shell.

## Preview Route Manifest

| route_id | preview_path | title | nav_group | active_key | catalog_components |
|---|---|---|---|---|---|
| launch | /preview | Launch and resume | start | start_launch | workspace_shell, nav_rail, empty_state, status_badge, button |
| onboarding | /preview/onboarding | Onboarding | start | start_onboarding | workspace_shell, nav_rail, onboarding_panel, models_panel, status_badge |
| workspace | /preview/workspace | Workspace | work | work_workspace | workspace_shell, nav_rail, chat, timeline, composer, utility_drawer, status_badge |
| objectives | /preview/objectives | Objectives | work | work_objectives | workspace_shell, nav_rail, objective_card, timeline, status_badge |
| jobs | /preview/jobs | Jobs | operate | operate_jobs | workspace_shell, nav_rail, job_card, table, status_badge |
| models | /preview/models | Models | operate | operate_models | workspace_shell, nav_rail, models_panel, settings_card, status_badge |
| channels | /preview/channels | Channels | extend | extend_channels | workspace_shell, nav_rail, channel_card, settings_card, status_badge |
| settings | /preview/settings | Settings and policy | trust | trust_settings | workspace_shell, nav_rail, settings_panel, surface_policy_panel, intents_panel |
| trust | /preview/trust | Trust and audit | trust | trust_audit | workspace_shell, nav_rail, trace_viewer, confirmation_card, approval_card, status_badge |

M6 `AllbertAssistWeb.Skeleton.RouteManifest` must mirror this table row-for-row.
The test should fail before route smoke if any route id, preview path, title, nav
group, active key, or catalog component list drifts from this manifest.

## M6 And M7 Handoff

M6 implements one placeholder route per manifest row under the flag-gated
`/preview` namespace. The route body should prove shell, active navigation, title,
placeholder composition, at least one route-specific composition zone from the
manifest, keyboard/focus accessibility, reduced-motion behavior, and
no-authority/no-live-data invariants. It should not attempt the v0.61 visual
overhaul. The route-specific zone can be a safe placeholder for a component that
would otherwise read live state in production. The implementation may use one shared
`AllbertAssistWeb.Skeleton.PreviewLive` with route actions for every manifest row;
that is intentional when the route manifest remains the source of truth and each
route action resolves its own title, nav group, active key, and placeholder
composition from the manifest.

M7 compares these screens and composition rules with the v0.58 token/component
substrate. Any missing token, responsive behavior, component variant, empty-state
pattern, onboarding pattern, or trust affordance is a v0.61 input, not a v0.60
implementation escape hatch.
