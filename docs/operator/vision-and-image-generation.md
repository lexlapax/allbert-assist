# Vision And Image Generation Operator Guide

Operator guide for vision (image/screenshot-to-text) and text-to-image generation.
Introduced in v0.49; current as of v0.63. Design authority: ADR 0042, ADR 0047, ADR 0051.

## Operator Posture

- `vision.enabled=false` disables image/screenshot-to-text analysis.
- `image.enabled=false` disables text-to-image generation.
- `image://capture/<id>` and `screen://capture/<id>` are inert identifiers for
  operator-supplied media. They do not capture the OS screen, grant permission,
  or create a durable artifact-store record.
- Browser screenshots can be analyzed only after `browser_screenshot` has
  produced a `cache://browser/...` `screenshot_ref`; the follow-on
  `analyze_browser_screenshot` action reuses that cached image and does not
  capture the OS screen.
- Remote image generation is confirmation-gated through `:image_generate`.
- Fake vision/image profiles are deterministic test fixtures only. Manual
  validation should use configured OpenAI or Gemini profiles when credentials
  are available.
- Uploaded/generated files are bounded local media resources; content-addressed
  artifact storage is owned by Artifacts Central (see
  [artifacts-central.md](artifacts-central.md)).
- Hosted vision/image providers (OpenAI, Gemini) resolve their API key through the
  three-tier secret vault — an OS-Keychain / encrypted-file / env-provided key all work
  (see [security-hardening.md](security-hardening.md) §Secret Vault) — and honor
  `SSL_CERT_FILE` with a bundled CA store for TLS.

## Settings

Enable only the surface being validated:

```sh
mix allbert.settings set vision.enabled true
mix allbert.settings set image.enabled true
```

Useful bounds and retention keys:

```text
vision.media.max_bytes
vision.media.max_pixels
vision.media.retention_enabled
vision.media.retention_root
image.generation.max_bytes
image.generation.max_pixels
image.generation.retention_enabled
image.generation.retention_root
```

Retention defaults off. Leave it off unless you intentionally want local media
files retained under Allbert Home.

## Workspace Vision Smoke

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-vision.XXXXXX)"
mix allbert.settings set vision.enabled true
PORT=4049 mix phx.server
```

Open `/workspace`, upload or paste a PNG/JPEG/WebP image, and ask a question
about it. Expected behavior:

- the upload control is available only when `vision.enabled=true`;
- the image is bounded server-side before provider use;
- the text answer uses a resolved `vision_input` profile;
- traces and action metadata contain redacted image metadata, not raw bytes or
  local paths.

Browser screenshot analysis uses the same vision path. Capture the browser page
first with the Browser screenshot action, then analyze the returned
`screenshot_ref`; Allbert records `source: :browser_screenshot` provenance in
the redacted media metadata.

## Image Generation Smoke

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-image.XXXXXX)"
mix allbert.settings set image.enabled true
```

Request image generation through the runtime/action surface. Expected behavior:

- `generate_image` resolves `image_generation`;
- remote OpenAI/Gemini profiles require operator confirmation before the
  provider call;
- generated output is a bounded local image file;
- `usage` and `cost` metadata is display-only;
- traces/action metadata redact binary content and generated resource paths.

## Release gate

The deterministic gate for the current release line is `mix allbert.test release.v063`.
For a live vision/image smoke against configured providers, the reusable script is
`scripts/v049_vision_live_smoke.exs` (OpenAI / Gemini / Ollama), driven from a disposable
`ALLBERT_HOME`. Detailed release-validation runbooks live in the version plan/request-flow
docs, not here.
