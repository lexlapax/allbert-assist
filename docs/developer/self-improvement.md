# Self-Improvement Developer Guide

Status: implemented in v0.47 with v0.47b M1-M4 handoff extensions. This guide
describes the discovery and local draft substrate plus inert capability-gap,
objective, template-backed, marketplace-backed, and delegate-plugin request
draft kinds, plus the capability-gap handoff into the existing source-bearing
dynamic-draft gate. The remaining v0.47b milestone is release/eval closeout.

## Authority Boundary

Self-improvement uses the normal Allbert runtime boundary:

- `discover_patterns` is a registered `:read_only` internal action.
- Suggestions are advisory metadata in the existing discovery suggestion
  table.
- Draft creation writes inert reviewed-draft state only.
- Live promotion resumes confirmation-gated registered actions.
- Draft metadata, YAML, trace references, model output, and repeated use never
  grant permission.

## Trace Index

`AllbertAssist.SelfImprovement.TraceIndex` reads existing redacted trace
markdown under `<ALLBERT_HOME>/memory/traces/` when both
`self_improvement.enabled` and `self_improvement.trace_index.enabled` are
true.

It returns request-scoped patterns for:

- `repeated_prompt`
- `action_chain`
- `correction`
- `failed_intent`

Pattern output contains counts, redacted samples, action names, optional
`user_id` / `app_id` scope, and relative source refs. The index writes no
derived file and does not expose raw trace content. The detailed privacy policy
is in `docs/developer/self-improvement-trace-index.md`.

## Suggestion Schema

v0.47 generalizes `AllbertAssist.Tools.Discovery.Suggestion` instead of adding
a second queue. Self-improvement suggestions use:

```text
provenance: "self_improvement"
candidate_id: nil
suggestion_type: trace_to_skill | trace_to_workflow | memory_promotion | memory_update | capability_gap | objective | template_backed | marketplace_backed | delegate_plugin_request
status: pending | accepted | dismissed | expired
```

The advisory packet lives in `metadata`:

- `summary`
- `evidence_refs`
- `proposed_draft_kind`
- `provenance`

TTL and capacity are controlled by
`self_improvement.suggestions.ttl_days` and
`self_improvement.suggestions.max_open`.

`AllbertAssist.SelfImprovement.Discovery.discover/2` converts trace-index
patterns to suggestion rows and records diagnostics for memory-review and
objective-event context. It may write suggestion rows only; it must not write
settings, skills, workflows, memory, plugins, permissions, confirmations, code,
or live runtime state.

## Draft Store

`AllbertAssist.Drafts.Store` is the unified reviewed-draft facade:

- Existing v0.37 dynamic-code drafts stay under
  `<ALLBERT_HOME>/dynamic_plugins/drafts/` and list as `kind: "code"`.
- v0.47 non-code drafts stay under `<ALLBERT_HOME>/drafts/`.
- Skill drafts use the `skill` kind.
- Workflow drafts use the `workflow` kind and write draft YAML under
  `<ALLBERT_HOME>/drafts/workflows/<id>.yaml`.
- Memory drafts use `memory_promotion` or `memory_update` and write draft
  artifacts under `<ALLBERT_HOME>/drafts/memory/`.
- Capability-gap drafts use `capability_gap`, write artifacts under
  `<ALLBERT_HOME>/drafts/capability_gaps/`, and store a redacted
  `DynamicPlugins.Codegen.CapabilityGap` summary without requesting a dynamic
  draft.
- Objective drafts use `objective`, write artifacts under
  `<ALLBERT_HOME>/drafts/objectives/`, and store declarative objective input
  without framing an objective.
- Template-backed drafts use `template_backed`, write artifacts under
  `<ALLBERT_HOME>/drafts/templates/`, and store original operator params plus a
  `Templates.preview/3` packet. `promote_template_draft` delegates to
  `create_from_template` and produces a v0.37 dynamic draft whose gate remains
  `not_run`.
- Marketplace-backed drafts use `marketplace_backed`, write artifacts under
  `<ALLBERT_HOME>/drafts/marketplace/`, and store a descriptive
  `Marketplace.list_entries/1` entry snapshot with no install or authority.
- Delegate-plugin request drafts use `delegate_plugin_request`, write artifacts
  under `<ALLBERT_HOME>/drafts/delegate_plugins/`, and store a v0.38
  plugin-template preview plus delegate metadata. They never scaffold a plugin
  directory or register an `Objectives.AgentRegistry` entry.

Non-code tiers are `draft`, `discarded`, and `promoted`. Promotion metadata is
recorded only after the live write has completed through the confirmed action
path.

## Registered Actions

The v0.47 actions are internal runtime actions:

| Action | Permission | Confirmation | Effect |
|---|---|---|---|
| `discover_patterns` | `:read_only` | not required | Writes advisory suggestions only. |
| `create_self_improvement_draft` | `:dynamic_codegen_request` | not required | Writes inert draft state only. |
| `discard_self_improvement_draft` | `:dynamic_codegen_discard` | not required | Marks a draft discarded. |
| `promote_skill_draft` | `:skill_write` | required | Writes an instruction-only local skill after approval. |
| `promote_workflow_draft` | `:objective_write` | required | Writes live workflow YAML after approval. |
| `promote_memory_draft` | `:memory_write` | required | Appends or updates markdown memory after approval. |
| `promote_template_draft` | `:dynamic_codegen_request` | not required | Creates an inert v0.37 dynamic draft through `create_from_template`; gate/integration stay separate. |
| `promote_capability_gap_draft` | `:dynamic_codegen_request` | not required | Creates an inert v0.37 dynamic draft through `DynamicPlugins.request_draft/2`; gate/integration stay separate. |
| `promote_objective_draft` | `:objective_write` | required | Frames a v0.24 objective through `Objectives.frame/2` after approval. |

Skill, workflow, memory, and objective promotion actions are resumable through
`approve_confirmation`. The initial call returns `:needs_confirmation` and
writes no live artifact; approval resumes the target action with confirmation
context. Template and capability-gap promotions are not resumable because they
write only v0.37 dynamic drafts with `gate_status: "not_run"`; gate execution
and integration remain separate actions. `integrate_dynamic_draft` checks the
dynamic draft before creating a confirmation and denies ungated drafts, so
operator approval is unavailable until the existing gate evidence is present.

## Release Gates

Focused v0.47 coverage lives in:

- `SelfImprovement.TraceIndexTest`
- `SelfImprovementActionsTest`
- `SelfImprovementDraftActionsTest`
- `SelfImprovementPromotionActionsTest`
- `Drafts.StoreTest`
- `SelfImprovementRoutingTest`
- `Allbert.SelfImprovementTest`
- `v047_self_improvement_eval_test.exs`

Focused v0.47b M1 coverage adds:

- `Drafts.StoreTest` capability-gap/objective draft cases
- `Tools.DiscoveryTest` v0.47b handoff suggestion kind validation
- `SelfImprovementDraftActionsTest` capability-gap/objective action coverage

Focused v0.47b M2 coverage adds:

- `Drafts.StoreTest` template-backed and marketplace-backed draft cases
- `Tools.DiscoveryTest` template/marketplace handoff suggestion kind validation
- `SelfImprovementDraftActionsTest` template/marketplace action coverage
- `SelfImprovementPromotionActionsTest` inert template dynamic-draft promotion
- `RegistryTest` `promote_template_draft` registration coverage

Focused v0.47b M3 coverage adds:

- `Drafts.StoreTest` delegate-plugin request inertness
- `Tools.DiscoveryTest` delegate-plugin handoff suggestion kind validation
- `SelfImprovementDraftActionsTest` delegate-plugin request action coverage
- `SelfImprovementPromotionActionsTest` objective promotion confirmation resume
- `RegistryTest` `promote_objective_draft` registration coverage

Focused v0.47b M4 coverage adds:

- `SelfImprovementPromotionActionsTest` capability-gap promotion to an inert
  v0.37 dynamic draft and pre-gate integration block
- `RegistryTest` `promote_capability_gap_draft` registration coverage
- `DynamicPlugins.CodegenTest` full dynamic draft gate/integration loop
- `DynamicPlugins.LoaderTest` confirmation, trusted-validation, and rollback
  regression coverage

The deterministic release handoff is:

```sh
mix allbert.test release.v047
```

It runs the core, surface, and security-eval fixture suites and writes evidence
under `<ALLBERT_HOME>/release_evidence/v047/`.

The v0.47b deterministic handoff gate is implemented in M5 as
`mix allbert.test release.v047b`.
