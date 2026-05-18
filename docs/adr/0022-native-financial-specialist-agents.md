# ADR 0022: Native Financial Specialist Agents

## Status

Accepted with v0.25 Native Financial Specialist Agents M6 closeout on
2026-05-17. Amendments below enumerate the binding implementation
shape that shipped: 10 plugin-owned specialist agents, the
`StockSage.Agents.NativeCoordinator` JidoBacked orchestrator,
Settings-bounded multi-round debate with durable objective-step
observability, explicit Python comparison/parity, and the core
`mix allbert.delegate` proof.

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

The required initial agent ids (per v0.25 Amendment A1; the original
7-agent topology was revised to 10 to preserve Python's risk-debate
quality):

- `stocksage.market_context`
- `stocksage.news_sentiment`
- `stocksage.fundamentals`
- `stocksage.bull_thesis` (multi-round capable per Amendment A2)
- `stocksage.bear_thesis` (multi-round capable per Amendment A2)
- `stocksage.risk_aggressive` (multi-round capable; added per A1)
- `stocksage.risk_conservative` (multi-round capable; added per A1)
- `stocksage.risk_neutral` (multi-round capable; added per A1)
- `stocksage.decision_synthesizer`
- `stocksage.quality_gate`

Plus one supervised JidoBacked orchestrator (not registered in
AgentRegistry; per A3): `StockSage.Agents.NativeCoordinator`.

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

## v0.25 Amendments (2026-05-17 third validation pass)

The third validation pass on v0.25 plan/flow surfaced plan-level
decisions that need to live in this ADR so future readers do not have
to reconstruct them from plan history. Each amendment extends (does
not contradict) the Decision section above.

### A1. 10-agent topology (3 risk debaters added)

The original 7-agent topology omitted Python's 3 risk debaters
(`aggressive_debator`, `conservative_debator`, `neutral_debator`).
v0.25 retains them as 3 distinct specialist agents:
`stocksage.risk_aggressive`, `stocksage.risk_conservative`,
`stocksage.risk_neutral`. These materially shape Python's
final-decision quality and represent distinct reasoning perspectives;
they default to the `:slow` (deep-think) model profile per Python's
`max_risk_discuss_rounds` model assignment.

Rationale: collapsing the 3 risk perspectives into a single agent
would lose the adversarial-quality property of separate per-stance
LLM calls. Keeping them distinct also matches the Python rating-scale
parity metric's "5-point" granularity (see A6).

### A2. Multi-round debate with objective-step observability

Bull/bear and risk debaters support multiple debate rounds bounded by
two settings: `stocksage.native_max_debate_rounds` (default 2 for
bull/bear cycles) and `stocksage.native_max_risk_rounds` (default 1
for risk-debate cycles). Each round = one `objective_steps` row of
`kind: :delegate_agent` with the round's `round_index` in the request
packet and prior rounds' reports in `prior_reports`.

The coordinator owns the StockSage-specific internal graph loop. It is
the only module that decides the fixed M5 stage order for market/news/
fundamentals, bull/bear rounds, risk rounds, synthesis, and quality
gate. The generic v0.24 Objective Engine remains the lifecycle and
inspection substrate rather than a StockSage-specific graph scheduler.

The graph may run independent advisory calls in parallel, but only at
bounded stage barriers. v0.25 runs the initial analyst trio in
parallel, keeps bull/bear sequential so each stance can respond to the
prior report, and runs the three risk perspectives in parallel per
risk round. Each specialist dispatch is bounded by
`stocksage.native_agent_timeout_ms` (default 90 seconds); timeout marks
that delegate step failed and lets the coordinator continue with a
warning rather than hanging the objective.

Rationale: specialist debate turns are plugin-owned internal advisory
turns, not operator-callable top-level action proposals. Keeping the
round loop inside the coordinator avoids asking the generic Objective
Engine to know StockSage's graph grammar while still recording every
turn as a durable, inspectable `objective_step` row that operators can
trace via `mix allbert.objectives show`.

### A3. `StockSage.Agents.NativeCoordinator` JidoBacked orchestrator

v0.25 introduces a JidoBacked agent at
`StockSage.Agents.NativeCoordinator` that owns:

- Per-analysis projection state (`current_analyses` map keyed by
  `objective_id`).
- Multi-round debate dispatch order.
- Parity-run composition (`--engine both` orchestrates native + Python
  concurrently).

The coordinator is **NOT** registered in
`AllbertAssist.Objectives.AgentRegistry`. It is a supervised process
under `StockSage.Supervisor`, called from
`StockSage.Actions.RunAnalysis` (registered action). It dispatches
each specialist agent via the v0.24 `DelegateAgent` registered action
through `Actions.Runner.run/3` — the registry boundary stays intact.

The coordinator's projection state is a cache. SQLite objective/step
rows and StockSage domain rows remain authoritative for operator
inspection and persistence; coordinator restarts do not become a
separate durable task graph.

### A4. 5 tiered evidence actions

External market-data access flows through 5 registered Allbert
actions under `StockSage.Actions.Evidence.*`:

- `FetchMarketData` (price + indicators)
- `FetchNews` (news + global news)
- `FetchSentiment` (StockTwits + Reddit)
- `FetchFundamentals` (basic fundamentals)
- `FetchFinancials` (balance sheet + cashflow + income statement)

Each action carries Resource Access Security Posture metadata and is
gated by a new `:stocksage_evidence_fetch` permission class (default
`:allow` inside an approved analysis context, floor
`:resource_access_required`).

Specialist agents declare their `tools:` list per role per the
restricted-tool-scope guidance in `project-direction-rethink-01.md`
L390-L392. No agent has tool access to all 5 evidence actions — each
is restricted to the actions relevant to its role.

The tiered granularity (5 actions vs Python's ~10 tools) is a
deliberate middle ground: finer than 3 broad actions
(better Resource Access auditability), coarser than 1 action per
tool (avoids settings/code sprawl in v0.25).

### A5. Request-scoped Python reference and `--engine both` parity execution

Engine selection is request-scoped, not Settings Central defaulted.
Absent an explicit engine parameter, `RunAnalysis` uses the native
engine. `--engine python` and `--engine both` are available only when
the operator explicitly requests them and `stocksage.python_comparison_enabled`
allows Python comparison. The legacy `"tradingagents"` value remains
only as a persisted-row / old-caller alias for `"python"`.

v0.25 must not extend `stocksage.analysis_engine` into a persistent
default selector for `"python"` or `"both"`. If the v0.22 compatibility
key remains in schema, `RunAnalysis` must not read it to choose the
engine.

When `engine = "both"`, the coordinator runs native and Python
concurrently with bounded `Task.async/1` fan-out and the same
`stocksage.bridge_timeout_ms` timeout posture.
Results merge into ONE `stocksage_analyses` row with both engines'
final-state fields populated under namespaced JSON keys in the
details row (`native_report`, `python_report`, `parity_diff`).

Rationale for parallel-over-sequential: avoids ~2x wall-clock cost;
matches operator expectation that `--engine both` is a parity
comparison, not a serial confirmation chain.

### A6. Parity metric (5-point rating + bounded confidence delta)

When `engine = "both"`, the coordinator computes a deterministic
parity diff:

- **Primary**: 5-point rating-scale agreement scoring on the
  Buy/Overweight/Hold/Underweight/Sell scale. Exact match = 1.0,
  adjacent = 0.5, distant = 0.0.
- **Secondary**: bounded confidence delta
  (`|native_confidence - python_confidence|`).
- **`parity_pass`**: `rating_agreement >= 0.5 AND confidence_delta <
  stocksage.native_parity_variance` (default 0.25).

The diff is persisted in `stocksage_analyses.parity_diff` JSON
column (new in v0.25) and surfaced via `mix stocksage.analyses show`,
the future v0.26 workspace shell, and v0.27 StockSage LiveViews.

Rationale: rating-scale agreement is the operator-meaningful primary
signal; confidence delta is a quantitative secondary check. Token
similarity / Jaccard over `final_trade_decision` text was rejected as
brittle against paraphrase differences (rejected alternative below).

### A7. `mix allbert.delegate` cross-app reuse proof

v0.25 ships a new Mix task `mix allbert.delegate <agent_id>
[--user USER] [--command COMMAND] [JSON_PARAMS]` in Allbert core
(NOT StockSage). The task creates a transient debug objective,
dispatches via the v0.24 `DelegateAgent` registered action through
`Actions.Runner.run/3`, prints the agent's report packet, and marks
the debug objective `:completed`/`:failed`.

This proves operationally that **any registered specialist agent is
callable from outside StockSage**. Future Allbert apps
(e.g., v0.26 workspace shell, future research-assistant) can call
`stocksage.fundamentals` through the same registry+action path
without coupling to StockSage modules.

StockSage-specific smoke tasks may add ticker/date/evidence defaults,
but they must still dispatch through `Actions.Runner.run("delegate_agent", ...)`
or an equivalent registered-action boundary. Operator-facing smoke
must not call specialist modules, PIDs, or `execute/1` directly.

### A8. Hybrid prompt provenance with per-prompt license audit

The Prompt Contract above specifies "license-compatible prompt
templates, or prompt-source notes plus Allbert-authored equivalents."
v0.25 makes this concrete:

- M1 task: per-prompt license audit against TradingAgents v0.2.5
  (`https://github.com/TauricResearch/TradingAgents@v0.2.5`).
- For license-permitted prompts: copy verbatim with `## Attribution:
  TauricResearch/TradingAgents@<commit> <license>` header.
- For license-incompatible prompts: Allbert-authored equivalent
  preserving role intent + output sections + rating scale, with
  `## Attribution: Allbert-authored (Sandeep Puri, 2026-05-17)`.
- Each prompt file: one role; lives at
  `plugins/stocksage/priv/prompts/native_agents/<role>.md`.
- Each carries `prompt_version` matching the v0.25 release tag (e.g.,
  `"v0.25.0"`); bumped per prompt revision.

A test asserts every prompt file starts with `## Attribution`. A test
asserts the attribution is either a valid `<repo>@<commit>` reference
OR the literal `Allbert-authored` marker.

### A9. Per-agent LLM model profile overrides

`stocksage.native_model_profile` (default `"fast"`) governs all
specialist agents by default. Each role has a per-agent override
setting `stocksage.native_model_profile_<role>` that takes
precedence. Role defaults split:

- Analysts (`market_context`, `news_sentiment`, `fundamentals`),
  bull/bear (`bull_thesis`, `bear_thesis`): default `:fast`.
- Risk debaters (`risk_aggressive`, `risk_conservative`,
  `risk_neutral`), `decision_synthesizer`: default `:slow` (deep-think).
- `quality_gate`: no LLM (deterministic Jido.Agent).

Rationale: matches Python's `deep_think_llm` / `quick_think_llm`
split. Per-agent overrides give operators cost control + model-quality
tuning per role without forcing a single profile.

### A10. Fixture mode as first-class operator surface

`stocksage.native_evidence_mode` setting accepts
`["live", "fixture", "compare"]` (default `"live"`). Per-call
override via `--evidence-mode` flag.

Fixture mode is a **first-class operator surface, not a test-only
shortcut**: production operators can switch to fixture mode for smoke
without market-data credentials and without modifying code. Fixtures ship under
`plugins/stocksage/priv/fixtures/native_agents/` for AAPL, MSFT, NVDA
at one canonical date (`2026-05-15`). Fixtures are versioned and
license-clear (synthetic data; no redistribution of Yahoo Finance,
StockTwits, or Reddit content).

`"compare"` mode calls both live and fixture and records divergence
for parity diagnostics (used in v0.25 M6 testing; future v0.27 may
expand).

## Consequences

- v0.25 proves the v0.24 delegate-agent substrate with real supervised agents
  (10 specialist agents under StockSage; cross-app callability proven via
  `mix allbert.delegate` in Allbert core per A7).
- Future apps can call the same financial specialists through shared objective
  and action boundaries instead of importing StockSage internals (A7).
- The StockSage native path can improve beyond the Python baseline without
  being constrained to every Python role/class boundary (10-agent topology
  per A1 collapses Python's research_manager + portfolio_manager + trader
  into a single decision_synthesizer; collapses news_analyst +
  sentiment_analyst into news_sentiment).
- Market-data access becomes more inspectable than the v0.22 Python bridge
  because native evidence is action-backed and Resource Access aware
  (5 tiered evidence actions per A4 with the new
  `:stocksage_evidence_fetch` permission class).
- The Python bridge remains useful for comparison, similarity scoring, and
  regression fixtures, but not for automatic fallback or persistent-default
  engine selection. `--engine both` per A5 runs both engines concurrently and
  persists a parity diff per A6.
- Multi-round bull/bear/risk debate is implemented inside the
  StockSage coordinator with durable objective-step observability (A2),
  giving operators per-round inspectability via
  `mix allbert.objectives show <id>` without coupling the generic
  Objective Engine to StockSage-specific graph grammar.
- A new JidoBacked orchestrator (`StockSage.Agents.NativeCoordinator`) per A3
  composes the agents into the analysis flow. The coordinator is not
  registered in AgentRegistry; it is called from `StockSage.Actions.RunAnalysis`
  via the v0.23 substrate's `JidoBacked.dispatch/4`.
- Hybrid prompt provenance per A8 keeps every prompt operator-readable and
  audit-traceable (verbatim with attribution or Allbert-authored).
- Per-agent model profile overrides per A9 give operators per-role LLM cost
  + quality control.
- Fixture mode per A10 is a first-class operator surface for smoke without
  market-data credentials + license-clear smoke data shipping with v0.25.
- The Jido agent surface grows from the existing IntentAgent to 9 new
  LLM-backed Jido.AI specialists, 1 deterministic Jido.Agent quality gate,
  and 1 JidoBacked coordinator. This is the v0.25 substrate-pattern proof
  for v0.27+ domain-specific specialist agents.

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

### Token-similarity / Jaccard parity metric (rejected per A6)

Rejected for v0.25. Token-bag overlap over `final_trade_decision` text is
brittle against legitimate paraphrase differences between native Elixir and
Python LLM agents. v0.25 uses the 5-point rating-scale agreement scoring
(exact 1.0 / adjacent 0.5 / distant 0.0) plus bounded confidence delta
because rating-scale agreement is operator-meaningful and quantitatively
verifiable. Token similarity could be added as a v0.27+ supplementary metric
if a real consumer emerges.

### One-agent risk perspective (rejected per A1)

Rejected. Collapsing Python's 3 risk debaters (aggressive, conservative,
neutral) into a single agent would lose the adversarial-quality property of
separate per-stance LLM calls. v0.25 keeps them distinct as 3 specialist
agents to preserve Python's final-decision quality.

### Hidden internal coordinator loop

Rejected. The shipped coordinator owns the StockSage graph loop, but it
does not hide the loop. Every specialist turn is persisted as a durable
`objective_step` row with `round_index` metadata. A private loop that
only returned a final report without objective-step observability remains
rejected.
