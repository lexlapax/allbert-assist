# ADR 0045: Operator-Supervised Self-Improvement Trust Tier

Status: Proposed for v0.46.

## Context

The v1.0 arc now includes a safe self-improvement precursor before the final
hardening milestone. Allbert should be able to notice repeated operator
patterns and propose useful drafts: skills, workflow YAML, template inputs, or
dynamic capability-gap requests.

Those suggestions are derived from traces, objectives, memory review decisions,
operator-marked examples, and existing skill/action metadata. That source data
is useful, but it is not authority. Repeated use, repeated approval, or model
confidence must not turn into permission grants, enabled skills, installed
plugins, package execution, or live code.

## Decision

Introduce an operator-supervised self-improvement trust tier for v0.46:

- Pattern discovery is read-only and runs through registered actions.
- Suggestion packets are advisory metadata only.
- Suggestions may create inert drafts in reviewed draft roots.
- Instruction-only skill drafts are disabled and untrusted by default.
- Workflow YAML drafts are declarative objective input only.
- Template inputs may hand off to the v0.38 templated creation path.
- Marketplace-lite metadata from v0.45 may inform suggestions but remains
  descriptive only.
- Reviewed memory promotion/update draft facades and objective/workflow
  draft-write facades may be added, but they write draft state only.
- Code-bearing drafts must hand off to the v0.36 sandbox/gate and v0.37
  trusted-validation/live-integration path before any live authority can be
  requested.
- Settings, secrets, shell, package-install, confirmation-decision,
  trust-control, and live workspace/canvas write facades are out of scope.
- Enablement, integration, publish, rollback, and marketplace submission still
  require normal registered actions, Security Central, durable confirmation,
  traces, and audits.

No trace-derived signal, model output, suggestion score, or repeated operator
approval grants permission by itself.

## Consequences

Allbert can become more helpful without becoming self-authorizing. Operators
get suggestions that reduce repeated manual work, while the action boundary
remains the only effectful boundary.

The implementation must add evals for:

- read-only pattern scans;
- suggestion packets carrying no authority;
- disabled/untrusted draft creation;
- code-bearing draft gate requirements;
- memory/workflow facade draft-only behavior;
- repeated-use non-grants;
- unsafe capability-request denial;
- marketplace/publish confirmation.

Fully autonomous skill creation, hidden model distillation, auto-enable,
auto-publish, remote code install, and unsupervised self-recompilation remain
outside the v1.0 arc.
