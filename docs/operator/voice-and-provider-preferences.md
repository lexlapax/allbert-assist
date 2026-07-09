# Voice And Provider Preferences

Operator guide for voice (STT/TTS) and ranked provider/model preferences. Introduced in
v0.48; current as of v0.63. Voice uses the same provider framework as text models: the
operator chooses a primary provider/model profile for most work and can override it per
task or capability (coding, speech-to-text, text-to-speech). Provider credentials resolve
through the three-tier secret vault (OS Keychain / encrypted file / env) — see
[security-hardening.md](security-hardening.md) §Secret Vault.

## How Voice Preferences Work

- Providers stay modality-agnostic connection profiles.
- Model profiles declare capabilities such as `text_generation`,
  `speech_to_text`, and `text_to_speech`.
- Preferences are ranked lists. Allbert tries the first capable enabled profile
  and falls back deterministically.
- `intent.model_profile` and `intent.direct_answer_model_profile` are live settings.
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
- local-endpoint STT/TTS uses the Allbert local voice runtime by default;
- local Ollama can be the text-generation model in the middle of a fully local
  voice loop and can back local STT when an audio-capable Ollama model is
  configured;
- bundled-local STT/TTS uses an explicitly configured offline engine when one
  is available;
- provider credentials remain Settings Central secrets;
- remote STT/TTS must display provider/profile and cost or usage metadata when
  available.

Provider choice guide:

| Mode | Best for | Operator posture |
|---|---|---|
| Fake | Release gates, deterministic tests, demos with fixture audio | No real provider authority; not a production default. |
| Allbert local voice runtime | Operators who want local STT/TTS without cloud credentials | Allbert-owned loopback endpoint on `127.0.0.1:5050` by default; uses real local backends and is required for local v0.48 release validation. |
| Local Ollama text | Operators who want local reasoning between STT and TTS | Ollama handles the text turn after transcription; it may also back local STT when an audio-capable model is configured, but it is not the whole local voice endpoint because current Ollama docs/source do not provide `/v1/audio/speech`. |
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

For real local-endpoint or remote-credentialed provider validation, use
`scripts/v048_voice_live_smoke.exs`. It drives the durable
`transcribe_voice`/`synthesize_voice` confirmation-resume path and then runs the
Ollama-backed text turn.

## Workspace Voice

Workspace microphone capture uses `mic://capture/<id>` resources and the voice
permission classes accepted in ADR 0042. The workspace asks for a per-session
microphone confirmation before recording, then sends the completed browser
capture through a LiveView upload to `transcribe_voice`. Captured audio is
bounded. Raw audio is not written to traces by default, and retention is
default-off unless an operator setting explicitly enables a bounded retained
artifact under `voice.audio.retention_root`.

## TTS And Telegram Voice Notes

`synthesize_voice` is a registered text-to-audio action that resolves the
`text_to_speech` capability through the same provider preference system as
text and STT. v0.49 M10 made natural-language TTS requests agent-visible
through the shared runtime and returned completed audio through the shared
`media_outputs` envelope, so CLI, workspace, Telegram text, and future channels
can route typed "speak/read aloud" requests consistently. Fake TTS writes
deterministic fixture audio only; real local, OpenAI, and Gemini TTS are the
v0.48 release targets. Remote TTS remains explicit opt-in.

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

## Smoke-testing voice

Enable `voice.enabled` with a disposable `ALLBERT_HOME`, then transcribe a short clip
(`mix allbert.ask --voice <file> --trace`) or exercise workspace capture / Telegram voice
notes. For real local-endpoint or remote-provider validation, drive
`scripts/v048_voice_live_smoke.exs`. Fake STT/TTS profiles are fixtures only — use a real
local or remote profile. Confirm traces carry redacted audio metadata (never raw bytes or
local paths). The deterministic gate is `mix allbert.test release.v063`; detailed
live-provider runbooks live in the version request-flow docs.
