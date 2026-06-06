# Operator-Supervised Self-Improvement

Status: implemented in v0.47 with v0.47b M1-M2 handoff extensions. This guide
covers the discovery and local-draft surface plus inert capability-gap,
objective, template-backed, and marketplace-backed handoff drafts;
delegate-plugin handoffs land in a later v0.47b milestone.

## Safety Model

Self-improvement is an operator-reviewed queue, not an autonomous capability
path. Discovery is read-only and creates advisory suggestion rows. Drafts are
inert until an operator promotes them, and live promotion still goes through a
registered action, Security Central, durable confirmation, traces, and audits.

Repeated use, suggestion score, prior approval, trace contents, workflow YAML,
skill YAML, and draft metadata never grant permission by themselves.

## Enablement

The surface is disabled by default. Enable the top-level feature and the trace
index before running discovery:

```sh
mix allbert.settings set self_improvement.enabled true
mix allbert.settings set self_improvement.trace_index.enabled true
```

Useful caps:

```sh
mix allbert.settings set self_improvement.trace_index.max_indexed_entries 5000
mix allbert.settings set self_improvement.trace_index.min_repetitions 3
mix allbert.settings set self_improvement.suggestions.max_open 25
mix allbert.settings set self_improvement.suggestions.ttl_days 14
mix allbert.settings set self_improvement.drafts.max_open 50
```

Emergency disable:

```sh
mix allbert.settings set self_improvement.enabled false
mix allbert.settings set self_improvement.trace_index.enabled false
```

`self_improvement.schema_version` is read-only and remains `1` in v0.47.

## Review Suggestions

Ask for self-improvement discovery from an operator surface with prompts such
as:

- `show self-improvement suggestions`
- `what could you turn into a skill`
- `what could you turn into a workflow`

The routed action is `discover_patterns`. It reads the trace index, objective
events, and reviewed memory counts, then writes only advisory suggestions to
the passive discovery queue. It does not enable a skill, create live workflow
YAML, write memory, change settings, install packages, load code, or create a
confirmation.

CLI inspection:

```sh
mix allbert.self_improvement list
mix allbert.self_improvement inspect <suggestion_id>
```

Expected v0.47 suggestion kinds are `trace_to_skill`, `trace_to_workflow`,
`memory_promotion`, and `memory_update`. v0.47b adds `capability_gap`,
`objective`, `template_backed`, and `marketplace_backed` so far. All
self-improvement suggestions have
`provenance: "self_improvement"` and no MCP candidate id.

## Review Drafts

Accepting a suggestion through the shipped action creates an inert draft in the
unified reviewed-draft store:

- Skill drafts are disabled/untrusted instruction-only drafts.
- Workflow drafts validate against the v0.44 workflow schema but stay under
  `<ALLBERT_HOME>/drafts/workflows/`, not the live
  `<ALLBERT_HOME>/workflows/` root.
- Memory promotion and update drafts stay under
  `<ALLBERT_HOME>/drafts/memory/` and do not call the memory facade until
  confirmation resumes the promotion action.
- Capability-gap drafts stay under `<ALLBERT_HOME>/drafts/capability_gaps/`
  and record a redacted `Codegen.CapabilityGap` summary with
  `dynamic_draft_requested: false`.
- Objective drafts stay under `<ALLBERT_HOME>/drafts/objectives/` and record
  declarative objective input with `objective_framed: false`.
- Template-backed drafts stay under `<ALLBERT_HOME>/drafts/templates/` and
  record a reviewed template preview without writing dynamic code.
- Marketplace-backed drafts stay under `<ALLBERT_HOME>/drafts/marketplace/`
  and record `Marketplace.list_entries/1` metadata with `authority:
  "metadata_only"` and `install_requested: false`.

CLI inspection and discard:

```sh
mix allbert.self_improvement drafts list
mix allbert.self_improvement drafts inspect <draft_id>
mix allbert.self_improvement drafts discard <draft_id>
```

Discarding a draft marks it discarded. It must not leave an enabled skill,
live workflow, memory entry, plugin, permission grant, or dynamic code behind.

## Promote Drafts

Live promotion is intentionally separate from draft creation:

- `promote_skill_draft` requires `:skill_write`.
- `promote_workflow_draft` requires `:objective_write`.
- `promote_memory_draft` requires `:memory_write`.
- `promote_template_draft` requires `:dynamic_codegen_request` and creates only
  an inert v0.37 dynamic draft through `create_from_template`; the sandbox gate
  and live integration remain separate.

For skill, workflow, and memory promotions, the first action call creates a
durable confirmation and writes no live artifact. Approval resumes the same
registered action and writes through the existing local skill, workflow, or
memory path. Denial writes nothing. Template promotion completes immediately
because it creates only a dynamic draft; live integration still requires the
separate gate and integration actions.

## Validation

The deterministic v0.47 gate exercises the full shipped surface without a live
model or network:

```sh
mix allbert.test release.v047
```

Expected evidence is written to:

```text
<ALLBERT_HOME>/release_evidence/v047/release-v047-<timestamp>.json
```
