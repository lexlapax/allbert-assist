# Public Protocol Surfaces

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

This guide separates packaged HTTP operation from source-checkout stdio and
release-validation commands.

Allbert can be reached by three public protocol surfaces:

- MCP stdio and MCP HTTP (source `mix allbert.mcp_server ...`, packaged
  `POST /mcp`)
- OpenAI-compatible HTTP (`GET /v1/models`, `POST /v1/chat/completions`)
- ACP stdio (source `mix allbert.acp_server ...`)

These are adapters over the existing Allbert runtime. They do not grant extra
authority, cannot approve their own confirmations, and are default-off.

## Settings

Enable only the surface and allowlist entries you intend to test:

```sh
allbert admin settings set mcp_server.enabled true
allbert admin settings set mcp_server.stdio.enabled true
allbert admin settings set mcp_server.streamable_http.enabled true
allbert admin settings set mcp_server.tools_enabled direct_answer,external_network_request,get_public_call_result
allbert admin settings set mcp_server.memory_namespaces_enabled stocksage.stocksage

allbert admin settings set openai_api.enabled true
allbert admin settings set openai_api.models_enabled local
allbert admin settings set openai_api.tools_enabled direct_answer,external_network_request,get_public_call_result

allbert admin settings set acp_server.enabled true
allbert admin settings set acp_server.stdio.enabled true
allbert admin settings set acp_server.tools_enabled direct_answer,external_network_request,get_public_call_result
allbert admin settings set acp_server.memory_namespaces_enabled stocksage.stocksage
```

All public protocol configuration goes through Settings Central. Do not use
Application env, process env, protocol metadata, ad hoc client flags, or Hermes
transport options as public-surface authority.

For list-valued settings, the CLI accepts comma-separated strings, validates
the members, and writes a real list value. A successful write prints
`Source: operator` and an `Updated:` line with bracketed list output.

## Tokens

HTTP surfaces require a client id and bearer token:

```sh
allbert admin public_protocol token create --surface mcp_http --client claude
allbert admin public_protocol token create --surface openai_api --client local-openai
allbert admin public_protocol token list --surface mcp_http
allbert admin public_protocol token rotate --surface openai_api --client local-openai
allbert admin public_protocol token revoke --surface mcp_http --client claude
```

`create` and `rotate` print the raw token once. `list` and `revoke` redact it.

## MCP

Source-checkout validation can inspect the enabled stdio surface:

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
PORT=4051 allbert serve
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

Source-checkout validation can inspect or run the ACP stdio server:

```sh
mix allbert.acp_server status
mix allbert.acp_server stdio
```

ACP v0.51 accepts text content blocks only. `cwd`, `additionalDirectories`,
`mcpServers`, and `permissionMode` are inert or rejected and never grant
filesystem or MCP-client authority. ACP permission responses are advisory UI
signals only; Allbert confirmation approval remains operator-owned.

## v1.1 Fan-Out Continuations

OpenAI-compatible and ACP requests are attended request/response surfaces, not
autonomous channel notifications. An eligible multi-task request records and
delivers its kickoff, then waits within a configured bound for the durable
fan-in report:

- OpenAI non-streaming holds the response for the joined report. SSE sends a
  real kickoff chunk, a working-status chunk, then the joined completion and
  `[DONE]`.
- ACP runs a prompt in a supervised worker so the stdio owner can still accept
  `session/cancel`; successful prompts emit the joined report before
  `end_turn`.
- If either surface reaches its continuation timeout, it returns the honest
  kickoff and leaves the eventual report pending. The next turn in the same
  owned session can carry that report.

A report is marked delivered only after its HTTP chunk/body or ACP stdout
frames have been written successfully. Only the report ids named by that
response are acknowledged; a closed stream or failed write leaves them pending.
None of this enables the default-off ADR 0084 remote report-back setting or
creates an autonomous notification ledger.

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

For a current release candidate, use the exact gate and manual steps in its
active request-flow document. Ordinary protocol operation does not begin with a
release gate.

The gate writes its evidence JSON (including the secret scan) under
`<gate-home>/release_evidence/<version>/`; the path is printed at the end of each run.

Manual real-client validation was not captured before the `v0.51.0` tag. Use
`docs/plans/archives/v0.51-request-flow.md` "Operator Manual Validation Steps" as the
shell-authoritative punch list. It covers an isolated `v0.51.0` worktree,
deterministic gates, disposable manual `ALLBERT_HOME`, Settings Central setup,
token creation/revocation, MCP HTTP, OpenAI-compatible HTTP, MCP stdio, ACP
stdio, real external-client checks, readback ownership, negative authority
checks, and redaction scans.
