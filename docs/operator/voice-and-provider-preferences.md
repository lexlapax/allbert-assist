# Voice And Provider Preferences

Status: implementation reopened before v0.48 release. Provider capabilities,
ranked preferences, voice doctor dispatch, the audio resource/security
substrate, CLI voice file transcription, workspace microphone capture, TTS,
Telegram voice-note ingestion, v0.48 evals, and first-pass `release.v048`
evidence landed, but release validation now requires real provider execution.

v0.48 makes voice use the same provider framework as text models. The operator
chooses a primary provider/model profile for most work and can override that
choice per task or capability, such as coding, speech-to-text, or
text-to-speech.

## What Changes In v0.48

- Providers stay modality-agnostic connection profiles.
- Model profiles declare capabilities such as `text_generation`,
  `speech_to_text`, and `text_to_speech`.
- Preferences are ranked lists. Allbert tries the first capable enabled profile
  and falls back deterministically.
- Existing `intent.model_profile` and `intent.direct_answer_model_profile`
  settings remain compatibility aliases during migration.
- Voice does not create a parallel provider or secret system.
- Media details such as accepted audio formats, duration limits, realtime
  session support, and local-vs-remote deployment mode are profile metadata,
  not permissions.
- Fake STT/TTS providers are fixtures only. A working v0.48 voice setup uses a
  real local or remote STT/TTS profile.

## Voice Defaults

The default posture is local/offline first:

- no cloud STT/TTS provider is used unless the operator configures it;
- fake STT/TTS providers are deterministic automated-test fixtures only, never
  product or release-validation flows;
- local-endpoint STT/TTS uses an operator-configured localhost service;
- local Ollama can be the text-generation model in the middle of a fully local
  voice loop;
- bundled-local STT/TTS uses an explicitly configured offline engine when one
  is available;
- provider credentials remain Settings Central secrets;
- remote STT/TTS must display provider/profile and cost or usage metadata when
  available.

Provider choice guide:

| Mode | Best for | Operator posture |
|---|---|---|
| Fake | Release gates, deterministic tests, demos with fixture audio | No real provider authority; not a production default. |
| Local endpoint | Operators running a localhost STT/TTS service such as an OpenAI-compatible speech server | No cloud credential, but still bounded and doctored; required for v0.48 release validation. |
| Local Ollama text | Operators who want local reasoning between STT and TTS | Ollama handles the text turn after transcription; it is not an STT/TTS provider in v0.48. |
| Bundled local | Operators who explicitly configure an offline engine | Local runtime presence is a doctor signal; executable bundled packaging remains future scope. |
| Remote credentialed | Cloud STT/TTS quality or managed voices | Explicit opt-in; may upload audio or incur provider cost. OpenAI and Gemini are required remote validation paths for v0.48. |

Realtime audio session support, generic audio understanding, and video input are
profile metadata only in v0.48. They do not enable always-on listening, generic
media upload, or video ingestion.

## CLI Voice

CLI voice mode transcribes an audio file or fixture:

```sh
mix allbert.settings set voice.enabled true
mix allbert.ask --voice test/fixtures/audio/hello.wav --trace
```

The CLI does not open a live microphone. Live capture is a workspace feature so
that the operator can see and confirm microphone use.

## Workspace Voice

Workspace microphone capture uses `mic://capture/<id>` resources and the voice
permission classes accepted in ADR 0042. The workspace asks for a per-session
microphone confirmation before recording, then sends the completed browser
capture through a LiveView upload to `transcribe_voice`. Captured audio is
bounded. Raw audio is not written to traces by default, and retention is
default-off unless an operator setting explicitly enables a bounded retained
artifact under `voice.audio.retention_root`.

## TTS And Telegram Voice Notes

`synthesize_voice` is an internal registered action that resolves the
`text_to_speech` capability through the same provider preference system as
text and STT. Fake TTS writes deterministic fixture audio only; real local,
OpenAI, and Gemini TTS are the v0.48 release targets. Remote TTS remains
explicit opt-in.

Telegram voice notes are channel input, not a channel-owned STT provider. The
Telegram adapter parses `message.voice`, fetches the file through Bot API
`getFile` plus the documented file-download path, stores it only in a bounded
temp path for the turn, and calls `transcribe_voice`. The runtime receives text
plus bounded Telegram voice metadata after STT succeeds.

## Provider Preferences

Operator settings expose:

- global primary profile;
- coding preference;
- direct-answer preference;
- speech-to-text preference;
- text-to-speech preference.

Capability validation protects the selection. A text-only model cannot be used
as an STT provider just because it appears in a preference list.

A fully local voice loop uses separate profiles:

```text
speech_to_text -> voice_stt_local
direct_answer/text_generation -> voice_text_local (local_ollama)
text_to_speech -> voice_tts_local
```

Claude/Anthropic profiles may be used for the text turn after transcription,
but they do not satisfy `speech_to_text` or `text_to_speech` in v0.48.

Voice doctor output uses the ADR 0047 envelope plus additive voice fields such
as `provider_capabilities`, `provider_deployment_mode`,
`speech_to_text_supported`, `text_to_speech_supported`,
`audio_formats_supported`, `sample_rates_supported`,
`provider_usage_metadata_available`, `local_runtime_present`, and
`fixture_probe_ok`.

## Manual Validation

Use the v0.48 request-flow checklist for release validation:

- `docs/plans/v0.48-request-flow.md`
- `docs/plans/v0.48-plan.md`
- ADR 0011 for voice-provider HTTP posture
- ADR 0051 for provider preferences
- ADR 0042 for media resource policy
- ADR 0047 for voice doctor output

The first-pass fixture gate is still useful:

```sh
mix allbert.test release.v048
```

It is not sufficient for release until M8R extends it to exercise the local,
OpenAI, Gemini, and Ollama paths through deterministic provider fixtures.

Manual validation before tag must also run disposable-home live smokes for:

- local OpenAI-compatible STT/TTS plus local Ollama text;
- OpenAI remote STT/TTS using Settings Central secrets loaded from `.env`;
- Gemini remote STT/TTS using Settings Central secrets loaded from `.env`.

The v0.48 first-pass evidence path from implementation was:

```text
/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v048/p0-13250/home/release_evidence/v048/release-v048-1780768719.json
```
