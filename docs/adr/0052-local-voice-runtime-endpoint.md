# ADR 0052: Allbert-Owned Local Voice Runtime Endpoint

## Status

Accepted for v0.48 M8R7 before the release tag.

## Context

v0.48 M8R added real voice adapters for local OpenAI-compatible endpoints,
OpenAI, and Gemini. That made the client-side local endpoint adapter real, but
left the local endpoint itself outside the product: an operator had to provide
an unrelated localhost speech server before the local validation path could run.

That is not sufficient for a release whose local/offline posture is a product
requirement. A port such as `5050` must not be a one-off validation fixture, and
it must not be described as "whatever server the operator happens to run."
Allbert needs an owned product endpoint with a stable contract, doctor output,
and release-gate coverage. External OpenAI-compatible servers may remain
advanced override targets, but they cannot be the v0.48 local release
authority.

Current provider research shapes the endpoint:

- Ollama exposes an OpenAI-compatible `POST /v1/audio/transcriptions`
  middleware that accepts multipart audio and maps the request to a local
  multimodal model.
- Ollama does not expose an OpenAI-compatible `POST /v1/audio/speech` TTS
  endpoint in the current docs/source inspected for M8R7.
- Bandit can host a Plug router directly with loopback binding, which gives
  the core app a narrow local HTTP endpoint without depending on Phoenix
  LiveView as the runtime authority.

## Decision

v0.48 will ship an Allbert-owned local voice runtime endpoint.

The endpoint is a product surface, not a test fixture:

- default base URL: `http://127.0.0.1:5050/v1`;
- loopback-only bind address;
- no credentials and no LAN exposure;
- OpenAI-compatible request shapes for:
  - `GET /v1/models`;
  - `GET /v1/doctor`;
  - `POST /v1/audio/transcriptions`;
  - `POST /v1/audio/speech`;
- bounded multipart input and bounded audio output;
- redacted diagnostics only;
- started and doctored by Allbert CLI commands.

The runtime owns a small adapter layer behind the endpoint:

- STT is backed by a configured local Ollama transcription model via
  Ollama's OpenAI-compatible transcription endpoint when available.
- TTS is backed by a configured local/offline TTS backend. v0.48 M8R7's first
  backend is the host local speech engine on macOS (`say`) plus bounded
  conversion to the requested OpenAI-compatible response format.
- Backend availability is doctor state. Missing Ollama, missing an audio-capable
  Ollama model, missing `say`, or missing `ffmpeg` are explicit diagnostics;
  they never silently fall back to fake audio or canned transcripts.

Allbert's existing `local_endpoint` voice adapter continues to call the
OpenAI-compatible HTTP contract. The difference is ownership: the default
release and operator validation target is the Allbert local runtime. Operators
may override `providers.local_voice.base_url` to another OpenAI-compatible
loopback server, but that is an advanced configuration path and does not replace
the Allbert runtime release gate.

## Consequences

- v0.48 is not release-ready until M8R7 implements and tests the local runtime
  endpoint.
- The local voice manual smoke must start the Allbert runtime and must not ask
  the operator to invent a server for port `5050`.
- The runtime depends on real local backends. A machine without a usable local
  STT model or local TTS backend can still use OpenAI/Gemini, but it cannot
  claim the fully local validation path.
- Fake, stub, canned, or silent providers remain automated-test fixtures only.
  They are not accepted as product or manual-validation evidence.
- Future bundled-local packaging can replace or add backends behind the same
  endpoint without changing the action/resolver/provider contract.
