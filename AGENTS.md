# AGENTS.md

This repository is Allbert: an Elixir/OTP assistant runtime built with Phoenix
and Jido. Phoenix LiveView is one operator/channel interface, not the center of
the system. The center is a signal-driven runtime, Jido agents and actions,
Security Central, markdown-first memory, Settings Central, and Allbert Home.

## Start Here

Before coding, read:

1. `DEVELOPMENT.md`
2. `docs/plans/roadmap.md`
3. The active milestone plan in `docs/plans/`
4. The matching request-flow document, when one exists
5. Relevant ADRs in `docs/adr/`

For v0.03 skill substrate regression work, read
`docs/plans/v0.03-plan.md`, `docs/plans/v0.03-request-flow.md`, and
`docs/adr/0003-skill-manifests-as-capability-contracts.md`.

For v0.04 runtime convergence regression or boundary-adjacent work, read
`docs/plans/v0.04-plan.md`,
`docs/plans/v0.04-request-flow.md`,
`docs/adr/0001-signal-first-jido-runtime.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md` before changing
runtime-facing action, signal, agent, CLI, LiveView, settings, skills, memory,
trace, or future security boundaries.

For v0.05 Security Central work, read `docs/plans/v0.05-plan.md`,
`docs/plans/v0.05-request-flow.md`, and
`docs/adr/0006-security-central.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md` before changing
security evaluation, permission policy, redaction, risk, trust, or audit
behavior.

For v0.06 skill-backed execution work, read `docs/plans/v0.06-plan.md`,
`docs/plans/v0.06-request-flow.md`, `docs/plans/v0.03-plan.md`,
`docs/plans/v0.03-request-flow.md`,
`docs/adr/0003-skill-manifests-as-capability-contracts.md`, and
`docs/adr/0006-security-central.md`, and
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`.

For v0.07 confirmation workflow work, read `docs/plans/v0.07-plan.md`,
`docs/plans/v0.07-request-flow.md`,
`docs/adr/0001-signal-first-jido-runtime.md`,
`docs/adr/0006-security-central.md`,
`docs/adr/0007-jido-native-internal-runtime-boundaries.md`, and
`docs/adr/0008-durable-confirmation-requests.md` before changing
confirmation queues, approval/denial behavior, action resumption, traces,
audits, CLI, LiveView, or future execution boundaries.

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
- Runtime-facing, effectful, security-relevant, or observable domain behavior
  belongs behind signals, internal agents or runtime routers, and registered
  Jido actions. Pure parsing, validation, schema, formatting, and storage
  helpers may remain plain Elixir behind those boundaries.
- Runtime-facing action invocation should resolve through
  `AllbertAssist.Actions.Registry` and execute through
  `AllbertAssist.Actions.Runner.run/3` so lifecycle signals, runner metadata,
  permission decisions, redaction, and future Security Central behavior stay
  consistent.
- Security decisions and permission checks belong at the action boundary.
  Skills, model output, and YAML declarations never grant permission by
  themselves.
- v0.03 skills are compatibility/importability context only. v0.04 converges
  runtime boundaries without new execution powers. v0.05 adds Security Central
  but no new execution powers. v0.06 action-backed skills must call registered
  Elixir/Jido actions through the action runner and Security Central. v0.07
  adds durable confirmation requests and approval/denial workflow, but approval
  is not a generic capability grant and must not bypass Security Central safety
  floors. Confirmation records should preserve origin and resolver channel
  context rather than becoming CLI-only or LiveView-only prompts.
- Do not auto-generate, compile, or load Elixir modules from arbitrary skill
  folders.
- Do not execute skill scripts, shell commands, external installs, or network
  adapters unless a plan explicitly adds the permission, confirmation, sandbox,
  and trace story.
- Use `Req` for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Workflow

- For docs-only changes, run `git diff --check`.
- For code changes, run focused tests first, then finish with the milestone
  warning gate: `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix dialyzer`, and `mix precommit` unless the user explicitly scopes the
  work differently.
- Every implementation milestone must be warning-free before commit or handoff:
  no compiler warnings, no formatter drift, no Credo findings, no Dialyzer
  warnings, and no focused-test or precommit failures.
- Update request-flow docs as implementation changes.
- Add or update ADRs when an implementation decision constrains future design.
- Keep LiveViews thin: they call contexts/actions/runtime boundaries and do not
  own agent logic, settings semantics, or security policy.
