# ADR 0002: Skill bodies require explicit activation

Date: 2026-04-17
Status: Proposed

## Context

Allbert is expected to load skills from markdown files, and over time that collection may include third-party or user-generated skills. There are two competing goals:

1. keep skill discovery easy so the model knows what capabilities are available
2. avoid automatically stuffing large, untrusted prompt bodies into every turn

If every `SKILL.md` body is injected by default, base context grows quickly and the system treats arbitrary skill text as trusted runtime instruction. That creates a prompt-injection hazard and weakens the boundary between "available capability" and "active instruction."

## Decision

Allbert will separate skill discovery from skill activation.

- This ADR applies to `SKILL.md` files only. Runtime bootstrap files such as `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, and `BOOTSTRAP.md` are governed separately by [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md).
- Skill manifests, meaning lightweight metadata such as name and description, are always available to the model.
- Full skill bodies are added to prompt context only after an explicit `invoke_skill` step.
- `SKILL.md` bodies are treated as untrusted prompt input even after activation; they can guide behavior, but they do not bypass runtime policy enforcement.

This makes activation an explicit runtime event rather than an ambient property of scanning the skills directory.

## Consequences

**Positive**
- Base prompt context stays small enough for many installed skills.
- Prompt-injection risk is reduced because skill text is not silently always-on.
- The model has a clear path: discover a skill, then choose to activate it.

**Negative**
- The agent must spend a tool call to activate a skill before using its full guidance.
- Some "obvious" skill behavior may feel less magical because the activation step is visible.

**Neutral**
- Skill metadata quality matters more, because discovery depends on the manifest.
- Future richer trust models can extend activation without changing the basic boundary.

## References

- [docs/plans/v0.1-mvp.md](../plans/v0.1-mvp.md)
