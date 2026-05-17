# JidoBacked Agent Pattern

Status: current as of v0.23.

This guide is the worked example for Allbert's pragmatic `Jido.Agent` rule.
Use it when converting an existing state machine to the shared
`AllbertAssist.JidoBacked` substrate or when adding a new internal
state-machine coordinator. Do not use it for plain storage wrappers.

## The Rule

Use `Jido.Agent` when the component has named transitions, lifecycle hooks,
private command routing, rebuildable state, or a plausible successor-agent
story. Use plain Elixir or `GenServer` when the component is storage IO or a
simple cache and an agent abstraction adds ceremony without a better future
shape.

v0.23 converted:

- `AllbertAssist.Confirmations.Store.Agent`
- `AllbertAssist.Jobs.Scheduler.Agent`

Both are supervised by `AllbertAssist.JidoBacked.Supervisor`.

## File Map

- `apps/allbert_assist/lib/allbert_assist/jido_backed.ex`
- `apps/allbert_assist/lib/allbert_assist/jido_backed/supervisor.ex`
- `apps/allbert_assist/lib/allbert_assist/confirmations/store.ex`
- `apps/allbert_assist/lib/allbert_assist/confirmations/store/agent.ex`
- `apps/allbert_assist/lib/allbert_assist/confirmations/store/commands.ex`
- `apps/allbert_assist/lib/allbert_assist/confirmations/store/persistence.ex`
- `apps/allbert_assist/lib/allbert_assist/jobs/scheduler.ex`
- `apps/allbert_assist/lib/allbert_assist/jobs/scheduler/agent.ex`
- `apps/allbert_assist/lib/allbert_assist/jobs/scheduler/commands.ex`
- `apps/allbert_assist/lib/allbert_assist/jobs/scheduler/executor.ex`

## Shape

Public modules stay as facades. For example,
`AllbertAssist.Confirmations.Store` keeps the old public API while delegating
lifecycle transitions to `AllbertAssist.Confirmations.Store.Agent`. Durable
YAML and audit markdown remain in Allbert Home through
`AllbertAssist.Confirmations.Store.Persistence`.

The agent declares private signal routes:

```elixir
use AllbertAssist.JidoBacked,
  name: "allbert_confirmations_store",
  description: "Coordinates durable confirmation store lifecycle transitions.",
  signal_routes: [
    {"allbert.confirmations.store.create",
     AllbertAssist.Confirmations.Store.Commands.Create},
    {"allbert.confirmations.store.read",
     AllbertAssist.Confirmations.Store.Commands.Read}
  ]
```

Private command modules use `Jido.Action`:

```elixir
defmodule AllbertAssist.Confirmations.Store.Commands.Create do
  use Jido.Action,
    name: "allbert_confirmations_store_create",
    description: "Private confirmation-store create command."

  def run(%{attrs: attrs, opts: opts}, _context) do
    AllbertAssist.Confirmations.Store.Commands.finish(
      :create,
      AllbertAssist.Confirmations.Store.Persistence.create(attrs, opts)
    )
  end
end
```

These command modules are not Allbert capability actions. They must not be
registered in `AllbertAssist.Actions.Registry`, must not appear in intent
candidates, and must not grant permissions.

## Rebuild Contract

Each JidoBacked agent implements:

```elixir
@callback rebuild_state(keyword()) :: {:ok, map()} | {:error, term()}
@callback command_modules() :: [module()]
```

`rebuild_state/1` reconstructs the in-memory projection from the durable
source of truth:

- Confirmations rebuild from `confirmations/pending/*.yml`.
- Jobs rebuild only runtime scheduler config/diagnostics; due work is read
  from SQLite on each tick.

In-memory state is never authoritative. Restarting the process must not lose a
pending confirmation, scheduled job, or run record.

`use AllbertAssist.JidoBacked` accepts optional `schema:` and optional
`signal_routes:` entries. A JidoBacked agent may be schema-only during early
construction, which is the expected v0.24 shape for `Objectives.Engine.Agent`
before its command routes are attached.

The macro intentionally passes the caller's `schema:` and `signal_routes:`
declarations through to `use Jido.Agent` instead of narrowing them to the
v0.23 empty-schema shape. Future objective agents can therefore use richer
state defaults, such as `%{}` maps, without receiving quoted AST data at
runtime.

## Supervisor Placement

`AllbertAssist.Application` starts `AllbertAssist.JidoBacked.Supervisor`
after the core Jido runtime and app/plugin registries and before session,
channel, and surface consumers. The JidoBacked supervisor owns converted core
coordinators. It is not a plugin contribution point in v0.23.

Later core milestones can append JidoBacked children with the supervisor's
`:extra_children` option without replacing the v0.23 confirmation and
scheduler agents. Use the full `:children` override only in focused tests.

The scheduler is started only through `JidoBacked.Supervisor`; do not also
start `AllbertAssist.Jobs.Scheduler` as a separate application child.

## Scheduling

`AllbertAssist.Jobs.Scheduler.Agent` uses
`Jido.Agent.Directive.schedule/2` for tick scheduling. Current Jido implements
that directive with `Process.send_after/3` inside `Jido.AgentServer`, which is
acceptable for the local scheduler because SQLite remains authoritative and
each tick re-reads durable due jobs.

## Debug Trace

`allbert.jido.debug_trace` is the shared diagnostic gate. It defaults to
`false`. New JidoBacked code must keep default operator traces unchanged and
may emit only bounded, redacted debug metadata when the setting is explicitly
enabled.

## Migration Checklist

- Keep the old public module as a facade.
- Move durable IO and parsing helpers into a pure helper module.
- Add an `.Agent` module using `AllbertAssist.JidoBacked`.
- Add private `.Commands.*` modules using `Jido.Action`.
- Rebuild projection from durable state on start.
- Preserve public result shapes exactly.
- Prove private command modules are absent from `Actions.Registry`.
- Wire the agent under `AllbertAssist.JidoBacked.Supervisor`.
- Add focused restart/rehydration tests.
- Document the substrate choice in `@moduledoc`.

## Pitfalls

- Do not treat agent state as durable truth.
- Do not expose private commands as registered capability actions.
- Do not add permissions or confirmations to the agent layer; authority stays
  at `Actions.Runner.run/3`, Security Central, and durable confirmations.
- Do not use undocumented Jido macros. As of v0.23, rely on documented
  `Jido.Agent`, `Jido.Action`, `Jido.AgentServer.call/3`,
  `on_before_cmd/2`, `on_after_cmd/3`, and
  `Jido.Agent.Directive.schedule/2`.
- Do not use the JidoBacked pattern for plain storage IO where a simple module
  or `GenServer` is clearer.
