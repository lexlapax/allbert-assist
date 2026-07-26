# ADR 0088: Model Catalog, Chooser, And Fallback/Degradation Policy

## Status

Proposed (v1.2 planning, 2026-07-24). Binding on the v1.2 catalog/chooser and
fallback milestones (`docs/plans/v1.2-plan.md`); flips Accepted at the v1.2
milestone that proves the chooser writes through Settings Central and the
fallback policy's no-silent-egress denial row. Consumed again by v1.4
(per-role model profiles read the catalog; adaptive suggestions propose
catalog entries).

Related: ADR 0087 (zero-click detection-based enablement — the detect states
select *from* what this ADR catalogs and are the first fallback consumer),
ADR 0078 (First-Model Path — curated-model criteria; no managed hosted
default), ADR 0072 (recommended model profiles per purpose — the advisory
matrix and `model_doctor` this ADR gives a browsable, actionable surface),
ADR 0061 (router model tiers + local embedding), ADR 0051 (provider
capability preferences — `model_preferences.*` stays the authority shape),
ADR 0047 (provider doctor envelope), ADR 0031 (Settings Central), ADR 0006
(Security Central).

## Context

Operators configure models by typing profile ids and model tags. There is no
browsable catalog: the ModelsPanel lists configured `model_profiles` /
`provider_profiles` with doctor rows and repair buttons — inventory and
repair, not choice. The curated default is a single constant
(`Ollama.curated_model/0`, `llama3.2:3b`); ADR 0072's recommendation matrix
is an operator doc plus a read-only `model_doctor` action. v0.64 explicitly
deferred a chooser ("browse available models with size/capability metadata
instead of typing a model id", `future-features.md:922-932`).

Fallback is equally partial. `Settings.Models.candidates_for/2` yields a
ranked candidate list and image/voice actions consume it, but the text chat
path resolves exactly one profile (`Models.for(:direct_answer, …)`) and any
provider error collapses to the static "model unavailable" fallback — no
retry, no degradation, no policy. The parked backlog entry
(`future-features.md:864-884`) names what a real policy needs: explicit
operator opt-in, per-provider failure detection, chain configuration
(primary → secondary → local), audit of fallback events, and prevention of
silent expensive failovers. ADR 0087's detect-state matrix additionally
needs *selection-time* ordering (local before hosted) — a different thing
from *runtime* failover, and the two must not be conflated.

One data-source fact matters: `llm_db` already ships as a transitive
dependency of ReqLLM 1.17.1 with zero direct usage. It may be able to supply
hosted-model metadata without a new dependency; whether its data quality,
size, and license posture fit is a build-time verification, not a
planning-time assumption.

## Decision

### 1. One read-only catalog, four merged sources

`AllbertAssist.Models.Catalog` is a read-only service producing a unified,
redacted model inventory:

1. **Curated local entries** — a shipped, versioned catalog file (criteria
   per ADR 0078: open-weight, prosumer hardware, modest download; each entry
   carries size, capability tags, hardware floor, and the ADR 0072 purposes
   it suits). The curated single default remains the first row.
2. **Live local runtime inventory** — pulled models from the local runtime
   (Ollama `/api/tags` through the existing bounded loopback client).
3. **Configured provider profiles** — the operator's `model_profiles.*` /
   `providers.*`, annotated with doctor status (`model_doctor` reuse:
   recommended vs configured vs status).
4. **Hosted metadata (conditional)** — `llm_db` IF the v1.2 build's
   verification confirms fitness (accuracy, footprint, license); otherwise
   the curated file carries a small hosted section. The plan records the
   verification either way; no new dependency is added for this.

The catalog is exposed only as registered **read-only** actions
(`list_model_catalog`, plus `model_doctor` unchanged), so web, TUI, CLI, and
onboarding all render the same rows under surface policy. The catalog never
performs hosted egress to build itself: hosted entries are static metadata;
live probing stays local/configured-endpoint-only per ADR 0087.

The v1.2 M0/M4 cross-platform bakeoff treats `llama3.2:3b` as the control and
tests Qwen 3 4B instruct/non-thinking, `qwen3.5:4b` as the direct successor,
and `qwen3.5:9b` as a higher-floor quality challenger. First-run trials force
non-thinking behavior; thinking variants may be cataloged but are not
zero-click defaults. A default or tier changes only when the precommitted
Allbert quality/tool-conformance and latency rule passes. The current 8 GB
floor may rise when the measured gain justifies reduced reach and the operator
accepts that tradeoff. A higher-floor winner must either remain a prosumer
recommendation beside a lower-floor consumer default or ship with a proven
`below_floor` BYOK/repair path; no machine is silently treated as ready. Exact
Ollama tag/digest, license, download, TTFT, throughput, peak RSS, malformed
tool/JSON rate, multilingual behavior, and supported macOS/Linux/WSL2 rows are
recorded across 8/16/32 GB cohorts.

### 2. The chooser writes through the spine, never around it

The chooser UX (web ModelsPanel upgrade, TUI/CLI equivalents, and the
onboarding `model_path` step re-pointed at it) is render-and-dispatch only:

- browse by ADR 0072 purpose with size/capability/floor metadata and doctor
  status inline;
- selecting a local model that is not pulled offers the existing
  confirmation-gated one-click pull (never a silent download);
- selection writes the existing keys (`model_preferences.*`,
  `model_profiles.*`, enablement flags) through the existing registered
  settings actions — Settings Central remains the sole authority and every
  write is audited. No chooser-private state exists.

### 3. Fallback policy — two distinct mechanisms, one rule about egress

**(a) Selection-time ordering (always on).** Choosing which configured
profile serves a task — at first-run detection (ADR 0087) and at
turn-time resolution — uses the existing `candidates_for/2` ranked-list
shape, extended to text generation. Ordering is strict local-first; this
mechanism only ever selects among providers the operator configured, so it
introduces no egress and needs no opt-in.

**(b) Runtime failover (default OFF, explicit opt-in).** Mid-turn or
mid-session automatic failover when the resolved provider fails:

- `models.fallback.enabled` — default `false`. Absent or `false`, behavior
  is exactly today's: one resolved profile, honest static fallback text on
  failure.
- **Chain** — the per-task candidate list IS the chain (primary → secondary
  → local), operator-editable through the existing
  `model_preferences.tasks.*` list shape; no parallel chain schema.
- **Failure classification per provider** — provider adapters normalize
  concrete ReqLLM/provider/streaming outcomes into typed definitive,
  ambiguous, or partial results; the executor never parses exception strings.
  Unknown outcomes are partial and never retried. Definitive failures
  (connection refused, auth rejected, model-not-found) advance the chain;
  ambiguous/timeout failures advance at most once; a provider that may have
  partially answered is never silently retried elsewhere (the v1.1
  uncertain-delivery posture applied to inference).
- **The egress line:** a failover step that would cross **local → hosted**
  requires, in addition to the global opt-in, a per-chain acknowledgement
  (`models.fallback.allow_local_to_hosted`, default `false`) — silent
  paid/egress failover is structurally impossible, not just discouraged.
- **No silent expensive failovers:** at most one failover per turn; the
  reply metadata names the profile that actually answered whenever it is
  not the primary; every fallback event writes a trace record and an audit
  row (which profile failed, classification, which answered).
- Degradation floor: when the whole chain fails, the deterministic fallback
  text names the failed chain honestly — never a fabricated answer.

### 4. Settings surface (additive)

New keys ship as additive Settings Central fragments with clamps and
defaults recorded in the v1.2 plan: `models.fallback.enabled` (false),
`models.fallback.allow_local_to_hosted` (false),
`models.fallback.max_failovers_per_turn` (1, clamp 1..2), plus the catalog
file version key. Existing `model_preferences.*` / `model_profiles.*` /
`first_model.*` keys are unchanged; nothing here requires a non-additive
migration.

## Consequences

- First-run, repair, profile-switching, and (in v1.4) adaptive model
  suggestions all draw from one catalog with one doctor-verified status
  model, instead of three partial surfaces and typed model tags.
- Text chat gains the same ranked-candidate resilience image/voice already
  have, but behind an explicit opt-in with an explicit local→hosted gate —
  the failure mode "my local model died so Allbert quietly started paying a
  hosted provider" cannot occur.
- The chain reuses `model_preferences.tasks.*`; operators who never touch
  fallback see zero behavior change.
- v1.4's per-role profiles formalize role→profile mappings against this
  catalog rather than inventing a second model-metadata source.

## Non-goals and guardrails

- **No managed hosted default** (ADR 0078 stands); the catalog recommends,
  Settings Central decides, the operator owns egress.
- **No auto-pull, no auto-provisioning** — catalog rows describe; pulls stay
  confirmation-gated one-click (ADR 0087 guardrail restated).
- **No new authority**: catalog reads are `permission: :read_only`
  registered actions; chooser writes ride existing settings actions and
  safe-write keys; Security Central posture unchanged.
- OAuth-authenticated hosted providers (subscription plans) remain on the
  1.4/1.5 enabler train — this catalog lists them when they exist but does
  not implement their auth.
- Per-role (fast/capable/thinking) profile *schema* is v1.4 scope (ADR
  0090's plan), not this ADR; this ADR only guarantees the catalog they
  will read.
