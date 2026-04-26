# ADR 0085: Adapter activation is local-only and base-model-pinned

Date: 2026-04-25
Status: Accepted

## Context

v0.13 trains LoRA adapters from approved durable/fact memory plus bounded recent episode summaries, optional v0.12.2 redacted trace excerpts, `SOUL.md` baseline persona, and accepted `PERSONALITY.md` adaptation hints. The natural next question is how the trained adapter actually shapes inference at runtime.

Hosted providers (Anthropic, OpenAI, Gemini, OpenRouter) do not accept locally trained LoRA adapters. They expose either no fine-tune surface or a hosted fine-tune surface that requires uploading training data — which contradicts v0.13's local-first contract and the v0.11 hosted-provider consent posture (ADR 0079).

Ollama, the v0.10 local-first default, supports adapter activation via Modelfile `FROM` + `ADAPTER` directives. llama.cpp also supports `--lora` at load time. These give Allbert a real local activation path.

The release must be explicit about which providers can activate adapters and what happens when an activation request meets a provider that cannot.

## Decision

Adapter activation is local-only in v0.13. Only the Ollama provider can activate a v0.13 adapter. Hosted providers (Anthropic, OpenRouter, OpenAI, Gemini) ignore the active-adapter pointer and the kernel logs an informational message at session start when an adapter is active and the configured provider cannot use it. The training, approval, and storage flow remains available for hosted-provider operators because adapters survive provider switches and become live again when the operator switches back to a compatible local provider.

Activation is base-model-pinned. Each adapter manifest records:

```yaml
base_model:
  provider: ollama
  model_id: gemma4
  model_digest: <sha256-of-base-weights-or-Modelfile-anchor>
```

Activation refuses with an actionable error when the active session's `model_id` does not match the manifest's `base_model.model_id`. The operator can either switch the active model to the matching base or activate a different adapter from history. Mismatches between `model_digest` values produce a warning but not a hard refusal — the operator is told the base weights have changed since training and may want to retrain.

The active-adapter pointer lives at `~/.allbert/adapters/active.json`:

```json
{
  "adapter_id": "20260501-personality-1",
  "activated_at": "2026-05-01T18:42:11Z",
  "base_model": { "provider": "ollama", "model_id": "gemma4", "model_digest": "..." }
}
```

Single-slot. Multi-adapter stacking is deferred. Activation/deactivation are explicit operator actions, never automatic side effects of install or training completion.

When the operator switches the active model (`/settings set providers.default ...` or equivalent), the kernel auto-deactivates any active adapter whose `base_model.model_id` differs from the new active model and writes a deactivation entry to `~/.allbert/adapters/history.jsonl`. The operator sees a one-line notice and can `adapters activate <id>` once a compatible model is selected again.

## Provider-side activation mechanics

For Ollama:

- The kernel's `OllamaProvider` accepts an optional `active_adapter` reference at request build time.
- When set, the provider pre-creates a per-session derived Modelfile under `~/.allbert/adapters/runtime/<adapter_id>.Modelfile` containing the `FROM` (base) + `ADAPTER` (weights) directives, and uses the resulting derived model name for chat. The derived model registration uses Ollama's `POST /api/create` endpoint and is idempotent.
- The derived registration is cached for the session and removed when the adapter is deactivated.
- The `ChatRequest.model` field stays the base model id from the operator's perspective; the activation rewrite is internal.

For other local providers added later (e.g. llama.cpp server, vLLM): the same `active_adapter` reference is plumbed through and each provider implements activation against its own format.

For hosted providers: `active_adapter` is silently ignored at the provider boundary; the kernel emits a one-shot `KernelEvent::AdapterIgnoredOnHostedProvider` that surfaces as a one-line operator notice the first time it happens in a session, then suppresses repeats for that session.

## Consequences

**Positive**

- The contract is explicit: hosted providers do not eat training data and do not pretend to apply adapters.
- Local-first operators get real personalization gains visible in the conversation.
- Base-model pinning prevents silently activating an adapter against a model whose weights have shifted.

**Negative**

- Hosted-provider operators see less benefit from v0.13. They can still train adapters against a local base for use when they switch to local. This is a stated trade-off, not a bug.
- Future provider additions must implement adapter activation explicitly to gain the local-first benefit.

**Neutral**

- Multi-adapter stacking is a deferred design space; the single-slot pointer keeps the v0.13 surface narrow.
- The auto-deactivation rule on base-model switch is a minor side effect of `/settings set` but is logged and reversible.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0066](0066-owned-provider-seam-over-rig-for-v0-10.md)
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0086](0086-adapter-approval-is-a-new-inbox-kind.md)
