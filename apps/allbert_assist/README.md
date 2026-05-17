# AllbertAssist

Core runtime app for Allbert Assist.

The current v0.24 runtime exposes:

- `AllbertAssist.Runtime.submit_user_input/1`
- `AllbertAssist.JidoBacked`
- `AllbertAssist.JidoBacked.Supervisor`
- `AllbertAssist.Agents.IntentAgent`
- `AllbertAssist.Confirmations.Store.Agent`
- `AllbertAssist.Jobs.Scheduler.Agent`
- `AllbertAssist.Objectives`
- `AllbertAssist.Objectives.Objective`
- `AllbertAssist.Objectives.Step`
- `AllbertAssist.Objectives.Event`
- `AllbertAssist.Objectives.Engine.Agent`
- `AllbertAssist.Objectives.AgentRegistry`
- `AllbertAssist.Actions.Objectives.ListObjectives`
- `AllbertAssist.Actions.Objectives.ShowObjective`
- `AllbertAssist.Actions.Objectives.ContinueObjective`
- `AllbertAssist.Actions.Objectives.CancelObjective`
- `AllbertAssist.Actions.Objectives.DelegateAgent`
- `mix allbert.objectives`
- `AllbertAssist.Actions.Registry`
- `AllbertAssist.Actions.Runner`
- `AllbertAssist.Intent.Candidate`
- `AllbertAssist.Intent.Engine`
- `AllbertAssist.Intent.Ranker`
- `AllbertAssist.Intent.Classifier`
- `AllbertAssist.App`
- `AllbertAssist.App.Registry`
- `AllbertAssist.App.SurfaceProvider`
- `AllbertAssist.Surface`
- `AllbertAssist.Surface.Encoder`
- `Mix.Tasks.Allbert.ValidateApp`
- `StockSage.Plugin`
- `StockSage.App`
- `StockSage.Actions.ListAnalyses`
- `StockSage.Actions.ShowAnalysis`
- `StockSage.Actions.GetTrends`
- `StockSage.Actions.QueueAnalysis`
- `StockSage.Actions.ListQueue`
- `StockSage.Actions.ImportSqlite`
- `StockSage.Actions.RunAnalysis`
- `StockSage.Bridge.Protocol`
- `StockSage.TraderBridge`
- `mix stocksage.import_sqlite`
- `mix stocksage.analyses`
- `mix stocksage.queue`
- `mix stocksage.analyze`
- `AllbertAssist.Skills`
- `AllbertAssist.Actions.Intent.ActivateSkill`
- `AllbertAssist.Actions.Intent.ExplainIntent`
- `AllbertAssist.Actions.Intent.ListIntentCandidates`
- `AllbertAssist.Security`
- `AllbertAssist.Actions.Security.Status`
- `AllbertAssist.Actions.Skills.ValidateSkill`
- `AllbertAssist.Actions.Skills.CreateSkill`
- `AllbertAssist.Actions.Intent.ExternalNetworkRequest`
- `AllbertAssist.Actions.Packages.PlanPackageInstall`
- `AllbertAssist.Actions.Packages.RunPackageInstall`
- `AllbertAssist.Actions.Skills.SearchOnlineSkills`
- `AllbertAssist.Actions.Skills.ShowOnlineSkill`
- `AllbertAssist.Actions.Skills.AuditOnlineSkill`
- `AllbertAssist.Actions.Skills.ImportOnlineSkill`
- `AllbertAssist.Confirmations`
- `AllbertAssist.Actions.Confirmations.ListConfirmations`
- `AllbertAssist.Actions.Confirmations.ShowConfirmation`
- `AllbertAssist.Actions.Confirmations.ApproveConfirmation`
- `AllbertAssist.Actions.Confirmations.DenyConfirmation`
- `AllbertAssist.Actions.Confirmations.ExpireConfirmations`
- `AllbertAssist.Memory`
- `AllbertAssist.Memory.Entry`
- `AllbertAssist.Memory.Review`
- `AllbertAssist.Memory.Index`
- `AllbertAssist.Memory.Compiler`
- `AllbertAssist.Memory.Promotion`
- `AllbertAssist.Actions.Memory.ListMemoryEntries`
- `AllbertAssist.Actions.Memory.ReadMemoryEntry`
- `AllbertAssist.Actions.Memory.SearchMemory`
- `AllbertAssist.Actions.Memory.ReviewMemoryEntry`
- `AllbertAssist.Actions.Memory.UpdateMemoryEntry`
- `AllbertAssist.Actions.Memory.DeleteMemoryEntry`
- `AllbertAssist.Actions.Memory.PruneMemoryEntries`
- `AllbertAssist.Actions.Memory.PromoteConversationTurn`
- `AllbertAssist.Actions.Memory.CompileMemoryIndex`
- `AllbertAssist.Actions.Memory.SummarizeMemoryCategory`
- `AllbertAssist.Actions.Memory.ListMemoryCategorySummary`
- `mix allbert.memory`
- `AllbertAssist.Settings`
- `AllbertAssist.Trace`
- `mix allbert.ask`
- `mix allbert.settings`
- `mix allbert.security status`
- `mix allbert.skills`
- `mix allbert.confirmations`
- `mix allbert.validate_app`

Confirmation records live under `<ALLBERT_HOME>/confirmations` with
`pending/`, `resolved/`, and `audit/` children. Approval and denial are
registered actions through `AllbertAssist.Actions.Runner.run/3`; approval
re-checks Security Central. Historical pre-v0.10 `adapter_unavailable` records
remain readable as audit history, while new v0.10 external service, package
install, and online skill import requests resume only through their registered
actions after confirmation.

The StockSage plugin now contributes the v0.22 Python bridge: the supervised
`StockSage.TraderBridge` GenServer wraps a `priv/python/bridge.py` subprocess,
and the registered `StockSage.Actions.RunAnalysis` action gates execution
behind the new `:stocksage_analyze` permission and v0.07 confirmation
workflow. All bridge code lives under `./plugins/stocksage/`; Allbert core
does not import bridge internals — the only contact points are the action
runner, Security Central, the action registry, and `AllbertAssist.Repo`.

v0.23 adds the shared `AllbertAssist.JidoBacked` substrate. The confirmation
store and scheduled-job scheduler are now Jido-backed coordinator agents, while
their public facade modules and durable YAML/SQLite stores remain unchanged.

v0.24 adds `AllbertAssist.Objectives`, the durable objective runtime for
multi-step and cross-turn work. `Objectives.Engine.Agent` is Jido-backed with
10 private command modules, while `AllbertAssist.Objectives` exposes the public
lifecycle facade for list/get/frame/advance/cancel/continue. All effectful
objective steps still execute through registered actions, Security Central,
resource posture, and durable confirmations. StockSage now threads
`objective_id` and `step_id` through its analysis flow.

See the umbrella root `README.md`, `docs/plans/v0.20-plan.md`,
`docs/plans/v0.20-request-flow.md`, `docs/plans/v0.21-plan.md`,
`docs/plans/v0.21-request-flow.md`, `docs/plans/v0.22-plan.md`,
`docs/plans/v0.22-request-flow.md`, `docs/plans/v0.23-plan.md`,
`docs/plans/v0.23-request-flow.md`, `docs/plans/v0.24-plan.md`,
`docs/plans/v0.24-request-flow.md`, `plugins/stocksage/README.md`, and
`docs/developer/how-to-create-an-allbert-app.md` for current memory review,
StockSage, app/surface, intent-routing, and objective-runtime behavior.
