# Allbert Roadmap

This roadmap is the running planning index for Allbert. The long-term vision is
captured in `docs/plans/allbert-jido-vision.md`; implementation-ready milestone
plans live alongside this file.

## Vision

Allbert is a personal assistant runtime that grows with its user. The core
direction is Elixir/OTP plus Jido: supervised processes, signal-driven
coordination, Jido agents for intent and delegation, Jido actions for validated
capabilities, and markdown-first memory that remains inspectable and portable.

Status: vision drafted.

## v0.01: First Local Assistant Loop

Plan: `docs/plans/v0.01-plan.md`

Status: planned.

Summary:

- Clean the formatter/precommit baseline.
- Introduce a signal-first runtime boundary.
- Add the first primary intent agent.
- Add explicit Jido actions and a permission gate.
- Add markdown memory v0.
- Record traces and basic cost/diagnostic metadata.
- Expose the same loop through CLI/REPL and Phoenix LiveView.

Exit signal: Allbert can remember something, recall recent memory, explain or
select a safe action, and leave an inspectable trace from both CLI and web UI.

## v0.02: Skill Registry

Status: placeholder.

Expected direction:

- Define a readable skill declaration format.
- Map skills to Jido actions and permission requirements.
- Let the intent agent list, inspect, and recommend skills.
- Keep autonomous skill creation out of scope until permissions and traces are
  mature.

## v0.03: Richer Memory And Retrieval

Status: placeholder.

Expected direction:

- Add memory summaries, pruning, and review workflows.
- Add compiled/indexed runtime views over markdown memory.
- Introduce embeddings or retrieval only after the markdown source of truth is
  stable.

## v0.04: Scheduled Jobs

Status: placeholder.

Expected direction:

- Add cron-like jobs that emit signals into the same runtime.
- Start with memory maintenance, daily summaries, and health checks.
- Keep scheduled jobs observable through traces.

## v0.05: Additional Channels

Status: placeholder.

Expected direction:

- Add channel adapters after CLI and LiveView share the same runtime core.
- Candidate channels include email, SMS, Discord/Telegram-style chat, browser
  capture, and native UI surfaces.
- Channels translate external messages to signals and render responses; they do
  not own agent logic.

## Future: Distillation And Self-Improvement

Status: research.

Expected direction:

- Explore small-model memory/personality distillation after memory and traces
  are trustworthy.
- Explore scripting or self-modification only after the action permission model
  is robust.
- Keep all self-improvement paths reviewable, reversible, and traceable.

