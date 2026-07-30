# Simplification Opportunities: Duplicate and Near-Duplicate Abstractions

Survey date: 2026-07-29. Baseline commit: `c7ee5a29`.

This is a findings document, not a milestone plan. It records where duplicated and
near-duplicated abstractions live in the codebase and what a consolidation would
target. Nothing here is scheduled; scope decisions belong in the roadmap and the
active version plan.

Method: a normalized duplicate-block detector (whitespace- and comment-stripped,
6- and 8- and 12-line sliding windows, cross-file matches only) run over all
non-test `.ex` sources, plus targeted symbol censuses and pairwise diffs to
confirm each family.

## Summary

Duplication is heavily concentrated in the actions layer. The CLI, web, and
channels subsystems are clean and need no consolidation work.

| Area | Non-blank LOC | Lines inside cross-file duplicate blocks (>= 6 lines) |
| --- | ---: | ---: |
| `allbert_assist/actions/` | 33,108 | **6,854 (20.7%)** |
| all of `allbert_assist/lib` | 162,737 | 10,321 (6.3%) |
| `cli/` | 9,150 | 253 (2.8%) |
| `allbert_assist_web/lib` | 14,600 | 270 (1.8%) |
| `intent/` | 8,484 | 231 (2.7%) |
| `confirmations/` | 1,723 | 72 (4.2%) |
| `public_protocol/` | 3,319 | 58 (1.7%) |
| `channels/` | 1,850 | 0 (0.0%) |

Two thirds of the repository's duplicated lines sit in the 249-module actions
layer.

Note on the `confirmations/` figure: 4.2% understates that subsystem. The
detector matches normalized text, and the confirmation metadata family (Tier 3)
duplicates *structure* with differing string labels, so its true near-duplicate
mass is higher than the exact-match number.

---

## Tier 1 — The action response envelope

Roughly 4,000+ lines across 249 modules.

Every action already declares its identity through
`use AllbertAssist.Action, permission: ..., name: ...`. But
`AllbertAssist.Action.__using__/1` (`apps/allbert_assist/lib/allbert_assist/action.ex:55`)
only stashes that metadata as `capability/0`. It generates no response helpers.
Each module therefore hand-rolls an envelope it could derive.

### Hand-rolled helpers

| Helper | Modules defining it |
| --- | ---: |
| `defp denied/1` | 130 |
| `defp action/3` | 121 |
| standard 4-key `output_schema` | 214 of 249 |
| `defp completed/2` | 56 |
| `defp error_message/…` | 34 |
| `defp denied_status/…` | 32 |
| `defp failed/…` | 30 |
| `defp error/2` | 22 |

`denied/1` is near-verbatim across all 130 sites:

```elixir
{:ok,
 %{
   message: permission_decision.reason,
   status: PermissionGate.response_status(permission_decision),
   permission_decision: permission_decision,
   actions: [action(:denied, permission_decision, nil)]
 }}
```

`action/3` differs only in the `name:` and `permission:` literals, both of which
are already present in the capability metadata. See
`apps/allbert_assist/lib/allbert_assist/actions/memory/update_memory_entry.ex:90`
— 40 of that module's 101 lines are derivable boilerplate (`output_schema` at
lines 21-27, `denied`/`error`/`action` at lines 69-100).

### Confirmation plumbing

| Helper | Modules defining it |
| --- | ---: |
| `approval_resume?` | 30 |
| `confirmation_id` | 28 |
| `create_confirmation` | 27 |
| `approved_resume?` | 21 |

The confirmation-summary map is byte-identical across 7 modules:

```elixir
%{
  id: Map.get(confirmation, "id"),
  status: Map.get(confirmation, "status"),
  origin: Map.get(confirmation, "origin"),
  expires_at: Map.get(confirmation, "expires_at"),
  audit_path: Map.get(confirmation, "audit_path")
}
```

- `actions/mcp/call_tool.ex:341`
- `actions/mcp/read_resource.ex:328`
- `actions/mcp/connect_server.ex:295`
- `actions/intent/external_network_request.ex:496`
- `actions/intent/run_shell_command.ex:327`
- `actions/packages/run_package_install.ex:375`
- `actions/skills/run_skill_script.ex:410`

### Request-context normalization

An identical 8-line block appears in 9 modules:

```elixir
request_context
|> Map.take([:actor, :operator_id, :channel, :input_signal_id])
|> Map.new(fn
  {:operator_id, value} -> {:actor, value}
  {:input_signal_id, value} -> {:source_signal_id, value}
  other -> other
end)
|> Map.put(:permission_decision, permission_decision)
```

- `actions/settings/set_active_model_profile.ex:152`
- `actions/settings/update_setting.ex:80`
- `actions/settings/set_notes_root.ex:120`
- `actions/settings/set_provider_credential.ex:180`
- `actions/settings/apply_persona_profile.ex:302`
- `actions/workspace/set_theme.ex:113`
- `actions/surface_policy/update.ex:127`
- `actions/channels/configure_channel_setting.ex:116`

### Consolidation target

Extend the `use AllbertAssist.Action` macro to inject `denied/1`, `error/2`,
`action/3`, the standard `output_schema`, the confirmation-summary helper, and
the request-context normalizer from the capability metadata the macro already
receives. Mark them `defoverridable` for the genuine outliers.

### Near-clone action families

| Family | Modules | LOC | Divergence |
| --- | ---: | ---: | --- |
| `channels/{slack,discord,telegram,matrix,email}_doctor.ex` | 5 | 534 | matrix vs telegram differ by 18 of 105 lines (~83% identical) |
| `mcp/scan_{enable,pause,resume,run_once}.ex` | 4 | 473 | pause vs resume differ by 18 of 110 lines (~84% identical) |
| `tools/find_local_tools.ex`, `tools/find_tools.ex`, `mcp/find_tools.ex` | 3 | — | identical `completed/4` |

---

## Tier 2 — Scattered primitives with divergent semantics

These matter beyond tidiness: several same-named helpers return different answers
for the same input.

### `truthy?/1` — 50 definitions, 8 distinct truth sets

| Truth set | Definitions |
| --- | ---: |
| `[true, "true", "1", 1]` | 8 |
| `[true, "true", "1", 1, "yes"]` | 1 |
| `[true, "true", "1", 1, "yes", "on"]` | 1 |
| `[true, "true", "1", 1, "yes", "all"]` | 1 |
| `[true, "true", "1", 1, "on"]` | 1 |
| `[true, "true", "1", 1, true, "enabled", :enabled]` | 1 |
| `[true, "true", "yes", "1", 1]` | 1 |
| clause-form, no integer `1` | `security/policy.ex:558` |

`AllbertAssist.Runtime.truthy?` (`runtime.ex:647`) accepts integer `1`.
`AllbertAssist.Security.Policy.truthy?` (`security/policy.ex:558`) does not.
Same-named predicate, different answers, in security-adjacent code.

### `json_safe/1` — 12 modules, genuinely divergent

| Module | Behavior |
| --- | --- |
| `conversations.ex:701` | handles `Date`/`Time`, handles improper lists, stringifies atom keys |
| `jobs/runner.ex:355` | no `Date`/`Time`, no improper-list handling |
| `plan_build.ex:210` | handles structs, does not stringify atom keys, passes tuples through unchanged |

`plan_build.ex` can therefore emit values that are not JSON-encodable. Whichever
implementation is correct, at least two of the twelve are latent encoding bugs.

### `private_ip?/1` — SSRF table triplicated byte-for-byte

- `external/http_policy.ex:164`
- `voice/provider_http.ex:401`
- `settings/model_doctor.ex:496`

All three are currently in sync. Patching one (for example, to cover
IPv4-mapped IPv6 such as `::ffff:127.0.0.1`) silently leaves two holes.

### Under-used canonical modules

`AllbertAssist.Maps` is well adopted (145 files), but `Serialization` and
`Validation` are not, while their inline equivalents proliferate:

| Canonical module | Callers | Competing local copies |
| --- | ---: | --- |
| `AllbertAssist.Serialization` (`stringify_keys/2`) | 4 | `stringify_keys` in 12 modules, `stringify_value` in 6, `json_safe` in 12 |
| `AllbertAssist.Validation` (`clamp_limit/4`) | 14 | `positive_integer` in 12 modules |
| `AllbertAssist.Maps` (`field/3`, `field_truthy/3`) | 145 | 164 local `defp field(` definitions, 16 of which literally wrap `Maps.field_truthy` |

### Other repeated micro-helpers

| Helper | Copies | Notes |
| --- | ---: | --- |
| `blank_to_nil/1` | 13 | identical; `cli/areas/*`, `mix/tasks/allbert.ask.ex:399`, `workspace/offline.ex`, others |
| `get_in_field/2` | 6 | identical `Enum.reduce_while` over `field/2` |
| `blank?/1` | 32 | |
| `present?/1` | 32 | |
| `maybe_put/3` | 96 | |

---

## Tier 3 — Structural families worth one shared primitive

### Subsystem audit modules — 8 modules, 933 LOC

`{external,mcp,packages,sandbox,execution,dynamic_plugins,skills/online,settings}/audit.ex`
all implement the same contract: `audit_root/0`, daily-rotated `audit_path/1`,
`append/N`, `render/N`, plus per-copy `redact_paths`/`preview` helpers.

`AllbertAssist.Runtime.Audit` (`runtime/audit.ex:67-112`) already unifies the
*dispatch* over six of them. The family was recognized, but only the front door
was shared — not the JSONL append/rotate/redact primitive behind it.

### Confirmation metadata modules — 5 modules

`confirmations/{shell_command,skill_script,package_install,external_request,online_skill}_metadata.ex`
share the same public shape (`lines/1`, `action_lines/1`, `*_details/1`,
`result_details/1`) and roughly 15 identical private helpers each:

`params_summary/1`, `target_result/1`, `target_status/1`, `ms_text/1`,
`bytes_text/1`, `denial_text/1`, `output_preview/1`, `reject_blank_values/1`,
`blank?/1`, `field/2`, `action_name/1`.

Only the domain-specific detail-line builder genuinely varies.

### `Runtime.Redactor` internal triple

`runtime/redactor.ex:120-178`: `redact_audio_metadata/1`,
`redact_image_metadata/1`, and `redact_artifact_metadata/1` are byte-identical
apart from the keyset module attribute and the value-redaction callback. The
three `redact_*_resource_uri/1` cond-chains have the same relationship.

One `redact_metadata(value, keys, value_fun)` replaces all six.

### Two `ContinueObjective` implementations

- `objectives/commands/continue_objective.ex` — 250 LOC
- `actions/objectives/continue_objective.ex` — 301 LOC

The action does not delegate to the command. Both re-derive `objective/2`,
`user_id/2`, `still_blocked/…`, `get_in_field/2`, and `field/2`. Two continue
paths that can drift apart.

---

## Explicit non-findings

Recorded so review effort is not spent here.

- **`Runtime.Redactor` vs `Security.Redactor`** is an intentional facade
  (`defdelegate redact/1`, documented at `runtime/redactor.ex:2-9`), not a
  duplicate. Leave it.
- **Repeated basenames** — 10 `audit.ex` (8 of which *are* a real family, above),
  7 `registry.ex`, 7 `doctor.ex`, 5 `catalog.ex`, 5 `commands.ex`, 4 `store.ex` —
  are otherwise genuinely different domains. Name collision only.
- **`surface/` vs `surfaces/` vs `allbert_assist_web/surface/`** each hold files
  of distinct purpose. The only oddity is `surfaces/context_builder.ex` sitting
  alone in a plural directory beside the singular `surface/`. That is a naming
  cleanup, not duplication.
- **CLI, web, and channels** are clean at 2.8%, 1.8%, and 0.0%. No work needed.

---

## Sequencing note

The highest-leverage single change is the Tier 1 macro extension: it addresses
roughly 4,000 lines across 249 modules and is mechanical, since the macro already
receives the `name` and `permission` that the boilerplate re-states by hand.

Tier 2's `truthy?` and `json_safe` are smaller but arguably should come first,
because consolidating them forces a decision about which semantics are correct —
and both currently have security- or correctness-relevant divergence. Tier 1 is a
pure refactor; Tier 2 is a behavior reconciliation and needs its own test
coverage before the merge.
