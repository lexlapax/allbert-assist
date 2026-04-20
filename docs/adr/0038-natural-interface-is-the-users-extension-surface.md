# ADR 0038: Natural interface is the user's extension surface

Date: 2026-04-18
Status: Proposed

## Context

The v0.3–v0.7 plans introduce several technologies that could, taken literally, suggest the user is expected to write code: a Rust `Agent` trait (ADR 0029), AgentSkills with `scripts/` directories (ADR 0032), a self-improvement release that touches Rust and an embedded Lua engine (v0.7). Each of these technologies is a runtime concern, but without an explicit statement of who is expected to author what, future plans and future tooling could drift toward "power users learn Rust / Python / Lua" as the default extension surface.

The vision is the opposite. Allbert is a personal assistant. End users interact with it through natural language and other media — text now, voice and images once channels support them. When a user *extends* Allbert — giving it a new persona, a new skill, a new scheduled job, or a new agent role — the authoring surface is markdown plus a small amount of declarative config, not code.

Bootstrap identity is already in this shape: ADR 0010 establishes `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md` as the user-editable persona layer. Jobs are in this shape: ADR 0022 makes job definitions markdown with YAML frontmatter and a bounded schedule DSL. Skills are in this shape once v0.4 lands: ADR 0032 adopts AgentSkills folder format with markdown prompts. What was missing was an explicit statement that this pattern is the commitment, not an accident.

Alternative considered: leave the principle implicit, trusting each future release to honour it. That has already produced one drift — the v0.7 plan initially read as if users were expected to use the Rust and Lua seams directly. A one-line principle is not enough; the constraint needs to be written down so every future plan inherits it.

## Decision

Natural language and markdown are the user's extension surface. Rust is the runtime-scaffolding language; it is not a user-facing language. Any future feature that adds an "author something" verb must have a natural-language or markdown-edit path as its default user flow.

Specifically:

- **User interaction** happens via text, CLI text commands, and (from v0.6 onward) voice, images, and attachments through channels. Writing code is never a prerequisite for using Allbert.
- **User-authored extensions** live in markdown and declarative config: bootstrap files under `~/.allbert/` (ADR 0010, ADR 0039), skill folders (ADR 0032), job definitions (ADR 0022), agent prompt files (ADR 0031), and TOML config. These are the complete extension surface for end users.
- **Skill scripts** (ADR 0034) are authored by skill authors, not end users. End users encounter them at install time through preview + confirm (ADR 0033), not through a "write a script" step.
- **Embedded scripting** (v0.7 Lua engine) is an opt-in advanced surface. It exists so Allbert — or a skill author — has a small, sandboxed DSL available. It is never a requirement for end-user workflows.
- **Self-improvement capabilities** (v0.7 Rust rebuild skill, skill-authoring skill) frame Allbert as the author, with the user as reviewer. The user approves diffs or install previews; the user does not produce the code.
- **Every future release plan** that introduces an authoring verb must document the natural-language or markdown path as its primary UX. Code-writing paths, if introduced, must be labelled as advanced and optional.

This ADR does not prevent power users from editing Rust in a development checkout, authoring Lua scripts by hand, or wiring up new exec-policy interpreters. It states that these are advanced, off-path activities — not the default user surface.

## Consequences

**Positive**
- Sets a clear bar against which future release plans can be audited: if a release introduces an authoring verb with no natural-language or markdown path, the plan is wrong.
- Aligns Allbert's extension surface with the already-established patterns for identity, jobs, and skills, so users learn one shape rather than several.
- Keeps the project's target audience ("personal assistant for a technical user") from drifting into "framework for developers."

**Negative**
- Puts load on the natural-language / CLI surface: every extension flow must have a path that does not require writing code. Some features will take longer to design this way than they would with a code-first escape hatch.
- The skill-authoring skill (v0.7) becomes more important — it is the main authoring bridge for users who want to create skills without hand-editing folder layouts.

**Neutral**
- Future advanced tooling (e.g. a skill SDK, a Rust extension template repo) can still exist; it is labelled "advanced / optional," not presented as the default extension path.
- This ADR reinforces ADR 0010 (bootstrap markdown), ADR 0022 (markdown jobs), ADR 0031 (markdown-contributed agents), and ADR 0032 (folder-format skills) rather than introducing a new mechanism.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/roadmap.md](../plans/roadmap.md)
- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0029](0029-agents-are-first-class-runtime-participants.md)
- [ADR 0031](0031-skills-can-contribute-agents-via-frontmatter.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0033](0033-skill-install-is-explicit-with-preview-and-confirm.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md)
