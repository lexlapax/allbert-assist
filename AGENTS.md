# AGENTS.md

This repository is Allbert: an Elixir/OTP assistant runtime built with Phoenix
and Jido. Phoenix LiveView is one operator/channel interface, not the center of
the system. The center is a signal-driven runtime, Jido agents and actions, a
permission gate, markdown-first memory, Settings Central, and Allbert Home.

## Start Here

Before coding, read:

1. `DEVELOPMENT.md`
2. `docs/plans/roadmap.md`
3. The active milestone plan in `docs/plans/`
4. The matching request-flow document, when one exists
5. Relevant ADRs in `docs/adr/`

For v0.02 work, the active implementation docs are
`docs/plans/v0.02-plan.md`, `docs/plans/v0.02-request-flow.md`,
`docs/adr/0004-domain-settings-engine.md`, and
`docs/adr/0005-canonical-allbert-home.md`.

## Non-Negotiables

- Preserve user data. Do not delete or rewrite memory, traces, settings,
  secrets, databases, skill folders, or user-created files unless explicitly
  asked.
- Keep code warning-free: no compiler warnings, no HEEx/parser warnings, no
  unused aliases/imports, and no lexical tracker warnings.
- Use Context7 MCP for fresh docs whenever implementation depends on a
  library, framework, SDK, API, CLI, cloud service, or provider. If Context7 is
  unavailable, use official docs or source and say so.
- All user/operator-supplied configuration belongs in Settings Central.
- All durable local runtime data should derive from Allbert Home:
  `ALLBERT_HOME`, alias `ALLBERT_HOME_DIR`, default `~/.allbert`.
- Tests and CI must use a temporary Allbert home or temp-specific roots; never
  write to a real user's `~/.allbert`.
- User-supplied secrets, including API keys, must be encrypted at rest and
  redacted in CLI output, LiveView, traces, audits, logs, and tests.
- Permission checks belong at the action boundary. Skills, model output, and
  YAML declarations never grant permission by themselves.
- Do not execute skill scripts, shell commands, external installs, or network
  adapters unless a plan explicitly adds the permission, confirmation, sandbox,
  and trace story.
- Use `Req` for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Workflow

- For docs-only changes, run `git diff --check`.
- For code changes, run focused tests first, then finish with `mix precommit`
  unless the user explicitly scopes the work differently.
- Update request-flow docs as implementation changes.
- Add or update ADRs when an implementation decision constrains future design.
- Keep LiveViews thin: they call contexts/actions/runtime boundaries and do not
  own agent logic, settings semantics, or permission policy.
