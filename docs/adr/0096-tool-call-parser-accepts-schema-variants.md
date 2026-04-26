# ADR 0096: Tool-call parser accepts schema variants and provider-native tool calling becomes a v0.15+ seam

Date: 2026-04-26
Status: Accepted

## Context

Through v0.14, every Allbert provider returns plain text. The kernel system prompt instructs the model to emit `<tool_call>{"name":"<tool>","input":{...}}</tool_call>` and the parser at [`lib.rs:4434`](../../crates/allbert-kernel/src/lib.rs) accepts only that exact shape.

Strong frontier models generally follow the XML format. The v0.10 fresh-profile default Ollama Gemma4 does not. An end-user transcript captured during v0.14.1 review showed Gemma4 emitting:

```text
<tool_call>{"args":["date"],"program":"date"}</tool_call>
```

The parser rejected this because it had no `name` or `input` keys, and the literal `<tool_call>` block leaked through to the user as final assistant output. The result is tool calling broken-by-default on a fresh local profile.

The deeper architectural issue is that the `LlmProvider` trait has no `tools` field on [`CompletionRequest`](../../crates/allbert-kernel/src/llm/provider.rs) and no `tool_calls` field on `CompletionResponse`. Every provider uses XML-tagged text even when the underlying API supports structured tool calls. XML-tagged text remains the universal lowest-common-denominator; it is also the least reliable on small/local models.

## Decision

v0.14.1 takes two steps without making provider-native tool calling release-blocking.

### Parser robustness

The parser accepts five shapes inside `<tool_call>...</tool_call>`:

- `{"name": <str>, "input": <object>}` — current canonical.
- `{"name": <str>, "arguments": <object>}` — OpenAI-style alias.
- `{"tool": <str>, ("input"|"args"|"arguments"|"parameters"): <object>}` — local-model alias with object input.
- `{"function": {"name": <str>, "arguments": <object>}}` — nested OpenAI legacy shape.
- `{"program": <str>, "args": [<str>...]}` — direct-spawn shape normalized to `process_exec`.

The first four shapes require object inputs. The only accepted array-args shape is the direct-spawn `program` form.

The direct-spawn form is accepted only when all authorization context agrees:

- `process_exec` is present in the active tool catalog for the turn;
- every active skill that constrains tools permits `process_exec` through `allowed-tools`;
- the requested program and arguments pass the existing `security.exec_allow` / `security.exec_deny` policy;
- the normalized input is the same structured `ProcessExecInput` the existing tool already expects, with no shell-string parsing.

Normalization is deterministic: every accepted variant produces a normal `ToolInvocation`, and normal tool dispatch still performs policy checks before execution.

On parse failure, the kernel issues exactly one corrective retry with a system message naming the canonical shape and active tool catalog. This retry is controlled by:

```toml
[intent]
tool_call_retry_enabled = true
```

Default: `true`. Validation accepts only booleans. When disabled, or after one failed retry, the kernel surfaces an operator-facing remediation rather than passing literal `<tool_call>` text through to the user.

The retry is bounded by the same daily cost cap and cost logging as any other provider call.

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
- The `tools` seam is added once; later provider-native work is additive.
- Stronger models that already emit the canonical shape continue through the original path.

## Alternatives considered

- **Switch to provider-native tool calling immediately.** Rejected for v0.14.1 because it would gate the parser fix on a multi-provider migration.
- **Drop the XML protocol entirely and require provider-native tools.** Rejected because some providers and local deployments still do not expose structured tools.
- **Train the user to avoid tool calls on Gemma4.** Rejected because the local-default profile should work out of the box.
- **Multiple retries with exponential backoff.** Rejected because cost grows quickly and most parse failures are deterministic. One corrective retry catches the realistic recovery cases.
