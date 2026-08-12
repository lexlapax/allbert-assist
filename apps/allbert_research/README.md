# allbert.research — Research Delegate Agent

The supervised `research.specialist` delegate agent.

## What it is

A shipped source-tree plugin of `kind: "delegate_agent"`, entered through
`AllbertResearch.Plugin`, contributing `AllbertResearch.App` and the research
Settings Central schema fragment.

## Why it exists, and what it deliberately is not

**It registers no new actions and grants no browser authority.** Its commands
orchestrate *existing* actions through `AllbertAssist.Actions.Runner.run/3`, so
every permission check, confirmation, and audit row that governs those actions
still applies unchanged.

That restraint is the design. A delegate agent is a planner over an existing
authority surface, not a second way to reach the network. If research could
navigate directly, the browser plugin's consent gate would be bypassable by
delegation.

## Contents

- `plugin.ex`, `app.ex` — entrypoint and contributed app.
- `agent.ex`, `runtime.ex`, `supervisor.ex` — the supervised delegate agent.
- `commands/research.ex`, `commands/summarize_url.ex` — the agent's commands.
- `delegate_objective.ex` — objective-side delegation.
- `settings/fragment.ex` — the settings schema fragment.
- `mix/tasks/allbert.research.ex` — operator task.

## How it is loaded

Not a separate Mix project. Its `lib` is injected into `apps/allbert_assist`
through `elixirc_paths/1`; `allbert_plugin.json` is discovery metadata only.
