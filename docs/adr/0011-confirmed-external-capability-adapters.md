# ADR 0011: Confirmed External Capability Adapters

## Status

Accepted for v0.10 planning.

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
floor. Search/detail/audit/import actions use `Req` source profiles. Import
writes only to `<ALLBERT_HOME>/cache/skills`, writes source manifests, runs the
existing skill parser/registry validation, and leaves imported skills disabled
and untrusted. Import does not enable, trust, activate, run scripts, install
dependencies, or load Elixir modules.

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
- Imported skills remain non-executable until existing local trust, enablement,
  capability, digest, and confirmation rules allow later actions.
- v0.11 can consume these real risky capabilities in the execution-aware intent
  contract and Approval Handoff without adding new execution powers.
- v0.12 jobs and v0.13 channels may create or render confirmation requests for
  these capabilities, but must not run them invisibly.
- v0.16 security hardening should add evals for SSRF, redirect, retry,
  package-manager, supply-chain, import, credential redaction, and approval
  bypass cases.
