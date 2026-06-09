# WIP: Roadmap restructure v0.51–v0.57 (TEMPORARY working notes — delete after roadmap reconciled)

Status: planning, decisions resolved 2026-06-09. Scratch tracking; not authority.

## Resolved decisions (operator, 2026-06-09)
1. **Terminology**: use a DIFFERENT UI label entirely — avoid both "thread" and "session". Proposed label **"Chats"** (consumer-friendly; the durable `Conversations.Thread` stays the internal name; existing volatile `Session.Scratchpad` untouched). → CONFIRM the exact word (Chats vs Conversations).
2. **Web UX redo = re-layout/re-skin** the existing `/workspace` Surface substrate (ADR 0023/0024 kept): chat becomes THE primary surface, ephemeral surfaces become popups/modals, canvas demoted to launcher/secondary, labels cleaned up. No canvas removal; app/surface contract preserved.
3. **Ordering**: Intent deepening moves BEFORE the Web UX redo.
4. **MCP** promoted to a full release AND expanded in scope (beyond the current v0.52b point-release content). → RESEARCH which parked items to pull in.

## Finalized renumbering + sequence

| Current | New | Title | Change |
|---|---|---|---|
| v0.50 | v0.50 | Artifacts Central | DONE |
| v0.50b | v0.50b | Artifacts Browser | DONE |
| v0.52b | **v0.51** | MCP Server Mode (expanded, full release) | promote + de-"b" + expand |
| v0.51 | **v0.52** | Channel Pack 1 — Discord & Slack | renumber |
| v0.52 | **v0.53** | Channel Pack 2 — WhatsApp, Signal, Matrix | renumber |
| — | **v0.54** | Intent Deepening (chat quality) | NEW |
| — | **v0.55** | Web UX/UI Redo (chat-primary, ephemeral→popup, relabel) | NEW |
| — | **v0.56** | Channel Parity + TUI/Terminal Channel | NEW |
| v0.53 | **v0.57** | Hardening, Export/Import, Settings Migration, Final RC | renumber |
| v1.0 | v1.0 | Stability Release & Public Contract Freeze | unchanged (review acceptance-matrix version refs) |

File renames (highest-first to avoid clobber), each = plan + request-flow:
1. v0.53-* → v0.57-*
2. v0.52-* → v0.53-*
3. v0.51-* → v0.52-*
4. v0.52b-* → v0.51-* (drop the "b")
5. Create v0.54-*, v0.55-*, v0.56-*.

## Zoom-out facts
- Channels (ADR 0016): plugin `channels/0`; Telegram + Email plugins; CLI is a `channel: :cli` label, not a plugin. Primitives `{:list,:button,:typed_command,:link}`. Parity matrix implicit in `primitives` + ADR 0016 adapter table.
- Intent (ADR 0019, 0034): `Intent.Engine.decide/1`, `IntentAgent`, advisory `Classifier`, `Descriptor`/`Handoff`. Per-turn proposal infra. ADR 0019 §violations lists what needs new ADRs.
- Web UX (ADR 0023, 0024): `/workspace` single surface; canvas = durable per-thread tiles; ephemeral = task-scoped overlays (16/thread); already chat-left-primary 2-pane; Surface DSL + 42-component catalog.
- ⚠ `session` already taken (volatile `Session.Scratchpad`); resolved by using a different UI label.

## RESEARCH PLAN (do before writing each version's plan/request-flow)

**R0 — Shared.** Re-confirm the v1.0 acceptance matrix + every cross-doc reference to v0.51/v0.52/v0.52b/v0.53 (roadmap, ADRs, agent-context-map, vision, future-features, operator/dev docs, older plans) — same exhaustive grep sweep used in the v0.50 insert. Output: complete edit-site map.

**R1 — v0.51 MCP Server Mode (expanded).** Base = current v0.52b plan + ADR 0044 (public protocol exposure) + ADR 0038 (MCP client trust tier). Questions: what does `hermes_mcp` (deps) support for SERVER mode? Which parked items to pull in (OpenAI-compatible API surface? ACP server? AG-UI/A2UI bridge?) and what stays post-1.0? Auth/trust-tier depth for an exposed server. Sources: Context7 `hermes_mcp` + MCP spec; ADR 0044/0038; existing `mix allbert.mcp` client. Deliverable: expanded v0.51 plan + request-flow + ADR 0044 amendment.

**R2 — v0.54 Intent Deepening.** Questions: what are ADR 0019/0034's stated limits, and what does "deeper so chat works well" mean concretely — better classification, multi-turn/clarification UX, intent for a chat-primary surface, disambiguation, follow-up handling? Sources: ADR 0019/0034, `Intent.Engine`/`Classifier`/`Descriptor`, intent traces; how chat-first assistants route intent. Deliverable: v0.54 plan + request-flow + possible ADR 0019/0034 amendment.

**R3 — v0.55 Web UX Redo.** Questions: clarify "Hermes" reference (hermes_mcp UI? a chat-UI design ref?). Map ChatGPT/Claude chat-UX patterns (message-level affordances, artifacts/popovers, streaming, model/session switcher) onto the Surface DSL + 42-component catalog; ephemeral→modal/popover; canvas demotion; the "Chats" relabel migration (UI strings only). Sources: ADR 0023/0024, WorkspaceLive, Surface catalog; design refs. Deliverable: v0.55 plan + request-flow + ADR 0024 amendment; **confirm UI label + Hermes ref with operator**.

**R4 — v0.56 Channel Parity + TUI.** Questions: build the explicit channel capability/parity matrix (primitives, attachments, streaming, identity, approvals per channel: web/Telegram/email/Discord/Slack/mobile). Promote CLI to a real channel? Elixir TUI options for a persistent terminal channel — `Ratatouille` vs `Owl` vs raw — and how a TUI plugs into the channel contract (ADR 0016) rather than `mix allbert.ask`. Sources: Context7 `ratatouille`/`owl`; ADR 0016; channel plugins. Deliverable: v0.56 plan + request-flow + ADR 0016 amendment (parity matrix + TUI channel).

**R5 — v0.57 Hardening (was v0.53).** Mostly inherit current v0.53 content; reconcile that the 1.0 freeze now follows three extra versions. Confirm export/import + settings migration still target the right surface set (now incl. MCP server, new UX, TUI). Deliverable: renumbered v0.57 + 1.0 acceptance-matrix reconciliation.

## Renumbering + re-roadmap EXECUTION plan (after research, on operator GO)
1. `git mv` the 8 files (rename order above) + create 6 new files (3 versions × plan+rf).
2. Sentinel-renumber every v0.51/v0.52/v0.52b/v0.53 cross-reference across docs (roadmap, ADRs 0016/0038/0040/0041/0043/0044/0046, agent-context-map, vision, future-features, operator/dev docs, older plans, v1.0 docs) — same placeholder technique as the v0.50 insert, with the historical-shift-note exceptions preserved.
3. Roadmap: re-order the section sequence (MCP before channels), insert the 3 new sections + backlog entries, retarget "Next milestone"/sequencing prose, reconcile the 1.0 acceptance matrix version refs.
4. New ADRs/amendments: ADR 0044 (MCP expansion), ADR 0024 (UX redo), ADR 0016 (parity+TUI), ADR 0019/0034 (intent), + any new ADR for the chat-primary surface decision.
5. agent-context-map + jido-vision reconciled with the new sequence.

## Open items — RESOLVED (operator, 2026-06-09)
- UI label: **"Conversations"** (matches internal `Conversations` module; `Thread` stays the internal name; volatile `Session.Scratchpad` untouched).
- "Hermes" ref: **https://hermes-agent.nousresearch.com/** (Nous Research Hermes agent UI) — R3 studies it + ChatGPT + Claude. WebFetch during R3.
- v0.51 MCP expansion includes: **OpenAI-compatible API + ACP server** (plus the MCP tools/resources surface). **AG-UI/A2UI stays parked post-1.0.** → ADR 0044 amendment re-decides these two.
- v1.0 boundary: **stays immediately after v0.57** (no v1.0 rescope).
