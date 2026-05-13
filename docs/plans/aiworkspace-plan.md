# Allbert — Elixir/OTP Workspace Rethink Plan

**Author:** Sandeep Puri  
**Date:** 2026-05-13  
**Status:** Draft — rebaselined after convergence critique and storage/runtime decisions
**Scope:** Three-deliverable plan for rethinking StockSage inside the Allbert personal AI workspace built on Elixir/OTP, Jido, Phoenix LiveView, and SQLite-first local storage

---

## 1. What Changed From The First Draft

The original `aiworkspace-plan.md` treated this as a greenfield project. This revision incorporates five new inputs:

1. **Prior art**: `allbert-assist-exs` (Elixir, v0.10) and `allbert-assist-rs` (Rust, v0.15) are both real, substantially built codebases. We are not starting from scratch.
2. **Workspace name**: The workspace is called **Allbert**. `allbert-assist-exs` is the Elixir repo this plan extends.
3. **Deliverable ordering**: Chat agent first, native trading agents second, StockSage web UI third.
4. **New architectural concerns**: multi-user data model from the start, cross-app agent/action/signal registry, and a generative UI live canvas in LiveView.
5. **Existing roadmap check**: The allbert-assist-exs `docs/plans/v0.11` through `v0.17` plans were reviewed. The direction is aligned, but not fully orthogonal: D1 touches the runtime identity model, conversation context, traces, LiveView chat, and future job ownership semantics. **v0.17 already plans the live canvas** ("Agentic Workspace Surface and Ephemeral UI Substrate") — the generative UI work is already on the allbert roadmap. We do not rebuild it; StockSage hooks into it when v0.17 ships.

### 1.1 Rebaseline Decisions

This plan is now governed by five decisions from the convergence critique:

1. **Preserve Allbert's no-server local posture as long as possible.** SQLite remains the default data store for Allbert and StockSage while this is a local personal workspace. PostgreSQL is deferred until there is a real hosted/multi-user deployment need.
2. **Avoid Oban as a hard dependency in the local path.** If background work can be handled by OTP/Jido supervisors, SQLite-backed queues, or supervised worker processes, prefer that. Oban can be revisited only if its current SQLite support is acceptable and does not force a server dependency; PostgreSQL-backed Oban belongs to hosted multi-user work.
3. **Use string `user_id` now, not `AllbertAssist.Accounts.User`.** D1 and D2 carry a stable string user id (`"local"`, `"alice"`, etc.) through runtime, data, signals, and traces. A real accounts/auth model is a later hosted milestone.
4. **Bridge first, native parity second.** Python StockSage/TradingAgents remains the behavioral baseline. The Elixir bridge is the first implementation path; native Jido agents become the default only after golden-fixture and batch parity checks prove they are good enough.
5. **Retire Rust Allbert as an experiment.** `allbert-assist-rs` is useful prior art for identity, sessions, daemon jobs, memory, and RAG, but it is not an active sibling runtime for this convergence plan.

---

## 2. What Allbert Already Has (allbert-assist-exs v0.10)

`https://github.com/lexlapax/allbert-assist-exs` is a Phoenix umbrella at v0.10 with:

| Concern | What exists |
|---------|-------------|
| Umbrella structure | `allbert_assist` (OTP core) + `allbert_assist_web` (Phoenix web) |
| Agent framework | Jido 2.2, jido_action 2.2, jido_signal 2.1, jido_ai 2.1 |
| Primary agent | `AllbertAssist.Agents.IntentAgent` — deterministic routing + Jido.AI.Agent tools |
| Action registry | `AllbertAssist.Actions.Registry` — module-keyed action lookup |
| Skills system | Full agentskills.io-compatible: parser, local registry, online import, SKILL.md shipped skills |
| Memory | Markdown-first: `AllbertAssist.Memory` writes per-category `.md` files under `ALLBERT_HOME/memory/` |
| Settings | `AllbertAssist.Settings` — YAML-backed settings engine with encrypted secrets |
| Security | `AllbertAssist.Security.PermissionGate`, `SecurityCentral`, resource grants, durable confirmations |
| Runtime | `AllbertAssist.Runtime.submit_user_input/1` — signal-first turn boundary with `operator_id` |
| CLI | Mix tasks: `allbert.ask`, `allbert.skills`, `allbert.settings`, `allbert.confirmations`, `allbert.resources` |
| Web UI | LiveView: `AgentLive` (chat), `SettingsLive`; DaisyUI + Tailwind |
| Database | SQLite via ecto_sqlite3 (local, no server needed) |
| Plans | `docs/plans/v0.01` through `v0.17` — 13 ADRs documented |

The Rust version (`allbert-assist-rs` v0.15) is more advanced in several runtime areas, but it was an experiment and is not a sibling runtime going forward. We treat it as prior art and extend the Elixir version.

**What is explicitly missing** from allbert-assist-exs v0.10 (and what this plan adds):

- Multi-user support: `operator_id` exists but all data is single-user / single-home
- Conversation history: no turn-by-turn DB persistence (memory is append-only markdown)
- ETS session scratchpad: no in-process session state per user
- Native trading agents (Jido AI): no domain-specific agent topology for financial analysis
- StockSage web surface: no analysis, queue, trends LiveViews
- Cross-app registry: only `allbert_assist` actions are registered; no contract for other apps to register

---

## 3. Vision

> **Allbert is a personal AI workspace. StockSage is the first domain app inside it.**

The workspace is the operating environment. Allbert handles memory, skills, security, settings, multi-user sessions, and the shared agent runtime. StockSage plugs in as a first-class workspace app — registering its own agents, actions, and skills with the Allbert core at startup.

The LiveView surface evolves from a static chat UI toward a **live canvas**: a server-authoritative, AI-drivable workspace where the agent's output can specify which UI components to render, not just what text to display.

---

## 4. Three Deliverables

### D1 — Multi-user Allbert Chat Agent with Memory

**Goal:** Extend allbert-assist-exs so the chat agent is multi-user from the start — `user_id` in all data structures, APIs, and storage — with conversation history and an ETS session scratchpad. Mix tasks are the primary test surface; LiveView comes in D3.

**What this is NOT:** This is not semantic vector search or structured fact extraction. Those are later phases. D1 is the foundation: turn history + in-session scratchpad + user scoping.

**Key changes to allbert-assist-exs:**

```
AllbertAssist.Memory.Thread       ← Ecto schema: {id, user_id, title, inserted_at, updated_at}
AllbertAssist.Memory.Message      ← Ecto schema: {id, thread_id, user_id, role, content, inserted_at}
AllbertAssist.Session.Scratchpad  ← ETS-backed, per session_id, TTL-expired
AllbertAssist.Runtime             ← updated: accepts user_id + thread_id; stores Message rows
```

**Mix task API changes:**

```sh
mix allbert.ask "hello"                          # user_id defaults to "local"
mix allbert.ask --user alice "hello"             # explicit user_id
mix allbert.ask --user alice --thread abc "..."  # explicit thread
mix allbert.ask --user alice --new-thread "..."  # creates a new thread
mix allbert.threads --user alice                 # list threads
mix allbert.threads --user alice --thread abc    # show messages in thread
```

**Why SQLite for history (not markdown):** Conversation history needs ordering, pagination, and cross-thread queries. Markdown files are fine for long-term memory entries but not for structured conversation records. SQLite via ecto_sqlite3 is already in the project.

**Later phases (not D1):**
- Semantic/vector recall (pgvector or sqlite-vec RAG)
- Structured fact extraction and entity recognition
- Cross-session memory promotion (connect to existing markdown memory)

---

### D2 — StockSage Domain + Analysis Engine (Bridge First, Native Later)

**Goal:** Bring StockSage analysis into the Allbert umbrella in two phases: first by calling the existing Python StockSage/TradingAgents engine through a supervised bridge, then by proving a native Jido AI implementation against that baseline. The full analysis pipeline runs via `mix stocksage.analyze AAPL 2026-05-01` before any web UI exists.

**Why bridge before native Jido:** Python StockSage 0.0.2 is the current behavioral baseline. Rebuilding TradingAgents as native Jido agents is a parity project, not a mechanical port. The bridge gets the product working inside Allbert early; native Jido becomes the default only after golden fixtures and batch validation show it matches the Python baseline closely enough.

**New umbrella apps:** `stocksage` (OTP core) + `stocksage_web` (Phoenix surface, D3).

**Native agent topology target:**

```
StockSage.Analysis.Pod  (one Pod per analysis run)
├── OrchestratorAgent    ← coordinates workflow; receives signals
├── MarketAnalystAgent   ← Jido.AI.Agent, fetches market data, writes market_report
├── SentimentAnalystAgent
├── NewsAnalystAgent
├── FundamentalsAnalystAgent
├── BullResearcherAgent  ← receives analyst reports; argues Bull thesis
├── BearResearcherAgent  ← argues Bear thesis
├── TraderAgent          ← resolves bull/bear debate into a trading plan
└── PortfolioManagerAgent ← final risk-adjusted decision (Buy/Hold/Sell + target)
```

Each agent uses `Jido.AI.Agent` with a ReAct strategy. Actions are Jido actions with AI tool schema generation:

```elixir
defmodule StockSage.Actions.FetchStockData do
  use Jido.Action,
    name: "fetch_stock_data",
    description: "Fetch OHLCV, fundamentals, and technical indicators for a ticker",
    schema: [
      ticker:     [type: :string, required: true],
      start_date: [type: :date, required: true],
      end_date:   [type: :date, required: true]
    ]
  # ...
end
```

**Mix task:**

```sh
mix stocksage.analyze AAPL 2026-05-01
mix stocksage.analyze --deep AAPL 2026-05-01   # full multi-agent graph
mix stocksage.analyze --quick AAPL 2026-05-01  # single-agent fast path
```

**Python bridge (initial default):** For the Python TradingAgents graph, keep a supervised bridge selectable via config. Start with a small bridge spike before committing to ErlPort specifically; a supervised Port with JSON over stdio may be simpler to operate with `uv`, virtualenvs, and Python dependencies. Native Jido agents become the default only after M-D2c parity acceptance passes.

---

### D3 — Web-based StockSage UI

**Goal:** A LiveView workspace surface for StockSage within the Allbert shell. Analysis, queue management, trends, and live agent progress.

**LiveViews:**

```
/stocksage/                  → StockSageLive.WorkspaceLive  (dashboard + quick-enqueue)
/stocksage/analysis/:id      → StockSageLive.AnalysisLive   (tabbed: Overview, Market, Bull/Bear, Trader, Risk)
/stocksage/queue             → StockSageLive.QueueLive      (live queue with SQLite-backed worker state + PubSub)
/stocksage/trends            → StockSageLive.TrendsLive     (accuracy charts, leaderboard)
```

Real-time agent progress via `Phoenix.PubSub` — worker events push through to the LiveView without polling. The first local implementation should use OTP/Jido supervision plus SQLite-backed queue records rather than introducing a hard PostgreSQL dependency.

**Canvas integration (post-v0.17):** StockSage LiveViews start as standard LiveViews. After the allbert core v0.17 live canvas ships, `StockSageWeb.Canvas.StockChart` and `AnalysisCard` register with the v0.17 catalog. No canvas work happens in D3 itself.

---

## 5. Cross-App Agent/Action/Signal Registry

### 5.1 The Problem

In an umbrella where `allbert_assist` (core) and `stocksage` are separate OTP applications, the IntentAgent in `allbert_assist` should be able to route to StockSage actions. Currently `AllbertAssist.Actions.Registry` only knows about actions defined in `allbert_assist`. There is no contract for apps to register themselves.

### 5.2 The Solution: Minimal Contract First, Full Contract Later

Modeled on the `Oban.Plugin` pattern: `validate/1` catches misconfiguration at startup time; `child_spec/1` injects workspace config so apps do not hardcode global module references. The contract spans five layers:

Implementation should land in two steps:

1. **M-AppContract-Lite before M-D2a**: app identity, validation, child supervision, registered actions, registered skills, and nav surfaces. This is enough for StockSage to exist as a first-class local app without prematurely building the full surface DSL.
2. **M-AppContract-Full before v0.17 canvas work**: signal declarations, SurfaceProvider, Allbert-native surface nodes, validation tooling, and optional protocol adapters. This gives v0.17 a real app/surface contract to consume.

```elixir
defmodule AllbertAssist.App do
  @moduledoc "Contract for all Allbert workspace apps. Modeled on Oban.Plugin."

  # --- Layer 1: Identity + OTP ---
  @callback app_id() :: atom()
  @callback display_name() :: String.t()
  @callback version() :: String.t()
  @callback validate(keyword()) :: :ok | {:error, String.t()}
  @callback child_spec(keyword()) :: Supervisor.child_spec()

  # --- Layer 2: Agents, Actions, Signals ---
  @callback actions() :: [module()]              # Jido.Action modules to register globally
  @callback agents() :: [module()]               # Jido.Agent | Jido.AI.Agent modules
  @callback signal_emits() :: [String.t()]       # topics this app may publish (declarative)
  @callback signal_subscribes() :: [String.t()]  # topics this app consumes

  # --- Layer 3: Skills (agentskills.io) ---
  @callback skill_paths() :: [Path.t()]          # priv/skills/ dirs to add to Skills.Registry

  # --- Layer 4: UI Surface ---
  @callback surfaces() :: [AllbertAssist.App.Surface.t()]     # nav surfaces (title, icon, path)
  @callback live_views() :: [{String.t(), module()}]          # {path_pattern, LiveView module}
  @callback router_scope() :: {String.t(), module(), keyword()} # {scope, Router, opts}
  # canvas_catalog/0 added after allbert core v0.17 ships (M-Canvas milestone)
  # @callback canvas_catalog() :: [AllbertAssist.Surface.catalog_entry()]

  # --- Layer 5: Data + Settings ---
  @callback settings_schema() :: keyword()       # NimbleOptions-style settings declaration
  @callback memory_namespaces() :: [atom()]      # allbert memory categories this app writes to

  @optional_callbacks [
    agents: 0,
    signal_subscribes: 0,
    live_views: 0,
    router_scope: 0,
    settings_schema: 0,
    memory_namespaces: 0
  ]
end
```

**Layer notes:**

- **Layer 1 (Identity + OTP)**: `validate/1` is called by `AllbertAssist.App.Registry.register/2` before any children are started — misconfiguration fails loudly at startup rather than at runtime. `child_spec/1` is passed workspace config opts (e.g., `[repo: AllbertAssist.Repo, bus: AllbertAssist.SignalBus]`) so apps never hardcode global module names.

- **Layer 2 (Agents/Actions/Signals)**: `actions/0` returns Jido.Action modules that are registered in `AllbertAssist.Actions.Registry` tagged with `app_id` for scoped routing. `signal_emits/0` is declarative — used for documentation and permission-gate checks, not runtime enforcement. `signal_subscribes/0` wires up bus subscriptions during registration.

- **Layer 3 (Skills)**: `skill_paths/0` returns filesystem paths added to `AllbertAssist.Skills.Registry` immediately on registration. Skills become discoverable via `mix allbert.skills list` without any restart.

- **Layer 4 (UI Surface)**: `surfaces/0` returns structs the workspace shell uses to build navigation. `live_views/0` are mounted by the Allbert router at startup (statically configured, not dynamically discovered at runtime). `router_scope/0` provides a sub-router for apps that need their own pipeline (API routes, plugs, etc.).

- **Layer 5 (Data + Settings)**: `settings_schema/0` declares required config keys validated at startup. `memory_namespaces/0` declares which allbert memory categories this app writes to — used for permission gating.

**Concrete StockSage.App implementation:**

```elixir
defmodule StockSage.App do
  @behaviour AllbertAssist.App

  def app_id(),       do: :stocksage
  def display_name(), do: "StockSage"
  def version(),      do: "0.1.0"

  def validate(opts) do
    if Keyword.has_key?(opts, :repo), do: :ok,
    else: {:error, "StockSage requires :repo in opts"}
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {StockSage.Application, :start_link, [opts]}, type: :supervisor}
  end

  def actions(), do: [
    StockSage.Actions.RunAnalysis,
    StockSage.Actions.QueueAnalysis,
    StockSage.Actions.GetTrends
  ]

  def agents(), do: [
    StockSage.Agents.OrchestratorAgent,
    StockSage.Agents.MarketAnalystAgent
    # ... all 8 analyst/researcher/trader agents
  ]

  def signal_emits(), do: [
    "stocksage.analysis.started",
    "stocksage.analysis.completed",
    "stocksage.analysis.failed",
    "stocksage.queue.updated"
  ]

  def signal_subscribes(), do: ["allbert.user.context_changed"]

  def skill_paths(), do: [Application.app_dir(:stocksage, "priv/skills")]

  def surfaces(), do: [
    %AllbertAssist.App.Surface{
      id: :workspace, title: "StockSage",
      icon: "chart-line", path: "/stocksage",
      live_view: StockSageWeb.WorkspaceLive
    }
  ]

  def live_views(), do: [
    {"/stocksage",              StockSageWeb.WorkspaceLive},
    {"/stocksage/analysis/:id", StockSageWeb.AnalysisLive},
    {"/stocksage/queue",        StockSageWeb.QueueLive},
    {"/stocksage/trends",       StockSageWeb.TrendsLive}
  ]

  def router_scope(), do: {"/stocksage", StockSageWeb.Router, []}

  def memory_namespaces(), do: [:stocksage_analyses, :stocksage_lessons]
end
```

The `AllbertAssist.Actions.Registry` already exists — it gains an `app_id` tag per entry so the intent agent can scope routing (actions registered by StockSage are only prioritized when `active_app: :stocksage` is set in the session scratchpad).

### 5.3 Cross-App Signal Routing

Signals cross app boundaries via the shared `Jido.Signal.Bus` (already in the core supervision tree). A StockSage agent emits:

```elixir
Jido.Signal.new!("stocksage.analysis.completed", %{analysis_id: id, user_id: user_id})
|> Jido.Signal.Bus.publish(AllbertAssist.SignalBus)
```

The Allbert shell `NotificationAgent` subscribes to `stocksage.*` and surfaces cross-app events in the workspace notification bar. LiveViews subscribe directly to PubSub topics:

```elixir
Phoenix.PubSub.subscribe(AllbertAssist.PubSub, "stocksage:analysis:#{analysis_id}")
```

### 5.4 Intent Routing to Cross-App Actions

The IntentAgent's deterministic router gets a new layer:

```elixir
defp route(text, context) do
  # 1. Check core allbert actions (existing)
  # 2. Check active app context from session (new)
  # 3. Route to registered app actions if in-scope
end
```

When a user is in the StockSage context (navigated to `/stocksage/...`), the session agent sets `active_app: :stocksage` and the intent agent prioritizes StockSage actions. A natural language prompt like "analyze AAPL for today" routes to `StockSage.Actions.RunAnalysis`.

### 5.5 Umbrella Structure

```
allbert/                          ← Umbrella root (allbert-assist-exs renamed/extended)
├── apps/
│   ├── allbert_assist/           ← Core OTP application (existing v0.10)
│   │   ├── lib/allbert_assist/
│   │   │   ├── app.ex            ← AllbertAssist.App behaviour (new)
│   │   │   ├── app/registry.ex   ← AllbertAssist.App.Registry (new)
│   │   │   ├── memory/
│   │   │   │   ├── memory.ex     ← existing markdown memory
│   │   │   │   ├── thread.ex     ← NEW: Ecto schema, user_id + thread_id
│   │   │   │   └── message.ex    ← NEW: Ecto schema, turn history
│   │   │   ├── session/
│   │   │   │   └── scratchpad.ex ← NEW: ETS-backed session state
│   │   │   ├── agents/           ← existing IntentAgent + future specialists
│   │   │   ├── actions/          ← existing action modules
│   │   │   ├── skills/           ← existing skill registry + parser
│   │   │   ├── security/         ← existing security + permission gate
│   │   │   └── settings/         ← existing settings engine
│   │   └── mix.exs
│   │
│   ├── allbert_assist_web/       ← Phoenix web (existing v0.10)
│   │   ├── lib/allbert_assist_web/
│   │   │   ├── live/
│   │   │   │   ├── agent_live.ex     ← existing chat UI (updated: multi-user threads)
│   │   │   │   └── settings_live.ex  ← existing
│   │   │   └── components/           ← existing + thread list component
│   │   └── mix.exs
│   │   (canvas_live.ex and canvas catalog added by allbert core v0.17, not this plan)
│   │
│   ├── stocksage/                ← StockSage OTP application (NEW)
│   │   ├── lib/stocksage/
│   │   │   ├── application.ex    ← registers with AllbertAssist.App.Registry
│   │   │   ├── agents/           ← Jido.AI.Agent modules
│   │   │   ├── actions/          ← Jido action modules
│   │   │   ├── domain/           ← SQLite-backed records (Analysis, Outcome, Queue, etc.)
│   │   │   ├── trader_bridge/    ← supervised Python bridge (transitional)
│   │   │   ├── outcomes/
│   │   │   ├── trends/
│   │   │   └── memory/           ← StockSage memory entries → allbert memory
│   │   └── mix.exs
│   │
│   └── stocksage_web/            ← StockSage LiveView surface (NEW, D3)
│       ├── lib/stocksage_web/
│       │   ├── live/             ← WorkspaceLive, AnalysisLive, QueueLive, TrendsLive
│       │   └── components/       ← StockSage UI components (standard LiveView)
│       │   (StockChart + AnalysisCard register with v0.17 canvas catalog post-D3)
│       └── mix.exs
│
├── config/
├── mix.exs
└── .env.example
```

### 5.6 AllbertAssist.App.SurfaceProvider

Apps that expose interactive surfaces (not just nav links) implement a secondary behaviour:

```elixir
defmodule AllbertAssist.App.SurfaceProvider do
  @moduledoc """
  Secondary contract for apps with interactive surface components.
  A2UI-inspired: surfaces have lifecycle (init → render → action).
  ADR 0001 compliance: handle_action/2 MUST return a Jido signal.
  """

  @type surface_id    :: atom()
  @type surface_state :: map()

  @callback init(surface_id()) ::
              {:ok, surface_state()} | {:error, term()}

  @callback render(surface_id(), surface_state()) ::
              AllbertAssist.Surface.node()

  @callback handle_action(surface_id(), action :: map()) ::
              {:signal, Jido.Signal.t(), surface_state()}
              | {:noreply, surface_state()}
end
```

`render/2` returns an `AllbertAssist.Surface.node()` (see §6.6). LiveView renders it by default. `AllbertAssist.Surface.Encoder.to_a2ui/1` converts it to A2UI JSON for mobile/desktop clients.

`handle_action/2` receives user-initiated actions (button clicks, form submits expressed as maps) and **must** return a Jido signal per ADR 0001 — all state transitions go through the signal bus, not direct GenServer state mutation.

### 5.7 App Registry: Elixir Registry + DynamicSupervisor

```elixir
defmodule AllbertAssist.App.Registry do
  @moduledoc "Runtime discovery and lifecycle management for registered Allbert apps."

  def register(app_module, opts \\ []) do
    with :ok <- app_module.validate(opts),
         {:ok, _pid} <- DynamicSupervisor.start_child(
           AllbertAssist.App.Supervisor,
           app_module.child_spec(workspace_opts(opts))
         ) do
      Enum.each(app_module.actions(),
        &AllbertAssist.Actions.Registry.register(&1, app_id: app_module.app_id()))
      Enum.each(app_module.skill_paths(),
        &AllbertAssist.Skills.Registry.add_path/1)
      subscribe_signals(app_module)
      Registry.register(__MODULE__, app_module.app_id(), app_module)
      {:ok, app_module.app_id()}
    end
  end

  def lookup(app_id) do
    case Registry.lookup(__MODULE__, app_id) do
      [{_pid, module}] -> {:ok, module}
      []               -> {:error, :not_found}
    end
  end

  def registered_apps() do
    Registry.select(__MODULE__, [{{:_, :_, :"$1"}, [], [:"$1"]}])
  end

  defp subscribe_signals(app_module) do
    Enum.each(app_module.signal_subscribes(), fn topic ->
      Jido.Signal.Bus.subscribe(AllbertAssist.SignalBus, topic, app_module)
    end)
  end

  defp workspace_opts(opts) do
    Keyword.merge([
      repo: AllbertAssist.Repo,
      bus: AllbertAssist.SignalBus,
      pubsub: AllbertAssist.PubSub
    ], opts)
  end
end
```

Apps supervised by `DynamicSupervisor` restart on crash and re-establish their action/skill/signal registrations via their own `start_link/1`. The Elixir `Registry` provides `{:via, Registry, {AllbertAssist.App.Registry, :stocksage}}` process naming for intent-agent-to-app routing.

---

## 6. Generative UI: Live Canvas — Alignment with allbert v0.17

### 6.1 What the Existing Roadmap Already Plans

The allbert-assist-exs `docs/plans/v0.17-plan.md` ("Agentic Workspace Surface and Ephemeral UI Substrate") already specifies exactly this concept. Key excerpts from that plan:

- Define an **Allbert surface envelope** for declarative UI data: surface id, purpose, lifecycle, component catalog, data bindings, provenance, fallback text, allowed events, registered action bindings
- Design the **LiveView workspace shell** around runtime state: conversation and signal timeline, canvas, task surfaces, approval inspector, trace inspector
- Use **Phoenix LiveView and OTP primitives**: PubSub topics for runtime events, LiveView streams for timelines, `start_async/3` for long-running requests
- Treat A2UI, AG-UI, MCP Apps, Claude Artifacts, Gemini generative UI as **research references** — Allbert-native contracts first

This is the right decomposition. **We do not build the canvas in D1–D3.** v0.17 owns it.

### 6.2 What D1–D3 Contribute Toward v0.17

D1 and D2 lay the groundwork that v0.17 needs:

| D1/D2/D3 contribution | Why v0.17 needs it |
|----------------------|---------------------|
| `user_id` + `thread_id` in runtime (D1a) | Canvas tiles are user-scoped and thread-scoped |
| ETS session scratchpad with `active_app` (D1b) | Canvas shell needs to know the active app context |
| `AllbertAssist.App` behaviour + registry (M-AppContract-Lite) | v0.17 enumerates registered apps to populate the workspace shell nav |
| Jido Signal bus publishing from StockSage (D2b/D2c) | Canvas timeline streams from the signal bus |
| StockSage LiveViews as plain LiveViews (D3) | v0.17 canvas wraps existing LiveView surfaces; no rewrite needed |

### 6.3 StockSage Canvas Integration (Post-v0.17)

Once allbert core v0.17 ships its canvas substrate, StockSage adds:

```elixir
# In StockSage.App callbacks (extends the existing behaviour)
def canvas_components(), do: [
  {"stock_chart",    StockSageWeb.Canvas.StockChart},
  {"analysis_card",  StockSageWeb.Canvas.AnalysisCard}
]
```

The agent response format gains `canvas_ops` after v0.17 defines the contract:

```elixir
%{
  message: "Here is AAPL's 30-day trend.",
  canvas_ops: [
    %{op: :upsert, id: "chart-aapl", component: "stock_chart",
      attrs: %{ticker: "AAPL", range: "30d"}}
  ]
}
```

**This is a post-D3 milestone** (§11, M-Canvas). It needs the v0.17 substrate and completed StockSage LiveView components; it does not redefine the StockSage domain model.

### 6.4 Three Protocols, One Stack

There are three distinct concerns in a generative agent UI. Allbert addresses each:

| Concern | External protocol | Allbert approach |
|---------|------------------|-----------------|
| **How events stream** (agent lifecycle, text chunks, tool calls) | AG-UI (CopilotKit) | Research reference only in v0.17; LiveView/PubSub remain the local transport |
| **What to render** (component descriptions, data bindings) | A2UI (Google) | Research reference only in v0.17; `AllbertAssist.Surface` stays Allbert-native |
| **How the browser updates** (DOM patching, reconnect, backpressure) | Phoenix LiveView | Unchanged — LiveView is the substrate; no extra JS runtime needed |

AG-UI and A2UI are **complementary research references**: A2UI component payloads can be delivered inside AG-UI `custom` events, but Allbert should not take either protocol as a core dependency before the v0.17 local surface contract is proven. LiveView is the default consumer; external protocol encoding is optional later work.

### 6.5 AG-UI: Agent Event Streaming

`ag_ui_ex` v0.1.0 (hex.pm, by 23min) defines event structs for the AG-UI protocol. Treat it as a candidate adapter package, not a required dependency for M-AppContract-Lite or the first v0.17 substrate:

```elixir
# Key event types used in allbert
%AGUIEx.RunStarted{thread_id: "...", run_id: "..."}
%AGUIEx.TextMessageStart{message_id: "...", role: :assistant}
%AGUIEx.TextMessageChunk{message_id: "...", delta: "AAPL is currently..."}
%AGUIEx.TextMessageEnd{message_id: "..."}
%AGUIEx.ToolCallStart{tool_call_id: "...", tool_name: "fetch_stock_data"}
%AGUIEx.ToolCallEnd{tool_call_id: "...", result: %{...}}
%AGUIEx.StateSnapshot{state: %{active_app: :stocksage, canvas_tiles: [...]}}
%AGUIEx.Custom{name: "canvas_op", value: %{op: :upsert, component: "stock_chart", ...}}
%AGUIEx.RunFinished{run_id: "...", final_state: %{decision: "Buy", ...}}
```

If Allbert later adopts an AG-UI adapter, these events can be published on the signal bus (`Jido.Signal` wrapping AG-UI event structs) and consumed by LiveViews via PubSub `handle_info/2`. The SSE/WebSocket transport that AG-UI specifies for external HTTP clients is not used internally — LiveView's own channel is the transport. If Allbert later exposes an HTTP streaming endpoint for external agent runners, that endpoint can emit AG-UI SSE using the same semantic event categories.

**StockSage flow:** OrchestratorAgent emits `RunStarted`, each analyst agent emits `TextMessageChunk` bursts as it reasons, `ToolCallStart`/`ToolCallEnd` wrap each data-fetch action, and `RunFinished` carries the final `%{decision: "Buy", confidence: 0.72}`. `AgentLive` receives these via PubSub and streams them into the conversation timeline using `LiveView.stream/3`.

### 6.6 A2UI and AllbertAssist.Surface

**A2UI** (Google's Agent-to-UI protocol, `ex_a2ui` hex.pm) defines five message types: `createSurface`, `updateComponents`, `updateDataModel`, `watchDataModel`, `deleteSurface`. It specifies standard component types plus a custom component catalog. Components declare JSON Pointer data bindings to a shared data model; actions flow back from UI to agent via `onAction` callbacks. Treat `ex_a2ui` as an optional future bridge for non-LiveView clients, not a dependency for the local web UI.

**Security alignment:** A2UI's catalog-as-allowlist model aligns directly with Allbert's permission gate — only registered component types can be rendered. No arbitrary HTML or JavaScript can be injected by an LLM response.

**AllbertAssist.Surface** is Allbert's native equivalent, defined as Elixir terms rather than JSON:

```elixir
defmodule AllbertAssist.Surface do
  @moduledoc "Allbert-native component DSL, A2UI-inspired. 18 standard types + custom."

  @type node ::
      {:text,    attrs(), String.t()}
    | {:heading, attrs(), String.t()}
    | {:image,   attrs(), String.t()}              # URL
    | {:button,  attrs(), String.t()}              # label; :action key in attrs
    | {:list,    attrs(), [node()]}
    | {:table,   attrs(), %{columns: list(), rows: list()}}
    | {:chart,   attrs(), %{type: :line | :bar | :candle, data: list()}}
    | {:form,    attrs(), [node()]}
    | {:card,    attrs(), [node()]}
    | {:badge,   attrs(), String.t()}
    | {:custom,  atom(), map()}                    # registered component atom (catalog)

  @type attrs          :: keyword()
  @type catalog_entry  :: {atom(), module()}       # {component_atom, LiveComponent module}
end
```

**Agent response with surface node (post-v0.17):**

```elixir
%{
  text: "AAPL analysis complete — signal: Buy.",
  surface: {:card, [id: "aapl-summary"], [
    {:heading, [], "AAPL — Buy"},
    {:chart, [type: :candle], %{ticker: "AAPL", range: "30d"}},
    {:badge, [color: :green], "↑ 4.2% projected"},
    {:button, [action: "view_full_analysis", analysis_id: "..."], "View full report"}
  ]}
}
```

**Rendering path:**

```
Agent produces AllbertAssist.Surface.node()
  │
  ├─► AllbertAssist.Surface.Renderer (LiveView, DEFAULT)
  │       → component dispatch against pre-approved catalog
  │       → DOM patch via LiveView channel (no extra JS)
  │
  └─► AllbertAssist.Surface.Encoder.to_a2ui/1  (OPTIONAL — mobile/Electron only)
          → A2UI JSON → non-LiveView client
```

`to_a2ui/1` is never called in the Phoenix web UI path. It exists as a bridge for future non-browser clients.

**agentskills.io hook:** A skill's SKILL.md frontmatter can declare a `canvas_component` key naming the surface component to render when the skill is activated. The intent agent uses this to trigger a surface update alongside the text response.

---

## 7. Multi-User Data Model

### 7.1 `user_id` Everywhere

Every resource, memory entry, action context, signal, and mix task parameter carries `user_id`. The default for local single-user operation is `"local"`. The existing `operator_id` in the runtime becomes `user_id` (or is aliased).

For D1-D3, `user_id` is a stable string, not a foreign key to an accounts table. This keeps the local workspace lightweight and avoids designing hosted auth too early. A real `AllbertAssist.Accounts.User` model, authentication, roles, and PostgreSQL-backed multi-user deployment belong to M-Production or a future hosted milestone.

```elixir
# Runtime boundary (updated signature)
AllbertAssist.Runtime.submit_user_input(%{
  text: "analyze AAPL",
  user_id: "alice",           # was operator_id
  thread_id: "thread-123",    # new
  session_id: "sess-abc",     # new (ETS scratchpad key)
  channel: :cli
})
```

### 7.2 Conversation History Schema (SQLite)

```elixir
defmodule AllbertAssist.Memory.Thread do
  use Ecto.Schema

  schema "threads" do
    field :user_id,    :string
    field :title,      :string
    field :app_id,     :string  # nil = general; "stocksage" = stocksage context
    timestamps()
  end
end

defmodule AllbertAssist.Memory.Message do
  use Ecto.Schema

  schema "messages" do
    field :thread_id,  :string
    field :user_id,    :string
    field :role,       :string   # "user" | "assistant" | "tool"
    field :content,    :string
    field :action_log, :map      # rendered action results, serialized
    field :trace_id,   :string
    timestamps(updated_at: false)
  end
end
```

`app_id` on `Thread` is the cross-app signal: a thread started from the StockSage LiveView is tagged `app_id: "stocksage"` and the intent agent uses it for context.

### 7.3 ETS Session Scratchpad

```elixir
defmodule AllbertAssist.Session.Scratchpad do
  # ETS table :allbert_session_scratchpad, type: :set
  # Key: {user_id, session_id}
  # Value: %{active_app: :stocksage, context: %{}, working_memory: %{}, expires_at: ...}
  # (canvas_tiles added by allbert core v0.17 — not in scope here)

  def get(user_id, session_id) :: map()
  def put(user_id, session_id, key, value) :: :ok
  def delete(user_id, session_id) :: :ok
end
```

### 7.4 Multi-user Mix Task API

```sh
# Single-user (default, backwards-compatible)
mix allbert.ask "hello"

# Multi-user
mix allbert.ask --user alice "hello"
mix allbert.ask --user alice --thread abc123 "continue this thread"
mix allbert.threads list --user alice
mix allbert.threads show --user alice --thread abc123
```

No authentication in D1 — just `user_id` as a string. Accounts, sessions, API keys, and hosted auth are later milestones.

---

## 8. Data Layer: SQLite-First, PostgreSQL Deferred

### 8.1 Two Storage Tiers

| App | Layer | Reason |
|-----|-------|--------|
| `allbert_assist` (core) | Ecto + SQLite (ecto_sqlite3) | Personal assistant; local-first; no server needed; existing choice |
| `stocksage` | SQLite-first domain storage | Keep the same no-server local posture as Allbert while StockSage is a personal workspace app |

The first implementation should not require a local PostgreSQL server. StockSage can use its own SQLite-backed repo or share a carefully namespaced SQLite repo, but the implementation must preserve clean app boundaries and test isolation. If Ash is still desired, validate an SQLite-backed Ash path before committing; AshPostgres is deferred until hosted/multi-user work.

### 8.2 Why keep SQLite locally

- `allbert_assist` is already on SQLite and it works for settings, confirmations, resource grants, and conversation history
- Adding PostgreSQL just for local StockSage would require users to run a server for a personal assistant
- SQLite is a correct fit for single-node, local-first, personal data
- Python StockSage 0.0.2 already proved the local SQLite shape for analysis history, requests, outcomes, queue runs, and trends
- PostgreSQL remains the likely answer when Allbert becomes a true hosted multi-user system

### 8.3 StockSage Domain Records

StockSage domain records:

```elixir
StockSage.Domain.Analysis
StockSage.Domain.AnalysisDetail
StockSage.Domain.Outcome
StockSage.Domain.AnalysisQueue
StockSage.Domain.QueueRun
StockSage.Domain.MemoryEntry
```

Each record carries a string `user_id` and, where appropriate, `thread_id` or `request_id`. Do not create a cross-app foreign key to `AllbertAssist.Accounts.User` in D1-D3 because that table does not exist yet and would force the hosted auth design too early.

Canonical analysis data should remain shared by ticker/date/model where that makes product sense. User ownership and "who asked for this?" history should be represented by request rows rather than duplicating expensive LLM analyses per user.

### 8.4 Background Work

The local implementation should prefer:

- OTP supervisors and workers for queue runners
- Jido signals for progress and lifecycle events
- SQLite-backed queue/request rows for durability and resumption
- Phoenix.PubSub for LiveView updates

Avoid PostgreSQL-backed Oban as a hard dependency in the local path. Oban can be re-evaluated later if the chosen adapter preserves SQLite/local-first operation, or adopted with PostgreSQL in the hosted multi-user milestone.

---

## 9. agentskills.io — Already Implemented, What to Add

**allbert-assist-exs v0.10 already implements the full agentskills.io client spec:**

- `AllbertAssist.Skills.Parser` — parses SKILL.md frontmatter + body
- `AllbertAssist.Skills.Registry` — discovers skills from `~/.allbert/skills/` and `priv/skills/`
- `AllbertAssist.Skills.ActionPlan` — three-tier progressive disclosure (catalog → activation → resources)
- Mix tasks: `allbert.skills validate`, `allbert.skills import-local`, `allbert.skills import-url`
- Built-in skills: `append-memory`, `direct-answer`, `read-recent-memory`, `list-skills`, etc.

**What to add for StockSage:**

```
apps/stocksage/priv/skills/
├── run-analysis/
│   └── SKILL.md    ← "Analyze a stock ticker for a given date using TradingAgents"
├── get-trends/
│   └── SKILL.md    ← "Get accuracy trends and leaderboard for a user's analyses"
├── resolve-outcome/
│   └── SKILL.md    ← "Resolve outcome for a completed analysis after holding period"
└── queue-analysis/
    └── SKILL.md    ← "Queue a batch of tickers for overnight analysis"
```

These skills register with the global skill registry via the `AllbertAssist.App` contract. The intent agent can activate them via natural language: "analyze AAPL" → activates `run-analysis` skill → routes to `StockSage.Actions.RunAnalysis`.

**What NOT to change:** The agentskills.io client implementation in allbert_assist is complete. StockSage just needs to publish skills.

---

## 10. Technology Stack (Updated)

### 10.1 Core Runtime (unchanged + confirmed against allbert-assist-exs)

| Layer | Technology | Version |
|-------|-----------|---------|
| Language | Elixir / OTP 27 | 1.18+ |
| Web framework | Phoenix | 1.8 |
| UI | Phoenix LiveView | 1.1 |
| Agent framework | Jido | 2.2 |
| AI integration | Jido AI | 2.1 |
| Actions library | Jido Action | 2.2 |
| Signal bus | Jido Signal / Phoenix.PubSub | 2.1 |

### 10.2 Data Layer

| Layer | App | Technology |
|-------|-----|-----------|
| Conversation history, settings, confirmations, resource grants | allbert_assist | Ecto + SQLite (ecto_sqlite3) |
| Analysis, outcomes, queue, trends | stocksage | SQLite-first domain storage; Ecto or Ash-with-SQLite after spike |
| In-memory session state | allbert_assist | ETS (session scratchpad) |
| Background jobs | stocksage | OTP/Jido workers + SQLite queue records; Oban optional later |

### 10.3 Python Bridge (transitional, StockSage only)

Supervised Python bridge for TradingAgents. ErlPort remains a candidate, but a JSON-over-stdio Port bridge may be simpler with `uv` and virtualenvs. Long-term: native Jido agents replace the bridge only after parity gates pass.

---

## 11. Milestones

### Two Parallel Tracks

The existing allbert-assist-exs roadmap already occupies v0.11–v0.17 for allbert core work (intent, jobs, channels, memory, security, canvas). This plan's milestones run as a **parallel track** using D-labels to avoid collision. The tracks share the same repo, but they are coupled at runtime boundaries: identity, thread/session context, action registration, job ownership, and the future canvas contract must be sequenced deliberately.

```
allbert core (existing plans):   v0.11 → v0.12 → v0.13 → v0.14 → v0.15 → v0.16 → v0.17(canvas)
                                             ↑                         ↑            ↑
stocksage track (this plan):     D1a → D1b → M-AppContract-Lite → D2a → D2b → D2c → M-AppContract-Full → D3a → D3b → M-Canvas
```

D1a/D1b touch allbert core files (add multi-user/thread context to `allbert_assist`). M-AppContract-Lite touches allbert core before StockSage exists as a registered app. D2a–D3b add new umbrella apps and use the contract. M-AppContract-Full matures the contract for v0.17 canvas consumption.

---

### M-D1a — Multi-User Conversation Layer  
**Allbert track: parallel to v0.11** (coordinate runtime request and trace changes with intent/resource work)

**Goal:** Add `user_id`, `thread_id`, and conversation history to the existing allbert-assist-exs runtime. All existing behavior is preserved; new behavior is additive.

**Scope:**
- `Thread` and `Message` Ecto schemas + SQLite migrations
- `AllbertAssist.Session.Scratchpad` ETS table started in supervision tree
- `Runtime.submit_user_input/1` accepts and propagates `user_id`, `thread_id`, `session_id`
- `IntentAgent.respond/1` reads last N messages from thread as context prefix
- Mix tasks: `allbert.ask --user`, `--thread`, `--new-thread`; `allbert.threads list|show`
- `AgentLive` updated to support multiple threads per user (basic thread list sidebar)
- All existing single-user behavior preserved when `user_id` is omitted (defaults to `"local"`)

**Acceptance:** `mix allbert.ask --user alice "hello"` creates a thread; `mix allbert.ask --user alice "what did I just say?"` reads context from that thread and responds correctly.

---

### M-D1b — ETS Session Scratchpad  
**Allbert track: parallel to v0.11–v0.12** (additive; no canvas yet)

**Goal:** Wire up the session scratchpad so agents and LiveViews can read/write volatile per-session state keyed by `{user_id, session_id}`.

**Scope:**
- `AllbertAssist.Session.Scratchpad` — ETS table, full CRUD, TTL expiry via `:timer`
- Started in `AllbertAssist.Application` supervision tree
- Runtime populates `active_app` and `working_memory` on each turn
- `AgentLive` stores its `session_id` and reads scratchpad for `active_app` context
- (No canvas — `canvas_tiles` key is reserved for allbert core v0.17)

**Acceptance:** Two concurrent `mix allbert.ask --user alice` calls get isolated scratchpad entries; stale entries expire after TTL.

---

### M-AppContract-Lite — Minimal App Registration Contract
**Allbert track: before M-D2a** (small core change; no surface DSL or canvas work)

**Goal:** Give StockSage just enough first-class app identity to register actions, skills, and navigation without inventing a partial private contract inside the StockSage app.

**Scope:**
- `AllbertAssist.App` behaviour with callbacks for `app_id`, `display_name`, `version`, `validate/1`, `child_spec/1`, `actions/0`, `skill_paths/0`, and `surfaces/0`
- `AllbertAssist.App.Registry` with static/configured registration at app startup
- `AllbertAssist.Actions.Registry` can tag registered actions with `app_id`
- `AllbertAssist.Skills.Registry` can add app skill paths
- Allbert shell can list registered app surfaces for navigation, while routes remain statically mounted/config-driven
- No `SurfaceProvider`, no `AllbertAssist.Surface` DSL, no AG-UI/A2UI dependencies

**Acceptance:** A tiny test app can register one action, one skill path, and one nav surface; the registry returns the app and the existing Allbert runtime continues to work unchanged.

---

### M-D2a — StockSage Umbrella App + Domain  
**StockSage track: v0.1.0** (depends on M-AppContract-Lite)

**Goal:** `stocksage` umbrella app with SQLite-first domain storage, migrations, and `AllbertAssist.App` registration.

**Scope:**
- `stocksage` and `stocksage_web` umbrella apps scaffolded
- `StockSage.App` implements M-AppContract-Lite
- SQLite-backed domain records: `Analysis`, `AnalysisDetail`, `Outcome`, `AnalysisQueue`, `QueueRun`, `MemoryEntry`
- String `user_id` on request/queue/user-facing rows; no `allbert_assist.users` FK yet
- Migration workflow for the chosen SQLite-backed storage layer
- StockSage skill pack: `run-analysis`, `get-trends`, `queue-analysis` SKILL.md files registered
- SQLite import task: `mix stocksage.import_sqlite /path/to/stocksage.db`

**Acceptance:** All StockSage records round-trip; existing Python `stocksage.db` data imports cleanly; StockSage skills appear in `mix allbert.skills list`; no local PostgreSQL server is required.

---

### M-D2b — Python Bridge (Transitional)  
**StockSage track: v0.2.0** (depends on M-D2a)

**Goal:** TradingAgents callable through a supervised Python bridge. Mix task produces a real analysis using the Python baseline engine.

**Scope:**
- `StockSage.TraderBridge` — bridge spike chooses ErlPort or a supervised JSON-over-stdio Port worker
- `priv/python/bridge.py` — Python entry point wrapping TradingAgents
- `StockSage.Actions.RunAnalysis` Jido action calling bridge
- Mix task: `mix stocksage.analyze AAPL 2026-05-01`
- Persists `Analysis` + `AnalysisDetail` records
- IntentAgent routes "analyze AAPL" → `run-analysis` skill → `StockSage.Actions.RunAnalysis`

**Acceptance:** `mix stocksage.analyze AAPL 2026-05-01` returns a decision, persists to DB, and is reachable via `mix allbert.ask --user local "analyze AAPL for last week"`.

---

### M-D2c — Native Jido Trading Agents  
**StockSage track: v0.3.0** (depends on M-D2b; can develop in parallel with allbert core v0.12–v0.15)

**Goal:** Replace Python bridge with native Jido AI agents for the full analysis pipeline.

**Scope:**
- All 8 analyst/researcher/trader agents as `Jido.AI.Agent` modules
- Jido Pod topology for the analysis workflow
- `StockSage.Actions.*` — FetchStockData, FetchNews, FetchSentiment, FetchFundamentals
- Bridge remains available for `--engine python` on `mix stocksage.analyze`
- SQLite-backed `analysis` queue with supervised OTP/Jido worker processes
- Outcome + memory workers using the same local worker substrate

**Acceptance:** Native analysis can be selected with `--engine native`; Python remains available; 20-stock smoke batch and golden fixtures produce decisions matching the Python baseline within a documented variance band. Native becomes the default only after this acceptance passes.

---

### M-AppContract-Full — Allbert App Contract and Surface DSL
**Allbert track: parallel to v0.15–v0.16** (builds on M-AppContract-Lite and StockSage usage; prerequisite for allbert core v0.17 canvas)

**Goal:** Mature the minimal app contract into the full `AllbertAssist.App` contract, the `AllbertAssist.Surface` DSL, and the tooling that lets any future app register with Allbert. StockSage is the first app to prove the contract. v0.17 builds the workspace shell consuming it.

**Scope:**
- `AllbertAssist.App` behaviour: full 5-layer spec (§5.2) — Identity/OTP, Agents/Actions/Signals, Skills, UI Surface, Data/Settings
- `AllbertAssist.App.Registry`: Elixir Registry + DynamicSupervisor (§5.7)
- `AllbertAssist.App.SurfaceProvider` behaviour: `init/1`, `render/2`, `handle_action/2` returning `{:signal, ...}` (§5.6)
- `AllbertAssist.Surface` module: A2UI-inspired component DSL, 18 standard types + custom (§6.6)
- `AllbertAssist.Surface.Encoder`: optional future bridge (mobile/desktop only, not used by LiveView)
- AG-UI/A2UI adapter decision documented; no package dependency unless an adapter is implemented in this milestone
- `mix allbert.validate_app MyApp` — checks all required callbacks present and `validate/1` passes
- `StockSage.App` fully implements the contract (proves it works end-to-end)
- ADR: `docs/adr/<next>-allbert-app-contract-and-surface-dsl.md` committed to allbert-assist-exs
- Documentation guide: `docs/how-to-create-an-allbert-app.md` (all 5 layers, StockSage as worked example)
- No generator (`mix allbert.gen.app`) — after contract is proven by M-D3b

**Acceptance:** `mix allbert.validate_app StockSage.App` passes; `AllbertAssist.App.Registry.registered_apps()` returns `[:stocksage]` at runtime; ADR 0014 is committed; v0.17 has a concrete local surface contract to consume without taking AG-UI/A2UI as a hard dependency.

---

### M-D3a — StockSage LiveView Shell  
**StockSage track: v0.4.0** (depends on M-AppContract-Lite and M-D2b; plain LiveViews — no canvas yet)

**Goal:** StockSage web surface inside the Allbert shell. Standard LiveViews with real-time PubSub; canvas integration is post-v0.17.

**Scope:**
- `StockSageLive.WorkspaceLive`, `AnalysisLive`, `QueueLive`, `TrendsLive`
- Router: Allbert shell mounts `/stocksage/...` via `App.Registry` (config-driven, not fully dynamic)
- Real-time analysis progress via PubSub + LiveView `stream/3`
- `active_app: :stocksage` set in session scratchpad when user navigates to `/stocksage/...`
- No canvas catalog registration yet — StockSage renders its own LiveView surfaces independently

**Acceptance:** Full analysis cycle from browser; live progress updates without page refresh; trends charts load.

---

### M-D3b — Polish, Outcome Tracking, Trends  
**StockSage track: v0.5.0** (depends on M-D3a)

**Goal:** Full parity with Python StockSage 0.0.2 feature set.

**Scope:**
- Outcome resolver (local scheduled worker): fetches returns, generates LLM reflection
- Memory sync: resolved outcomes → allbert memory entries
- Trends dashboard: alpha-aware accuracy, rating calibration, leaderboard
- Analysis re-run from LiveView
- Mobile-responsive layout
- Error state handling, empty states

**Acceptance:** All Python StockSage 0.0.2 user-facing features are replicated in Elixir. If native Jido parity has passed, no Python runtime is needed for analysis; otherwise the Python bridge remains the explicit fallback until parity closes.

---

### M-Canvas — StockSage Canvas Integration  
**After: allbert core v0.17 ships**

**Goal:** Register StockSage components with the v0.17 canvas substrate. No new agent or data work — purely wiring existing StockSage LiveView components into the allbert canvas catalog.

**Scope:**
- `StockSageWeb.Canvas.StockChart` — Phoenix.Component wrapping the chart LiveView
- `StockSageWeb.Canvas.AnalysisCard` — summary tile for a completed analysis
- `StockSage.App` canvas_components callback implemented
- Agent response format extended with `canvas_ops` for analysis results (where useful)
- `WorkspaceLive` dashboard leverages canvas tiles for recent analysis summaries

**Acceptance:** `mix allbert.ask --user alice "analyze AAPL"` triggers an analysis and pushes a `stock_chart` tile to the canvas; tile survives page reload when `persist: true`.

---

### M-Production — Release Hardening  
**After: M-D3b + allbert core v0.16**

- `mix release` + Docker + Fly.io deployment
- Hosted multi-user data decision: PostgreSQL, account records, login/session/API key model, and migration from string `user_id`
- libcluster + Horde for distributed agent supervision (if multi-node needed)
- Telemetry → OpenTelemetry export
- `StockSage.TraderBridge` pool adapted for cluster: analysis workers routed to analysis-tier nodes

---

## 12. Plan Incorporation into allbert v0.11–v0.17

### 12.1 Alignment Map

This plan's milestones feed into the allbert-assist-exs roadmap at specific points. They should be treated as aligned but coupled, not conflict-free:

| This plan | allbert core | Integration |
|-----------|-------------|-------------|
| M-D1a (multi-user chat) | parallel to v0.11 | Updates `allbert_assist` runtime identity and thread context; coordinate with intent/resource work |
| M-D1b (ETS scratchpad) | parallel to v0.11–v0.12 | Adds volatile session context; coordinate with job/session ownership semantics |
| M-AppContract-Lite | before M-D2a | Small allbert core contract needed before StockSage registers actions, skills, and surfaces |
| M-D2a (StockSage umbrella) | after M-AppContract-Lite | New umbrella apps using SQLite-first storage and the app contract |
| M-D2b/M-D2c (Python bridge → native agents) | parallel to v0.12–v0.15 | Uses local workers and explicit user/request context; no PostgreSQL requirement |
| **M-AppContract-Full** | **parallel to v0.15–v0.16** | **New ADR; prerequisite for v0.17 canvas** |
| M-D3a/M-D3b (StockSage LiveViews) | after M-D2b and app contract lite | Proves app surfaces before v0.17 consumes the full surface contract |
| M-Canvas | after v0.17 ships | v0.17 canvas substrate is the hard prerequisite |
| M-Production | after v0.16 + M-D3b | Hosted auth/accounts, PostgreSQL decision, libcluster, Fly.io |

### 12.2 What Goes Into allbert-assist-exs

**M-D1a and M-D1b** commit directly into `allbert-assist-exs` — new modules + migrations in the existing `allbert_assist` OTP app. These are in-repo changes, not a new repo.

**M-AppContract-Lite** commits directly into `allbert_assist` before StockSage is scaffolded. It gives domain apps a small public registration surface instead of forcing StockSage to create a private one-off integration.

**M-D2a–M-D2c** add new umbrella apps (`stocksage`, `stocksage_web`) to the same repo. The umbrella root `mix.exs` gains two new entries. StockSage uses the app contract and shared runtime boundaries rather than reaching into allbert internals.

**M-AppContract-Full** contributes to `allbert_assist`:
1. `AllbertAssist.App` behaviour module
2. `AllbertAssist.App.Registry` (Elixir Registry + DynamicSupervisor)
3. `AllbertAssist.App.SurfaceProvider` behaviour
4. `AllbertAssist.Surface` DSL module
5. `AllbertAssist.Surface.Encoder` (optional future bridge)
6. **ADR** — `docs/adr/<next>-allbert-app-contract-and-surface-dsl.md`
7. `docs/how-to-create-an-allbert-app.md` developer guide
8. `mix allbert.validate_app` mix task

### 12.3 What v0.17 Needs from This Plan

The allbert-assist-exs `v0.17-plan.md` ("Agentic Workspace Surface") explicitly defers A2UI compatibility and says "Allbert-native contracts first." **M-AppContract-Full delivers those contracts.**

Suggested addition to `v0.17-plan.md`:

> **Dependency on M-AppContract-Full:** v0.17 builds the workspace shell using `AllbertAssist.App.Registry.registered_apps/0` for nav and `AllbertAssist.Surface` for the component DSL. M-AppContract-Full must land before canvas LiveView work starts. The surface envelope format described in v0.17 (`surface_id`, `purpose`, `component_catalog`, `data_bindings`, `allowed_events`) maps directly to `AllbertAssist.Surface` node types and the `AllbertAssist.App.SurfaceProvider` behaviour defined in M-AppContract-Full.

### 12.4 Post-D3 Roadmap Addition (allbert v0.18)

Once StockSage proves the contract end-to-end (post-M-D3b), propose to the allbert roadmap:

**v0.18 — Allbert App Generator**

- `mix allbert.gen.app MyApp` — scaffolds all 5 contract layers as a working stub
- Generated output: `MyApp.App` module, sample Jido action, sample SKILL.md, sample surface, Ash domain stub, `mix allbert.validate_app MyApp` passes on first run
- Optional: `mix allbert.publish_skills` — publishes app's SKILL.md files to agentskills.io public registry

This milestone is explicitly **not** in scope until the contract is proven. Generator before proof = premature abstraction.

### 12.5 Coupling Rules for v0.11–v0.16

Milestones in this plan should preserve existing operator behavior, but they are not purely isolated. The coupling rules are:

- M-D1a/M-D1b: new modules + migrations; existing agents, settings, security, and skills keep their public behavior, but runtime request maps and traces gain `user_id`, `thread_id`, and `session_id`
- M-AppContract-Lite/Full: new behaviour modules; `allbert_assist` is the host, while StockSage is the first app proving the contract
- M-D3a: mounts StockSage routes in `allbert_assist_web` via the registry — one line in the router, existing routes unchanged
- v0.11–v0.16 can continue, but job ownership, security evals, traces, and memory review must be checked against the new `user_id`/thread context before release
- Hard sequencing: M-AppContract-Lite → M-D2a; M-D2b → M-D3a; M-AppContract-Full → v0.17 canvas

---

## 13. Open Questions

| # | Question | Current position |
|---|----------|-----------------|
| 1 | Rename the repo `allbert-assist-exs` → `allbert`? | Yes — extend in place; GitHub repo rename preserves history and adds redirect |
| 2 | Should `Thread`/`Message` use Ash or raw Ecto? | Raw Ecto for now (consistent with existing allbert_assist style); migrate to Ash later if needed |
| 3 | `user_id` — simple string or UUID? | Simple string for now (`"local"`, `"alice"`) — UUID or integer account ids when hosted accounts/auth lands |
| 4 | How does `allbert-assist-rs` (Rust v0.15) relate going forward? | Retire it as an experiment; use it only as prior art for concepts worth porting |
| 5 | Should `allbert_assist_web` router mount StockSage routes dynamically or statically? | Static mounts with conditional inclusion via config — simpler than runtime dynamic routing |
| 6 | D1a (multi-user) vs allbert core v0.11 (intent/resource): which goes first? | They are coupled but can be developed carefully in parallel; D1a must preserve existing `operator_id` compatibility while adding `user_id`/thread context |
| 7 | Should M-D2a (stocksage scaffolding) wait for D1a to land? | It should wait for M-AppContract-Lite; it can use string `user_id` even if D1a is still finishing |
| 8 | agentskills.io: publish StockSage skills to public registry? | Not yet; local priv/skills first; publishing is a post-M-D3b task |
| 9 | When do we introduce PostgreSQL? | Only when actual hosted/multi-user deployment makes it worth the operational cost |
| 10 | Should StockSage use Oban? | Not as a hard dependency in the local path; prefer OTP/Jido workers and SQLite queue records first |

---

## 14. Migration Path from Python StockSage

The Python `0.0.2` codebase is frozen at `stocksage.db`. Migration:

1. **M-D2a includes** `mix stocksage.import_sqlite /path/to/stocksage.db` — idempotently imports users, canonical analyses, analysis details, outcomes, queue rows, queue runs, and analysis request history.
2. **Canonical analysis identity is preserved** — shared analysis rows stay shared by ticker/date/model where possible; user-level ownership/history is represented by request rows.
3. **Failed and pending work is preserved** — failed analyses, unresolved outcomes, and queued items import with their status and error text so the new app can resume or retry honestly.
4. **TradingAgents memory log** (markdown file) is copied to `ALLBERT_HOME/memory/notes/` as a seed entry, with StockSage memory namespace metadata when the app contract supports it.
5. **API keys** move from Python `.env` to Settings Central. The exact Mix task name should match the then-current Allbert settings surface.
6. **Python app stays frozen** — it can run in parallel for reference; no new features. The bridge calls the frozen baseline until native parity is accepted.

---

## 15. References

- allbert-assist-exs: [github.com/lexlapax/allbert-assist-exs](https://github.com/lexlapax/allbert-assist-exs) — Elixir umbrella at v0.10
- allbert-assist-rs: [github.com/lexlapax/allbert-assist-rs](https://github.com/lexlapax/allbert-assist-rs) — Rust experiment at v0.15; prior art only for this plan
- Jido 2.2: [github.com/agentjido/jido](https://github.com/agentjido/jido)
- Jido AI 2.1: [github.com/agentjido/jido_ai](https://github.com/agentjido/jido_ai)
- agentskills.io standard: [agentskills.io/specification](https://agentskills.io/specification)
- A2UI Protocol: [a2ui.org](https://a2ui.org/) / ex_a2ui: [github.com/23min/ex_a2ui](https://github.com/23min/ex_a2ui)
- Phoenix LiveView 1.1: [hexdocs.pm/phoenix_live_view](https://hexdocs.pm/phoenix_live_view)
- Ash Framework 3.x: [ash-hq.org](https://ash-hq.org) — candidate only if it works with the SQLite-first posture
- Oban: [hexdocs.pm/oban](https://hexdocs.pm/oban) — revisit only if it preserves the no-server local posture
- Sagents (reference agent+LiveView pattern): [github.com/sagents-ai/sagents](https://github.com/sagents-ai/sagents)
- phoenix_streamdown (streaming markdown): [github.com/dannote/phoenix_streamdown](https://github.com/dannote/phoenix_streamdown)
- Loomkin (reference Jido+LiveView app): [github.com/bleuropa/loomkin](https://github.com/bleuropa/loomkin)
