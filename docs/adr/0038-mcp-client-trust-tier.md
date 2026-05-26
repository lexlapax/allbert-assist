# ADR 0038: MCP Client Trust Tier

## Status

Proposed for v0.40 MCP Client Integration (`docs/plans/v0.40-plan.md`).

## Context

ADR 0013 reserves `mcp://` as an inert resource identity. v0.40 promotes MCP
client calls from parked metadata to executable capability. MCP servers expose
tools, schemas, and resources, but those declarations cannot become authority
inside Allbert.

## Decision

MCP client integration adds an explicit Allbert trust tier:

- MCP server configuration lives in Settings Central under `mcp.servers.*`.
- MCP secrets use Settings Central secret refs.
- MCP tools/resources are descriptive metadata until consumed by registered
  Allbert actions.
- MCP resources use `mcp://<server-id>/<encoded-uri>`.
- Add `:mcp_tool_call` and `:mcp_resource_read` permission classes.
- Confirmation policy may be tightened per server/tool, but not loosened below
  the safety floor defined by Security Central.
- MCP stdio/HTTP transports are adapters, not execution authority.

## Consequences

MCP can unlock ecosystem integrations without importing MCP's trust model.
Every MCP effect must still pass through `Actions.Runner.run/3`, Security
Central, confirmations, Resource Access, traces, and audits.

## Non-Goals

- No MCP Apps iframe model.
- No `agent://` execution.
- No automatic trust from tool schemas.
- No code-bearing plugin install through MCP.
