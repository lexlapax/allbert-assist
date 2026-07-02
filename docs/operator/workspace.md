# Operator Workspace

Status: released v0.58 operator guide.

Note: this guide describes the released/current workspace behavior through
v0.61.0. The planned v0.61b point release supersedes the Canvas Drawer guidance
with ADR 0080's consolidated sidebar and docked workspace pane at closeout; until
that ships, keep this page as the released operator reference.

The operator workspace is `/workspace`. v0.58 keeps that route and changes the
layout and panels on top of the existing authority spine.

## What Changes In v0.58

- Chat is the primary surface.
- The left rail uses the UI label **Conversations**.
- The canvas opens from a launcher/drawer instead of occupying a co-equal pane.
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

## Canvas Drawer

Use the canvas launcher for durable output tiles, app panels, and artifact-like
views. Closing the drawer should return to the chat-primary workspace without
losing the conversation or selected context.

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
state as:

```sh
mix allbert.settings model-doctor
mix allbert.model list
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

For v0.58 release validation, follow
`docs/plans/v0.58-request-flow.md`. Evidence is kept outside the repository under:

```text
$HOME/.allbert-release-evidence/v058
```

Expected evidence includes browser screenshots, CLI output, one warm TUI
transcript, public-protocol JSON responses, redaction proof, and final settings
guard output. Do not commit raw screenshots, transcripts containing secrets, raw
tokens, or local evidence directories.

## Pass/Fail Summary

Pass:

- chat-primary layout is default;
- Conversations label appears only in UI strings;
- canvas opens as a drawer;
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
