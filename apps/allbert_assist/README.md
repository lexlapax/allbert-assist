# AllbertAssist

Core runtime app for Allbert Assist.

The current v0.07 runtime exposes:

- `AllbertAssist.Runtime.submit_user_input/1`
- `AllbertAssist.Agents.IntentAgent`
- `AllbertAssist.Actions.Registry`
- `AllbertAssist.Actions.Runner`
- `AllbertAssist.Skills`
- `AllbertAssist.Actions.Intent.ActivateSkill`
- `AllbertAssist.Security`
- `AllbertAssist.Actions.Security.Status`
- `AllbertAssist.Actions.Skills.ValidateSkill`
- `AllbertAssist.Actions.Skills.CreateSkill`
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

Confirmation records live under `<ALLBERT_HOME>/confirmations` with
`pending/`, `resolved/`, and `audit/` children. Approval and denial are
registered actions through `AllbertAssist.Actions.Runner.run/3`; approval
re-checks Security Central and in v0.07 resolves external-network requests as
`adapter_unavailable` without making a network call.

See the umbrella root `README.md`, `docs/plans/v0.07-plan.md`, and
`docs/plans/v0.07-request-flow.md` for operator usage and current confirmation
workflow behavior.
