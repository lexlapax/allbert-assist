# ADR 0042: Audio, Image, And Media Resource Classes

## Status

Proposed for v0.45 Voice Modality and v0.46 Vision And Image Generation
(`docs/plans/v0.45-plan.md`, `docs/plans/v0.46-plan.md`).

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

## Consequences

Media can compose with CLI, workspace, and channels without channel adapters
becoming authority or storage systems.

## Non-Goals

- No always-on wake word for 1.0.
- No hidden cloud upload.
- No binary media in traces by default.
- No model-generated UI code.
