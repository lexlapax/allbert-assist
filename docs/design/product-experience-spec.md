# Product Experience Spec

Status: v0.60 M1 design artifact, amended after v0.63 product-readiness review.
This document defines the target 1.0 product experience for the non-developer
local-first operator. It is a design contract for v0.61-v0.66, not a claim about
current implementation.

## Purpose

Allbert should feel like a coherent local-first assistant product before it
feels like a collection of runtime pieces. The operator should understand how to
install it, reach a useful first run, onboard through an opinionated model path,
get to first-value, and return for daily-use without learning the internal
architecture first.

This spec is the journey source for:

- M2 information architecture and navigation.
- M3 First-Model Path.
- M4 onboarding flow and persona model.
- M5 entry-point and CLI UX.
- M6 walking skeleton routes.
- M7 design-system gap analysis.

v0.60 adds no runtime authority, no Settings key, no capability, and no live
provider behavior. The implementation owners named here are downstream release
owners.

## Audience

The target operator is a non-developer local-first user: willing to install a
trusted local app and make clear choices about local vs hosted model use, but
unwilling to debug raw Phoenix, Elixir, provider keys, or config files before
seeing product value.

The experience should respect operator competence without making setup feel like
a source checkout. Advanced paths remain visible, but the default path is
opinionated and fastest-to-value.

## First-Value Definition

The first-value moment is **first useful chat**:

An operator starts from a clean Allbert Home, reaches a model-backed conversation
inside Allbert, asks a task-relevant question, receives a useful answer, and can
see enough local trust context to continue: provider/model state, what authority
was not granted, and the next safe action.

First useful chat is not just "a model responded." It requires:

- A reachable local or BYOK model path.
- A clear surface for the conversation.
- A plain indication of provider/model status.
- No hidden permission grant or egress authority.
- A follow-on action that does not strand the operator in setup.

M3 operationalizes this definition. M4 turns it into onboarding flow. M5 gives
it entry-point behavior. v0.64 makes it trusted and repairable, v0.65 grounds it
in local files/notes/memory, and v0.66 validates it across the integrated
product.

## Journey Map

| Stage | Operator goal | Primary surfaces | What good looks like | Sub-1.0 failure modes | Owning release(s) |
|---|---|---|---|---|---|
| Install | Get Allbert onto the machine without becoming a project contributor. | Packaged binary, terminal, installation docs, OS vault prompt, optional web handoff. | One obvious trusted install path; `allbert --help` works; `allbert serve` starts the product; no Elixir/OTP source workflow is required for normal use. | Git clone as the default install; Mix commands as product entry points; unclear binary layout; secrets stored outside the OS vault story; installer verification deferred or unclear. | v0.62 implements packaging and entry points; v0.64 closes trusted install and rollback posture. |
| First-run | Understand what Allbert is doing locally and choose the next setup step. | CLI first invocation, daemon/server startup, web landing or workspace empty state, TUI handoff. | Fresh Home is detected; the operator sees a local-first trust posture; the product routes to onboarding or a resume path; blocked states show one repair action; no blank configuration wall appears. | Blank workspace; raw settings page as first screen; unclear Home location; no explanation of provider/model state; commands that diverge between web, CLI, and TUI. | v0.61 implements landing and empty-state composition; v0.62 implements first-run detection; v0.63 implements onboarding launch; v0.64 makes blocked states repairable. |
| Onboard | Pick an opinionated path that matches skill level and provider preference. | Web wizard, terminal wizard, provider/model doctor, persona/profile review. | QuickStart offers assisted-local by default with BYOK fallback; Advanced exposes explicit choices; personas are reviewed before seeding settings; provider checks are specific and repairable. | API key prompt as the first meaningful step; unreviewed persona defaults; model installation instructions detached from the wizard; hidden settings writes; no fallback when local model setup is blocked. | v0.63 implements the guided onboarding and profiles; v0.62 supplies packaging hooks for model setup; v0.61 supplies the screen shell. |
| First-value | Complete first useful chat and know what to do next. | Chat-primary workspace, model/provider status, local notes/files prompts, memory review, trace/trust affordances. | The operator asks a real question, gets a useful response, sees model and authority posture, can connect local notes/files, and can review what becomes memory without granting surprise permission. | Model not reachable after setup; answer appears without trust context; setup is "complete" before any useful chat; no suggested next step; effectful actions look enabled before confirmation; memory appears automatic or opaque. | v0.63 owns the first useful chat checkpoint; v0.64 repairs first-run; v0.65 owns local files/notes/memory; v0.66 proves the path. |
| Daily-use | Return to Allbert for repeated local work across web, CLI/TUI, channels, notes, and memory. | Workspace, objectives/jobs, settings and model panels, local knowledge panels, audit/trace surfaces, CLI/TUI commands, configured channels. | The product opens where work continues; durable traces, objectives, local notes/files, and reviewed memory are inspectable; settings/models are understandable; CLI/TUI and channel surfaces use the same mental model as web; export/import confidence is visible. | Utility dashboard sprawl; routes without product hierarchy; command names that do not match the product; lost traces or unclear Home portability; channel setup detached from the core trust model; local files or memory feel like hidden side effects. | v0.61 implements presentation hierarchy; v0.62 implements durable product entry points; v0.63 applies profiles; v0.64 repairs first-run; v0.65 grounds local knowledge; v0.66 validates end-to-end use. |

## Cross-Surface Contract

Web is the primary product surface for first-run, onboarding, first-value, and
daily-use scanning. It must feel like the place where the product is operated,
not a debug console over the runtime.

CLI/TUI are product entry and control surfaces. They should start, inspect,
repair, and resume the same product state the web surface presents. They are not
separate conceptual products.

Channels are daily-use extensions after setup. They should inherit Allbert's
existing runtime, permission, trace, and settings posture. Channel setup must not
be the first place the operator learns the product's trust model.

All surfaces must preserve Security Central as the authority boundary. Product
copy, onboarding choices, persona labels, and generated content do not grant
permission.

## Downstream Ownership

| Release | Owns | Consumes from this spec | Must not reinterpret |
|---|---|---|---|
| v0.61 Presentation Layer Overhaul | Information architecture, navigation, screen composition, landing and empty states, chat-primary workspace craft. | The five-stage journey, first-run and first-value surface expectations, daily-use hierarchy. | First useful chat is the product's value moment; web is the primary product surface. |
| v0.62 Packaging & Entry Points | Binary/distribution shape, unified `allbert` command taxonomy, daemon/server entry, first-run detection, model setup hooks. | Install and first-run expectations, CLI/TUI contract, First-Model Path packaging implications. | Normal users should not need source checkout or Mix commands as product entry points. |
| v0.63 Guided Onboarding & Profiles | QuickStart and Advanced wizard tracks, profile/persona review, provider/model checks, first useful chat checkpoint. | Onboard and first-value expectations, M3 First-Model Path, persona constraints. | Onboarding is complete only when the operator can reach first useful chat or sees a repairable blocker. |
| v0.64 Trusted Install And Non-Developer First Run | Installer trust, package-first docs, repairable first-run, model setup repair, trust-spine presentation. | Install, first-run, onboard, first-value expectations. | Trust and repair must be part of first-run, not deferred to RC evidence. |
| v0.65 Local Knowledge | Local files/notes and reviewed memory as the launch-critical first assistant workflow. | First-value and daily-use expectations. | Local file access and memory must feel explicit, scoped, and reviewable. |
| v0.66 Product RC | Integrated journey validation, no-docs validation, and advanced-surface regression evidence. | The complete install -> first-run -> onboard -> local-knowledge -> first-value -> daily-use path. | A green runtime gate is not enough if the product journey strands the operator. |
| v1.0 | Freezes public presentation/product contracts after the redesign has landed. | v0.60 design decisions as implemented through v0.61-v0.66. | Late structural redesign after freeze is contract churn. |

## Failure Modes To Design Against

- Toolchain install friction: the normal path starts from source checkout, Mix,
  or Phoenix instructions.
- Blank-field first-run: the first screen asks for raw config before explaining
  the product path.
- No first model: setup appears successful but no local or BYOK model can answer.
- No first useful chat: the operator configures things but never reaches value.
- Undifferentiated config: settings, models, personas, and channels appear as one
  flat admin surface.
- Hidden authority: suggested actions, provider setup, or personas imply
  permission that Security Central did not grant.
- Surface drift: web, CLI/TUI, and channels use different names for the same
  product concepts.
- Design-as-you-go drift: downstream releases reinterpret the journey instead of
  consuming this shared spec.

## Handoff Requirements

M2 must turn this journey into a sitemap, screen inventory, navigation model, and
workspace composition rules. M2 is responsible for preserving the five-stage
journey in route and navigation language.

M3 must convert first useful chat into the concrete First-Model Path: assisted
local by default, BYOK fallback, and managed-hosted rejected unless a later ADR
reopens that decision.

M4 must design onboarding as the operator-facing path from fresh Home to first
useful chat. It must distinguish QuickStart from Advanced without hiding what
settings or profiles will be applied.

M5 must design product entry points so install and first-run behavior are not
left to package implementation. Command names, first-run detection, daemon/server
startup, and wizard launch all come from this journey.

M6 must implement only a navigable placeholder skeleton for the M2 IA. Its
screens may prove route, shell, and nav behavior, but they must not read live
business state or grant authority.

M7 must compare the M2/M6 composition against the v0.58 design-system substrate
and identify token, component, pattern, motion, accessibility, and responsive
gaps for v0.61.

M8 must verify this artifact is present, covers install, first-run, onboard,
first-value, and daily-use, names first useful chat, and maps each stage to its
owning downstream release.
