# Sample Media

This directory contains small committed media files for operator manual
validation, documentation examples, and focused smoke testing of Allbert media
flows.

## Files

- `audio/voice-testing-123.wav` — WAV sample for voice/STT validation and
  v0.48-style provider preference checks.
- `images/validation-input.png` — image-input sample for vision/manual
  validation flows.
- `images/validation-input-small.png` — downscaled image-input sample for
  v0.49 live/action smoke commands that enforce the 1 MiB metadata read cap.
- `images/generated-image-sample.png` — generated-image sample for documentation
  and visual inspection of text-to-image output handling.

## Boundaries

- These files are safe sample media, not secrets, credentials, private user
  data, or runtime state.
- These files are not canonical artifacts and are not stored through Artifacts
  Central. v0.50 owns content-addressed durable artifact storage.
- Automated tests may reference these files when a stable shared sample is
  useful. Version-specific regression fixtures should still live under the
  relevant `apps/allbert_assist/test/fixtures/` path.
- Do not add live-provider outputs here unless they are intentionally promoted
  as stable, non-sensitive samples for documentation or manual validation.
