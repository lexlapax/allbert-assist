# DEVELOPMENT.md

This is the development contract for Allbert. It is meant for humans and coding
agents working from a fresh checkout, including cloud-based agents that only
have the repository and its docs.

Allbert is an Elixir/OTP assistant runtime with Phoenix interfaces and Jido at
the agent/action layer. LiveView is an interface over the runtime, not the
architecture center.

## Reading Order

Before implementation work:

1. Read `AGENTS.md`.
2. Read `docs/plans/roadmap.md`.
3. Read the active milestone plan in `docs/plans/`.
4. Read the matching request-flow document, when one exists.
5. Read ADRs that constrain the task.
6. Use `CHANGELOG.md` for targeted shipped-history context when needed.
7. Inspect the relevant code before editing.

Use `docs/developer/agent-context-map.md` only when a task needs deeper
subsystem routing or released-version context. Do not bulk-read historical
plans or changelog entries.

Document authority order:

1. Current user request
2. Code and tests
3. Active milestone plan and request-flow document
4. ADRs
5. `docs/plans/roadmap.md`
6. `CHANGELOG.md` released-history notes
7. Historical plans

If these sources conflict, flag the conflict instead of silently following
stale guidance.

## Commit And Attribution Hygiene

- Commit messages should describe the human-intended change only.
- Never include AI-tool attribution in git commits, commit messages, PR text,
  release notes, changelog entries, or generated docs.
- Do not add Claude, Codex, Gemini, opencode, Cursor, Antigravity, Pi, or
  similar generated-by/co-authored-by footers.
- The project process is strict human supervision during planning,
  architecture, and development. Attribution belongs to the human project
  authors, not AI coding tools.

## Fresh Checkout

Install dependencies and set up child apps from the umbrella root:

```sh
mix setup
```

Run the full project gate:

```sh
mix precommit
```

Run static checks including Dialyzer:

```sh
MIX_ENV=test mix check
```

Start Phoenix:

```sh
mix phx.server
```

Open the current operator LiveView:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

Use the CLI runtime entrypoint:

```sh
mix allbert.ask "hello"
mix allbert.ask --trace "remember that I prefer concise milestone handoffs"
mix allbert.ask --trace "activate skill append-memory"
mix allbert.security status
mix allbert.confirmations list
mix allbert.skills validate apps/allbert_assist/priv/skills/append-memory
mix allbert.skills create demo-memory append_memory memory_write "Save a short memory helper" --root "$ALLBERT_HOME/skills"
```

## Useful Commands

Umbrella root:

```sh
mix setup
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
mix precommit
MIX_ENV=test mix check
```

Focused examples:

```sh
mix test apps/allbert_assist/test/allbert_assist/runtime_test.exs
mix test apps/allbert_assist/test/allbert_assist/memory_test.exs
mix test apps/allbert_assist/test/allbert_assist/skills/registry_test.exs
mix test apps/allbert_assist/test/mix/tasks/allbert_ask_test.exs
mix test apps/allbert_assist_web/test/allbert_assist_web/live/agent_live_test.exs
```

Docs-only verification:

```sh
git diff --check
```

## Repository Map

- `apps/allbert_assist/`: core OTP app, runtime, agents, actions, memory,
  security, settings, execution policy/specs, and Mix tasks.
- `apps/allbert_assist_web/`: Phoenix web app and LiveView operator surfaces.
- `config/`: Phoenix, repo, release, and bootstrap configuration.
- `docs/plans/`: roadmap and implementation-ready milestone plans.
- `docs/adr/`: architectural decisions.
- `docs/developer/`: developer-facing guides and lazy-loaded agent context.
- `docs/notes/`: origin notes and project context.
- `notebooks/`: exploratory Livebook material.

## Architecture Contract

The runtime boundary is:

```elixir
AllbertAssist.Runtime.submit_user_input/1
```

All user-facing interfaces should converge there or at a lower context/action
boundary. Do not duplicate runtime or agent logic in CLI tasks, LiveViews, or
future channel adapters.

Core rules:

- User input becomes observable signals.
- Jido agents decide, route, or delegate.
- Jido actions perform bounded work with schemas, explicit permissions, and
  structured results.
- Externally invoked, effectful, security-relevant, or observable domain
  operations enter through signals, internal agents or runtime routers, and
  registered Jido actions.
- Runtime-facing action invocation resolves through
  `AllbertAssist.Actions.Registry` and runs through
  `AllbertAssist.Actions.Runner.run/3`.
- Action lifecycle events use the shared Allbert signal vocabulary, especially
  `allbert.action.requested` and `allbert.action.completed`.
- Pure parsing, validation, schema, formatting, and storage helpers stay plain
  Elixir behind action boundaries.
- CLI tasks, LiveViews, jobs, and future channel adapters should call runtime,
  signal, agent, or action boundaries rather than owning domain semantics
  directly.
- Permission checks happen at the action boundary.
- Local command execution is Level 1 policy-bounded host execution in v0.08,
  not OS isolation. Shell execution must enter only through registered actions,
  Security Central, Settings Central execution policy, durable confirmation,
  and trace/audit records. Container or remote isolation requires future
  adapter work.
- Runtime turns should be traceable when tracing is enabled.
- Trace metadata should explain selected agent, selected skill, selected
  action, permission decision, settings source, memory effects, and
  diagnostics.
- Model output must be validated against known skills, known actions, known
  permissions, and known execution modes before it can affect behavior.

## Allbert Home

All durable local runtime data should live under one home directory.

Canonical env var:

```sh
ALLBERT_HOME
```

Accepted alias:

```sh
ALLBERT_HOME_DIR
```

Default:

```text
~/.allbert
```

Expected layout:

```text
<ALLBERT_HOME>/
  settings/
    settings.yml
    secrets.yml.enc
    .settings_key
    audit/YYYY-MM.md
  confirmations/
    pending/
    resolved/
    audit/YYYY-MM.md
  memory/
    notes/
    preferences/
    traces/
    skills/
  db/
    allbert.sqlite3
  skills/
  cache/
    skills/
  tmp/
```

Implementation rule:

- New subsystems should use `AllbertAssist.Paths`.
- Specific overrides such as `ALLBERT_MEMORY_ROOT`, `ALLBERT_SETTINGS_ROOT`,
  and `DATABASE_PATH` are for tests, migrations, compatibility, or operator
  escape hatches.
- Tests and CI must set a temporary `ALLBERT_HOME` or specific temporary roots.
  They must never write to a real user's `~/.allbert`.

## Settings Central

All user/operator-supplied configuration belongs in Settings Central.

This includes:

- operator profile
- provider profiles
- model profiles
- API keys and other user-supplied credentials
- channel preferences
- job defaults
- memory policy
- permission defaults
- skill trust and enablement
- future declarative agent definitions

Bootstrap values remain outside Settings Central:

- `ALLBERT_HOME` / `ALLBERT_HOME_DIR`
- settings-root escape hatches
- deployment infrastructure
- the secret-store master key
- Phoenix endpoint/repo/release config

Secrets rule:

- Store raw user-supplied secrets only in the encrypted secret store.
- Store only `secret://...` references in `settings.yml`.
- Redact secrets in CLI output, LiveView, traces, audits, logs, and tests.
- Add tests that prove raw API keys do not leak into inspectable surfaces.

## Agents, Jido, And Skills

Complex agents should be explicit Elixir modules using Jido.

Simple user-created agents should be declarative YAML specs interpreted by a
generic Allbert runner. Do not generate or load arbitrary Elixir modules from
user YAML.

Declarative agents should reference:

- Settings Central provider/model profiles
- known actions
- known skills
- limits
- memory policy
- permissions

Agent Skills should use the standard `SKILL.md` directory format. Allbert
metadata should be a namespaced overlay, not a forked skill format.

v0.03 skills are compatibility/importability context: parse, discover, trust,
list, read, activate, and trace standard Agent Skills without granting new
execution powers. Activation should go through a dedicated `activate_skill`
action so Allbert can enforce trust, wrap instructions, list resources, and
trace the selection.

v0.04 Runtime Convergence defines Boundary Actions for Allbert internals:
settings, skills, security, memory, trace, jobs, and channels should expose
runtime-facing behavior through signals, agents, and registered Jido actions
while keeping pure helper modules plain Elixir.

The shared runtime action boundary is
`AllbertAssist.Actions.Runner.run/3`. New runtime-facing capabilities should
be registered in `AllbertAssist.Actions.Registry`, emit lifecycle metadata
through the runner, and stay distinct from private Jido command modules used
inside state-machine agents. Private Jido command modules are not registered
Allbert capability actions and must not appear in intent candidates.

v0.05 Security Central defines shared security decisions, risk, redaction,
trust-boundary, and audit vocabulary without adding new execution powers.

v0.06 action-backed skills bind trusted metadata only to registered Elixir/Jido
actions and known permission classes through Security Central. Do not
auto-generate, compile, or load Elixir modules from arbitrary skill folders. If
a new side effect is needed, add or scaffold ordinary Elixir action code,
review it, test it, compile it, and register it before a skill can invoke it.

v0.07 confirmation workflow stores durable pending action requests under
Allbert Home and resolves them through registered Jido actions. Approval,
denial, listing, expiration, and any target resumption should go through
`Actions.Runner.run/3`; CLI and LiveView should not mutate confirmation files
directly or own permission policy. Approval re-checks Security Central and does
not grant denied or unimplemented capabilities. Confirmation records should
store origin actor/channel/session separately from resolver
actor/channel/session so CLI, LiveView, jobs, and future channels can share one
queue without losing interaction context.

Skill scripts, external package installs, shell execution, and external network
adapters remain inert until a milestone explicitly adds sandboxing,
permission, confirmation, and tracing.

## App Version Metadata

Every `AllbertAssist.App` implementation defines `version/0`. The
convention is **release-pinned, not semantic-per-app**: bump the
returned string to match the Allbert release that last meaningfully
changed the app's surface (signals, actions, surfaces, schemas,
behaviour). Do not bump the string for cosmetic changes or release
mechanics that didn't move the surface.

Why release-pinned and not semver-per-app:

- Reduces "is this number stale?" ambiguity. The number tracks the
  release that introduced the behaviour, so a v0.22 reader can
  immediately tell that an app version of `0.20.0` means the app
  surface hasn't moved since v0.20.
- Avoids per-app semver bookkeeping for apps that ship together. A
  semver-per-app convention would require a major-version policy
  per-app and an audit log per-app — neither of which we maintain.
- Keeps the version string consistent with the related `mix.exs`
  version when the app is the umbrella core (`AllbertAssist.App.CoreApp`
  → `apps/allbert_assist/mix.exs`).

Where this gets enforced:

- Reviewed at each milestone closeout: if a milestone changes an app's
  signals/actions/surfaces or persists a new schema for that app, bump
  the app's `version/0` to match the milestone's Allbert release.
- The v0.24 closeout bumped `AllbertAssist.App.CoreApp.version/0`
  from `"0.23.0"` to `"0.24.0"` because v0.24 added the objective
  runtime, canonical turn signal aliases, objective actions, and
  objective surfaces to the core runtime.
- The v0.24 closeout also bumped `StockSage.App.version/0` and
  `./plugins/stocksage/allbert_plugin.json` from `"0.22.0"` to
  `"0.24.0"` because v0.24 threads objective context through
  StockSage analysis rows and adds the deterministic StockSage
  proposer path.

## Component Substrate: Jido.Agent vs. GenServer

Allbert uses both `Jido.Agent` and plain `GenServer` for state-bearing
components. The choice is pragmatic and per-component, not uniform.

Reach for `Jido.Agent` when one or more is plausibly useful:

- A named state machine with declared transitions.
- Lifecycle hooks at meaningful points. As of the current Jido docs, the
  supported hooks to plan around are `on_before_cmd/2` and `on_after_cmd/3`;
  verify any additional callback against Context7 or source before coding.
- Skill composition (Jido.Skill attaching actions, signals, child specs).
- A plausible successor agent with better algorithms later. The "v2 with
  better algorithms" test: if you can imagine the module being rewritten
  with smarter logic that another team's agent could implement against
  the same command interface, Jido.Agent fits.

Use plain `GenServer` when the module is stateful storage and the
v2-with-better-algorithms test fails. Settings is a key-value store
with validation; Trace is an append-only writer; Memory storage IO is
markdown file IO; Session.Scratchpad is an ETS wrapper with TTL. None
of these have a meaningful "smarter algorithm" successor; agent
ceremony adds nothing.

As of v0.24:

- **Jido.Agent**: `IntentAgent`,
  `AllbertAssist.Confirmations.Store.Agent`,
  `AllbertAssist.Jobs.Scheduler.Agent`, and
  `AllbertAssist.Objectives.Engine.Agent`.
- **Plain GenServer**: `Settings`, `Trace`, `Memory` storage IO,
  `Session.Scratchpad`, `Memory.Compiler`, `Memory.Promotion`.

See `docs/developer/jido-agent-pattern.md` for the worked v0.23 conversion
example and the v0.24 schema/signal-route shape used by
`AllbertAssist.Objectives.Engine.Agent`.

Every new state-bearing module must include a `@moduledoc` paragraph
that states its substrate choice and one-sentence rationale, e.g.,
"`Jido.Agent` because it carries a status state machine with audit
hooks at every transition" or "`GenServer` because it's a key-value
cache and no useful successor with better algorithms exists."

Worked example:

```elixir
use AllbertAssist.JidoBacked,
  name: "allbert_confirmations_store",
  signal_routes: [
    {"allbert.confirmations.store.create",
     AllbertAssist.Confirmations.Store.Commands.Create}
  ]
```

Private command modules such as
`AllbertAssist.Confirmations.Store.Commands.Create` use `Jido.Action`
inside the state machine, but they are not Allbert capability actions and
must not be registered in `AllbertAssist.Actions.Registry`.

`allbert.jido.debug_trace` is the operator-controllable diagnostic switch for
bounded JidoBacked trace details. It defaults to `false`; do not add default
operator-visible trace output from a JidoBacked agent.

## Objective Runtime

v0.24 adds `AllbertAssist.Objectives` as the durable substrate for
multi-step, multi-turn work. ADR 0021 records the boundaries.

Three durable layers:

- **Intent** — per-turn; what the user appears to mean now;
  `AllbertAssist.Intent.Decision` is inert proposal data.
- **Objective** — cross-turn; what Allbert is trying to accomplish;
  `objectives`/`objective_steps`/`objective_events` SQLite tables.
- **Action** — per-step; the executable capability boundary at
  `Actions.Runner.run/3` + Security Central + confirmations.

Authority rules (carry into every consumer):

- `objective_id` is never permission. `step_id` is never permission.
  `active_app` on an objective is never permission.
- Advisory provider output (LLM proposers, world-model predictors,
  diffusion proposers, market allocators, probabilistic critics,
  agent-behavior simulators) is never authority. Predictions can rank,
  score, predict, summarize, critique; they cannot authorize, execute,
  or short-circuit confirmation.
- Predictions about user behavior never short-circuit confirmation. "The
  user usually says yes" is not equivalent to the user saying yes this
  time. This rule holds regardless of confidence or calibration.

The engine implements a seven-stage state machine: receive → interpret
intent → frame/resume objective → propose and evaluate steps →
authorize → execute → observe and advance. Cooperative cancellation
only; mid-action interruption is deferred to v0.25+.

Multi-step capabilities (intent that decomposes into multiple actions)
should be represented as objectives with multiple steps, not private
loops inside an app, channel, LiveView, or plugin. Apps and plugins
may propose objective steps through the registered objective actions;
they may not subscribe to raw signals and mutate objective state
privately.

Reserved vocabulary (named in ADR 0021; not implemented in v0.24):
capability inventory, capability gap, route, acquisition option,
advisory provider umbrella behaviour, world-model provider, diffusion
proposer, market allocator, probabilistic inference provider. Research
note at `docs/research/objective-runtime-research.md`.

## Elixir And OTP Rules

- Keep the code warning-free.
- Run `mix format` on changed Elixir files.
- Prefer small modules, explicit structs/maps, pattern matching, and pure
  functions where reasonable.
- Do not use `String.to_atom/1` on user input.
- Do not access lists with `list[index]`; use pattern matching, `Enum.at/2`, or
  `List` functions.
- Do not access struct fields through map access unless the struct implements
  Access. Use direct field access or APIs such as
  `Ecto.Changeset.get_field/2`.
- Predicate functions should end in `?`; reserve `is_*` names for guards.
- Use `start_supervised!/1` for supervised processes in tests.
- Avoid `Process.sleep/1` in tests. Prefer monitors, messages, or
  `:sys.get_state/1`.
- Use `Task.async_stream/3` with back-pressure for concurrent enumeration.

## Phoenix And LiveView Rules

Phoenix and LiveView are operator/channel interfaces over the same runtime and
settings core.

- LiveViews should call contexts/actions/runtime boundaries.
- Do not put agent logic, settings semantics, or permission policy in LiveViews.
- Begin LiveView templates with `<Layouts.app flash={@flash} ...>` and pass
  `current_scope` when the route/session requires it.
- Use `<.flash_group>` only from the layouts module.
- Use the existing `<.icon>` and `<.input>` components when available.
- Use `~H` or `.html.heex`; never use `~E`.
- Use `Phoenix.Component.to_form/2` and `<.form for={@form}>`; do not use
  `Phoenix.HTML.form_for` or `<.form let={f}>`.
- Add stable DOM IDs for key forms, buttons, lists, diagnostics, and streamed
  collections.
- Use LiveView streams for large or growing collections.
- Use `<.link navigate={...}>`, `<.link patch={...}>`, `push_navigate/2`, and
  `push_patch/2`; do not use deprecated `live_redirect` or `live_patch`.
- Do not write inline `<script>` tags in templates. Use colocated hooks or
  external hooks in `assets/js` when JavaScript is necessary.

## Data And Persistence

- Markdown memory is the inspectable source of truth for memories, traces,
  summaries, preferences, and user-owned narrative context until a plan changes
  that decision.
- YAML settings should be parsed with a real YAML parser and written
  deterministically. Do not hand-roll YAML with string concatenation.
- Local SQLite database files should derive from Allbert Home by default once
  `AllbertAssist.Paths` exists.
- Migrations should be generated with `mix ecto.gen.migration` when Ecto schema
  changes require them.

## Dependencies And Fresh Docs

Do not add dependencies casually. Prefer the standard library and existing
project dependencies.

Use Context7 MCP for current documentation whenever work depends on a library,
framework, SDK, API, CLI tool, cloud service, or provider. This includes
Elixir, Phoenix, LiveView, Ecto, Jido, Req, YAML libraries, Tailwind, and LLM
provider SDKs.

Context7 process:

1. Resolve the library ID.
2. Query docs with the real project question.
3. Use the fetched docs to guide implementation.
4. If Context7 is unavailable or insufficient, use official docs or source and
   note that fallback.

HTTP rule:

- Use `Req`.
- Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Milestone Workflow

For each milestone:

1. Read the milestone plan.
2. Read or create the request-flow doc.
3. Implement the smallest coherent slice.
4. Add focused automated tests.
5. Update the request-flow doc with actual modules, flows, commands, and
   operator-visible behavior.
6. Add or update ADRs when an implementation decision affects future work.
7. Run focused tests.
8. Run the code warning gate for code changes:
   `mix compile --warnings-as-errors`, `mix format --check-formatted`,
   `mix credo --strict`, `mix dialyzer`, and `mix precommit`.
9. Run `git diff --check` for docs-only changes.
10. Keep commits free of AI-tool attribution, generated-by footers, and
    co-author trailers.

Each milestone should include operator/user verification steps, not only unit
tests.

Do not commit, tag, or hand off an implementation milestone with known compiler
warnings, formatter drift, Credo findings, Dialyzer warnings, focused-test
failures, or precommit failures. If a gate cannot run because of environment
constraints, document the exact blocker and ask before deferring it.

## Current Safety Boundaries

- No autonomous shell execution.
- No external network calls unless a milestone explicitly adds the adapter and
  confirmation model.
- No approval bypass: confirmation approval records an operator decision and
  may resume only eligible registered actions after Security Central is
  re-checked.
- No arbitrary skill script execution.
- No arbitrary Elixir module loading from YAML or skill files.
- No raw secret display.
- No hidden subsystem-specific settings roots.
- No destructive changes to user-owned data without explicit user instruction.
