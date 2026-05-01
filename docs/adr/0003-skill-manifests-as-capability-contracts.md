# ADR 0003: Agent Skills Compatibility With Allbert Capability Overlay

## Status

Accepted.

## Context

Allbert's origin note calls for a system that can read skills, choose them from
natural language, ask for permission when needed, and eventually help create new
skills. The v0.01 runtime now has a signal-first boundary, a primary intent
agent, named Jido actions, a permission gate, markdown memory, traces, CLI, and
LiveView.

The remaining v0.01 skill layer is intentionally thin: `AllbertAssist.Skills`
contains a static list of capabilities in code. That is enough for the first
loop, but it is not enough foundation for scheduled jobs, additional channels,
external tools, shell execution, or future skill creation. Those features need
one shared way to know which capabilities exist, what they are allowed to do,
and how their behavior should be traced.

The external skill ecosystem has converged around Agent Skills: a skill is a
directory with a required `SKILL.md` file containing YAML frontmatter and
markdown instructions, with optional `scripts/`, `references/`, and `assets/`
directories. The format emphasizes progressive disclosure: discover by
`name`/`description`, activate by loading the full instructions, and load
resources only when needed.

At the same time, standard Agent Skills can include scripts and instructions to
use external tools. Allowing those scripts or tools to run automatically would
move too much power ahead of Allbert's permission, confirmation, and trace
model.

## Decision

Allbert will adopt the Agent Skills directory and `SKILL.md` format as its
external and native skill format.

Allbert-specific skills will be standard Agent Skills with an optional
namespaced metadata overlay. That overlay can describe the known Jido actions a
skill may invoke, the permissions those actions require, the confirmation
policy, and expected memory and trace effects. The registry translates standard
skills into internal Allbert skill records and, when present, translates the
Allbert overlay into a capability contract.

v0.03 implements the skill substrate: parse, validate, discover, trust, read,
activate, and trace skills. Capability contracts remain inert in v0.03. A later
milestone promotes validated contracts into action-backed skills.

Imported skills without Allbert metadata are instruction-only or workflow
skills. They can be discovered, inspected, and activated as context, but they
cannot gain new side effects.

Capability skills may reference only registered Allbert/Jido action names. They
may not name an arbitrary Elixir module and cause it to execute. Bundled scripts
and external package installation remain non-executable in v0.03; they may be
listed, inspected, planned, and traced, but not run.

Autonomous skill creation, scripting engines, and code-loading skills are
deferred until the permission, confirmation, sandbox, and trace model has
matured.

## Consequences

- Allbert can participate in the wider Agent Skills ecosystem instead of
  creating an incompatible `allbert-skills` island.
- Skills remain inspectable, portable, and aligned with markdown-first memory.
- Agents, CLI, LiveView, scheduled jobs, and future channels can discover the
  same capability contracts.
- Permissions and confirmations can be reasoned about before any side effect
  runs.
- Adding entirely new executable capabilities will require adding or
  registering a Jido action in code first.
- A direct YAML parser dependency is required for `SKILL.md` frontmatter.
- Future scripting or autonomous skill creation will need a separate ADR and
  sandbox design rather than piggybacking on the v0.03 registry.
