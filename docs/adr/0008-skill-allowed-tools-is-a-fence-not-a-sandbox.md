# ADR 0008: Skill `allowed-tools` is a narrowing fence, not a sandbox

Date: 2026-04-17
Status: Accepted

## Context

Skills declare an `allowed-tools` list in their frontmatter. There is a tempting reading of that list as a per-skill sandbox: "when this skill is active, it can do these things and no others, in isolation." A sandbox reading implies real isolation guarantees — process boundaries, separate filesystem views, independent policy enforcement — none of which the MVP provides.

The reading that actually matches what the MVP can deliver is narrower: while a skill is active, the set of tools available to the model is intersected with the skill's declared list. Global policy still applies, filesystem roots still apply, confirm prompts still fire, and deny rules still deny. The list cannot grant anything the surrounding security layer would not already have allowed.

Conflating the two readings is a documentation hazard and a security hazard. If skill authors or users believe the list is a sandbox, they will assume isolation that is not present.

## Decision

A skill's `allowed-tools` list is a **narrowing fence**, not a sandbox.

- When any skill is active, tool dispatch must be a member of the union of the active skills' `allowed-tools` (plus a small built-in allowlist for low-risk tools like `request_input`, `read_memory`, `invoke_skill`, `list_skills`).
- The list can only narrow the set of available tools; it cannot expand privileges beyond global policy.
- Confirm prompts, filesystem roots, exec allow/deny rules, and other kernel-level security checks continue to apply unchanged.
- Documentation and error messages use the word "fence" rather than "sandbox" to avoid implying isolation the MVP does not provide.

## Consequences

**Positive**
- Skill-scoped capability narrowing is available without pretending to offer isolation the kernel cannot enforce.
- The security model is legible: one central policy layer, skills narrow the tool set, global rules still apply.
- Future real sandboxing (if needed) can be added as a distinct mechanism without overloading this field.

**Negative**
- Skill authors accustomed to sandbox-like models may need to adjust expectations.
- The fence name is slightly less intuitive than "permissions" but more accurate.

**Neutral**
- `allowed-tools` remains compatible with Claude Code's subset, so existing skill files remain portable.
- Richer per-skill capability fields (`fs_paths_read`, `net_allow`, etc.) can be added later without changing the meaning of `allowed-tools`.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
