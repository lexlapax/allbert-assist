# ADR 0044: Public Protocol Exposure (MCP Server, OpenAI-Compatible API, ACP Server)

## Status

Accepted at v0.51 M1 for Public Protocol Surfaces (`docs/plans/archives/v0.51-plan.md`).

Proposed amendment (v0.51, 2026-06-09 restructure): v0.51 is promoted to a
full release and expands to three public surfaces — MCP server, an
OpenAI-compatible HTTP API (`/v1/chat/completions`), and an ACP server. The
earlier MCP-server-only tightening is superseded. Public AG-UI/A2UI and MCP
Apps iframe UI remain parked post-1.0.

All three honor the same authority rules uniformly: never more authority than a
local workspace user; every effectful call through `Actions.Runner.run/3` +
Security Central + confirmations + traces + audits; no external-client
self-approval (operator-owned Approval Handoff, `:confirmation_pending` + id).
The **inbound trust tier** — the `:public_surface_call_inbound` permission class
and floor, per-client token authentication, inbound rate-limiting, the API
secure-header posture, and the poll-by-id result-readback exposure — is decided
in **ADR 0055** (the inbound counterpart to the outbound ADR 0038). stdio
surfaces remain under ADR 0009 bounds. The non-exposable set (settings,
secrets, signals, traces, confirmation store, registry internals,
`:internal` actions, system namespaces, and confirmation-decision actions) is
unchanged and applies to all three. `hermes_mcp` provides MCP protocol framing
only; Allbert owns ingress auth and authority. This ADR (exposure: which
surfaces, what they expose) and ADR 0055 (inbound trust/auth/readback) were
accepted at v0.51 M1.

The v0.51 public surfaces are also a **text-first protocol subset**. MCP,
OpenAI-compatible Chat Completions, and ACP can carry richer content forms in
their ecosystems, but Allbert does not infer `speech_to_text`, `vision_input`,
`artifact_read`, filesystem, browser, or MCP-client authority from protocol
payload shape. Non-text OpenAI/ACP content and embedded resources are rejected
unless a later ADR/plan exposes a capability-specific route.

The MCP server also targets the protocol versions supported by the pinned
`hermes_mcp` 0.14.1 server stack (`2025-03-26` / `2025-06-18` where available).
Latest public MCP `2025-11-25` parity is future compatibility work unless the
dependency is upgraded and reverified before M3/M4. The OpenAI-compatible API is
a bounded Chat Completions shim, not full OpenAI API or Responses API parity.

## Context

v0.40 ships MCP **client** integration: Allbert calls registered actions
against configured MCP servers under Settings Central, Resource Access, and
Security Central policy. The symmetric question is whether Allbert should also
expose itself as an MCP **server** so external agents (Claude Desktop,
Cursor, ChatGPT MCP clients, other agent runtimes) can call Allbert's actions
and read enabled Allbert memory namespaces.

The 2026-06-09 roadmap restructure re-decided the public-protocol split:

- **MCP server mode** remains the highest-value agent interop surface and is
  symmetric with the v0.40 MCP client work.
- **OpenAI-compatible API** is in scope because `/v1/chat/completions` reaches a
  large client ecosystem with a bounded conversational-turn adapter rather than
  a new authority path.
- **ACP server mode** is in scope because editor agents can enter Allbert
  through stdio JSON-RPC at low marginal cost over the existing process-boundary
  story.
- **Public AG-UI/A2UI bridge** stays parked because the v0.26 bridge is
  internal/test-only and public HTTP/WS UI exposure would freeze a broader UI
  protocol surface prematurely.
- **MCP Apps iframe UI** stays parked because remote UI code, CSP expansion, and
  iframe/component reconciliation need a separate trust decision.

The expanded scope is acceptable only because all three shipped surfaces remain
thin adapters over existing Allbert runtime and action boundaries.

## Decision

v0.51 implements MCP server mode, an OpenAI-compatible API, and an ACP server
under the following rules:

- Allbert MCP server exposes **registered actions as MCP tools** and **app
  memory namespaces as MCP resources**. Tool calls dispatch through
  `Actions.Runner.run/3`. v0.51 advertises only the implemented tools/resources
  subset: no prompts, resource templates, subscriptions, or `listChanged`
  capability unless implemented and tested in this milestone.
- The OpenAI-compatible `/v1/chat/completions` endpoint enters Allbert as a
  bounded conversational turn through `Runtime.submit_user_input/1`; any
  selected effectful action still routes through `Actions.Runner.run/3`.
- ACP `session/prompt` enters Allbert as a bounded conversational turn through
  `Runtime.submit_user_input/1`; ACP `session/request_permission` maps to
  Approval Handoff but is advisory and never authorizes execution by itself.
- ACP `cwd`, `additionalDirectories`, `mcpServers`, `permissionMode`, and
  non-text content blocks are not authority. v0.51 advertises only implemented
  ACP capabilities and rejects unsupported fields instead of treating them as
  configuration. Client-supplied `mcpServers` are never imported into Allbert MCP
  client settings, discovery, or connection flows.
- The OpenAI-compatible API accepts a bounded text-chat subset. Client-supplied
  `tools`, `functions`, `tool_calls`, `tool_choice`, non-text content parts,
  `modalities`, `audio`, and unsupported structured-output or streaming options
  are rejected rather than ignored or translated into internal authority.
- Settings, secrets, raw runtime signals, confirmation-storage internals,
  registry internals, `:internal` actions, system namespaces, and confirmation-
  decision actions are not exposed through any surface.
- Because current `:agent` actions include settings/profile/credential
  operations, exposure is deny-before-allow: execution modes such as
  `:settings_read`, `:settings_write`, `:secret_write`, confirmation storage/
  decision modes, raw trace/signal access, plugin/registry internals, and local-
  process/shell-like actions are rejected before an operator allowlist can expose
  anything.
- The exposed tool and memory-resource sets are operator-configurable in
  Settings Central. Defaults are disabled and empty; operators explicitly enable
  surfaces, tools, and namespaces.
- `Actions.Registry.capabilities/0` is the action source for public tools.
  `exposure: :agent` is necessary but not sufficient: a public surface also
  requires explicit operator allowlisting, and generated/dynamic/plugin actions
  keep their existing reviewed/gated authority requirements before they can be
  public. App memory resources are sourced from app namespaces only; system
  namespaces are never enumerated and filtered late.
- External clients **never receive more authority than local workspace users**.
  Every effectful call still routes through `Actions.Runner.run/3`, Security
  Central, Resource Access, confirmations, traces, and audits.
- External clients **cannot approve their own confirmations**. Approval Handoff
  remains operator-owned and renders through workspace or origin channel. A
  confirmation-needing call sees `:confirmation_pending` or the surface-shaped
  equivalent with the confirmation id; the operator approves through their usual
  surface.
- MCP and ACP stdio transports remain under ADR 0009 bounds. HTTP-bearing
  surfaces (MCP streamable HTTP and OpenAI-compatible API) use Allbert's
  authenticated/secure-headered/rate-limited ingress rather than a second
  ingress. The inbound permission class, per-client token authentication,
  rate-limiting, API secure-header posture, and the poll-by-id result-readback
  exposure are decided in **ADR 0055** (inbound public-surface trust tier).
- Redaction and audit policy apply uniformly: external clients see the same
  redacted responses as local workspace users.
- MCP stdio keeps stdout protocol-clean (JSON-RPC/MCP messages only) and logs to
  stderr. MCP streamable HTTP uses Allbert-owned ingress constraints, including
  token auth where required, secure headers, rate limits, body caps, Origin
  validation, protocol-version handling, and documented session behavior.

## Consequences

- Allbert becomes reachable from MCP clients, OpenAI-compatible API clients, and
  ACP editor agents without creating new authority paths.
- Operators who want public AG-UI/A2UI or MCP Apps iframe UI access track the
  parked entries in `future-features.md` and can revisit post-1.0 when operator
  demand or external-protocol stability warrants it.
- Tool/resource exposure is opt-in. An empty exposure is a valid 1.0
  configuration.
- The v0.59 security eval sweep covers all three v0.51 public surfaces: client/
  tool isolation, cross-client identity confusion, prompt injection through
  inbound payloads, self-approval denial, resource-scope leakage, HTTP token
  redaction/revocation/rate-limit posture, HTTP Origin/session behavior,
  unsupported OpenAI/ACP content denial, and ACP permission-response
  non-authority.

## Non-Goals

- No public AG-UI/A2UI bridge in 1.0.
- No MCP Apps iframe UI in 1.0.
- No hosted multi-user authorization model.
- No MCP OAuth 2.1 protected-resource / authorization-server implementation in
  v0.51.
- No cloud sync service.
- No remote UI code execution.
- No protocol-specific permission bypass.
- No external-client self-approval of confirmations.
- No generic multimodal or embedded-resource ingress.
- No full OpenAI API or Responses API parity.
- No exposure of raw runtime signals, secrets, settings store internals, or
  confirmation storage.
