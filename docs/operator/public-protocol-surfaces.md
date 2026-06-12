# Public Protocol Surfaces

Status: released in v0.51 as `0.51.0`; `v0.51.4` is the corrective tag for
operator manual validation. Real-client validation steps remain below for
operators.

Allbert can be reached by three public protocol surfaces:

- MCP stdio and MCP HTTP (`mix allbert.mcp_server ...`, `POST /mcp`)
- OpenAI-compatible HTTP (`GET /v1/models`, `POST /v1/chat/completions`)
- ACP stdio (`mix allbert.acp_server ...`)

These are adapters over the existing Allbert runtime. They do not grant extra
authority, cannot approve their own confirmations, and are default-off.

## Settings

Enable only the surface and allowlist entries you intend to test:

```sh
mix allbert.settings set mcp_server.enabled true
mix allbert.settings set mcp_server.stdio.enabled true
mix allbert.settings set mcp_server.streamable_http.enabled true
mix allbert.settings set mcp_server.tools_enabled direct_answer,external_network_request,get_public_call_result
mix allbert.settings set mcp_server.memory_namespaces_enabled stocksage.stocksage

mix allbert.settings set openai_api.enabled true
mix allbert.settings set openai_api.models_enabled local
mix allbert.settings set openai_api.tools_enabled direct_answer,external_network_request,get_public_call_result

mix allbert.settings set acp_server.enabled true
mix allbert.settings set acp_server.stdio.enabled true
mix allbert.settings set acp_server.tools_enabled direct_answer,external_network_request,get_public_call_result
mix allbert.settings set acp_server.memory_namespaces_enabled stocksage.stocksage
```

All public protocol configuration goes through Settings Central. Do not use
Application env, process env, protocol metadata, ad hoc client flags, or Hermes
transport options as public-surface authority.

For list-valued settings, the CLI accepts comma-separated strings and writes a
real list value. Each manual validation write should print `Source: operator`
and an `Updated:` line with bracketed list output. If a public list setting
fails with `expected_public_tool_list`, `expected_public_memory_namespace_list`,
or `expected_profile_ref_list`, switch to the corrected `v0.51.4` tag before
continuing validation.

## Tokens

HTTP surfaces require a client id and bearer token:

```sh
mix allbert.public_protocol token create --surface mcp_http --client claude
mix allbert.public_protocol token create --surface openai_api --client local-openai
mix allbert.public_protocol token list --surface mcp_http
mix allbert.public_protocol token rotate --surface openai_api --client local-openai
mix allbert.public_protocol token revoke --surface mcp_http --client claude
```

`create` and `rotate` print the raw token once. `list` and `revoke` redact it.

## MCP

Inspect the enabled stdio surface:

```sh
mix allbert.mcp_server status
mix allbert.mcp_server tools list
mix allbert.mcp_server resources list
mix allbert.mcp_server stdio
```

The stdio command writes only JSON-RPC protocol frames to stdout. Runtime,
startup, and transport logs go to stderr so MCP clients can treat stdout as the
protocol stream.

MCP HTTP uses the Phoenix API ingress:

```sh
PORT=4051 mix phx.server
```

Clients call `POST http://127.0.0.1:4051/mcp` with:

- `x-allbert-client-id: <client-id>`
- `authorization: Bearer <token>`
- optional `mcp-protocol-version: 2025-06-18` or `2025-03-26`

The v0.51 HTTP subset is JSON-only `initialize`, `tools/list`, `tools/call`,
`resources/list`, and `resources/read`. `DELETE /mcp` returns `405`.

## OpenAI-Compatible API

Start Phoenix and point a local OpenAI-API client at
`http://127.0.0.1:4051/v1` with:

- `x-allbert-client-id: <client-id>`
- `authorization: Bearer <token>`

`GET /v1/models` lists only `openai_api.models_enabled` aliases.
`POST /v1/chat/completions` accepts text-only chat messages. It rejects
client-supplied tools/functions/tool calls, non-text media/resource content,
unsupported response formats, stream options, and unknown fields that could
change authority or routing.

## ACP

Inspect or run the ACP stdio server:

```sh
mix allbert.acp_server status
mix allbert.acp_server stdio
```

ACP v0.51 accepts text content blocks only. `cwd`, `additionalDirectories`,
`mcpServers`, and `permissionMode` are inert or rejected and never grant
filesystem or MCP-client authority. ACP permission responses are advisory UI
signals only; Allbert confirmation approval remains operator-owned.

## Artifacts

v0.51 does not serve artifacts as MCP resources and does not expose artifacts
through the OpenAI-compatible or ACP surfaces. If a later milestone adds MCP
artifact resources, the adapter must resolve through Artifacts Central and the
registered `:artifact_read` action boundary, with Settings Central allowlists,
redaction, and byte/bounds tests. Raw store paths and `artifact://` metadata are
not permission authority.

## Validation

Run the deterministic release lane first:

```sh
MIX_ENV=test mix allbert.test release.v051
```

Current v0.51 evidence, including the v0.51 secret scan:
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-13252/home/release_evidence/v051/release-v051-1781069964.json`.

Current full release evidence:
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-7/home/release_evidence/gates/release-2026-06-10T04_50_39Z.json`.

Manual real-client validation was not captured before the `v0.51.0` tag. Use
`docs/plans/v0.51-request-flow.md` "Operator Manual Validation Steps" as the
shell-authoritative punch list. It covers an isolated `v0.51.0` worktree,
deterministic gates, disposable manual `ALLBERT_HOME`, Settings Central setup,
token creation/revocation, MCP HTTP, OpenAI-compatible HTTP, MCP stdio, ACP
stdio, real external-client checks, readback ownership, negative authority
checks, and redaction scans.
