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

Use these numbered steps before tagging v0.48. They deliberately use
disposable `ALLBERT_HOME` roots. Do not run live smokes against a real operator
home.

1. Prepare the release shell.

```sh
cd /Users/spuri/projects/lexlapax/allbert-assist
unset MIX_ENV
unset DATABASE_PATH
export ALLBERT_TRACE_ENABLED=true
export V048_AUDIO="/Users/spuri/projects/lexlapax/allbert-assist/Voice-testing-123.wav"
test -f "$V048_AUDIO" && echo "audio ok: $V048_AUDIO"
```

Expected: the last command prints `audio ok: ...`. Replace `V048_AUDIO` with
another explicit WAV path if validating on a different machine.

2. Verify local prerequisites.

```sh
command -v ffmpeg
command -v ollama
command -v say
ollama --version
ollama list
curl -sS --max-time 5 http://127.0.0.1:11434/v1/models
ffprobe -hide_banner -loglevel error \
  -show_entries format=duration:stream=codec_name,sample_rate,channels \
  -of default=noprint_wrappers=1 "$V048_AUDIO"
```

Expected: `ffmpeg`, `ollama`, and macOS `say` resolve; Ollama responds on
`127.0.0.1:11434`; the audio file is readable. If Ollama is not serving, start
it with `ollama serve` in another terminal or through the local Ollama app.

3. Validate the local Ollama STT model before involving Allbert.

```sh
ollama show gemma4:e2b
curl -sS --max-time 240 \
  -F model=gemma4:e2b \
  -F response_format=json \
  -F file=@"$V048_AUDIO" \
  http://127.0.0.1:11434/v1/audio/transcriptions
```

Expected: `ollama show` includes `audio`, and the curl response has non-empty
`text`. `gemma4:e2b` is the validated v0.48 Mac local STT default.

4. Optionally validate the larger local STT model.

```sh
ollama show gemma4:e4b
curl -sS --max-time 300 \
  -F model=gemma4:e4b \
  -F response_format=json \
  -F file=@"$V048_AUDIO" \
  http://127.0.0.1:11434/v1/audio/transcriptions
```

Expected: non-empty `text`. Use `gemma4:e4b` only when the operator wants the
heavier, higher-quality local STT option. Do not use `gemma4:e2b-mlx` or
`gemma3n:e2b` as v0.48 release-validation defaults.

5. Create a disposable home for the fully local Allbert validation.

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-local.XXXXXX)"
mix ecto.create --quiet
mix ecto.migrate --quiet
```

Expected: both Mix commands exit 0.

6. Configure the Allbert-owned local voice runtime through Settings Central.

```sh
mix allbert.settings set voice.enabled true
mix allbert.settings set voice.local_runtime.enabled true
mix allbert.settings set voice.local_runtime.port 5050
mix allbert.settings set voice.local_runtime.ollama_base_url http://127.0.0.1:11434/v1
mix allbert.settings set voice.local_runtime.ollama_stt_model gemma4:e2b
mix allbert.settings set providers.local_voice.enabled true
mix allbert.settings set providers.local_voice.base_url http://127.0.0.1:5050/v1
```

Expected: each command prints `Updated: ...`. Use `gemma4:e4b` in the STT
setting only if step 4 passed and the operator wants the larger model.

7. Start the Allbert local voice runtime in Terminal B.

```sh
cd /Users/spuri/projects/lexlapax/allbert-assist
unset MIX_ENV
unset DATABASE_PATH
export ALLBERT_HOME="PASTE_THE_STEP_5_VALUE"
mix allbert.voice.local doctor
mix allbert.voice.local start
```

Expected doctor lines: `settings_enabled=true`, `stt_model=gemma4:e2b`,
`stt_available=true`, `tts_available=true`, and
`models=whisper-local,tts-local`. The `start` command should print
`Allbert local voice runtime listening on http://127.0.0.1:5050/v1` and remain
running.

8. Validate the Allbert 5050 endpoint from Terminal A.

```sh
curl -sS --max-time 5 http://127.0.0.1:5050/v1/models
curl -sS --max-time 5 http://127.0.0.1:5050/v1/doctor
export ALLBERT_LOCAL_VOICE_TOKEN="$(cat "$ALLBERT_HOME/tmp/local-voice-runtime/token")"
test -n "$ALLBERT_LOCAL_VOICE_TOKEN" && echo "local runtime token loaded"
test -r "$V048_AUDIO" && echo "audio readable: $V048_AUDIO"
```

Expected: `/v1/models` lists `whisper-local` and `tts-local`; `/v1/doctor`
has `endpoint_ok=true` and empty `diagnostic_codes`; the token command prints
`local runtime token loaded`; the audio preflight prints `audio readable: ...`.
If this step is run from a new terminal, export `ALLBERT_HOME` and `V048_AUDIO`
again before running the token and audio preflight commands.

9. Validate token-backed Allbert STT and TTS directly.

```sh
curl -sS --max-time 240 \
  -H "x-allbert-local-runtime-token: $ALLBERT_LOCAL_VOICE_TOKEN" \
  -F model=whisper-local \
  -F response_format=json \
  -F file=@"$V048_AUDIO" \
  http://127.0.0.1:5050/v1/audio/transcriptions

curl -sS --max-time 60 \
  -o "$ALLBERT_HOME/tts-local.wav" \
  -w "%{http_code} %{content_type} %{size_download}\n" \
  -H "x-allbert-local-runtime-token: $ALLBERT_LOCAL_VOICE_TOKEN" \
  -H "content-type: application/json" \
  -d '{"model":"tts-local","input":"v0.48 local voice validation succeeded","response_format":"wav"}' \
  http://127.0.0.1:5050/v1/audio/speech
```

Expected: STT returns non-empty `text`; TTS prints `200 audio/wav...` and a
non-zero byte count. `curl: (26) Failed to open/read local data from
file/application` means the current shell cannot read `$V048_AUDIO`; it is a
local file-path/export problem, not an Allbert runtime or provider error.

10. Run the full local live smoke.

```sh
export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=local
export LOCAL_VOICE_BASE_URL=http://127.0.0.1:5050/v1
export ALLBERT_V048_AUDIO="$V048_AUDIO"
mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Expected: doctor output for `voice_stt_local` and `voice_tts_local` has
`endpoint_ok=true model_available=true`; the script prints `Transcript:`,
`Runtime response:`, `Speech file:`, and
`v0.48 live voice smoke completed.`

11. Stop the local runtime.

In Terminal B, press `Ctrl+C` twice. Then verify from Terminal A:

```sh
lsof -nP -iTCP:5050 -sTCP:LISTEN
```

Expected: no output. If a validation Beam process is still listening, stop it
before continuing.

12. Run the OpenAI live smoke in a fresh disposable home.

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-openai.XXXXXX)"
unset MIX_ENV
unset DATABASE_PATH
mix ecto.create --quiet
mix ecto.migrate --quiet
set -a
source .env
set +a
test -n "$OPENAI_API_KEY" && echo "OPENAI_API_KEY present"
export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=openai
export ALLBERT_V048_AUDIO="$V048_AUDIO"
mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Expected: the script prints successful STT doctor, TTS doctor, transcript,
runtime response, speech file, and completion lines. This may upload audio and
incur provider cost.

13. Run the Gemini live smoke in a fresh disposable home.

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v048-gemini.XXXXXX)"
unset MIX_ENV
unset DATABASE_PATH
mix ecto.create --quiet
mix ecto.migrate --quiet
set -a
source .env
set +a
test -n "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" && echo "Gemini key present"
export ALLBERT_V048_LIVE_SMOKE=1
export ALLBERT_V048_PROVIDER=gemini
export ALLBERT_V048_AUDIO="$V048_AUDIO"
mix run --no-start scripts/v048_voice_live_smoke.exs "$V048_AUDIO"
```

Expected: the same successful doctor, transcript, runtime response, speech
file, and completion lines. Gemini STT uses the stable `generateContent`
inline-audio request path. This may upload audio and incur provider cost.

14. Run the deterministic v0.48 release lane.

```sh
MIX_ENV=test mix allbert.test release.v048
```

Expected: provider capability core, voice action/CLI/channel, workspace voice,
voice security eval, and secret scan all pass. The latest validated shape was
provider capability core `65 tests, 0 failures`, voice action/CLI/channel
`52 tests, 0 failures`, workspace voice `64 tests, 0 failures`, voice security
eval `20 tests, 0 failures`, and a clean secret scan. The command prints the
evidence JSON path under `<ALLBERT_HOME>/release_evidence/v048/`.

15. Check traces for obvious leaks.

Run this once for each disposable home used in steps 10, 12, and 13:

```sh
if [ -d "$ALLBERT_HOME/memory/traces" ]; then
  rg -i 'sk-|api[_-]?key|authorization|x-goog-api-key|AIza|Voice-testing-123.wav' \
    "$ALLBERT_HOME/memory/traces" || true
else
  echo "no memory traces directory"
fi
```

Expected: no API keys, authorization headers, Gemini keys, or raw sample path.

16. Record release evidence.

Capture the following in the release handoff notes:

- output from steps 3 and 4 showing local transcription model behavior;
- `mix allbert.voice.local doctor` output from step 7;
- direct Allbert STT/TTS outputs from step 9;
- full local live-smoke completion from step 10;
- OpenAI and Gemini live-smoke completion from steps 12 and 13;
- `release.v048` evidence JSON path from step 14;
- trace/secret scan result from step 15.
