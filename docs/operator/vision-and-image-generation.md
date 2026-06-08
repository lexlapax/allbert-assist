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

## Numbered Validation Checklist

Use these steps for v0.49 manual validation and report back by step number.
Steps 1-10 are deterministic local validation and do not require provider
credentials. Steps 11-18 are credentialed/manual validation for an operator who
has OpenAI or Gemini credentials and wants to validate real provider behavior
before tagging.

1. Start from the repo root and record the commit being validated:

   ```sh
   git rev-parse --short HEAD
   git status --short
   ```

   Expected: the commit is the intended v0.49 validation commit. Report any
   local changes or untracked files separately before continuing.

2. Create a disposable Allbert Home for operator validation:

   ```sh
   export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-validate.XXXXXX)"
   ```

   Expected: `echo "$ALLBERT_HOME"` prints a `/tmp/allbert-v049-validate.*`
   path. Do not use a real `~/.allbert` for validation.

3. Enable only the v0.49 operator surfaces:

   ```sh
   mix allbert.settings set intent.direct_answer_model_enabled true
   mix allbert.settings set browser.enabled true
   mix allbert.settings set vision.enabled true
   mix allbert.settings set image.enabled true
   mix allbert.settings get intent.direct_answer_model_enabled
   mix allbert.settings get browser.enabled
   mix allbert.settings get vision.enabled
   mix allbert.settings get image.enabled
   ```

   Expected: all reads report `true`.

4. Confirm the v0.49 model profiles are present:

   ```sh
   mix allbert.model list
   ```

   Expected: output includes `vision_openai`, `vision_gemini`, `vision_fake`,
   `image_openai`, `image_gemini`, and `image_fake`.

5. Confirm Security Central floors and caps:

   ```sh
   mix allbert.security status
   ```

   Expected: `image_input` is effectively `allowed`; `image_generate` is
   effectively `needs_confirmation` even if configured `allowed`; browser
   session start and navigation remain `needs_confirmation`; browser screenshot
   remains `allowed`.

6. Confirm browser readiness:

   ```sh
   mix allbert.browser doctor
   ```

   Expected: `browser doctor: ok`. If the doctor is unavailable, record the
   error and do not claim the browser manual smoke passed; the deterministic
   release gate in step 7 still covers the stubbed screenshot bridge.

7. Run the deterministic v0.49 release gate:

   ```sh
   MIX_ENV=test mix allbert.test release.v049
   ```

   Expected: the gate passes and prints an evidence path like
   `<ALLBERT_HOME>/release_evidence/v049/release-v049-<ts>.json`.

8. Inspect the v0.49 evidence file from step 7:

   ```sh
   export V049_EVIDENCE="<path printed by step 7>"
   jq -r '.status' "$V049_EVIDENCE"
   jq -r '.steps[] | "\(.id): \(.status) exit=\(.exit_status)"' "$V049_EVIDENCE"
   jq '.secret_scan' "$V049_EVIDENCE"
   ```

   Expected: status is `passed`; every step has `status=passed` and
   `exit=0`; secret scan findings are empty.

9. Check release evidence for database-lock signatures:

   ```sh
   rg -n 'database is locked|Exqlite\.Error|SQLITE_BUSY|SQLITE_LOCKED|database table is locked' "$V049_EVIDENCE"
   ```

   Expected: no output.

10. Run the full release gate before a release tag:

    ```sh
    MIX_ENV=test mix allbert.test release
    ```

    Expected: static compile, dependency, format, Credo, core tests, web tests,
    StockSage tests, channel-plugin tests, and Dialyzer all pass. Record the
    printed full-release evidence path.

11. If validating OpenAI live behavior, configure the OpenAI credential through
    stdin and enable the provider:

    ```sh
    printf '%s\n' "$OPENAI_API_KEY" | mix allbert.settings providers set-key openai
    mix allbert.settings set providers.openai.enabled true
    ```

    Expected: the credential command reports `openai credential=configured`;
    the provider setting reports `true`. Do not pass keys as command
    arguments.

12. Select OpenAI vision and image-generation profiles for live validation:

    ```sh
    mix allbert.settings set model_preferences.capabilities.vision_input vision_openai
    mix allbert.settings set model_preferences.capabilities.image_generation image_openai
    mix allbert.model doctor vision_openai
    mix allbert.model doctor image_openai
    ```

    Expected: with valid credentials, doctors report `credential_ok=true`,
    `endpoint_ok=true`, and the selected models are available or explicitly
    diagnosed by the provider. Without credentials, the expected diagnostic is
    `credential_missing`.

13. If validating Gemini live behavior instead, configure Gemini and select its
    v0.49 profiles:

    ```sh
    printf '%s\n' "$GEMINI_API_KEY" | mix allbert.settings providers set-key gemini
    mix allbert.settings set providers.gemini.enabled true
    mix allbert.settings set model_preferences.capabilities.vision_input vision_gemini
    mix allbert.settings set model_preferences.capabilities.image_generation image_gemini
    mix allbert.model doctor vision_gemini
    mix allbert.model doctor image_gemini
    ```

    Expected: with valid credentials, doctors report `credential_ok=true`,
    `endpoint_ok=true`, and the selected models are available or explicitly
    diagnosed by the provider. Without credentials, the expected diagnostic is
    `credential_missing`.

14. Start a disposable workspace server for manual UI validation:

    ```sh
    PORT=4049 mix phx.server
    ```

    Expected: the server starts on `http://localhost:4049`. Keep this terminal
    running until steps 15-17 are complete.

15. Validate workspace vision input in the browser:

    Open `http://localhost:4049/workspace`, upload or paste a small PNG, JPEG,
    or WebP image, and ask a concrete question about the image.

    Expected: the upload control is available; oversized/unsupported media is
    rejected server-side; the answer uses a resolved `vision_input` profile;
    traces/action metadata contain redacted image metadata, not raw image bytes
    or local file paths.

16. Validate browser screenshot analysis:

    In `/workspace`, use the Browser app/panel flow or a browser prompt such as
    `screenshot https://example.com` to create a browser screenshot. Open the
    Browser results panel and record the `cache://browser/...` `screenshot_ref`
    shown for the screenshot artifact. Then analyze that same ref through the
    screenshot analysis action/surface available in the runtime.

    Expected: the screenshot ref has the form `cache://browser/...`; analysis
    records `source: :browser_screenshot` and `screen://capture/browser_<hash>`
    provenance; the action does not capture the OS screen or grant authority
    from the `screen://` id itself.

17. Validate image generation:

    Request image generation through the runtime/workspace action surface.

    Expected: remote OpenAI/Gemini profiles create a confirmation before the
    provider call; after approval, `generate_image` writes a bounded local PNG,
    reports display-only usage/cost metadata, and redacts binary content plus
    generated-resource paths from traces/action metadata.

18. Stop the workspace server and inspect recent confirmations/traces:

    ```sh
    mix allbert.confirmations list --resolved
    mix allbert.security review --recent --limit 20
    ```

    Expected: resolved confirmations show the image-generation approval; recent
    security review shows no redaction incidents. Report any denial, provider
    diagnostic, or redaction incident with the step number where it appeared.

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
