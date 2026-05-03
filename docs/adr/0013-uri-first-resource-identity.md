# ADR 0013: URI-First Resource Identity And Permission Matching

## Status

Accepted for the remaining v0.10 closeout. ADR 0013 refines ADR 0012; it does
not replace the broader Resource Access Security Posture decision.

## Context

ADR 0012 named Allbert's shared local and remote resource access posture. The
first implementation pass deliberately started with practical fields:
`origin_kind`, `canonical_id`, `operation_class`, `access_mode`, `scope`, and
downstream consumer metadata. That was enough for v0.10 M7-M11, but it is not
the right long-term identity substrate.

Allbert is about to add more resource consumers: direct skill URL import, local
skill directory import, URL/file summary UX, document inspection, future MCP
resources and tools, future agent endpoints, and package/source provenance.
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

Future resource references should carry a canonical `uri` or `resource_uri` as
the durable identity field. Existing fields such as `origin_kind`,
`canonical_id`, and legacy scope values become compatibility and derived
metadata. They may remain in records, renderers, traces, and tests while
existing grants and confirmations are migrated.

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
- future MCP envelope: `mcp://<server-id>/<encoded-server-resource-uri>`
- future agents: recognized but unsupported `agent://` or `agent+https://`

Unsupported URI schemes are inert. A scheme may be represented for planning,
approval explanation, trace, or future handoff, but it is denied for execution
until a later plan adds an action, policy, confirmation shape, adapter,
redaction, trace, audit, and tests.

The remaining v0.10 implementation work should add a URI normalization module,
tentatively `AllbertAssist.Resources.URI` or
`AllbertAssist.Resources.ResourceURI`. That module should own scheme-specific
normalization, redaction/display rendering, scope derivation, compatibility
field derivation, and matching support. `AllbertAssist.Resources.Ref` should
delegate to it instead of embedding URI/path/source/package rules directly.

`AllbertAssist.Resources.Grants` should store and use `resource_uri` when
present and derive it from legacy fields when reading older grants. Existing
M11 grant behavior must keep working through the refactor.

## Consequences

- ADR 0012 remains the shared posture ADR. ADR 0013 narrows in on identity and
  matching.
- v0.10 M12 becomes a real URI-first resource identity refactor milestone.
  Direct skill URL import and local skill directory import move after that
  refactor so they build on the final substrate.
- v0.11 consumes URI-backed `resource_access` and Approval Handoff metadata.
  It does not redefine storage, permission policy, grant matching, or
  execution authority.
- Skills, packages, MCP resources, future agents, source profiles, local
  files, and network URLs become typed resource consumers over the same URI
  substrate.
- Existing confirmation records and remembered grants remain compatibility
  inputs. No release may silently invalidate operator audit history.
- Future hardening should add evals for URI normalization mismatch, redacted
  URI authority leaks, cross-scheme grant reuse, operation-scope bypass,
  source-profile drift, local symlink escape, SSRF, MCP resource confusion,
  package PURL ambiguity, and unsupported `agent://` execution attempts.
