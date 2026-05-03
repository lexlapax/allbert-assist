# ADR 0012: Resource Access Security Posture

## Status

Accepted for v0.10. The M7 shared resource reference contract, M8 remembered
resource grant contract, M9 release-readiness handoff, M10 resource
identity/scope hardening, and M11 remembered-grant operator UX are
implemented. ADR 0013 refines this posture with URI-first resource identity
and permission matching for the remaining v0.10 closeout.

## Context

Allbert now has several resource-access special cases:

- v0.08 added confirmed local command execution with cwd, path-like operand,
  env, timeout, output, confirmation, trace, and audit policy.
- v0.09 added confirmed trusted skill script execution where the script path
  is authorized by selected skill inventory and digest, not arbitrary
  filesystem authority.
- v0.10 added confirmed external HTTP/service requests, package-manager
  profiles, and online skill search/detail/audit/import.

Those releases should remain historical records. Their docs may be reframed,
but they must not be rewritten to claim a generalized abstraction that was not
implemented at the time. Any new implementation work for a shared posture must
be explicit v0.10 milestone work.

The broader product boundary is resource access, not skills. Local skill
installation from a directory is a local resource consumer. Remote skill
installation from a URL or source registry is a network resource consumer. URL
summarization, document inspection, package metadata lookup, shell execution,
and script execution are also resource consumers with different risk profiles.

Current security guidance supports a unified posture:

- OWASP path traversal guidance emphasizes normalizing paths, accepting known
  good input, and preventing unauthorized file inclusion.
- OWASP file upload guidance emphasizes extension/type validation, safe names,
  storage boundaries, size limits, and parser/sandbox caution for untrusted
  files.
- OWASP SSRF guidance emphasizes allowlists, strict URL validation, redirect
  control, and private-network/metadata endpoint blocking.
- OWASP AI agent and prompt-injection guidance emphasizes least privilege,
  treating external documents/API responses as untrusted data, and using
  human-in-the-loop controls for high-risk actions.
- RFC 3986, MCP resources, Package URL / PURL, and current agent harness
  permission models reinforce that files, URLs, package coordinates, skill
  resources, MCP resources, and future agent endpoints should be identified by
  URI-shaped resource identities before workflow-specific consumers act on
  them. ADR 0013 records this URI-first refinement.

## Decision

Allbert will name a shared **Resource Access Security Posture**.

Every local or remote resource-consuming workflow should be represented by a
structured resource reference plus operation class before execution, import,
summarization, install, trust, or persistence decisions.

The M7 resource reference is plain data, not execution authority. It is
implemented by `AllbertAssist.Resources.Ref`,
`AllbertAssist.Resources.Scope`, `AllbertAssist.Resources.OperationClass`,
and the inert `AllbertAssist.Resources.Grant` descriptor. It carries:

- origin kind: `local_path`, `local_skill_resource`, `allbert_home`,
  `remote_url`, `remote_source`, `package_registry`, or future equivalent
- canonical identity: canonical path, skill resource id, URL, source profile,
  or package coordinate
- operation class: examples include `read_local_path`, `write_local_path`,
  `run_shell_command`, `run_skill_script`, `import_local_skill`,
  `external_service_request`, `summarize_url`, `inspect_document`,
  `import_skill`, and `package_install`
- access mode: read, write, execute, fetch, import, summarize, install, or
  audit
- scope: exact file, directory subtree, exact URL, URL prefix, source profile,
  or package-manager target root
- downstream consumer: shell runner, skill runner, summarizer, importer,
  package manager, registry client, or audit-only reader
- limits: timeout, byte cap, output cap, extraction cap, redirect/retry
  posture, digest/cache expectation, and parser/extractor expectations
- origin channel/surface, resolver channel, confirmation id, redaction, trace,
  audit, and remembered-grant metadata when applicable

`AllbertAssist.Confirmations.ResourceMetadata` renders concise operator-facing
resource summaries for confirmations, CLI output, `/settings`, audits, and
traces. Rendering the metadata does not grant access.

Resource identity and display metadata are separate. Enforcement, remembered
grant matching, drift checks, and audit authority use canonical resource
fields such as canonical path, canonical URL, source profile id, or package
coordinate. Operator renderers may use redacted display fields such as
`display_url`, but those redacted strings are never remembered as canonical
grant authority.

ADR 0013 makes the next identity step explicit: future refs should carry a
canonical `resource_uri` or `uri` first. `origin_kind`, `canonical_id`, and
legacy scope fields remain compatibility and derived metadata. Matching
authority becomes canonical URI plus operation class, access mode, downstream
consumer, and the current Security Central permission decision.

Remembered grants are stored in Settings Central at
`resource_grants.remembered` and matched by `AllbertAssist.Resources.Grants`.
They are generic resource approval memory, not skills/search/summarization
policy. A caller must pass the current action permission when asking whether a
grant applies, so Security Central can be re-checked without the grant store
guessing workflow-specific permission routing.

Local path scopes are canonicalized before matching, including intermediate
symlink components that already exist. A directory-subtree grant cannot be
used by entering an allowed directory and then escaping through a symlinked
child directory. Source-profile grants record enough endpoint fingerprint
metadata to reject same-id grants when base/API URLs drift.

Operation class is part of the security boundary. A grant or confirmation for
one operation class does not authorize another:

- local skill directory import does not authorize script execution
- local directory read does not authorize package install
- URL summarization does not authorize remote skill import
- remote skill import does not authorize trust, activation, dependency install,
  or script execution
- package metadata inspection does not authorize package install

## Consequences

- v0.08 and v0.09 docs may include retrospective framing that their completed
  implementations are local resource posture special cases, but they must not
  claim new generalized behavior.
- v0.10 M7 owns the implemented resource reference contract, operation-class
  vocabulary, local/remote consumer metadata, docs, and tests. v0.10 M8 owns
  implemented remembered grant scope, storage, matching, revocation, docs, and
  tests. v0.10 M9 owns release-readiness docs, user-testing instructions, and
  future milestone handoffs over the implemented M7/M8 contracts. v0.10 M10
  owns canonical-vs-display URL separation, intermediate symlink hardening,
  source-profile drift rejection, and registry-driven resumable-action
  metadata for confirmation approval. v0.10 M11 owns registered
  remembered-grant operator actions, CLI and thin `/settings` controls,
  approval-time remembered-grant inputs, and application of matching grants to
  existing v0.10 resource consumers before new confirmations are created.
  v0.10 M12 owns the URI-first identity refactor described by ADR 0013.
- ADR 0011 remains the external-adapter decision. ADR 0012 sits above it and
  names the shared local/remote resource access posture. ADR 0013 refines the
  durable identity and matching layer underneath the posture.
- v0.11 consumes the posture for execution-aware intent and channel-native
  Approval Handoff. Channels render resource approvals; they do not fetch,
  read, import, execute, summarize, remember grants, or mutate confirmation
  records directly.
- v0.12 jobs and v0.13 channels must use the same posture instead of creating
  background or channel-specific resource-access rules.
- v0.16 hardening should add evals for local traversal, unsafe directory
  import, skill-resource digest drift, SSRF, unsafe remote content,
  operation-scope bypass, misleading approval prompts, and prompt injection
  through fetched or local documents.
