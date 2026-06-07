# ADR 0044: Public Protocol Exposure (MCP Server Only)

## Status

Proposed for v0.52b MCP Server Mode (`docs/plans/v0.52b-plan.md`).

Scope tightened in the post-v0.37 planning pass: v1.0 public protocol exposure
is **MCP server mode only**. OpenAI-compatible local HTTP API, ACP server
mode, and public AG-UI/A2UI bridge are parked post-1.0 in
`docs/plans/future-features.md` under "Public Protocol Interop".

## Context

v0.40 ships MCP **client** integration: Allbert calls registered actions
against configured MCP servers under Settings Central, Resource Access, and
Security Central policy. The symmetric question is whether Allbert should also
expose itself as an MCP **server** so external agents (Claude Desktop,
Cursor, ChatGPT MCP clients, other agent runtimes) can call Allbert's actions
and read Allbert's memory namespaces.

The original v0.52 plan bundled MCP server with OpenAI-compatible HTTP API,
ACP server mode, and public AG-UI/A2UI bridge under one "public protocol
exposure" policy. The post-v0.37 planning pass split these because:

- **MCP server mode** is the highest-value protocol surface: it integrates
  Allbert directly with the most widely-adopted agent ecosystem in late 2026
  (Claude Desktop, Cursor, JetBrains MCP, several editor extensions).
- **OpenAI-compatible API** has unclear operator demand. Most operators use
  Allbert through CLI or workspace; few want Allbert to pretend to be OpenAI.
  Parked until concrete demand exists.
- **ACP server mode** has narrower adoption than MCP. Editor integration via
  MCP server covers the same operator need with broader client compatibility.
  Parked.
- **Public AG-UI/A2UI bridge** is currently internal-only and test-only
  (v0.26). Promoting to a public HTTP/WS endpoint expands surface area we are
  not ready to freeze at 1.0. Parked.

Bundling all four would have shipped three surfaces with weak operator
justification and locked AG-UI/A2UI prematurely. The single-surface scope
keeps the v0.52b ADR focused.

## Decision

v0.52b implements MCP server mode under the following rules:

- Allbert MCP server exposes **registered actions as MCP tools** and **app
  memory namespaces as MCP resources**. Settings, secrets, raw runtime
  signals, and confirmation-storage internals are not exposed.
- The exposed tool set is operator-configurable in Settings Central. The
  default tool set is empty; operators explicitly enable tools.
- The exposed memory resource set is operator-configurable per app
  namespace. Default-empty; explicit enablement.
- External MCP clients **never receive more authority than local workspace
  users**. Every effectful call still routes through `Actions.Runner.run/3`,
  Security Central, Resource Access, confirmations, traces, and audits.
- External MCP clients **cannot approve their own confirmations**. Approval
  Handoff remains operator-owned and renders through workspace or origin
  channel. An external MCP client that triggers a confirmation-needing tool
  sees a `:confirmation_pending` response with the confirmation id; the
  operator approves through their usual surface.
- MCP server transport supports stdio (for editor/desktop integrations) and
  optionally HTTP streamable mode (where a public endpoint exists and CSP
  policy permits). HTTP transport adds the v0.35 CSP baseline reconciliation.
- Authentication for HTTP transport: a per-client token issued through
  Settings Central. Tokens are encrypted at rest and never logged.
- Rate limits, redaction, and audit policy apply uniformly: external clients
  see the same redacted responses as local workspace users.

## Consequences

- Allbert becomes reachable from the MCP-client ecosystem without bringing
  three unproven protocol surfaces into 1.0.
- Operators who want OpenAI-compatible API, ACP, or AG-UI/A2UI access track
  the parked entries in `future-features.md` and can revisit post-1.0 when
  operator demand or external-protocol stability warrants it.
- Tool/resource exposure is opt-in. An empty exposure is a valid 1.0
  configuration.
- The v0.53 security eval sweep covers MCP server mode (client/tool isolation,
  cross-client identity confusion, prompt injection through MCP request
  payload, self-approval denial, resource-scope leakage) without needing to
  cover three additional protocol surfaces.

## Non-Goals

- No OpenAI-compatible local HTTP API in 1.0.
- No ACP server mode in 1.0.
- No public AG-UI/A2UI bridge in 1.0.
- No hosted multi-user authorization model.
- No cloud sync service.
- No remote UI code execution.
- No protocol-specific permission bypass.
- No external-client self-approval of confirmations.
- No exposure of raw runtime signals, secrets, settings store internals, or
  confirmation storage.
