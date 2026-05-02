# ADR 0006: Security Central As Policy Evaluation Boundary

## Status

Accepted.

## Context

Allbert currently has a small `AllbertAssist.Security.PermissionGate` that
returns permission decisions for the first local assistant loop. That is enough
for read-only work, memory writes, settings writes, command planning, blocked
command execution, and external network confirmation.

The post-v0.03 roadmap is broader. Action-backed skills, confirmations, shell
execution, skill scripts, package installs, external services, online skill
import, scheduled jobs, and additional channels all need more than
`permission -> allowed/denied`. They need one place to reason about actor,
channel, session, selected skill, skill provenance, action, resource, external
content, supply chain, risk, confirmation, redaction, audit, and traces.

External agent harnesses point in the same direction. Hermes documents a
defense-in-depth model covering user authorization, dangerous command approval,
container isolation, MCP credential filtering, context file scanning,
cross-session isolation, and input sanitization:
`https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/security.md`.
Hermes MCP docs also emphasize environment filtering, tool exposure control,
rate limits, timeouts, and tool-loop limits:
`https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp`.

OpenClaw documents explicit trust boundaries for channel access, agent
sessions, tool execution, external content, and supply chain:
`https://docs.openclaw.ai/security/THREAT-MODEL-ATLAS`. Its exec and approval
docs show the same shape Allbert needs later: policy, allowlists, approval
state, host/sandbox choice, strict inline-eval handling, and safe-bin rules:
`https://docs.openclaw.ai/tools/exec` and
`https://docs.openclaw.ai/tools/exec-approvals`.

## Decision

Allbert will introduce Security Central in v0.05, after v0.04 establishes the
Jido runtime/action boundary that Security Central consumes.

Security Central is the policy evaluation boundary for runtime security. It is
not a replacement for Settings Central. Settings Central remains the durable,
typed, auditable source for operator policy and secrets. Security Central reads
settings, skill trust, secret status, and runtime context, then returns a
structured security decision.

The canonical security decision should include:

- permission
- decision or outcome
- reason
- risk tier
- confirmation requirement
- redaction obligations
- audit metadata
- trace metadata
- actor, channel, and session context
- selected skill and action context
- trust boundary and provenance summary

`AllbertAssist.Security.PermissionGate.authorize/2` remains as a compatibility
entrypoint, but it delegates conceptually to the Security Central decision path.
Future actions, confirmations, execution adapters, jobs, and channels should use
Security Central decisions rather than inventing their own private policy
objects.

## Consequences

- v0.05 becomes Security Central Foundation.
- v0.04 becomes Jido Runtime Convergence Refactor.
- The action-backed Allbert skills plan moves to v0.06.
- Confirmation workflow moves to v0.07.
- Shell execution, skill scripts, external services/package installs/imports,
  execution-aware intent, jobs, channels, memory review, and cross-surface
  intent all move forward one version.
- Security decisions become richer than permission decisions, but current
  permission behavior must remain compatible.
- Redaction policy gains a central home while encrypted secret storage remains
  in `AllbertAssist.Settings.Secrets`.
- Sandbox and supply-chain policy shapes can be named before execution or
  online import exists.
- Security hardening and evals should return after the risky capability and
  channel surfaces exist.
