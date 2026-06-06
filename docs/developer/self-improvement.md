# Self-Improvement Developer Guide

Status: implemented in v0.47. This guide describes the discovery and local
draft substrate. v0.47b may add draft kinds and promotion targets, but must
reuse this suggestion lifecycle, draft facade, and authority boundary.

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
suggestion_type: trace_to_skill | trace_to_workflow | memory_promotion | memory_update
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

Promotion actions are resumable through `approve_confirmation`. The initial
call returns `:needs_confirmation` and writes no live artifact; approval
resumes the target action with confirmation context.

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

The deterministic release handoff is:

```sh
mix allbert.test release.v047
```

It runs the core, surface, and security-eval fixture suites and writes evidence
under `<ALLBERT_HOME>/release_evidence/v047/`.

