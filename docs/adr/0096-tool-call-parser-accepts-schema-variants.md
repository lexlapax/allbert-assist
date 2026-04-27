# ADR 0096: Tool-call parser accepts schema variants and provider-native tool calling becomes a v0.15+ seam

Date: 2026-04-26
Status: Accepted

Amended by the v0.14.3 draft plan to add flat named-call normalization,
a schedule-specific no-tool retry guard for mutating recurring-job requests,
and a shared one-retry budget for generic malformed-tool and schedule-specific
retry paths.

## Context

Through v0.14, every Allbert provider returns plain text. The kernel system prompt instructs the model to emit `<tool_call>{"name":"<tool>","input":{...}}</tool_call>` and the tool-call parser now lives in the split kernel layout at [`allbert-kernel-core/src/tool_call_parser.rs`](../../crates/allbert-kernel-core/src/tool_call_parser.rs) with service re-exports in [`allbert-kernel-services/src/tool_call_parser.rs`](../../crates/allbert-kernel-services/src/tool_call_parser.rs).

Strong frontier models generally follow the XML format. The v0.10 fresh-profile default Ollama Gemma4 does not. An end-user transcript captured during v0.14.1 review showed Gemma4 emitting:

```text
<tool_call>{"args":["date"],"program":"date"}</tool_call>
```

The parser rejected this because it had no `name` or `input` keys, and the literal `<tool_call>` block leaked through to the user as final assistant output. The result is tool calling broken-by-default on a fresh local profile.

The deeper architectural issue is that the `LlmProvider` trait has no `tools` field on [`CompletionRequest`](../../crates/allbert-kernel-core/src/llm/provider.rs) and no `tool_calls` field on `CompletionResponse`. Every provider uses XML-tagged text even when the underlying API supports structured tool calls. XML-tagged text remains the universal lowest-common-denominator; it is also the least reliable on small/local models.

## Decision

v0.14.1 takes two steps without making provider-native tool calling release-blocking.

### Parser robustness

The parser accepts six shapes inside `<tool_call>...</tool_call>`:

- `{"name": <str>, "input": <object>}` — current canonical.
- `{"name": <str>, "arguments": <object>}` — OpenAI-style alias.
- `{"name": <str>, ...flat_fields}` — flat named local-model shape; every non-`name` field is normalized into `input`.
- `{"tool": <str>, ("input"|"args"|"arguments"|"parameters"): <object>}` — local-model alias with object input.
- `{"function": {"name": <str>, "arguments": <object>}}` — nested OpenAI legacy shape.
- `{"program": <str>, "args": [<str>...]}` — direct-spawn shape normalized to `process_exec`.

The canonical, alias, `tool`, and nested `function` shapes require object inputs. The flat named shape is accepted only when the object has a string `name`, has no `input` or `arguments`, and has at least one non-`name` field. Empty flat calls such as `{"name":"upsert_job"}` are rejected. The only accepted array-args shape is the direct-spawn `program` form.

The implementation is explicitly two-stage:

1. `parse_tool_call_blocks(text)` extracts XML-contained JSON into
   `ParsedToolCall` values without consulting runtime policy.
2. `resolve_tool_calls(parsed, catalog, active_skill_policy, security)` converts
   parsed values into `ToolInvocation` values only after runtime context agrees.

The direct-spawn form is resolved only when all authorization context agrees:

- `process_exec` is present in the active tool catalog for the turn;
- every active skill that constrains tools permits `process_exec` through `allowed-tools`;
- the requested program and arguments pass the existing `security.exec_allow` / `security.exec_deny` policy;
- the normalized input is the same structured `ProcessExecInput` the existing tool already expects, with no shell-string parsing.

For direct-spawn calls, `args` is the argv tail. If the first arg exactly
matches `program` or `basename(program)`, the resolver drops that duplicate
command name before policy checks and records the normalization reason in trace
metadata. This accepts the observed Gemma4 shape
`{"program":"date","args":["date"]}` as a single `date` invocation instead of
`date date`.

The flat named shape exists for local models that flatten a tool schema into
top-level JSON fields:

```json
{"name":"upsert_job","description":"Daily review","schedule":"@daily at 07:00","prompt":"Run a concise daily review."}
```

It normalizes deterministically to:

```json
{"name":"upsert_job","input":{"description":"Daily review","schedule":"@daily at 07:00","prompt":"Run a concise daily review."}}
```

No authorization moves into the parser. After normalization, the same resolve
step checks the active tool catalog, active skill `allowed-tools`, confirmation
hooks, and exec policy before dispatch.

Normalization is deterministic: every accepted variant produces either a
policy-approved `ToolInvocation` or a refusal/retry error. Normal tool dispatch
still performs policy checks before execution as defense in depth.

On parse failure, the kernel issues exactly one corrective retry with a system message naming the canonical shape and active tool catalog. This retry is controlled by:

```toml
[intent]
tool_call_retry_enabled = true
```

Default: `true`. Validation accepts only booleans. Parse/resolve happens before
assistant-message persistence and before `AssistantText` is emitted. When retry
is disabled, or after one failed retry, the kernel surfaces an operator-facing
remediation rather than passing literal `<tool_call>` text through to the user.

The retry is bounded by the same daily cost cap and cost logging as any other provider call.

v0.14.3 adds one schedule-specific retry guard on top of the generic malformed
tool-call retry. Retry eligibility is based on validated router metadata, not a
lexical scan of words such as `daily`, `remind`, or `pause`: the current turn
must have a valid router decision with `intent = schedule` and action
`schedule_upsert`, `schedule_pause`, `schedule_resume`, or `schedule_remove`,
but must have fallen through to the full assistant path instead of executing a
high-confidence router draft. In explicit compatibility mode
(`intent_classifier.rule_only = true`), the legacy rule classifier may be used
as the eligibility source.

When retry is eligible and the model responds with prose confirmation but no
tool call, the kernel retries with a corrective message requiring `upsert_job`,
`pause_job`, `resume_job`, or `remove_job`. The model must not ask "Shall I
proceed?" in prose before the job tool call. The structured durable-change
confirmation prompt remains the only approval surface for job mutations. The
schedule-specific retry and the generic malformed-tool retry share one retry
budget per turn; Allbert must not do one generic retry and then one schedule
retry for the same provider-response failure.

If that retry still fails or emits malformed JSON, Allbert surfaces a safe
operator message that names the CLI fallback, `allbert-cli jobs upsert
<job-definition.md>`, and points to trace inspection. The failure records
bounded, redacted trace provenance: parse error, whether flat normalization was
attempted, whether the scheduling retry was attempted, and which retry path was
taken. Raw malformed payloads do not appear in ordinary user output unless
trace capture and redaction settings already permit them.

### Provider seam

`LlmProvider` gains an additive seam:

```rust
pub struct ToolDeclaration {
    pub name: String,
    pub description: String,
    pub schema: serde_json::Value,
}

pub struct CompletionRequest {
    // existing fields...
    pub tools: Vec<ToolDeclaration>,         // NEW
}

pub struct ToolCallSpan {
    pub call_id: String,
    pub name: String,
    pub input: serde_json::Value,
}

pub struct CompletionResponse {
    // existing fields...
    pub tool_calls: Vec<ToolCallSpan>,        // NEW
}
```

In v0.14.1 every shipped provider sets `tool_calls = vec![]` and the kernel keeps using XML-tagged text. The seam is added now so v0.15+ can add provider-native tool calling per provider without another trait migration.

When provider-native tool calling lands, the kernel call site prefers `tool_calls` when non-empty and falls back to XML parsing when empty. Both paths coexist; no flag day.

## Consequences

- The default Gemma4 profile can call tools reliably once v0.14.1 lands because the parser accepts the shapes Gemma actually emits.
- The XML protocol stays universal; no provider becomes a hard dependency on structured tool calling.
- The direct-spawn variant cannot bypass active tool catalog, active skill `allowed-tools`, or exec policy.
- Flat named-call normalization lets local models recover from a common schema-flattening error while preserving the same authorization and confirmation gates.
- Mutating conversational scheduling becomes deterministic: the model calls the job tool first, and Allbert owns the approval surface.
- The `tools` seam is added once; later provider-native work is additive.
- Stronger models that already emit the canonical shape continue through the original path.

## Alternatives considered

- **Switch to provider-native tool calling immediately.** Rejected for v0.14.1 because it would gate the parser fix on a multi-provider migration.
- **Drop the XML protocol entirely and require provider-native tools.** Rejected because some providers and local deployments still do not expose structured tools.
- **Train the user to avoid tool calls on Gemma4.** Rejected because the local-default profile should work out of the box.
- **Multiple retries with exponential backoff.** Rejected because cost grows quickly and most parse failures are deterministic. One corrective retry catches the realistic recovery cases.

## References

- [docs/plans/v0.14.1-vision-alignment.md](../plans/v0.14.1-vision-alignment.md)
- [docs/plans/v0.14.3-operator-reliability.md](../plans/v0.14.3-operator-reliability.md)
- [ADR 0027](0027-durable-schedule-mutations-require-preview-and-explicit-confirmation.md)
- [ADR 0030](0030-intent-routing-is-a-kernel-step-not-a-skill-concern.md)
