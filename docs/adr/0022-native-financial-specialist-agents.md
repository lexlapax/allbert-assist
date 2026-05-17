# ADR 0022: Native Financial Specialist Agents

## Status

Proposed.

## Context

v0.22 added the StockSage Python bridge so Allbert could produce real
financial-analysis results through the existing TradingAgents baseline. v0.24
added durable objectives, objective steps/events, a monitored
`AllbertAssist.Objectives.AgentRegistry`, and a minimal `:delegate_agent` step
kind. v0.25 is the first milestone that should consume that substrate with
real app-contributed specialist agents.

The original shorthand, "native Jido trading agents," is too easy to interpret
as a one-for-one Python graph translation or as a trading/autonomous execution
system. Allbert's architecture needs something narrower and more reusable:
supervised, bounded financial specialist agents that can be called through the
shared objective runtime and that remain advisory until a registered action
persists or executes anything.

The Python bridge file (`plugins/stocksage/priv/python/bridge.py`) defines the
JSON bridge and the final-state fields persisted by StockSage. It does not
contain the role prompts. v0.25 must therefore inventory the pinned
TradingAgents package/source for prompt material, adapt only license-compatible
instructions, and keep any native prompts operator-readable and versioned.

## Decision

v0.25 implements native financial specialist agents, not a textual clone of the
Python TradingAgents graph.

The agents are plugin-owned and live under `./plugins/stocksage`. They start
under `StockSage.Supervisor` through `StockSage.Plugin.child_spec/1`. They
register stable ids in `AllbertAssist.Objectives.AgentRegistry` and are called
through the v0.24 delegate-agent path. StockSage is the first consumer, but the
agents are not StockSage-private internals; other Allbert runtime paths may
call them later through registered objective/action boundaries.

The required initial agent ids are:

- `stocksage.market_context`
- `stocksage.news_sentiment`
- `stocksage.fundamentals`
- `stocksage.bull_thesis`
- `stocksage.bear_thesis`
- `stocksage.decision_synthesizer`
- `stocksage.quality_gate`

Each agent accepts a bounded request packet containing `user_id`, `ticker`,
`analysis_date`, optional `objective_id`/`step_id`/`trace_id`, role/task,
evidence, constraints, and `prompt_version`. Each agent returns a bounded
advisory report packet containing status, summary, report, evidence
references, confidence, warnings, data requests, and generation metadata.

Agents may reason, summarize, critique, compare, and request more evidence.
They may not:

- grant permission;
- create confirmations directly;
- execute trades or contact brokers;
- write StockSage tables directly;
- fetch market data directly;
- bypass `Actions.Runner.run/3`;
- bypass Security Central or Resource Access Security Posture;
- maintain a private durable task graph outside objectives and StockSage
  domain tables.

External evidence access is action-backed. v0.25 adds or reuses registered
actions for market data, news/sentiment, and fundamentals evidence. Those
actions carry Resource Access Security Posture metadata, support fixture mode,
emit bounded signals/trace metadata, and run through
`AllbertAssist.Actions.Runner.run/3`.

`StockSage.Actions.RunAnalysis` remains the single analysis execution boundary.
It accepts native analysis as the default path and accepts Python only when the
operator explicitly requests a comparison/reference run. Both paths preserve
the `:stocksage_analyze` permission and confirmation path and persist results
to the existing `stocksage_analyses` / `stocksage_analysis_details` tables.
Native results use `engine: "native"` and preserve the v0.22 final-state field
names where useful so existing list/show flows and later LiveViews can render
both engines.

The Python bridge is not a fallback. Allbert must not automatically retry or
recover a native failure by running Python. Python bridge execution is retained
for similarity checks, regression fixtures, and explicitly requested reference
runs. There is no persistent setting that makes Python the default operational
engine.

Every Python comparison run must be labeled as such in CLI output,
confirmation text, trace metadata, and persisted detail JSON so operators can
distinguish baseline/reference output from native operational output.

## Prompt Contract

v0.25 begins with a prompt inventory:

- Confirm that `plugins/stocksage/priv/python/bridge.py` contains bridge
  protocol and result-field structure, not role prompts.
- Inspect the pinned TradingAgents package/source used by v0.22 for role
  prompts and debate instructions.
- Store license-compatible prompt templates, or prompt-source notes plus
  Allbert-authored equivalents, under
  `plugins/stocksage/priv/prompts/native_agents/`.
- Version prompts with `prompt_version` and include that version in agent
  reports and persisted detail JSON.

Prompts are operator-readable instructions, not authority. They must not ask
agents to execute trades, contact brokers, or provide personalized financial
advice. They must require evidence references and uncertainty/warnings when
data is incomplete.

## Consequences

- v0.25 proves the v0.24 delegate-agent substrate with real supervised agents.
- Future apps can call the same financial specialists through shared objective
  and action boundaries instead of importing StockSage internals.
- The StockSage native path can improve beyond the Python baseline without
  being constrained to every Python role/class boundary.
- Market-data access becomes more inspectable than the v0.22 Python bridge
  because native evidence is action-backed and Resource Access aware.
- The Python bridge remains useful for comparison, similarity scoring, and
  regression fixtures, but not for automatic fallback.

## Rejected Alternatives

### One-for-one Python graph clone

Rejected. It would preserve accidental implementation structure instead of
Allbert's Jido/OTP architecture. Native agent boundaries should be split when
there is a reusable output, operator UX, or test reason to split them.

### StockSage-private agent graph

Rejected. It would duplicate the objective runtime and make the first real
delegate agents unavailable to the wider Allbert runtime.

### Direct market-data calls from agents

Rejected. It would bypass Security Central, Resource Access Security Posture,
traces, and fixture-mode testing.

### Automatic Python fallback

Rejected. A native failure should be visible and debuggable. Python can be run
only when the operator explicitly asks for a comparison/reference run.

### Python as a persistent default

Rejected. v0.25's operational engine is native. Python remains a comparison
tool, not the default runtime path.
