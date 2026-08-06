# ADR 0090: Adaptive Usage Profiling And Confirmed Customization

## Status

Proposed (v1.4 planning, 2026-07-24). Binding on v1.4 M1–M6
(`docs/plans/v1.4-plan.md`); flips Accepted at the v1.4 milestone that
proves the full loop — usage signals → distill/suggest → one-click
**confirmed** customization → applied with audit → effectiveness measured —
together with the confirm-required and allowlist denial rows.

This ADR **amends the ADR 0045 boundary deliberately**: ADR 0045 excludes
settings changes from suggestion scope entirely; v1.4 keeps suggestions
inert but adds the one sanctioned application path — a
confirmation-required registered action over an allowlisted key set. The
ADR 0084 amendment of the same date adds the `:suggestion` notification
kind this ADR's delivery stage uses.

Related: ADR 0045 (operator-supervised self-improvement — the trust tier
this extends), ADR 0089 (long-term user memory — the operator-facing
sibling; same episodic sources, same propose/review grammar), ADR 0084
(+ v1.4 amendment — proactive suggestion delivery), ADR 0088 (model
catalog — per-role profiles read it), ADR 0072 (recommended profiles per
purpose), ADR 0061 (router model tiers), ADR 0008 (durable
confirmations), ADR 0031/0006 (Settings/Security Central), ADR 0080/0074
(workspace shell + design system — the mobile-stage-1 rider renders
within them; no authority content).

## Context

What exists (verified 2026-07-24, anchors in the v1.4 plan):

- **The v0.47 pipeline is alive but passive**: `discover_patterns`
  (read-only action) → `SelfImprovement.Discovery`/`TraceIndex` (four
  fixed pattern types) → inert suggestions
  (`tool_discovery_suggestions`, statuses
  `pending|accepted|dismissed|expired`) + draft artifacts → six
  confirmation-gated `promote_*_draft` actions. Nothing schedules it; the
  web panel renders self-improvement suggestions as display-only cards
  with no accept handler; the `dismissed` status has no writer; two
  promote actions are missing from the approve-resume list (a
  bug-shaped hole v1.4 fixes).
- **Usage signals are rich but not queryable**: intent decisions exist
  only inside markdown traces (opt-in via `runtime.trace_default`) and
  per-turn `action_log` JSON blobs on assistant messages; there is no
  decisions store. Durable structured sources: `conversation_messages`
  (+`action_log`), `objective_events`, `scheduled_job_runs`,
  privileged-subsystem markdown audits.
- **The settings-write trap**: `permissions.settings_write` defaults
  `:allowed` and the generic settings actions are
  `confirmation: :not_required` — "one-click confirmed customization"
  is NOT automatic; without a deliberate floor it would be one-click
  *silent* customization. The precedent for forcing confirmation by
  action name is the safety-floor clause pinning `apply_persona_profile`.
- **Per-role model profiles have no schema**: `fast/capable/thinking`
  exist as catalog JSON and codegen aliases, not Settings keys; model
  selection is scattered across router/decomposer/coding/direct-answer
  profile keys (ADR 0061/0072 substrate); ADR 0088 supplies the catalog.
- **Proactive delivery has one boundary**: `Channels.Notify` with kinds
  `[:status, :completion, :confirmation_request, :consent_offer]`,
  defaults-OFF settings, ledger, throttle, exact-origin binding — the
  `:suggestion` kind is an additive extension of that boundary, never a
  second spine.

The flagship goal (backlog + roadmap): system usage memory +
distill/suggest jobs + one-click confirmed customizations + effectiveness
feedback, with per-role model profiles and proactive notifications riding.

## Decision

### 1. An additive, local, redacted usage-signal store

v1.4 adds a bounded usage-event store (SQLite, additive table) written at
turn close: intent decision outcome (kind, action name, confidence band,
fallback/steering class), action outcome class, model profile used,
surface/channel, timing bands — **never message bodies, never prompt
text, never secrets** (schema-level redaction proven by an eval row).
Rationale: traces are opt-in and markdown-parsed; profiling needs a
deterministic, always-on, cheap signal. Existing sources (conversations'
`action_log`, objectives, jobs runs, traces where enabled) remain joined
raw material. Retention is bounded by a cap + age setting, prunable
through existing operator surfaces.

### 2. Distill/suggest: a managed job producing inert, evidenced cards

- A periodic managed job (the ReviewCadence pattern;
  `profiling.distill.*` settings; kill switch; explicit activation) runs
  a registered distill action: reads the usage store + joined sources,
  computes profile aggregates, and emits **suggestion cards** through the
  existing suggestion machinery (additive suggestion types) — each card
  carries its evidence (the aggregate + sample references), a proposed
  concrete change, and a predicted benefit statement.
- Suggestion classes in scope: settings customizations over the
  allowlist (§3), per-role model profile remaps (§4), and the existing
  v0.47 workflow/skill/memory draft kinds (unchanged authority).
- Suggestions remain **inert** (ADR 0045 posture): rendering, accepting,
  or dismissing a card changes nothing by itself. The dead `dismissed`
  status gains its writer; the approve-resume gap for the two missing
  promote actions is fixed.
- Distill is zero-egress; model assist, if any, is the configured local
  model under the same bounds as ADR 0089's LD-R5 posture.

### 3. The one sanctioned application path: confirmed customization

- New registered action `apply_suggested_customization`
  (`confirmation: :required`) **plus** an action-name-scoped Security
  safety-floor clause (the `apply_persona_profile` precedent) so the
  requirement cannot drift with a contract edit.
- The action accepts only a suggestion id; it re-reads the card, checks
  the proposed key against the **customization allowlist** — a shipped,
  reviewed subset of safe-write keys (model roles, cadence/level tunables,
  UI/verbosity preferences; **never** permissions, security policy,
  egress, provider credentials, or fallback egress gates) — renders the
  exact before→after diff into the confirmation, and applies through
  `Settings.put` with audit only after approval.
- One click on a card creates the durable confirmation; the existing
  confirmation surfaces (web, typed command, buttons) resolve it. Free
  text never approves (standing rule). Rejection marks the suggestion
  dismissed with provenance.

**Amendment, 2026-08-05 (operator decision) — prompt-rule variants are a
third delta kind on this same path.** The application mechanism is unchanged:
an allowlisted key, an exact before→after diff, `Settings.put` after approval,
full audit. What changes is the allowlisted set, which now admits
`prompt_rules.<catalog>.<rule_id>.variant`.

Two measured facts bound it, and both were verified in the tree before the
amendment was accepted:

- **Almost no shipped rule is presentational.** Of the nine
  `DirectAnswer.Policy` rules exactly one — `useful_factual_and_brief` — is
  about style. The rest are authority, truthfulness, or the prompt-injection
  boundary; `supplied_text_is_data` *is* that boundary. So eligibility is an
  explicit per-rule `tunable?` field defaulting to **false**, reviewed like the
  settings allowlist, and a non-tunable rule id is refused before a
  confirmation exists.
- **Rule catalogs are digest-bound.** `Worker.QualityPolicy.rule_catalog_digest/1`
  records the catalog in quality receipts. Tuning therefore selects among
  **shipped, reviewed variants** rather than authoring text: the catalog stays a
  closed set, the resolved digest stays meaningful, and a variant change is
  visible in the receipt instead of hidden.

Free text never enters the system role. This is not the parked System Memory
Distillation route — nothing is learned or trained; a variant is chosen from a
set that shipped in the release.

### 4. Per-role model profiles (fast / capable / thinking)

- New additive Settings fragments formalize roles:
  `model_roles.<role>.profile` (initial roles: `fast`, `capable`,
  `thinking`), resolved through the existing `Settings.Models` machinery
  as aliases the per-purpose keys may reference — the scattered
  router/decomposer/coding/direct-answer profile keys keep working
  unchanged; roles are a naming layer over the ADR 0088 catalog, not a
  parallel resolver.
- The chooser renders roles; profiling may propose role remaps ("your
  ranking turns are slow — map `fast` to X") strictly through §3.
- Legacy `intent.*model_profile` aliases are untouched (additive-only
  rule; removal stays with the migration-runner train).

### 5. Effectiveness feedback

Applied customizations link suggestion id → confirmation id → settings
audit entry. The next distill run measures the before/after usage deltas
for the touched dimension (e.g. turn-time band, fallback rate,
steering-correction rate) and writes the outcome onto the suggestion
record; the panel shows it ("applied 12 days ago — decide p50 −18%").
Reverts are one click through the same confirmed path. No automatic
rollback: measurement informs the operator, it never acts.

### 6. Proactive suggestion delivery (ADR 0084 amendment)

Delivery of "a suggestion is ready" beyond the workspace rides the
amended `Channels.Notify` boundary as kind `:suggestion`: per-channel
opt-in key separate from status/completion, **default OFF**, quiet-hours
window and a per-class rate limit (additive keys), the same ledger /
throttle / exact-origin / redaction machinery, always a new message. The
backlog's proactive-notifications policy items (per-class opt-in,
quiet hours, rate limit, audit, revocation) land here; broader proactive
classes (meeting starts, disconnects) remain out of scope.

### 7. Mobile-ready web, stage 1 (rider — no authority content)

v1.4 carries the mobile-ready web stage 1 as non-flagship scope
(operator-slotted 2026-07-24): breakpoint token roles in the design
system (folding in the parked Dynamic Mobile Breakpoints entry),
phone-form-factor usability for the primary surfaces, within ADR
0074/0080. Stages 2–4 (API surface, remote auth, native shell) are
explicitly out. Recorded here only so the ADR set names the release's
whole surface; this section grants nothing and constrains only the plan.

## Consequences

- Allbert closes its self-improvement loop: it observes its own usage,
  proposes concrete improvements with evidence, applies exactly what the
  operator confirms, and reports whether it worked — while the ADR 0045
  inert-suggestion posture and the confirmation spine hold.
- The settings-write trap is closed structurally (floor + allowlist),
  not by convention.
- Role-based model tuning becomes a first-class, suggestible surface on
  top of the 1.2 catalog rather than folklore across scattered keys.
- One notification spine continues to carry every autonomous send;
  quiet hours and per-class rate limits harden it for all kinds.
- v1.3 and v1.4 share the propose/review grammar deliberately: memory
  proposals → review; usage suggestions → confirm. Operators learn one
  model.

## Non-goals and guardrails

- **No autonomous settings changes, ever** — no suggestion applies
  without an approved durable confirmation; the allowlist excludes
  permissions/security/egress/credentials/fallback gates categorically.
- **No egress** in profiling; local model only for any assist.
- **No message bodies or secrets in the usage store** (schema-level,
  eval-bound).
- **No learned/trained profile models** (System Memory Distillation
  stays parked); distill is deterministic aggregation + bounded local
  assist.
- **No new notification spine**; `:suggestion` is a kind on ADR 0084's
  boundary, default OFF.
- **Additive-only** (operator-locked 1.2–1.4): the usage store, roles
  fragments, suggestion types, and notify keys are additive; legacy
  aliases untouched.
- Mobile stages 2–4 and OAuth hosted providers stay on their own
  tracks.

## Validation

Gate-bound behavioral rows (v1.4 plan §G): suggestion-inert,
confirm-required (floor-pinned), allowlist denial, zero-egress distill,
usage-store redaction, suggestion-notify default-off, quiet-hours
suppression, role-remap write-path. Accepted flip requires the full loop
proven end to end with a measured effectiveness record in Build Progress.
