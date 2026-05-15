# AllbertAssist

Core runtime app for Allbert Assist.

The current v0.20 runtime exposes:

- `AllbertAssist.Runtime.submit_user_input/1`
- `AllbertAssist.Agents.IntentAgent`
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
- `mix stocksage.import_sqlite`
- `mix stocksage.analyses`
- `mix stocksage.queue`
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

See the umbrella root `README.md`, `docs/plans/v0.20-plan.md`,
`docs/plans/v0.20-request-flow.md`, `plugins/stocksage/README.md`, and
`docs/developer/how-to-create-an-allbert-app.md` for current StockSage,
app/surface, and intent-routing behavior.
