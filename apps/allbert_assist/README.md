# AllbertAssist

Core runtime app for Allbert Assist.

The current v0.06 runtime exposes:

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
- `AllbertAssist.Memory`
- `AllbertAssist.Settings`
- `AllbertAssist.Trace`
- `mix allbert.ask`
- `mix allbert.settings`
- `mix allbert.security status`
- `mix allbert.skills`

See the umbrella root `README.md`, `docs/plans/v0.06-request-flow.md`, and
`docs/plans/v0.07-plan.md` for operator usage, current action-backed skill
behavior, and the next confirmation workflow milestone.
