# ADR 0044: Public Protocol Exposure

## Status

Proposed for v0.49 Channel Pack 2 And Public Protocol Interop
(`docs/plans/v0.49-plan.md`).

## Context

v0.49 plans mobile/personal channel expansion plus OpenAI-compatible API, ACP,
MCP server, and public AG-UI/A2UI bridge surfaces. The protocol surfaces expose
Allbert to external clients and therefore need a shared policy rather than
per-protocol ad hoc authority.

## Decision

- API, ACP, MCP server, and AG-UI/A2UI exposure share one auth, rate-limit,
  CSP, redaction, trace, and audit policy.
- External clients never receive more authority than local workspace users.
- External clients cannot approve their own confirmations.
- All effectful work still routes through Runtime or registered actions.
- The v0.35 CSP baseline is explicitly re-evaluated before bridge exposure.

## Consequences

Allbert can become programmable and editor/agent-compatible without turning
external clients into a parallel authority system.

## Non-Goals

- No hosted multi-user authorization model.
- No cloud sync service.
- No remote UI code execution.
- No protocol-specific permission bypass.
