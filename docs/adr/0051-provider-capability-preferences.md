# ADR 0051: Provider Capability Metadata And Operator Preferences

## Status

Accepted in v0.48 M1.

M1 closeout evidence:

- `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/settings/provider_catalog_test.exs apps/allbert_assist/test/allbert_assist/settings_test.exs`
  passed with 44 tests and 0 failures.
- The shipped provider catalog now validates profile capabilities/media and
  includes deterministic fake STT/TTS profiles as descriptive seed data.
- `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/settings/model_preferences_test.exs apps/allbert_assist/test/mix/tasks/allbert_onboard_test.exs apps/allbert_assist/test/mix/tasks/allbert_settings_test.exs apps/allbert_assist/test/mix/tasks/allbert_model_test.exs apps/allbert_assist/test/allbert_assist/actions/settings_actions_test.exs apps/allbert_assist/test/allbert_assist/actions/intent/direct_answer_test.exs apps/allbert_assist/test/allbert_assist/onboarding_test.exs`
  passed with 38 tests and 0 failures for M2 preference resolution and
  onboarding/settings compatibility.

## Context

Allbert already has a provider/model substrate:

- shipped seed data under `apps/allbert_assist/priv/provider_catalog/models.json`;
- Settings Central provider and model profile overrides;
- Jido model aliases generated from `model_profiles.*`;
- `doctor_model_profile` and ADR 0047's redacted doctor envelope;
- operator-facing model selection through `intent.model_profile` and the
  ad-hoc `intent.direct_answer_model_profile` override.

That substrate is currently text-generation shaped. Model profiles do not
declare capabilities or media metadata, and task-specific preferences are
encoded in profile names or one-off settings keys. v0.48 voice and v0.49 vision
need speech, image, and video models to use the same provider framework instead
of introducing separate voice-provider or image-provider systems.

Current providers expose materially different media shapes: request/response
audio APIs, realtime audio sessions, multimodal audio/video model inputs, local
text/vision endpoints, dedicated STT/TTS APIs, and local offline engines. The
Allbert profile contract must model those differences without treating provider
marketing metadata as permission.

## Decision

Providers are modality-agnostic connection profiles. Model profiles declare the
capabilities they support, and operator preferences choose ranked model
profiles for a task or capability.

### Capability Vocabulary

v0.48 introduces this additive vocabulary:

- `text_generation`
- `speech_to_text`
- `text_to_speech`
- `vision_input`
- `image_generation`
- `video_input`
- `token_streaming`
- `embeddings`
- `tool_use`

Later releases may add capabilities, but they must not change the meaning of
the existing names without an ADR amendment and settings migration plan.

Capability names are routing predicates:

- `speech_to_text` means audio-to-text transcription through a registered
  action.
- `text_to_speech` means text-to-audio synthesis through a registered action.
- `vision_input` means image/screenshot input analysis.
- `video_input` means video or sampled-frame input analysis; it is vocabulary
  only until a later plan implements it.
- `token_streaming` means streaming text tokens or text deltas. Realtime audio
  sessions are media transport metadata, not this capability.

Model profiles may also carry optional media metadata. Media metadata explains
how a selected adapter can run and how the UI should describe the profile. It
does not grant permission and is not a substitute for doctor output:

```json
{
  "media": {
    "input_modalities": ["audio"],
    "output_modalities": ["text"],
    "transport_modes": ["request_file", "local_endpoint"],
    "deployment_mode": "local_endpoint",
    "audio_formats_supported": ["wav", "flac"],
    "audio_sample_rates_supported": [16000, 24000],
    "max_audio_bytes": 10485760,
    "max_audio_duration_ms": 120000
  }
}
```

Known `deployment_mode` values are `fake`, `local_endpoint`, `bundled_local`,
and `remote_credentialed`. Known `transport_modes` are `request_file`,
`live_upload`, `realtime_session`, `local_endpoint`, and `bundled_local`.
`input_modalities`/`output_modalities` use coarse media values such as `text`,
`audio`, `image`, and `video`.

### Catalog And Settings Shape

The shipped catalog may include coarse provider metadata:

```json
{
  "providers": {
    "local_ollama": {
      "type": "openai_compatible",
      "modalities": ["text"]
    }
  }
}
```

Model profiles carry capability metadata:

```json
{
  "model_profiles": {
    "coding_local": {
      "provider": "local_ollama",
      "model": "qwen2.5-coder:7b",
      "capabilities": ["text_generation", "tool_use"],
      "media": {
        "input_modalities": ["text"],
        "output_modalities": ["text"],
        "deployment_mode": "local_endpoint"
      }
    }
  }
}
```

Settings Central remains the runtime authority. The catalog is seed data only;
operator overrides still win, and live doctor probes still determine
availability. Capability metadata never grants permission, never supplies
secrets, and never bypasses provider policy.

### Preference Shape

v0.48 adds a first-class `model_preferences` settings namespace. Task and
capability preferences are ordered lists of model profile names, with a global
primary profile used as the common fallback:

```elixir
%{
  "primary" => "local",
  "tasks" => %{
    "direct_answer" => ["fast", "local"],
    "coding" => ["coding", "coding_local", "local"]
  },
  "capabilities" => %{
    "text_generation" => ["local", "fast", "capable"],
    "speech_to_text" => ["voice_stt_local", "voice_stt_fake"],
    "text_to_speech" => ["voice_tts_local", "voice_tts_fake"]
  }
}
```

The resolver accepts a task or capability, walks the matching ranked list, and
returns the first enabled profile whose declared capabilities satisfy the
request. If the ranked list is absent or exhausted, the resolver tries the
global primary only when that profile satisfies the requested capability.
Otherwise it returns a bounded `:no_capable_profile` error.

The resolver must skip disabled profiles and profiles whose configured
provider is disabled. Doctor output may be used as diagnostic context, but it
does not grant authority and does not silently rewrite preferences.

### Backward Compatibility

The existing text settings remain compatibility aliases:

- `intent.model_profile` ↔ `model_preferences.primary` (single ↔ single): a
  legacy write sets `primary`; a `primary` write updates the legacy read.
- `intent.direct_answer_model_profile` ↔
  `model_preferences.tasks.direct_answer` (single ↔ list): the legacy read
  returns the list head (or `primary` when the list is empty); a legacy write
  sets the list to `[value]`.

The `model_preferences.*` and `voice.*` namespaces declare `schema_version: 1`
per ADR 0046. Existing callers can continue to read those keys during
migration. New v0.48+ callers use the capability-aware resolver. A
compatibility alias must never produce a profile that fails capability
validation.

### Onboarding And Settings Central

Onboarding and Settings Central should expose:

- global primary profile;
- task preferences such as `coding` and `direct_answer`;
- capability preferences such as `speech_to_text`, `text_to_speech`, and later
  `vision_input`;
- local/offline defaults before cloud defaults;
- explicit operator override for cloud provider use.

Provider credentials remain Settings Central secrets. No preference setting
stores a raw credential or raw URL.

## Consequences

- v0.48 can ship voice without a parallel provider framework.
- v0.49 vision can consume the same capability and preference substrate.
- Realtime audio and generic audio/video understanding remain expressible as
  metadata without becoming v0.48 release authority.
- Profile names can stay semantic, but routing no longer depends on name
  convention alone.
- The default "top candidate" and per-capability overrides become visible,
  auditable settings instead of scattered consumer-specific keys.
- Graceful fallback is deterministic and bounded: incapable, disabled, or
  unavailable profiles are skipped, but no model output can choose a provider
  or capability at runtime.
- The resolver selects a profile only; per-modality execution (e.g. the v0.48
  voice STT/TTS adapter) runs behind the action boundary and makes no authority
  decisions.

## Non-Goals

- No automatic capability grant from provider marketing metadata.
- No automatic cloud upload when an operator has not opted into a cloud
  provider profile.
- No implementation of generic audio-understanding, video ingestion, or
  realtime speech-to-speech in v0.48.
- No unified spend dashboard or budget enforcement in v0.48.
- No promotion action that turns a doctor result into a preference without an
  explicit Settings Central write.

## Validation

v0.48 M1 and M2 added focused tests for:

- catalog capability loading and Settings Central merge behavior;
- media metadata validation and Settings Central merge behavior;
- resolver preference ordering;
- capability validation and primary fallback;
- compatibility aliases for `intent.model_profile` and
  `intent.direct_answer_model_profile`;
- disabled-provider and disabled-profile skips;
- secret redaction in diagnostics and traces.

The release gate must include `mix allbert.test release.v048`.

M8 closeout adds `release.v048` coverage for the provider capability core,
voice STT/TTS actions, CLI voice, workspace microphone capture, Telegram
voice-note ingestion, v0.48 eval rows, and the release-task usage surface.

## Relates To

- ADR 0004 - Domain Settings Engine.
- ADR 0011 - Confirmed External Capability Adapters.
- ADR 0031 - Settings Schema Fragments And Authority.
- ADR 0046 - Settings Schema Migration Policy.
- ADR 0047 - Provider Doctor Contract.
- `docs/plans/v0.39-plan.md`.
- `docs/plans/v0.48-plan.md`.
- `docs/plans/v0.49-plan.md`.
