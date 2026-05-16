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
6. Inspect the relevant code before editing.

For v0.04 runtime convergence regression or boundary-adjacent work, start with:

- `docs/plans/v0.04-plan.md`
- `docs/plans/v0.04-request-flow.md`
- `docs/adr/0001-signal-first-jido-runtime.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`

For v0.05 Security Central regression or boundary work, start with:

- `docs/plans/v0.05-plan.md`
- `docs/plans/v0.05-request-flow.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`

For v0.06 skill-backed execution regression work, start with:

- `docs/plans/v0.06-plan.md`
- `docs/plans/v0.06-request-flow.md`
- `docs/plans/v0.03-plan.md`
- `docs/plans/v0.03-request-flow.md`
- `docs/adr/0003-skill-manifests-as-capability-contracts.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`

For v0.07 confirmation workflow regression work, start with:

- `docs/plans/v0.07-plan.md`
- `docs/plans/v0.07-request-flow.md`
- `docs/adr/0001-signal-first-jido-runtime.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`
- `docs/adr/0008-durable-confirmation-requests.md`

For v0.08 local execution sandbox regression work, start with:

- `docs/plans/v0.08-plan.md`
- `docs/plans/v0.08-request-flow.md`
- `docs/plans/v0.07-plan.md`
- `docs/plans/v0.07-request-flow.md`
- `docs/adr/0001-signal-first-jido-runtime.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`
- `docs/adr/0008-durable-confirmation-requests.md`
- `docs/adr/0009-local-execution-sandbox-levels.md`

For active v0.09 skill script runner work, start with:

- `docs/plans/v0.09-plan.md`
- `docs/plans/v0.09-request-flow.md`
- `docs/plans/v0.03-plan.md`
- `docs/plans/v0.03-request-flow.md`
- `docs/plans/v0.06-plan.md`
- `docs/plans/v0.06-request-flow.md`
- `docs/plans/v0.08-plan.md`
- `docs/plans/v0.08-request-flow.md`
- `docs/adr/0003-skill-manifests-as-capability-contracts.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0007-jido-native-internal-runtime-boundaries.md`
- `docs/adr/0008-durable-confirmation-requests.md`
- `docs/adr/0009-local-execution-sandbox-levels.md`
- `docs/adr/0010-resource-gated-skill-script-execution.md`

For active v0.10 external capability adapter work, start with:

- `docs/plans/v0.10-plan.md`
- `docs/plans/v0.10-request-flow.md`
- `docs/plans/v0.07-request-flow.md`
- `docs/plans/v0.08-request-flow.md`
- `docs/plans/v0.09-request-flow.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0008-durable-confirmation-requests.md`
- `docs/adr/0009-local-execution-sandbox-levels.md`
- `docs/adr/0010-resource-gated-skill-script-execution.md`
- `docs/adr/0011-confirmed-external-capability-adapters.md`
- `docs/adr/0012-resource-access-security-posture.md`
- `docs/adr/0013-uri-first-resource-identity.md`

For active v0.11 execution-aware intent, Approval Handoff, or remote network
content posture work, start with:

- `docs/plans/v0.11-plan.md`
- `docs/plans/v0.11-request-flow.md`
- `docs/plans/v0.10-plan.md`
- `docs/plans/v0.10-request-flow.md`
- `docs/plans/v0.07-request-flow.md`
- `docs/plans/v0.08-request-flow.md`
- `docs/plans/v0.09-request-flow.md`
- `docs/adr/0006-security-central.md`
- `docs/adr/0008-durable-confirmation-requests.md`
- `docs/adr/0009-local-execution-sandbox-levels.md`
- `docs/adr/0010-resource-gated-skill-script-execution.md`
- `docs/adr/0011-confirmed-external-capability-adapters.md`
- `docs/adr/0012-resource-access-security-posture.md`
- `docs/adr/0013-uri-first-resource-identity.md`

For v0.12 local workspace identity and conversation history work, start with:

- `docs/plans/v0.12-plan.md`
- `docs/plans/v0.12-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0014-local-workspace-identity.md`

For v0.13 scheduled jobs work, start with:

- `docs/plans/v0.13-plan.md`
- `docs/plans/v0.13-request-flow.md`
- `docs/plans/v0.11-request-flow.md`
- `docs/plans/v0.12-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0008-durable-confirmation-requests.md`
- `docs/adr/0012-resource-access-security-posture.md`
- `docs/adr/0014-local-workspace-identity.md`

For v0.14 session scratchpad work, start with:

- `docs/plans/v0.14-plan.md`
- `docs/plans/v0.14-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0014-local-workspace-identity.md`

For v0.15/v0.18 app contract and surface DSL regression work, start with:

- `docs/plans/v0.15-plan.md`
- `docs/plans/v0.15-request-flow.md`
- `docs/plans/v0.18-plan.md`
- `docs/plans/v0.18-request-flow.md`
- `docs/developer/how-to-create-an-allbert-app.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

For v0.19 cross-surface intent enrichment regression work, start with:

- `docs/plans/v0.19-plan.md`
- `docs/plans/v0.19-request-flow.md`
- `docs/plans/v0.11-plan.md`
- `docs/plans/v0.11-request-flow.md`
- `docs/plans/v0.18-plan.md`
- `docs/plans/v0.18-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0012-resource-access-security-posture.md`
- `docs/adr/0014-local-workspace-identity.md`
- `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`
- `docs/adr/0017-allbert-plugin-contract.md`
- `docs/adr/0019-cross-surface-intent-enrichment.md`

For v0.21 memory review and retrieval regression work, start with:

- `docs/plans/v0.21-plan.md`
- `docs/plans/v0.21-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0014-local-workspace-identity.md`
- `docs/adr/0019-cross-surface-intent-enrichment.md`

For v0.17 plugin contract work, start with:

- `docs/plans/v0.17-plan.md`
- `docs/plans/v0.17-request-flow.md`
- `docs/plans/allbert-jido-vision.md`
- `docs/adr/0017-allbert-plugin-contract.md`
- `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`
- `docs/adr/0016-channel-adapter-boundary-and-identity-mapping.md`

For StockSage workspace app milestones, start with the active milestone plan,
`docs/plans/allbert-jido-vision.md`, ADR 0006, ADR 0014, ADR 0015, ADR 0017,
and ADR 0018. For v0.20, also read `docs/plans/v0.20-request-flow.md`. The
canonical plans are `v0.20`, `v0.22`, `v0.23`, `v0.25`, `v0.27`, and `v0.28`.

For v0.29 generator work, encode only the shape already proven by v0.20
StockSage plugin/app, v0.25 StockSage SurfaceProvider LiveViews, v0.27 memory
namespace completion, and v0.28 canvas integration. The generator should not
invent new plugin/app contracts or bypass explicit compile-path review.

After v0.12 closeout, remember that local conversation history is SQLite-backed
`AllbertAssist.Conversations` data, not markdown memory and not hosted auth.
Runtime requests and responses carry canonical `user_id`, legacy
`operator_id`, `thread_id`, and optional `session_id`; new runtime-facing work
should preserve those fields in signals, traces, confirmations, and job/channel
metadata without adding accounts or roles.

For v0.13, scheduled jobs are a local supervised runtime channel, not a second
automation runtime. Job definitions and run records belong in SQLite, due work
enters through `AllbertAssist.Runtime.submit_user_input/1` or
`AllbertAssist.Actions.Runner.run/3`, and risky work must stop at the existing
confirmation/Approval Handoff boundary.

For v0.15, app registration is a supervised local contract, not authority.
`AllbertAssist.App.Registry` may expose app identity, actions, skill paths, and
navigation metadata, but permissions, confirmations, resource access, traces,
and execution still belong at the registered action/runtime boundary. Do not
load modules dynamically, create routes from app metadata, or treat `app_id` as
authorization.

For v0.16, additional channels are supervised delivery adapters around
`AllbertAssist.Runtime.submit_user_input/1` and registered confirmation
actions. Telegram and email are the proving adapters. External provider
identities must map to local string `user_id` values through Settings Central;
there is no implicit `"local"` fallback and no hosted accounts model. Channel
events belong in SQLite for dedupe and traceability, while conversation history
remains `AllbertAssist.Conversations` data. Channel transports may receive
updates and send responses through bounded provider clients only; they must not
fetch arbitrary URLs, download media/documents, import skills, execute provider
methods, mutate confirmations privately, or bypass Resource Access Security
Posture.

For v0.17, plugins are the local package/discovery layer for extension
contributions. Plugins may contribute apps, channels, actions, skills, settings
schema entries, and supervised children, but registration is not authority.
Channel descriptors live in `AllbertAssist.Plugin.Registry`; do not add a
parallel channel registry in v0.17. Plugin-owned child specs run under the
plugin child supervisor, while channel adapters remain under
`AllbertAssist.Channels.Supervisor`.
Do not load arbitrary code from `<ALLBERT_HOME>/plugins`, execute package
managers during discovery, auto-trust plugin skills, grant action permissions,
or bypass confirmations from plugin metadata. Do not automatically compile
arbitrary `./plugins/*/lib` folders. Telegram and email move into
`./plugins/allbert.telegram` and `./plugins/allbert.email` as shipped
source-tree channel plugins while preserving the v0.16 channel boundary.

For v0.20, StockSage is the first shipped source-tree plugin app. It uses
`./plugins/stocksage`, the existing `AllbertAssist.Repo`, and
`stocksage_*` SQLite tables. Do not add `apps/stocksage`, `apps/stocksage_web`,
`StockSage.Repo`, run Python, call market-data APIs, mount StockSage routes,
or auto-promote StockSage memory records to markdown memory in this slice.
Read-by-id paths must require `user_id`; `:stocksage_write` is only a local
domain write permission and must not authorize financial API calls or analysis
execution.

After v0.11 closeout, remember that URL summarization, document inspection,
direct skill URL import, local skill directory import, local path access,
trusted skill script execution, package installs, online source consumers,
future MCP resources, and future agent endpoints are all URI-backed resource
access operation classes. v0.11 implements execution-aware decisions, Approval
Handoff, URL/document fetch approvals over the v0.10 Req substrate, and explicit
unavailable states for missing summarizers, extractors, and generic local file
readers. Channels and summarizers do not fetch, read, import, or execute
directly; they render or consume Approval Handoff data and registered action
results.

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
through the runner, and expose internal actions separately from the
intent-agent tool surface when needed.

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
