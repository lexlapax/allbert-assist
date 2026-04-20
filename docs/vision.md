# Allbert Vision

Allbert is a personal AI assistant that grows with you.

The project is centered on a small Rust runtime kernel rather than a bloated application shell. The kernel should stay compact, auditable, and secure while remaining extensible through tools, skills, and future frontends.

## Principles

- **Kernel first.** The runtime core owns the agent loop, tools, memory, policy, and system behavior.
- **Daemon capable.** The kernel must be able to run as a long-lived local daemon host so that user-facing interfaces attach to it instead of each booting their own private runtime.
- **Portable by default.** Durable knowledge should live in markdown files for posterity and transference between systems.
- **Markdown-defined identity.** Personality, user profile, and local conventions should live in a small set of editable markdown bootstrap files that the kernel can load into runtime context.
- **Security at the core.** Risky actions should be mediated by explicit policy checks at the kernel layer rather than hidden in frontends or ad hoc scripts.
- **Service oriented, not bloated.** New capabilities should come from small internal services, skills, tools, and clean interfaces before adding heavyweight embedded runtimes or a broad distributed platform.
- **Natural interface.** End users interact via natural language — text, and over time voice, images, and attachments through channels. User-authored extension lives in markdown and declarative config (bootstrap files, skills, jobs, agent prompts). Rust is the runtime-scaffolding language, not a user-facing language. Writing code is never a prerequisite for using or extending Allbert.
- **Personal over generic.** The assistant should learn your habits, preferences, history, and working context over time.

## What Allbert Should Do

- Run an agentic loop that can listen, reason, act, and continue a turn until it is done or hits a limit.
- Run that loop either directly or inside a long-lived local daemon that can host multiple attachable channels.
- Let a primary agent delegate bounded work to sub-agents without losing the policy envelope or cost visibility.
- Classify user intent at the start of each turn so the right skills, sub-agents, or services are engaged deliberately rather than by prompt accident.
- Let a user create and manage recurring work through normal conversation, while still requiring explicit confirmation for durable schedule changes.
- Load a small bootstrap bundle of markdown files that define persona, user context, identity, and local working conventions.
- Discover, read, install, and invoke skills — including skills authored for the wider AgentSkills ecosystem.
- Execute a small set of core tools, including process execution, input gathering, and memory operations.
- Keep track of operational cost.
- Support tracing so failures can be diagnosed and learned from.
- Maintain a memory system that can be inspected and edited directly by the user, with ranked retrieval once memory is large enough to need it.
- Host lightweight internal services such as channel handling, session management, and job management without turning into a large distributed system.
- Reach the user through more than one surface — terminal first, then messaging channels, later richer native interfaces.
- Accept input and produce output across text, voice, images, and file attachments as channels and providers support it.

## Agent Direction

Allbert should treat agents as first-class runtime participants rather than as a framing of prompts. Each session has a root agent; an orchestrator agent can spawn bounded sub-agents for focused sub-tasks. Every sub-agent turn runs through the same kernel hooks, cost tracking, and policy envelope as any other turn. Skills can contribute new agent roles without requiring kernel changes, so the set of agents grows with the skill ecosystem rather than with a bespoke registry.

## Intent Direction

Allbert should classify what the user turn is asking for — task, chat, schedule, memory query, meta — before constructing an agent turn. Classification is a kernel step, not a prompt trick: it is observable via hooks, cost-tracked via the same surfaces as any other LLM call, and swappable without rewriting skills. Intent is a hint that guides skill selection and sub-agent choice, not a hard gate that blocks the user.

## Memory Direction

Allbert should keep its durable memory in markdown and linked files first, with richer compiled or indexed memory added later for runtime performance. The memory system should eventually support:

- maintaining and pruning long-term memory
- compiling searchable memory representations with ranked retrieval
- separating durable identity/profile files from durable learned memory
- separating durable knowledge from ephemeral session context
- staging new learnings for user review before promoting them into durable memory
- adapting over time to the user's preferences and personality

## Identity Direction

Allbert should have a small always-on bootstrap layer made of inspectable markdown files rather than a hidden hardcoded personality blob. That layer should cover who the assistant is, who it serves, and local working conventions, while staying distinct from both task skills and long-term memory.

## Model Direction

For planning and reasoning, Allbert should use strong foundation models. Over time it may also use smaller specialized models for memory shaping, personalization, or other narrow tasks, as long as those additions keep the runtime understandable and maintainable.

## Skill Direction

Skills should be the primary way Allbert gains new capabilities. The canonical shape follows the AgentSkills open standard: a folder with a `SKILL.md`, optional scripts, references, and assets, and a documented frontmatter schema. That lets Allbert read and share skills with the wider agent-assistant ecosystem. End users install and use skills; authoring happens either by hand (markdown plus declarative frontmatter — no code required) or through a natural-language scaffolding skill that Allbert itself provides. Every skill install goes through explicit preview and confirmation before activation; skill scripts run under the same exec policy as any other command. Progressive disclosure — surface a skill's name and description cheaply, load its body on activation, pull references only on demand — keeps skill discovery affordable even as the installed set grows.

## Channel Direction

Allbert should reach the user through more than one surface. The terminal REPL is the starting channel; messaging channels (Telegram first, then others) follow; richer native or web surfaces come later. Every channel is an adapter over the kernel's session model, not a separate product. Channels declare their capabilities — inline confirm, async confirm, rich output, file attach, and multimodal flags for voice and image input/output — so the kernel can route confirm-trust and policy checks through paths each channel actually supports. Multimodal content passes through to providers that support it; channels without a given capability transcode or refuse gracefully. Channels without any confirmation capability fail closed on policy-sensitive actions, just as scheduled jobs already do.

## Self-Improvement Direction

End users do not write Rust, Python, or Lua to extend Allbert. When Allbert improves itself, it is Allbert doing the authoring under the user's explicit review. A Rust coding skill can read, modify, build, and test the Allbert codebase in a sibling worktree, producing diffs the operator reviews before merge. A skill-authoring skill scaffolds new AgentSkills-format skills through natural-language conversation; the result lands in the same install quarantine as any external install. Embedded scripting — Lua first, others later — enters through a deliberate `ScriptingEngine` seam, opt-in per exec policy and sandboxed by default. Skills and tool seams come first; embedded scripting is an advanced, optional surface, never a prerequisite for end-user workflows.

## Product Direction

Early Allbert should stay focused:

- a terminal-first, source-based personal assistant for technical users
- a small kernel that can also be hosted as a local daemon
- attachable channels for REPL, CLI, and future interfaces
- bootstrap identity/personality files
- a small toolset
- skills
- memory
- security checks
- cost tracking
- tracing

End-user usability in v0.1 comes from guided setup for bootstrap identity and explicit workspace-trust configuration, not from packaged installers or a broader app shell.

After that foundation is solid, the next step is not just "cron jobs." It is a daemon substrate plus lightweight internal services, especially an internal job manager that can run background and scheduled work without making OS cron the primary runtime mechanism.

From there, the project grows along a sequenced path: agents and intent routing, then richer skills through AgentSkills adoption, then curated memory, then new channels, and finally self-improvement skills for Allbert itself. That sequence — captured in [docs/plans/roadmap.md](plans/roadmap.md) — keeps each release useful on its own while unlocking the next.

Even as that happens, Allbert should remain local-first, compact, and understandable. It should not turn into a broad distributed microservice platform just to gain background execution.

## Name

The name "Allbert" draws on the lexical hypothesis lineage associated with Gordon Allport and Henry S. Odbert, while also nodding playfully toward the idea of a capable personal assistant ala Batman's Albert.

## History

The rough original seed note for the project is preserved at [docs/notes/origin-2026-04-17.md](./notes/origin-2026-04-17.md).
