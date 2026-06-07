# Voice And Provider Preferences

Status: implemented for v0.48 release handoff. Provider capabilities, ranked
preferences, voice doctor dispatch, the audio resource/security substrate, CLI
voice file transcription, workspace microphone capture, TTS, Telegram
voice-note ingestion, v0.48 evals, M8R real-provider adapters, and the M8R7
Allbert-owned local voice runtime endpoint are implemented. Manual live
provider validation remains required before the release tag.

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

The fixture regression gate is still useful:

```sh
mix allbert.test release.v048
```

M8R extends this with deterministic local/OpenAI/Gemini/Ollama fixture coverage
and the 16 `:v048` voice-modality eval rows. Before tagging, run the opt-in
live-smoke script from a disposable home for each provider you want to certify.
The script configures `voice.enabled=true`, enables the direct-answer model
gate, stores provider API keys in Settings Central secrets, drives the
confirmation-resume path, and fails if STT, the Ollama text turn, or TTS does
not produce real output.

Prerequisites:

- `ffmpeg` is installed and on `PATH`.
- Ollama is serving `llama3.2:3b` for the text middle turn:
  `ollama pull llama3.2:3b` and then keep `ollama serve` running if it is not
  already running as a service.
- The audio sample is an explicit file path:
  `export V048_AUDIO=/absolute/path/to/sample.wav`.
- Provider credentials are loaded into the shell, for example:
  `set -a; source .env; set +a`.
- The disposable home database is bootstrapped before the smoke:
  `mix ecto.create --quiet` and `mix ecto.migrate --quiet`.

OpenAI:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-openai.XXXXXX)"
mix ecto.create --quiet
mix ecto.migrate --quiet

export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=openai

mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Gemini:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-gemini.XXXXXX)"
mix ecto.create --quiet
mix ecto.migrate --quiet

export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=gemini

mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Allbert local voice runtime:

M8R7 implementation: v0.48 provides this endpoint as an Allbert product
runtime. It is not the Phoenix app, not Ollama's `11434` text endpoint, and not
an operator-supplied validation server. The default product base URL is
`http://127.0.0.1:5050/v1`; advanced operators may override
`providers.local_voice.base_url` to another OpenAI-compatible loopback server,
but the release path uses the Allbert runtime.

The runtime implements:

```text
GET  /v1/models
GET  /v1/doctor
POST /v1/audio/transcriptions
POST /v1/audio/speech
```

The Allbert-facing local profile ids are `whisper-local` for STT and
`tts-local` for TTS unless the operator has overridden the profiles. Behind the
endpoint, local STT uses a configured Ollama audio/transcription model through
Ollama's OpenAI-compatible transcription endpoint. Ollama listens on `11434`;
the Allbert runtime listens on `5050`. Ollama by itself is not the complete
local voice endpoint because current Ollama docs/source do not provide
OpenAI-compatible TTS at `/v1/audio/speech`.

Configuration and service lifecycle are owned by Allbert:

- Settings Central keys: `voice.local_runtime.enabled`,
  `voice.local_runtime.port`, `voice.local_runtime.ollama_base_url`,
  `voice.local_runtime.ollama_stt_model`,
  `voice.local_runtime.stt_model_alias`,
  `voice.local_runtime.tts_model_alias`,
  `voice.local_runtime.stt_backend`, `voice.local_runtime.tts_backend`, and
  `voice.local_runtime.max_text_bytes`.
- Security Central lifecycle permission:
  `permissions.voice_local_runtime_manage`.
- STT/TTS HTTP requests require the per-Allbert-Home local runtime token. The
  Allbert local adapter attaches it automatically; manual `curl` diagnostics
  can read it with `mix allbert.voice.local token`.

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-local.XXXXXX)"
mix ecto.create --quiet
mix ecto.migrate --quiet

mix allbert.settings set voice.local_runtime.enabled true
mix allbert.settings set voice.local_runtime.port 5050
mix allbert.settings set voice.local_runtime.ollama_base_url http://127.0.0.1:11434/v1
# Use the default `gemma3n:e2b` only if `ollama list` confirms that model is
# installed and audio-capable for your Ollama build.
mix allbert.settings set voice.local_runtime.ollama_stt_model gemma3n:e2b

export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=local
export LOCAL_VOICE_BASE_URL=http://127.0.0.1:5050/v1

# Start the Allbert local voice runtime in a second terminal with the same
# ALLBERT_HOME:
#   mix allbert.voice.local doctor
#   mix allbert.voice.local start
export ALLBERT_LOCAL_VOICE_TOKEN="$(mix allbert.voice.local token)"
curl -sS -i --max-time 5 \
  -H "x-allbert-local-runtime-token: $ALLBERT_LOCAL_VOICE_TOKEN" \
  "$LOCAL_VOICE_BASE_URL/models"
mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Expected successful output includes all of the following:

```text
Doctor voice_stt_<provider>: endpoint_ok=true model_available=true
Doctor voice_tts_<provider>: endpoint_ok=true model_available=true
Transcript: ...
Runtime response: ...
Speech resource: file://...
Speech file: ...
v0.48 live voice smoke completed.
```

Manual validation before tag must also run disposable-home live smokes for:

- Allbert local voice runtime STT/TTS plus local Ollama text;
- OpenAI remote STT/TTS using Settings Central secrets loaded from `.env`;
- Gemini remote STT/TTS using Settings Central secrets loaded from `.env`.

The v0.48 first-pass evidence path from implementation was superseded by the
M8R closeout evidence under the release-evidence root for the disposable gate
home:

```text
<ALLBERT_HOME>/release_evidence/v048/
```
