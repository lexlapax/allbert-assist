# Delegate Agents

Delegate agents are local plugin-owned Jido agents that the Objective
Runtime can call through the registered `delegate_agent` action. They are
composition points, not authority surfaces: a delegate agent may orchestrate
registered Allbert actions, but every effectful hop still goes through
`AllbertAssist.Actions.Runner.run/3`, Security Central, confirmations, and
Resource Access.

## Contract

A plugin-owned delegate agent registers with
`AllbertAssist.Objectives.AgentRegistry.register/4`:

```elixir
AgentRegistry.register(
  "example.specialist",
  Example.Specialist.Agent,
  Example.Specialist.Agent,
  %{allowed_commands: [:execute, :research]}
)
```

The registry entry contains:

- `id` - stable local delegate id, such as `research.specialist`.
- `server` - a running local Jido agent server.
- `module` - the agent module.
- `metadata` - contract metadata. v0.46 uses `allowed_commands`.

Callers do not call the agent server directly. Objective execution crosses
the action boundary:

```elixir
Actions.Runner.run(
  "delegate_agent",
  %{
    user_id: user_id,
    objective_id: objective_id,
    step_id: step_id,
    delegate_agent_id: "example.specialist",
    command: "research",
    params: %{topic: "delegation"}
  },
  context
)
```

The `delegate_agent` action resolves the registry entry, validates the
command against `:execute` plus the entry's `allowed_commands` metadata,
normalizes string or atom commands without dynamic atom creation, and then
dispatches through `AgentRegistry.dispatch/4`.

## Objective Step Shape

Workflow YAML and Plan/Build delegate steps use the v0.44 nested action
parameter shape:

```elixir
%{
  kind: "delegate_agent",
  delegate_agent_id: "research.specialist",
  action_params: %{
    command: "research",
    params: %{topic: "Allbert"}
  }
}
```

`Objectives.Commands.ExecuteStep` reads `action_params.command` with a
default of `"execute"` and forwards `action_params.params` as the action
params. Older direct delegate-step creators stored params directly in
`action_params`; those continue to default to `execute` and pass the whole
map as params so existing StockSage/debug paths do not need a Step-schema
migration.

## Advisory Output

Delegate output is advisory unless the called registered action has already
performed a confirmed authoritative effect. Delegate agents return normalized
response/report packets with summaries and evidence references. A delegate
result never grants permission, never confirms a browser navigation, never
promotes memory, and never changes Settings Central by itself.

## Plugin Example

The v0.46 `allbert.research` plugin contributes `research.*` Settings
Central schema and starts a supervised `research.specialist` agent that
registers:

```elixir
%{allowed_commands: [:research, :summarize_url]}
```

The agent may implement internal Jido command modules for those command
signals, but those command modules are private to the agent. Do not register
private delegate command modules in `AllbertAssist.Actions.Registry`.

## Security Rules

- Delegation does not widen authority.
- Plugin metadata and YAML never grant permissions.
- Unknown commands return `:invalid_delegate_command`.
- Command normalization must not use `String.to_atom/1`.
- Delegate agents are local plugin processes; remote/distributed agents are
  future work.
- Operator-authored no-code delegate agents remain parked behind the
  supervised dynamic-capability path.
