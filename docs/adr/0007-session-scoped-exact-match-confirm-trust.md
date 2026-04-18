# ADR 0007: "Always" confirm scope is session-only and exact-match

Date: 2026-04-17
Status: Accepted

## Context

When the kernel asks the user to approve a risky action such as a process execution, the confirm prompt offers three choices: deny, allow once, or "always." A confirm UI needs to define what "always" means. Two extremes:

1. "Always" writes to persistent config and trusts the bare program name forever.
2. "Always" is limited to the current session and tied to the exact normalized request.

Option (1) is convenient but turns a single UX click into a durable security policy that the user may not remember granting. It also lets future invocations of the same program with very different arguments inherit the earlier approval, which collapses the distinction between "approving `ls` in this cwd" and "approving anything named `ls` anywhere." Once granted, it is invisible until someone audits the config file.

Option (2) keeps the scope of approval aligned with what the user actually saw when they clicked "always." Persistent trust still exists, but it goes through a deliberate path: editing the config's explicit allow-list.

## Decision

`AllowSession` caches the exact normalized exec request for the lifetime of the current `Kernel` instance.

- Scope: current session only. Never written back to `config.toml`.
- Match: exact normalized request (`program`, `args`, `cwd`) rather than program name.
- Persistent allow entries remain a separate, deliberate mechanism in config.

Session trust is a UX convenience, not a policy promise.

## Consequences

**Positive**
- Approval surface matches what the user saw when they approved.
- A bare-name program cannot smuggle arbitrary arguments under an earlier approval.
- Persistent trust requires a visible, auditable edit to the config file.

**Negative**
- Repeated similar commands across sessions re-prompt, which can feel noisy.
- The user must learn that the config allow-list is the durable path if repeated prompts become annoying.

**Neutral**
- Future versions may introduce richer approval scopes (pattern-based, time-bounded) but should not do so silently.
- Logs of approvals can be added later without changing this scope rule.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
