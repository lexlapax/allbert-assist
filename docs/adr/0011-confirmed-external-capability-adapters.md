# ADR 0011: Confirmed External Capability Adapters

## Status

Accepted and implemented for v0.10.

## Context

Allbert has intentionally deferred real external calls, package installs, and
online skill import until after the action, security, confirmation, local
execution, and skill-script foundations exist.

Those foundations now exist:

- ADR 0006 defines Security Central as the policy evaluation boundary.
- ADR 0008 defines durable confirmations as action state.
- ADR 0009 defines Level 1 local execution as policy-bounded host process
  execution, not OS isolation.
- ADR 0010 defines resource-gated trusted skill script execution.
- ADR 0012 names the broader Resource Access Security Posture that connects
  local paths, local skill resources, Allbert Home resources, remote URLs,
  remote sources, and package registries without rewriting v0.08 or v0.09.

v0.10 is the first point where a confirmed request may leave the local machine
for an HTTP/service call, invoke a package manager, or fetch an online Agent
Skill candidate. Each of those capabilities crosses a different trust boundary:

- External HTTP can become SSRF, credential leakage, data exfiltration, hidden
  retries, unsafe redirect following, or unbounded response capture.
- Package managers can execute lifecycle scripts, fetch transitive dependency
  code, mutate lockfiles and dependency folders, and run attacker-controlled
  install-time code.
- Online skill import can introduce untrusted instructions, bundled scripts,
  package manifests, external links, and social proof that may look safer than
  it is.
- Remote network content is broader than online skills, and ADR 0012 broadens
  the language again to resource access. A URL may point to API JSON, a web
  page, a PDF, markdown, text, a direct `SKILL.md`, an archive, or package
  metadata. A local path may point to a document, a skill directory, or a
  trusted skill script resource. Higher-level requests such as "check this URL
  and summarize it" or "import this local skill directory" still begin as
  resource acquisition and need the same source, approval, bounds, redaction,
  trace, and downstream-consumer posture.

Current research reinforces that the boundary must be explicit:

- Req supports redirects, retries, request/response steps, Finch options, and
  test stubs. Those are useful, but v0.10 must not inherit hidden retry or
  redirect behavior when policy says a single reviewed request was approved.
- OWASP SSRF guidance favors allowlists, strict input validation, defense in
  depth, and disabling redirect following when redirects could bypass
  validation.
- npm exposes dry-run, package-lock-only, ignore-scripts, and git-dependency
  controls, but lifecycle scripts and git dependencies remain explicit risk.
- pip supports dry-run reports, but its own secure-install docs warn that
  default installs do not protect against remote tampering and may run
  arbitrary code. Safe pip execution needs hash-checking and binary-only
  constraints.
- skills.sh documents `npx skills add` and anonymous telemetry, but also tells
  users to review skills because ecosystem quality and security are not
  guaranteed. Allbert should not delegate trust or install behavior to that CLI.
- OpenClaw and Hermes both treat skills as lifecycle-managed remote sources,
  and Anthropic's skills repository models skills as one plugin payload in a
  broader marketplace manifest. That supports treating skills.sh as one source
  profile, not the Allbert trust model.

## Decision

Allbert will add confirmed external capability adapters in v0.10 through
registered Jido actions only.

The first confirmed HTTP/service action remains `external_network_request`.
Before v0.10, approvals for that action recorded `adapter_unavailable`. In
v0.10, new approved requests may resume the same registered action and execute
through a bounded `Req` adapter after Security Central re-check. Historical
`adapter_unavailable` records remain valid audit history.

All HTTP/service calls must:

- use `Req`
- use Settings Central service/source profiles and encrypted secret refs
- validate method, scheme, host, path, query, headers, timeout, response size,
  retry policy, and redirect policy before pending creation and before resume
- default to no automatic redirects and no automatic retries
- deny embedded URL credentials, non-HTTP schemes, Unix sockets, private
  networks, loopback, link-local, multicast, broadcast, cloud metadata
  endpoints, and unsafe IP literals
- redact secrets, sensitive headers, and large bodies in output, traces, and
  audits
- use `Req.Test` or equivalent stubs in automated tests instead of live network
  calls

Remote network content gets an explicit security posture in this ADR, and ADR
0012 generalizes the same posture to local and remote resource access. Any
workflow that fetches URL content for later summarization, inspection, import,
package metadata use, or another consumer must carry resource access metadata
with:

- origin kind and canonical URL or path
- method when applicable
- source/profile label
- operation class, such as `external_service_request`, `summarize_url`,
  `inspect_document`, `import_skill`, `import_local_skill`, or
  `run_skill_script`
- access mode and scope
- expected content kind and accepted content types
- byte cap, redirect/retry posture, and cache/digest expectation
- origin channel/surface and response target when available
- confirmation id and downstream consumer

Operation class is part of the security boundary. A remembered approval for
`summarize_url` must not authorize `import_skill`; an `inspect_document`
approval must not authorize package installation; `import_local_skill` must not
authorize `run_skill_script`; an import approval must not authorize activation,
trust, dependency installation, script execution, or package install.

Package installs get distinct policy, not a reused shell permission. v0.10
adds `:package_install` as a high-risk permission with a confirmation safety
floor. Package-install actions may reuse v0.08 local runner primitives, but
only through package-manager profiles with explicit executable/argv, target
root, dry-run preview, confirmation, timeout, output cap, redaction, and audit.
The first executable profile should be npm with lifecycle scripts disabled and
git/global/path/URL installs denied by default. Pip remains preview/audit-only
unless strict hash-checking, binary-only, pinned requirement, and target-root
controls are implemented and tested.

Online skill import also gets distinct policy. v0.10 adds
`:online_skill_import` as a high-risk permission with a confirmation safety
floor. Search/detail use `:external_network` and `Req` source profiles because
they fetch remote metadata without importing. Audit inspects cached fetched
metadata as `:read_only`. Import uses `:online_skill_import`, writes only to
`<ALLBERT_HOME>/cache/skills`, writes source manifests, runs the existing skill
parser/registry validation, and leaves imported skills disabled and untrusted.
Import does not enable, trust, activate, run scripts, install dependencies, or
load Elixir modules.

skills.sh is one source profile and search convenience. Direct skill URL
import should be modeled as `remote_url + import_skill`, followed by the same
parser/registry validation and disabled/untrusted cache write. Local skill
directory import should be modeled as `local_path + import_local_skill`, also
followed by parser/registry validation and disabled/untrusted import state. No
import path should require a marketplace-specific search result.

v0.10 does not add container, remote, or microVM isolation. If a package,
online import, or untrusted-code workflow needs that level of isolation, the
workflow must be denied or deferred to a later sandbox milestone.

## Consequences

- `external_network_request` changes from inert confirmation scaffolding to the
  first confirmed external HTTP action for new v0.10 requests.
- `approve_confirmation` may resume `external_network_request`,
  `run_package_install`, and `import_online_skill` only after Security Central
  re-check and target-specific validation.
- Security Central gains `:package_install` and `:online_skill_import`.
- Settings Central gains external service, package install, and online import
  policy namespaces.
- Req becomes the only HTTP client for runtime external adapters.
- Req redirect/retry behavior must be configured deliberately and tested.
- Package managers are not shell strings. They are package-manager profiles
  with explicit argv, previews, and audit records.
- skills.sh and other registries are sources of candidates, not trust roots.
- Resource Access Security Posture becomes the shared substrate for later URL
  summarization, document inspection, local skill directory import, direct
  skill URL import, trusted skill script execution UX, and source-profile
  consumers.
- Imported skills remain non-executable until existing local trust, enablement,
  capability, digest, and confirmation rules allow later actions.
- v0.11 can consume these real risky capabilities in the execution-aware intent
  contract and Approval Handoff without adding a new network primitive. Its
  consumer UX may orchestrate URL summarization or direct skill URL import over
  the v0.10 adapter, but channels and summarizers do not gain direct fetch
  authority.
- v0.12 jobs and v0.13 channels may create or render confirmation requests for
  these capabilities, but must not run them invisibly.
- v0.16 security hardening should add evals for SSRF, redirect, retry,
  package-manager, supply-chain, import, resource access posture, summarizer
  handoff, credential redaction, path traversal, symlink escape, operation
  scope bypass, and approval bypass cases.

## Implementation Notes

- v0.10 M2 implemented the confirmed `Req` external request adapter and kept
  historical `adapter_unavailable` records as audit history.
- v0.10 M3 implemented package install planning and confirmed npm execution
  through package-manager profiles; pip remains preview-only.
- v0.10 M4 implemented confirmed online skill search/detail/audit/import with
  disabled, untrusted cache writes and source manifests. Online source failures
  after approval are target execution failures (`target_status=failed`) on an
  `approved` confirmation, not operator or policy denials. The default
  skills.sh source searches the current `/api/search` endpoint from its
  configured API base and keeps page fallback for detail fetches.
- v0.10 M5 made CLI, `/settings`, markdown traces, confirmation audits, and
  Security Central status render the same v0.10 request/result metadata.
- v0.10 M6 reconciles the actual post-M5 history: the online approval
  clarity/search fix, README/operator onboarding cleanup, ADR 0012 Resource
  Access Security Posture, and historical v0.08/v0.09 reframing.
- v0.10 M7 implemented the shared resource reference contract through
  `AllbertAssist.Resources.Ref`, `Scope`, `OperationClass`, inert `Grant`
  descriptors, and `AllbertAssist.Confirmations.ResourceMetadata`. Existing
  shell, skill script, external request, package install, and online skill
  source summaries can now emit `resource_refs` metadata without changing
  permission behavior.
- v0.10 M8-M9 resume after M7 with operation-scoped remembered approval
  requirements and final release readiness/user testing. v0.11 then consumes
  the resulting posture for channel-native local and remote resource UX.
