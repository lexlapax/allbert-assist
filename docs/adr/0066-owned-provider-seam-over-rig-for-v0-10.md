# ADR 0066: Keep Allbert's owned provider seam instead of adopting Rig in v0.10

Status: Accepted

## Context

v0.10 expands Allbert's model-provider support from Anthropic and OpenRouter to Anthropic, OpenRouter, OpenAI, Gemini, and local Ollama. That raised the obvious framework question: should Allbert keep writing direct provider clients, or adopt a Rust provider framework such as Rig?

Rig is attractive. It is a Rust library for LLM-powered applications focused on ergonomics and modularity, and it already carries provider and agent-oriented abstractions that could reduce boilerplate.

Allbert's provider seam, however, is not only an HTTP abstraction. It is wired into:

- kernel-owned tool execution and policy gates;
- cost logging and daily-cap enforcement;
- daemon/client protocol payloads;
- REPL and setup model switching;
- job and skill-contributed agent model overrides;
- channel capability checks for image input;
- local-first posture where Ollama needs no API key and no hosted gateway.

## Decision

Allbert keeps its owned `LlmProvider` seam in v0.10 and adds OpenAI, Gemini, and Ollama as direct provider implementations.

Rig is not adopted as the runtime provider framework in v0.10.

## Rationale

The current seam is intentionally narrow: complete a prompt, report usage, expose pricing, expose provider name, and declare image-input support. That narrow shape keeps provider behavior auditable and lets the kernel remain the policy surface.

Adopting Rig now would require adapting or bypassing several kernel-owned surfaces at once. That is extra migration risk during a release whose primary goal is user-visible provider expansion and a local-first default.

Rig remains worth revisiting later if Allbert needs capabilities it is specifically good at, such as embeddings/RAG integrations, richer model registries, or provider-side agent/tool abstractions. Those are not v0.10 goals.

## Consequences

- Provider clients remain small direct HTTP modules under `crates/allbert-kernel/src/llm/`.
- Allbert owns provider request/response mapping, usage parsing, pricing tables, and image serialization.
- v0.10 can make `api_key_env` optional and add `base_url` without fitting another framework's model config shape.
- There is more provider-specific boilerplate than a framework would provide.
- Future framework adoption remains possible behind the same `LlmProvider` trait if the tradeoff changes.

## References

- [docs/plans/v0.10-provider-expansion.md](../plans/v0.10-provider-expansion.md)
- [ADR 0005](0005-support-anthropic-and-openrouter-in-v0-1.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0064](0064-default-contributor-validation-is-provider-free-temp-home-based-and-network-optional.md)
- [Rig crate docs](https://docs.rs/rig-core/latest/rig/)
