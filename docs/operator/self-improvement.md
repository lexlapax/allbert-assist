# Operator-Supervised Self-Improvement

Status: implemented in v0.47 with v0.47b/`0.47.1` handoff extensions. This guide
covers the discovery and local-draft surface plus inert capability-gap,
objective, template-backed, and marketplace-backed handoff drafts;
delegate-plugin request drafts, confirmation-gated objective promotion, and
the code-bearing capability-gap handoff into the existing dynamic-draft gate.

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
`objective`, `template_backed`, `marketplace_backed`, and
`delegate_plugin_request` so far. All self-improvement suggestions have
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
- Delegate-plugin request drafts stay under
  `<ALLBERT_HOME>/drafts/delegate_plugins/` and record a v0.38 plugin-template
  preview with `scaffold_requested: false` and `agent_registered: false`.

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
- `promote_capability_gap_draft` requires `:dynamic_codegen_request` and turns
  an inert capability-gap draft into a v0.37 dynamic draft through
  `DynamicPlugins.request_draft/2`; it still has no live authority.
- `promote_objective_draft` requires `:objective_write`, creates a durable
  confirmation, and frames a v0.24 objective only after approval.

For skill, workflow, and memory promotions, the first action call creates a
durable confirmation and writes no live artifact. Approval resumes the same
registered action and writes through the existing local skill, workflow, or
memory path. Objective promotion follows the same confirmation-resume shape and
frames through the public objective facade after approval. Denial writes
nothing. Template and capability-gap promotion complete immediately because
they create only dynamic drafts; live integration still requires the separate
gate and integration actions. `integrate_dynamic_draft` creates no confirmation
for an ungated dynamic draft, so an operator cannot approve live integration
until the v0.36/v0.37 gate path has passed.

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

The deterministic v0.47b handoff gate exercises the shipped handoff drafts:

```sh
mix allbert.test release.v047b
```

Expected evidence is written to:

```text
<ALLBERT_HOME>/release_evidence/v047b/release-v047b-<timestamp>.json
```
