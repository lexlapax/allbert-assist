# ADR 0051: Provider Capability Metadata And Operator Preferences

## Status

Accepted in v0.48 M1.

M8R amendment before v0.48 release: fake voice profiles are fixture-only.
Release-ready voice capability routing must include executable local
OpenAI-compatible STT/TTS, OpenAI remote STT/TTS, Gemini remote STT/TTS, and a
local Ollama text-generation profile for the listen -> think -> speak loop.
Anthropic/Claude profiles remain `text_generation` profiles in v0.48 unless a
future ADR/plan adds native Anthropic audio APIs.

v1.3 M9.b.3 amendment (2026-07-31): DirectAnswer is the first task whose
non-empty preference is a closed, operator-ordered execution chain rather than
an open list followed implicitly by the global primary. The shipped head is
`direct_answer_local` (`qwen2.5:7b`); the global `local`/primary profile remains
`llama3.2:3b`. This amendment is additive and task-specific; other task and
capability resolver behavior is unchanged.

v1.3 M9.b.4.3/M9.b.5.3 amendment (implemented at `c3baec24`): add distinct,
non-empty closed task chains for `fanout_manager`, `fanout_review`, and
`fanout_synthesis`. Their additive shipped values reuse
`direct_answer_local`, but the roles remain independently resolved,
disclosed, diagnosed, and operator-overridable. Selection configures a route;
it is not model qualification, transport consent, permission, or effect
authority.

M1 closeout evidence:

- `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/settings/provider_catalog_test.exs apps/allbert_assist/test/allbert_assist/settings_test.exs`
  passed with 44 tests and 0 failures.
- The shipped provider catalog now validates profile capabilities/media and
  includes deterministic fake STT/TTS profiles as descriptive seed data.
- `MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/settings/model_preferences_test.exs apps/allbert_assist/test/mix/tasks/allbert_onboard_test.exs apps/allbert_assist/test/mix/tasks/allbert_settings_test.exs apps/allbert_assist/test/mix/tasks/allbert_model_test.exs apps/allbert_assist/test/allbert_assist/actions/settings_actions_test.exs apps/allbert_assist/test/allbert_assist/actions/intent/direct_answer_test.exs apps/allbert_assist/test/allbert_assist/onboarding_test.exs`
  passed with 38 tests and 0 failures for M2 preference resolution and
  onboarding/settings compatibility.

## Context

Allbert already has a provider/model substrate:

- shipped seed data under `apps/allbert_assist/priv/provider_catalog/models.json`;
- Settings Central provider and model profile overrides;
- Jido model aliases generated from `model_profiles.*`;
- `doctor_model_profile` and ADR 0047's redacted doctor envelope;
- operator-facing model selection through `intent.model_profile` and the
  ad-hoc `intent.direct_answer_model_profile` override.

That substrate is currently text-generation shaped. Model profiles do not
declare capabilities or media metadata, and task-specific preferences are
encoded in profile names or one-off settings keys. v0.48 voice and v0.49 vision
need speech, image, and video models to use the same provider framework instead
of introducing separate voice-provider or image-provider systems.

Current providers expose materially different media shapes: request/response
audio APIs, realtime audio sessions, multimodal audio/video model inputs, local
text/vision endpoints, dedicated STT/TTS APIs, and local offline engines. The
Allbert profile contract must model those differences without treating provider
marketing metadata as permission.

## Decision

Providers are modality-agnostic connection profiles. Model profiles declare the
capabilities they support, and operator preferences choose ranked model
profiles for a task or capability.

### Capability Vocabulary

v0.48 introduces this additive vocabulary:

- `text_generation`
- `speech_to_text`
- `text_to_speech`
- `vision_input`
- `image_generation`
- `video_input`
- `token_streaming`
- `embeddings`
- `tool_use`

Later releases may add capabilities, but they must not change the meaning of
the existing names without an ADR amendment and settings migration plan.

Capability names are routing predicates:

- `speech_to_text` means audio-to-text transcription through a registered
  action.
- `text_to_speech` means text-to-audio synthesis through a registered action.
- `vision_input` means image/screenshot input analysis.
- `image_generation` means text-to-image or context-to-image synthesis through
  a registered action.
- `video_input` means video or sampled-frame input analysis; it is vocabulary
  only until a later plan implements it.
- `token_streaming` means streaming text tokens or text deltas. Realtime audio
  sessions are media transport metadata, not this capability.

Model profiles may also carry optional media metadata. Media metadata explains
how a selected adapter can run and how the UI should describe the profile. It
does not grant permission and is not a substitute for doctor output:

```json
{
  "media": {
    "input_modalities": ["audio"],
    "output_modalities": ["text"],
    "transport_modes": ["request_file", "local_endpoint"],
    "deployment_mode": "local_endpoint",
    "audio_formats_supported": ["wav", "flac"],
    "audio_sample_rates_supported": [16000, 24000],
    "max_audio_bytes": 10485760,
    "max_audio_duration_ms": 120000
  }
}
```

Known `deployment_mode` values are `fake`, `local_endpoint`, `bundled_local`,
and `remote_credentialed`. Known `transport_modes` are `request_file`,
`live_upload`, `realtime_session`, `local_endpoint`, and `bundled_local`.
`input_modalities`/`output_modalities` use coarse media values such as `text`,
`audio`, `image`, and `video`.

v0.49 image profiles may add descriptive image media bounds:

```json
{
  "media": {
    "input_modalities": ["text", "image"],
    "output_modalities": ["text"],
    "deployment_mode": "remote_credentialed",
    "image_formats_supported": ["png", "jpeg", "webp"],
    "max_image_bytes": 20971520,
    "max_image_pixels": 33177600
  }
}
```

There is intentionally no `multimodal` capability. Local or online profiles can
describe multiple modalities through media metadata, but executable routing
still uses specific capabilities such as `speech_to_text`, `text_to_speech`,
`vision_input`, and `image_generation`. Generic audio understanding, video
input, and video generation require a future ADR/plan before they can become
operator-visible executable paths.

`fake` is a test deployment mode only. A profile with `deployment_mode: fake`
may satisfy deterministic fixture tests but must not be treated as release
authority for an operator-visible modality. `local_ollama`/Ollama profiles may
declare `text_generation` and can be selected for the text turn after STT; they
must not be marked `speech_to_text` or `text_to_speech` unless Ollama exposes
native audio endpoints and Allbert implements that adapter.

### Catalog And Settings Shape

The shipped catalog may include coarse provider metadata:

```json
{
  "providers": {
    "local_ollama": {
      "type": "openai_compatible",
      "modalities": ["text"]
    }
  }
}
```

Model profiles carry capability metadata:

```json
{
  "model_profiles": {
    "coding_local": {
      "provider": "local_ollama",
      "model": "qwen2.5-coder:7b",
      "capabilities": ["text_generation", "tool_use"],
      "media": {
        "input_modalities": ["text"],
        "output_modalities": ["text"],
        "deployment_mode": "local_endpoint"
      }
    }
  }
}
```

Settings Central remains the runtime authority. The catalog is seed data only;
operator overrides still win, and live doctor probes still determine
availability. Capability metadata never grants permission, never supplies
secrets, and never bypasses provider policy.

### Preference Shape

v0.48 adds a first-class `model_preferences` settings namespace. Task and
capability preferences are ordered lists of model profile names, with a global
primary profile used as the common fallback:

```elixir
%{
  "primary" => "local",
  "tasks" => %{
    "direct_answer" => ["fast", "local"],
    "coding" => ["coding", "coding_local", "local"]
  },
  "capabilities" => %{
    "text_generation" => ["local", "fast", "capable"],
    "speech_to_text" => ["voice_stt_local", "voice_stt_openai", "voice_stt_gemini"],
    "text_to_speech" => ["voice_tts_local", "voice_tts_openai", "voice_tts_gemini"]
  }
}
```

Fake voice profiles may appear in deterministic tests, but they must not be
operator default preferences or release-validation targets.

The resolver accepts a task or capability, walks the matching ranked list, and
returns the first enabled profile whose declared capabilities satisfy the
request. If the ranked list is absent or exhausted, the resolver tries the
global primary only when that profile satisfies the requested capability.
Otherwise it returns a bounded `:no_capable_profile` error.

The resolver must skip disabled profiles and profiles whose configured
provider is disabled. Doctor output may be used as diagnostic context, but it
does not grant authority and does not silently rewrite preferences.

For `direct_answer`, a **non-empty**
`model_preferences.tasks.direct_answer` list is the complete candidate chain.
Its authored order is binding, and the resolver does not append or reorder
`model_preferences.primary`. An explicitly configured hosted profile may
therefore lead the task chain and still uses the existing pre-egress disclosure.
An unrelated hosted credential or global primary cannot escape into the task.
Only an **empty** DirectAnswer list uses the legacy primary fallback. This
distinguishes explicit operator policy from the compatibility state without a
second settings namespace.

The three phase-separated fan-out roles are also complete, closed task chains:

```elixir
%{
  "fanout_manager" => ["direct_answer_local"],
  "fanout_review" => ["direct_answer_local"],
  "fanout_synthesis" => ["direct_answer_local"]
}
```

For these roles an empty list is invalid, and the resolver never appends the
global primary. `fanout_manager` is consumed only by conversational planning;
`fanout_review` is consumed only by the separate Worker/composer critics;
`fanout_synthesis` is consumed only by initial/revised report composition.
DirectAnswer child generation and its one possible revision continue through
the registered `direct_answer` task route rather than borrowing either critic
or synthesis selection. Reusing the same initial profile in all four chains is
an additive compatibility default, not permission to treat the purposes as one
role or evidence that a model has passed the frozen fan-out qualification.

Resolution checks declared capability and enabled provider state. Runtime then
performs callability preflight and exact effective-transport Disclosure before
durable fan-out framing; provider invocation retains the request-specific
configuration binding. The read-only model doctor reports each complete chain,
the exact resolved profile, callability, and the exact unavailable role. It
never auto-pulls a model, rewrites a preference, or initiates a per-turn
prompt. A
hosted profile remains an explicit operator choice and requires the existing
bounded exact-route disclosure; one shared route may carry several role usages
under one acknowledgement.

The shipped DirectAnswer defaults are:

```elixir
model_preferences = %{
  "primary" => "local",
  "tasks" => %{"direct_answer" => ["direct_answer_local"]}
}

model_profiles = %{
  "local" => %{"provider" => "local_ollama", "model" => "llama3.2:3b"},
  "direct_answer_local" => %{
    "provider" => "local_ollama",
    "model" => "qwen2.5:7b",
    "temperature" => 0.0,
    "max_tokens" => 1024,
    "timeout_ms" => 60_000
  }
}
```

DirectAnswer forces temperature `0` at its request boundary even when an
operator-authored profile carries a different temperature. Token and timeout
bounds remain profile-owned. This deterministic task control does not affect
the same profile when another consumer uses it.

### Backward Compatibility

The existing text settings remain compatibility aliases:

- `intent.model_profile` ↔ `model_preferences.primary` (single ↔ single): a
  legacy write sets `primary`; a `primary` write updates the legacy read.
- `intent.direct_answer_model_profile` ↔
  `model_preferences.tasks.direct_answer` (single ↔ list): the legacy read
  returns the list head (or `primary` when the list is empty); a legacy write
  sets the list to `[value]`.

`allbert admin models use PROFILE` is an intentionally broad operator command:
it moves `PROFILE` to both the global-primary position and the DirectAnswer
task head, preserves the existing DirectAnswer fallback tail without
duplicates, and enables that provider (plus model assist when requested). A
targeted change uses `allbert admin models use-direct-answer PROFILE`; its
registered Settings action moves only the DirectAnswer head, preserves the
tail, enables the selected provider, audits both writes, and leaves the global
primary unchanged. The raw `intent.direct_answer_model_profile` alias remains
for compatibility and retains its historical single-value behavior
(`list = [value]`); operator chooser surfaces use the purpose-specific action.
There are no legacy single-value aliases for the three fan-out role chains;
they are written through their canonical Settings Central keys so role intent
cannot be lost in alias projection.

The `model_preferences.*` and `voice.*` namespaces declare `schema_version: 1`
per ADR 0046. Existing callers can continue to read those keys during
migration. New v0.48+ callers use the capability-aware resolver. A
compatibility alias must never produce a profile that fails capability
validation.

### Onboarding And Settings Central

Onboarding and Settings Central should expose:

- global primary profile;
- task preferences such as `coding` and `direct_answer`;
- capability preferences such as `speech_to_text`, `text_to_speech`, and later
  `vision_input`/`image_generation`;
- local/offline defaults before cloud defaults;
- explicit operator override for cloud provider use.

Provider credentials remain Settings Central secrets. No preference setting
stores a raw credential or raw URL.

## Consequences

- v0.48 can ship voice without a parallel provider framework.
- v0.49 vision can consume the same capability and preference substrate.
- Realtime audio and generic audio/video understanding remain expressible as
  metadata without becoming v0.48 release authority.
- Profile names can stay semantic, but routing no longer depends on name
  convention alone.
- The default "top candidate" and per-capability overrides become visible,
  auditable settings instead of scattered consumer-specific keys.
- Graceful fallback is deterministic and bounded: incapable, disabled, or
  unavailable profiles are skipped, but no model output can choose a provider
  or capability at runtime.
- The resolver selects a profile only; per-modality execution (e.g. the v0.48
  voice STT/TTS adapter) runs behind the action boundary and makes no authority
  decisions.

## Non-Goals

- No automatic capability grant from provider marketing metadata.
- No automatic cloud upload when an operator has not opted into a cloud
  provider profile.
- No implementation of generic audio-understanding, video ingestion, video
  generation, or realtime speech-to-speech in v0.48; v0.49 implements only the
  bounded `vision_input` and `image_generation` image bridge unless a later
  amendment expands it.
- No unified spend dashboard or budget enforcement in v0.48.
- No promotion action that turns a doctor result into a preference without an
  explicit Settings Central write.

## Validation

v0.48 M1 and M2 added focused tests for:

- catalog capability loading and Settings Central merge behavior;
- media metadata validation and Settings Central merge behavior;
- resolver preference ordering;
- capability validation and primary fallback;
- compatibility aliases for `intent.model_profile` and
  `intent.direct_answer_model_profile`;
- disabled-provider and disabled-profile skips;
- secret redaction in diagnostics and traces.

The release gate must include `mix allbert.test release.v048`.

M8 closeout adds `release.v048` coverage for the provider capability core,
voice STT/TTS actions, CLI voice, workspace microphone capture, Telegram
voice-note ingestion, v0.48 eval rows, and the release-task usage surface.

## Relates To

- ADR 0004 - Domain Settings Engine.
- ADR 0011 - Confirmed External Capability Adapters.
- ADR 0031 - Settings Schema Fragments And Authority.
- ADR 0046 - Settings Schema Migration Policy.
- ADR 0047 - Provider Doctor Contract.
- `docs/plans/archives/v0.39-plan.md`.
- `docs/plans/archives/v0.48-plan.md`.
- `docs/plans/archives/v0.49-plan.md`.
