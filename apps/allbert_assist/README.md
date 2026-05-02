# AllbertAssist

Core runtime app for Allbert Assist.

The current v0.05 runtime exposes:

- `AllbertAssist.Runtime.submit_user_input/1`
- `AllbertAssist.Agents.IntentAgent`
- `AllbertAssist.Actions.Registry`
- `AllbertAssist.Actions.Runner`
- `AllbertAssist.Skills`
- `AllbertAssist.Actions.Intent.ActivateSkill`
- `AllbertAssist.Security`
- `AllbertAssist.Actions.Security.Status`
- `AllbertAssist.Memory`
- `AllbertAssist.Settings`
- `AllbertAssist.Trace`
- `mix allbert.ask`
- `mix allbert.settings`
- `mix allbert.security status`

See the umbrella root `README.md`, `docs/plans/v0.05-request-flow.md`, and
`docs/plans/v0.06-plan.md` for operator usage, current security behavior, and
the next action-backed skills milestone.
