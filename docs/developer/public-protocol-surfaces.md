# Public Protocol Surfaces

Status: planned for v0.51.

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
- OpenAI-compatible `/v1/chat/completions` accepts string content and text
  content parts. Reject `tools`, `functions`, `tool_calls`, `tool_choice`,
  non-text parts, `modalities`, `audio`, and unsupported `response_format` or
  streaming options.
- ACP accepts text content blocks. Reject image/audio/resource blocks unless a
  later capability-specific plan exposes them. Treat `cwd`,
  `additionalDirectories`, `mcpServers`, and `permissionMode` as unsupported or
  bounded metadata, never authority.

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
- ACP advertises only implemented text-session capabilities. Client-supplied
  `mcpServers` are rejected and never imported into Settings Central or MCP
  discovery/connection flows.

## Response Shapes

- MCP list responses expose only bounded enabled tools/resources. Protocol,
  parse, version, auth, and exposure failures are JSON-RPC/MCP errors.
  Action-level denial returns an error tool result. Confirmation-required calls
  return a successful tool result with `status: "pending"` and
  `public_call_id`.
- OpenAI-compatible success returns `chat.completion`; streaming returns
  `chat.completion.chunk` SSE deltas and `[DONE]`. `/v1/models` returns a list
  of enabled Allbert model/profile aliases. Pending confirmation uses
  `allbert_status: "pending"` and `allbert_public_call_id` extension fields.
  Validation/auth/authorization/rate-limit failures use the OpenAI
  `%{"error" => ...}` body shape.
- ACP initialize/session setup advertises only implemented text capabilities.
  Prompt responses return assistant text or pending/readback ids. Errors are
  JSON-RPC-shaped and redacted.

## Ingress

HTTP-bearing surfaces use Allbert-owned ingress:

- body/frame bounds before runtime work where possible
- token authentication before runtime work
- per-client/per-surface rate limiting before runtime work
- API secure headers
- redacted logs/traces/audits

Bearer tokens are reusable credentials. v0.51 must prove token redaction,
revocation denial, and rate-limit-before-runtime behavior. Do not claim replay
prevention unless the implementation adds nonce, request-signature,
token-binding, or idempotency semantics with tests.

The token operator surface is:
`mix allbert.public_protocol token create|rotate|revoke|list --surface <mcp_http|openai_api> --client <id>`.
Only `create` and `rotate` print the new raw bearer token, once. This
bearer-token posture is an Allbert local/private ingress-auth subset, not MCP
OAuth 2.1 protected-resource or authorization-server parity.

MCP stdio and ACP stdio keep stdout protocol-clean. Logs go to stderr.

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
return `expired` and no result bytes.

Readback never exposes raw confirmation records, `show_confirmation`,
`list_confirmations`, trace bodies, or secrets. Unknown and cross-client ids
return authorization/error shapes, not confirmation data.
