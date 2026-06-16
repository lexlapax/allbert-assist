# ADR 0061: Local Embedding Capability And Router Model Tiers

## Status

Proposed for v0.54 (Intent Deepening) — `docs/plans/v0.54-plan.md`. Accepted at
v0.54 M7 closeout after release evidence.

This ADR provides the model substrate the two-stage intent router (ADR 0060)
needs: a **local text-embedding capability** (which does not exist today) and the
**router model tiers** (embedding, local reasoning, optional hosted escalation).
It lands in v0.54, resequenced ahead of completing v0.53.

## Context

ADR 0060's Stage 1 prefilter requires **text embeddings**. The `embeddings`
capability is already named in `Settings.ProviderCatalog.known_capabilities/0`,
but **no model profile declares it and there is no embedding client, no vector,
and no index** — a repo-wide search for an embedding client/`vector` finds
nothing in `apps/` or `plugins/`. What does exist and is reused:

- A model-resolution layer: `Models.for(capability)` + `model_profiles.*` +
  `model_routing` capability aliases (e.g. `text_generation → ["local", "fast"]`).
- Schema-**constrained** structured output: `ReqLLM.generate_object` (already used
  by `Intent.Classifier.DefaultClassifier`).
- A local **Ollama** posture: the voice runtime already calls Ollama
  (`voice.local_runtime.ollama_base_url`, STT model config) — precedent for a
  local model dependency the operator pulls and a doctor reports.

Constraints from the local-first vision and the routing research:

- Routing must work **offline by default**; the network-egress, audited path is
  opt-in only.
- Small local models (≈3B) are unreliable at open tool selection but usable at
  **constrained disambiguation over a shortlist**; **7–8B** is materially better
  at multi-slot extraction; hosted models are best for the low-confidence tail.
- **Pretraining-aligned action names** (`create_note`, `search_notes`, `open_url`)
  cut small-model tool-name hallucination substantially; this is a data-level
  requirement on the action surface, recorded here and built in the plan.

## Decision

### Local embedding capability

- Use the existing **`embeddings`** model capability (already named in
  `Settings.ProviderCatalog.known_capabilities/0`) and add an **embedding
  profile** resolved through the existing `Models.for/model_profiles` machinery.
  Default to a local Ollama embedding model (e.g. `nomic-embed-text` or a
  `bge-small` GGUF), reusing the voice `ollama_base_url` host posture. (The
  capability exists today, but no model profile declares it and there is no
  embedding client or index — those are net-new.)
- A thin `Intent.Router.Embedder` client calls the Ollama embeddings endpoint and
  returns vectors. **No external vector database.** The action/descriptor
  **utterance index is an in-memory cosine index** built at boot from the
  registered descriptors/actions and refreshed on registry change
  (`ExtensionsRegistry`/`ActionsRegistry` notification). Embedding is **local-only
  — no network egress.**
- A `router doctor` (ADR 0047 envelope style) reports embedding endpoint/model
  availability, index size, and last refresh, redacted.

### Router model tiers

- **Stage 1 embedding** → the local embedding profile
  (`intent.router_embedding_profile`, default the local Ollama embedding model).
- **Stage 2 disambiguation default** → a **local 7–8B profile**
  (`intent.router_model_profile`, default e.g. `qwen2.5:7b` or `llama3.1:8b`),
  chosen for multi-slot reliability. This is the router's default reasoning model
  and is distinct from the `direct_answer`/general `local` profile.
- **Optional hosted escalation** → a settings-gated escalation profile
  (`intent.router_escalation_profile`, default **off**), invoked **only** on a
  low-confidence/complex Stage-2 outcome. When off, low confidence falls to
  **targeted clarify** (never silently downgraded). Escalation **sends the
  utterance text to a remote provider**, so it is **audited** through Security
  Central and is never required for the default offline path.

### Naming + index hygiene

- Action/tool names exposed to the router use **pretraining-aligned verbs**.
- Descriptor coverage includes write/create actions (the missing-`write_note`
  class of gap is closed in the plan), and the embedding index deduplicates and
  sharpens overlapping descriptors so similarity alone cannot conflate
  "create" vs "search".

## Consequences

- New local embedding path: client + `embeddings`-capability profile + index +
  in-memory utterance index + doctor. Adds an Ollama embedding model the operator
  pulls; the doctor reports availability and the router degrades to the
  deterministic fallback (ADR 0060) if it is missing.
- Default routing is fully **local/offline**; hosted escalation is opt-in and
  audited.
- `model_profiles` gains an embedding profile and a 7–8B router profile. Operators
  on constrained hardware may point `intent.router_model_profile` at a smaller
  model at a documented reliability cost, or pin `intent.router_strategy =
  :deterministic`.

## Related

- ADR 0060 (two-stage intent router — the consumer of this substrate), ADR 0051
  (provider capability preferences), ADR 0052 (local voice runtime endpoint —
  the Ollama-posture precedent), ADR 0006 (Security Central — escalation audit),
  ADR 0047 (provider doctor envelope).
- `docs/plans/v0.54-plan.md`.
