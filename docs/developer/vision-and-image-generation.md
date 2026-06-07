# Vision And Image Generation Developer Guide

Status: v0.49 implemented. This guide summarizes the shipped code seams for
image/screenshot-to-text and text-to-image work.

## Capability Boundary

v0.49 adds no generic `multimodal` capability. Executable media routes are
capability-specific:

- `vision_input`: image or screenshot plus text -> text answer.
- `image_generation`: text prompt -> generated image file.

`video_input`, generic audio understanding, video generation, and catch-all
media routing remain future work.

## Vision Input

Vision input stays on the existing text path:

1. Workspace upload/paste creates bounded image metadata for an
   `image://capture/<id>` or `screen://capture/<id>` resource.
2. `direct_answer` detects image metadata on the request and resolves
   `Models.for(:vision_input)`.
3. The ReqLLM answerer attaches the image as a multimodal content part on the
   normal chat request.
4. Transient image inputs are removed after the action returns.
5. Runtime traces keep redacted metadata only.

Important modules:

- `AllbertAssist.Actions.Intent.DirectAnswer`
- `AllbertAssist.Resources.ImageMetadata`
- `AllbertAssist.Resources.ImageBounds`
- `AllbertAssist.Runtime.Redactor`
- `AllbertAssistWeb.WorkspaceLive`

## Image Generation

Image generation is a registered internal action:

```text
generate_image -> Models.candidates_for(:image_generation)
  -> PermissionGate.authorize(:image_generate, deployment mode)
  -> ReqLLM.generate_image/3
  -> ImageMetadata.from_path + ImageBounds.validate_generated
  -> redacted metadata + local image_file
```

Remote/unknown/local-endpoint deployment modes confirm before the provider
call. Fake image generation is allowed only as fixture support. Retry behavior
is intentionally bounded: a retryable provider failure advances once through the
ranked `image_generation` candidates and rechecks the permission floor.

Important modules:

- `AllbertAssist.Actions.Image.GenerateImage`
- `AllbertAssist.Actions.Confirmations.ApproveConfirmation`
- `AllbertAssist.Actions.Registry`
- `AllbertAssist.Settings.Models`
- `AllbertAssist.Settings.ModelRuntime`

## Resource And Artifact Boundary

v0.49 media files are bounded local resources:

- uploaded input: `image://capture/<id>` or `screen://capture/<id>`;
- generated output: local `image_file` plus redacted `file://[REDACTED_IMAGE_PATH]`
  metadata;
- content hashes are integrity/provenance metadata only.

Do not add cross-surface artifact lookup, artifact lifecycle, or
`artifact://sha256/<hex>` identity in v0.49 code. That belongs to v0.50
Artifacts Central.

## Tests And Gates

Focused implementation tests:

```sh
MIX_ENV=test mix test \
  apps/allbert_assist/test/allbert_assist/resources/image_metadata_test.exs \
  apps/allbert_assist/test/allbert_assist/resources/image_bounds_test.exs \
  apps/allbert_assist/test/allbert_assist/actions/intent/direct_answer_test.exs \
  apps/allbert_assist/test/allbert_assist/actions/generate_image_test.exs \
  apps/allbert_assist/test/security/v049_vision_modality_eval_test.exs
```

Release-specific gate:

```sh
MIX_ENV=test mix allbert.test release.v049
```

The gate uses fake providers and local fixture images; it must not require live
network or provider credentials.
