# Vision And Image Generation Operator Guide

Status: v0.49 implemented. Use this guide for manual validation and local
operator setup. The design authority remains `docs/plans/v0.49-plan.md`,
`docs/plans/v0.49-request-flow.md`, ADR 0042, ADR 0047, and ADR 0051.

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
- v0.49 keeps uploaded/generated files as bounded local media resources. v0.50
  Artifacts Central owns canonical content-addressed artifact storage.

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

## Release Gate

The deterministic fixture gate is:

```sh
MIX_ENV=test mix allbert.test release.v049
```

It writes evidence to:

```text
<ALLBERT_HOME>/release_evidence/v049/release-v049-<ts>.json
```

The v0.49 closeout evidence path from implementation was:

```text
/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v049/p0-13252/home/release_evidence/v049/release-v049-1780876139.json
```
