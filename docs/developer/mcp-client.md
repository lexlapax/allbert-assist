# Allbert MCP Client Developer Notes

Status: planned for v0.40. This document describes the intended module and
boundary contract for MCP Client Integration. Module names land as the v0.40
milestones complete; treat unimplemented details as planned.

These notes explain how the MCP client fits Allbert's action, security, and
resource boundaries. The authoritative decisions are in
`docs/adr/0038-mcp-client-trust-tier.md`; the milestone contract is in
`docs/plans/v0.40-plan.md`.

## The One Rule

MCP tool schemas, tool descriptions, resource lists, and tool/resource result
bodies are descriptive metadata. They never grant a permission, select an
action, create or widen a grant, or loosen a confirmation floor. Every MCP
effect passes through `AllbertAssist.Actions.Runner.run/3`, Security Central,
confirmations, Resource Access, traces, and audits — like every other
capability. MCP is one more resource consumer and one more action family, not a
second runtime.

## Modules

Planned modules under `AllbertAssist.Mcp.*` (project acronym convention is
`Mcp`, matching `Http`):

- `AllbertAssist.Mcp` — facade for resolving servers and dispatching client ops.
- `AllbertAssist.Mcp.ServerConfig` — resolves an `mcp.servers.*` entry from
  Settings Central and resolves `secret://mcp/...` refs at call time.
- `AllbertAssist.Mcp.Client` — per-server client (Hermes-backed; see Codec).
- `AllbertAssist.Mcp.Transport` — routes egress through Allbert-owned transports.
- `AllbertAssist.Mcp.Doctor` — reuses `AllbertAssist.Settings.ModelDoctor`'s
  ADR 0047 envelope.

Actions under `AllbertAssist.Actions.Mcp.*`, registered in
`AllbertAssist.Actions.Registry`:

| Action name | Module | Permission | Confirmation |
|---|---|---|---|
| `mcp_doctor_server` | `Actions.Mcp.DoctorServer` | `:read_only` | not required |
| `mcp_list_tools` | `Actions.Mcp.ListTools` | `:read_only` | not required |
| `mcp_list_resources` | `Actions.Mcp.ListResources` | `:read_only` | not required |
| `mcp_read_resource` | `Actions.Mcp.ReadResource` | `:mcp_resource_read` | grant-gated |
| `mcp_call_tool` | `Actions.Mcp.CallTool` | `:mcp_tool_call` | per call |

CLI surface: `Mix.Tasks.Allbert.Mcp` (`doctor`, `tools`, `resources`, `read`,
`call`).

## Settings

`mcp.servers.<server-id>` in `AllbertAssist.Settings.Schema`. Per-transport
validation: `streamable_http`/`sse` require `base_url` (no `command`); `stdio`
requires `command` (no `base_url`). Secret-bearing `env`/`headers` values and
`auth_ref` must be `secret://mcp/<server-id>/<name>` refs. `confirmation` is
tighten-only (`required` | `denied`). See `docs/plans/v0.40-plan.md` for the
full key list and validation rules.

## Permission And Operation Classes

Added to `AllbertAssist.Security.Policy`:

- `:mcp_tool_call` — safety floor `:needs_confirmation`. Cannot be loosened
  below confirmation; per-server policy can tighten to `:denied`.
- `:mcp_resource_read` — safety floor `:allowed`; authority comes from a
  remembered Resource Access grant per `mcp://` scope.

Added to `AllbertAssist.Resources.OperationClass`:

- operation classes `:mcp_tool_call`, `:mcp_resource_read`;
- access mode `:call`;
- scope kinds `mcp_server`, `mcp_tool`;
- default access modes (`mcp_tool_call: :call`, `mcp_resource_read: :read`).

`:mcp_resource` already exists as an origin kind. Operation class is part of the
security boundary (ADR 0011): a read grant never authorizes a tool call.

## Resource Identity

`mcp://<server-id>/<encoded-uri>`, `<server-id>` matching `[a-zA-Z0-9_-]+` and
`<encoded-uri>` the percent-encoded server resource URI. v0.40 removes `mcp` from
`@unsupported_schemes` in `AllbertAssist.Resources.ResourceURI` and adds
`normalize`, `derive`, and an encode helper; round-trip encode/decode is
lossless. `agent://` and `agent+https://` stay unsupported.
`AllbertAssist.Resources.Grants` matches grants on the canonical `mcp://` URI,
operation class, and scope kind.

## Transports

Both transports are bounded adapters; neither carries authority.

- **HTTP / SSE**: egress routes through `AllbertAssist.External.HttpClient` /
  `HttpPolicy` (SSRF blocking, host allowlist, bounded timeout/response, redirect
  denial, redaction). MCP does not open a second network path.
- **stdio**: process started with explicit argv and secret-ref-only env, bounded
  under ADR 0009 local-execution sandbox levels (no shell string, bounded
  lifecycle, audited startup).

## Codec And Dependency

v0.40 uses `hermes_mcp` for MCP protocol framing/codec only, with an
Allbert-owned transport so traffic stays inside the posture above. The M1 spike
proves the transport can be constrained; if not, v0.40 falls back to a minimal
native JSON-RPC MCP client over `Req`. Either way, MCP is a protocol-generic
dependency, not a provider SDK, so it does not violate ADR 0039.

## Doctor

`mcp_doctor_server` returns the ADR 0047 envelope (`endpoint_kind`,
`endpoint_ok`, `redacted_host`, `diagnostics`, ...) plus the MCP additive fields
`:transport_kind`, `:tools_listable`, `:resources_listable`, `:tool_count`,
`:resource_count`, `:protocol_version`. stdio servers report
`endpoint_kind: :local_endpoint`; authenticated HTTP/SSE report
`:credentialed_remote`. The doctor grants no authority and creates no grants.

## Adding A New Server Shape

1. Add an `mcp.servers.<id>` config (transport, url/command, secret refs).
2. Doctor it; confirm tools/resources are listable.
3. For CI, add a deterministic mock server fixture under `test/support` rather
   than depending on a live server. v0.40 validates GitHub, calendar, and mail
   shapes (the v0.41 consumers) plus mocks.

## Testing And Security Evals

Add rows to `AllbertAssist.SecurityFixtures.EvalInventory` (milestone `:v040`,
surface `:mcp_server_integration`) and `AllbertAssist.Security.McpIntegrationEvalTest`:
`mcp-schema-not-authority`, `mcp-tool-resource-confusion`, `mcp-prompt-injection`,
`mcp-server-impersonation`, `mcp-secret-env-redaction`, `mcp-stdio-startup-policy`,
`mcp-doctor-redacted-envelope`. Use the mock-server fixtures and assert zero
unintended transport calls for denial cases.

## Intent Routing Flip

The intent surface currently routes `mcp://` and "mcp tool/resource/call"
phrasing to `AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow`, with
tests asserting `status == :unsupported`. v0.40 flips
`AllbertAssist.Agents.IntentAgent`, `AllbertAssist.Intent.Engine`, and
`AllbertAssist.Intent.Ranker` to the MCP actions and rewrites those tests, while
keeping `agent://` unsupported.

## Out Of Scope (v0.40)

MCP prompts, WebSocket transport, MCP Apps iframe UI, `agent://` execution,
remembered/silent tool-call approval, MCP server mode, and memory auto-promotion.
See `docs/plans/future-features.md`.
