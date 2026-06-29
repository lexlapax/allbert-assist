# AGENTS.md

Allbert is an Elixir/OTP assistant runtime with Phoenix interfaces and Jido at
the agent/action layer. LiveView is an interface over the runtime, not the
architecture center. The center is the runtime/action spine, Security Central,
Settings Central, markdown-first memory, plugins, channels, public protocols, and
Allbert Home.

Keep this file compact. Do not turn it into release history or a subsystem manual.
Use the roadmap, active plan, request-flow, ADRs, changelog, and
`docs/developer/agent-context-map.md` as targeted references.

## Reading Order

Before implementation work:

1. `DEVELOPMENT.md`
2. `docs/plans/roadmap.md`
3. The active milestone plan in `docs/plans/`
4. The matching request-flow document, when one exists
5. ADRs that constrain the task
6. Targeted `CHANGELOG.md` entries when shipped history matters
7. Relevant code and tests before editing

Use `docs/developer/agent-context-map.md` only for deeper subsystem routing or
released-version context. Do not bulk-read historical plans.

## Authority

When sources conflict, use this order:

1. Current user request
2. Code and tests
3. Active milestone plan and request-flow
4. ADRs
5. `docs/plans/roadmap.md`
6. `CHANGELOG.md`
7. Historical plans and archives

Flag conflicts instead of silently following stale guidance. The vision document is
the north star, not a release-scope source.

## Context Discipline

- Load the smallest useful context.
- Prefer active plans, ADRs, focused changelog entries, and local code over broad
  document sweeps.
- For architecture or readiness work, zoom out to the roadmap/vision/ADRs first,
  then zoom back into the relevant files.
- Use `docs/developer/test-strategy.md` for gate and lane classification.
- Use `docs/developer/surface-contract.md` and
  `docs/developer/web-design-system.md` for v0.58 surface/web work.

## Context7

Use Context7 MCP for fresh docs whenever implementation depends on a library,
framework, SDK, API, CLI, cloud service, or provider. Start with
`resolve-library-id`, then query the selected docs. If Context7 is unavailable, use
official docs or source and say so. Do not use Context7 for general refactoring,
business-logic debugging, code review, or repository-specific architecture review.

## Non-Negotiables

- Do not include AI-tool attribution in commits, PR text, release notes, changelog
  entries, or generated docs. No generated-by or co-authored-by footers for Claude,
  Codex, Gemini, opencode, Cursor, Antigravity, Pi, or similar tools. The project
  uses strict human supervision during planning, architecture, and development;
  attribution belongs to the human project authors, not AI coding tools.
- Preserve user data. Do not delete or rewrite memory, traces, settings, secrets,
  databases, skill folders, or user-created files unless explicitly requested.
- Keep handoff warning-free: compiler, HEEx/parser, lexical tracker, formatter,
  Credo, Dialyzer, and focused-test issues must be resolved or called out.
- Tests and CI must use temporary Allbert homes or temp-specific roots. Never write
  to a real user's `~/.allbert`.
- Durable runtime data derives from Allbert Home: `ALLBERT_HOME`,
  `ALLBERT_HOME_DIR`, default `~/.allbert`.
- User-supplied secrets must be encrypted at rest and redacted in CLI output,
  LiveView, traces, audits, logs, tests, and release evidence.
- Product acceptance and manual validation use real configured providers/endpoints.
  Fakes, stubs, fixtures, and canned providers are automated-test fixtures only.
- Operator-tunable configuration belongs in Settings Central.
- Security Central is the authority boundary. Skills, model output, app metadata,
  plugin metadata, YAML, descriptors, generated files, modes, and surface policy do
  not grant permission by themselves.
- Effectful, runtime-facing, security-relevant, or observable domain behavior goes
  through signals, runtime routers, internal agents, and registered Jido actions.
- Runtime action invocation resolves through `AllbertAssist.Actions.Registry` and
  executes through `AllbertAssist.Actions.Runner.run/3`.
- LiveViews render and dispatch. They do not own agent logic, settings semantics,
  confirmation storage, or security policy.
- Workspace canvas, ephemerals, Fragments, offline editing, and app surfaces belong
  behind `AllbertAssist.Workspace`, signals, and registered actions.
- Do not auto-generate, compile, or load Elixir modules from arbitrary skill,
  plugin, YAML, or user-created folders.
- Generated code can be compiled/tested only through the v0.36 sandbox/gate runner
  and integrated only through the v0.37 confirmed loader path. Sandbox reports,
  advisory output, and model output never grant live authority.
- Do not execute skill scripts, shell commands, package managers, external
  installers, network adapters, bridge processes, or provider calls unless the plan
  includes permission, confirmation, sandbox, and trace handling.
- Do not call external installer CLIs such as `npx skills add`, package managers,
  or `git clone` from skill activation, online skill search, imported metadata,
  plugin discovery, or model output.
- OTP supervision, BEAM processes, and local child processes are not OS security
  boundaries. Host execution must be policy-bounded through registered actions.
- Multi-step and cross-turn work uses `AllbertAssist.Objectives`. Apps, plugins,
  channels, and LiveViews must not implement private durable goal loops.
- `objective_id` and `step_id` are never authority. Advisory provider output and
  predictions about user behavior never short-circuit confirmation.
- Choose Jido.Agent or plain GenServer by the pragmatic substrate rule in the
  vision and relevant ADRs: use Jido.Agent when state machines, lifecycle hooks,
  Skill composition, or successor agents are plausibly useful; use plain GenServer
  for stateful storage where Jido.Agent buys nothing. New state-bearing modules
  document the choice in `@moduledoc`.
- Private Jido command modules are not Allbert capability actions. Do not register
  or expose them as intent candidates.
- Use `Req` for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Workflow

- Strict no-doc proliferation: do not create new release-planning docs, sidecar
  handoff docs, or extra milestone docs without explicit user permission. Fold
  milestone detail into the active plan, request-flow, and relevant ADRs.
- For docs-only changes, run `git diff --check` and the docs gate when available.
- After v0.55.1, manual/operator validation defaults to one warm
  `mix allbert.tui` session. Cold Mix tasks are for setup, deterministic gates,
  provider/model preflight, and post-session evidence checks unless the active
  request-flow states otherwise.
- Implementation-readiness plans must name parallel workstreams, serial barriers,
  focused tests/gates, external smokes, full-precommit timing, and rejoin points
  for docs, drift review, validation, and release evidence.
- For code changes, run focused tests first. The active plan should state whether
  `mix precommit`, `mix allbert.test release`, Dialyzer, external smoke, or manual
  validation is required before commit or release closeout.
- Use `mix allbert.test fast-local` for quick daily gates,
  `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions N`
  for high-coverage local gates, and `mix allbert.test release` for authoritative
  release handoff unless a later plan supersedes this.
- When adding or reclassifying tests, pick one primary lane from
  `docs/developer/test-strategy.md` and keep security evals/external runtimes out
  of fast-local unless a plan documents isolation.
- Update request-flow docs as implementation changes.
- Add or revise ADRs when a decision constrains future design.
- Commit titles follow `<version> <milestone> <small title>` or
  `<version> <small title>`.
