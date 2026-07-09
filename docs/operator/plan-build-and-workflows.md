# Plan/Build And Workflow YAML

Allbert exposes the Objective Runtime (introduced in v0.44) as an operator-visible
Plan/Build surface. Workflow YAML is inert declarative data under
Allbert Home; it does not execute scripts, install packages, grant
permissions, or register new modules.

## Author Workflows

Place workflow files here:

```text
<ALLBERT_HOME>/workflows/<workflow-id>.yaml
```

Workflow ids must match:

```text
^[a-z0-9][a-z0-9_-]*$
```

The v0.44 schema version is `1`. A workflow is a bounded sequential
step list. v0.44 does not support loops, parallel branches,
sub-workflow includes, triggers, workflow-scope `env:`, shell script
steps, package installs, or dynamic action names.

Use the workflow CLI before running a workflow:

```sh
mix allbert.workflows list
mix allbert.workflows inspect multi_step
mix allbert.workflows expand multi_step --input since="1 day ago"
```

`inspect` validates the YAML and per-action `params:` against the
current registered action snapshot. `expand` resolves allowed
expressions and prints the would-be step count without starting a run.

## Preview And Run

Natural-language planning:

```text
plan: collect my open GitHub issues and summarize them
```

Authored workflow run:

```text
run workflow multi_step
```

Both paths produce a Plan Preview Contract packet. The preview is
advisory. The authority boundary is still the registered action and
permission gate. Starting a workflow always uses the
`:workflow_run_start` confirmation gate; individual step confirmations
still apply later according to each action's registered floor.

The workspace has two Plan/Build surfaces:

| Surface | Purpose |
|---|---|
| Plan/Build Preview | Shows workflow id, step count, action/kind, params summary, resources, permission, safety floor, confidence/cost/blast-radius fields, and confirmation points. |
| Plan Run Progress | Shows objective status, step status, event timeline, inline delegate/subagent visibility, and cancel controls. |

The preview editor is intentionally bounded. Operators may keep, remove,
reorder, or add `confirm: true` to existing steps. Unknown step ids fail
closed, and edits recompute through the registered `preview_plan` action.

## Inspect And Cancel Runs

Plan runs are v0.24 objectives with a workflow source intent.

```sh
mix allbert.plan list
mix allbert.plan list --format ids
mix allbert.plan show obj_00000000-0000-0000-0000-000000000000
mix allbert.plan cancel obj_00000000-0000-0000-0000-000000000000 --reason "operator cancelled"
```

Cancellation is cooperative. The currently executing step may finish, no
new step should start, and the cancellation reason is recorded in
objective events.

## Security Notes

- `workflow://<id>` and `plan://run/<objective_id>` are identities for
  traces, audits, and UI references. They do not grant authority.
- YAML `confirm: true` can only raise friction. YAML cannot lower an
  action's registered permission floor.
- `${secrets.*}` and `${env.*}` references are rejected in v0.44.
- Plan preview and trace output redact secret-shaped operator inputs and
  params summaries.
- Workflow YAML is never loaded from remote marketplaces or generated
  drafts in v0.44. Future draft/promotion paths must remain
  operator-reviewed and confirmation-gated.
