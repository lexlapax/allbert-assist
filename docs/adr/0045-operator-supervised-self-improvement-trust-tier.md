# ADR 0045: Operator-Supervised Self-Improvement Trust Tier

Status: Proposed for v0.47.

## Context

The v1.0 arc now includes a safe self-improvement precursor before the final
hardening milestone. Allbert should be able to notice repeated operator
patterns and propose useful drafts: skills, workflow YAML, template inputs, or
dynamic capability-gap requests.

Those suggestions are derived from traces, objectives, memory review decisions,
operator-marked examples, and existing skill/action metadata. That source data
is useful, but it is not authority. Repeated use, repeated approval, or model
confidence must not turn into permission grants, enabled skills, installed
plugins, package execution, or live code.

## Decision

Introduce an operator-supervised self-improvement trust tier for v0.47:

- Pattern discovery is read-only and runs through registered actions.
- Suggestion packets are advisory metadata only.
- Suggestions may create inert drafts in reviewed draft roots.
- Instruction-only skill drafts are disabled and untrusted by default.
- Workflow YAML drafts are declarative objective input only.
- Template inputs may hand off to the v0.38 templated creation path.
- Marketplace-lite metadata from v0.45 may inform suggestions but remains
  descriptive only.
- Reviewed memory promotion/update draft facades and objective/workflow
  draft-write facades may be added, but they write draft state only.
- Code-bearing drafts must hand off to the v0.36 sandbox/gate and v0.37
  trusted-validation/live-integration path before any live authority can be
  requested.
- Settings, secrets, shell, package-install, confirmation-decision,
  trust-control, and live workspace/canvas write facades are out of scope.
- Enablement, integration, publish, rollback, and marketplace submission still
  require normal registered actions, Security Central, durable confirmation,
  traces, and audits.

No trace-derived signal, model output, suggestion score, or repeated operator
approval grants permission by itself.

## Consequences

Allbert can become more helpful without becoming self-authorizing. Operators
get suggestions that reduce repeated manual work, while the action boundary
remains the only effectful boundary.

The implementation must add evals for:

- read-only pattern scans;
- suggestion packets carrying no authority;
- disabled/untrusted draft creation;
- code-bearing draft gate requirements;
- memory/workflow facade draft-only behavior;
- repeated-use non-grants;
- unsafe capability-request denial;
- marketplace/publish confirmation.

Fully autonomous skill creation, hidden model distillation, auto-enable,
auto-publish, remote code install, and unsupervised self-recompilation remain
outside the v1.0 arc.

## Amendments

These amendments record the binding implementation decisions taken in the
post-v0.46 planning pass when the release was split into v0.47 (discovery +
local drafts) and v0.47b (handoff drafts). A1–A4 bind v0.47; A5–A7 bind
v0.47b. They refine, not replace, the Decision above.

### A1. The discovery substrate is a read-only trace index (v0.47)

Status: planned amendment for v0.47; binding once v0.47 M1 lands.

Pattern discovery needs repetition to be queryable, but traces are
append-only redacted markdown under `<ALLBERT_HOME>/memory/traces/`, not a
queryable event log. v0.47 adds `AllbertAssist.SelfImprovement.TraceIndex`, a
read-only compiled view that records repeated prompts, action chains,
corrections, and failed intents with reference pointers only. The index
inherits the v0.40–v0.43 trace redaction, stores no raw content or secrets,
and grants nothing. Free-text NLP mining beyond bounded repetition is out of
scope.

### A2. The suggestion surface is the generalized v0.42 discovery surface (v0.47)

Status: planned amendment for v0.47.

Self-improvement suggestions reuse `AllbertAssist.Tools.Discovery.Suggestion`
(extended `suggestion_type` plus a provenance discriminator) and the passive
`Workspace.DiscoverySuggestions` panel. One queue, one panel, one
pending/accepted/dismissed/expired lifecycle. No parallel suggestion store.

### A3. All inert drafts live in one unified reviewed-draft store (v0.47)

Status: planned amendment for v0.47.

The v0.37 `AllbertAssist.DynamicPlugins.Draft` lifecycle is generalized into
a single logical reviewed-draft facade holding every inert draft kind
(code-bearing, workflow, skill, memory; objective and the v0.47b kinds added
later) with a generic `kind`, provenance, and tier. The facade is the only
review/list/show/discard/promote surface. Existing source-bearing dynamic
drafts keep `<ALLBERT_HOME>/dynamic_plugins/drafts/` as a compatibility root;
new non-code v0.47 drafts use `<ALLBERT_HOME>/drafts/` subroots where
appropriate. **Promotion** routes a draft to the existing live write path for
its kind (skill enablement, live `<ALLBERT_HOME>/workflows/<id>.yaml`,
`Memory.append/1`, v0.37 `Loader.integrate/2`). See the ADR 0041
reconciliation note for the workflow drafts root.

### A4. v0.47 ships discovery + non-code local drafts; v0.47b ships handoff drafts

Status: planned amendment for v0.47.

v0.47 ships the trace index, the generalized suggestion surface, the
read-only `discover_patterns` action, and skill/workflow/memory draft
creation. Template-backed, marketplace-backed, delegate-plugin,
capability-gap, and objective drafts ship in v0.47b on the same substrate.
The split keeps the discovery substrate and inert non-code drafts decoupled
from the code-bearing gate path.

### A5. Marketplace and delegate-plugin drafts are inert (v0.47b)

Status: planned amendment for v0.47b.

Marketplace-lite metadata (v0.45) informs suggestions but grants nothing; a
delegate-plugin draft scaffolds an inert v0.46-style plugin request through
the v0.38 plugin template and registers no agent. Operator no-code
delegate-agent authoring stays parked.

### A6. Code-bearing drafts reuse the v0.36/v0.37 path unchanged (v0.47b)

Status: planned amendment for v0.47b.

Capability-gap and template-backed code drafts route through
`DynamicPlugins.request_draft/2` → `Sandbox.run_gate/2` →
`Loader.integrate/2`, with `TrustedValidator` and `Loader.rollback/3`. v0.47b
adds no new sandbox, gate, or loader; live authority appears only after gate
evidence plus operator confirmation.

### A7. Objective drafts are declarative (v0.47b)

Status: planned amendment for v0.47b.

An objective draft is an inert objective definition in the unified store.
Framing and running it remains a confirmed v0.24 Objective Runtime action;
repetition never frames or runs an objective.
