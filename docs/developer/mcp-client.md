# Allbert MCP Client Developer Notes

Status: implemented in v0.40 (`0.40.0`). This document describes the shipped
module and boundary contract for MCP Client Integration.

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

Modules under `AllbertAssist.Mcp.*` (project acronym convention is
`Mcp`, matching `Http`):

- `AllbertAssist.Mcp` — facade for resolving servers and dispatching client ops.
- `AllbertAssist.Mcp.ServerConfig` — resolves an `mcp.servers.*` entry from
  Settings Central and resolves `secret://mcp/...` refs at call time.
- `AllbertAssist.Mcp.Codec` — Hermes-backed MCP JSON-RPC message wrapper.
- `AllbertAssist.Mcp.Client` — per-server client sequencing over the Allbert
  transport boundary.
- `AllbertAssist.Mcp.Transport` — routes egress through Allbert-owned transports.
- `AllbertAssist.Mcp.Doctor` — returns the ADR 0047-style redacted doctor
  envelope plus MCP additive fields.

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

Capability execution modes added in v0.40:

- `:mcp_doctor`
- `:mcp_discovery`
- `:mcp_resource_read`
- `:mcp_tool_call`

Action parameter schemas:

| Action | Required params | Optional params |
|---|---|---|
| `mcp_doctor_server` | `server_id` | `include_discovery` |
| `mcp_list_tools` | `server_id` | `cursor`, `limit` |
| `mcp_list_resources` | `server_id` | `cursor`, `limit` |
| `mcp_read_resource` | `server_id`, `uri` | `resource_uri`, `scope_kind`, `downstream_consumer`, `remember_scope` |
| `mcp_call_tool` | `server_id`, `tool_name`, `arguments` | `downstream_consumer`, `idempotency_key` |

`uri` is the server-native resource URI. `resource_uri` may be the canonical
`mcp://<server-id>/<encoded-uri>` form. `arguments` is a decoded JSON object/map
and CLI parsing fails closed on invalid JSON.

## Settings

`mcp.servers.<server-id>` in `AllbertAssist.Settings.Schema`. Per-transport
validation: `streamable_http`/`sse` require `base_url` (no `command`); `stdio`
requires `command` (no `base_url`) and the command must match
`mcp.stdio.allowed_launchers`, which defaults to an empty deny-all list.
Secret-bearing `env`/`headers` values and `auth_ref` must be
`secret://mcp/<server-id>/<name>` refs. `confirmation` is tighten-only
(`required` | `denied`). See `docs/plans/v0.40-plan.md` for the full key list
and validation rules.

`args`, `tool_allowlist`, and `tool_denylist` are string lists. `env` and
`headers` are string-to-string maps. The implemented CLI/config input path is
JSON-aware `mix allbert.settings set` parsing for MCP list/map keys;
comma-separated string-list input remains available for non-JSON list values.

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
`mcp_read_resource` uses the existing `AllbertAssist.Resources.GrantHandoff` /
`remember_resource_grant` path for first-access approval. MCP must not introduce
a private remembered-grant store.

## Transports

Both transports are bounded adapters; neither carries authority.

- **HTTP / SSE**: egress routes through `AllbertAssist.External.HttpClient` /
  `HttpPolicy` (SSRF blocking, host allowlist, bounded timeout/response, redirect
  denial, redaction). MCP does not open a second network path.
- **stdio**: process started with explicit argv and secret-ref-only env, bounded
  under ADR 0009 local-execution sandbox levels (no shell string, bounded
  lifecycle, audited startup). Stderr is not merged into stdout because real
  MCP servers may log on stderr while stdout remains the JSON-RPC stream.
  Resolved env entries are converted to charlists before `Port.open/2`.

## Codec And Dependency

v0.40 uses `hermes_mcp` for MCP protocol framing/codec through
`AllbertAssist.Mcp.Codec`, which wraps `Hermes.MCP.Message`. Runtime calls do
not use `Hermes.Client` or Hermes transport modules because the M1/M2 spike
found no production custom transport hook that forces HTTP/SSE and stdio egress
through Allbert-owned policy boundaries. `AllbertAssist.Mcp.Client` sequences
JSON-RPC requests and `AllbertAssist.Mcp.Transport` owns HTTP/SSE over
`External.HttpClient` plus bounded stdio `Port` startup. MCP remains a
protocol-generic dependency, not a provider SDK, so it does not violate ADR
0039.

## Doctor

`mcp_doctor_server` returns the ADR 0047 envelope (`endpoint_kind`,
`endpoint_ok`, `redacted_host`, `diagnostics`, ...) plus the MCP additive fields
`:transport_kind`, `:tools_listable`, `:resources_listable`, `:tool_count`,
`:resource_count`, `:protocol_version`. stdio servers report
`endpoint_kind: :local_endpoint`; authenticated HTTP/SSE report
`:credentialed_remote`. Because stdio is `:local_endpoint`, `credential_ok` is
`nil` for stdio. The doctor grants no authority and creates no grants.

## Adding A New Server Shape

1. Add an `mcp.servers.<id>` config (transport, url/command, secret refs).
2. Doctor it; confirm tools/resources are listable.
3. For CI, add a deterministic mock server fixture under `test/support` rather
   than depending on a live server. v0.40 validates GitHub, calendar, and mail
   shapes (the v0.41 consumers) plus mocks.
4. Record whether the data v0.41 needs for summary panels is exposed as MCP
   resources or only as MCP tools. Tool-only summary reads remain per-call
   confirmed unless ADR 0038 is explicitly amended.

## Testing And Security Evals

Add rows to `AllbertAssist.SecurityFixtures.EvalInventory` (milestone `:v040`,
surface `:mcp_server_integration`) and `AllbertAssist.Security.McpIntegrationEvalTest`:
`mcp-schema-not-authority-001`, `mcp-tool-resource-confusion-001`,
`mcp-prompt-injection-001`, `mcp-server-impersonation-001`,
`mcp-secret-env-redaction-001`, `mcp-stdio-startup-policy-001`, and
`mcp-doctor-redacted-envelope-001`. The evals use deterministic mock MCP
servers and assert zero unintended transport calls before approval.

## Intent Routing Flip

`AllbertAssist.Agents.IntentAgent` routes `mcp://` resources and explicit MCP
tool/resource/call phrasing to the MCP actions. `AllbertAssist.Intent.Engine`
and `AllbertAssist.Intent.Ranker` no longer treat `mcp://` as an unsupported
resource marker. `agent://` and `agent+https://` remain unsupported.

## Out Of Scope (v0.40)

MCP prompts, WebSocket transport, MCP Apps iframe UI, `agent://` execution,
remembered/silent tool-call approval, MCP server mode, and memory auto-promotion.
See `docs/plans/future-features.md`.
