# ADR 0088: Model Catalog, Chooser, And Fallback/Degradation Policy

## Status

Accepted (2026-07-26; M4 proved chooser writes through Settings Central and
M5 proved the fallback policy's no-silent-egress denial row). Consumed again by v1.8
(per-role model profiles read the catalog; adaptive suggestions propose
catalog entries).

v1.3 M9.b.3 amendment (2026-07-31): the catalog adds the qualified
`direct_answer_local` / `qwen2.5:7b` local task row without changing the curated
first row (`local` / `llama3.2:3b`). DirectAnswer's non-empty task list is
closed and order-authoritative; that task-specific rule supersedes the generic
implicit-primary selection wording below.

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

The v1.3 DirectAnswer row records the official Ollama `qwen2.5:7b` tag, its
4.7 GB catalog size, 16 GB recommended floor, Apache-2.0 upstream license, and
the `direct_answer` purpose. It is a catalog/profile default, not a bundled
weight. Ollama owns the external download; the Allbert artifact license
inventory covers shipped bytes and therefore does not inventory Qwen weights.

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
- DirectAnswer selection dispatches the registered
  `set_direct_answer_model_profile` action. It validates the canonical
  text-generation capability policy (including pre-capability text-profile
  compatibility), moves the selected profile to the task head without losing
  or duplicating the existing fallback tail, enables that provider, leaves the
  global primary unchanged, and reconciles disclosure;
- the intentionally broad `set_active_model_profile` action moves the same
  profile to both global primary and DirectAnswer head while preserving the
  tail. All writes use Settings Central and are audited. No chooser-private
  state exists.

### 3. Fallback policy — two distinct mechanisms, one rule about egress

**(a) Selection-time ordering (always on).** Choosing which configured
profile serves a task — at first-run detection (ADR 0087) and at
turn-time resolution — uses the existing `candidates_for/2` ranked-list
shape, extended to text generation. An explicitly selected primary remains
first; otherwise ordering is strict local-first, and the remaining chain is
local-first. This
mechanism only ever selects among providers the operator configured, so it
introduces no egress and needs no opt-in.

DirectAnswer is the explicit task-specific exception to generic implicit-
primary completion. Its non-empty task list is already the complete chain and
is walked in authored order without local reordering or a global-primary
append. An empty DirectAnswer list alone uses the compatibility primary. This
keeps a selected local model from silently becoming hosted, and also keeps an
explicitly selected hosted DirectAnswer head from being silently displaced;
the existing pre-egress disclosure still applies.

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
- **One bounded disclosure set:** when a hosted primary or callable hosted
  fallback exists, the pre-egress marker covers the ordered primary plus at
  most one callable fallback. Any provider/profile/class/order change
  invalidates it. A provider call is admitted only when that exact current set
  was acknowledged on its local control surface or, for a non-presenting
  channel, on a local operator-control surface in the same Allbert Home. One
  route acknowledgement cannot oscillate into authority for another.
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

- First-run, repair, profile-switching, and (in v1.8) adaptive model
  suggestions all draw from one catalog with one doctor-verified status
  model, instead of three partial surfaces and typed model tags.
- Text chat gains the same ranked-candidate resilience image/voice already
  have, but behind an explicit opt-in with an explicit local→hosted gate —
  the failure mode "my local model died so Allbert quietly started paying a
  hosted provider" cannot occur.
- The chain reuses `model_preferences.tasks.*`; operators who never touch
  fallback see zero behavior change.
- v1.8's per-role profiles formalize role→profile mappings against this
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
  connectivity release (v1.7 after the 2026-08-06 resequencing) — this catalog
  lists them when they exist but does not implement their auth.
- Per-role (fast/capable/thinking) profile *schema* is v1.3.2 scope (ADR
  0090's plan), not this ADR; this ADR only guarantees the catalog they
  will read.
