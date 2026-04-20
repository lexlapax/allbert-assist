# ADR 0034: Skill scripts run under the same exec policy as tools

Date: 2026-04-18
Status: Proposed

## Context

AgentSkills allows shipping `scripts/` directories inside a skill folder — typically Bash, Python, or Node programs that support the skill's prompt. v0.1 already established a central `exec_policy` (ADR 0004) and a policy envelope (ADR 0009). v0.4 adopts the folder format (ADR 0032); the question is how skill scripts should execute.

Options considered:

1. Skill scripts execute through a skill-specific runner that bypasses `exec_policy`. Fast, but breaks the policy envelope and undoes v0.1's central security posture.
2. Skill scripts execute through the same `process_exec` seam as any other command, with `exec_policy`, confirm-trust (ADR 0007), and hook surface applied identically.
3. Skill scripts execute in a sandboxed subprocess with its own policy layer.

Option 3 is a longer-horizon goal but adds a new runtime surface that v0.4 does not need. Option 2 matches v0.1's "one policy surface" principle.

## Decision

Skill scripts run under the same exec policy as tools.

- Skill scripts are declared in `SKILL.md` frontmatter under `scripts:` with an interpreter hint (e.g. `python`, `bash`, `node`) and a relative path (e.g. `scripts/run.py`).
- The kernel invokes each script through the `process_exec` seam, not via raw subprocess from prompt templates. All `exec_policy` rules apply.
- Default interpreter allowlist in v0.4: Bash and Python. Node (and any other interpreter) requires explicit opt-in in `config.exec_policy` before a skill that relies on it can run scripts.
- Every script invocation is observable through the accepted `BeforeTool` / `AfterTool` hook points on the `process_exec` tool, carrying the skill name, interpreter, and script path as metadata. If Allbert later adds dedicated exec hook points, that is an additive extension to ADR 0006 rather than a replacement for the existing names.
- Skills declaring scripts but lacking an interpreter on the allowlist still load; they simply cannot run those scripts until the user updates `exec_policy`.
- The preview step at install time (ADR 0033) surfaces required interpreters so the user can see up front whether they will need to widen `exec_policy` before the skill is usable.

## Consequences

**Positive**
- One policy surface for everything that executes — matches v0.1's "security at the core."
- Users can audit, restrict, or log skill script execution per interpreter just like any exec call.
- No new privileged runtime path slips in alongside skills.

**Negative**
- Some skills authored for the broader AgentSkills ecosystem that rely on Node will not run until explicitly opted in. Acceptable trade-off: an explicit opt-in is better than a silent broader default.
- Skill authors must be clear about which interpreters their scripts require so install previews are informative.

**Neutral**
- Future sandboxing work can layer on top of this seam without changing the skill-author contract.
- Adding interpreter allowlist entries is a config change, not a skill change.

## References

- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0009](0009-v0-1-tool-surface-expansion-and-policy-envelope.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
