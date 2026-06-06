# ADR 0042: Audio, Image, And Media Resource Classes

## Status

- Proposed for v0.48 Voice Modality (`docs/plans/v0.48-plan.md`).
- Proposed for v0.49 Vision And Image Generation (`docs/plans/v0.49-plan.md`).
- The v0.48 audio amendments below are the implementation-readiness contract
  for voice. The image, screenshot, and generated-media portions remain scoped
  to v0.49 unless v0.48 explicitly narrows them.

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
- Voice adds operation classes for microphone capture, transcription, and
  synthesis. Security Central policy must distinguish local/test providers
  from credentialed remote providers, because remote STT/TTS can upload audio
  or synthesize billable output.
- Microphone capture and cloud STT/TTS cannot be configured below
  `:needs_confirmation`. A fake deterministic provider used by tests grants no
  external authority and may run in the release gate without prompting.
- Traces may include bounded text transcripts, provider/profile identifiers,
  duration, mime type, byte count, and redacted cost/usage metadata. They must
  not include raw audio bytes, unredacted audio file paths, microphone capture
  payloads, or credential-bearing URLs.
- Audio retention is default-off. If a later setting allows retained audio, the
  retained path must be Allbert Home-derived, size-bounded, redacted in traces,
  and separately removable by the operator.
- v0.48 cost visibility is display-only metadata on STT/TTS action results and
  traces. Cross-provider dashboards and budget enforcement remain parked.

The v0.49 image/screenshot portion will amend this ADR separately when the
vision plan is deepened.

## Consequences

Media can compose with CLI, workspace, and channels without channel adapters
becoming authority or storage systems.

## Non-Goals

- No always-on wake word for 1.0.
- No hidden cloud upload.
- No binary media in traces by default.
- No model-generated UI code.
