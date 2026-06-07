# ADR 0042: Audio, Image, And Media Resource Classes

## Status

- Accepted for the v0.48 audio slice in M4
  (`docs/plans/v0.48-plan.md`).
- Proposed for v0.49 Vision And Image Generation (`docs/plans/v0.49-plan.md`).
- The v0.48 audio amendments below are the implementation-readiness contract
  for voice. The image, screenshot, and generated-media portions remain scoped
  to v0.49 unless v0.48 explicitly narrows them.

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
this ADR (`docs/plans/v0.49-plan.md`):

- `image://capture/<id>` and `screen://capture/<id>` identify **operator-
  supplied** paste/upload media. The capture id is opaque, Allbert-Home-local,
  and never provider-selected. v0.49 adds **no autonomous OS screen capture**;
  vision analysis may also target an existing v0.43 `browser_screenshot`
  resource (distinct origin).
- Vision input is a multimodal `ReqLLM` `ContentPart` on the existing
  text-generation call; image generation is a registered `generate_image`
  action wrapping `ReqLLM.generate_image/3`. `ReqLLM` owns provider HTTP and
  credentials for both (as for text), so v0.49 adds no bespoke provider HTTP
  and requires no ADR 0011 amendment.
- v0.49 adds permission classes `:image_input` (floor `:allowed`, operator-
  supplied + redacted) and `:image_generate` (floor by resolved profile
  `media.deployment_mode`: remote → `:needs_confirmation`, fake → `:allowed`,
  unresolved → fail-closed), reusing the v0.48 floor mechanism. Operation
  classes `:image_input`/`:image_generate`, origin kind `:image_input`.
- Image input is constrained to the resolved profile's
  `image_formats_supported`, `max_image_bytes`, and `max_image_pixels`;
  oversized/unsupported media is denied before the provider call. v0.49 does
  **not** resize/convert images (no image-transcode dependency); a format/size
  mismatch is an action denial, not a widening.
- Media is default-off for retention (Allbert-Home-derived, bounded, operator-
  removable). Traces may record bounded metadata only — resource URI, byte
  size, dimensions, MIME type, provider profile, content hash, redaction
  status — and never raw image/screenshot bytes, unredacted paths, or
  credential-bearing URLs.
- v0.49 cost visibility is display-only pass-through `usage`/`cost` from
  `ReqLLM.Response`; cross-provider dashboards and budget enforcement stay
  parked.
- Video ingestion, sampled-frame analysis, and video generation are NOT part of
  v0.49; a profile may report `video_input`/transport metadata, but the release
  flow remains bounded image input + image generation.

## Consequences

Media can compose with CLI, workspace, and channels without channel adapters
becoming authority or storage systems.

## Non-Goals

- No always-on wake word for 1.0.
- No hidden cloud upload.
- No binary media in traces by default.
- No model-generated UI code.
