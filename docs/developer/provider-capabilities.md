# Provider Capabilities Developer Notes

Status: M1-M4 implemented.

v0.48 generalizes the v0.39 provider/model substrate. A provider is a
connection profile. A model profile declares what that connection can do and,
when media is involved, how it can do it. Consumers ask for a task or
capability and receive a validated profile through the preference resolver.

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
- `token_streaming`
- `embeddings`
- `tool_use`

Additions after v0.48 require an ADR update if they affect operator-visible
settings, provider doctor fields, or permission policy.

Capabilities are routing predicates, not the full media schema. `speech_to_text`
and `text_to_speech` are the executable v0.48 voice capabilities.
`token_streaming` means streaming text tokens or text deltas. Realtime audio
sessions, file upload, local endpoint use, and bundled local execution live in
profile media metadata:

```json
{
  "media": {
    "input_modalities": ["audio"],
    "output_modalities": ["text"],
    "transport_modes": ["request_file"],
    "deployment_mode": "fake",
    "audio_formats_supported": ["wav"],
    "audio_sample_rates_supported": [16000],
    "max_audio_bytes": 10485760,
    "max_audio_duration_ms": 120000
  }
}
```

Known `deployment_mode` values: `fake`, `local_endpoint`, `bundled_local`,
`remote_credentialed`.

Known `transport_modes` values: `request_file`, `live_upload`,
`realtime_session`, `local_endpoint`, `bundled_local`.

`video_input` is vocabulary for later media work. v0.48 must not treat generic
audio/video understanding metadata as an STT/TTS provider.

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
- Local-endpoint voice providers target the v0.48 Allbert-owned localhost
  contract: `POST /v1/audio/transcriptions`, `POST /v1/audio/speech`, and
  `GET /v1/doctor`.
- Bundled-local providers are explicitly configured offline engines behind a
  bounded helper. The release lane does not require packaging a concrete engine.
- Credentialed remote STT/TTS can upload audio or incur cost, so policy and
  result metadata must stay explicit.
- M4 added `mic://capture/<id>` resource identity, voice permission floors,
  audio metadata redaction, `voice.*` bounds/retention settings, and the
  bounded transcode spec helper. M5-M7 add the executable STT/TTS flows.
- Voice doctor fields use the ADR 0047 names: `provider_capabilities`,
  `provider_deployment_mode`, `speech_to_text_supported`,
  `text_to_speech_supported`, `audio_formats_supported`,
  `sample_rates_supported`, `provider_usage_metadata_available`,
  `local_runtime_present`, and `fixture_probe_ok`.

## Validation

Implementation milestones should add focused tests for:

- capability metadata loading and merge behavior (implemented in M1);
- media metadata validation and merge behavior (implemented in M1);
- ranked preference resolution and fallback (implemented in M2);
- compatibility aliases (implemented in M2);
- disabled provider/profile skips (implemented for disabled providers and
  incapable/missing profiles in M2);
- doctor additive fields (implemented in M3);
- audio redaction, permission floors, retention defaults, and transcode bounds
  (implemented in M4);
- `release.v048` coverage for fake STT/TTS.
