# Research Specialist

Introduced in v0.46 (`research.specialist`); current as of v0.63.

The research specialist is a delegated objective agent contributed by
`./plugins/allbert.research/`. It is a read-only orchestration layer over the
v0.43 browser actions: it starts or receives an ephemeral browser session,
navigates to bounded sources, extracts text, builds an advisory summary, and
closes the browser session. It does not add browser authority, write memory, or
register a new public action.

## Enable

Use a disposable Allbert Home for validation:

```sh
export ALLBERT_HOME=/tmp/allbert-research
mix allbert.settings set browser.enabled true
mix allbert.settings set research.enabled true
```

Navigation still uses the v0.43 browser confirmation/grant boundary. A URL
without a remembered `browser_navigate` grant returns a pending confirmation
and leaves the objective blocked with that confirmation id.

## CLI

```sh
mix allbert.research "https://example.com/docs/a" --max-sources=1
mix allbert.research "release gate evidence" --max-sources=2
```

URL input dispatches the `summarize_url` command. Topic input dispatches the
`research` command and normalizes the topic into a bounded search URL for the
current deterministic fallback.

Expected successful output includes:

- `Allbert research research.specialist`
- `Command: summarize_url` or `Command: research`
- `Status: completed`
- `Summary: Research summary from ...`
- one `Source: ...` line per extracted source

If navigation needs confirmation, output includes `Status: needs_confirmation`
and `Confirmation: <id>`.

## Boundaries

- `research.specialist` is registered in `AllbertAssist.Objectives.AgentRegistry`
  with `allowed_commands: [:research, :summarize_url]`.
- Dispatch goes through the existing `delegate_agent` action and
  `Actions.Runner.run/3`.
- Browser navigation still confirms or uses a remembered v0.43 URL-prefix
  grant.
- Output is advisory and does not auto-promote to markdown memory.
- `research.max_sources` bounds source fan-out, with an implementation cap of
  eight.
- Browser sessions are closed after completed, failed, and pending research
  command paths.
- The opt-in real-browser smoke is:

```sh
mix allbert.test external-smoke -- browser_research_delegate
```

The deterministic release gate is:

```sh
mix allbert.test release.v063
```

## Out Of Scope

v0.46 does not add authenticated browsing, crawling, multi-tab research, office
document ingestion, automatic memory promotion, operator no-code agent
authoring, or remote/distributed delegate agents. Those remain parked in
`docs/plans/future-features.md`.
