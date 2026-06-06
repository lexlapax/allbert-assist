# Provider Capabilities Developer Notes

Status: planned for v0.48 M1-M3.

v0.48 generalizes the v0.39 provider/model substrate. A provider is a
connection profile. A model profile declares what that connection can do.
Consumers ask for a task or capability and receive a validated profile through
the preference resolver.

## Authority Model

- Settings Central is authority for configured providers, model profiles, and
  operator preferences.
- `apps/allbert_assist/priv/provider_catalog/models.json` is seed data only.
  It may provide default capabilities, modalities, aliases, and local/offline
  defaults, but it never grants permission or supplies secrets.
- ADR 0051 defines the capability vocabulary and preference shape.
- ADR 0047 defines doctor output. Doctor success is diagnostic evidence, not a
  permission grant and not an automatic settings write.
- Security Central still decides whether a provider-backed action can run.

## Capability Vocabulary

The v0.48 vocabulary is:

- `text_generation`
- `speech_to_text`
- `text_to_speech`
- `vision_input`
- `image_generation`
- `video_input`
- `streaming`
- `embeddings`
- `tool_use`

Additions after v0.48 require an ADR update if they affect operator-visible
settings, provider doctor fields, or permission policy.

## Resolver Contract

New runtime code should not branch directly on `intent.model_profile` or profile
names. It should ask the resolver for a task or capability:

- `:text_generation` for ordinary model-backed replies;
- `:direct_answer` for direct-answer routing;
- `:coding` for coding-oriented model use;
- `:speech_to_text` for transcription;
- `:text_to_speech` for synthesis.

The resolver walks `model_preferences.tasks.<task>` or
`model_preferences.capabilities.<capability>` in order, skips disabled profiles
and disabled providers, validates declared capabilities, and then falls back to
`model_preferences.primary` only when the primary profile satisfies the
requested capability. Otherwise it returns a bounded no-capable-profile error.

Existing text settings remain compatibility aliases:

- `intent.model_profile` maps to the primary text-generation preference.
- `intent.direct_answer_model_profile` maps to the direct-answer preference.

Aliases are for migration. New v0.48+ code should use the resolver.

## Voice Notes

Voice providers use the same model-profile and doctor contract:

- STT requires `speech_to_text`.
- TTS requires `text_to_speech`.
- CLI voice uses a file path or fixture.
- Workspace microphone capture uses `mic://capture/<id>` and a confirmed action.
- Fake STT/TTS providers are release-test fixtures, not operator defaults.
- Credentialed remote STT/TTS can upload audio or incur cost, so policy and
  result metadata must stay explicit.

## Validation

Implementation milestones should add focused tests for:

- capability metadata loading and merge behavior;
- ranked preference resolution and fallback;
- compatibility aliases;
- disabled provider/profile skips;
- doctor additive fields;
- audio redaction and retention defaults;
- `release.v048` coverage for fake STT/TTS.
