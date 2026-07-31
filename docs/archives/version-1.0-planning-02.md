# Allbert v1.0 Strategic Replanning Memo

Date: 2026-05-26  
Status: planning recommendation, not yet roadmap authority  
Context: Allbert has released `v0.37.5`; `v0.38` is currently the next planned
milestone.

## Purpose

This memo records a holistic recommendation for what Allbert 1.0 should look
like from an end-user perspective, using the current Allbert roadmap, plans,
future-features parking lot, ADRs, code posture, and current external research
on OpenClaw and Hermes Agent.

The central question is:

Should Allbert proceed with `v0.38` as planned, or insert one or more
user-facing feature milestones before it, and what should the path to 1.0 be?

## Sources Reviewed

Local project sources:

- [`README.md`](README.md)
- [`DEVELOPMENT.md`](DEVELOPMENT.md)
- [`CHANGELOG.md`](CHANGELOG.md), especially `v0.37.5`
- [`docs/plans/roadmap.md`](docs/plans/roadmap.md)
- [`docs/plans/future-features.md`](docs/plans/future-features.md)
- [`docs/plans/allbert-jido-vision.md`](docs/plans/allbert-jido-vision.md)
- [`docs/plans/archives/v0.38-plan.md`](docs/plans/archives/v0.38-plan.md)
- [`docs/plans/archives/v0.38-request-flow.md`](docs/plans/archives/v0.38-request-flow.md)
- [`docs/developer/agent-context-map.md`](docs/developer/agent-context-map.md)
- [`docs/adr/0013-uri-first-resource-identity.md`](docs/adr/0013-uri-first-resource-identity.md)
- [`docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md`](docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md)
- [`docs/adr/0021-intent-objective-capability-and-advisory-boundary.md`](docs/adr/0021-intent-objective-capability-and-advisory-boundary.md)
- [`docs/adr/0023-workspace-canvas-and-ephemeral-surface-substrate.md`](docs/adr/0023-workspace-canvas-and-ephemeral-surface-substrate.md)
- [`docs/adr/0036-templated-creation-and-pattern-registry.md`](docs/adr/0036-templated-creation-and-pattern-registry.md)
- Current code boundaries in `apps/allbert_assist/lib/allbert_assist/`, especially
  `Runtime`, `Actions.Registry`, `Actions.Runner`, `Settings.Schema`,
  `Channels`, `Resources.ResourceURI`, `Resources.OperationClass`, and
  `App.SurfaceProvider`.

External research sources:

- [OpenClaw homepage](https://openclaw.ai/)
- [OpenClaw docs overview](https://docs.openclaw.ai/)
- [OpenClaw features](https://docs.openclaw.ai/concepts/features)
- [OpenClaw channels](https://docs.openclaw.ai/channels)
- [OpenClaw capabilities overview](https://docs.openclaw.ai/tools)
- [OpenClaw provider directory](https://docs.openclaw.ai/providers)
- [OpenClaw MCP CLI](https://docs.openclaw.ai/cli/mcp)
- [OpenClaw security docs](https://docs.openclaw.ai/gateway/security)
- [Hermes Agent homepage](https://hermes-agent.ai/)
- [Hermes features overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/overview/)
- [Hermes messaging gateway](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/)
- [Hermes MCP](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp)
- [Hermes API server](https://hermes-agent.nousresearch.com/docs/user-guide/features/api-server)
- [Hermes ACP editor integration](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp)
- [Hermes personality / SOUL.md](https://hermes-agent.nousresearch.com/docs/user-guide/features/personality)
- [Hermes plugins](https://hermes-agent.nousresearch.com/docs/user-guide/features/plugins)

## Executive Recommendation

Ship `v0.38` next as planned. Do not insert a new feature milestone before it.

The reason is that `v0.38` is the deterministic creation substrate that makes
the next phase cheaper and safer. `v0.37` proved dynamic generation and gated
live action integration. `v0.38` turns known, reviewed shapes into repeatable
templates: plugins, apps, LLM tools, scheduled/chron flows, objective workflows,
and future reviewed code patterns. It explicitly reuses the `v0.36` sandbox and
`v0.37` loader without adding new authority. That is the right bridge before
we broaden Allbert's user-facing capability surface.

However, after `v0.38`, the roadmap should pivot from substrate-first milestones
to an end-user 1.0 arc. OpenClaw and Hermes both show that a 1.0-feeling
personal assistant is not defined by one brilliant internal runtime feature. It
is defined by reachable, everyday usefulness:

- easy first-run setup;
- model/provider choice;
- messaging channels where the user already lives;
- persistent memory and identity;
- tools/integrations for real work;
- browser and web research;
- MCP ecosystem access;
- media input/output;
- plan/review/execute workflows;
- plugins/skills distribution;
- API/editor/protocol access for power users.

Allbert has a stronger safety and inspectability foundation than those systems:
Security Central, durable confirmations, Resource Access, markdown-first memory,
Objective Runtime, signed workspace fragments, sandbox/gate reports, and gated
dynamic integration. The 1.0 challenge is to use that safety architecture to
broaden capability, not to keep building foundations in isolation.

## Competitive Positioning

### OpenClaw

OpenClaw is the closest comparator because it is self-hosted, channel-heavy,
local-first, and personal-assistant oriented. Its official docs position it as
a gateway that connects many chat apps and channel surfaces to an agent runtime.
It emphasizes:

- many simultaneous channels, including Discord, iMessage, Signal, Slack,
  Telegram, WhatsApp, WebChat, and more;
- bundled and third-party channel plugins;
- media support for images, audio, video, and documents;
- model-provider breadth, including local and OpenAI-compatible endpoints;
- browser automation, exec, sandboxing, web search, cron jobs, heartbeat
  scheduling, skills, plugins, and workflow pipelines;
- a public registry for skills and plugins through ClawHub;
- MCP server behavior and an OpenClaw-owned registry for outbound MCP server
  definitions.

OpenClaw's user promise is: send a message from anywhere and let the assistant
act across real tools.

Allbert's equivalent strength is not channel breadth yet. It is the authority
model underneath action. Allbert should not try to copy OpenClaw's surface area
all at once. It should prioritize the few features that multiply usefulness
while preserving the action/security/resource model.

### Hermes Agent

Hermes is the broader agent-platform comparator. Its feature docs emphasize:

- persistent memory and project context files;
- skills compatible with the Agent Skills style;
- scheduled tasks and subagent delegation;
- code execution through sandboxed RPC;
- voice, TTS, browser automation, vision/image paste, and image generation;
- MCP client and server integration;
- provider routing, fallback providers, credential pools, and memory providers;
- an OpenAI-compatible API server;
- ACP editor integration;
- personality customization through `SOUL.md`;
- plugins for tools, hooks, integrations, memory providers, context engines,
  model providers, and media backends.

Hermes demonstrates the expected 2026 feature set for a serious personal agent:
MCP, media, browser, API, editor integration, provider control, and plugin
distribution.

Allbert should copy the capability classes, not necessarily the implementation
style. Hermes permits plugin code in ways Allbert deliberately avoids or gates.
Allbert should preserve the rule that metadata, plugin declarations, advisory
provider output, and generated files never grant permission by themselves.

## Allbert's Current Strategic Advantages

Allbert has several advantages that should be defended:

1. **One effectful action boundary.** Runtime-facing action invocation resolves
   through `AllbertAssist.Actions.Registry` and executes through
   `AllbertAssist.Actions.Runner.run/3`. This is the right place to add MCP,
   browser, media, channel, and integration actions.

2. **Security Central and durable confirmations.** Sensitive work can already
   be represented, confirmed, resumed, traced, and audited instead of hidden
   inside an agent loop.

3. **URI-first Resource Access.** ADR 0013 already reserves `mcp://`,
   `agent://`, and `agent+https://` as inert resource identities. That gives MCP
   and future agent endpoints a place to land without inventing a new permission
   model.

4. **Markdown-first memory.** Allbert memory remains inspectable, portable, and
   operator-owned. That is more consistent with long-term personal assistant
   trust than opaque memory providers alone.

5. **Objective Runtime.** Durable multi-step work already exists. Plan/Build
   mode should be an operator surface over this substrate, not a parallel
   planning runtime.

6. **Workspace and Surface DSL.** Allbert already has declarative, validated
   surfaces, Canvas, signed Fragments, offline editing, and app panels. UI
   protocol interop can adapt this model instead of accepting arbitrary
   generated HTML or iframe authority.

7. **Sandbox/gate plus dynamic integration.** `v0.36` and `v0.37` create a
   rare safety story for generated code: report-only sandbox evidence first,
   trusted validation, then operator-confirmed reversible live integration.

8. **Templated creation is ready.** `v0.38` is the right mechanism to speed up
   channel, integration, provider, and workflow creation after the foundation.

## User-Facing Gaps Before 1.0

From an end-user perspective, the current gaps are:

1. **First-run onboarding.** A new user should not need to mentally assemble
   Allbert Home, provider keys, local model setup, channels, sandboxes, jobs,
   and first workflows from scattered docs. The future-features parking lot
   already names operator first-run onboarding.

2. **Provider/model control.** Allbert already has provider and model profile
   schema entries for local Ollama, OpenAI, Anthropic, and OpenRouter. The gap
   is a polished control plane: CLI/workspace/channel model switching,
   validation, provider doctor checks, and clear fallback behavior.

3. **MCP client integration.** The rest of the agent ecosystem increasingly
   treats MCP as the interoperability layer. Allbert has reserved resource
   identity but no execution path yet.

4. **General personal integrations.** StockSage proves the app/plugin model,
   but it is not a universal personal-assistant use case. 1.0 needs at least a
   first wave of everyday integrations such as calendar, mail, GitHub, and
   notes/files.

5. **Browser and research.** Approved URL fetches are not enough to match the
   OpenClaw/Hermes user expectation of web research and browser operation.
   Browser state, cookies, screenshots, forms, and memory extraction need a
   stricter Resource Access policy.

6. **Channel reach.** Telegram and email prove the adapter model. Discord and
   Slack should come next because they stress group/team identity, mentions,
   callbacks, and threaded replies without jumping immediately into mobile
   protocol fragility.

7. **Plan/Build mode.** Allbert has confirmations at the action level, but not
   yet a high-level "show me the plan, let me approve it, then run it" product
   mode.

8. **Voice and vision.** Hermes and OpenClaw make media feel expected. Allbert
   should add audio and image resource classes rather than bolt media directly
   into channels.

9. **Marketplace/distribution.** Allbert has local skills/plugins and soon
   templates, but not a reviewed skill/plugin discovery path. Code-bearing
   marketplace installs should remain later and stricter.

10. **API/editor/protocol interop.** Hermes exposes an OpenAI-compatible API
    server and ACP editor mode. OpenClaw exposes gateway/MCP/protocol surfaces.
    Allbert should expose these after the internal policy and workspace
    contracts are stable.

## Architecture Analysis

### What Is Ready To Reuse

The following substrates are ready and should be reused for v1.0 work:

- `AllbertAssist.Runtime.submit_user_input/1` for channel and API ingress.
- `AllbertAssist.Actions.Registry` and `Actions.Runner.run/3` for all
  effectful operations.
- Security Central and confirmations for permissioned execution.
- Resource Access URI identity for local files, URLs, packages, skills, MCP,
  and future agents.
- Settings Central and encrypted secrets for provider, channel, MCP, browser,
  and media configuration.
- Channel adapter boundary from Telegram/email.
- Plugin contract for source-tree extensions.
- App/surface contract for workspace panels and Canvas destinations.
- Objective Runtime for multi-step and Plan/Build workflows.
- Workspace Surface DSL and signed Fragment path for rich UI without arbitrary
  generated UI authority.
- v0.36/v0.37 sandbox/gate/live-loader path for generated code.
- v0.38 templates after they ship.

### What Needs New ADRs

These areas need focused ADRs before implementation:

1. **MCP client trust and execution.**
   MCP server schemas must be descriptive, not authority. Allbert should add
   explicit permission classes, resource identities, server config, per-tool
   allow/deny policy, confirmation floors, redaction, trace, audit, and evals.

2. **Browser session and web research policy.**
   Browser automation is not just URL fetch. It includes sessions, cookies,
   screenshots, page DOM, form fill, downloads, and potential memory promotion.
   It needs a resource model such as `browser://session/<id>` plus per-domain
   and per-operation grants.

3. **Media resource classes.**
   Microphone input, audio output, image upload, screenshot capture, generated
   image/video, and document upload need URI identity, retention, redaction,
   provider settings, and confirmation rules.

4. **Public protocol/API exposure.**
   API server, ACP, AG-UI/A2UI, and MCP server modes expose Allbert to external
   clients. They need auth, rate limits, ownership, cross-client concurrency,
   confirmation ownership, CSP review, redaction, and audit rules.

### What Does Not Need A New ADR First

These can likely be planned as implementation milestones using existing
architecture:

- first-run onboarding;
- provider/model control-plane UX;
- Discord and Slack channel adapters;
- first-wave native integration apps;
- skill-only marketplace discovery;
- Plan/Build workspace surface over Objective Runtime.

## System Design Recommendations

### MCP

MCP should be the first ecosystem unlock after onboarding/provider control.
Hermes registers tools from stdio and HTTP MCP servers, supports filtering, and
can expose itself as an MCP server. OpenClaw exposes channel conversations via
MCP server mode and stores outbound MCP server definitions centrally.

Allbert should start with MCP client behavior, not MCP Apps UI:

- Settings Central namespace: `mcp.servers.*`.
- Secret refs for headers/env/tokens.
- Transports: stdio first, streamable HTTP second.
- Server enablement default off.
- Per-server and per-tool include/exclude policy.
- MCP resources represented through `mcp://<server-id>/<encoded-uri>`.
- MCP tool calls executed only through registered Allbert actions.
- Security Central permission class such as `:mcp_tool_call`.
- Confirmation floor for write/execute/external side effects.
- Read-only resource utility actions only when the MCP server advertises
  capability and Allbert policy allows it.
- No MCP tool schema should become permission authority.
- Eval rows for prompt injection through MCP resources, tool/resource
  confusion, cross-scheme grant reuse, server impersonation, env leakage, and
  unsafe stdio process startup.

### Browser And Research

Browser work should not be implemented as a generic "let the model drive a
browser" hole. It should be a plugin-owned action set:

- `BrowserStartSession`
- `BrowserNavigate`
- `BrowserExtract`
- `BrowserScreenshot`
- `BrowserClick`
- `BrowserFill`
- `BrowserDownload`
- `BrowserCloseSession`

Each action should declare operation class, resource URI, downstream consumer,
and confirmation behavior. Remembered grants should be scoped by domain and
operation, not by all browser access.

Start with research/extraction and screenshots. Defer arbitrary form-fill and
authenticated account operations until the policy and UI prove usable.

### Provider And Model Control

Allbert already has a provider/model profile schema:

- providers: `local_ollama`, `openai`, `anthropic`, `openrouter`;
- model profiles: `local`, `fast`, `anthropic_fast`, `openrouter_fast`;
- Settings Central secret refs for API keys.

The missing 1.0 work is productization:

- `mix allbert.model list`
- `mix allbert.model use PROFILE`
- `mix allbert.model doctor PROFILE`
- workspace model/provider picker;
- channel command equivalent;
- clear current-profile display in traces and workspace;
- provider availability checks without leaking secrets;
- explicit fallback policy instead of hidden provider failover.

This should be folded into first-run onboarding rather than treated as a deep
substrate milestone.

### Channels

Discord and Slack should come before WhatsApp/Signal/SMS/iMessage.

Reasons:

- They map well to the existing channel adapter boundary.
- They prove group/team identity, mention handling, callbacks, and threaded
  replies.
- They are more operationally predictable than phone-number or QR-session
  channels.
- They give a large user-visible reach win quickly.

WhatsApp, Signal, SMS, and iMessage should be a second pack. SMS has cost and
truncation concerns. WhatsApp/Signal/iMessage have pairing/session/device
fragility and privacy expectations that deserve separate design.

### Everyday Integration Apps

1.0 should not depend on StockSage as the only serious app. Ship a first
integration pack after MCP:

- Calendar: read schedule, draft events, resolve conflicts, daily agenda.
- Mail: summarize inbox, draft replies, search messages, flag follow-ups.
- GitHub: issues, PR summaries, notifications, simple project triage.
- Notes/files: Obsidian-style markdown notes, local document search, memory
  promotion candidates.

Implementation rule: these are plugin-shaped apps/actions, never core special
cases. All effects route through registered actions and Resource Access.

### Plan/Build Mode

Plan/Build mode should be a workspace and channel UX over Objective Runtime:

- draft objective and steps;
- show required capabilities and resources;
- show confirmation points up front;
- allow operator edits;
- execute step-by-step;
- preserve action-level confirmation;
- record objective events and traces.

This should come after MCP, integrations, browser, and first channel expansion,
because Plan/Build becomes more valuable once Allbert has useful capabilities
to plan with.

### Voice, Vision, And Media

Do not make "voice" a channel. Treat it as modality:

- STT converts audio input into channel/runtime input.
- TTS renders output for a channel.
- Voice notes are audio resources with retention/redaction policy.
- Microphone capture is local resource access.

Do not make "vision" just an LLM feature:

- image upload/paste/screenshot are resource artifacts;
- model profile must support vision;
- image inputs need size/type/redaction policy;
- image generation is an effectful registered action with provider settings,
  cost visibility, retention, and confirmation for external provider calls.

### Marketplace

For 1.0, do not ship arbitrary remote code-bearing marketplace installs.

Ship marketplace lite:

- search/install skill-only bundles;
- reviewed-source plugin index metadata;
- template catalog metadata if local templates are already shipped;
- disabled-by-default installs;
- provenance, hash, version, and rollback metadata;
- security review UI.

Code-bearing remote plugin distribution can come after 1.0 when signing,
dependency policy, provenance, sandbox posture, and rollback semantics are
clear.

### API, ACP, AG-UI, A2UI

These are important but should land late in the 1.0 arc:

- OpenAI-compatible API endpoint for local clients.
- ACP server mode for editors.
- MCP server mode so other agents can inspect/send Allbert conversations and
  approvals.
- Public AG-UI/A2UI bridge over the existing workspace signal/surface model.

Reasons to place late:

- public exposure expands the threat surface;
- auth and confirmation ownership must be settled;
- CSP and redaction rules need review;
- external clients should not get more authority than local workspace users.

## Recommended Version Sequence

### v0.38: Templated Creation

Ship as planned.

Scope:

- `TemplatePattern` registry;
- Mix tasks for plugin/app/tool/flow generation;
- operator `workspace:create` surface;
- deterministic reviewed templates;
- inert source output by default;
- optional live integration only through v0.36/v0.37 gates;
- security evals and documentation closeout.

Reason:

This is the accelerator for every later capability. It should stay lean and
should not absorb MCP, channels, provider UX, or onboarding beyond the docs it
already needs.

### v0.39: First-Run Onboarding And Provider Control

Scope:

- Guided CLI and workspace onboarding objective.
- Provider/model setup wizard.
- `mix allbert.model list/use/doctor`.
- Workspace provider/model control.
- Validate local Ollama and remote OpenAI/Anthropic/OpenRouter profiles.
- Setup of first channel or workspace-only fallback.
- Setup of first useful workflow/job.
- Optional personality/identity memory slot, using Allbert memory conventions
  rather than copying Hermes `SOUL.md` exactly.

Reason:

Users cannot get value if they cannot start. Provider flexibility already has a
schema substrate, so the highest-leverage work is the control plane and user
journey.

### v0.40: MCP Client Integration

Scope:

- New MCP trust ADR.
- `mcp.servers.*` Settings Central schema.
- Stdio MCP transport first; HTTP second if feasible in the same milestone.
- Per-server and per-tool filters.
- MCP resource wrappers.
- Registered Allbert actions for list/read/call.
- Security Central permission and confirmation floors.
- Trace/audit/redaction.
- Eval rows for MCP-specific threats.

Reason:

MCP is the largest ecosystem unlock. It lets Allbert use existing tools without
writing a native plugin for each one, while Allbert keeps authority at its own
action boundary.

### v0.41: Everyday Integration Pack 1

Scope:

- Calendar plugin/app.
- Mail plugin/app or mail expansion beyond channel behavior.
- GitHub plugin/app.
- Notes/files plugin/app.
- Workspace panels and intent descriptors.
- Resource Access and confirmations for each effect.

Reason:

This turns Allbert into a personal assistant for ordinary work, not only a
runtime plus StockSage.

### v0.42: Browser, Web Research, And Document Extraction

Scope:

- Browser/web ADR.
- Browser plugin with session-scoped actions.
- Research/extract/screenshot first.
- Bounded document extraction for HTML, markdown, plain text, PDF, and common
  office/document formats if practical.
- Prompt-injection and data-exfiltration evals.
- Domain/operation-scoped remembered grants.

Reason:

OpenClaw and Hermes both treat browser/web as core. Allbert should add it once
MCP and first integrations exist, because browser is high-risk and high-value.

### v0.43: Channel Expansion Pack 1

Scope:

- Discord plugin.
- Slack plugin.
- Workspace/server identity mapping.
- Mention handling.
- Group/channel authorization.
- Threaded replies where supported.
- Confirmation callbacks and Approval Handoff rendering.
- Cross-channel spoofing/replay/group leakage evals.

Reason:

This makes Allbert reachable where users and teams already talk, while proving
team-channel security before phone-style channels.

### v0.44: Plan/Build Mode And Background Objectives

Scope:

- Workspace Plan/Build surface over Objective Runtime.
- Channel-visible plan summaries.
- Operator editing of steps/constraints.
- Up-front capability/resource/confirmation preview.
- Background objective execution and status.
- Step-level traces and final summary.

Reason:

This is the user-facing expression of the Objective Runtime. It should wait
until Allbert has enough real capabilities for planning to matter.

### v0.45: Voice Modality

Scope:

- Audio resource class ADR.
- STT provider profiles.
- TTS provider profiles.
- CLI/workspace voice input.
- Voice notes from supported channels.
- Spoken replies where channel UX supports it.
- Retention/redaction/cost visibility.

Reason:

Voice changes how reachable Allbert feels, but it is more useful after channels
and integrations exist.

### v0.46: Vision And Media Generation

Scope:

- Image input resource handling.
- Screenshot analysis.
- Vision-capable model profile checks.
- Image generation action and provider profiles.
- Workspace media rendering and retention controls.
- Safety/cost/trace policies.

Reason:

Vision and generated media close a visible parity gap with Hermes/OpenClaw and
make Canvas more useful.

### v0.47: Marketplace Lite And Trace-To-Skill Suggestions

Scope:

- Skill-only discovery/install/update.
- Reviewed-source plugin index metadata.
- Disabled-by-default installs.
- Provenance, hash, version, and rollback records.
- Trace-to-skill suggestion workflow producing drafts only.
- Explicit operator approval before enablement.

Reason:

This gives Allbert ecosystem growth without taking on arbitrary code-bearing
marketplace risk before 1.0.

### v0.48: API, ACP, MCP Server, And UI Protocol Bridge

Scope:

- OpenAI-compatible local API endpoint.
- ACP server mode for editor clients.
- MCP server mode exposing conversations, messages, and approval tools.
- Public AG-UI/A2UI bridge from Allbert signals/surfaces.
- Auth, rate limits, confirmation ownership, redaction, CSP review.

Reason:

This makes Allbert programmable and interoperable after the internal capability
and policy story has matured.

### v0.49: Export/Import, Hardening, And Release Candidate Polish

Scope:

- Full profile export/import dry run.
- Allbert Home portability checks.
- Settings/memory/skills/database export policy.
- Secret migration policy.
- Security eval sweep across MCP, browser, media, channels, marketplace, API.
- Onboarding and operator docs final pass.
- Upgrade/rollback documentation.

Reason:

1.0 should be portable, auditable, and boring to operate.

### v1.0: Stability Release

Scope:

- Public contract freeze for runtime/action/plugin/app/surface/resource APIs.
- Stable installer/onboarding story.
- Stable provider/model control.
- Stable MCP/client API posture.
- Stable workspace and channel UX.
- Security and warning gates clean.
- Documentation reconciled.

Reason:

1.0 should mean the system is coherent for an end user, not that every future
feature exists.

## Features To Defer Past 1.0

Defer these unless a concrete user/customer requirement changes the calculus:

- hosted multi-user authorization;
- arbitrary remote code-bearing plugin marketplace;
- remote secrets-manager adapters;
- broad remote sync service;
- native desktop/mobile apps beyond local browser/workspace;
- autonomous skill creation from traces without explicit operator review;
- system memory distillation or small-model training;
- deeper remote/microVM sandbox backends;
- broad scripting engine interface;
- marketplace theme/snippet distribution;
- full MCP Apps sandboxed iframe compatibility.

## Comparison With Prior Agent Research

The prior analysis was directionally right in several places:

- `v0.38` should ship next.
- MCP should come early.
- Channels, voice, browser, vision, and marketplace are real parity gaps.
- Allbert's safety architecture is a differentiator.

This memo changes the sequencing:

1. **Combine onboarding and provider flexibility.**
   Allbert already has provider/model profile schema and settings surfaces. The
   missing work is a user-facing control plane, not a deep provider substrate.

2. **Move everyday integrations earlier than voice.**
   Voice is compelling, but calendar/mail/GitHub/notes/browser/MCP make Allbert
   useful. Voice without useful capabilities is a nicer input method for a
   narrower assistant.

3. **Put Plan/Build after capabilities.**
   Objective Runtime exists, but Plan/Build needs real tools to plan around.

4. **Keep code-bearing marketplace distribution out of 1.0.**
   Skill-only and reviewed-source discovery is enough for 1.0. Arbitrary remote
   plugin code needs signing, dependency, sandbox, and rollback policy first.

5. **Move API/ACP/protocol interop late.**
   Public exposure should arrive after MCP/browser/channels/media have hardened
   the permission and confirmation model.

## Immediate Actions

1. Ship `v0.38` as planned.

2. Create skeleton roadmap entries and plan docs for:
   - `v0.39` First-Run Onboarding And Provider Control;
   - `v0.40` MCP Client Integration;
   - `v0.41` Everyday Integration Pack 1.

3. Draft the MCP trust ADR before implementing `v0.40`.

4. Update `docs/plans/future-features.md` after roadmap promotion:
   - remove or mark graduated entries for operator onboarding;
   - split MCP client from broader agent URI work;
   - split browser/research from broader browser capture;
   - split marketplace lite from code-bearing remote distribution.

5. Keep `v0.38` lean. Do not add channel/provider/MCP templates unless they
   are explicitly inert examples needed to validate the template registry.

6. Define a 1.0 acceptance matrix:
   - first-run setup succeeds in a disposable Allbert Home;
   - user can choose local or remote model profile;
   - user can connect at least one remote channel;
   - user can run at least one everyday integration workflow;
   - user can use an MCP server under policy;
   - user can ask Allbert to research a web/document target with confirmation;
   - user can review and approve a multi-step plan;
   - user can inspect traces, memory effects, permissions, and costs;
   - all warning/security/precommit gates pass.

## Bottom Line

Allbert should not chase OpenClaw or Hermes by copying their breadth
indiscriminately. It should use its stronger safety architecture to add the
same classes of user-visible capability in a stricter order.

The path is:

`v0.38` templates, then onboarding/provider control, MCP, everyday
integrations, browser/research, channels, Plan/Build, media, marketplace lite,
API/protocol interop, export/hardening, and then 1.0.

That sequence makes Allbert feel like a real personal assistant by 1.0 without
abandoning the design principle that makes it valuable: the assistant can grow
more capable without becoming less understandable.
