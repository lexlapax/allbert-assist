# ADR 0047: Provider Doctor Contract

## Status

Accepted at v0.39 First-Run Onboarding And Provider Control M1 closeout.
Becomes a Tier-1 freeze candidate at v1.0.

## Context

v0.39 First-Run Onboarding ships a provider doctor: a bounded probe operators
run before they trust a provider/model profile. The post-v0.37 planning pass
(`docs/archives/version-1.0-planning-03.md`) names two branches and asserts
both branches return the same redacted summary, but does not pin the shape.

Several later milestones reuse the doctor pattern:

- **v0.40 MCP client integration** doctors MCP servers (transport reachable,
  tools/resources listable, secret env present).
- **v0.47 voice modality** doctors STT/TTS provider profiles (credential
  reachable, model available, on-device backends present).
- **v0.48 vision and image generation** doctors vision-capable provider
  profiles (credential reachable, model accepts image input, generation
  endpoint reachable).

Without a pinned doctor contract, each later milestone risks reinventing the
return shape, drifting on redaction policy, or leaking provider-specific
internals (raw error bodies, full URLs, credential fragments) in
operator-facing output.

The v1.0 acceptance matrix (`docs/plans/roadmap.md`) requires first-run
setup to succeed on macOS, Linux, and Windows/WSL2, and requires operators
to choose any of local Ollama, OpenAI, Anthropic, or OpenRouter. Both
acceptance items run through the doctor. The doctor return shape therefore
becomes part of the operator-visible contract that v1.0 promises to
preserve.

## Decision

The v0.39 model-profile doctor and downstream doctors that opt into the same
diagnostic pattern (v0.40, v0.47, v0.48) share a single canonical return
shape, share one redaction policy, and evolve additive-only.

The public v0.39 action is `doctor_model_profile`: callers pass a model
profile name, and the action resolves `model_profiles.<name>.provider` to the
provider profile. Branch selection still belongs to the provider profile's
`endpoint_kind` field.

### 1. Branch selection: explicit `endpoint_kind`

Provider profiles carry an explicit `endpoint_kind` field:

```
providers.<name>.endpoint_kind ∈ {"credentialed_remote", "local_endpoint"}
```

Default derivation: `local_ollama` → `local_endpoint`; everything else →
`credentialed_remote`. Operator-overridable through `update_setting` (safe
key).

Branch selection is **not** derived from `base_url` heuristics, **not**
derived from provider type alone, and **not** decided inside the doctor
module. The Settings Central field is authority; the doctor module reads it
after resolving the model profile's referenced provider.

### 2. Canonical return shape

Every doctor (v0.39, v0.40, v0.47, v0.48, and any future doctor) returns:

```elixir
%{
  endpoint_kind: :credentialed_remote | :local_endpoint,
  credential_ok: boolean() | nil,            # nil for :local_endpoint
  endpoint_ok: boolean(),
  model_available: boolean() | :unknown,
  context_window: pos_integer() | nil,
  deprecation_warning: String.t() | nil,
  last_seen_rate_limit_hint: String.t() | nil,
  redacted_host: String.t(),                 # host only; path/query stripped
  diagnostics: [%{code: atom(), message: String.t()}]
}
```

Additive-only post-v0.39: later milestones may add new optional fields, but no
field is removed or renamed without an ADR amendment and an ADR 0046 schema
migration. Known additive fields:

- **v0.40 MCP** (`mcp_doctor_server`) adds `:transport_kind`
  (`:streamable_http | :sse | :stdio`), `:tools_listable` (boolean),
  `:resources_listable` (boolean), `:tool_count`
  (`non_neg_integer() | :unknown`), `:resource_count`
  (`non_neg_integer() | :unknown`), and `:protocol_version`
  (`String.t() | nil`). For stdio servers `endpoint_kind` is `:local_endpoint`;
  for authenticated HTTP/SSE servers it is `:credentialed_remote`.
- **v0.48 vision** adds `:image_input_supported`.

### 3. Redaction policy

Doctors **never** return:

- raw secret values;
- raw HTTP error response bodies;
- full URLs (path and query are stripped; only `redacted_host` is returned);
- backend stack traces;
- credential fragments (no prefix/suffix peeks).

Doctors **may** return:

- bounded diagnostic codes (e.g., `:credential_missing`, `:endpoint_unreachable`,
  `:model_not_found`, `:rate_limited`);
- operator-readable messages capped at 256 bytes per `diagnostics` entry,
  rendered from a fixed catalog of strings (no dynamic raw-input pass-through);
- host-only URL fragments;
- additive domain-specific informational fields per §2.

### 4. Execution boundary

Doctors run as registered Jido actions under Security Central:

- v0.39: `doctor_model_profile` (`:read_only`, `:not_required`).
- v0.40: `mcp_doctor_server` (`:read_only`, `:not_required`).
- v0.47: `doctor_voice_provider` (`:read_only`, `:not_required`).
- v0.48: `doctor_vision_provider` (`:read_only`, `:not_required`).

The v0.39 doctor is read-only but network-observable. It is allowed to probe
only the configured host of the provider resolved from a configured model
profile. It never accepts raw URLs, model-output-selected targets, or
operator-supplied one-off probe destinations. It does not create remembered
Resource Access grants.

All effectful network calls inside the doctor go through `Req` and respect a
doctor-specific subset of the `external_network_request` posture: SSRF
blocking, bounded timeouts, bounded response bodies, no credential-bearing
redirect following, no unbounded retries, and host-only redaction. Doctors do
not bypass Resource Access Security Posture; future doctors that need
free-form URLs or arbitrary targets must use explicit resource confirmation
instead of this read-only doctor boundary.

### 5. Tier-1 freeze candidate

This ADR is binding from v0.39 acceptance forward and becomes a **Tier-1
freeze contract** at v1.0 per the roadmap's tiered freeze. Tier-1 means the
return-shape keys, redaction policy, and execution-boundary rules cannot
change between v1.0 and the next major release without an ADR amendment.

## Consequences

- v0.39 lands the canonical contract; later doctors implement the same
  shape without re-debating return fields.
- Operator-facing UX is consistent across doctors (workspace picker, CLI,
  channel summaries all render the same fields).
- Doctor output is safe to render in traces and audits without additional
  redaction passes — the doctor itself is the redaction boundary.
- Adding a new provider-specific signal (e.g., v0.48 image-input
  capability) is a one-line additive field, not a return-shape redesign.
- `providers.*.endpoint_kind` becomes part of the v1.0 Tier-1 schema
  freeze; renaming or removing it requires an ADR amendment and an
  ADR 0046 settings migration.
- The action name intentionally follows the operator input (`model profile`)
  while the branch semantics follow the resolved provider profile. This avoids
  a CLI/action mismatch where `mix allbert.model doctor local` would be backed
  by an action named as if it accepted only provider profile names.

## Alternatives Considered

- **Derive branch from `base_url` heuristic**: rejected. `localhost`
  detection breaks for WSL2 Windows-host bridging, custom local proxies,
  and self-hosted Ollama-cloud setups. Explicit operator-overridable field
  wins.
- **Two separate doctor return shapes**: rejected. Forces every consumer
  (workspace picker, CLI, traces, audits) to branch on the shape; doubles
  the surface area to redact.
- **Defer the contract to v1.0**: rejected. v0.40 ships before v1.0 and
  has already been planned to reuse the doctor pattern. Pinning the
  contract now prevents drift.
- **Make the doctor a private helper, not a registered action**: rejected.
  Operator confidence in setup depends on traces and audits; that requires
  the doctor to enter through `Actions.Runner.run/3` like every other
  effectful call.

## References

- `docs/plans/v0.39-plan.md` — v0.39 First-Run Onboarding And Provider
  Control.
- `docs/plans/v0.39-request-flow.md` — v0.39 request flow and security
  evals.
- `docs/plans/v0.40-plan.md` — v0.40 MCP Client Integration (downstream
  doctor consumer).
- `docs/plans/v0.47-plan.md` — v0.47 Voice Modality (downstream doctor
  consumer).
- `docs/plans/v0.48-plan.md` — v0.48 Vision And Image Generation
  (downstream doctor consumer).
- ADR 0004 — Domain Settings Engine.
- ADR 0011 — Confirmed External Capability Adapters.
- ADR 0046 — Settings Schema Migration Policy (covers `endpoint_kind`
  field evolution).
