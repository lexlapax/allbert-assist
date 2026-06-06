# Voice And Provider Preferences

Status: planned for v0.48.

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

## Voice Defaults

The default posture is local/offline first:

- no cloud STT/TTS provider is used unless the operator configures it;
- fake STT/TTS providers are deterministic release-test fixtures, not real voice
  defaults;
- provider credentials remain Settings Central secrets;
- remote STT/TTS must display provider/profile and cost or usage metadata when
  available.

## CLI Voice

CLI voice mode transcribes an audio file or fixture:

```sh
mix allbert.ask --voice test/fixtures/audio/hello.wav --trace
```

The CLI does not open a live microphone. Live capture is a workspace feature so
that the operator can see and confirm microphone use.

## Workspace Voice

Workspace microphone capture uses `mic://capture/<id>` resources and the voice
permission classes planned in ADR 0042. Captured audio is bounded. Raw audio is
not written to traces by default, and retention is default-off unless an
operator setting explicitly enables a bounded retained artifact.

## Provider Preferences

After v0.48 lands, operator settings should expose:

- global primary profile;
- coding preference;
- direct-answer preference;
- speech-to-text preference;
- text-to-speech preference.

Capability validation protects the selection. A text-only model cannot be used
as an STT provider just because it appears in a preference list.

## Manual Validation

Use the v0.48 request-flow checklist for release validation:

- `docs/plans/v0.48-request-flow.md`
- `docs/plans/v0.48-plan.md`
- ADR 0051 for provider preferences
- ADR 0042 for media resource policy
- ADR 0047 for voice doctor output
