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
- **Unix co-tenant.** Allbert composes with small focused utility programs already on the system rather than re-implementing them in-kernel. Shell exec stays under the existing policy envelope, and pipe-style composition of local tools is a legitimate tool shape, not a workaround.
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
- Build a bounded memory context before the first root-agent model call, then let tools, skills, and sub-agents deepen that context on demand rather than by silently loading everything up front.
- Keep operator-facing runtime state legible through terminal telemetry: model posture, context pressure, token usage, cost, memory state, active skills, pending approvals, and trace posture.
- Host lightweight internal services such as channel handling, session management, and job management without turning into a large distributed system.
- Reach the user through more than one surface — terminal first, then messaging channels, later richer native interfaces.
- Accept input and produce output across text, voice, images, and file attachments as channels and providers support it.

## Agent Direction

Allbert should treat agents as first-class runtime participants rather than as a framing of prompts. Each session has a root agent; an orchestrator agent can spawn bounded sub-agents for focused sub-tasks. Every sub-agent turn runs through the same kernel hooks, cost tracking, and policy envelope as any other turn. Skills can contribute new agent roles without requiring kernel changes, so the set of agents grows with the skill ecosystem rather than with a bespoke registry. A generated `AGENTS.md` index should keep that roster inspectable for end users.

## Intent Direction

Allbert should classify what the user turn is asking for — task, chat, schedule, memory query, meta — before constructing an agent turn. Classification is a kernel step, not a prompt trick: it is observable via hooks, cost-tracked via the same surfaces as any other LLM call, and swappable without rewriting skills. Intent is a hint that guides skill selection and sub-agent choice, not a hard gate that blocks the user. The active operator surface should expose the last resolved intent so the system remains legible instead of magical.

## Memory Direction

Allbert should keep its durable memory in markdown and linked files first, with richer compiled or indexed memory added later for runtime performance. The memory system should eventually support:

- maintaining and pruning long-term memory
- compiling searchable memory representations with ranked retrieval
- keeping a small always-visible memory synopsis separate from larger retrieved memory documents
- separating durable identity/profile files from durable learned memory
- separating approved durable memory from staged candidate learnings
- separating durable knowledge from ephemeral session context
- staging new learnings for user review before promoting them into durable memory
- separating hot-path memory updates from background maintenance and promotion work
- making memory-curation skills always eligible through configurable routing without always loading their full prompt bodies
- searching prior session episodes as working-history recall without treating transcripts as approved durable memory
- attaching temporal fact metadata and provenance to staged/promoted memory while preserving review before durable promotion
- optionally layering semantic retrieval as a derived index alongside BM25 rather than replacing markdown ground truth; v0.11 ships the seam with a fake deterministic provider first, and v0.15 plans a broader SQLite-backed RAG substrate for operator docs, commands, settings, memory, and promoted ingestion records before growth-loop ingestion expands the corpus
- adapting over time to the user's preferences and personality

## Identity Direction

Allbert should have a small always-on bootstrap layer made of inspectable markdown files rather than a hidden hardcoded personality blob. That layer should cover who the assistant is, who it serves, and local working conventions, while staying distinct from both task skills and long-term memory. `SOUL.md` is the seeded operator-owned persona and boundary file. `PERSONALITY.md`, introduced in v0.11, is an optional reviewed learned overlay that can adapt collaboration style but cannot override `SOUL.md`, user/profile files, policy, or tool/security rules.

## Model Direction

For planning and reasoning, Allbert should support both strong hosted foundation models and local models. v0.10 makes the local-first default Ollama with `gemma4`, while Anthropic, OpenRouter, OpenAI, and Gemini remain first-class direct-provider options for operators who want hosted models. Provider choice stays a kernel-owned runtime configuration concern so cost logs, policy gates, daemon protocol, jobs, skills, and channel capability checks all see the same model posture.

Over time Allbert may also use smaller specialized models for memory shaping, personalization, or other narrow tasks, as long as those additions keep the runtime understandable and maintainable. v0.11 took the first review-first step toward the origin note's nightly-learning ambition with an opt-in deterministic personality digest and a `LearningJob` seam, but it did not train a model and did not rewrite `SOUL.md`. v0.13 is the shipped release that trains: a local LoRA/adapter job plugs into the same seam, consumes the same approved durable/fact plus bounded episode-summary corpus contract plus optional redacted v0.12.2 trace excerpts, treats `SOUL.md` as baseline persona/constraints, treats accepted `PERSONALITY.md` as reviewed learned adaptation input, and routes new adapters through review before activation. Activation is local-only, single-slot, and base-model-pinned (Ollama in v0.13; future local providers are additive); hosted providers ignore the active adapter rather than pretending to apply one. Full foundation-model retraining remains out of scope.

## Skill Direction

Skills should be the primary way Allbert gains new capabilities. The canonical shape follows the AgentSkills open standard: a folder with a `SKILL.md`, optional scripts, references, and assets, and a documented frontmatter schema. That lets Allbert read and share skills with the wider agent-assistant ecosystem. End users install and use skills; authoring happens either by hand (markdown plus declarative frontmatter — no code required) or through a natural-language scaffolding skill that Allbert itself provides. Installed skills live under `~/.allbert/skills/installed/`, while fetched content is quarantined under `~/.allbert/skills/incoming/` until explicit approval. Every skill install goes through preview and confirmation before activation; skill scripts run under the same exec policy as any other command. Progressive disclosure — surface a skill's name and description cheaply, load its body on activation, pull references only on demand — keeps skill discovery affordable even as the installed set grows.

## Channel Direction

Allbert should reach the user through more than one surface. The terminal starts as the primary surface, first as a classic REPL and then as a richer TUI that still attaches to the daemon-owned session model. Messaging channels (Telegram first, then others) follow; richer native or web surfaces come later. Every channel is an adapter over the kernel's session model, not a separate product. Channels declare their capabilities — inline confirm, async confirm, rich output, file attach, and multimodal flags for voice and image input/output — so the kernel can route confirm-trust and policy checks through paths each channel actually supports. v0.8 ships that posture concretely: a Telegram pilot with long-polling, identity-routed cross-surface continuity, a shared approval inbox that CLI/REPL/Telegram can all resolve, heartbeat-guided proactive nags, and provider-gated photo input that lands as session-scoped artifacts rather than durable memory. v0.11 makes the terminal surface more operator-legible with a TUI and kernel-owned session telemetry, while preserving the classic REPL fallback. v0.12.1 extends that posture with daemon-owned live activity, responsive in-flight TUI behavior, channel-native Telegram activity/status, and bounded approval context across review surfaces. Multimodal content passes through to providers that support it; channels without a given capability transcode or refuse gracefully. Channels without any confirmation capability fail closed on policy-sensitive actions, just as scheduled jobs already do. Hosted website-serving or broader web-hosting behaviour is explicitly outside the current roadmap; the near-term web story is richer channel and UI work, not turning the daemon into a site host.

## Self-Improvement Direction

End users do not write Rust, Python, or Lua to extend Allbert. When Allbert improves itself, it is Allbert doing the authoring under the user's explicit review. v0.12 ships the first layer: a Rust coding skill can read, modify, build, and test the Allbert codebase in a sibling worktree, producing diffs the operator reviews before install; a skill-authoring skill scaffolds new AgentSkills-format skills through natural-language conversation and lands the result in the same install quarantine as any external install; embedded scripting enters through a deliberate Lua `ScriptingEngine` seam, opt-in per exec policy and sandboxed by default. Skills and tool seams come first; embedded scripting is an advanced, optional surface, never a prerequisite for end-user workflows.

Self-improvement ships in progressive layers — code changes (v0.12), adapter training (v0.13), and self-diagnosis (v0.14) — and each flavor of self-change shares the same envelope: artifacts produced in isolation (sibling worktree, install quarantine, `~/.allbert/adapters/`, staging), routed through an approval surface (inbox kind or staging), gated by the monetary spend cap and by explicit compute caps where a release introduces local compute-bound work, observable through the existing hook surface, and reversible through a rollback trail. v0.12.2 session trace artifacts are diagnostic inputs to that envelope, not a self-change output path. No self-change flavor bypasses that envelope.

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

From there, the project grows along a sequenced path: agents and intent routing, then richer skills through AgentSkills adoption, then curated memory, then hardening around restart-durable sessions, cost caps, and operator-visible verification, then new channels, then continuity and sync across those channels, then a pinned contributor/development contract that makes the source tree reproducible on macOS, Linux, and Codex Web workspaces, then provider expansion with a local-first Ollama/Gemma4 default, then a richer TUI and adaptive-memory release with a review-first personality digest and a learning-job seam, then the shipped v0.12 self-improvement surfaces for source patches, skill authoring, and Lua scripting, then the shipped v0.12.1 operator-legibility point release for activity awareness, responsive TUI behavior, settings, and review workflow discovery, then the shipped v0.12.2 tracing/replay point release for persisted session spans and redacted trace inspection, then the shipped v0.13 local-personalization release for review-first adapter training, then the shipped v0.14 self-diagnosis plus curated Unix co-tenant posture, then the shipped v0.14.1 truth-repair point release, then the shipped v0.14.2 core/services split, and then the shipped v0.14.3 router reliability patch. That sequence — captured in [docs/plans/roadmap.md](plans/roadmap.md) — keeps each release useful on its own while unlocking the next.

Reality note as of 2026-04-27: v0.14.1 reconciled the v0.13/v0.14 drift around daemon adapter handlers, production trainer selection from configured backends, concrete self-diagnosis remediation candidates, local-default tool-call parsing, and doc-reality checks. v0.14.2 then shipped the separate core/services split, retired the monolithic kernel crate rather than preserving it as a compatibility facade, and kept kernel compactness enforceable through size, crate-graph, import-migration, and dependency compactness gates. v0.14.3 then replaced default brittle semantic routing with a schema-bound router, made conversational scheduling and explicit-memory capture deterministic without weakening confirmation/review gates, and repaired OpenAI Responses assistant-history serialization.

Even as that happens, Allbert should remain local-first, compact, and understandable. It should not turn into a broad distributed microservice platform just to gain background execution.

## Future Direction

Beyond the shipped v0.12 self-improvement, v0.12.1 operator-legibility, v0.12.2 tracing/replay, v0.13 personalization, and v0.14 self-diagnosis releases, the roadmap keeps full foundation-model retraining, hosted web surfaces, and distributed runtime ambitions out of scope until a separate design pass.

- **v0.12.2 — Tracing and replay.** A point release after v0.12.1 persists schema-versioned session-local spans at `sessions/<id>/trace.jsonl` plus rotated session archives, exposes redacted replay through CLI/TUI/Telegram surfaces, and adds file-based OTLP-JSON export for operators who already own an observability stack. It makes v0.14 self-diagnosis consume stable trace artifacts instead of inventing trace persistence later.
- **v0.13 — Local personalization.** Shipped `PersonalityAdapterJob`, which plugs into the v0.11 `LearningJob` seam and trains a small local LoRA adapter from approved durable memory, approved facts, bounded recent episode summaries labelled as working-history-derived input, `SOUL.md` baseline persona/constraints, accepted `PERSONALITY.md` learned adaptation input, and optional redacted v0.12.2 trace excerpts. Behind the job sits an owned `AdapterTrainer` trait with three implementations — Apple Silicon (mlx-lm-lora), cross-platform (llama.cpp), and a deterministic provider-free fake — modelled on the same owned-seam discipline ADR 0066 chose for inference. Every new adapter routes through an `adapter-approval` inbox kind that mirrors v0.12's patch review. Activation is local-only, single-slot, and base-model-pinned: only the Ollama provider activates an adapter in v0.13; hosted providers ignore the active-adapter pointer and surface a one-line per-session notice. A daily wall-clock compute cap (`learning.compute_cap_wall_seconds`) sits alongside the ADR 0051 spend cap so local training cannot pin the operator's machine. No training data leaves the machine. Adapter weights are derived/host-specific and excluded from profile export by default; the corpus inputs continue to travel so a peer machine can re-train its own equivalent adapter against the same digest. `PERSONALITY.md` remains the human-readable learned overlay; the adapter is a second, optional surface.
- **v0.14 — Self-diagnosis and Unix co-tenant.** Shipped `self-diagnose` reads Allbert's own v0.12.2 session traces through bounded diagnostic bundles, correlates failures with turn/tool/agent state, and writes markdown explanations before proposing any optional remediation. Code-shaped fixes route through `patch-approval`, skill-shaped fixes through install quarantine with `provenance: self-diagnosed`, and memory-shaped fixes through staging. The same release hardens Unix-style composition: a curated local-utilities surface and a structured, bounded `unix_pipe` tool shape let Allbert call small focused utilities (jq, ripgrep, fd, bat, pandoc, etc.) under the existing exec policy, without adopting a new scripting runtime or reintroducing shell-string execution.

Full foundation-model retraining, hosted web surfaces, and a broader distributed-service platform remain out of scope.

## Name

The name "Allbert" draws on the lexical hypothesis lineage associated with Gordon Allport and Henry S. Odbert, while also nodding playfully toward the idea of a capable personal assistant ala Batman's Albert.

## History

The rough original seed note for the project is preserved at [docs/notes/origin-2026-04-17.md](./notes/origin-2026-04-17.md).
