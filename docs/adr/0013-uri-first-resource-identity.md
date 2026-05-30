# ADR 0013: URI-First Resource Identity And Permission Matching

## Status

Accepted for the remaining v0.10 closeout. ADR 0013 refines ADR 0012; it does
not replace the broader Resource Access Security Posture decision.

Amended at v0.40 MCP Client Integration: `mcp://` graduates from a reserved,
inert scheme to a supported resource adapter (see ADR 0038). `agent://` and
`agent+https://` remain reserved and inert.

Amended at v0.43 Browser And Web Research: `browser://session/<id>` is added as
a supported plugin-owned scheme for browser-session identity (see ADR 0040).
Navigated URL targets keep their native `https://` or explicitly allowed
`http://` URI; the session URI is the lifecycle/ownership identity, and the
navigated URL is the operation target authorized by per-domain remembered
grants. `agent://` and `agent+https://` remain reserved and inert.

## Context

ADR 0012 named Allbert's shared local and remote resource access posture. The
first implementation pass deliberately started with practical fields:
`origin_kind`, `canonical_id`, `operation_class`, `access_mode`, `scope`, and
downstream consumer metadata. That was enough for v0.10 M7-M11, but it is not
the right long-term identity substrate.

Allbert is adding more resource consumers. v0.10 M13 adds direct skill URL
import and local skill directory import; later releases add URL/file summary
UX, document inspection, future MCP resources and tools, future agent
endpoints, and package/source provenance.
If each consumer extends `origin_kind` and scope matching separately, the
resource layer will keep drifting toward workflow-specific branches.

Current research points to a URI-first substrate:

- RFC 3986 defines URI as an extensible identifier for physical, abstract,
  local, remote, service, and collection resources:
  `https://www.rfc-editor.org/rfc/rfc3986`.
- MCP resources are identified by URI, support common schemes such as
  `file://`, `https://`, and `git://`, allow custom schemes, and require URI
  validation and permission checks:
  `https://modelcontextprotocol.io/specification/2025-06-18/server/resources`.
- Package URL / PURL defines a standard `pkg:` URI shape for package
  identities across ecosystems:
  `https://github.com/package-url/purl-spec`.
- Claude Code permission docs separate permissions from sandboxing and model
  files, domains, Bash, WebFetch, and MCP as permission targets:
  `https://code.claude.com/docs/en/permissions`.
- OpenAI Codex approval and security docs treat approvals, sandboxing, network
  controls, and telemetry as separate security layers:
  `https://developers.openai.com/codex/agent-approvals-security`.
- Pi, OpenClaw, Hermes, and Anthropic skills docs treat skills as
  lifecycle-managed resources with sources, locations, scans, trust, and
  precedence, not as the root permission model:
  `https://pi.dev/docs/latest/skills`,
  `https://docs.openclaw.ai/tools/skills`,
  `https://hermes-agent.nousresearch.com/docs/user-guide/features/skills`,
  and `https://github.com/anthropics/skills`.
- `agent://` is currently an experimental Internet-Draft. Allbert should
  reserve future compatibility for `agent://` and `agent+https://` identities
  without treating them as stable execution authority:
  `https://www.ietf.org/archive/id/draft-narvaneni-agent-uri-03.html`.

## Decision

Allbert resource identity will become URI-first.

Resource references carry canonical `resource_uri` as the durable identity
field. Fields such as `origin_kind`, `canonical_id`, and scope values are
derived/descriptive metadata for renderers, traces, audits, and workflow
context. They are not the remembered-grant authority.

Permission matching authority is:

- canonical resource URI
- operation class
- access mode
- downstream consumer
- current Security Central permission decision

Display URI, redacted URI, source labels, operator summaries, and rendered
resource lines are not authority. They exist for human review only.

Initial URI mappings:

- host local paths: `file://...`
- Allbert Home managed data: `allbert://home/...`
- external URLs: `https://...` or explicitly allowed `http://...`
- source profiles: `allbert://sources/<kind>/<id>`
- skill inventory resources: `skill://<skill-name>/...`
- package specs: `pkg:npm/...`, `pkg:pypi/...`, or another PURL-compatible
  `pkg:` form when a package type exists
- MCP resources: `mcp://<server-id>/<encoded-server-resource-uri>` (reserved and
  inert here; promoted to a supported adapter in v0.40, see ADR 0038)
- browser sessions: `browser://session/<id>` (reserved and inert here; promoted
  to a supported plugin-owned scheme in v0.43, see ADR 0040). The session URI
  is lifecycle/ownership identity; navigated URL targets keep their native
  `https://`/`http://` URI and are authorized through per-domain remembered
  grants on the target URL, not on the session URI.
- future agents: recognized but unsupported `agent://` or `agent+https://`

Unsupported URI schemes are inert. A scheme may be represented for planning,
approval explanation, trace, or future handoff, but it is denied for execution
until a later plan adds an action, policy, confirmation shape, adapter,
redaction, trace, audit, and tests.

v0.40 MCP Client Integration is the plan that does exactly this for `mcp://`: it
adds the MCP actions, the `:mcp_tool_call` / `:mcp_resource_read` permission
classes, MCP operation classes, confirmation and grant shapes, redaction,
traces, audits, and tests (ADR 0038). `agent://` and `agent+https://` remain
inert and reserved.

The v0.10 M12 implementation adds `AllbertAssist.Resources.ResourceURI`. That
module owns scheme-specific normalization, redaction/display rendering, scope
URI derivation, descriptive field derivation, and matching support.
`AllbertAssist.Resources.Ref` delegates to it instead of embedding
URI/path/source/package rules directly.

`AllbertAssist.Resources.Grants` stores and uses `resource_uri`. Because
Allbert is pre-1.0, M12 removes the temporary `canonical_scope` grant authority
shape instead of maintaining a legacy grant matcher. Existing grant records
without `resource_uri` are invalid under the M12 schema and should be
re-created through the current approval/resource-grant UX.

## Consequences

- ADR 0012 remains the shared posture ADR. ADR 0013 narrows in on identity and
  matching.
- v0.10 M12 becomes a real URI-first resource identity refactor milestone.
  v0.10 M13 builds on that substrate with direct skill URL import and local
  skill directory import. v0.10 M14 adds explicit unsupported/deferred UX for
  URI-backed workflows whose execution/orchestration remains v0.11+.
- v0.11 consumes URI-backed `resource_access` and Approval Handoff metadata.
  It does not redefine storage, permission policy, grant matching, or
  execution authority.
- Skills, packages, MCP resources, future agents, source profiles, local
  files, and network URLs become typed resource consumers over the same URI
  substrate.
- v0.40 promotes `mcp://` to a supported, grant-matched consumer of this
  substrate: MCP resource reads are remembered-grant authority on the canonical
  `mcp://` URI, and MCP tool calls are confirmation-gated (ADR 0038). The URI
  substrate, grant matching, and operation-class scoping are unchanged; MCP just
  stops being inert.
- v0.43 promotes `browser://session/<id>` to a supported, plugin-owned scheme
  for browser-session identity (ADR 0040). Unlike `mcp://`, remembered grants
  are not stored against the `browser://` URI itself; they are stored against
  the navigated target URL (`https://<host>/...` with the existing
  `:url_prefix` scope kind) plus the new browser operation classes. The
  session URI participates in trace/audit identity, lifecycle ownership, and
  cross-operation grant denial; it is not authority.
- Existing confirmation/audit records remain historical evidence, but
  remembered grants without `resource_uri` are not compatibility inputs for
  matching after M12. No user data is deleted; operators may re-create grants
  under the current schema.
- Future hardening should add evals for URI normalization mismatch, redacted
  URI authority leaks, cross-scheme grant reuse, operation-scope bypass,
  source-profile drift, local symlink escape, SSRF, MCP resource confusion,
  package PURL ambiguity, and unsupported `agent://` execution attempts.
