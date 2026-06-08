# Provider Capabilities Developer Notes

Status: implemented through v0.49. v0.48 landed the shared provider-capability
substrate plus executable local endpoint, OpenAI remote, and Gemini remote
STT/TTS paths while keeping fake providers as automated-test fixtures only.
v0.49 adds bounded vision/image catalog profiles, image media metadata
validation, Settings Central defaults, the app-started ReqLLM model/provider
proof, image/screen resource identity, image permission/operation classes,
image media redaction, shared image bounds, workspace image upload,
vision-input dispatch through the existing ReqLLM text path, and the
`generate_image` action through the ReqLLM image-provider path. Content hashes are
metadata only at v0.49; the canonical content-addressed artifact store is
proposed for v0.50.

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
- ADR 0011 defines the provider HTTP posture, including the v0.48 M8R split
  between loopback-only local voice endpoints and HTTPS-only credentialed
  remote voice providers.
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
and `text_to_speech` are executable v0.48 voice capabilities only when backed
by a real local endpoint, OpenAI, or Gemini adapter. Fake profiles are fixtures.
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
audio/video understanding metadata as an STT/TTS provider. v0.49 likewise must
not treat a profile's local/online multimodal metadata as a catch-all media
authority.

## Resolver Contract

New runtime code should not branch directly on `intent.model_profile` or profile
names. It should ask the resolver for a task or capability:

- `:text_generation` for ordinary model-backed replies;
- `:direct_answer` for direct-answer routing;
- `:coding` for coding-oriented model use;
- `:speech_to_text` for transcription;
- `:text_to_speech` for synthesis;
- `:vision_input` for image/screenshot-to-text analysis;
- `:image_generation` for provider-backed image generation.

The resolver walks `model_preferences.tasks.<task>` or
`model_preferences.capabilities.<capability>` in order, skips disabled profiles
and disabled providers, validates declared capabilities, and then falls back to
`model_preferences.primary` only when the primary profile satisfies the
requested capability. Otherwise it returns a bounded no-capable-profile error.

Existing text settings remain compatibility aliases:

- `intent.model_profile` maps to the primary text-generation preference.
- `intent.direct_answer_model_profile` maps to the direct-answer preference.

Aliases are for migration. New v0.48+ code should use the resolver.

## Vision/Image Notes

v0.49 vision/image work uses the same model-profile and doctor contract:

- Vision input requires `vision_input` and attaches image content to the normal
  ReqLLM text path as a multimodal content part.
- Image generation requires `image_generation` and runs through a registered
  `generate_image` action on the ReqLLM image-provider path.
- Provider HTTP, credentials, and request shape remain owned by ReqLLM, as for
  text. v0.49 does not add an image-specific ProviderHTTP module or ADR 0011
  amendment.
- M1 must verify app-started ReqLLM provider/model registration with
  `ReqLLM.Providers.list/0`, `ReqLLM.Images.validate_model/1`, and deterministic
  fixture request paths. A `mix run --no-start` probe is not enough because
  provider discovery initializes at application startup.
- Fake vision/image profiles are release-test fixtures, not operator defaults
  or live-provider release authority.
- Operator setup and manual validation live in
  `docs/operator/vision-and-image-generation.md`; implementation seams live in
  `docs/developer/vision-and-image-generation.md`.
- Image media metadata is descriptive bounds, not permission. Supported keys
  include `image_formats_supported`, `max_image_bytes`, and
  `max_image_pixels`:

```json
{
  "media": {
    "input_modalities": ["text", "image"],
    "output_modalities": ["text"],
    "deployment_mode": "remote_credentialed",
    "image_formats_supported": ["png", "jpeg", "webp"],
    "max_image_bytes": 20971520,
    "max_image_pixels": 33177600
  }
}
```

For image generation, `image_formats_supported` constrains the format Allbert
requests from the provider. It is not treated as authority over the actual
bytes returned by the provider. The v0.49 `generate_image` action sniffs
returned bytes, writes the local generated image with the actual safe extension,
records sniffed MIME/format metadata, and validates the output against
Allbert's system-safe generated-image formats plus byte/pixel bounds.

There is no generic `multimodal` capability. A local or online profile may
declare multiple modalities, but executable flows stay capability-specific:
v0.48 owns `speech_to_text` and `text_to_speech`; v0.49 owns `vision_input` and
`image_generation`; video and generic audio understanding remain parked.

## Vision And Image Notes

Vision and image generation use the same capability/profile resolver as voice,
but execute through ReqLLM rather than the v0.48 ProviderHTTP voice adapters.

- `vision_openai` and `vision_gemini` are the remote release-validation
  profiles for image/screenshot -> text.
- `image_openai` and `image_gemini` are the remote release-validation profiles
  for text -> image, and non-fake image generation remains confirmation-gated.
- `vision_ollama` and `image_ollama` are opt-in local profiles on the existing
  `local_ollama` OpenAI-compatible endpoint. The selected model IDs are
  `qwen3-vl:8b` for image input and `x/z-image-turbo` for experimental image
  generation; `x/z-image-turbo:latest` is accepted as an installed-model alias
  for local doctor availability.
- Local/custom OpenAI-compatible model calls use explicit ReqLLM model specs
  instead of `"provider:model"` catalog strings. For Ollama image generation,
  Allbert also clears OpenAI's `output_format` option on the ReqLLM-prepared
  image request so the experimental endpoint returns its documented base64 JSON
  response for ReqLLM decoding.
  When an OpenAI-compatible profile has no configured secret, Allbert passes the
  harmless placeholder API key `ollama`; this prevents ReqLLM/OpenAI defaults
  from inheriting an ambient `OPENAI_API_KEY` for local/proxy calls.
- Gemma 4 Ollama tags that advertise text+image input, such as `gemma4:e4b`,
  are valid local vision-candidate checks through the live-smoke model override;
  they are not image-generation models and do not replace `image_ollama`.
- The default `vision_input` and `image_generation` preference lists stay
  OpenAI/Gemini only. Operators who want local media validation must explicitly
  select the Ollama profiles or run the v0.49 live smoke with
  `ALLBERT_V049_PROVIDER=ollama`.
- No v0.49 profile claims video generation or generic audio understanding.

## Voice Notes

Voice providers use the same model-profile and doctor contract:

- STT requires `speech_to_text`.
- TTS requires `text_to_speech`.
- CLI voice uses a file path or fixture.
- Workspace microphone capture uses `mic://capture/<id>` and a confirmed action.
- Fake STT/TTS providers are release-test fixtures, not operator defaults.
- Local-endpoint voice providers target the v0.48 Allbert-owned localhost
  contract: `POST /v1/audio/transcriptions`, `POST /v1/audio/speech`, and
  `GET /v1/doctor`. The local endpoint path is implemented by M8R.
- Bundled-local providers are explicitly configured offline engines behind a
  bounded helper. Executable bundled packaging remains deferred unless a later
  plan scopes model/binary distribution.
- Credentialed remote STT/TTS can upload audio or incur cost, so policy and
  result metadata must stay explicit. OpenAI and Gemini are required v0.48
  remote adapter implementations.
- Anthropic/Claude is a `text_generation` provider in v0.48 voice flows, not a
  native STT/TTS adapter. It may consume the transcript and produce the text
  response before TTS.
- Local Ollama is the required local text-generation middle of the
  listen -> think -> speak validation loop. Ollama does not provide native
  STT/TTS endpoints in the v0.48 contract.
- M4 added `mic://capture/<id>` resource identity, voice permission floors,
  audio metadata redaction, `voice.*` bounds/retention settings, and the
  bounded transcode spec helper.
- M5 adds `transcribe_voice` and `mix allbert.ask --voice AUDIO_FILE` for
  bounded local files. M8R routes the same action through real local/OpenAI/
  Gemini adapters with durable confirmation/resume for provider calls. It
  submits the transcript as normal runtime text and records only redacted voice
  metadata.
- M6 adds `capture_workspace_voice`, a confirmation-gated workspace microphone
  grant that feeds a LiveView binary upload into `transcribe_voice` with
  `mic://capture/<id>` resource identity.
- M7 adds `synthesize_voice` for provider-backed TTS output plus redacted
  display-only usage/cost metadata, and Telegram voice-note ingestion that
  downloads through the Telegram Bot API before delegating STT to
  `transcribe_voice`. M8R makes local/OpenAI/Gemini TTS executable.
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
- CLI voice file transcription through the fixture STT path (implemented in
  M5);
- workspace microphone confirmation, upload, redaction, and transcript handoff
  (implemented in M6);
- fixture TTS action output and Telegram voice-note ingestion through shared
  STT (implemented in M7);
- `release.v048` first-pass coverage used fixture STT/TTS for workspace voice,
  Telegram voice-note ingestion, and the first ten v0.48 eval rows
  (implemented in M8).
- provider HTTP policy tests for loopback-only local voice endpoints,
  HTTPS+secret-only remote voice endpoints, and IPv4-mapped IPv6 private-host
  denial (M8R2).
- bounded transcode materialization tests proving the provider call uses the
  materialized output, not arbitrary ffmpeg args or the original path when a
  conversion is required (M8R3).
- OpenAI-compatible local STT/TTS adapter request/response fixture tests
  (M8R3) plus Allbert-owned local runtime router/auth/backend tests (M8R7).
- OpenAI remote multipart transcription and speech response fixture tests
  (M8R4).
- Gemini remote `generateContent` inline-audio transcription and
  `generateContent` AUDIO TTS fixture tests (M8R4/M8R7).
- local Ollama text-loop resolver/orchestration tests proving the transcript is
  answered through the local text profile before TTS (M8R5).
- `release.v048` real-adapter fixture coverage plus opt-in `.env` live-smoke
  script instructions for OpenAI, Gemini, the Allbert local voice runtime, and
  Ollama (M8R6/M8R7).
