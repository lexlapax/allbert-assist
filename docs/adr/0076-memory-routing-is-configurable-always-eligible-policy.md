# ADR 0076: Memory routing is configurable always-eligible policy

Date: 2026-04-24
Status: Accepted

## Context

Allbert already ships a first-party `memory-curator` skill. The skill can review staged entries, promote or reject memory, search durable memory, and help compact notes. The gap is routing: users should not have to remember that the skill exists before memory behavior improves, but loading the full skill body every turn would increase prompt size and cost.

The user-facing requirement is "make memory part of routing and configurable without writing code." The runtime requirement is "do not weaken progressive disclosure."

## Decision

v0.11 introduces memory routing policy with `always_eligible` as the default mode.

```toml
[memory.routing]
mode = "always_eligible"
always_eligible_skills = ["memory-curator"]
auto_activate_intents = ["memory_query"]
auto_activate_cues = ["remember", "what do you remember", "review staged", "promote that", "forget"]
```

Rules:

- Always-eligible skills are surfaced every root turn as likely available capabilities.
- Their full skill bodies are not loaded unless routing policy activates them.
- `memory-curator` auto-activates for `memory_query` and configured memory-review cues.
- Operators can change policy through config, setup, or `allbert-cli memory routing show|set`.
- Runtime-generated `~/.allbert/AGENTS.md` reflects the policy but is not the policy source.

Rejected alternatives:

- `always_active`: predictable but too expensive and too noisy for every turn.
- intent-only routing: safe but does not make memory feel sufficiently near at hand.
- editing generated `AGENTS.md`: violates the generated-bootstrap contract.

## Consequences

**Positive**

- Memory help is always discoverable without loading full prompt bodies every turn.
- Operators can tune routing without Rust changes or skill edits.
- Progressive disclosure remains intact.
- The generated `AGENTS.md` stays inspectable while config remains authoritative.

**Negative**

- Routing policy adds another config surface.
- Misconfigured cues could over-activate the curator, so validation and status rendering must be clear.

**Neutral**

- Other first-party or installed skills can later opt into the same routing mechanism.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0030](0030-intent-routing-is-a-kernel-step-not-a-skill-concern.md)
- [ADR 0036](0036-progressive-disclosure-maps-to-prompt-construction-stages.md)
- [ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md)
- [ADR 0048](0048-v0-5-ships-a-first-party-memory-curator-skill.md)
