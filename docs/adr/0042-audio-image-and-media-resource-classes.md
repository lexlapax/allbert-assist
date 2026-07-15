# ADR 0042: Audio, Image, And Media Resource Classes

## Status

- Accepted for the v0.48 audio slice in M4
  (`docs/plans/archives/v0.48-plan.md`).
- Accepted for the v0.49 image/screenshot amendment in M1
  (`docs/plans/archives/v0.49-plan.md`) after catalog/settings, app-started ReqLLM
  probe, and fixture-profile evidence.
- Accepted for the v0.50 artifact-resource amendment after Artifacts Central,
  retained-media backfill, the supervised ingestion sensor, and `release.v050`
  evidence landed.
- The v0.48 audio amendments below are the implementation-readiness contract
  for voice. The v0.49 image, screenshot, and generated-media portions are
  shipped as bounded media resources; the v0.50 amendment below promotes
  durable retained media into the canonical artifact resource class.

v0.48 M4 closeout evidence:

- `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/resources/resource_uri_test.exs apps/allbert_assist/test/allbert_assist/resources/operation_class_test.exs apps/allbert_assist/test/allbert_assist/security/permission_gate_test.exs apps/allbert_assist/test/allbert_assist/runtime/redactor_test.exs apps/allbert_assist/test/allbert_assist/voice/transcode_test.exs apps/allbert_assist/test/allbert_assist/settings_test.exs`

v0.48 M8 closeout evidence:

- `mix allbert.test release.v048` covers audio resource identity, permission
  floors, trace redaction, transcode bounds, retention default-off posture,
  workspace microphone confirmation, STT/TTS actions, Telegram voice-note
  ingestion, and the v0.48 voice-modality eval rows.

M8R/M8R7 release correction: the M8 evidence above proves the fixture/security
surface only. v0.48 release readiness now requires executable real-provider
voice paths: the Allbert-owned local voice runtime STT/TTS, OpenAI remote
STT/TTS, Gemini remote STT/TTS, bounded transcode materialization, and a local
Ollama text turn between STT and TTS.

## Context

Voice and vision are modalities, not separate runtimes. Allbert needs to model
microphone capture, TTS output, image input, screenshots, and generated media
without bypassing Resource Access or provider policy.

## Decision

- Microphone capture is a Resource Access consumer such as
  `mic://capture/<id>`.
- TTS output is a registered action with provider profile and cost visibility.
- Image input is a Resource Access consumer such as `image://capture/<id>`.
- Screenshot capture is a Resource Access consumer such as
  `screen://capture/<id>`.
- Image generation is a registered action with provider profile.
- Raw media is bounded and redacted from traces by default.
- Retention is explicit and default-off unless a milestone narrows it.

### v0.48 Audio Amendments

v0.48 implements only the audio portion of this ADR:

- `mic://capture/<id>` identifies a bounded workspace microphone capture. The
  capture id is opaque, local to Allbert Home, and never a provider-selected
  target.
- CLI voice input uses an operator-supplied audio file path or fixture. Live
  microphone capture is workspace-only.
- Captured audio is normalized to a provider-accepted format by a bounded
  ffmpeg-class transcode step before the provider call: input is size- and
  duration-bounded, the output format is chosen from the resolved provider's
  `audio_formats_supported`, and no operator- or model-supplied codec flags are
  passed. The transcoder is an external binary dependency, not a provider.
  The helper uses a fixed command template, rejects network/protocol inputs,
  writes only to a temp or Allbert Home-derived path, and redacts both source
  and output paths in traces. Missing transcode support is a doctor diagnostic
  or action error, not a reason to widen accepted provider inputs.
  M8R materializes this spec for real provider calls; a plan-only argv spec is
  insufficient when the selected provider does not accept the source audio
  format.
- Voice adds operation classes for microphone capture, transcription, and
  synthesis. Security Central policy must distinguish local/test providers
  from credentialed remote providers, because remote STT/TTS can upload audio
  or synthesize billable output.
- Microphone capture cannot be configured below `:needs_confirmation` for any
  deployment mode. STT/TTS floors derive from the resolved profile's
  `media.deployment_mode`: `fake` and `bundled_local` (no audio leaves the
  BEAM) may be `:allowed`; `local_endpoint` and `remote_credentialed` (audio
  crosses a socket) are `:needs_confirmation`. A fake deterministic provider
  used by tests grants no external authority and may run in the release gate
  without prompting; an unresolvable deployment mode fails closed to
  `:needs_confirmation`.
- Traces may include bounded text transcripts, provider/profile identifiers,
  duration, mime type, byte count, and redacted cost/usage metadata. They must
  not include raw audio bytes, unredacted audio file paths, microphone capture
  payloads, or credential-bearing URLs.
- Audio retention is default-off. If a later setting allows retained audio, the
  retained path must be Allbert Home-derived, size-bounded, redacted in traces,
  and separately removable by the operator.
- v0.48 cost visibility is display-only metadata on STT/TTS action results and
  traces. Cross-provider dashboards and budget enforcement remain parked.
- Realtime audio sessions and generic audio/video understanding are not part of
  the v0.48 media-resource implementation. A profile may report such transport
  metadata, but the release flow remains bounded file/capture STT and TTS.
- Local Ollama is a text-generation provider in the middle of the voice flow,
  not an audio media resource provider in v0.48.

### v0.49 Image/Screenshot Amendments

v0.49 implements the image input, screenshot, and image-generation portions of
this ADR (`docs/plans/archives/v0.49-plan.md`):

- `image://capture/<id>` and `screen://capture/<id>` identify **operator-
  supplied** paste/upload media. The capture id is opaque, Allbert-Home-local,
  and never provider-selected. v0.49 adds **no autonomous OS screen capture**;
  vision analysis may also target a browser screenshot surfaced through the
  v0.43 `browser_screenshot` read operation / `screenshot_ref`. There is no
  pre-existing `image://`-style screenshot resource URI to inherit; v0.49 maps
  the `screenshot_ref` into the new image-resource path while keeping the
  browser-page screenshot origin distinct from operator-supplied media.
- Vision input is a multimodal `ReqLLM` `ContentPart` on the existing
  text-generation call; image generation is a registered `generate_image`
  action wrapping `ReqLLM.generate_image/3`. `ReqLLM` owns provider HTTP and
  credentials for both (as for text), so v0.49 adds no bespoke provider HTTP
  and requires no ADR 0011 amendment. M1 must prove this in Allbert's
  app-started runtime with `ReqLLM.Providers.list/0`,
  `ReqLLM.Images.validate_model/1`, and fixture-backed request paths; a
  `mix run --no-start` provider/model probe is not release evidence.
- v0.49 adds permission classes `:image_input` (floor `:allowed`, operator-
  supplied + redacted) and `:image_generate` (floor by resolved profile
  `media.deployment_mode`, reusing the v0.48 `voice_floor` mechanism: fake →
  `:allowed`; remote/unresolved/unknown → `:needs_confirmation`
  (fail-safe-to-confirm, never auto-`:allowed`). Operation classes
  `:image_input`/`:image_generate`, origin kind `:image_input`. M2 implements
  these vocabulary, policy, and Settings Central entries.
- Image input is constrained to the resolved profile's
  `image_formats_supported`, `max_image_bytes`, and `max_image_pixels`;
  oversized/unsupported media is denied before the provider call. M2 adds a
  shared `ImageBounds` helper for input/output bounds. v0.49 does **not**
  resize/convert images (no image-transcode dependency); a format/size mismatch
  is an action denial, not a widening.
- Provider/profile metadata validation must accept image media keys only as
  descriptive bounds: `image_formats_supported`, `max_image_bytes`, and
  `max_image_pixels`. These keys never grant permission and never replace
  Resource Access or Security Central checks.
- Media is default-off for retention (Allbert-Home-derived, bounded, operator-
  removable). Traces may record bounded metadata only — resource URI, byte
  size, dimensions, MIME type, provider profile, content hash, redaction
  status — and never raw image/screenshot bytes, unredacted paths, or
  credential-bearing URLs. The content hash is metadata for integrity,
  provenance, and redaction checks only in v0.49; canonical content-addressed
  artifact storage, lifecycle policy, deduplication, and cross-surface lookup are
  proposed for the v0.50 artifact-management follow-on.
- v0.49 cost visibility is display-only pass-through `usage`/`cost` from
  `ReqLLM.Response`; cross-provider dashboards and budget enforcement stay
  parked.
- Video ingestion, sampled-frame analysis, video generation, and generic audio
  understanding are NOT part of v0.49; a profile may report
  `video_input`/transport metadata, but the release flow remains bounded image
  input + image generation. There is no catch-all `multimodal` capability or
  all-purpose media router in this ADR.

### v0.50 Artifact Resource Amendment

v0.50 implements the artifact-management follow-on reserved by v0.49
(`docs/plans/archives/v0.50-plan.md`, ADR 0053, ADR 0054):

- `artifact://sha256/<hex>` identifies a durable, content-addressed artifact in
  Allbert Home. The hash is lowercase SHA-256 over the bytes and is distinct
  from transport/capture identities such as `mic://capture/<id>`,
  `image://capture/<id>`, `screen://capture/<id>`, browser cache refs, generated
  media handles, and future channel attachment identifiers.
- Artifact identity is inert. A content address, metadata sidecar, browser row,
  or thread link never grants read/write/send authority; all reads and writes
  still resolve through Resource Access, Security Central, and registered
  actions.
- v0.50 adds permission classes `:artifact_read` and `:artifact_write` with
  floor `:allowed`, and `:artifact_delete` with floor `:needs_confirmation`.
  It adds operation classes `:artifact_read`, `:artifact_write`,
  `:artifact_delete`, and origin kind `:artifact_store`.
- Metadata is allow-listed and trace-safe only: `sha256`, MIME/type, byte size,
  origin, source resource URI, created time, retention/lifecycle/redaction
  state, and bounded provenance. Raw bytes, unredacted file paths, provider
  payloads, and filenames-as-content do not enter traces, audits, LiveView
  assigns, or CLI output.
- Retention remains default-off. v0.50 backfills retained v0.48 audio, v0.49
  vision input media, and v0.49 generated-image outputs into the CAS; ephemeral
  scratch and historical Browser cache are out of scope for that backfill.
- Artifact provenance links live in the Repo-backed `artifact_thread_links`
  join table, not in a single artifact column. Links connect an artifact hash to
  one or more thread/message roles and are provenance only, never authority.
- The v0.50 Jido ingestion sensor is advisory. It emits ingestion-request
  signals and routes durable writes through the same `put_artifact` path as
  actions; it does not create a private storage authority or auto-promote media
  into memory.

## Consequences

Media can compose with CLI, workspace, and channels without channel adapters
becoming authority or storage systems.

## Non-Goals

- No always-on wake word for 1.0.
- No hidden cloud upload.
- No binary media in traces by default.
- No model-generated UI code.
