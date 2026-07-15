# Allbert Version 1.0 Planning — Strategic Analysis

Date: 2026-05-26
Status: planning analysis, not an implementation-ready milestone plan.
Author context: produced after v0.37.5 release closeout, while v0.38 (Templated
Creation) is the next implementation-ready milestone on the roadmap.

This document synthesizes a strategic look at what Allbert v1.0 should be from
an end-user perspective, grounded in the existing roadmap and vision, the
parked items in `docs/plans/future-features.md`, the 38 accepted ADRs, and
focused competitive research on **OpenClaw** (the closest peer) and **Hermes
Agent** (the adjacent peer). It does not replace `docs/plans/roadmap.md` or any
milestone plan. It proposes the next 12 milestones that would carry the
project from v0.38 to v1.0.

## 1. Executive Summary

- Allbert at v0.37.5 has the runtime contracts for safe local assistant work:
  registered Jido actions, durable confirmations, Settings Central, Security
  Central, local traces, markdown memory, jobs, objectives, reviewed plugin
  apps, Allbert Home theming/layout overrides, a default-off Elixir/OTP
  sandbox/gate runner, and a default-off dynamic draft/live integration path
  for reviewed read-only and delegated memory/network action artifacts.
- The closest peer in the market is **OpenClaw** — also local-first, also
  markdown-memory, also Canvas-based, also plugin/skills-based, also
  multi-channel. **Allbert is not behind OpenClaw on architecture. It is ahead
  on architecture and behind on shipped capability.** Most gaps are delivery
  gaps, not design gaps.
- The decisive missing pieces from an end-user perspective are: MCP client
  (for integrations), more channels (Discord/Slack/WhatsApp/Signal/iMessage),
  voice, browser, vision, easier LLM provider swap, first-run onboarding, and
  a reviewed plugin index. Each of these can be layered onto the proven
  substrates without re-architecting.
- The user-confirmed direction is: ship v0.38 lean as planned, position 1.0
  in the OpenClaw / Hermes Agent personal-assistant shape, and add MCP client
  as the first capability milestone after foundation work.
- Proposed sequence: **12 milestones from v0.38 to v1.0**, grouped in five
  phases (Foundation → Integration Platform → Multi-Modal → Operator
  Workflows → Ecosystem & Production). At the project's recent cadence this
  is roughly six months of work.
- The strategic moat is the safety architecture. As long as the v0.38 → v1.0
  sequence preserves Security Central, the confirmation model, the
  sandbox/gate runner, and the reversible dynamic loader, Allbert ships at
  v1.0 as **the safest personal assistant runtime with feature parity to
  OpenClaw and Hermes**.

## 2. Project Context: Where Allbert Is Today

At `v0.37.5`:

- `/workspace` is the operator home. Chat is the primary spine, the launcher
  is view-only, and Canvas shows one destination at a time (Output, an app,
  or a workspace tool).
- StockSage is the reference plugin app. It exercises the app, objective,
  security, native-agent, LiveView surface, memory-sync, and canvas contracts
  through a concrete financial-analysis workflow.
- Channels: CLI (`mix allbert.ask`), Phoenix LiveView (`/workspace`),
  Telegram, and email.
- Memory: markdown-first under `<ALLBERT_HOME>/memory` with review,
  promotion, correction, pruning, and metadata-only memory intent candidates
  (v0.21).
- Objectives: durable multi-step work across turns/channels/jobs (v0.24
  Objective Runtime, ADR 0021).
- Safety: 38 ADRs of binding decisions, Security Central with explicit
  permission classes and risk tiers, durable confirmations under Allbert
  Home, Resource Access Security Posture with URI-first identity, default-off
  Elixir/OTP sandbox/gate runner (v0.36), default-off dynamic draft/live
  integration path with reversible loader (v0.37).
- Workspace UI: Surface DSL with 42-component catalog, HMAC-signed Fragment
  emission, per-thread Canvas + ephemeral surfaces, multi-tab sync, offline
  Yjs/IndexedDB editing, WCAG-oriented accessibility, mobile responsive
  layout, dark/light/system theming, sanitized user theme/snippet overrides
  (v0.35).

The next implementation-ready milestone on the roadmap is **v0.38 Templated
Creation**: vetted plugin/app/LLM-tool/scheduled-flow/code templates via Mix
tasks, operator workspace flows, and a Canvas Create surface.

## 3. Competitive Landscape

### 3.1 OpenClaw (primary comparator)

OpenClaw is an open-source TypeScript/Node.js personal AI assistant
(mascot is *Molty*, a space lobster; tagline "the lobster way"). It is the
closest peer because the architecture choices match Allbert's almost 1:1.

What ships in OpenClaw today:

- **Gateway control plane**: single local daemon process orchestrating
  sessions, channels, tools, and events. Runs as launchd/systemd, Docker, or
  foreground. SSH/Tailscale for remote access.
- **Channels (50+)**: WhatsApp, Telegram, Slack, Discord, Signal, iMessage,
  IRC, Microsoft Teams, Matrix, Feishu, LINE, Mattermost, Nextcloud Talk,
  Nostr, Synology Chat, Tlon, Twitch, Zalo, WeChat, QQ, WebChat, plus native
  macOS/iOS/Android surfaces. All bundled channels load through a
  standardized setup/secret contract.
- **Memory**: canonical `MEMORY.md`. Since 2026.4.10, an **Active Memory
  sub-agent** runs before every reply, pulling preferences, historical
  context, and prior session details automatically.
- **Skills**: tiered `bundled` / `managed` / `workspace` at
  `~/.openclaw/workspace/skills/<skill>/SKILL.md`. Post-hardening realpath()
  validation. Agents can self-generate skills.
- **ClawHub**: official skill marketplace — 800+ skills, 150,000+ installs
  as of March 2026.
- **First-class tools**: browser (Playwright), canvas (with A2UI), nodes
  (device pairing), cron, sessions, channel-specific actions.
- **MCP integrations**: officially supported — GitHub, Notion, Google Drive,
  Postgres. Community — Linear, Jira, Stripe, Shopify. Emerging — Figma,
  Vercel, AWS.
- **LLM providers**: Claude, GPT-5/Codex, Gemini, xAI Grok, Mistral,
  DeepSeek, local Ollama, 100+ via OpenRouter; GitHub Copilot for embeddings
  (beta). Configured as `agent.model: "<provider>/<model-id>"`. Hybrid
  escalation budget→premium based on task complexity.
- **Voice**: wake-words on macOS/iOS, continuous talk-mode on Android,
  on-device MLX synthesis on macOS (2026.4.10 experimental, marked
  production-unsafe). TTS fallback to ElevenLabs + system.
- **Multi-agent**: Task Brain control plane (2026.3.31) with heartbeat
  monitoring, parent-child task relationships, `openclaw flows list|show|cancel`
  lifecycle commands. **"Lobster" workflow engine** runs YAML-defined
  multi-step/multi-agent flows with sequential/parallel/loops/conditionals.
- **Subagent isolation**: inbound channels/accounts/peers route to isolated
  agents (per-agent workspaces + sessions). Non-main sessions run in Docker,
  SSH, or OpenShell sandboxes.
- **Personality**: `SOUL.md` defines agent identity; `AGENTS.md` for
  multi-agent coordination; `TOOLS.md` for tool exposure. Workspace root at
  `~/.openclaw/workspace`.
- **Trust model**: DM pairing for unknown senders, explicit allowlist;
  "semantic category approval" (read-ops auto-approve, execution requires
  confirmation); plugin install fail-closed by default (needs
  `dangerously-force-unsafe-install` to override); blocked env-var categories
  (proxy, TLS, Docker, AWS/AZURE/GCLOUD credentials); workspace `.env` from
  untrusted sources can't override critical controls.
- **Onboarding**: `npm install -g openclaw@latest && openclaw onboard
  --install-daemon` — step-by-step setup of gateway, workspace, channels,
  skills. macOS, Linux, Windows (via WSL2).
- **Deployment**: local daemon, Docker, DigitalOcean 1-Click ($24/mo),
  Fly.io/Render/Vercel configs included.
- **Community**: 50K Discord members, 120K r/OpenClaw, OpenClaw News,
  "The Claw Pod" podcast, Moltbook (AI-only social network, 1.4M agent
  users).

### 3.2 Hermes Agent (adjacent peer)

Hermes Agent by Nous Research shares Allbert's tagline almost verbatim
("the agent that grows with you"). It is similar to OpenClaw in shape but
broader in some dimensions and narrower in others.

Distinct features vs OpenClaw:

- 22 channels (Telegram, Discord, Slack, WhatsApp, Signal, SMS, CLI, plus
  more).
- 8 external memory providers (Honcho, OpenViking, Mem0, Hindsight,
  Holographic, RetainDB, ByteRover, Supermemory) in addition to `MEMORY.md`
  + `USER.md`.
- ACP integration for VS Code, Zed, JetBrains.
- Batch processing across hundreds/thousands of prompts for trajectory data
  generation (Nous Research training workflows).
- Multiple browser backends (Browserbase, Browser Use cloud, local Chrome
  via CDP).
- Image generation through FAL.ai (FLUX 2, GPT-Image, Ideogram V3, Recraft).
- TTS via ten provider options (Edge TTS, ElevenLabs, OpenAI TTS, MiniMax,
  Mistral Voxtral, Google Gemini, xAI, NeuTTS, KittenTTS, Piper).
- OpenAI-compatible HTTP endpoint for Open WebUI, LobeChat, LibreChat.
- Skills system explicitly compatible with the agentskills.io standard.

### 3.3 Out-of-category tools (not direct comparators)

- **OpenCode** (`opencode.ai`): terminal-first coding agent with Plan/Build
  modes, LSP integration, 75+ LLM providers, MCP. Different category —
  coding tool, not personal assistant. Listed here to disambiguate from
  OpenClaw.
- **Claude Code**: Anthropic's official terminal/desktop/IDE coding agent.
  Same different-category note.
- **Cursor**: AI-native IDE fork of VS Code. IDE-first coding tool.
- **Aider**: git-native terminal coding pair-programmer.

Pattern lessons worth keeping from these (despite the different category):
multi-provider abstraction with easy swap, headless API server mode, MCP
client adoption, IDE protocols (ACP/LSP). These map onto items already in
the Allbert roadmap or future-features list rather than driving new ones.

## 4. The Architectural Mirror — Allbert ↔ OpenClaw

The most important finding of this analysis: nearly every architectural
concept OpenClaw has shipping has a direct Allbert counterpart in code,
ADR, or named future-features parking lot.

| Concept | OpenClaw | Allbert |
|---|---|---|
| Local control plane | Gateway (Node daemon) | OTP supervision tree under `AllbertAssist.Application` |
| Channel abstraction | Standardized setup/secret contract per bundled channel | ADR 0016 channel adapter boundary, ADR 0017 plugin contract |
| Workspace root | `~/.openclaw/workspace` | `~/.allbert` (`<ALLBERT_HOME>`) |
| Memory file | `MEMORY.md` (+ Active Memory sub-agent) | Markdown memory under `<ALLBERT_HOME>/memory` with review/promotion |
| Skill directory | `~/.openclaw/workspace/skills/<skill>/SKILL.md` | `<ALLBERT_HOME>/skills/<skill>/SKILL.md` (Agent-Skills compatible, v0.03) |
| Personality file | `SOUL.md` | Reserved (future-features "system memory" / personality slot) |
| Multi-agent prompt file | `AGENTS.md` | `AGENTS.md` (exists today) |
| Multi-step orchestration | Task Brain + "Lobster" YAML workflows | Objective Runtime (`AllbertAssist.Objectives`, v0.24) |
| Subagent isolation | Per-channel isolated agents in Docker/SSH/OpenShell | `:delegate_agent` step kind + AgentRegistry (v0.24/v0.25) |
| Tool: browser | Playwright integration | Reserved future-features (Browser/Search Capture) |
| Tool: canvas | Live Canvas with A2UI | Workspace Canvas (v0.26+); internal A2UI bridge ready, public exposure deferred |
| Tool: cron | Cron tool | Scheduled jobs (v0.13) |
| Trust model | Semantic category approval + fail-closed plugins | Security Central + confirmations + permission classes + safety floors |
| Sandbox | Docker/SSH/OpenShell non-main sessions | v0.36 Elixir/OTP sandbox + gate runner |
| Self-generating skills | Mentioned as capability | v0.37 dynamic codegen + gated live integration |
| MCP | Shipping client + named integrations | Reserved `mcp://` URI (ADR 0013, v0.10 M12), no consumer |
| Skill marketplace | ClawHub (800+ skills) | Reserved (future-features "Remote Plugin Marketplace") |
| LLM provider swap | `agent.model: "<provider>/<model-id>"`, hybrid escalation | Implicit via Jido.AI model aliases; no operator UX |
| Onboarding | `openclaw onboard --install-daemon` | None |

This validates the project direction strongly: Allbert has been building the
right primitives. What is missing is delivery surface and ecosystem reach.

## 5. Honest Comparison — Where Each Is Ahead

### 5.1 Allbert is ahead of OpenClaw on

1. **Permission and safety architecture.** Security Central with explicit
   permission classes (`:read_only`, `:settings_write`,
   `:skill_script_execute`, `:package_install`, `:external_network`,
   `:objective_write`, `:workspace_canvas_write`, `:stocksage_analyze`, …)
   with risk tiers and safety floors that Settings Central cannot lower.
   OpenClaw's "semantic category approval" is coarser.
2. **Inspectable memory with explicit human review workflow.** OpenClaw's
   Active Memory auto-curates; Allbert's v0.21 memory review lets the
   operator promote, correct, and prune deliberately. Both have legitimate
   use cases, but Allbert's approach is auditable in a way OpenClaw's is not.
3. **Dynamic codegen rigor.** v0.36 sandbox + gate evidence + v0.37
   reversible live loader is more disciplined than OpenClaw's
   docker-sandboxed sessions. Generated code in Allbert remains pure
   read-only or delegates to reviewed facades; it cannot escalate authority.
4. **Surface DSL with catalog validation + signed Fragment emission.**
   OpenClaw's A2UI Canvas works, but Allbert's `AllbertAssist.Surface` +
   HMAC-signed `Workspace.Fragment.Envelope` + catalog validation is
   structurally tighter against model-generated UI attacks.
5. **OTP supervision and operational story.** Elixir/OTP supervised
   processes will outlast Node.js process management when something crashes
   mid-conversation.
6. **38 ADRs of binding decisions.** OpenClaw's documentation is good but
   the ADR discipline here is unusually rigorous.

### 5.2 OpenClaw is ahead of Allbert on

1. **Channels** — 50+ shipped vs 2. The biggest reach gap.
2. **Skill marketplace (ClawHub)** — 800+ community skills with 150K
   installs. Allbert has local-only skill discovery.
3. **MCP** — shipping client + named integrations (GitHub/Notion/GDrive/
   Postgres). Allbert has reserved URI only.
4. **Voice** — shipped (experimental). Allbert has none.
5. **Browser automation** — Playwright integration. Allbert has only
   approved URL fetches.
6. **Onboarding** — `openclaw onboard` works step-by-step. Allbert has
   `mix setup`.
7. **LLM provider flexibility surface** — `agent.model` configuration,
   hybrid escalation. Allbert has model aliases but no operator-facing swap.
8. **Workflow YAML ("Lobster")** — operator-authorable multi-step flows.
   Allbert's Objective Runtime is programmatic only.
9. **Active Memory sub-agent** — auto-pulls relevant context on every turn.
   Allbert requires explicit retrieval.
10. **Distribution/deployment** — DigitalOcean 1-click, Fly.io/Render/Vercel
    configs, npm install one-liner. Allbert needs `mix setup` and Elixir
    knowledge.

### 5.3 Neither is meaningfully ahead on

- Markdown-first memory as a concept (both have it).
- Plugin/skills architecture (both have it, with similar trust shapes).
- Local-first privacy stance (both default local).
- Multi-modal vision support (neither ships it fully yet).

## 6. End-User Gap Analysis

What a new user would notice as missing when comparing Allbert to
OpenClaw/Hermes today:

1. **Onboarding.** `git clone; mix setup` is developer-facing. No guided
   "set up your first provider, pick a workflow, connect your phone" flow.
   Already flagged in `docs/plans/future-features.md`.
2. **Easy LLM provider swap.** No `mix allbert.model <id>` equivalent;
   users cannot trivially pick Ollama, OpenAI, Claude, or OpenRouter.
3. **Multi-channel reach.** Text-only assistant on Telegram/email feels
   small compared to a Discord-native bot or a WhatsApp assistant.
4. **Voice.** Both peers let you talk to the assistant across CLI and chat
   platforms. Allbert does not.
5. **Vision / image input.** Cannot paste a screenshot and ask "what's
   this?".
6. **Browser / web research.** Can fetch an approved URL; cannot *use* the
   web like an agent.
7. **MCP client.** Every other tool in the comparison set is now
   MCP-compatible. Allbert is the only one without it.
8. **Skills discovery / sharing.** `skills.sh` import exists but no
   marketplace, no agentskills.io interop, no ClawHub-equivalent.
9. **API / IDE access.** No way to drive Allbert programmatically from
   another tool. ACP-style IDE integration does not exist.
10. **Personality / identity customization.** No explicit identity slot
    (Hermes/OpenClaw have SOUL.md).
11. **Image generation.** No FLUX/image-gen capability.
12. **Operator-authorable workflows.** Objective Runtime exists but is
    programmatic; no YAML-defined operator workflows like OpenClaw's
    "Lobster" engine.

## 7. Architectural Readiness — Substrate Inventory

Walking the dependency graph in the roadmap and the 38 ADRs, the substrate
status is:

### 7.1 Substrates already proven (lean on these)

- **Channel adapter boundary** (ADR 0016, v0.16, v0.17). Telegram + email
  prove the contract. Adding Discord, Slack, SMS, WhatsApp, Signal,
  iMessage is new code but known shape.
- **Plugin contract** (ADR 0017, v0.17). Source-tree plugins under
  `./plugins/` with manifest, actions, settings, child specs. Voice/vision/
  browser ship as plugins.
- **Resource Access Security Posture** (ADR 0012, v0.10–v0.11). URI-first
  identity with `resource_uri + operation_class + access_mode +
  downstream_consumer` authority. Browser/web research fit this model.
- **Objective Runtime** (ADR 0021, v0.24). Durable multi-step with
  `:delegate_agent`, advisory providers, observed/predicted separation.
  Operator workflow YAML and subagent delegation surfaces compose over this.
- **Action runner + Security Central + confirmations** (ADR 0006, ADR 0007,
  ADR 0008). Every effectful operation goes through one boundary. Adding
  new actions is the additive path.
- **Sandbox + gate + dynamic loader** (v0.36, v0.37). Generated code is
  policy-bounded and reversible. This is the moat vs OpenClaw/Hermes.
- **Workspace + Canvas + Surface DSL** (v0.18, v0.26, v0.32, v0.34).
  Multi-modal output rendering is solved.
- **Memory review/retrieval/index** (v0.21). Markdown memory promotion and
  metadata-only intent candidates are operational.

### 7.2 Substrates that need new ADRs

- **Microphone input as Resource Access** — voice input is a new resource
  class.
- **Audio output (TTS)** — registered action with provider profile,
  parallels v0.10 external services.
- **Image input handling** — paste/upload binary as a resource class;
  multimodal model input through the existing model alias substrate.
- **Image generation** — registered action with provider profile (FLUX,
  GPT-Image, Recraft, Ideogram).
- **Browser automation** — registered actions wrapping a sandboxed
  Playwright/Puppeteer plugin; reuses Resource Access posture for
  navigation grants.
- **MCP client** — `mcp://` URIs gain consumers; new MCP server connection
  settings; reused Approval Handoff; new permission class for MCP tool
  calls.
- **LLM provider profiles** — operator-facing provider swap UX over what
  is currently model-alias config; Jido.AI is already underneath.
- **Operator workflow YAML** — operator surface over Objective Runtime
  allowing "draft a plan in YAML, validate, run".

### 7.3 Substrates reserved but unused (good shape for reuse)

- `WorldModelProvider`, `DiffusionProposalProvider`, etc. (ADR 0021
  reserved vocabulary). The advisory provider umbrella is ready when a
  second concrete provider exists.
- `mcp://`, `agent://`, `agent+https://` URI schemes (v0.10 M12). Inert
  metadata exists; MCP client just needs a consumer.
- A2UI internal mapping bridge (v0.26 internal bridge per ADR 0023 §8).
  Public HTTP exposure is the missing piece.
- Memory namespaces (declared by apps since v0.27, consumed by sync since
  v0.29). A new `identity` namespace would host the personality/SOUL slot
  without inventing a new format.

## 8. User Decisions That Shaped This Plan

Three decisions were taken explicitly during this analysis:

1. **1.0 identity**: Personal-assistant shape (OpenClaw / Hermes shape).
   Not the Claude Code / OpenCode coding-agent shape. Allbert serves
   personal automation, knowledge work, and assistant tasks across channels;
   coding is one workflow among many, not the center.
2. **v0.38 scope**: Ship v0.38 lean, exactly per the published plan.
   Don't pad it with channel or provider template patterns; those land in
   their own milestones.
3. **First capability after foundation**: MCP client. This unlocks every
   MCP-compatible tool in the broader ecosystem (GitHub, Notion, Google
   Drive, Postgres, Linear, Jira, Stripe, Shopify, Figma, Vercel, AWS, …)
   in one milestone, and is small enough that it is the highest-leverage
   single investment.

These decisions are the constraints inside which the roadmap below is
drawn.

## 9. Proposed Roadmap to v1.0 — 12 Milestones, 5 Phases

### Phase 1 — Foundation (v0.38–v0.40)

| Version | Theme | Substrate work | User-visible win |
|---|---|---|---|
| **v0.38** | Templated creation (lean, as-planned) | TemplatePattern registry, Mix tasks (`mix allbert.gen.plugin/app/tool/flow`), `workspace:create` Canvas surface, security evals. No bloat. | Developers and operators scaffold capabilities in minutes; the v0.36 sandbox and v0.37 loader gain a deterministic, operator-facing entry point. |
| **v0.39** | First-Run Onboarding + Personality slot | `mix allbert.onboard` as a registered objective; new `identity` memory namespace hosts the persona file (SOUL.md-equivalent); reuses Settings Central, secret entry, and channel registration. | New users get a guided "pick provider → connect channel → first workflow" flow. Optional persona file shapes assistant tone. |
| **v0.40** | LLM Provider Flexibility + Active Memory | `providers.profile.*` Settings Central keys; `mix allbert.model` command; provider doctor; shipped Ollama profile. Active Memory: deterministic retrieval before each reply, scoped to current thread + active app + identity namespace (graduates the "system memory" parking-lot entry from future-features). | "Use any model you want" — Ollama, OpenAI, Claude, OpenRouter, Bedrock. Conversations feel context-aware without manual recall. |

### Phase 2 — Integration Platform (v0.41–v0.42)

| Version | Theme | Substrate work | User-visible win |
|---|---|---|---|
| **v0.41** | **MCP Client Integration** | Consumer for reserved `mcp://` URIs (ADR 0013, v0.10 M12). New ADR for MCP tool trust tier with `:mcp_tool_call` permission class and confirmation safety floor. Reuses Approval Handoff for tool calls. Settings Central holds MCP server connection configs. First four named MCP servers operationally tested: **GitHub, Notion, Google Drive, Postgres** — matching OpenClaw's official set. | Allbert gains the entire MCP-compatible ecosystem in one milestone. Tens of integrations become operator-configurable without per-integration plugin work. |
| **v0.42** | Channel Pack 1: Discord + Slack | Two new plugin packages under `./plugins/` reusing the v0.16 channel adapter boundary. Reuses Approval Handoff rendering, identity-mapping, durable event dedupe. | Allbert in your team chat and community server, not just personal Telegram. |

### Phase 3 — Multi-Modal (v0.43–v0.45)

| Version | Theme | Substrate work | User-visible win |
|---|---|---|---|
| **v0.43** | Voice Modality (experimental) | New ADR: audio resource class + TTS action with provider profile (Edge TTS default free option, ElevenLabs, on-device MLX where possible). Microphone capture as Resource Access consumer with explicit per-session confirmation. Voice-mode subscribers for channels that support audio. | Talk to Allbert from CLI and Discord; hear it back. Marked experimental in 1.0; honest parity with OpenClaw's experimental voice. |
| **v0.44** | Browser / Web Research | Sandboxed Playwright plugin under `./plugins/allbert.browser/`. Navigation grants via Resource Access posture (`browser://session/<id>` URIs with `:navigate`, `:click`, `:fill`, `:submit` operation classes). Remembered grants per-domain per-operation. New ADR for browser permission policy. | "Research X for me" with confirmation per navigation scope. The first time Allbert can act on the open web like an agent. |
| **v0.45** | Vision + Image Generation | Image input as a new resource class (paste/upload binary). Image generation as a registered action with provider profile (FLUX, GPT-Image, Recraft, Ideogram). Reuses v0.40 provider flexibility work. | Paste a screenshot and ask about it. Generate diagrams and images on demand. |

### Phase 4 — Operator Workflows (v0.46–v0.47)

| Version | Theme | Substrate work | User-visible win |
|---|---|---|---|
| **v0.46** | Operator Workflow YAML + Subagent Delegation UX | Operator-authorable multi-step workflows defined in YAML (Allbert's "Lobster" equivalent), validated and executed through Objective Runtime. Operator-facing subagent delegation: spawning concurrent specialist agents from a parent objective. Substrates exist (v0.24 + v0.25); v0.46 is the operator surface. | Operators can compose multi-step automations without writing Elixir. Concurrent specialist agents observable from `/workspace`. |
| **v0.47** | Channel Pack 2: WhatsApp + Signal + iMessage + Matrix | Four more channels reusing v0.42 patterns. iMessage via macOS-only adapter, Matrix via standard protocol, WhatsApp via Business API or whatsapp-web bridge, Signal via signald or libsignal. | Allbert reachable on personal-messaging platforms, not just team/community chat. |

### Phase 5 — Ecosystem & Production (v0.48–v1.0)

| Version | Theme | Substrate work | User-visible win |
|---|---|---|---|
| **v0.48** | Plugin Marketplace (reviewed index) | Allbert's ClawHub-equivalent at smaller scale. Reviewed-source-only first phase. Index hosted under a curated GitHub org or project domain. Reuses v0.36 sandbox + v0.37 loader for any code-bearing imports. Marketplace UI in Workspace. | Discover and install reviewed plugins from a curated index, not just hand-clone repositories. |
| **v0.49** | A2UI Public Bridge + ACP IDE Integration | Promote v0.26 internal AG-UI bridge to a public HTTP/WS endpoint with auth, rate limits, and CSP reconciliation per future-features. Add ACP (Agent Client Protocol) for VS Code, Zed, JetBrains. | External clients can drive Allbert through standard protocols. Editor-resident workflows become possible. |
| **v1.0** | API Server + Remote Sync + Polish + 1.0 commitment | OpenAI-compatible HTTP endpoint (rate-limited, audited). Allbert Home portability/sync (future-features "Remote Sync And Profile Export/Import"). Comprehensive operator docs. Performance hardening. CSP final reconciliation. 1.0 stability commitment for all public contracts. | Programmable, embeddable, portable. The 1.0 release. |

**Total: 12 milestones from v0.38 to v1.0. At the project's recent cadence
(roughly one minor every 5–7 days), this is approximately six months of
focused work.**

## 10. Three Principles Driving the Ordering

1. **Foundation before fan-out.** v0.38 (templates) → v0.39 (onboarding) →
   v0.40 (providers + active memory) precede capability expansion because
   every later milestone reuses them.
2. **MCP early, channels next, modality after.** MCP at v0.41 unlocks
   tools immediately and absorbs what would otherwise have been a separate
   "first-wave integrations" milestone. Channels at v0.42 and v0.47 broaden
   reach. Voice / vision / browser at v0.43–v0.45 broaden modality. Each
   step compounds the previous.
3. **Operator workflow YAML belongs after MCP and multi-modal, not before.**
   Operator-authorable flows are only interesting when they can call MCP
   tools, talk over voice, drive a browser, or analyze an image. Putting
   them earlier would be a UI shell over what we already have.

## 11. What's Deferred Past v1.0

These remain in `docs/plans/future-features.md` until promoted:

- **System memory / distillation** (small-model personality distillation).
  Needs trace quality and operator review patterns from real deployments
  first. The v0.40 Active Memory addition is a deterministic precursor, not
  the full research direction.
- **Hosted multi-user authorization model.** Only graduated when there is
  a real hosted deployment customer.
- **Remote Secrets Manager** (OS keychain, cloud secret vault adapters).
  Niche; local encrypted Settings store stays default.
- **Advisory Providers / World Models** beyond the v0.33 narrow intent/
  route subset. Waits for a second concrete provider.
- **Native UI surface** (packaged macOS / Windows app, not the web UI).
  Packaging concern, not capability concern.
- **Container / microVM sandboxes beyond v0.36 Level 1.** Only when a real
  workflow needs deeper isolation than the current Elixir/OTP sandbox plus
  Docker/Podman/runsc backends provide.
- **Scripting Engine Interface** (embedded Lua/Python/JS). Elixir +
  registered actions + plugin contract cover the need.
- **StockSage Native/Python Parity Tuning.** StockSage-internal; not
  gating 1.0.
- **Deep Remote Document Extraction** (broad document formats: PDF,
  Office, archives). Wait for browser/web research to settle first.

## 12. Architecture Decisions This Plan Asks You to Accept

These are the implicit binding decisions that follow from the proposed
sequence. Each will need an ADR before its milestone is implemented.

1. **MCP client trust tier needs a new ADR.** MCP tools come from external
   servers; their tools should not auto-grant action-execution authority.
   Proposed: new permission class `:mcp_tool_call` with confirmation
   safety floor, modeled on `:external_network`. The MCP tool's stated
   schema is descriptive only — Allbert remains the policy authority. MCP
   server configurations sit in Settings Central; secrets in the encrypted
   secret store.
2. **Voice as resource class, not channel.** Microphone capture and TTS
   playback are Resource Access consumers (URI-addressed), not a separate
   "voice channel" type. Channels remain the messaging boundary; voice
   composes with any channel that supports audio.
3. **Browser actions reuse Resource Access posture.** Navigation grants
   are `resource_uri = browser://session/<id>` with `operation_class` like
   `:navigate`, `:click`, `:fill`. Remembered grants apply per-domain
   per-operation. This avoids inventing a parallel permission model.
4. **Image input is a resource class, image generation is an action.**
   Symmetric with audio: input is a Resource Access consumer; output is a
   registered action with provider profile.
5. **A2UI bridge graduates earlier than future-features assumed.** The
   v0.26 internal bridge can become a public HTTP endpoint in v0.49
   (paired with ACP). This pulls in CSP work that future-features was
   deferring to post-v0.38.
6. **Integrations are MCP-first, plugin-second.** Most named integrations
   ship as MCP server configurations in v0.41. Some may later be promoted
   to native plugin apps when they need richer surface (settings panels,
   custom Canvas cards, memory namespace). Allbert core never grows a
   dependency on Google APIs, iCloud, etc. — those live in plugins or in
   downstream MCP servers.
7. **Operator workflow YAML reuses Objective Runtime.** Not a new
   execution engine. The YAML format is a declarative input that produces
   objective steps, validated by an explicit schema, executed through
   `Actions.Runner.run/3` + Security Central + confirmations as usual.
8. **Channel adapters do not invent new permission classes.** They reuse
   existing Approval Handoff rendering, identity mapping, dedupe, and
   redaction posture. Each new channel is a plugin under `./plugins/`
   following the v0.16 substrate.

## 13. Key Differences from Earlier Iterations of This Plan

This document amalgamates three prior iterations of the analysis. The
significant changes from the earliest draft are:

| Earliest draft | Final | Reason |
|---|---|---|
| Included Plan/Build agent modes (OpenCode pattern) | Dropped | That was OpenCode-only. OpenClaw doesn't have it. Operator subagent delegation + workflow YAML is the better goal. |
| Separate "First-Wave Integration Apps" milestone | Mostly absorbed into v0.41 (MCP) | OpenClaw delivers integrations via MCP; Allbert can too. Named integrations as MCP servers ship in v0.41 itself, removing the need for a bespoke integrations milestone. |
| Personality slot at v0.49 | Moved into v0.39 | OpenClaw's SOUL.md ships with onboarding. Doing it at v0.39 is small and high-impact. |
| Active Memory not on plan | Added to v0.40 | OpenClaw's Active Memory sub-agent is a real UX win. Future-features has the parking-lot entry ready to graduate. |
| Workflow YAML not on plan | Added to v0.46 | OpenClaw's "Lobster" engine highlights this gap. Allbert has the substrate (Objectives) but not the operator surface. |
| A2UI bridge as separate item | Paired with ACP IDE in v0.49 | Both are external-protocol bridges that need CSP work; pair them. |
| LSP integration discussed | Dropped | OpenCode pattern, not relevant to personal-assistant 1.0. |
| Session sharing via URLs | Dropped | OpenCode pattern, not relevant. Remote Sync (v1.0) is the local-first answer. |
| 13 milestones | 12 milestones | MCP absorbing integrations. |

## 14. The Strategic Reframe

After the OpenClaw research, the clean way to state Allbert's position is:

> Allbert is not behind OpenClaw on architecture. It is ahead on
> architecture and behind on shipped capability. The roadmap to 1.0 is not
> a rewrite — it is a 12-milestone delivery push that reuses substrates
> already proven through v0.37.

The decisive milestones are **v0.41 (MCP)** and **v0.42 + v0.47 (channels)**.
Those three close most of the channels/integrations gap. Voice (v0.43) and
Browser (v0.44) close the multi-modal gap. Everything else is polish that
1.0 needs but is not the strategic moat.

The strategic moat — Allbert's actual advantage over OpenClaw and Hermes —
is the safety architecture. As long as the v0.38 → v1.0 sequence does not
compromise Security Central, the confirmation model, the sandbox/gate
runner, or the reversible dynamic loader, Allbert ships at v1.0 as **the
safest personal assistant runtime with feature parity to OpenClaw and
Hermes**. That is a defensible 1.0 positioning.

## 15. Concrete Next Steps

If you want to act on this analysis:

1. **This week**: Promote three entries from
   `docs/plans/future-features.md` into named roadmap milestones with
   skeleton plan docs:
   - First-Run Onboarding → v0.39
   - LLM Provider Flexibility + Active Memory → v0.40
   - MCP Client Integration → v0.41
   Even stub plans help the work get sized and reviewed.
2. **Parallel to v0.38 implementation**: Draft the MCP trust-tier ADR
   (new permission class `:mcp_tool_call` with confirmation safety floor;
   trust tier policy for MCP server connections; Resource Access posture
   for MCP-fetched resources). This is the highest-leverage architectural
   document to draft early because v0.41 carries the most ecosystem weight.
3. **Update `docs/plans/future-features.md`**: Mark "Operator first run
   onboarding", "system memory / Active Memory", "Operator workflow YAML",
   "MCP And Agent URI Resource Access", "Additional Remote Channel Adapters"
   (Discord, Slack, WhatsApp, Signal, iMessage, Matrix), and "Browser/Search
   Capture" as **graduated** to specific v0.39–v0.46 slots. The "Remote
   Plugin Marketplace" entry graduates to v0.48. The "Post-v0.38 UI Protocol
   Interop" entry graduates partially to v0.49 (A2UI public bridge + ACP).
4. **Optional first plan draft**: v0.39 First-Run Onboarding is the
   smallest, least controversial, and highest-leverage milestone to plan
   first. It composes existing primitives (registered objective + Settings
   Central + provider profiles + memory namespace + channel registration)
   and unblocks v0.40 sequencing.

## 16. Sources

### Primary comparator (OpenClaw)

- [OpenClaw — official site](https://openclaw.ai/)
- [OpenClaw on GitHub (openclaw/openclaw)](https://github.com/openclaw/openclaw)
- [Petronella: OpenClaw 2026 Self-Hosted AI Agent Setup Guide](https://petronellatech.com/blog/openclaw-ai-agent-guide-2026/)
- [DigitalOcean: What is OpenClaw](https://www.digitalocean.com/resources/articles/what-is-openclaw)
- [Globussoft: 10 Powerful Features of OpenClaw](https://globussoft.ai/openclaw-ai-agents-features/)
- [OpenClaw News: The OpenClaw Ecosystem in 2026 (ClawHub map)](https://openclawnews.online/article/openclaw-ecosystem-2026)

### Adjacent peer (Hermes Agent)

- [Hermes Agent — features overview](https://hermes-agent.nousresearch.com/docs/user-guide/features/overview)
- [Hermes Agent — main site](https://hermes-agent.org/)
- [Hermes Agent on GitHub (NousResearch/hermes-agent)](https://github.com/nousresearch/hermes-agent)

### Out-of-category reference (coding agents — different category, listed for disambiguation)

- [OpenCode AI — terminal coding agent](https://opencode.ai/)
- [OpenCode CLI docs](https://opencode.ai/docs/cli/)
- [Claude Code vs Cursor 2026 comparison (Northflank)](https://northflank.com/blog/claude-code-vs-cursor-comparison)
- [DigitalOcean: 10 Claude Code Alternatives 2026](https://www.digitalocean.com/resources/articles/claude-code-alternatives)

### Internal references

- `docs/plans/roadmap.md` — full milestone list through v0.38
- `docs/plans/future-features.md` — parking-lot entries that graduate into v0.39–v0.49
- `docs/plans/allbert-jido-vision.md` — long-term vision
- `docs/plans/archives/v0.38-plan.md` — next implementation-ready milestone
- ADR 0013 (URI-first resource identity, reserves `mcp://`)
- ADR 0016 (channel adapter boundary)
- ADR 0017 (plugin contract)
- ADR 0021 (intent/objective/capability/advisory boundary)
- ADR 0023 (workspace canvas and ephemeral surface substrate; internal A2UI bridge)
- ADR 0032, 0033, 0035 (dynamic plugin generation / capability gap acquisition / codegen agents)
- ADR 0036 (templated creation and pattern registry — v0.38)
- ADR 0037 (Elixir/OTP sandbox backend and gate runner — v0.36)
