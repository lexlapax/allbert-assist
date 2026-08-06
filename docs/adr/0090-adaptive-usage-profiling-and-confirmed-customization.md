# ADR 0090: Adaptive Usage Profiling And Confirmed Customization

## Status

Proposed (v1.8 planning, 2026-07-24; implementation-readiness revision
2026-08-06). Binding on v1.8 S1-S9 and M0.5-M8, including M4.5
(`docs/plans/v1.8-plan.md`). The source-only v1.3.1 predecessor shipped and
closed on 2026-08-05, so its barrier is satisfied; v1.8 M0 still re-verifies
the implementation seams at the accepted predecessor tag before feature work.

This ADR flips Accepted at v1.8 M8, after the whole authority loop is proved:
user-owned minimized usage events -> deterministic distillation -> inert
suggestion -> durable confirmation -> compare-and-set allowlisted write ->
linked audit/recovery record -> descriptive observed outcome -> confirmed
revert. M8 also proves model-role, prompt-variant, notification-enrollment,
quiet-hours, rate-cap, and abuse-case rows. A partial loop or a synthetic
claim about real-world improvement cannot accept the ADR.

This ADR **amends the ADR 0045 boundary deliberately**. ADR 0045 excludes
settings changes from suggestion scope; v1.8 keeps suggestions inert but adds
one sanctioned application path: confirmation-required registered actions over
an exact reviewed allowlist. The ADR 0084 amendment adds the `:suggestion`
notification kind used only to point an enrolled user to inert cards.

Related: ADR 0045 (operator-supervised self-improvement), ADR 0089 (long-term
user memory and user ownership), ADR 0084 (+ v1.8 amendment — proactive
suggestion delivery), ADR 0088 (model catalog), ADR 0072 (recommended profiles
per purpose), ADR 0061 (router model tiers), ADR 0008 (durable
confirmations), ADR 0031/0006 (Settings/Security Central), and ADR 0080/0074
(workspace shell and design system).

## Context

The source-only v1.3.1 point release is complete. It supplied the answering-head
qualification evidence and corrective hardening that v1.8 inherits; v1.8 is
the first packaged carrier of those changes. The implementation seams below
were audited during planning and are re-checked by M0 rather than treated as
permanent line-number facts.

- **The v0.47 pipeline is alive but passive:** `discover_patterns` ->
  `SelfImprovement.Discovery`/`TraceIndex` -> inert
  `tool_discovery_suggestions` and draft artifacts -> confirmation-gated
  `promote_*_draft` actions. It does not supply the lifecycle needed for a
  settings customization. Its existing types and authority remain unchanged;
  v1.8 fixes the missing dismissed writer and approve-resume coverage without
  overloading its draft-oriented records.
- **Usage signals are rich but not queryable:** intent decisions live in
  opt-in markdown traces and per-turn `action_log` JSON. Structured sources
  include conversations, objectives, and managed-job runs, but no bounded,
  content-minimized decision store exists.
- **The settings-write trap remains:** generic Settings actions are not a safe
  substitute for confirmed customization. A card must not turn
  `permissions.settings_write=:allowed` into silent authority. Both the action
  contract and Security safety floor must force confirmation by action name.
- **A customization spans storage boundaries:** suggestions and operations are
  SQLite records, Settings are Home-owned YAML, and the audit is append-only
  markdown. A database transaction cannot make all three atomic. The design
  therefore needs a durable operation state and explicit recovery rather than
  claiming impossible all-or-nothing behavior.
- **Per-role profiles and prompt variants do not yet have a uniform resolver:**
  purpose-specific model keys remain authoritative; prompt rules have multiple
  call sites and quality receipts already bind catalog digests.
- **Proactive delivery has one boundary:** `Channels.Notify` already owns
  defaults-OFF grants, exact-origin re-authorization, redaction, throttling,
  durable delivery state, and uncertain-send handling. `:suggestion` is an
  additive kind on that boundary, never another transport spine.

The flagship is local usage memory plus deterministic distill/suggest,
operator-confirmed customization, descriptive follow-up, per-role aliases, and
default-off suggestion delivery. Mobile-ready web stage 1 is a presentation
rider and grants no authority.

## Decision

### 1. User-owned, local, minimized usage events

v1.8 adds a dedicated additive SQLite usage-event store. Collection is local,
bounded, user-scoped, and fail-open with respect to the response the user is
waiting for. Its data-minimization and storage-limitation posture follows the
[NIST Privacy Framework](https://www.nist.gov/privacy-framework) and the
principles in
[GDPR Article 5](https://eur-lex.europa.eu/legal-content/EN/TXT/?uri=CELEX%3A32016R0679)
even when an installation is outside GDPR scope.

The Settings contract is frozen as follows:

- `profiling.enabled=true` is the master analysis switch. `false` stops new
  capture and every scheduled or on-demand distillation. It does not prevent
  status inspection, retention pruning, or confirmed clearing.
- `profiling.usage_events.enabled=true` is the capture-only switch. `false`
  stops new event writes while leaving existing retained data available to an
  explicitly enabled distill.
- `profiling.usage_events.max_rows=10_000`, accepted range
  `1_000..1_000_000`, is enforced per user.
- `profiling.usage_events.max_age_days=90`, accepted range `7..365`, is
  enforced per user.
- `profiling.distill.enabled=false` controls the managed cadence, whose default
  is `weekly`. A user may invoke on-demand distillation while
  `profiling.enabled=true` even when the cadence is disabled.

Exactly one event is attempted for each user-owned terminal response signal.
Terminal outcomes are `completed`, `denied`, `failed`, `cancelled`, and
`assistant_persistence_failed`. Background jobs do not mint turn events. The
unique `response_signal_id` makes the writer idempotent across retries.

The typed event contains only:

- local user, thread, message, response-signal, and supported correlation IDs;
- terminal outcome plus registry-bounded intent, action, and action-outcome
  classes;
- confidence band, fallback class, and steering-correction class;
- resolved concrete model profile and its provider/endpoint/locality class;
- surface/channel;
- non-negative schema-clamped `duration_ms` and a prompt-length band; and
- a versioned HMAC-SHA-256 fingerprint of normalized prompt text, keyed by a
  random per-Home key that is never exported.

Fields that do not apply to a terminal path are `nil`, never a free-text
sentinel.

The fingerprint exists only to group repeated prompts within one Home. It is
not a cross-install identity. Storage/query ownership prevents joins across
users, and different Home keys prevent joins across Homes. Normalization and
its version are deterministic and digest-bound. Raw prompt,
message, response, trace, action-log, objective, or job text; snippets;
arbitrary model prose; secret material; and free-text error strings are
prohibited from the event schema and from derived evidence.

Distillation may read usage events and user-scoped typed objective/job outcomes.
It may use identifiers to fetch registry-bounded classes, but it may not ingest
conversation, trace, objective, or job bodies. v1.8 distillation is deterministic
aggregation with zero provider or model egress and no model-assisted fallback.

Age and row-cap pruning runs per user at store startup and after inserts in
bounded database transactions. An event-write or prune failure never changes
the response outcome; it emits a content-free diagnostic and sets a redacted
profiling-health state visible through operator surfaces.

The first eligible use displays a non-blocking disclosure with inspect, pause,
and clear affordances. Confirmed clear removes that user's usage events,
profiling suggestions, and observed outcomes. It preserves Settings,
customization-operation records, confirmations, and security/audit evidence.
Raw Home backups may contain retained profiling rows. Portable export contains
only redacted schema/count summaries, never event rows or the HMAC key. Uninstall
preserves Home; only an explicit confirmed purge removes retained Home data.

### 2. Deterministic distillation and dedicated inert cards

A managed ReviewCadence-style job and an on-demand registered action aggregate
eligible rows and create user-owned profiling suggestions. The managed job is
default OFF under `profiling.distill.enabled`; both paths honor the master
switch and perform zero egress.

The managed-job reconciliation is explicit: `enabled=false` leaves the reserved
per-user job paused with no effective due time; `enabled=true` reconciles and
resumes its schedule using `profiling.distill.cadence`; cadence changes while
disabled update the reserved schedule but do not resume it. On-demand distill
invokes the same registered action without changing managed-job state.

Profiling uses dedicated suggestion, customization-operation, and outcome
records behind the shared Suggestions surface. It does not overload
`tool_discovery_suggestions`, whose draft workflow remains governed by ADR
0045. A profiling card has one of these states:

`open | confirmation_pending | applied | dismissed | expired | stale | reverted`

Every card binds all of the following before it is rendered:

- local user, stable card id, revision, and card digest;
- target key, expected current value, and proposed value;
- evidence/metric version, bounded sample window and sample references;
- customization-allowlist digest and, for prompt rules, catalog digest;
- expiry timestamp and stable dedupe key.

Card text is deterministic and derived from typed aggregates. A card is inert:
rendering, opening, accepting, dismissing, or notifying it does not write a
setting. Terminal cards cannot be silently reopened. A dismissed or expired
dedupe-equivalent proposal observes a 30-day cooldown unless the current target
value changes, in which case the new expected-before value produces a new
proposal identity. Metric version 1 reads the most recent 10–50 eligible events
from at most 14 days; fewer than 10 or an ambiguous aggregate emits no card. A
card expires 14 days after creation unless it reaches another terminal state
first.

### 3. Confirmed compare-and-set customization and recovery

The only profiling write path is through registered
`apply_suggested_customization` and `revert_suggested_customization` actions.
Both declare `confirmation: :required` and both action names are pinned by the
Security safety floor so a later contract edit cannot weaken them. A surface
may create or resolve the durable confirmation, but it may not write Settings
directly. Free text never approves.

The exact v1.8 customization allowlist is:

- `operator.communication_style`
- `operator.handoff_detail`
- `channels.<registered-id>.response_style`
- `model_roles.fast.profile`
- `model_roles.capable.profile`
- `model_roles.thinking.profile`
- `prompt_rules.direct_answer.useful_factual_and_brief.variant`

Cadence, diagnostic, accessibility, resource-limit, permission, security,
credential, provider-egress, and fallback-policy keys are categorically
excluded. A wildcard `prompt_rules.*` key is not allowed. The shipped allowlist
is closed and digest-bound; plugin, skill, model, YAML, descriptor, or card
metadata cannot extend it.

An apply confirmation binds user, suggestion id/revision/digest, target key,
expected-before value, proposed-after value, target version, allowlist digest,
and any rule-catalog digest. On resume, the action re-reads and revalidates all
bindings inside the same Settings lock used for its compare-and-set write. A
stale card or changed current value writes nothing, marks the card `stale`, and
requires a newly distilled card and confirmation. A confirmation id may produce
at most one application operation.

A revert confirmation is equally bound. It writes the recorded before value
only when the current setting still equals that operation's applied value; an
intervening operator edit makes the revert stale and writes nothing. Denial or
dismissal changes card state with provenance but never Settings.

Customization operations have these durable states:

`prepared | applied | recovery_required | reverted | failed`

`prepared` records intent without claiming a result; `applied` means CAS,
audit, and SQLite linkage agree; `recovery_required` means Settings may have
changed while linkage is incomplete or ambiguous; `reverted` means the
separately confirmed CAS restored the prior value; and `failed` is terminal
only when Settings is proven unchanged.

SQLite-local card, operation, and outcome changes use one database transaction
(the intended boundary of
[`Ecto.Multi`](https://hexdocs.pm/ecto/Ecto.Multi.html)). The operation ledger
coordinates the non-atomic SQLite -> Settings YAML -> markdown-audit sequence.
The Settings audit entry carries stable audit-entry, operation, suggestion, and
confirmation IDs plus redacted before/after values. If Settings commits but
audit or SQLite linkage fails, the action returns `recovery_required`; it never
reports success and never performs an unsafe blind rollback. Startup and the
next operation reconcile from the durable operation id and current Settings
value idempotently. An unresolved mismatch is surfaced for operator repair and
cannot be treated as application authority.

### 4. Per-role model profiles

**Split across two releases by the 2026-08-06 resequencing.** The *resolution*
half of this decision — fragments, nil defaults, alias expansion, diagnostic
skip, and concrete-profile-only values — ships in **v1.3.2**, because Knowledge
Central hard-depends on `model_roles.capable` and hosted-provider OAuth wants a
consumer, and neither should wait behind a profiling flagship. The *remap* half
— a profiling suggestion proposing a role change, its allowlist entry, and the
same-provider/endpoint/locality guard — ships in **v1.8** with the rest of
confirmed customization. The split follows the authority line: resolution is
additive and grants nothing, while proposing a remap is part of the one
sanctioned application path and must not ship in halves.

The only role references are `role:fast`, `role:capable`, and
`role:thinking`. Their Settings fragments are
`model_roles.<role>.profile`, and all three default to `nil`. An unconfigured
role is skipped with a content-free diagnostic; the existing concrete
purpose-profile chain then continues unchanged.

A role value may name one configured concrete ADR 0088 profile only. It may not
name another role, which prevents self-reference and cycles. Resolution expands
the role before ordinary profile validation and records both the role and the
resolved concrete profile in usage evidence. Existing purpose keys and legacy
`intent.*model_profile` write aliases remain additive and unchanged.

A profiling suggestion may remap a role only to a configured profile with the
same provider, endpoint, and locality tuple as the current concrete profile.
Missing, disabled, or cross-tuple targets are denied before confirmation. An
operator may still make a broader explicit change through the ordinary model
Settings path and its existing authority; profiling does not gain that power.

### 5. Prompt-rule variants

Prompt tuning is variant selection, never authored or learned system text. A
uniform immutable rule spec/snapshot carries catalog, purpose, catalog version,
rule id, variant id, resolved text, and digest. Each of the six
`PromptEnvelope` callers resolves through this contract; the separately
replayed `Worker.QualityPolicy` stores and reuses the same immutable snapshot.
Durable jobs and receipts replay their stored snapshot rather than current
Settings.

Every shipped rule declares `tunable?`, default `false`. v1.8 ships exactly one
tunable rule in the direct-answer catalog:

- `useful_factual_and_brief/default` preserves the pre-v1.8 text byte for byte.
- `useful_factual_and_brief/balanced_detail` resolves to: “Keep the answer
  useful, factual, and direct. Include enough detail to answer the request
  completely, without unrelated material.”

Every other rule is non-tunable. A non-tunable rule, unknown variant, or catalog
digest mismatch is refused before confirmation. The resolved catalog digest
changes when the selected variant changes and remains byte-identical when the
default is selected. The sole Settings enum defaults to `default`; non-tunable
rules expose no variant key. Free text never enters a system rule; this is not System
Memory Distillation and trains nothing.

### 6. Descriptive observed outcomes, not effectiveness claims

Applied customizations link suggestion -> confirmation -> operation -> Settings
audit entry -> observed outcome. Outcomes use only these states:

`pending | insufficient_data | confounded | observed_improvement |
observed_regression | no_clear_change`

The engine takes equal-sized matched pre/post samples, each capped at 50 eligible
events, from windows no longer than 14 days. Fewer than 10 eligible events in
either side is `insufficient_data`. A related customization or material
endpoint/surface/profile change inside the comparison is `confounded`. The card
shows window dates, sample counts, medians or rates, metric version, and detected
confounders.

Metric families are fixed:

- communication style, handoff detail, and channel response style use
  steering-correction rate; metric version 1 requires a change of at least five
  percentage points to classify direction, and response-length distribution is
  descriptive only;
- model roles use median duration with failure and fallback rates as
  guardrails; metric version 1 requires at least a ten-percent relative median
  movement, while a failure/fallback worsening of five percentage points makes
  the result `observed_regression`; and
- the prompt variant uses a typed card-level `better | same | worse` rating
  after 10 eligible turns; response length and steering correction remain
  descriptive context.

Movement below the versioned floor is `no_clear_change`; model output cannot
classify the result. These are product classification floors, not statistical
or causal significance claims. Before/after observation
does not establish a counterfactual, so UI, CLI, audit, and release evidence
never say the customization “caused,” “helped,” or “worked.” This follows the
caution in the
[Magenta Book evaluation guidance](https://www.gov.uk/government/publications/the-magenta-book/magenta-book-central-government-guidance-on-evaluation-html).
Synthetic fixtures prove computation and state transitions only; they are never
product-efficacy evidence. Outcomes are advisory and never trigger automatic
application or rollback. Revert remains the confirmed path in §3.

### 7. Proactive suggestion delivery

Suggestion delivery rides the ADR 0084 amendment through a typed notification
subject adapter. It never fabricates an Objective and never grants transport
authority outside `Channels.Notify`.

Delivery requires all of: the existing autonomous-notify authority, the
default-OFF `suggestions_enabled` setting, and an explicit identity-reverified
enrollment binding the local user, registered channel, and exact provider
thread reference/digest. Last activity, model output, card metadata, and free
text are never destinations. Email is excluded in v1.8.

Suggestion quiet hours defer and coalesce rather than suppress. The setting is
an optional start/end local-time window evaluated in `operator.timezone`,
start-inclusive and end-exclusive, including overnight windows. One durable row
per user/channel/thread/window coalesces eligible cards into a deterministic
“N suggestions ready” pointer delivered at the next valid window edge. Timezone
database rules determine daylight-saving transitions; equal start/end is an
invalid window. The default daily cap is
one per local user/channel calendar day; `sending`, `delivered`, and `uncertain`
reservations consume it. Payloads are length-bounded, redacted pointers only,
with no evidence, proposed value, or approval control.

### 8. Mobile-ready web stage 1

Mobile stage 1 is presentation-only scope inside ADR 0074/0080. It includes
320-CSS-pixel reflow/400% zoom, 390x844 portrait, 844x390 landscape, keyboard
order, visible and unobscured focus around sticky regions, accessible names and
status, 200% text resizing, and shared breakpoint/viewport-height contracts.
The AA target-size floor is 24x24 CSS pixels; 44x44 is the preferred enhanced
target, not a blanket AAA claim. These acceptance dimensions follow
[WCAG 2.2](https://www.w3.org/TR/WCAG22/).

Physical-phone acceptance is not part of v1.8; measured Chromium and WebKit
viewport/browser proof is. The operator-owned later stages retain their backlog
meanings: stage 2 responsive information architecture, stage 3 offline-capable
PWA, and stage 4 native shell. Authenticated/configurable non-local access is a
v1.7 concern. This rider grants no application, notification, or network
authority.

## Consequences

- Allbert gains a bounded loop that observes typed local behavior, proposes an
  inert change, applies only an exact confirmed allowlisted delta, and reports a
  descriptive outcome without claiming causality.
- The settings-write trap is closed structurally through action-name floors,
  exact allowlisting, confirmation binding, compare-and-set, and durable
  recovery state.
- Profiling data has explicit ownership, collection, retention, clear, backup,
  export, and uninstall semantics rather than relying on “local” as a privacy
  substitute.
- Role aliases and prompt variants become explicit naming/snapshot layers over
  existing resolvers. Existing concrete profile and rule behavior remains the
  default.
- One notification spine continues to carry every autonomous send. Enrollment,
  deferred quiet hours, coalescing, and the daily cap prevent a Settings toggle
  from becoming an inferred-address or spam grant.
- ADR 0045 discovery suggestions and ADR 0089 memory proposals remain separate
  data models while sharing an operator-facing propose/review grammar.

## Non-goals and guardrails

- No autonomous Settings change or rollback; both apply and revert require an
  approved durable confirmation.
- No wildcard customization keys and no permission, security, credential,
  egress, fallback, cadence, diagnostic, accessibility, or resource-limit
  customization.
- No prompt, response, trace, objective, job, error, or model prose in usage
  events, derived cards, notification payloads, audit evidence, or portable
  export.
- No provider/model egress and no learned or trained profile model in
  distillation.
- No causal product claim from an observed pre/post delta.
- No new notification spine, inferred destination, email suggestion, or
  notification-side approval.
- No change to legacy model aliases, purpose-profile precedence, or untuned
  prompt text.
- No non-local bind or authentication authority and no physical-phone
  acceptance in v1.8.
- All additions are Tier-2/additive; ADR 0090 does not change a frozen Tier-1
  public contract.

## Validation

M8 may flip this ADR Accepted only when the v1.8 gate proves, at minimum:

- user isolation; response-signal idempotency; every terminal outcome; HMAC
  stability and non-recoverability; duration clamping; fail-open capture;
  switch separation; age/row pruning while capture is off; confirmed clear;
  and absence of raw or secret content;
- low-sample abstention; card dedupe/cooldown and every state transition;
  apply/revert safety-floor pins; stale and double-resume denial; explicit
  allowlist denial; expiry; intervening-edit revert denial; and audit-failure
  restart reconciliation through `recovery_required`;
- equal matched windows; pending, insufficient, confounded, improvement,
  regression, and no-clear-change states; bounded arithmetic; typed prompt
  ratings; and non-causal surface copy;
- nil-role fallback, concrete-profile validation, same-tuple remap denial,
  disabled-profile handling, legacy purpose parity, byte-identical untuned
  catalogs, non-tunable/out-of-set denial, snapshot replay, and digest changes
  only for a selected shipped variant;
- explicit enrollment and cross-user denial; suggestion default OFF; overnight
  and DST deferral; concurrent daily-cap reservation; restart recovery;
  uncertain-send no-retry; coalescing; deterministic redaction; email exclusion;
  and proof that notification cannot approve; and
- 320/390/landscape geometry, reflow/zoom, keyboard and focus behavior, target
  sizing, sticky-composer behavior, stable streamed DOM IDs, browser-console
  cleanliness, and proof that mobile rendering grants no authority.

Synthetic fixtures prove mechanics only. Product acceptance uses real configured
providers and endpoints where the plan calls for a live channel or model path.
