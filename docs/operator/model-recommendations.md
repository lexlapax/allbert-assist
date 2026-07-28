# Allbert Model Recommendations (Which Model For What)

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

This is the canonical operator guide for *which model to use for what purpose*
in Allbert (ADR 0072, extended by the v1.2 bakeoff). It is **advice**: actual
configuration lives in Settings Central, and you override any row with the
documented key. No recommendation enables network egress or lowers a safety
floor — hosted profiles are always an explicit, audited operator opt-in.

Verify your setup at any time:

```sh
allbert admin intent doctor             # intent-purpose rows
allbert admin settings model-doctor     # recommended vs configured vs status
```

For the first-chat catalog and selection surface, use
`allbert admin models catalog [PURPOSE]`, TUI `/catalog`, or the web Models
panel. TUI `/models` is the separate model-health view. The catalog surfaces
share one read-only registered action. Runtime text fallback is off by default;
local-to-hosted fallback additionally requires
`models.fallback.allow_local_to_hosted=true`.

## v1.2 Local First-Chat Decision

The curated consumer default remains `llama3.2:3b`. The M4 macOS arm64 bakeoff
used 12 warm prompts per model across JSON, tool-shaped JSON, Spanish, and
context recall with Qwen thinking disabled:

| Model | Correct | Mean | Throughput | v1.2 disposition |
|---|---:|---:|---:|---|
| `llama3.2:3b` | 8/12 (66.7%) | 740.6 ms | 144.5 tok/s | Cross-platform consumer default; 8 GB floor. |
| `qwen3:4b-instruct` | 12/12 (100%) | 811.4 ms | 121.0 tok/s | Recommended opt-in when tool/JSON conformance matters more than throughput; macOS-evidenced, not cross-platform-promoted. |
| `qwen3.5:4b` | 10/12 (83.3%) | 956.5 ms | 106.2 tok/s | Catalog alternative for operators evaluating Qwen 3.5 behavior. |
| `qwen3.5:9b` | 8/12 (66.7%) | 956.8 ms | 74.9 tok/s | 16 GB reasoning/catalog option; not recommended as the v1.2 first-chat replacement. |

`qwen3:4b-instruct` cleared the fixed quality and mean-latency thresholds, but
its 16.2% throughput regression exceeded the 10% promotion limit. Linux x64
was unavailable, so no candidate had the required cross-platform promotion
evidence. The result supports a task-specific Qwen recommendation, not a silent
default or hardware-floor change.

Status values: `ok` · `missing` (no profile set) · `under-capable` (model too
small/wrong capability) · `not-pulled` (local model not downloaded) ·
`remote-egress-warning` (a hosted profile is configured).

## Recommendation matrix

| Purpose | Recommended local | Hosted alternative (opt-in, audited) | Min capability / size | Privacy posture | Settings key / profile | Fallback when unavailable |
|---|---|---|---|---|---|---|
| Intent Stage-1 embedding | `nomic-embed-text` (or `bge-small`) via Ollama | — keep local | embeddings, ~300M–1.4B | **local-only required** | `intent.router_embedding_profile = embedding_local` | Prefilter returns fallback → deterministic ladder |
| Intent Stage-2 disambiguation | `llama3.1:8b` | a capable hosted chat model | constrained-object/JSON, 7–8B | local-first | `intent.router_model_profile = router_local` | heuristic / clarify |
| Intent escalation (low-confidence tail) | `gemma4:26b` (local) | capable hosted | larger reasoning | local default; egress audited | `intent.router_escalation_profile = router_escalation_local` | second pass -> clarify |
| Descriptor generation (v0.56) | reuse `router_local` | — keep local in v0.56 | json_schema generation | local-only, redacted | reuses `intent.router_model_profile` | heuristic generator |
| Intent eval **live** bench (v0.56) | reuse `router_local` | — | same as disambiguation | local | reuses `intent.router_model_profile` | deterministic gate is model-free |
| Main conversational loop | `:capable` / `:thinking` (object), `:fast` (text/stream) | per provider | text + structured output | operator choice | `jido_ai` aliases (config) + Settings Central model profiles | graceful decline |
| Voice STT / TTS | per `docs/operator/voice-and-provider-preferences.md` | OpenAI / Gemini (audited) | audio in/out | per provider | `voice.*` | voice doctor reports gap |
| Vision / image generation | per provider catalog (v0.49) | image provider (audited) | image generation | per provider | image profile | provider doctor reports gap |
| Codegen committee (Author/Critic) | `:capable` / `:thinking` | capable hosted | strong reasoning, long context | sandboxed; gated | codegen profiles | gate report blocks |
| Advisory critics / LLM-judge | `:capable` (local) | hosted (audited) | reasoning | advisory-only (never authority) | per-feature profile | advisory output dropped |
| Pi-mode coding (v0.57) | `pi_coding_local`: local/private model proven to emit real provider tool calls + mid-session switch | capable hosted coding profile, explicit egress opt-in | coding, long context, real tool-call chunks; `ReqLLM.stream_text` + `StreamResponse.cancel` | local-coding operator trust tier at sandbox Level 1; audited, never default | `coding.model_profile = pi_coding_local` by default; `/model <profile>` is session-only | explicit profile-compatibility diagnostic or graceful decline; no hosted fallback without operator choice |

For Pi-mode, prefer `pi_coding_local` for repository work. It is distinct from
`coding_local`: `coding_local` remains the codegen-committee fallback, while
`pi_coding_local` is the interactive tool-loop profile and must emit real
provider tool-call chunks for `read`/`grep`/`write`/`edit`/`bash`. Hosted profiles
are acceptable only when the operator explicitly accepts source-code egress for
that home/session. `/model <profile>` changes the in-memory Pi-mode session model
only; it never changes permissions, approval mode, trusted operator, cwd jail, or
confirmation behavior. Live assistant-token streaming and provider-level Esc
cancel use the selected provider path with `ReqLLM.stream_text` and
`ReqLLM.StreamResponse.cancel`; validation should choose a coding profile that
supports streaming, real tool calls, and provider cancel.

## Pulling local models

The intent and codegen local recommendations run on Ollama (the same runtime voice
already uses). Typical setup:

```sh
ollama pull nomic-embed-text
ollama pull llama3.1:8b
ollama pull qwen2.5:7b     # Pi-mode tool-loop profile
ollama pull gemma4:26b      # optional local escalation tier
allbert admin intent doctor # confirm embedder + router model report ok
```

For the v1.2 first-chat alternatives, prefer the web Models panel so catalog
selection and any pull stay on the reviewed Settings/confirmation path. If you
explicitly manage Ollama yourself, the evaluated opt-in tag is
`qwen3:4b-instruct`; `qwen3.5:9b` has a 16 GB catalog floor and is intended for
reasoning experiments rather than first-chat replacement.

> Tag note (rechecked against official Ollama library pages on 2026-06-22):
> current Ollama model docs list `gemma4:26b` for local workstation escalation and
> `gemma4:e2b` / `gemma4:e4b` for edge local use. v0.56 keeps the existing Settings
> Central defaults aligned to those public tags; `model_doctor` reports `not-pulled`
> for any tag you have not yet pulled.

## Privacy and egress

- Local profiles never leave the machine. The embedder enforces a local-only
  endpoint and refuses a remote profile (ADR 0061).
- Descriptor generation is also local-only in v0.56: a remote or disabled
  `intent.router_model_profile` is refused before any model call and the heuristic
  generator is used instead.
- `router_escalation_local` is local by default and should report as local in the
  doctor. Hosted escalation remains an explicit Settings Central override and
  must be doctor-flagged with `remote-egress-warning`.
- Any hosted profile is an explicit operator opt-in, configured through Settings
  Central and audited at the capability/egress boundary (ADR 0051, Security
  Central / ADR 0006). The doctor flags a configured hosted profile with
  `remote-egress-warning` so it is never a surprise.
- Descriptor generation is local-only and redacted by default. Learned-review
  proposal-mining infrastructure accepts reviewed evidence maps and redacts them
  before writing review YAML; v0.56 does not wire autonomous runtime producers
  (ADR 0062).

## Related

- ADR 0072 (this recommendation as a decision), ADR 0061 (router model tiers),
  ADR 0051 (capability preferences), ADR 0047 (doctor contract).
- `docs/operator/voice-and-provider-preferences.md` (voice-specific slice).
- `docs/developer/provider-capabilities.md` (developer-facing capability substrate).
