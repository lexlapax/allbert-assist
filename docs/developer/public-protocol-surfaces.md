# Public Protocol Surfaces

Status: released for v0.51 as `0.51.0`; deterministic release evidence is
current. Real-client validation remains an operator smoke step.

This document is the implementation contract for the v0.51 MCP server,
OpenAI-compatible API, and ACP server adapters. The authoritative planning set
is `docs/plans/v0.51-plan.md`, `docs/plans/v0.51-request-flow.md`, ADR 0044,
and ADR 0055.

## Boundary Model

The public surfaces are adapters over existing Allbert authority:

1. Conversational requests enter through `Runtime.submit_user_input/1`.
2. Effectful tool calls execute through `Actions.Runner.run/3`.
3. Security Central, Resource Access, confirmations, traces, audits, and
   redaction stay in the same path used by local workspace users.
4. External clients never self-approve confirmations.

Do not add private protocol-specific execution paths. A protocol field, client
identity string, model name, content type, ACP permission response, or MCP
metadata packet is never permission authority.

Operator configuration for these surfaces comes only from Settings Central. Do
not add Application env, process-env, ad hoc CLI flag, protocol metadata, or
Hermes transport-option config paths for public-surface enablement, clients,
tokens, rate limits, body caps, tool/resource allowlists, model aliases, or ACP
sessions.

## Exposure Filter

The public tool source is `Actions.Registry.capabilities/0` filtered by both:

- deny-before-allow non-exposable rules, then `capability.exposure == :agent`
- explicit per-surface operator allowlist in Settings Central

Do not treat `:agent` as sufficient. Some current `:agent` actions are settings,
provider-profile, credential, or diagnostic operations. Public filters must deny
by capability id, execution mode, and permission class before allowlisting:
`:settings_read`, `:settings_write`, `:secret_write`, confirmation-decision/
storage modes, raw trace/signal access, plugin/registry internals, and local-
process/shell-like modes are non-exposable unless a later ADR/plan names a
specific action public-safe.

That filter is necessary but not enough for dynamic/generated/plugin actions:
they keep their existing reviewed/gated authority requirements before the
operator allowlist can expose them publicly.

Memory resources come from `Memory.Namespaces.app_namespaces/0` intersected
with the per-surface allowlist. Do not enumerate `Memory.Namespaces.all/0` and
filter late; system namespaces such as identity must never be visible to public
resource listing code.

## Content Subset

v0.51 is text-first.

- MCP tool/resource calls expose operator-enabled Allbert actions/resources.
  Embedded image/audio/resource content in tool outputs or prompts is not
  authority to read artifacts, fetch URLs, transcribe audio, or run vision.
  v0.51 M3/M4 do not serve artifacts as MCP resources. If artifact serving is
  required later, the implementation must use Artifacts Central and
  `:artifact_read` policy through a public-safe adapter, Settings Central
  allowlists, redaction, and byte/bounds tests. Do not expose raw artifact store
  paths or make existing internal artifact actions public by metadata alone.
- OpenAI-compatible `/v1/chat/completions` accepts only `model`, `messages`,
  `stream`, `user`, `response_format`, and Allbert extension fields
  `allbert_user_id`, `allbert_thread_id`, and `allbert_session_id`. Accepted
  message content is string content or text content parts with roles `system`,
  `developer`, `user`, or `assistant`. Reject `tools`, `functions`,
  `tool_calls`, `tool_choice`, incoming `tool` role messages, assistant
  `tool_calls`/`function_call`, non-text parts, `modalities`, `audio`,
  `stream_options`, unknown OpenAI fields, and unsupported `response_format`.
  The OpenAI-compatible surface does not expose artifacts or multimodal
  authority.
- ACP accepts text content blocks only. Reject image/audio/resource/resource-link
  blocks unless a later capability-specific plan exposes them. Treat `cwd` as
  inert metadata, and reject non-empty `additionalDirectories`, non-empty
  `mcpServers`, and `permissionMode`; none is authority.

Unsupported protocol features return bounded, redacted, protocol-shaped errors.
Do not silently ignore a feature that could change authority or media handling.

## Protocol Compatibility

- MCP targets the versions supported by pinned `hermes_mcp` 0.14.1:
  `2025-03-26` / `2025-06-18` where the transport supports them. Do not claim
  `2025-11-25` parity unless the dependency is upgraded and reverified.
- MCP v0.51 advertises initialize/lifecycle, `tools/list`, `tools/call`,
  `resources/list`, and `resources/read` only. No prompts, resource templates,
  subscriptions, or `listChanged` capability are advertised unless implemented
  and tested in v0.51.
- OpenAI compatibility means a bounded Chat Completions shim. It is not full
  OpenAI API or Responses API parity.
- ACP advertises only implemented text-session capabilities for protocol version
  `1`. It does not advertise image/audio/embedded-resource, filesystem,
  terminal, MCP, load/resume, or additional-directory capability.
  Client-supplied `mcpServers` are rejected and never imported into Settings
  Central or MCP discovery/connection flows.

## Response Shapes

- MCP list responses expose only bounded enabled tools/resources. Protocol,
  parse, version, auth, and exposure failures are JSON-RPC/MCP errors.
  Action-level denial returns an error tool result. Confirmation-required calls
  return a successful tool result with `status: "confirmation_pending"` and
  `public_call_id`.
- OpenAI-compatible success returns `chat.completion`; streaming returns one
  bounded `chat.completion.chunk` SSE event for the completed turn and `[DONE]`.
  `/v1/models` returns a list of enabled Allbert model/profile aliases from
  Settings Central. Pending confirmation uses
  `allbert_status: "pending"` and `allbert_public_call_id` extension fields.
  Validation/auth/authorization/rate-limit failures use the OpenAI
  `%{"error" => ...}` body shape.
- ACP initialize/session setup advertises only implemented text capabilities.
  Prompt responses emit `session/update` agent text chunks and return
  `stopReason: "end_turn"` or pending/readback ids. Confirmation-pending turns
  may emit ACP `session/request_permission` for client UI display, but ACP
  permission responses are advisory only and never authorize Allbert execution.
  Errors are JSON-RPC-shaped and redacted.

## Ingress

HTTP-bearing surfaces use Allbert-owned ingress:

- body/frame bounds before runtime work where possible
- token authentication before runtime work
- per-client/per-surface rate limiting before runtime work; if the supervised
  limiter is unavailable, HTTP ingress fails closed with a rate-limit response
- API secure headers
- redacted logs/traces/audits

For MCP HTTP, do not mount `Hermes.Server.Transport.StreamableHTTP.Plug`
directly in the endpoint/router and do not start a Hermes-owned HTTP listener.
Hermes may frame MCP protocol data after Allbert-owned Phoenix/Plug ingress has
already enforced body caps, token auth, rate limits, API secure headers, Origin
and session policy, and protocol-version denial.

The v0.51 M4 MCP HTTP subset is:

- `POST /mcp` with JSON-RPC `initialize`, `tools/list`, `tools/call`,
  `resources/list`, and `resources/read`; JSON responses only, no SSE claim.
- `mcp-protocol-version` optional; `2025-06-18` and `2025-03-26` accepted,
  unsupported newer versions rejected before runtime work.
- `mcp-session-id` echoed when supplied, with no durable HTTP session store in
  M4.
- Authenticated `DELETE /mcp` returns `405`.
- HTTP auth requires `x-allbert-client-id` and `authorization: Bearer <token>`.
  Client entries, token refs, token material, rate limits, feature flags, and
  body caps are Settings Central / Settings Secrets state only.
- Origin is accepted only for loopback origins on loopback request hosts; absent
  Origin is accepted.

Bearer tokens are reusable credentials. v0.51 must prove token redaction,
revocation denial, and rate-limit-before-runtime behavior. Do not claim replay
prevention unless the implementation adds nonce, request-signature,
token-binding, or idempotency semantics with tests.

The token operator surface is:
`mix allbert.public_protocol token create|rotate|revoke|list --surface <mcp_http|openai_api> --client <id>`.
Only `create` and `rotate` print the new raw bearer token, once. This
bearer-token posture is an Allbert local/private ingress-auth subset, not MCP
OAuth 2.1 protected-resource or authorization-server parity.

MCP stdio and ACP stdio keep stdout protocol-clean. Logs go to stderr. MCP
stdio uses an Allbert-owned JSON-RPC line adapter over the shared MCP runtime;
do not route the public stdio surface through a dependency-owned transport
unless that path is reverified with an OS subprocess stdout fixture. The ACP
operator entrypoint is `mix allbert.acp_server status|stdio`.

## Result Readback

Confirmation-gated calls return a public call id. The client polls
`get_public_call_result` or the surface-shaped equivalent.

The ownership record is the `public_protocol_call_results` Ecto table in the
Allbert Assist DB. Do not store it as an Allbert Home flat file or expose extra
confirmation-store metadata.

The ownership record stores only public call id, surface, client id,
action/turn label, confirmation id when present, trace id,
created/resolved/expires timestamps, status, and redacted result/error metadata.
Statuses are `pending`, `approved_with_result`, `denied`, and `expired`.
Entries expire after `public_protocol.result_readback_ttl_ms`; expired entries
return `expired` and no result bytes. The supervised readback sweeper runs on
`public_protocol.result_readback_sweep_interval_ms` so expired result/error bytes
are zeroed even when a client never polls again.

Readback never exposes raw confirmation records, `show_confirmation`,
`list_confirmations`, trace bodies, or secrets. Unknown and cross-client ids
return authorization/error shapes, not confirmation data.

## Validation Evidence

The deterministic v0.51 gate is:

```sh
MIX_ENV=test mix allbert.test release.v051
```

The clean M7 evidence is
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v051/p0-13252/home/release_evidence/v051/release-v051-1781069964.json`.
It covers the public-surface foundations, MCP stdio, MCP HTTP ingress,
OpenAI-compatible mapping and web controller, ACP stdio, 34 `:v051`
public-protocol security eval rows, and the secret scan. Evidence scans found no
`public protocol result readback sweep failed`, `database is locked`,
`SQLITE_BUSY`, `Exqlite.Connection`, `DBConnection.ConnectionError`, or
`unknown_app_namespace` noise.

The full aggregate release gate also passed:
`/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-7/home/release_evidence/gates/release-2026-06-10T04_50_39Z.json`.
It is the broad compile/test/Dialyzer handoff; v0.51-specific secret-scan
evidence lives in `release.v051`.
