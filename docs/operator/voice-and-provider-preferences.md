# Voice And Provider Preferences

Status: implemented in `0.48.0`. Provider capabilities, ranked preferences,
voice doctor dispatch, the audio resource/security substrate, CLI voice file
transcription, workspace microphone capture, TTS, Telegram voice-note
ingestion, v0.48 evals, and `release.v048` evidence are complete.

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

## Voice Defaults

The default posture is local/offline first:

- no cloud STT/TTS provider is used unless the operator configures it;
- fake STT/TTS providers are deterministic release-test fixtures, not real voice
  defaults;
- local-endpoint STT/TTS uses an operator-configured localhost service;
- bundled-local STT/TTS uses an explicitly configured offline engine when one
  is available;
- provider credentials remain Settings Central secrets;
- remote STT/TTS must display provider/profile and cost or usage metadata when
  available.

Provider choice guide:

| Mode | Best for | Operator posture |
|---|---|---|
| Fake | Release gates, deterministic tests, demos with fixture audio | No real provider authority; not a production default. |
| Local endpoint | Operators running a localhost STT/TTS service | No cloud credential, but still bounded and doctored. |
| Bundled local | Operators who explicitly configure an offline engine | Local runtime presence is a doctor signal; packaging is not required by the v0.48 release lane. |
| Remote credentialed | Cloud STT/TTS quality or managed voices | Explicit opt-in; may upload audio or incur provider cost. |

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
text and STT. Fake TTS writes deterministic local audio and reports redacted
display-only usage/cost metadata; remote TTS remains explicit opt-in.

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
- ADR 0051 for provider preferences
- ADR 0042 for media resource policy
- ADR 0047 for voice doctor output

Release authority is the deterministic fake-provider lane:

```sh
mix allbert.test release.v048
```

The v0.48 closeout evidence path from implementation was:

```text
/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v048/p0-7/home/release_evidence/v048/release-v048-1780765740.json
```
