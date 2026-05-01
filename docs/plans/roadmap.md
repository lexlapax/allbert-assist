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
Request flow: `docs/plans/v0.01-request-flow.md`

Status: in progress. Milestones 1 and 2 are complete and tested; Milestone 3
is complete, tested, and operator-verified; Milestone 4 is complete, tested,
and operator-verified; Milestone 5 is complete and tested. Milestone 5.1 is
complete and tested. Milestone 6 is complete and tested.

Summary:

- Clean the formatter/precommit baseline. Complete.
- Introduce a signal-first runtime boundary. Complete.
- Add the first primary intent agent. Complete.
- Add explicit Jido actions and a permission gate. Complete.
- Add markdown memory v0. Complete.
- Add deterministic personal preference heuristics. Complete.
- Record traces and basic cost/diagnostic metadata. Complete.
- Expose the same loop through CLI/REPL and Phoenix LiveView.

Current operator loop:

- `AllbertAssist.Runtime.submit_user_input/1` accepts local user input and
  emits `allbert.input.received` / `allbert.agent.responded` log signals.
- The default runtime path uses `AllbertAssist.Agents.IntentAgent` with a
  deterministic v0.01 action surface for direct answers, memory intent
  selection, skill inspection, and inert shell-command planning.
- `AllbertAssist.Security.PermissionGate` records explicit permission decisions
  for read-only work, memory-write intent, command planning, blocked command
  execution, and external network confirmation.
- `AllbertAssist.Memory` stores explicit memories as user-readable markdown
  under `ALLBERT_MEMORY_ROOT` or `var/allbert/memory`, and recall prompts read
  the same markdown source of truth.
- Basic identity and preference statements, such as "my name is Sandeep" and
  "I prefer short updates", flow through the same markdown memory path with
  conservative heuristics.
- When tracing is enabled, runtime turns write inspectable markdown traces under
  the memory `traces` category and return the trace path in `response.trace_id`.
- The `/agent` LiveView uses the same runtime boundary and displays the
  response, status, signal id, and trace path when available.

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
