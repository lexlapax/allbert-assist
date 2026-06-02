# ADR 0041: Plan/Build Mode And Operator Workflow YAML

## Status

Accepted for v0.44 Plan/Build Mode And Operator Workflow YAML
(`docs/plans/v0.44-plan.md`). M1 landed the substrate vocabulary,
settings namespace, URI schemes, and locked decisions that make this
decision binding for implementation. The post-implementation audit added
a v0.44 remediation amendment: release readiness requires approved-plan
runtime handoff, per-step YAML semantics, step-output reference
resolution, repaired release evidence, and release-record closeout.

## Context

Objective Runtime (v0.24) already stores durable multi-step work as
`objectives`, `objective_steps`, and `objective_events` rows; runs a
seven-stage state machine on `AllbertAssist.Objectives.Engine.Agent`;
exposes a public lifecycle facade (`Objectives.frame/2`, `advance/2`,
`cancel/3`, `continue/2`); and ships six step kinds (`action`,
`ask_user`, `wait`, `observe`, `reflect`, `delegate_agent`) plus the
minimal `:delegate_agent` contract (ADR 0021 §A3) and the
`AllbertAssist.Objectives.AgentRegistry`. v0.25 native financial
specialist agents and v0.31 typed runtime responses (ADR 0029) confirm
the runtime is mature enough to surface to operators.

v0.44 exposes that substrate to operators as **Plan/Build mode** — a
workspace surface that previews multi-step work, shows required
resources and confirmation points, and runs the plan step by step under
operator authority — and adds **declarative workflow YAML** for
repeatable objectives.

The v1 schema needs:

- a stable artifact format operators can author by hand, version-
  control separately if they wish, and inspect in `cat`;
- a way to declare typed inputs, ordered steps, per-step conditions,
  and step-output references — without inventing a code-bearing DSL;
- enough strictness to fail closed on operator typos and on
  attacker-shaped injections, without forcing operators to learn a
  parallel permission system;
- a clean boundary between document (declarative, inert) and runtime
  (existing v0.24 engine + Security Central + `Actions.Runner.run/3`).

The 2025-2026 prior art (GitHub Actions workflow syntax, Argo Workflows,
Serverless Workflow DSL, OpenClaw Lobster, Anthropic Claude Plan Mode,
Cursor 2.2 Plan Mode panel, Devin plan card, Anthropic Agent Skills
`allowed-tools` precedent) converges on a small set of design rules:

- declarative documents validate against an explicit JSON Schema
  (`additionalProperties: false` at every level);
- expression substitution uses a **closed function table** (no `eval`,
  no Jinja-with-callables; the GitHub Actions `${{ ... }}` model);
- per-step permissions stay at the action's registered floor; YAML can
  only **upgrade** confirmation requirements, never downgrade
  (Agent-Skills `allowed-tools` precedent);
- plans render in a **panel** adjacent to the conversation, not in a
  separate destination (Cursor / Claude Code / Devin precedent);
- subagent delegation events render **inline** under the parent step
  (the "invisible subagents" UX lesson).

Allbert's existing substrates make these rules cheap: ADR 0017 plugin
contract, ADR 0023/0024 workspace canvas + panel zones, ADR 0027 action
DSL + capability registry, ADR 0029 typed responses, ADR 0030 unified
surface catalog, ADR 0031 settings fragments, and ADR 0049 development
gates all consume directly.

## Decision

### 1. Plan/Build is a workspace surface, not a new runtime

Plan/Build adds two LiveView panels under the v0.23/v0.26 workspace
canvas via the v0.30 unified surface catalog:

- `AllbertAssist.Workspace.PlanBuild.Panels.Preview` — pinnable card
  that renders the Plan Preview Contract packet. Expandable to
  fullscreen for inline editing of `inputs:` and per-step `confirm:`
  upgrades (the Claude Plan-Mode `Ctrl+G` analog).
- `AllbertAssist.Workspace.PlanBuild.Panels.RunProgress` — live run
  timeline that subscribes to `allbert.objective.**` through
  `AllbertAssistWeb.SignalBridge` and renders per-step events. Cancel
  control wires to `cancel_plan_run`. Subagent delegation events
  render inline under the parent step.

Plan/Build is **not** a destination route. The 2025-2026 prior art
(Cursor 2.2 Plan Mode panel, Claude Code plan side-panel, Devin plan
card) all converged on plan-adjacent panels because plans need ambient
context (which connector, which prior step output, which thread). A
destination would duplicate canvas chrome and split the operator's
mental model.

The destination option remains promotable: if a future release ships
team-wide plan boards, a destination can be added without removing the
panel.

### 2. Workflow YAML is declarative data; the runtime never executes it

Workflow YAML files live at
`<ALLBERT_HOME>/workflows/<workflow-id>.yaml`. `<workflow-id>` matches
`^[a-z0-9][a-z0-9_-]*$`. Collisions on `id` fail closed at import.

The runtime reads a file only when an operator references the workflow
id (e.g., "run workflow nightly-briefing"). **Discovery is on-demand**:
no scanning, no autoload, no compilation, no execution outside of
expanding the document into objective-step attrs.

The expansion path:

1. Loader bounds the read to
   `workflows.max_yaml_bytes_per_file` (default 256 KiB).
2. YAML parses through `:yaml_elixir` with string-key output, no atom
   creation, no custom node behavior, and an explicit anchor/merge-key
   policy before validation.
3. Validator runs a JSON Schema (Draft 2020-12) assembled from the
   current `Actions.Registry.modules/0` snapshot + `Step.kinds()`.
   Unknown keys reject with JSON-Pointer-path-bearing diagnostics.
4. AST parser resolves `${...}` references against a closed grammar.
5. Expander resolves inputs and references, producing a list of
   `objective_steps.attrs` maps.
6. `start_plan_run` (the plan-approval gate) confirms with
   `:workflow_run_start` `:needs_confirmation` floor. On approval,
   the v0.24 `Objectives.frame/2` path creates the objective, persists
   the expanded proposed steps, and hands the first eligible workflow
   step to the existing objective step lifecycle.

The runtime never executes the document; it executes the produced step
attrs the same way every other v0.24 objective executes them.

### v0.44 Remediation Amendment: approved plans must execute through Objective Runtime

The implementation audit found a real distinction that this ADR now
makes explicit. It is acceptable for the loader, validator, and expander
to treat YAML as inert data; it is not acceptable for an approved plan
run to stop after proposed-step persistence when the operator-facing
contract says the run has started.

Therefore v0.44 release readiness requires:

- approval of the plan-start gate selects and advances the first
  eligible `provider: "plan_build"` proposed step through the existing
  Objective Runtime command modules;
- workflow-specific metadata stored in
  `objective_steps.resource_access` is part of the runtime contract:
  `if:` gates selection, `on_error:` controls abort-vs-continue after a
  failed workflow step, and `confirm: true` upgrades confirmation at
  execution time;
- `${steps.<id>.<field>}` references resolve at runtime from prior
  completed workflow steps and declared `save_as:` aliases;
- the deterministic `release.v044` gate must prove execution semantics,
  not only preview and persistence.

This amendment does not authorize a second workflow engine. The only
allowed implementation path is to add the smallest Plan/Build-aware
selection/reference behavior needed around the existing objective step
lifecycle and `Actions.Runner.run/3`.

### 3. Schema is derived from the action registry; expression grammar is closed

The v1 schema is assembled from
`AllbertAssist.Actions.Registry.modules/0` (each action's `schema/0`) and
`AllbertAssist.Objectives.Step.kinds/0` at validation time. Static core
branches are ordinary code; plugin and dynamic actions are included from
the current registry snapshot. Hand-maintained schema drift is
impossible by construction. When an action's params change, the workflow
schema reflects the change automatically; when a new action is
registered, the workflow schema gains it.

Expression substitution uses a **closed function table**:

- References: `${inputs.<name>}`, `${steps.<id>.<field>}`,
  `${user.locale|timezone}`, `${workflow.id|version}`.
- Functions: `length`, `contains`, `starts_with`, `ends_with`,
  `lower`, `upper`, `default`, `to_json`, `from_json`.
- Operators: `==`, `!=`, `<`, `<=`, `>`, `>=`, `&&`, `||`, `!`.
- No `eval`. No user-defined functions. No string concatenation that
  produces an action name.

The AST parser verifies every reference resolves to a declared input
or an earlier step's `save_as`-bound field; unknown identifiers,
cycles, and forward refs reject with structured `error_category`
diagnostics.

### 4. Step kinds are frozen at the v0.24 six

`action | ask_user | wait | observe | reflect | delegate_agent`. The
v1 workflow schema lowers each YAML step into one of the six v0.24
kinds. v0.44 ships no new step kinds.

The kinds are exhaustive for v0.44's use cases:

- `action` — every effectful capability;
- `ask_user` — plan-level checkpoints;
- `wait` — async signals (e.g., scheduled-job completion);
- `observe` — incoming signals from other subsystems;
- `reflect` — proposes memory/workflow candidates (v0.21 review
  surface remains the only writer);
- `delegate_agent` — registered specialist via v0.24 AgentRegistry.

### 5. Confirmation invariant — registered action's floor is authoritative

YAML `confirm: true` may only **upgrade** a step's confirmation
requirement above its action's registered floor; it can never
**downgrade**. A `:needs_confirmation` action stays
`:needs_confirmation` regardless of YAML. The plan-start gate is a
separate `:workflow_run_start` confirmation per *run*, not per step.

This rule prevents the most direct attack on the boundary: a malicious
workflow file (operator-authored or future-marketplace-distributed)
cannot weaken any per-step floor.

`kind: ask_user` is the plan-author's explicit checkpoint mechanism
when the workflow needs operator input mid-run. It uses the same
Approval Handoff substrate as other confirmations.

### 6. Authority boundary — every step goes through `Actions.Runner.run/3`

Every produced step executes through `Actions.Runner.run/3`, Security
Central, confirmations, resource access posture, traces, and audits.
The objective engine arranges state; the action runner arranges
permission. **No artifact above the runner grants permission**:

- `workflow_id` is not authority.
- `plan_id` is not authority.
- `step_id` is not authority.
- Plan Preview Contract output is advisory only (ADR 0021 §4 applied).
- Operator approval of the plan-start gate authorizes the **run**,
  not any specific step's execution.

## Schema Invariants

The v1 schema enforces these invariants at load time:

1. `additionalProperties: false` at every object level. Unknown keys
   reject with a JSON-Pointer path.
2. Top-level `version` is required; missing rejects.
3. Workflow `id` matches `^[a-z0-9][a-z0-9_-]*$`; matches the filename
   basename.
4. Step `id`s match `^[a-z][a-z0-9_]*$`; unique within workflow.
5. Step `kind` is one of the six v0.24 kinds; unknown rejects.
6. References to `inputs.<name>` require a declared input.
7. References to `steps.<id>.<field>` require an earlier step with a
   matching `save_as:` (forward refs reject at load).
8. Cycles in step dependencies (derived from references) reject.
9. Action names must resolve to a registered action; unknown rejects.
10. `params:` for `kind: action` validates against the action's
    registered `schema/0` at load time.
11. `delegate_agent_id` must resolve to a registered agent in
    `AllbertAssist.Objectives.AgentRegistry`.
12. Expressions must parse against the closed grammar; unknown
    functions, dynamic action-name lookups (`action: ${...}`),
    `${secrets.x}`, and `${env.x}` reject.
13. `workflows.max_steps_per_workflow` cap (default 3; max 10 in v0.44)
    enforced.
14. `workflows.max_param_bytes_per_step` (default 64 KiB; max 1 MiB)
    enforced.
15. `workflows.max_yaml_bytes_per_file` (default 256 KiB; max 1 MiB)
    enforced before parsing.

Validation errors carry `error_category` (one of
`:unknown_key`, `:type_mismatch`, `:missing_required`,
`:invalid_reference`, `:unknown_action`, `:unknown_step_kind`,
`:cycle`, `:forward_ref`, `:unknown_delegate_agent`,
`:invalid_id_pattern`, `:cap_exceeded`, `:invalid_expression`,
`:dynamic_action_name`, `:secret_substitution_attempt`,
`:env_substitution_attempt`).

## Authority Boundary And Identity

- **`workflow_id` is not authority.** It identifies a file under
  `<ALLBERT_HOME>/workflows/`; reading it produces objective-step
  attrs but no authority.
- **`plan_id` is not authority.** A plan identifier is a transient
  preview-time handle; the operator's approval of the plan-start gate
  is the authority transition.
- **`step_id` is not authority.** Step ids are addressing tokens for
  `${steps.<id>.<field>}` references, not permission grants.
- **Plan Preview Contract is advisory.** Preview packets are
  descriptive metadata per ADR 0021 §4. They never grant permission;
  they never bypass a confirmation.
- **Subagent delegation reuses v0.24's `:delegate_agent` step kind +
  Security Central + Approval Handoff.** YAML never opens a parallel
  delegation path; the registered `delegate_agent` action is the only
  crossing.
- **YAML never grants permission.** YAML cannot widen any action
  floor; `confirm: true` may only upgrade.
- **Workflow URIs.** `workflow://<id>` identifies a file (read-only
  resource); `plan://run/<objective_id>` identifies a plan-run for
  trace/audit identity. Both schemes are added to
  `AllbertAssist.Resources.ResourceURI` per the v0.44 amendment to
  ADR 0013.

## Trust And Trace Posture

Workflow YAML files are **operator-readable inert data**. They are not
secrets; they are not code; they are not a third-party trust
boundary. The loader is read-only. The expander is deterministic
(same inputs → same step attrs).

Trace records carry:

- `workflow_id`, `workflow_version`, `plan_id`, `objective_id`,
  `step_id` — identity metadata.
- redacted `inputs:` map (secret-shaped values scrubbed by
  `AllbertAssist.Security.Redactor`).
- redacted `params:` summary per step.
- success/failure, confirmation id, durations.
- `## Plan Preview` trace section (added in v0.44 alongside v0.24's
  `## Objective` and `## Objective Steps` sections).

Plan Preview Contract packets in trace are advisory metadata; they
echo the same redaction posture. Raw YAML body content is never
re-echoed in trace; the trace points to the file location (and
trace ingestion can re-read the file if needed for debugging).

## Consequences

- Operators can review, edit, and approve multi-step work without
  any new execution engine.
- Existing Objective Runtime and action boundaries remain the only
  sanctioned substrate; the v0.44 surface adds renderers, validators,
  and an expander, not authority.
- Schema-from-registry derivation makes "documented action params"
  and "valid YAML inputs" the same thing by construction; v0.43 R3
  drift class of bug becomes impossible.
- Subagent delegation visibility (inline child events under parent
  step) resolves the "invisible subagents" UX lesson and unblocks
  v0.25-class specialist agents from rendering uniformly across all
  surfaces.
- **v0.45 Marketplace Lite** consumers MAY reference workflow ids in
  metadata (descriptive only); remote workflow distribution is
  parked under "Remote Workflow Distribution / Marketplace Workflows"
  in future-features.
- **v0.46 Operator-Supervised Self-Improvement** trace-to-workflow
  drafts consume the v0.44 schema; drafts write to
  `<ALLBERT_HOME>/drafts/workflows/<id>.yaml`, never to the live
  `workflows/` directory. Promotion is a confirmed operator action.
- **v0.49 Channel Pack 1** amends ADR 0016 to lock channel approval
  primitives; v0.44 plan cards render through existing channel-specific
  affordances and are expressible in
  `:typed_command`/`:button`/`:link`/`:list` without re-litigation.
- **v0.51 Hardening / Export-Import** preserves the
  `<ALLBERT_HOME>/workflows/` directory and the `workflows.*` +
  `plan.*` core settings namespace with `schema_version: 1` per the
  ADR 0046 migration policy.

## Non-Goals

- No autonomous plan approval.
- No workflow YAML script execution, shell, or package install.
- No private workflow scheduler or parallel objective store outside
  `AllbertAssist.Objectives`.
- No lowering action-level confirmation floors.
- No `for_each`, `for`, `while`, or other loop kinds in YAML v1.
- No `parallel:`, `Fork`, or fan-out kinds in YAML v1.
- No sub-workflow includes (`include:`, `import:`).
- No `on:` triggers (no schedule, no event); workflows are
  operator-referenced. Scheduling lives in v0.13 jobs targeting a
  registered Plan-Build action; the YAML never carries `on:`.
- No `env:` block at workflow scope.
- No retry/backoff policies in YAML.
- No dynamic action-name resolution (`action: ${...}`).
- No `${secrets.x}` substitution; secrets resolve through
  `secret://` settings refs at the action layer.
- No `${env.x}` substitution.
- No LLM-authored workflow YAML in v0.44 (that is v0.46
  self-improvement drafts).
- No plan-time spend enforcement (cost is descriptive only).
- No multi-user collaborative plan editing.
- No remote workflow distribution.
- No `/plan` destination route at v0.44; Plan/Build is a panel.
- No new step kinds beyond the v0.24 six.

## Reserved Vocabulary (not implemented in v0.44)

These names are reserved here so future releases can promote them
without renaming:

- `for_each` — loop step kind (parked).
- `parallel_steps` — fan-out step kind (parked).
- `sub_workflow_include` — composition primitive (parked).
- `on_schedule` — cron/interval trigger (parked).
- `on_event` — event-source trigger (parked).
- `retry_policy` — per-step retry configuration (parked).
- `dynamic_action_name` — `action: ${...}` substitution (parked; will
  require an explicit authority-boundary analysis if ever promoted).
- `env_block` — workflow-scope environment (parked).
- `secret_substitution` — `${secrets.x}` reference (parked behind a
  separate ADR; current rule is that secrets resolve at the action
  layer, not in YAML).

When a real consumer needs a reserved name, the next release promotes
it through a v0.4x amendment to this ADR plus a v0.4x security eval
covering the new attack surface.

## Relates To

- Surfaces over: ADR 0021 (intent/objective/capability/advisory
  boundary) and v0.24 Objective Runtime.
- Amends: ADR 0013 (URI-first resource identity) for `workflow://`
  and `plan://`.
- Composes with: ADR 0011 (confirmed external capability adapters),
  ADR 0017 (Allbert plugin contract), ADR 0023 (workspace canvas and
  ephemeral surface substrate), ADR 0024 (app UI contribution and
  workspace zones), ADR 0027 (Allbert action DSL and capability
  registry), ADR 0029 (typed runtime response contracts), ADR 0030
  (unified surface catalog, renderer, extension registry), ADR 0031
  (settings schema fragments and authority).
- Forward-pins: ADR 0046 (settings schema migration policy; v0.44
  declares `workflows.*` + `plan.*` at `schema_version: 1`; v0.51
  ships the migration tool).
- Composes with: ADR 0049 (development gates and test
  parallelization) for the `release.v044` deterministic gate.
- Forward-pin to: ADR 0016 amendment (channel approval primitives;
  v0.49) which formalizes `:list`/`:button`/`:typed_command`/`:link`
  as the vocabulary v0.44 plan cards are already expressible in.
