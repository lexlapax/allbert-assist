# Operator Workspace

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

Introduced in v0.58 and consolidated into the single shell in v0.61b (ADR 0080).
Allbert 1.2 starts first run in chat. A detected usable provider answers
the first question without a setup click; a missing or unhealthy model keeps
chat open and routes to one state-appropriate Models repair action. Onboarding
is optional, and confirmed local pulls stream progress in the workspace (see
[onboarding.md](onboarding.md)).

The operator workspace is [http://localhost:4000/workspace](http://localhost:4000/workspace).
It is the primary browser surface over the existing authority spine.

## Workspace At A Glance

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

For a v1.1 fan-out, the originating conversation receives the kickoff and then
the joined child report. The kickoff does not release child execution until its
exact hidden delivery marker mounts in that browser; a stale/forged marker or
failed acknowledgement leaves kickoff pending and every child open. Multiple
completed fan-outs may be visible at once; the browser acknowledges each exact
report only after its DOM marker mounts. If that acknowledgement fails, the
report remains visible, an error explains that delivery was not recorded, and
it remains pending for the next turn.

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

## Fan-Out Objective Controls

The Objectives index refreshes from durable lifecycle signals. An objective
detail page shows the parent/child tree, terminal outcomes, and the authoritative
joined projection. A mixed result is `partial`, not success; all-cancelled work
is `cancelled`. Steer and cancel controls re-prove the signed-in operator owns
the objective, the child belongs to the displayed parent, and the child is still
active. A stale, forged, or cross-parent child id changes nothing and produces a
bounded error.

These are attached Web controls. Rendering a local report does not opt the
operator into default-off remote autonomous notifications.

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

## Suggestions Surface (v1.8 Planned)

v1.8 adds profiling cards to the shared Suggestions surface. A card is inert:
it shows one exact proposed Settings change, its expected current value,
evidence window/sample count, expiry, and observed-outcome state. It never
changes a setting merely because it is displayed, highly scored, repeated, or
sent to a remote channel.

Apply, dismiss, and revert dispatch registered actions. Apply and revert use
separate durable confirmations; a stale card or intervening Settings edit
writes nothing. Remote notifications contain only a deterministic pointer back
to Suggestions and never carry approval controls.

The growing card list uses stable streamed row identities so LiveView updates do
not duplicate or silently replace cards. The workspace owns rendering and event
dispatch only; Settings comparison, confirmation binding, operation recovery,
and outcome classification stay behind runtime actions.

## Surface-Policy Panel

Surface policy controls presentation governance per surface/action:

- `operator_report` vs `assistant_summary` eligibility;
- redaction and display profile;
- row/count bounds;
- explicit affordance required for raw or expanded reports.

Surface policy does not grant authority. If Security Central denies an action or a
confirmation is required, policy cannot override that decision.

## Release Validation Is Separate

For the current release, follow its active request-flow document under
[`docs/plans`](../plans/README.md). Historical evidence belongs with archived
request flows; ordinary workspace use does not require a validation transcript.
Release evidence is kept outside the repository under:

```text
$HOME/.allbert-release-evidence/<version>
```

Expected evidence includes browser screenshots, CLI output, one warm TUI
transcript, public-protocol JSON responses, redaction proof, and final settings
guard output. Do not commit raw screenshots, transcripts containing secrets, raw
tokens, or local evidence directories.

### v1.8 mobile-web validation

The packaged web service remains loopback-bound by default. v1.8 acceptance uses
measured Chromium and WebKit browser runs at 320 CSS pixels, 390×844 portrait,
and 844×390 landscape, including 400% reflow, 200% text resize, keyboard order,
visible/not-obscured focus around sticky controls, target sizing, horizontal
overflow, and console cleanliness. Browser emulation is not proof of physical-
device dynamic-toolbar behavior; that real-device row belongs to the later
responsive-information-architecture stage. Authenticated/configurable non-local
access also remains v1.7 scope.

## Operating Invariants

Expected:

- chat-primary layout is default;
- Conversations label appears only in UI strings;
- canvas opens as a docked resizable pane (never a floating overlay);
- ephemerals are accessible modals/popovers;
- panels render action-backed DTOs with redaction;
- `/jobs` and `/objectives` use the shared shell and tokens;
- joined fan-out reports are visible before their individual delivery receipts
  are acknowledged;
- parent/child controls fail closed for stale, forged, or cross-parent ids;
- warm TUI, CLI, and web panel DTOs agree;
- MCP/OpenAI public smokes expose only public-safe tools.

Stop and investigate if:

- web reads settings, confirmations, descriptor stores, or business stores
  directly from LiveView code;
- internal operator reads appear in public-protocol tool lists;
- a panel displays raw secrets, endpoints, prompts, provider bodies, or raw
  descriptor/evidence payloads;
- surface policy changes permission, confirmation, or egress behavior;
- the layout revives `/agent` or `/settings` as compatibility routes.
