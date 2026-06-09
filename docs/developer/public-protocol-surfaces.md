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

- `capability.exposure == :agent`
- explicit per-surface operator allowlist in Settings Central

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

MCP stdio and ACP stdio keep stdout protocol-clean. Logs go to stderr.

## Result Readback

Confirmation-gated calls return a public call id. The client polls
`get_public_call_result` or the surface-shaped equivalent.

The ownership record stores only public call id, surface, client id,
action/turn label, confirmation id when present, trace id,
created/resolved/expires timestamps, status, and redacted result/error metadata.
Statuses are `pending`, `approved_with_result`, `denied`, and `expired`.

Readback never exposes raw confirmation records, `show_confirmation`,
`list_confirmations`, trace bodies, or secrets. Unknown and cross-client ids
return authorization/error shapes, not confirmation data.
