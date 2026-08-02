# Plan/Build And Workflow YAML

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

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
allbert admin workflows list
allbert admin workflows inspect multi_step
allbert admin workflows expand multi_step --input since="1 day ago"
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
allbert admin plan list
allbert admin plan list --format ids
allbert admin plan show obj_00000000-0000-0000-0000-000000000000
allbert admin plan cancel obj_00000000-0000-0000-0000-000000000000 --reason "operator cancelled"
```

Cancellation starts cooperatively at action checkpoints, then escalates through
supervised process shutdown and scoped OS child-process termination when work
does not stop within the configured grace period. No new step starts after a
cancel request. The reached tier and reason are recorded in objective events;
an uncertain effect remains blocked for operator review rather than being
silently retried.

## Background Fan-Out And Steering

An eligible multi-part advisory/read-only request can return a kickoff receipt
listing its child tasks. On the ordinary conversational route, Allbert's
qualified manager model applies the same documented rules used by operator
qualification: the tasks must be independent, concurrently useful, fully cover
the outer request, and treat quoted/pasted/list content as data. Dependent,
ambiguous, effectful, mixed, or explicitly unsplit work remains one turn. A
manager failure preserves its useful same-call answer and creates no partial
Objective tree.

Fan-out resolves two closed, independently operator-configurable model task
chains before durable framing. `fanout_manager` decides whether and how to
split; `fanout_synthesis` generates the joined advisory paragraph and
relationship layout in one call. Child drafting remains on the existing
`direct_answer` route. All three routes default to `direct_answer_local`, but
sharing a profile does not merge their roles. An
unavailable fan-out role leaves the request on the ordinary single-answer path;
Allbert neither creates a partial Objective tree nor auto-pulls a model or asks
again on every turn.

Two exact operator protocols remain a model-independent force path:
`Do N things: ... . Work on them in parallel and report back.` and
`Do these N tasks in parallel: ...; ...`. Their declared count must match a
complete distinct task list. A malformed, partial, or mismatched protocol stays
one manager-off turn and creates no parent or child. Counted effectful tasks do
not gain authority: each action still passes Registry, Runner, Security Central,
and its normal confirmation contract. Manager-authored children are
DirectAnswer-only; they cannot turn generated prose into an effect.

Child execution begins only after the kickoff receipt has been delivered or
durably recorded. The children then run concurrently within Settings Central's
global and per-fan-out bounds. A DirectAnswer Worker makes one immutable draft,
then two separate private Jido critics assess disjoint policy-owned rule groups.
An all-satisfied first round accepts the unchanged draft in exactly three
provider attempts: one draft plus two critics. Otherwise one separate revision
is followed by two fresh critics, for exactly six attempts. A remaining
violation, unresolved assessment, timeout, or malformed group fails the child
honestly unresolved; no model revises and verifies the same bytes in one call.

The final child freezes one ordered durable snapshot and queues central report
composition; it does not ask a child or the current surface to write the
report. The composer uses the same three-attempt/six-attempt shape: one initial
synthesis plus two critics, with at most one revision and two fresh critics.
The verified model result may supply only the advisory paragraph and a
versioned relationship grouping/order. Allbert's deterministic renderer still
owns child identity, status, ordering, effect-receipt truth, the authoritative
appendix, byte bounds, and the truthful complete-child fallback. The selected
model result or fallback and its provenance are stored before delivery becomes
pending. A crash or restart therefore resumes composition or delivery from
durable state instead of replaying an uncertain provider call or inventing
another fan-in result.

The stored report lists every child as completed, failed, abandoned, or
cancelled—partial success is never presented as total success. A mix of terminal
outcomes is reported as `partial`; a fan-out whose children were all cancelled
is reported as `cancelled`. A child's summary of an effect is labelled as an
observation, not proof; only an attached durable action receipt is effect
evidence. Inspect the central state with
`allbert admin objectives show OBJECTIVE_ID`; `Report composition` identifies
whether selection is still in progress or ready, and `Report source` identifies
the model selection or deterministic fallback.

A supervisor admission failure before a child worker or effect exists is retried
automatically with capped backoff; it is not shown as `uncertain_effect`.
Crashes after a worker starts still follow the action's retry-safety contract.

While a fan-out is active, reply in its originating thread to steer it. Plain
language can request status, adjust a child, cancel work, or begin a separate
request. Classification is advisory: effectful changes dispatch through
registered actions, ownership is re-proved, and text such as “yes” never
approves a pending confirmation. In Web, open `/objectives/:id` for the
parent/child tree and use a child's steer or cancel control; controls re-check
that the named child belongs to that parent and is still active. In an attached
TUI, status arrives in the live region, normal input can steer, and Escape offers
cancellation. The TUI tracks concurrent fan-outs independently. If more than one
is active, an unqualified Escape cancellation asks you to name the fan-out or
child instead of guessing.

Attached Web and TUI sessions show the joined report before recording its exact
delivery receipt. They render the exact centrally stored body rather than
re-composing it. Failed rendering/output leaves that report pending for recovery
or the next turn. This attended behavior does not enable autonomous remote
notifications; remote report-back remains a separate, default-off per-channel
setting described in the security guide.

Relevant Settings Central keys and shipped defaults:

| Key | Default | Meaning |
| --- | --- | --- |
| `objectives.fanout.enabled` | `true` | Enable the shared fan-out runtime. |
| `objectives.fanout.rollout_mode` | `automatic` | `explicit`, `shadow`, or rules-derived automatic advisory planning. |
| `objectives.fanout.max_concurrent_runs_per_fanout` | `3` | Fair per-parent running-child bound. |
| `objectives.fanout.max_concurrent_runs_global` | `6` | Runtime-wide running-child bound. |
| `objectives.fanout.max_children_per_fanout` | `8` | Decomposition ceiling (allowed 2–16). |
| `objectives.fanout.confirm_before_start` | `false` | Require an explicit start confirmation in addition to kickoff delivery. |
| `objectives.fanout.max_model_calls_per_plan` | `64` | Structural ceiling for up to two manager attempts, one call per DirectAnswer child, and one composer call (allowed 1–256). Child action selection is deterministic/model-off. |
| `objectives.fanout.max_output_tokens_per_plan` | `32768` | Structural output-token ceiling for those fan-out-owned calls (allowed 1,024–1,000,000); the default maximum eight-child/two-manager plan reserves 30,720. |
| `objectives.fanout.max_elapsed_ms_per_plan` | `300000` | Frozen plan window in milliseconds (allowed 1,000–3,600,000). It is a dispatch boundary for ordinary actions and a hard execution bound for the read-only Jido worker. |
| `objectives.fanout.max_worker_attempts_per_child` | `2` | Frozen child-attempt ceiling consumed by Coordinator recovery (allowed 1–4). |
| `model_preferences.tasks.fanout_manager` | `["direct_answer_local"]` | Closed planning route; unavailable readiness keeps the turn out of durable fan-out. |
| `model_preferences.tasks.fanout_synthesis` | `["direct_answer_local"]` | Closed route for the single joined synthesis call. |

These knobs change scheduling, resource limits, or friction, not action
authority. Registered actions retain their own provider-use budgets; the
fan-out layer does not count arbitrary provider calls hidden inside an action.
Inspect the settings
with `allbert admin settings get <key>` (or `mix allbert.settings get <key>` in
a checkout) and change them only through Settings Central.

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
