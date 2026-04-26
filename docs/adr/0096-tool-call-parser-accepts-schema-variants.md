# ADR 0096: Tool-call parser accepts schema variants and provider-native tool calling becomes a v0.15+ seam

Date: 2026-04-26
Status: Accepted

## Context

Through v0.14, every Allbert provider returns plain text. The kernel system prompt instructs the model to emit `<tool_call>{"name":"<tool>","input":{...}}</tool_call>` and the parser at [`lib.rs:4434`](../../crates/allbert-kernel/src/lib.rs) accepts only that exact shape.

Strong frontier models (Claude, GPT-4) follow the XML format reliably. The v0.10 fresh-profile default Ollama Gemma4 does not. An end-user transcript captured during v0.14.1 review showed Gemma4 emitting:

```
<tool_call>{"args":["date"],"program":"date"}</tool_call>
```

The parser rejected this (no `name` or `input` keys), and the literal `<tool_call>` block leaked through to the user as final assistant output. The result: tool calling is broken-by-default on a freshly set up profile.

The deeper architectural issue is that the `LlmProvider` trait has no `tools` field on [`CompletionRequest`](../../crates/allbert-kernel/src/llm/provider.rs) and no `tool_calls` field on `CompletionResponse`. Every provider — Anthropic, OpenAI, OpenRouter, Gemini, Ollama — uses XML-tagged text even when the underlying API supports structured tool calls (Ollama since v0.3, Anthropic via `tool_use`, OpenAI/Gemini via structured tools). XML-tagged text is the universal lowest-common-denominator; it is also the least reliable on small/local models.

## Decision

v0.14.1 takes two steps in the same release without making provider-native tool calling release-blocking.

### Parser robustness

The parser accepts five canonical shapes inside `<tool_call>...</tool_call>`:

- `{"name": <str>, "input": <object>}` — current canonical.
- `{"name": <str>, "arguments": <object>}` — OpenAI-style alias.
- `{"tool": <str>, ("input"|"args"|"arguments"|"parameters"): <object>}` — Gemma/Mistral-style alias.
- `{"function": {"name": <str>, "arguments": <object>}}` — nested OpenAI legacy.
- `{"program": <str>, "args": [<str>...]}` — direct-spawn shape, mapped only to `process_exec` and only when the program matches the active `security.exec_allow` policy.

Normalization is deterministic and lossless: every accepted variant produces the same `ToolInvocation` the kernel already operates on. The system prompt names accepted variants and continues to prefer `{"name", "input"}` for compatibility.

On parse failure, the kernel issues exactly one corrective retry with a system message naming the canonical shape and the active tool catalog. After one failed retry, the kernel surfaces an operator-facing remediation rather than passing literal `<tool_call>` text through to the user.

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

In v0.14.1 every shipped provider sets `tool_calls = vec![]` and the kernel keeps using XML-tagged text. The seam is added now so v0.15 can add provider-native tool calling per provider without re-migrating `LlmProvider`.

When v0.15 lands provider-native tool calling, the kernel call site prefers `tool_calls` when non-empty, falls back to XML parsing when empty. Both code paths coexist; no flag day.

## Consequences

- The default Gemma4 profile can call tools reliably in v0.14.1 because the parser accepts the shapes Gemma actually emits.
- The XML protocol stays universal; no provider becomes a hard dependency on structured tool calling.
- The `tools` seam is added once. v0.15+ provider-native work is additive.
- Stronger models (Claude, GPT-4) are unaffected; their canonical-shape outputs continue to parse on the original path.
- The retry budget (one corrective re-prompt per assistant turn) is bounded by the daily cost cap and shows up in cost logs like any other provider call.
- Any future shape that small models emit can be added to the variant set as a one-line addition; the deterministic normalization keeps the kernel call site simple.

## Alternatives considered

- **Switch to provider-native tool calling immediately.** Rejected for v0.14.1 because it would gate the parser fix on a multi-provider migration, and the doc-reconciliation release should not stack a major architectural change.
- **Drop the XML protocol entirely and require provider-native tools.** Rejected because some providers (and some local-model deployments) still don't expose structured tools, and the universal default must keep working.
- **Train the user to phrase prompts that avoid tool calls on Gemma4.** Rejected because the origin and vision both promise that the local-default profile works out of the box.
- **Multiple retries with exponential backoff.** Rejected because cost grows quickly and most parse failures are deterministic. One corrective retry catches the realistic recovery cases.
