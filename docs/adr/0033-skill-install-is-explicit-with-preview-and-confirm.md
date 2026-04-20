# ADR 0033: Skill install is explicit with preview and confirm

Date: 2026-04-18
Status: Proposed

## Context

Adopting the AgentSkills folder format (ADR 0032) makes skill-sharing easier, but a shared skill will contribute prompt content the kernel loads on activation and may ship scripts that the kernel later executes through the exec seam (ADR 0034). That matches the trust surface already covered by `confirm-trust` (ADR 0007) and `exec_policy` (ADR 0004): anything that touches a user's runtime authority requires explicit approval.

Options considered:

1. Auto-install from a URL or path with no prompt.
2. Download first, then prompt the user to approve what will be installed, then activate.
3. Install silently but require explicit activation per session.

Option 1 is unsafe. Option 3 still lets installable content sit on disk unreviewed — the risk is only deferred. Option 2 keeps the user in the loop at install time, which is the right moment to audit frontmatter, script hashes, and `allowed-tools` claims.

## Decision

Every skill install goes through an explicit preview + confirmation step before activation.

- The install flow fetches the candidate skill into a quarantine directory under `~/.allbert/skills/incoming/` before touching the active skills root.
- The preview surfaces: skill name and description, the first N lines of `SKILL.md`, a list of scripts with SHA-256 hashes, the declared `allowed-tools`, and the source (local path or git URL + pinned ref).
- The user approves or rejects at the CLI (or, once supported, through a prompt-native confirmation flow). Rejection deletes the quarantine copy.
- Approvals may be remembered per source (keyed by source identity + SHA-256 of the skill tree) to streamline repeat installs from trusted sources. Remembered approvals do not carry across SHA changes; any change forces re-preview.
- Skills installed from a local path still go through the same preview step so the surface stays uniform.
- No skill is activated on any session until it has been explicitly approved.

## Consequences

**Positive**
- Treats skill install as a trust-sensitive action, consistent with `confirm-trust` and `exec_policy`.
- Makes supply-chain hygiene visible: users see script hashes, tool claims, and source identity at install time.
- Forces integrity awareness into the flow rather than relying on retrospective audit.

**Negative**
- Slight friction on first install per source. Mitigated by remembered approvals.
- Preview rendering must handle long descriptions, many scripts, and unusual frontmatter gracefully.

**Neutral**
- A future curated registry (deferred per ADR 0035) inherits the same install gate; registry provenance becomes another field in the preview.
- The preview + confirm seam is reusable for other trust-sensitive installs (e.g. bundled agent definitions).

## References

- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0027](0027-durable-schedule-mutations-require-preview-and-explicit-confirmation.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0035](0035-remote-skill-registry-is-deferred-v0-4-sources-are-local-path-and-git-url.md)
- [docs/plans/v0.4-agentskills-adoption.md](../plans/v0.4-agentskills-adoption.md)
