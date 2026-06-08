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
Steps 1-10 are deterministic local/action validation and do not require
provider credentials. Steps 11-14 are live-provider validation. Steps 15-18
cover browser/workspace surfaces and cleanup. Do not delete temporary homes
until after recording the evidence paths you will report.

1. Prepare the validation shell.

   ```sh
   cd /Users/spuri/projects/lexlapax/allbert-assist
   unset MIX_ENV
   unset DATABASE_PATH
   unset ALLBERT_HOME_DIR
   export ALLBERT_TRACE_ENABLED=true
   export V049_IMAGE="$PWD/docs/samples/media/images/validation-input-small.png"
   export V049_LARGE_IMAGE="$PWD/docs/samples/media/images/validation-input.png"
   test -r "$V049_IMAGE" && wc -c "$V049_IMAGE" && file "$V049_IMAGE"
   test "$(wc -c < "$V049_IMAGE")" -lt 1048576 && echo "small image under 1 MiB"
   command -v jq
   command -v rg
   ```

   Expected: the small image is readable, reports PNG `512 x 512`, is below
   `1048576` bytes, and both `jq` and `rg` resolve. Use the small image for
   command-line smokes; the larger image remains a visual/manual sample.

2. Confirm the commit and clean tracked tree.

   ```sh
   git rev-parse --short HEAD
   git log -1 --oneline
   git status --short
   git diff --check
   ```

   Expected: the commit is the intended v0.49 validation commit,
   `git status --short` prints nothing, and `git diff --check` exits 0. Stop
   here if tracked files are dirty.

3. Validate profile registration and Security Central posture in a disposable
   home.

   ```sh
   export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-policy.XXXXXX)"
   export V049_POLICY_HOME="$ALLBERT_HOME"

   mix allbert.settings set intent.direct_answer_model_enabled true
   mix allbert.settings set browser.enabled true
   mix allbert.settings set vision.enabled true
   mix allbert.settings set image.enabled true

   mix allbert.model list | tee /tmp/allbert-v049-models.log
   for profile in \
     vision_openai vision_gemini vision_ollama vision_fake \
     image_openai image_gemini image_ollama image_fake
   do
     rg -n -- "$profile" /tmp/allbert-v049-models.log
   done

   mix allbert.security status | tee /tmp/allbert-v049-security.log
   rg -n 'image_input .*effective=allowed' /tmp/allbert-v049-security.log
   rg -n 'image_generate .*effective=needs_confirmation .*capped=true' \
     /tmp/allbert-v049-security.log
   ```

   Expected: every profile `rg` command prints a matching model line.
   Security status shows `image_input` effectively `allowed` and
   `image_generate` capped to `needs_confirmation`.

4. Run the deterministic v0.49 release gate and capture its evidence path.

   ```sh
   unset ALLBERT_HOME
   unset ALLBERT_HOME_DIR
   unset DATABASE_PATH
   export V049_RELEASE_LOG=/tmp/allbert-v049-release-v049.log

   MIX_ENV=test mix allbert.test release.v049 2>&1 | tee "$V049_RELEASE_LOG"
   export V049_EVIDENCE="$(
     sed -n 's/^release\.v049 evidence: //p' "$V049_RELEASE_LOG" | tail -1
   )"
   test -r "$V049_EVIDENCE" && echo "v0.49 evidence ok: $V049_EVIDENCE"
   ```

   Expected: the gate exits 0 and the final command prints a readable evidence
   path. `release.v049` creates its own disposable gate home; it does not reuse
   the shell's `ALLBERT_HOME`.

5. Inspect deterministic release evidence.

   ```sh
   jq -r '.status' "$V049_EVIDENCE"
   jq -r '.steps[] | "\(.id): \(.status) exit=\(.exit_status)"' "$V049_EVIDENCE"
   jq -r '.secret_scan.status' "$V049_EVIDENCE"
   jq '.secret_scan.findings' "$V049_EVIDENCE"
   rg -n 'database is locked|Exqlite\.Error|SQLITE_BUSY|SQLITE_LOCKED|database table is locked' \
     "$V049_EVIDENCE" || true
   ```

   Expected: status is `passed`; every step is `passed exit=0`; secret-scan
   status is `passed`; findings are `[]`; the database-lock `rg` prints no
   matches.

6. Run the authoritative full release gate and capture its evidence path.

   ```sh
   export V049_FULL_RELEASE_LOG=/tmp/allbert-v049-release-full.log

   MIX_ENV=test mix allbert.test release 2>&1 | tee "$V049_FULL_RELEASE_LOG"
   export V049_FULL_EVIDENCE="$(
     sed -n 's/^evidence=//p' "$V049_FULL_RELEASE_LOG" | tail -1
   )"
   test -r "$V049_FULL_EVIDENCE" && echo "full release evidence ok: $V049_FULL_EVIDENCE"
   ```

   Expected: static compile, dependency, format, Credo strict, core tests, web
   tests, StockSage tests, channel-plugin tests, and Dialyzer all pass. The
   evidence path is readable.

7. Inspect full-release evidence.

   ```sh
   jq -r '.status' "$V049_FULL_EVIDENCE"
   jq -r '.phases[] | "\(.id): \(.status) exit=\(.exit_status)"' \
     "$V049_FULL_EVIDENCE"
   jq -r '.phases[] | select(.status != "passed") | .redacted_output_log_path' \
     "$V049_FULL_EVIDENCE"
   ```

   Expected: status is `passed`; every phase is `passed exit=0`; the last
   command prints nothing.

8. Validate image input through the registered action path using deterministic
   fake media.

   ```sh
   unset MIX_ENV
   unset DATABASE_PATH
   unset ALLBERT_HOME_DIR
   export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-actions.XXXXXX)"
   export V049_ACTION_HOME="$ALLBERT_HOME"

   mix allbert.settings set intent.direct_answer_model_enabled true
   mix allbert.settings set vision.enabled true
   mix allbert.settings set image.enabled true
   mix allbert.settings set model_preferences.capabilities.vision_input vision_fake
   mix allbert.settings set model_preferences.capabilities.image_generation image_fake

   mix run --no-start -e '
   Mix.Task.run("app.start")
   alias AllbertAssist.Actions.Runner
   alias AllbertAssist.Resources.{ImageMetadata, ResourceURI}
   image = System.fetch_env!("V049_IMAGE")
   {:ok, uri} = ResourceURI.image_capture("operator_validation")
   {:ok, metadata} =
     ImageMetadata.from_path(image,
       resource_uri: uri,
       filename: Path.basename(image),
       transient?: false
     )
   context = %{
     actor: "local",
     channel: :cli,
     request: %{metadata: %{image_inputs: [metadata]}}
   }
   {:ok, response} =
     Runner.run("direct_answer",
       %{text: "Describe the validation image in one sentence."},
       context
     )
   IO.inspect(%{
     status: response.status,
     source: response.direct_answer.source,
     profile: response.direct_answer.model_profile,
     image_inputs: length(get_in(response, [:direct_answer, :media, :image_inputs]) || [])
   }, label: "vision summary")
   '
   ```

   Expected: the summary includes `status: :completed`, `source: :model`,
   `profile: "vision_fake"`, and `image_inputs: 1`.

9. Validate image generation through the registered action path using
   deterministic fake media.

   ```sh
   export ALLBERT_HOME="$V049_ACTION_HOME"

   mix run --no-start -e '
   Mix.Task.run("app.start")
   alias AllbertAssist.Actions.Runner
   {:ok, response} =
     Runner.run("generate_image",
       %{prompt: "Generate a one-pixel validation image."},
       %{actor: "local", channel: :cli}
     )
   IO.inspect(%{
     status: response.status,
     profile: response.image_metadata.provider_profile,
     mime_type: response.image_metadata.mime_type,
     image_format: response.image_metadata.image_format,
     file_exists?: File.regular?(response.image_file)
   }, label: "image generation summary")
   '
   ```

   Expected: the summary includes `status: :completed`,
   `profile: "image_fake"`, `mime_type: "image/png"`,
   `image_format: "png"`, and `file_exists?: true`.

10. Check browser readiness in a disposable home.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-browser.XXXXXX)"
    export V049_BROWSER_HOME="$ALLBERT_HOME"

    mix allbert.settings set browser.enabled true
    mix allbert.browser doctor | tee /tmp/allbert-v049-browser-doctor.log
    rg -n 'browser doctor: ok' /tmp/allbert-v049-browser-doctor.log
    ```

    Expected: browser doctor prints `ok`. If it does not, record this step as
    failed and do not claim the browser screenshot manual smoke passed.

11. Run the OpenAI live vision/image smoke when `OPENAI_API_KEY` is available.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-openai.XXXXXX)"
    export V049_OPENAI_HOME="$ALLBERT_HOME"
    set -a
    [ -f .env ] && source .env
    set +a
    test -n "${OPENAI_API_KEY:-}" && echo "OPENAI_API_KEY present"
    export ALLBERT_V049_LIVE_SMOKE=1
    export ALLBERT_V049_PROVIDER=openai
    export ALLBERT_V049_IMAGE="$V049_IMAGE"
    export V049_OPENAI_LOG=/tmp/allbert-v049-openai.log

    mix run --no-start scripts/v049_vision_live_smoke.exs 2>&1 | tee "$V049_OPENAI_LOG"
    export V049_OPENAI_EVIDENCE="$(sed -n 's/^Evidence: //p' "$V049_OPENAI_LOG" | tail -1)"
    test -r "$V049_OPENAI_EVIDENCE" && echo "OpenAI evidence ok: $V049_OPENAI_EVIDENCE"
    jq -r '.status, .provider' "$V049_OPENAI_EVIDENCE"
    jq '.doctors' "$V049_OPENAI_EVIDENCE"
    jq '.redaction_scan' "$V049_OPENAI_EVIDENCE"
    jq '.image_generation.image_metadata | {mime_type, image_format, byte_size, width, height}' \
      "$V049_OPENAI_EVIDENCE"
    ```

    Expected: the key preflight prints present; the script doctors
    `vision_openai` and `image_openai`, performs real vision input, creates and
    approves image-generation confirmation, and writes evidence. Evidence
    status is `passed`, provider is `openai`, doctor summaries are live-ready,
    redaction scan values are all `false`, and generated-image metadata is
    bounded. This may upload media and incur provider cost.

12. Run the Gemini live vision/image smoke when `GEMINI_API_KEY` or
    `GOOGLE_API_KEY` is available.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-gemini.XXXXXX)"
    export V049_GEMINI_HOME="$ALLBERT_HOME"
    set -a
    [ -f .env ] && source .env
    set +a
    test -n "${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" && echo "Gemini key present"
    export ALLBERT_V049_LIVE_SMOKE=1
    export ALLBERT_V049_PROVIDER=gemini
    export ALLBERT_V049_IMAGE="$V049_IMAGE"
    export V049_GEMINI_LOG=/tmp/allbert-v049-gemini.log

    mix run --no-start scripts/v049_vision_live_smoke.exs 2>&1 | tee "$V049_GEMINI_LOG"
    export V049_GEMINI_EVIDENCE="$(sed -n 's/^Evidence: //p' "$V049_GEMINI_LOG" | tail -1)"
    test -r "$V049_GEMINI_EVIDENCE" && echo "Gemini evidence ok: $V049_GEMINI_EVIDENCE"
    jq -r '.status, .provider' "$V049_GEMINI_EVIDENCE"
    jq '.doctors' "$V049_GEMINI_EVIDENCE"
    jq '.redaction_scan' "$V049_GEMINI_EVIDENCE"
    jq '.image_generation.image_metadata | {mime_type, image_format, byte_size, width, height}' \
      "$V049_GEMINI_EVIDENCE"
    ```

    Expected: evidence status is `passed`, provider is `gemini`, doctor
    summaries are live-ready, redaction scan values are all `false`, and
    generated-image metadata is bounded. Gemini may return JPEG bytes even when
    PNG was requested; this is a pass only when evidence records a sniffed safe
    `image_format`/`mime_type` and bounded dimensions/bytes. Provider quota or
    model access failures are not release passes.

13. Run the local Ollama live vision/image smoke with the default local media
    models.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    command -v ollama
    ollama list
    ollama show qwen3-vl:8b
    ollama show x/z-image-turbo || ollama show x/z-image-turbo:latest
    curl -sS --max-time 5 http://127.0.0.1:11434/v1/models | jq -r '.data[].id'

    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-ollama.XXXXXX)"
    export V049_OLLAMA_HOME="$ALLBERT_HOME"
    export ALLBERT_V049_LIVE_SMOKE=1
    export ALLBERT_V049_PROVIDER=ollama
    export ALLBERT_V049_IMAGE="$V049_IMAGE"
    export V049_OLLAMA_LOG=/tmp/allbert-v049-ollama.log
    # Optional when Ollama is not on the default local endpoint.
    # export OLLAMA_BASE_URL="http://127.0.0.1:11434/v1"

    mix run --no-start scripts/v049_vision_live_smoke.exs 2>&1 | tee "$V049_OLLAMA_LOG"
    export V049_OLLAMA_EVIDENCE="$(sed -n 's/^Evidence: //p' "$V049_OLLAMA_LOG" | tail -1)"
    test -r "$V049_OLLAMA_EVIDENCE" && echo "Ollama evidence ok: $V049_OLLAMA_EVIDENCE"
    jq -r '.status, .provider' "$V049_OLLAMA_EVIDENCE"
    jq '.doctors' "$V049_OLLAMA_EVIDENCE"
    jq '.redaction_scan' "$V049_OLLAMA_EVIDENCE"
    ```

    Expected: Ollama is installed and serving on the OpenAI-compatible local
    endpoint; `qwen3-vl:8b` and `x/z-image-turbo` are available; evidence
    status is `passed`, provider is `ollama`, doctors are live-ready, and
    redaction scan values are all `false`. This validates local image and
    vision only; it does not validate video.

14. Run the Gemma 4 local vision-candidate smoke through the Ollama profile.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    ollama show gemma4:e4b
    ollama show x/z-image-turbo || ollama show x/z-image-turbo:latest

    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-gemma4.XXXXXX)"
    export V049_GEMMA4_HOME="$ALLBERT_HOME"
    export ALLBERT_V049_LIVE_SMOKE=1
    export ALLBERT_V049_PROVIDER=ollama
    export ALLBERT_V049_VISION_MODEL=gemma4:e4b
    export ALLBERT_V049_IMAGE="$V049_IMAGE"
    export V049_GEMMA4_LOG=/tmp/allbert-v049-gemma4.log

    mix run --no-start scripts/v049_vision_live_smoke.exs 2>&1 | tee "$V049_GEMMA4_LOG"
    export V049_GEMMA4_EVIDENCE="$(sed -n 's/^Evidence: //p' "$V049_GEMMA4_LOG" | tail -1)"
    test -r "$V049_GEMMA4_EVIDENCE" && echo "Gemma 4 evidence ok: $V049_GEMMA4_EVIDENCE"
    jq -r '.status, .provider, .profiles.vision_input' "$V049_GEMMA4_EVIDENCE"
    jq '.doctors.vision_input' "$V049_GEMMA4_EVIDENCE"
    jq '.redaction_scan' "$V049_GEMMA4_EVIDENCE"
    ```

    Expected: evidence status is `passed`, provider is `ollama`,
    `profiles.vision_input` is `vision_ollama`, the vision doctor records the
    overridden Gemma 4 model as available, and redaction scan values are all
    `false`.

15. Start a disposable workspace server for browser/UI validation.

    ```sh
    unset MIX_ENV
    unset DATABASE_PATH
    unset ALLBERT_HOME_DIR
    export ALLBERT_HOME="$(mktemp -d /tmp/allbert-v049-workspace.XXXXXX)"
    export V049_WORKSPACE_HOME="$ALLBERT_HOME"

    mix allbert.settings set intent.direct_answer_model_enabled true
    mix allbert.settings set browser.enabled true
    mix allbert.settings set vision.enabled true
    mix allbert.settings set image.enabled true
    mix allbert.settings set model_preferences.capabilities.vision_input vision_fake
    mix allbert.settings set model_preferences.capabilities.image_generation image_fake

    PORT=4049 mix phx.server > /tmp/allbert-v049-workspace-server.log 2>&1 &
    export V049_SERVER_PID=$!
    sleep 10
    curl -fsS http://127.0.0.1:4049/workspace >/tmp/allbert-v049-workspace.html
    echo "workspace server pid=$V049_SERVER_PID"
    ```

    Expected: `curl` exits 0 and the server is reachable at
    `http://127.0.0.1:4049/workspace`. Keep this server running through
    steps 16-17.

16. Validate workspace vision input and image generation in the browser.

    ```sh
    echo "Open: http://127.0.0.1:4049/workspace"
    echo "Upload this image: $V049_IMAGE"
    ```

    In the browser, upload or paste `$V049_IMAGE` and ask:
    `Describe this validation image in one sentence.` Then request image
    generation with: `Generate a one-pixel validation image.`

    ```sh
    mix allbert.confirmations list --resolved | tee /tmp/allbert-v049-confirmations.log
    mix allbert.security review --recent --limit 20 | tee /tmp/allbert-v049-security-review.log
    [ -d "$ALLBERT_HOME/memory/traces" ] &&
      rg -n 'image://capture|screen://capture|vision_fake|image_fake|generate_image' \
        "$ALLBERT_HOME/memory/traces" || true
    ```

    Expected: workspace accepts the upload, answers through the configured
    `vision_fake` profile, generates through `image_fake`, and security review
    shows no redaction incidents. Resolved confirmations may be empty in this
    fake-profile workspace smoke; steps 11-14 are the remote/local provider
    confirmation proof. Trace search should find redacted metadata refs if
    traces were emitted; it must not print raw image bytes or local file paths.

17. Validate browser screenshot analysis through the operator UI flow.

    ```sh
    mix allbert.browser doctor | tee /tmp/allbert-v049-workspace-browser-doctor.log
    echo "In the workspace Browser flow, capture https://example.com."
    echo "Record the cache://browser/... screenshot_ref, then analyze that ref."
    ```

    After the browser action:

    ```sh
    [ -d "$ALLBERT_HOME/cache/browser" ] &&
      find "$ALLBERT_HOME/cache/browser" -type f | head -20 || true
    [ -d "$ALLBERT_HOME/memory/traces" ] &&
      rg -n 'cache://browser|browser_screenshot|screen://capture/browser_' \
        "$ALLBERT_HOME/memory/traces" || true
    mix allbert.security review --recent --limit 20
    ```

    Expected: browser doctor remains `ok`; the UI produces a
    `cache://browser/...` screenshot ref; screenshot analysis records
    browser-screenshot provenance (`screen://capture/browser_<hash>` when
    traced); no OS screen capture is started; security review shows no
    redaction incidents.

18. Stop the workspace server and clean up temporary homes after recording
    report-back evidence.

    ```sh
    if [ -n "${V049_SERVER_PID:-}" ] && kill -0 "$V049_SERVER_PID" 2>/dev/null
    then
      kill "$V049_SERVER_PID"
      wait "$V049_SERVER_PID" 2>/dev/null || true
    fi
    lsof -nP -iTCP:4049 -sTCP:LISTEN || true

    printf '%s\n' \
      "release.v049 evidence: ${V049_EVIDENCE:-missing}" \
      "full release evidence: ${V049_FULL_EVIDENCE:-missing}" \
      "OpenAI evidence: ${V049_OPENAI_EVIDENCE:-not-run}" \
      "Gemini evidence: ${V049_GEMINI_EVIDENCE:-not-run}" \
      "Ollama evidence: ${V049_OLLAMA_EVIDENCE:-not-run}" \
      "Gemma 4 evidence: ${V049_GEMMA4_EVIDENCE:-not-run}"

    # Run this only after copying evidence paths into the validation report.
    rm -rf \
      "${V049_POLICY_HOME:-}" \
      "${V049_ACTION_HOME:-}" \
      "${V049_BROWSER_HOME:-}" \
      "${V049_WORKSPACE_HOME:-}" \
      "${V049_OPENAI_HOME:-}" \
      "${V049_GEMINI_HOME:-}" \
      "${V049_OLLAMA_HOME:-}" \
      "${V049_GEMMA4_HOME:-}"
    ```

    Expected: port 4049 has no listener after shutdown. Report `PASS` only if
    every required step completed as expected; otherwise report the failing
    step number, command or UI action, error output, and evidence path.

## Release Gate

The deterministic fixture gate is:

```sh
MIX_ENV=test mix allbert.test release.v049
```

It writes evidence to:

```text
<ALLBERT_HOME>/release_evidence/v049/release-v049-<ts>.json
```

The latest deterministic v0.49 release evidence path is:

```text
/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release-v049/p0-11013/home/release_evidence/v049/release-v049-1780886771.json
```

The latest full release-gate evidence path is:

```text
/var/folders/nc/r_scv0hd78x07x908ymg5mk80000gn/T/allbert_test_gates/release/p0-1218/home/release_evidence/gates/release-2026-06-08T03_08_24Z.json
```

Current M10 live-provider status:

- OpenAI passed with evidence:
  `/tmp/allbert-v049-openai.wd0zIU/release_evidence/v049/live-vision-openai-1780886149.json`.
- Gemini passed with evidence:
  `/tmp/allbert-v049-gemini.cQbb9E/release_evidence/v049/live-vision-gemini-1780886180.json`.
  The generated output was returned as JPEG and accepted through the
  system-level generated-output normalization path.
- Local Ollama passed with `qwen3-vl:8b` and `x/z-image-turbo`; evidence:
  `/tmp/allbert-v049-ollama.Z4w0Sj/release_evidence/v049/live-vision-ollama-1780886386.json`.
- Gemma 4 local vision-candidate validation passed with
  `ALLBERT_V049_VISION_MODEL=gemma4:e4b`; evidence:
  `/tmp/allbert-v049-gemma4.v2qeT4/release_evidence/v049/live-vision-ollama-1780886599.json`.

v0.49 is ready for operator manual validation before the release-tag decision.
