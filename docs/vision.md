# Allbert Vision

Allbert is a personal AI assistant that grows with you.

The project is centered on a small Rust runtime kernel rather than a bloated application shell. The kernel should stay compact, auditable, and secure while remaining extensible through tools, skills, and future frontends.

## Principles

- **Kernel first.** The runtime core owns the agent loop, tools, memory, policy, and system behavior.
- **Portable by default.** Durable knowledge should live in markdown files for posterity and transference between systems.
- **Markdown-defined identity.** Personality, user profile, and local conventions should live in a small set of editable markdown bootstrap files that the kernel can load into runtime context.
- **Security at the core.** Risky actions should be mediated by explicit policy checks at the kernel layer rather than hidden in frontends or ad hoc scripts.
- **Extensible, not bloated.** New capabilities should come from skills, tools, and clean interfaces before adding heavyweight embedded runtimes.
- **Personal over generic.** The assistant should learn your habits, preferences, history, and working context over time.

## What Allbert Should Do

- Run an agentic loop that can listen, reason, act, and continue a turn until it is done or hits a limit.
- Load a small bootstrap bundle of markdown files that define persona, user context, identity, and local working conventions.
- Discover, read, and invoke skills.
- Execute a small set of core tools, including process execution, input gathering, and memory operations.
- Keep track of operational cost.
- Support tracing so failures can be diagnosed and learned from.
- Maintain a memory system that can be inspected and edited directly by the user.

## Memory Direction

Allbert should keep its durable memory in markdown and linked files first, with richer compiled or indexed memory added later for runtime performance. The memory system should eventually support:

- maintaining and pruning long-term memory
- compiling searchable memory representations
- separating durable identity/profile files from durable learned memory
- separating durable knowledge from ephemeral session context
- adapting over time to the user's preferences and personality

## Identity Direction

Allbert should have a small always-on bootstrap layer made of inspectable markdown files rather than a hidden hardcoded personality blob. That layer should cover who the assistant is, who it serves, and local working conventions, while staying distinct from both task skills and long-term memory.

## Model Direction

For planning and reasoning, Allbert should use strong foundation models. Over time it may also use smaller specialized models for memory shaping, personalization, or other narrow tasks, as long as those additions keep the runtime understandable and maintainable.

## Extensibility Direction

Usable scripting may eventually be helpful, but it should enter through a deliberate interface rather than by making the kernel dependent on a large general-purpose runtime from day one. Skills and tool seams come first; embedded scripting engines can come later if they still look worthwhile.

## Product Direction

Early Allbert should stay focused:

- a simple assistant loop
- bootstrap identity/personality files
- a small toolset
- skills
- memory
- security checks
- cost tracking
- tracing

After that foundation is solid, the project can grow into scheduled jobs, broader integrations, richer memory retrieval, self-generated skills, and additional frontends.

## Name

The name "Allbert" draws on the lexical hypothesis lineage associated with Gordon Allport and Henry S. Odbert, while also nodding playfully toward the idea of a capable personal assistant ala Batman's Albert.

## History

The rough original seed note for the project is preserved at [docs/notes/origin-2026-04-17.md](./notes/origin-2026-04-17.md).
