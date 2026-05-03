# ADR 0012: Resource Access Security Posture

## Status

Accepted for v0.10 planning.

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

## Decision

Allbert will name a shared **Resource Access Security Posture**.

Every local or remote resource-consuming workflow should be represented by a
structured resource reference plus operation class before execution, import,
summarization, install, trust, or persistence decisions.

The resource reference is plain data, not execution authority. It should carry:

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
- v0.10 plan milestones own the new implementation-ready posture work:
  resource reference contract, operation classes, local/remote consumers,
  remembered grant scope, docs, and tests.
- ADR 0011 remains the external-adapter decision. ADR 0012 sits above it and
  names the shared local/remote resource access posture.
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
