# ADR 0072: Skill-authoring is a first-party natural-language skill

Date: 2026-04-23
Status: Proposed

Reinforces: [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md), [ADR 0048](0048-v0-5-ships-a-first-party-memory-curator-skill.md)

## Context

v0.4 shipped `allbert-cli skills init` as a CLI wizard for creating new folder-format skills. It works, but it sets the wrong default expectation: the front door for "I want a skill that does X" should not be a CLI subcommand. ADR 0038 says natural language is the user's extension surface; a CLI wizard is the opposite of that.

There are three plausible designs for the user-facing authoring path:

1. **Keep the CLI wizard as the default.** Simple, matches the v0.4 implementation. But it pushes every "I want a skill that..." conversation into command-line ritual and contradicts ADR 0038.
2. **Add a kernel-native authoring agent.** Good ergonomics, but it sets a precedent that "user-facing capabilities ship as kernel agents" — which collides with the ADR 0048 pattern (`memory-curator` ships as a first-party skill, not a kernel agent). Two precedents for the same shape of capability is one too many.
3. **Ship the authoring capability as a first-party natural-language skill.** Matches ADR 0048's pattern, lets intent routing (ADR 0030) dispatch to it, keeps the CLI wizard available as an escape hatch.

Option 3 is the right shape. It also gives the authoring capability the same trust gates as any other skill: it can be inspected, fenced via `allowed-tools`, replaced by an alternate skill if a user prefers a different style, and uninstalled cleanly.

The remaining question is what the skill is called and where it lives. Following the `memory-curator` precedent, the answer is `skill-author`, shipped under `skills/skill-author/` in the repo and installed under `~/.allbert/skills/installed/skill-author/` on first run.

## Decision

The default user-facing skill-authoring path is a first-party skill (`skill-author`). The v0.4 CLI wizard (`allbert-cli skills init`) is retained as an explicit escape hatch.

### Packaging

- `skills/skill-author/` ships in the repo. SKILL.md, prompts, and any helper references live there.
- On first daemon run after v0.11 upgrade, the skill is seeded into `~/.allbert/skills/installed/skill-author/` (the same shape ADR 0048 establishes for `memory-curator`). Seeding is recorded in the install log; the operator can uninstall the skill and replace it with their own variant.
- The skill carries `provenance: external` (per ADR 0071). It is shipped by Allbert, not authored by the user.

### Intent routing

ADR 0030's intent routing dispatches natural-language requests to `skill-author`. Triggering phrases are markdown-first; sample patterns:

- "make me a skill that drafts standup updates"
- "I want a skill to summarize my calendar"
- "create a skill that..."
- "let's build a skill for..."

The exact patterns live in `skills/skill-author/SKILL.md` frontmatter (`intents:` per ADR 0031), not in the kernel. Operators can add or change patterns by editing the installed copy.

### Conversational intake

`skill-author` walks the user through a structured intake:

1. **Name** (kebab-case, unique, ≤64 chars per ADR 0032).
2. **Description** (≤1024 chars per ADR 0032).
3. **Capability summary**: what the skill does, what inputs it needs, what outputs it produces.
4. **Interpreter choice if scripts are needed**: Python (recommended), Bash, or any other interpreter already on `security.exec_allow`. Lua appears as an option only if the scripting engine is enabled (ADR 0069/0070) and `lua` is on the allowlist.
5. **Tool needs** (`allowed-tools` fence per ADR 0008).
6. **Agent contribution** (optional, per ADR 0031).

The skill uses the in-memory tier-1/tier-2 prompt builder (ADR 0036) to preview what the new skill would contribute before materializing it. Each refinement round re-runs the preview so the operator sees what changes.

### Iterative refinement

Drafts persist across turns at `~/.allbert/skills/incoming/<draft-name>/` (per ADR 0071). A user can start a draft on Monday, return on Wednesday, refine it further, and submit on Friday — the draft survives session exit because `incoming/` is on disk, not in session memory.

### Final submission

Final submission routes through the standard install preview + confirm flow (ADR 0033). The skill-authoring skill does **not** call `create_skill` with `skip_quarantine: true` (ADR 0071). That tool path is reserved for kernel-internal first-party seeding. `skill-author`'s `allowed-tools` fence enforces this at the kernel boundary.

### Capability scope for v0.11

`skill-author` can author:

- ✅ Skills with `scripts/` using any interpreter already on the allowlist (bash, python, etc.).
- ✅ Skills that contribute agents via ADR 0031 frontmatter.
- ✅ Skills that reference other installed skills by name in their body.
- ✅ Skills with `references/` and `assets/` subdirectories.

It cannot:

- ❌ Author skills declaring Lua scripts unless the scripting engine is enabled and `lua` is on `security.exec_allow`. Enforced at preview-time validation.
- ❌ Modify or delete already-installed skills. The skill-authoring path produces new skills; managing the existing skill set is a separate operator concern.

### CLI escape hatch

`allbert-cli skills init` remains available for users who prefer a CLI wizard. It is documented in the operator guide as the explicit advanced path. ADR 0038's principle holds: the natural-language path is the default; the CLI is the escape hatch, not the other way around.

### Recommendation: Python as the default scripting interpreter

When the user does not state a preference, `skill-author` recommends Python. Rationale:

- Python is already on the v0.4 default `security.exec_allow` list (ADR 0034).
- It is the most portable interpreter likely to be present on a contributor or operator machine.
- It is the most ergonomic for the kind of "small data wrangling" most authored skills will do.

This is a recommendation, not a policy. The user can pick Bash or any other allowlisted interpreter.

## Consequences

**Positive**

- Aligns user-facing authoring with ADR 0038 (natural-language extension) and ADR 0048 (first-party skill packaging).
- Intent routing makes the surface discoverable: "make me a skill" works without the user knowing a CLI command.
- The CLI wizard remains for users who prefer it — no capability removed.
- `skill-author` is a normal skill: inspectable, fence-able, uninstallable, replaceable.

**Negative**

- Two paths to the same outcome (natural language + CLI). Documented as "natural is default, CLI is escape hatch" so users don't have to choose blindly.
- First-party seeding adds another file to `~/.allbert/skills/installed/` on upgrade. Acceptable — it matches the `memory-curator` precedent.

**Neutral**

- Future authoring patterns (e.g. a "convert markdown notes into a skill" capability) can be additional skills, or extensions to `skill-author`. The seam does not constrain.
- The recommendation of Python as default interpreter is documented in `docs/operator/skill-authoring.md` and can be revisited per release without an ADR change.

## References

- [docs/plans/v0.11-self-improvement.md](../plans/v0.11-self-improvement.md)
- [ADR 0008](0008-skill-allowed-tools-is-a-fence-not-a-sandbox.md)
- [ADR 0030](0030-intent-routing-is-a-kernel-native-step.md)
- [ADR 0031](0031-skills-can-contribute-agents-via-frontmatter.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0036](0036-progressive-disclosure-maps-to-prompt-construction-stages.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0048](0048-v0-5-ships-a-first-party-memory-curator-skill.md)
- [ADR 0069](0069-scripting-engine-trait-with-lua-as-the-v0-11-default-embedded-runtime.md)
- [ADR 0070](0070-embedded-script-sandbox-policy.md)
- [ADR 0071](0071-self-authored-skills-route-through-the-standard-install-quarantine.md)
