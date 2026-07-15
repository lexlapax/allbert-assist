# Operator Workspace

Introduced in v0.58; consolidated into the single shell in v0.61b (ADR 0080); current
packaged behavior as of v0.64.3, where packaged first run starts from the service/browser
path, first-run auto-opens onboarding, missing-model states route to the standalone
Models repair panel, and curated model pulls stream live progress in the web workspace
(see [onboarding.md](onboarding.md)).

The operator workspace is `/workspace`. v0.58 keeps that route and changes the
layout and panels on top of the existing authority spine.

## What Changed In v0.58 (baseline; presentation since revised by v0.61/v0.61b)

- Chat is the primary surface.
- **Conversations** (UI label only) is a contextual section under the product
  sidebar's Workspace entry (v0.61b) with inline thread rename.
- The canvas/tool region opens as a right-docked resizable pane beside chat
  (v0.61b); nothing floats over the conversation.
- Approval and other ephemeral surfaces appear as modals or popovers.
- Intents, Settings/Models, and Surface-Policy panels are first-class operator
  panels.
- `/jobs` and `/objectives` share the same shell and design-system tokens.

The "Conversations" label is UI-only. It does not rename internal thread,
session, event, topic, settings, or database concepts.

## Authority Boundary

The workspace renders and dispatches. It does not own authority.

- User turns still go through the runtime.
- Operator reads and mutations go through registered actions.
- Security Central still makes permission decisions.
- Settings Central remains the only operator-tunable config authority.
- Surface policy governs report shape and redaction, not permission.

A panel may show a diagnostic or an affordance. It cannot make an internal action
public, lower confirmation floors, bypass confirmation, or grant egress.

## Conversations And Chat

Use the Conversations rail to create or switch conversation history. The chat
timeline and composer stay visible as the primary workspace surface. Streaming
responses should remain in the chat column; canvas output should be opened only
when the operator chooses it.

## Docked Canvas Pane

Use the sidebar's workspace destinations (or the chat-header Canvas button) for
durable output tiles, app panels, and artifact-like views — they open in the
right-docked resizable pane beside chat (drag the divider; double-click resets;
the divider button or Cmd/Ctrl+\ collapses it; a slim right-edge tab reopens
it). Opening a destination replaces the canvas content and closing it restores
the canvas, without losing the conversation or selected context. The sidebar
itself collapses with the chevron (or Cmd/Ctrl+B) to an icon rail — the
Workspace icon opens the sections as a flyout — and Cmd/Ctrl+Shift+B hides it
fully (reopen with the left-edge tab).

## Modal Ephemerals

Approvals, clarification prompts, and short-lived operator decisions should appear
as modals or popovers with keyboard focus, Esc dismissal, and visible action
buttons. Treat a modal as a temporary decision surface, not a separate route.

## Intents Panel

The Intents panel shows routing coverage, descriptor source badges, slot counts,
eval/gate status, and review queue state. Mutations such as promotion or disabling
a descriptor are explicit operator actions. A regressing promotion must show the
ADR 0071 gate diagnostic and commit no mutation.

## Settings/Models Panel

The Settings/Models panel shows the same model recommendation and configuration
state as the package-safe admin model/status commands:

```sh
allbert admin models list
allbert admin models doctor openai
```

The panel should show bounded, redacted status and diagnostics. Raw provider
responses, endpoint URLs, API keys, and secret refs must not be displayed.

## Surface-Policy Panel

Surface policy controls presentation governance per surface/action:

- `operator_report` vs `assistant_summary` eligibility;
- redaction and display profile;
- row/count bounds;
- explicit affordance required for raw or expanded reports.

Surface policy does not grant authority. If Security Central denies an action or a
confirmation is required, policy cannot override that decision.

## Manual Validation Evidence

For the current release, follow `docs/plans/archives/v0.65-request-flow.md`, then the
matching request-flow document for later releases. Historical v0.58 validation
followed `docs/plans/archives/v0.58-request-flow.md`; evidence is kept
outside the repository under:

```text
$HOME/.allbert-release-evidence/<version>
```

Expected evidence includes browser screenshots, CLI output, one warm TUI
transcript, public-protocol JSON responses, redaction proof, and final settings
guard output. Do not commit raw screenshots, transcripts containing secrets, raw
tokens, or local evidence directories.

## Pass/Fail Summary

Pass:

- chat-primary layout is default;
- Conversations label appears only in UI strings;
- canvas opens as a docked resizable pane (never a floating overlay);
- ephemerals are accessible modals/popovers;
- panels render action-backed DTOs with redaction;
- `/jobs` and `/objectives` use the shared shell and tokens;
- warm TUI, CLI, and web panel DTOs agree;
- MCP/OpenAI public smokes expose only public-safe tools.

Fail:

- web reads settings, confirmations, descriptor stores, or business stores
  directly from LiveView code;
- internal operator reads appear in public-protocol tool lists;
- a panel displays raw secrets, endpoints, prompts, provider bodies, or raw
  descriptor/evidence payloads;
- surface policy changes permission, confirmation, or egress behavior;
- the layout revives `/agent` or `/settings` as compatibility routes.
