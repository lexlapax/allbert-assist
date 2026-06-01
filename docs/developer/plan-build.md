# Plan/Build Developer Notes

Plan/Build is a v0.44 surface over the existing Objective Runtime. It is
not a new scheduler, permission layer, or code loader.

## Runtime Boundaries

- Workflow files live under `<ALLBERT_HOME>/workflows/<id>.yaml`.
- `AllbertAssist.Workflows` is a plain facade. It holds no process state
  and grants no authority.
- Loader/validator/expander modules treat YAML as inert data. The loader
  bounds file size and id shape; the validator rejects unknown keys,
  dynamic action names, secret/env references, cycles, forward
  references, too many steps, and oversized per-step params.
- Plan/Build actions are registered Jido actions under
  `AllbertAssist.Actions.PlanBuild.*`; callers should use
  `AllbertAssist.Actions.Runner.run/3`.
- Execution persists already-expanded steps into the v0.24 objective
  tables. The Objective Runtime remains the run loop.

## Actions

| Action | Boundary |
|---|---|
| `list_workflows` | Read-only workflow file discovery. |
| `inspect_workflow` | Read-only validation and parsed workflow summary. |
| `expand_workflow` | `:workflow_read`; validates and expands a workflow without running it. |
| `preview_plan` | Read-only advisory preview for workflow ids or ad-hoc plan text. |
| `start_plan_run` | `:workflow_run_start`; confirmation-gated workflow objective creation. |
| `cancel_plan_run` | `:plan_cancel`; cooperative objective cancellation. |
| `list_plan_runs` | Read-only workflow objective listing. |

`show plan <objective_id>` routes to the existing v0.24 `show_objective`
action.

## Intent Routing

The deterministic v0.44 corpus is:

| Pattern | Route |
|---|---|
| `plan: <text>` | `preview_plan` with synthesized advisory steps. |
| `plan <text>` | Same. |
| `run workflow <id>` | Plan/Build workflow path. |
| `run <id>` | Plan/Build only when `<ALLBERT_HOME>/workflows/<id>.yaml` exists. |
| `cancel plan <objective_id>` | `cancel_plan_run`. |
| `show plan <objective_id>` | `show_objective`. |
| `list workflows` | `list_workflows`. |
| `list plans` | `list_plan_runs`. |

Descriptors and routes are advisory. They do not authorize execution.

## Workspace Surfaces

Plan/Build contributes workspace panels through the surface/workspace
catalogs:

- Preview panel for the Plan Preview Contract and bounded inline edits.
- Run Progress panel for objective status, step events, delegate/subagent
  visibility, and cancellation.

LiveViews render and dispatch to actions; they must not call the
workflow loader, validator, expander, or Objective internals directly.

## Testing

Use the narrow v0.44 lanes first:

```sh
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/workflows/loader_test.exs apps/allbert_assist/test/allbert_assist/workflows/schema_test.exs apps/allbert_assist/test/allbert_assist/workflows/validator_test.exs apps/allbert_assist/test/allbert_assist/workflows/expander_test.exs apps/allbert_assist/test/allbert_assist/actions/plan_build_actions_test.exs
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/intent/plan_build_routing_test.exs apps/allbert_assist/test/mix/tasks/allbert_plan_test.exs
MIX_ENV=test mix test apps/allbert_assist_web/test/allbert_assist_web/live/plan_build_live_test.exs apps/allbert_assist_web/test/allbert_assist_web/live/objective_live_test.exs
MIX_ENV=test mix compile --warnings-as-errors
```

For release closeout, v0.44 adds the deterministic
`mix allbert.test release.v044` gate and then rejoins the normal release
gate.
