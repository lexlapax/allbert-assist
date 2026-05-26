# Allbert Version 1.0 Planning — Amalgamated, Holistic Plan

Date: 2026-05-26
Status: planning recommendation. Not yet roadmap authority. To be promoted into
`docs/plans/roadmap.md` and `docs/plans/future-features.md` after operator
review.
Inputs: `docs/archives/version-1.0-planning-01.md` (prior synthesis with OpenClaw/Hermes
research), `docs/archives/version-10-planning-02.md` (independent second-pass replanning
memo), the current roadmap and future-features parking lot, the 38 accepted
ADRs, the v0.37.5 release closeout, and the v0.38 implementation-ready plan.

This document amalgamates the two prior analyses into a single, holistic plan
that honors the three explicit priorities you set:

1. **Operator-first.** Every milestone has to deliver something an operator
   can use, not only substrate the next milestone needs.
2. **Safety is already in.** Preserve Security Central, durable confirmations,
   Resource Access posture, the v0.36 sandbox/gate runner, and the v0.37
   reversible dynamic loader without compromise. Every new capability lands
   under the existing authority boundary.
3. **Usability is the 1.0 bar.** 1.0 is not the runtime feeling complete
   internally; it is a new user being able to install Allbert, pick a model,
   connect a channel, plug into an MCP server, ask for help with calendar or
   mail, and trust what happens — and reach all of that without leaving the
   docs trail.

## 1. Executive Summary

- Allbert at `v0.37.5` already has the substrates a serious 1.0 personal
  assistant needs: registered Jido actions, durable confirmations, Settings
  Central, Security Central, local traces, markdown memory with review,
  jobs, the Objective Runtime, reviewed plugin apps, Allbert Home theming and
  layout overrides, a default-off Elixir/OTP sandbox/gate runner, and a
  default-off reversible dynamic draft/live integration path. **The gap to
  1.0 is delivery and reach, not architecture.**
- Both prior planning passes converge on the same conclusion: **ship `v0.38`
  Templated Creation next, exactly as planned, lean.** It is the deterministic
  creation accelerator that every later milestone reuses; padding it with MCP,
  channels, or provider UX would defeat its purpose.
- The decisive parity-closing milestones are **MCP**, **Everyday
  Integrations**, **Browser**, and **two channel packs**. Voice, vision,
  Plan/Build, marketplace, and API/protocol interop are the second tier —
  important for 1.0 but not the differentiator.
- The strategic moat is the safety architecture. As long as the v0.38 → v1.0
  sequence preserves Security Central, the confirmation model, the
  sandbox/gate runner, and the reversible dynamic loader, Allbert ships at
  1.0 as **the safest personal-assistant runtime with feature parity to
  OpenClaw and Hermes**.
- Proposed sequence: **12 milestones from `v0.38` to `v1.0`**, grouped in
  five phases. At the project's recent cadence (a minor every 5–7 days), this
  is roughly six months of focused work.

## 2. Where Allbert Stands Today (v0.37.5)

This section is intentionally brief; the prior docs and the roadmap have the
full detail.

- `/workspace` is the operator home; chat is the spine; Canvas shows one
  destination at a time; the launcher is view-only.
- Channels: CLI (`mix allbert.ask`), Phoenix LiveView (`/workspace`),
  Telegram, email.
- Memory: markdown-first under `<ALLBERT_HOME>/memory` with review,
  promotion, correction, pruning, and metadata-only intent candidates.
- Objectives: durable multi-step work across turns, channels, and jobs
  (ADR 0021, v0.24).
- Safety: Security Central with explicit permission classes and risk tiers,
  durable confirmations under Allbert Home, Resource Access Security Posture
  with URI-first identity (`mcp://`, `agent://`, `agent+https://` already
  reserved as inert metadata), the v0.36 Elixir/OTP sandbox/gate runner, and
  the v0.37 reversible dynamic draft/live integration path.
- Workspace: Surface DSL with a 42-component catalog, HMAC-signed Fragment
  emission, per-thread Canvas plus ephemeral surfaces, multi-tab sync,
  offline Yjs/IndexedDB editing, WCAG-oriented accessibility, mobile
  responsive layout, dark/light/system theming, sanitized user
  theme/snippet/layout overrides.
- 38 ADRs of binding decisions; CHANGELOG through v0.37.5.

`v0.38` Templated Creation is the next implementation-ready milestone.

## 3. The Two Prior Drafts — Where They Agree, Where They Diverge

### 3.1 Convergences (no debate needed)

- **Ship `v0.38` lean as planned.** Do not insert a new user-facing
  milestone before it. The deterministic template substrate accelerates
  every later milestone.
- **MCP is the highest-leverage single ecosystem unlock.** It brings the
  GitHub/Notion/Drive/Postgres/Linear/Jira/Stripe/Figma/Vercel ecosystem in
  one milestone without per-integration plugin work.
- **Onboarding plus provider control are the first usability milestone after
  templates.** Users cannot reach value if they cannot start.
- **Browser, voice, and vision are real parity gaps**, but each is a
  capability, not the platform.
- **Marketplace stays lite.** Reviewed skill/plugin-index metadata only.
  Code-bearing remote plugin distribution waits until after 1.0.
- **API, ACP, MCP-server, and A2UI public bridges arrive late** in the 1.0
  arc, after the internal permission, confirmation, and CSP story has
  hardened against the new capability surface.
- **Allbert's safety architecture is the moat.** Don't trade it away for
  parity speed.

### 3.2 Divergences and the chosen resolution

| Question | Draft 01 | Draft 02 | Final choice | Reason |
|---|---|---|---|---|
| Onboarding scope at v0.39 | Onboarding + Personality slot | Onboarding + Provider Control | **Combine all three at v0.39** | Provider schema already exists; control plane is the missing UX; personality file is small additive piece; ship them together so a new user lands fully wired up. |
| When is MCP | v0.41 (after onboarding + providers + Active Memory) | v0.40 (after combined onboarding/providers) | **v0.40** | With provider control folded into v0.39, MCP can lead the integration phase. |
| Active Memory placement | v0.40 (with providers) | not separately listed | **Folded into v0.39** as a thin pre-reply retrieval pass keyed on the new identity namespace | Active Memory is a polish on top of memory + identity that pays off the moment onboarding writes preferences. |
| Browser ordering | v0.44 (after channels + voice) | v0.42 (after MCP + integrations, before channels) | **v0.42** | Browser is what makes "research" feel like an agent. Putting it before channels widens the "what can Allbert do for me?" answer before broadening "where can I reach Allbert from?". |
| Channels Discord/Slack | v0.42 (before browser) | v0.43 (after browser) | **v0.43** | Aligns with browser-first ordering; team channels stress group identity and authorization independently. |
| Plan/Build Mode | v0.46 (after voice/vision) | v0.44 (after channels) | **v0.44** | Plan/Build is only interesting when there are real capabilities to plan with — MCP, integrations, browser, two channels are enough. |
| Voice | v0.43 | v0.45 | **v0.45** | Modality after capabilities. Voice over a useful assistant is a real win; voice over an empty assistant is a nicer microphone. |
| Vision/image gen | v0.45 | v0.46 | **v0.46** | Pair with voice. |
| Channel Pack 2 (mobile) | v0.47 | not explicitly | **v0.47** | Mobile channels (WhatsApp/Signal/iMessage/Matrix) deserve their own milestone for pairing/session/privacy reasons; they ride the v0.43 channel substrate. |
| Marketplace + API/ACP/protocol | v0.48 + v0.49 (split) | v0.47 + v0.48 (split) | **v0.48 combined** | Marketplace-lite and external-protocol surfaces both ride the same auth/CSP/redaction conversation; pair them so the eval sweep covers both in one pass. |
| Final RC | v1.0 = features + freeze | v0.49 = hardening, v1.0 = freeze | **v0.49 = RC hardening, v1.0 = freeze** | A real 1.0 should not introduce new features. 02's split is cleaner and gives operators a stable platform commitment. |

This gives **12 milestones from v0.38 through v1.0** (v0.38, v0.39, v0.40,
v0.41, v0.42, v0.43, v0.44, v0.45, v0.46, v0.47, v0.48, v0.49, v1.0 — 13
versions, 12 increments).

## 4. The Amalgamated Roadmap to 1.0

### Phase 1 — Foundation & Onboarding (v0.38–v0.39)

#### v0.38 — Templated Creation (lean, as planned)

Already implementation-ready. Ship exactly per `docs/plans/v0.38-plan.md` and
ADR 0036.

Substrate work: `TemplatePattern` registry; Mix tasks
(`mix allbert.gen.plugin/app/tool/flow`); operator `workspace:create` Canvas
surface; reviewed plugin/app/LLM-tool/scheduled-flow/objective templates;
deterministic parameter substitution; default inert source output; optional
live integration that reuses the v0.36 sandbox and v0.37 loader exactly;
security evals for parameter injection, traversal, authority bypass,
ungated/unconfirmed integration, scheduled-flow escalation, and Canvas
authority.

Operator-visible win: developers and operators scaffold capabilities in
minutes. The v0.36 sandbox and v0.37 loader get a deterministic, vetted entry
point that doesn't depend on free LLM authoring.

Do not pad v0.38 with channel templates, provider templates, MCP templates,
or onboarding flows. Each lands in its own milestone.

#### v0.39 — First-Run Onboarding + Provider Control + Identity Slot + Active Memory

This is the largest "make Allbert usable" milestone. It bundles four
small-but-high-impact pieces that all touch the same first-run surface.

Substrate work:

- **Onboarding as a registered objective.** `mix allbert.onboard` and a
  workspace onboarding destination both invoke the same Objective
  Runtime-backed flow. Steps: pick provider profile → enter and validate
  credentials → optional local Ollama setup → register at least one channel
  (or workspace-only) → pick first useful workflow/template → optional
  personality file. Each step is a registered action under Security Central.
- **Provider control plane.** `mix allbert.model list`, `mix allbert.model
  use <profile>`, `mix allbert.model doctor <profile>`; workspace
  provider/model picker; channel command equivalent; current profile
  rendered in traces and workspace status. Existing `providers.profile.*`
  schema gains validation hardening and explicit fallback policy (no hidden
  failover; explicit operator opt-in only).
- **Identity / personality memory slot.** New `identity` memory namespace
  declared per ADR 0017/v0.27 namespace contract. Hosts a Hermes-`SOUL.md`-
  equivalent persona file under `<ALLBERT_HOME>/memory/identity/`. Inert
  content — never grants permission, never executes. Optional. Operator-
  editable.
- **Active Memory pre-reply retrieval.** Deterministic retrieval pass before
  each reply, scoped to current thread + `active_app` + `identity`
  namespace. Reuses the v0.21 memory review/retrieval infrastructure;
  expands its consumer set rather than introducing a new system. Auditable
  in trace metadata.

ADR work needed: none new — `identity` is a namespace declaration; Active
Memory is a registered retrieval action wired into the existing intent
context.

Operator-visible win: a new user goes from `git clone` to "I can have a
useful, context-aware conversation with the model I chose, from the channel
I picked, in under fifteen minutes."

Doctor and validation behavior must not leak secrets; provider availability
checks render redacted summaries only.

### Phase 2 — Integration Platform (v0.40–v0.41)

#### v0.40 — MCP Client Integration

The single largest ecosystem unlock in the entire 1.0 arc.

Substrate work:

- New ADR for **MCP trust tier** (see §6 for the binding decisions this
  forces). MCP server schemas are descriptive only; Allbert remains the
  policy authority.
- New permission class `:mcp_tool_call` with a `:needs_confirmation` safety
  floor that Settings Central cannot lower (modeled on
  `:external_network`).
- New permission class `:mcp_resource_read` for read-only resource fetches
  through MCP, with the same confirmation safety floor when the resource
  carries network or untrusted text.
- Settings Central namespace `mcp.servers.*`: per-server transport (stdio
  first, streamable HTTP second), env/header refs into Secrets, enabled
  flag (default off), per-tool include/exclude filters, per-tool
  confirmation override (only to tighten, never loosen).
- Consumer for the reserved `mcp://` URI scheme (ADR 0013, v0.10 M12).
  Allbert-side MCP resources are addressed `mcp://<server-id>/<encoded-uri>`
  and flow through the same Resource Access posture as any other resource.
- Registered actions `mcp_list_tools`, `mcp_call_tool`, `mcp_list_resources`,
  `mcp_read_resource`. All effects route through `Actions.Runner.run/3`.
- Approval Handoff reuse: every MCP tool call renders the same confirmation
  card as any other registered action — channel-agnostic, no MCP-specific
  approval path.
- First four named MCP servers operationally tested:
  **GitHub, Notion, Google Drive, Postgres** — matching OpenClaw's official
  list, validating the trust-tier ADR against four real-world server shapes.
- Security evals: prompt injection through MCP resources, tool/resource
  confusion, cross-scheme grant reuse, server impersonation, env leakage,
  unsafe stdio process startup, redirect/header injection on HTTP transport.

Operator-visible win: Allbert gains the entire MCP-compatible ecosystem in
one milestone. Tens of integrations become operator-configurable through
Settings Central without per-integration plugin code.

#### v0.41 — Everyday Integration Pack 1

After MCP, ship the first wave of native integrations that don't fit MCP
cleanly or benefit from richer workspace surface (custom panels, memory
namespace, intent descriptors).

Substrate work:

- Calendar plugin/app: read schedule, draft events, resolve conflicts,
  daily agenda. Resource Access posture for write effects.
- Mail plugin/app: summarize inbox, draft replies, search messages, flag
  follow-ups. Sits next to the existing v0.16 email channel adapter; reuses
  IMAP/SMTP credentials with explicit operator scoping.
- GitHub: thin local plugin for the workspace panels and intent
  descriptors. Heavy lifting (PR diffs, issue CRUD) can route through the
  v0.40 GitHub MCP server; the local plugin owns surface and memory.
- Notes/files plugin/app: Obsidian-style markdown notes, local document
  search, memory promotion candidates from notes content.
- All effects through registered actions, Security Central, and Resource
  Access. Channel hand-off uses the same Approval Handoff path.

ADR work needed: small ADR formalizing the **"MCP-first, native-plugin-second"
rule** (see §6.6).

Operator-visible win: Allbert becomes a personal assistant for ordinary
work — not only a runtime plus StockSage.

### Phase 3 — Reach & Multi-Modal (v0.42–v0.46)

#### v0.42 — Browser & Web Research

The first time Allbert can act on the open web like an agent.

Substrate work:

- New ADR for **browser session and web research policy** (see §6.2).
- Sandboxed Playwright (or comparable) plugin under
  `./plugins/allbert.browser/`. Browser process lives inside a plugin-owned
  supervisor; never embedded in core.
- Resource model: `browser://session/<id>` URIs with operation classes
  `:navigate`, `:click`, `:fill`, `:submit`, `:extract`, `:screenshot`,
  `:download`. Each operation class is a separate Resource Access grant.
- Per-domain, per-operation remembered grants. A grant for
  `:navigate github.com` does not authorize `:fill github.com`.
- Registered actions: `BrowserStartSession`, `BrowserNavigate`,
  `BrowserExtract`, `BrowserScreenshot`, `BrowserClick`, `BrowserFill`,
  `BrowserDownload`, `BrowserCloseSession`.
- Start with research/extract/screenshot. Defer arbitrary form-fill and
  authenticated account operations to a later milestone once the policy UI
  is proven.
- Bounded document extraction for HTML, markdown, plain text, and PDF as
  part of the same release. Broader Office/archive support stays parked
  under "Deep Remote Document Extraction".
- Security evals: prompt injection from fetched pages, data exfiltration
  through navigation chains, cookie/session leakage, screenshot redaction,
  cross-domain grant escape.

Operator-visible win: "Research X for me", with operator confirmation per
new navigation scope.

#### v0.43 — Channel Pack 1: Discord + Slack

Team-channel reach before mobile/personal-messaging channels.

Substrate work:

- Two new plugin packages under `./plugins/` reusing the v0.16 channel
  adapter boundary and the v0.17 plugin contract.
- Discord plugin: bot identity, workspace/server mapping, channel/thread
  authorization, mention handling, threaded replies, slash commands for
  approval callbacks.
- Slack plugin: workspace mapping, channel/group authorization, mentions,
  thread replies, interactive Block Kit confirmation buttons.
- Both reuse Approval Handoff rendering, durable event dedupe, identity
  mapping, and redaction posture. No channel-specific confirmation logic.
- Security evals: cross-channel spoofing, replay, group leakage, command
  injection in reply bodies, resource approval scope leakage,
  workspace-vs-DM authorization confusion.

Operator-visible win: Allbert is reachable in team chat and community
servers, not only personal Telegram and email.

#### v0.44 — Plan/Build Mode + Operator Workflow YAML

After MCP, integrations, browser, and team channels, Allbert finally has
enough real capability surface that operator-authorable plans matter.

Substrate work:

- Workspace Plan/Build destination: an operator surface over the v0.24
  Objective Runtime. Renders an objective draft with steps, required
  capabilities/resources, upcoming confirmation points, and a "what could
  fail" preview.
- Operator-authorable workflow YAML (Allbert's equivalent of OpenClaw's
  "Lobster" engine): a declarative input that produces objective steps,
  validated by an explicit schema, executed through `Actions.Runner.run/3`
  with Security Central and confirmations as usual. Not a new execution
  engine.
- Operator-visible subagent delegation UX: spawn concurrent specialist
  agents from a parent objective; observe from `/workspace`. The
  `:delegate_agent` step kind already exists from v0.24/v0.25; v0.44 is
  the operator surface.
- Channel-visible plan summaries: Telegram/Discord/Slack render a compact
  plan card with approve-step / approve-all / cancel buttons. CLI prints
  the plan inline.
- Background objective execution with progress reporting back through the
  origin channel.

Operator-visible win: operators compose multi-step automations without
writing Elixir; they preview and approve plans before they run.

#### v0.45 — Voice Modality (experimental)

Substrate work:

- New ADR for **audio resource class** (see §6.3). Microphone capture is a
  Resource Access consumer with explicit per-session confirmation; audio
  output (TTS) is a registered action with a provider profile.
- STT provider profiles: on-device first where available; Whisper API,
  ElevenLabs, Edge TTS as cloud options.
- TTS provider profiles: Edge TTS as default free option, ElevenLabs and
  on-device MLX-on-macOS where available, OpenAI TTS as cloud option.
- CLI voice mode (`mix allbert.ask --voice`), workspace mic button.
- Discord voice channel support (read-only at first); Telegram voice notes
  ingest as transcribed text input.
- Retention/redaction posture for captured audio: bounded local cache,
  redacted from traces by default, explicit retention opt-in.
- Marked **experimental** in 1.0 — honest parity with OpenClaw's experimental
  voice surface.

Operator-visible win: talk to Allbert from CLI and team channels and hear
it back.

#### v0.46 — Vision + Image Generation

Substrate work:

- Image input as a new resource class: paste/upload binary as
  `image://capture/<id>` Resource Access consumer. Size/type/redaction
  policy. Vision-capable model profile checks at v0.39's provider doctor.
- Screenshot capture as a Resource Access consumer (`screen://capture/<id>`).
- Image generation as a registered action with a provider profile (FLUX,
  GPT-Image, Recraft, Ideogram). Reuses the v0.39 provider profile schema.
- Workspace media rendering and retention controls; bounded cache;
  redaction by default in traces.
- Cost visibility: generation cost surfaced at confirmation time.

Operator-visible win: paste a screenshot and ask about it; generate
diagrams and images on demand.

### Phase 4 — Reach Continued + Ecosystem (v0.47–v0.48)

#### v0.47 — Channel Pack 2: WhatsApp + Signal + iMessage + Matrix

The mobile/personal-messaging pack, delayed deliberately because pairing
fragility, phone-number mapping, and privacy expectations differ from team
channels.

Substrate work:

- Four more channel plugins under `./plugins/` reusing v0.43 patterns.
- iMessage via macOS-only adapter (operator opt-in, documented platform
  constraint).
- Matrix via standard protocol (Element/Synapse compatible).
- WhatsApp via Business API or whatsapp-web bridge (operator chooses;
  fragility documented).
- Signal via signald or libsignal (operator chooses).
- Each provider gets its own Settings Central schema, pairing UX, and
  delivery/retry/dedupe policy.
- Security evals: phone-number identity mapping confusion, QR-session
  replay, device-pairing recovery, mobile-specific link/redirect handling.

Operator-visible win: Allbert reachable on the messaging surfaces people
actually use on their phones.

#### v0.48 — Marketplace Lite + API/ACP/Protocol Interop

Two related ecosystem surfaces share one milestone because both ride the
same external-exposure policy review.

Substrate work:

- **Marketplace lite:**
  - Reviewed-skill-only discovery/install path: search a curated index,
    install a skill bundle into `<ALLBERT_HOME>/skills/`, validate through
    the v0.03 parser, leave disabled and untrusted by default.
  - Reviewed-source-only plugin index metadata (no auto-install; surface
    only — user clones manually after reading the entry).
  - Template catalog metadata: shipped templates plus curated community
    templates, surfaced through `workspace:create`.
  - Provenance, hash, version, and rollback metadata for everything
    discovered.
  - **Explicitly not in scope for 1.0:** arbitrary remote code-bearing
    plugin install, marketplace theme/snippet distribution, MCP-Apps-style
    sandboxed iframe execution.

- **API, ACP, MCP-server, AG-UI/A2UI public bridge:**
  - OpenAI-compatible local HTTP endpoint (rate-limited, redacted,
    audited). Reuses provider profile schema.
  - ACP (Agent Client Protocol) server mode for VS Code, Zed, JetBrains.
  - MCP server mode exposing Allbert conversations and approval tools to
    other agents — symmetric to the v0.40 client work.
  - Public AG-UI/A2UI bridge: promote the v0.26 internal bridge (ADR 0023
    §8) to a public HTTP/WS endpoint with auth, rate limits, and CSP
    reconciliation per the v0.35 baseline.
  - All four bridges share one auth/rate-limit/CSP/redaction policy review.
  - External clients never receive more authority than local workspace
    users.

ADR work needed: the marketplace-lite trust tier ADR; the public-protocol
exposure ADR (covers API, ACP, MCP server, A2UI bridge as one policy
surface).

Operator-visible win: discover and install reviewed skills/plugins; drive
Allbert programmatically from editors and other agents.

### Phase 5 — Production Release (v0.49–v1.0)

#### v0.49 — Hardening + Export/Import + Release Candidate

No new features. The job is to make 1.0 portable, auditable, and boring to
operate.

Substrate work:

- **Profile export/import dry run.** Full `<ALLBERT_HOME>` portability:
  settings (with secret migration policy), memory (with namespace
  preservation), skills, threads/messages, traces, audit, jobs,
  objectives, confirmations. Schema/version metadata for each table.
  Rollback documented.
- **Security eval sweep.** End-to-end across MCP, browser, channels,
  voice, vision, marketplace, API, ACP, A2UI bridge. Tripwire any
  regressions before 1.0.
- **Onboarding and operator docs final pass.** Every milestone's operator
  doc cross-linked from `docs/operator/onboarding.md`. Upgrade and
  rollback paths documented.
- **Performance hardening.** Trace any p99 outliers under realistic load
  (multi-channel, MCP, browser, voice concurrent).
- **CSP final reconciliation** for the v0.48 public protocol surfaces.
- **Warning gate clean** across all packages.

Operator-visible win: Allbert installs, runs, exports, imports, and
upgrades without surprises.

#### v1.0 — Stability Release & Public Contract Freeze

The 1.0 mark. No new features. Public contracts freeze.

Frozen contracts:

- Runtime: `AllbertAssist.Runtime.submit_user_input/1`, signals, action
  metadata.
- Actions: `AllbertAssist.Actions.Registry` and
  `AllbertAssist.Actions.Runner.run/3` shape; permission classes; safety
  floors.
- Plugin contract: `AllbertAssist.Plugin` behaviour and registry.
- App contract: `AllbertAssist.App` and `App.SurfaceProvider`.
- Surface DSL: 42-component catalog, signed Fragment envelope.
- Resource Access: `ResourceURI`, operation classes, grant shape.
- Workspace canvas and ephemeral surface contracts.
- Channel adapter boundary.
- Settings Central schema.
- Allbert Home layout.

What 1.0 means to a user: "I can install this, use it, trust it, share it,
and upgrade it. The shapes I depend on will not change underneath me."

What 1.0 deliberately does **not** mean: "Every possible feature exists."
The post-1.0 future-features list is healthy and substantial; 1.0 is the
stable platform commitment, not the feature ceiling.

## 5. Architecture Decisions This Plan Asks You to Accept

Each will need an accepted ADR before the milestone implements it.

### 5.1 MCP client trust tier (v0.40)

- New permission class `:mcp_tool_call` with `:needs_confirmation` safety
  floor; Settings Central cannot lower it.
- New permission class `:mcp_resource_read` with the same floor when the
  resource carries network or untrusted text.
- MCP tool schemas are descriptive only. The MCP server is not the
  authority on permission, confirmation, or risk. Allbert is.
- MCP server configurations sit in Settings Central under `mcp.servers.*`;
  secrets live in the encrypted secret store.
- Per-server and per-tool include/exclude filters. Confirmation overrides
  can only tighten, never loosen.

### 5.2 Browser session and web research policy (v0.42)

- Browser sessions are `browser://session/<id>` Resource Access resources.
- Each operation (`:navigate`, `:click`, `:fill`, `:submit`, `:extract`,
  `:screenshot`, `:download`) is a separate Resource Access grant.
- Remembered grants are scoped per-domain per-operation.
- The browser plugin owns its sandbox; core never spawns the browser
  process directly.
- Sensitive-data detection (passwords, tokens, OTP codes in screenshots)
  triggers explicit confirmation.

### 5.3 Audio and image as resource classes (v0.45–v0.46)

- Microphone capture is a Resource Access consumer (`mic://capture/<id>`).
- Audio output (TTS) is a registered action with provider profile.
- Image input is a Resource Access consumer (`image://capture/<id>`).
- Screenshot capture is a Resource Access consumer
  (`screen://capture/<id>`).
- Image generation is a registered action with provider profile.

This keeps voice and vision out of the channel boundary: they compose with
any channel that supports the relevant media.

### 5.4 Public protocol exposure (v0.48)

- One auth/rate-limit/CSP/redaction policy covers API, ACP, MCP server,
  and A2UI bridge.
- External clients never receive more authority than local workspace
  users.
- Approval Handoff over external protocols remains operator-owned;
  external clients do not approve their own confirmations.
- The v0.35 CSP baseline (`style-src 'self'`, no remote fetch) is
  re-evaluated explicitly and any source expansions are documented as ADR
  amendments.

### 5.5 Operator workflow YAML reuses Objective Runtime (v0.44)

- YAML is a declarative input that produces objective steps. It is not a
  new execution engine.
- Every step still goes through `Actions.Runner.run/3`, Security Central,
  and confirmations.
- Schema is explicit and validated; unknown keys fail closed.

### 5.6 MCP-first, native-plugin-second integration rule (v0.41)

- Most named integrations ship as MCP server configurations in v0.40.
- A native plugin app exists only when the integration needs richer
  surface (custom panels, memory namespace, intent descriptors) beyond
  what MCP provides.
- Allbert core never grows a dependency on Google APIs, iCloud, GitHub
  APIs, etc. Those live either in MCP servers or in plugins.

### 5.7 Channel adapters do not invent new permission classes (v0.43, v0.47)

- Each new channel is a plugin under `./plugins/` following the v0.16/v0.17
  substrate.
- They reuse existing Approval Handoff rendering, identity mapping,
  dedupe, and redaction posture.
- No channel-specific permission class; no channel-specific confirmation
  shape.

### 5.8 Identity namespace and Active Memory ride existing substrates (v0.39)

- The `identity` memory namespace is just a namespace declaration under
  the v0.27 contract.
- Active Memory pre-reply retrieval is a registered action that wraps the
  existing v0.21 retrieval infrastructure; not a new memory engine.
- The optional persona file is inert content; it never grants permission
  or executes.

## 6. End-User Gap Analysis — Mapped to Milestones

The 1.0 acceptance test is the new-user experience. Each gap is closed by a
named milestone.

| Gap a new user notices today | Closed by |
|---|---|
| "How do I even start?" | v0.39 onboarding |
| "Can I use Ollama / OpenAI / Claude / OpenRouter?" | v0.39 provider control |
| "Does it remember anything between sessions?" | already done (v0.21); v0.39 Active Memory makes it feel automatic |
| "Can it use my GitHub / Notion / Drive / Postgres?" | v0.40 MCP |
| "Can it manage my calendar / email / notes?" | v0.41 Integration Pack 1 |
| "Can it actually use the web?" | v0.42 Browser |
| "Can I use it from Discord / Slack?" | v0.43 Channel Pack 1 |
| "Can I see what it's about to do and approve the plan?" | v0.44 Plan/Build |
| "Can I talk to it?" | v0.45 Voice |
| "Can I show it a screenshot or generate an image?" | v0.46 Vision |
| "Can I use it from WhatsApp / Signal / iMessage / Matrix?" | v0.47 Channel Pack 2 |
| "Can I discover and install community skills?" | v0.48 Marketplace lite |
| "Can other tools / my editor talk to it?" | v0.48 API, ACP, MCP server, A2UI bridge |
| "Can I export and re-import everything?" | v0.49 |
| "Will the contracts I depend on stay stable?" | v1.0 |

## 7. 1.0 Acceptance Matrix

These are the criteria 1.0 must clear in a disposable Allbert Home before
the contract freeze is signed.

1. First-run setup succeeds on macOS, Linux, and Windows (WSL2).
2. The user can choose any of: local Ollama, OpenAI, Anthropic, OpenRouter.
3. The user can connect at least one remote channel (Telegram, email,
   Discord, Slack, WhatsApp, Signal, iMessage, or Matrix).
4. The user can run at least one everyday integration (calendar, mail,
   GitHub, notes/files).
5. The user can configure and use at least one MCP server under policy.
6. The user can ask Allbert to research a web target and approve the
   navigation scope.
7. The user can review and approve a multi-step plan before it executes.
8. The user can have a voice conversation through CLI or a supporting
   channel.
9. The user can paste a screenshot and ask about it.
10. The user can discover and install a reviewed skill from the
    marketplace lite.
11. The user can drive Allbert from VS Code or another ACP client.
12. The user can export their Allbert Home, re-import it on a second
    machine, and observe identical behavior.
13. All warning/security/precommit gates pass.
14. The full eval sweep across MCP, browser, channels, voice, vision,
    marketplace, and public protocols passes.

## 8. What Stays Deferred Past 1.0

These remain in `docs/plans/future-features.md` until promoted:

- **Code-bearing remote plugin marketplace** — needs signing, dependency
  policy, sandbox posture, and rollback semantics that are out of 1.0
  scope.
- **Hosted multi-user authorization model** — local string `user_id`
  remains the 1.0 identity model.
- **Remote secrets manager adapters** — OS keychain, cloud vaults, etc.
  Local encrypted Settings store stays default.
- **Advisory providers / world models** beyond the v0.33 narrow intent/
  route subset. Waits for a second concrete provider.
- **Native packaged UI** (macOS/Windows desktop bundles). Packaging
  concern, not capability concern.
- **Deeper sandbox tiers** (Level 2 trusted-project, Level 3 container,
  Level 4 remote/microVM) beyond v0.36 Level 1 plus the existing
  Docker/Podman/runsc backends.
- **Scripting engine interface** (embedded Lua/Python/JS). Elixir +
  registered actions + plugin contract cover the need.
- **Autonomous skill creation from traces** without explicit operator
  review.
- **System memory / personality distillation** (small-model training).
  Active Memory in v0.39 is the deterministic precursor; the research
  direction stays parked.
- **Deep remote document extraction** (broad Office/archive formats).
  v0.42 ships HTML/markdown/text/PDF; broader formats wait.
- **MCP Apps sandboxed-iframe model.** Conflicts with the
  "declarative + catalog-bound" Surface stance; reconciliation needs its
  own trust-policy ADR.
- **Broad remote sync service.** v0.49 export/import is local-first; a
  hosted sync service is a separate product decision.

## 9. The Strategic Frame

> Allbert is not behind OpenClaw or Hermes on architecture. It is ahead on
> architecture and behind on shipped capability. The 1.0 plan is not a
> rewrite — it is a 12-milestone delivery push that reuses substrates
> already proven through v0.37.

Three principles drive the ordering:

1. **Foundation before fan-out.** v0.38 (templates) → v0.39 (onboarding +
   providers + Active Memory) precede capability expansion because every
   later milestone reuses them.
2. **MCP early, browser next, channels alongside.** MCP at v0.40 absorbs
   what would otherwise have been a separate "first-wave integrations"
   milestone. Browser at v0.42 gives Allbert real agency on the web before
   channels broaden reach. Channels at v0.43 and v0.47 broaden where the
   agent is reachable.
3. **Operator workflow YAML and modality after capability.** Plan/Build
   (v0.44), voice (v0.45), and vision (v0.46) compound on top of the real
   capability surface. Earlier placement would be UI over emptiness.

The decisive milestones are **v0.40 (MCP)**, **v0.41 (integrations)**,
**v0.42 (browser)**, **v0.43 + v0.47 (channels)**. Those five close most of
the parity gap. Voice, vision, marketplace, and protocol interop are the
polish that 1.0 needs but are not the moat.

The strategic moat — Allbert's actual advantage over OpenClaw and Hermes —
is the safety architecture. The 1.0 commitment is: **add the same classes of
user-visible capability in a stricter order, without compromising the
authority boundary that makes the assistant trustworthy.**

## 10. Concrete Next Steps

If you want to act on this plan:

1. **This week — promote four future-features entries to roadmap milestones**
   with skeleton plan docs:
   - First-Run Onboarding + Provider Control + Identity Slot + Active
     Memory → v0.39
   - MCP Client Integration → v0.40
   - Everyday Integration Pack 1 → v0.41
   - Browser & Web Research → v0.42

   Even stub plans help the work get sized and reviewed in parallel with
   v0.38 implementation.

2. **In parallel with v0.38 implementation — draft the MCP trust-tier ADR.**
   This is the single highest-leverage architectural document because v0.40
   carries the most ecosystem weight and the most novel trust surface.
   Cover: `:mcp_tool_call` and `:mcp_resource_read` permission classes,
   trust tier policy for MCP server connections, Resource Access posture
   for MCP-fetched resources, and the descriptive-not-authoritative rule
   for tool schemas.

3. **Update `docs/plans/future-features.md`** after roadmap promotion:
   - Mark **graduated** to specific slots: Operator First-Run Onboarding
     (v0.39), system memory / Active Memory (v0.39 precursor), MCP And
     Agent URI Resource Access (v0.40 — split the MCP-client part from the
     broader `agent://` work which stays parked), Browser/Search Capture
     (v0.42 — split from Deep Remote Document Extraction which stays parked
     for broader formats), Additional Remote Channel Adapters (v0.43 for
     Discord/Slack, v0.47 for WhatsApp/Signal/iMessage/Matrix), Remote
     Plugin Marketplace (v0.48 — split marketplace-lite from
     code-bearing-remote-distribution which stays parked), Post-v0.38 UI
     Protocol Interop (v0.48 for A2UI public bridge + ACP).
   - Keep parked: code-bearing marketplace distribution, hosted
     multi-user model, remote secrets manager, advisory providers,
     native packaged UI, deeper sandbox tiers, scripting engine,
     autonomous skill creation, deep remote document extraction, MCP
     Apps iframe, broad remote sync.

4. **Pick the first v0.39 plan to draft.** v0.39 is the smallest, least
   controversial, and highest-leverage milestone to plan first. It
   composes existing primitives (registered objective + Settings Central +
   provider profiles + memory namespace + channel registration + memory
   retrieval) and unblocks the v0.40 sequencing.

5. **Adopt the 1.0 acceptance matrix from §7** as the closeout test for
   v0.49 and the freeze test for v1.0.

## 11. Sources

### The two prior planning iterations this document amalgamates

- `docs/archives/version-1.0-planning-01.md` — earlier synthesis with detailed
  OpenClaw/Hermes competitive research and the substrate inventory.
- `docs/archives/version-10-planning-02.md` — independent second-pass replanning memo
  with the recommended sequencing and the 1.0 acceptance matrix
  vocabulary.

### External research (already gathered by 01 and 02)

OpenClaw: official site, GitHub repo, docs (concepts, channels, tools,
providers, MCP CLI, security), Petronella self-host guide, DigitalOcean
overview, Globussoft feature list, OpenClaw News ecosystem map.

Hermes Agent: features overview, messaging gateway, MCP, API server, ACP
editor integration, personality, plugins, GitHub repo.

Out-of-category disambiguation: OpenCode, Claude Code, Cursor, Aider —
listed in 01 §3.3 to distinguish coding-agent category from
personal-assistant category.

### Internal authority documents

- `docs/plans/roadmap.md` — current authority through v0.38.
- `docs/plans/future-features.md` — parking lot for promotion into
  v0.39–v0.48.
- `docs/plans/allbert-jido-vision.md` — long-term vision.
- `docs/plans/v0.38-plan.md` — next implementation-ready milestone.
- ADR 0006 (Security Central), ADR 0007 (Jido boundaries), ADR 0008
  (durable confirmations), ADR 0012 (Resource Access posture), ADR 0013
  (URI-first resource identity; reserves `mcp://`, `agent://`,
  `agent+https://`), ADR 0014 (local workspace identity), ADR 0015 (app
  contract and Surface DSL), ADR 0016 (channel adapter boundary), ADR 0017
  (plugin contract), ADR 0019 (cross-surface intent enrichment), ADR 0021
  (intent/objective/capability/advisory boundary), ADR 0023 (workspace
  canvas and ephemeral surface substrate; internal A2UI bridge), ADR 0032
  / 0033 / 0035 (dynamic plugin generation / capability gap acquisition /
  codegen agents), ADR 0036 (templated creation and pattern registry —
  v0.38), ADR 0037 (Elixir/OTP sandbox backend and gate runner — v0.36).
