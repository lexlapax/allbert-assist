# Allbert Model Recommendations (Which Model For What)

Status: authored for v0.56 (ADR 0072). This is the canonical operator guide for
*which model to use for what purpose* in Allbert. It is **advice**: actual
configuration lives in Settings Central, and you override any row with the
documented key. No recommendation enables network egress or lowers a safety
floor — hosted profiles are always an explicit, audited operator opt-in.

Verify your setup at any time:

```sh
mix allbert.intent doctor              # intent-purpose rows (embedding/disambiguation/escalation/generation/eval)
mix allbert.settings model-doctor      # every purpose: recommended vs configured vs status
```

Status values: `ok` · `missing` (no profile set) · `under-capable` (model too
small/wrong capability) · `not-pulled` (local model not downloaded) ·
`remote-egress-warning` (a hosted profile is configured).

## Recommendation matrix

| Purpose | Recommended local | Hosted alternative (opt-in, audited) | Min capability / size | Privacy posture | Settings key / profile | Fallback when unavailable |
|---|---|---|---|---|---|---|
| Intent Stage-1 embedding | `nomic-embed-text` (or `bge-small`) via Ollama | — keep local | embeddings, ~300M–1.4B | **local-only required** | `intent.router_embedding_profile = embedding_local` | Prefilter returns fallback → deterministic ladder |
| Intent Stage-2 disambiguation | `llama3.1:8b` | a capable hosted chat model | constrained-object/JSON, 7–8B | local-first | `intent.router_model_profile = router_local` | heuristic / clarify |
| Intent escalation (low-confidence tail) | `gemma4:26b` (local) | capable hosted | larger reasoning | local default; egress audited | `intent.router_escalation_profile = router_escalation_local` | second pass -> clarify |
| Descriptor generation (v0.56) | reuse `router_local` | opt-in hosted | json_schema generation | local-only, redacted | reuses `intent.router_model_profile` | heuristic generator |
| Intent eval **live** bench (v0.56) | reuse `router_local` | — | same as disambiguation | local | reuses `intent.router_model_profile` | deterministic gate is model-free |
| Main conversational loop | `:capable` / `:thinking` (object), `:fast` (text/stream) | per provider | text + structured output | operator choice | `jido_ai` aliases (config) + Settings Central model profiles | graceful decline |
| Voice STT / TTS | per `docs/operator/voice-and-provider-preferences.md` | OpenAI / Gemini (audited) | audio in/out | per provider | `voice.*` | voice doctor reports gap |
| Vision / image generation | per provider catalog (v0.49) | image provider (audited) | image generation | per provider | image profile | provider doctor reports gap |
| Codegen committee (Author/Critic) | `:capable` / `:thinking` | capable hosted | strong reasoning, long context | sandboxed; gated | codegen profiles | gate report blocks |
| Advisory critics / LLM-judge | `:capable` (local) | hosted (audited) | reasoning | advisory-only (never authority) | per-feature profile | advisory output dropped |
| Pi-mode coding (v0.57, forward-looking) | capable local coding model + mid-session switch | capable hosted | coding, long context | local coding / sandbox level 0 | (defined in v0.57) | (v0.57) |

## Pulling local models

The intent and codegen local recommendations run on Ollama (the same runtime voice
already uses). Typical setup:

```sh
ollama pull nomic-embed-text
ollama pull llama3.1:8b
ollama pull gemma4:26b      # optional local escalation tier
mix allbert.intent doctor   # confirm embedder + router model report ok
```

## Privacy and egress

- Local profiles never leave the machine. The embedder enforces a local-only
  endpoint and refuses a remote profile (ADR 0061).
- `router_escalation_local` is local by default and should report as local in the
  doctor. Hosted escalation remains an explicit Settings Central override and
  must be doctor-flagged with `remote-egress-warning`.
- Any hosted profile is an explicit operator opt-in, configured through Settings
  Central and audited at the capability/egress boundary (ADR 0051, Security
  Central / ADR 0006). The doctor flags a configured hosted profile with
  `remote-egress-warning` so it is never a surprise.
- Descriptor generation and learned mining are local-only and redacted by default
  (ADR 0062); they never emit raw prompts or secrets to traces.

## Related

- ADR 0072 (this recommendation as a decision), ADR 0061 (router model tiers),
  ADR 0051 (capability preferences), ADR 0047 (doctor contract).
- `docs/operator/voice-and-provider-preferences.md` (voice-specific slice).
- `docs/developer/provider-capabilities.md` (developer-facing capability substrate).
