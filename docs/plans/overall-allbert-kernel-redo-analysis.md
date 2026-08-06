# Allbert Kernel Redo — Architecture Analysis And Proposal

Status: **analysis and proposal only.** This is not a release plan, not a
milestone triad, and not an accepted decision. Nothing here is binding until the
operator accepts it and the affected ADRs are written or amended. It carries no
release scope; [roadmap.md](roadmap.md) remains the single source of truth for
what ships when, and [allbert-jido-vision.md](allbert-jido-vision.md) remains
the north star this proposal is measured against.

Question it answers: *how minimally could Allbert be rearchitected so the core
is small and everything else arrives as a plugin or addon, while staying
Elixir/OTP?*

Evidence base: the source tree as of this analysis, the roadmap ladder 1.0
through 1.8, the vision document, and the ADR set. Every quantitative claim
below is measured from the tree and carries its anchor. Where a number is a
count of files or lines it was taken from the working tree, not from memory.

**Amended three times. Read §13 for the resolved recommendation and §14 for
the routines/execution-graph re-check.**

- [Section 12](#12-amendment--re-check-against-v13-m9b4m9b5-adaptive-fan-out)
  re-checks §§1–11 against the v1.3 M9.b.4/M9.b.5 adaptive-fan-out revisions and
  supersedes part of §8.
- [Section 13](#13-resolved-recommendation--decided-structure-tiers-and-sequencing)
  is the **resolved recommendation**: it adds the kernel-to-pack coupling
  measurement, decides structure, tier tokens, and release sequencing, and
  supersedes §11's open decisions entirely along with the tier tokens in §3.2 and
  the phase placement in §9. Where §13 and an earlier section disagree, §13 wins.
- [Section 14](#14-amendment--routines-typed-execution-graphs-and-learning)
  re-checks the Turn Engine and Spine against primary-source Routines/workflow
  research and the v1.3 attended fan-out finding. It does not change §13's
  kernel/pack structure or sequencing; it decides that any future routine or
  graph capability deepens Jobs and Objectives instead of creating another
  runtime.

---

## 1. What The Code Says

### 1.1 Measured inventory

| Dimension | Measured |
| --- | ---: |
| Elixir in `apps/*/lib` | 181,429 LOC across 952 modules |
| Test scripts (`.exs`) across `apps` | 118,144 LOC, 617 `*_test.exs` files |
| Plugin Elixir under `plugins/` | 31,607 LOC across 13 plugins |
| Subsystem directories under `allbert_assist/lib/allbert_assist` | 56 |
| Action modules using the Allbert DSL | 252 in the kernel tree, 35 in plugins |
| Settings keys in one module | 463 |
| Accumulated `release.vNNN` gates in one Mix task | 43 |
| Web app | 17,413 LOC, 53 modules (separate umbrella app) |

Largest single modules:

| Module | Lines |
| --- | ---: |
| `lib/mix/tasks/allbert.test.ex` | 10,117 |
| `settings/schema.ex` | 6,858 |
| `agents/intent_agent.ex` | 3,703 |
| `runtime.ex` | 1,420 |
| `actions/registry.ex` | 876 |

### 1.2 The plugin boundary is not a boundary

All 13 directories under `./plugins` are compiled *into* `allbert_assist` by
path injection — `apps/allbert_assist/mix.exs:38-53` lists each plugin's `lib`
directory in `elixirc_paths/1`. There is no Mix project per plugin, no dependency
isolation, no independent version, and no independent test suite.

A plugin today is a manifest plus a directory convention. That is a real
contribution boundary for *discovery and metadata* — which is what
[ADR 0017](../adr/0017-allbert-plugin-contract.md) actually promised — but it is
not a compilation, deployment, or blast-radius boundary. Every consequence below
follows from that gap.

### 1.3 Four hand-maintained kernel lists are the real architecture

A fifth was found later and is recorded in
[§13.1](#131-the-measurement-that-decides-the-strategy):
`Plugin.Discovery.@shipped_modules`, a thirteen-entry plugin-id-to-module map
that is the purest instance of the violation.

| Kernel edit-point | Evidence | Effect |
| --- | --- | --- |
| `Actions.Registry` compile-time alias list | `actions/registry.ex:541,545` — `@actions @agent_actions ++ @internal_actions`; ~250 `alias` lines above it | Adding any capability edits a kernel file |
| `Settings.Schema` monolith | `settings/schema.ex:4667` — `def core_schema, do: @schema`; 463 dotted keys in the module | All settings ownership is central |
| `mix allbert.test` gate task | 43 `release.vNNN` gate definitions in a 10,117-line module | Gates accumulate and never retire |
| `Runtime` direct subsystem aliases | `runtime.ex:22-46` aliases ~25 subsystems by name | The fan-in/fan-out loop knows every feature |

The settings case deserves precision, because the mechanism *looks* solved and
is not. [ADR 0031](../adr/0031-settings-schema-fragments-and-authority.md)
introduced schema fragments, and `settings/fragments.ex:85-104` does compose
them — but `core_fragments/0` derives fragments *by namespace-grouping the
central schema after the fact*. Genuine external ownership is exercised by
exactly one plugin module (`plugins/allbert.notes_files/lib/.../
settings_fragment.ex:39`), and **zero** plugin manifests declare a
`settings_schema` entry. The fragment layer is a presentation and composition
view over a central schema, not a distribution of ownership.

### 1.4 The pattern this produces, visible in the roadmap itself

The 1.5 through 1.8 ladder is largely a coupling-repayment schedule:

- **1.5** is explicitly framed as one sweep over 249 action modules, because
  param-contract enforcement and response-envelope consolidation both touch all
  of them. Its own survey found ~4,000 lines of derivable boilerplate:
  `denied/1` hand-rolled in 130 modules, `action/3` in 121, the standard
  four-key `output_schema` in 214 of 249.
- **1.6** consolidates an SSRF private-address table that is triplicated
  byte-for-byte across `external/http_policy.ex`, `voice/provider_http.ex`, and
  `settings/model_doctor.ex`. Three copies of a security guard means fixing one
  leaves two holes.
- **1.0.2 and 1.0.3** were two entire releases spent on test isolation and
  suite speed ([ADR 0082](../adr/0082-registry-injection-seams-for-test-isolation.md),
  [ADR 0086](../adr/0086-test-global-state-ownership-conversion.md)), and the
  aggregate still peaks near a recorded 47.7 minutes.
- **1.1** required eight corrective rounds whose systemic root was resource
  ownership, ending at a single SQLite writer with `pool_size: 1`.
- **1.3 M9.b** burned six authoritative release attempts, none stopped by a
  product regression — which is why 1.4 now carries a preflight gate.

### 1.5 Diagnosis

> The cost of every change is proportional to the number of capability modules,
> because capability code and kernel code share one compilation unit, one
> registry, one settings schema, and one test gate.

That is the thing to rearchitect against. It is not a code-quality problem; the
subsystems are individually well built. It is a *boundary placement* problem,
and it regrows every release because nothing structurally prevents it.

### 1.6 What is already healthy and must be preserved

Any proposal that damages these is worse than doing nothing:

- **Security Central.** A 37-line facade (`security.ex`) over ~2,600 LOC, with
  policy, risk, decision, context, and redaction cleanly separated. This is the
  best boundary in the system. It should not be restructured.
- **`Actions.Runner.run/3` as the single effect boundary.** Correct, and the
  reason the extension model below is safe to widen.
- **`Models.PromptEnvelope`.** Prompt rules are already typed `{atom, text}`
  data with a provenance-preserving role split, and only six call sites. The
  best available foundation for adaptive prompting.
- **`Projection.PromoteProtocol` and disposable SQLite projections.** The most
  under-exploited idea in the codebase (§7).
- **Markdown in Allbert Home as source of truth, SQLite as derived.**
  [ADR 0002](../adr/0002-markdown-first-memory.md). Keep exactly as is.
- **The authority model.** Registration never grants permission; metadata,
  manifests, and model output are never authority. Every proposal below is
  constrained by this and none of them relax it.

---

## 2. The Invariant To Rearchitect Around

> **The kernel contains no list of its extensions.**
> Adding a capability must not edit any kernel file.

Applied today, adding one capability requires editing `Actions.Registry` (alias
plus list), `Settings.Schema` (keys), `mix allbert.test` (gate and lane), and
usually an intent descriptor. Four kernel files minimum.

Everything in §3 through §9 is a consequence of inverting those four lists. This
is deliberately a smaller claim than "rewrite Allbert": the proposal is five
inversions, each of which moves a list from the kernel to the owner of the thing
being listed.

---

## 3. Proposed Shape — A Seven-Concern Kernel Plus Packs

### 3.1 The kernel

Target: roughly 20,000–25,000 LOC, from the current 181,000.

| # | Concern | Owns | Does **not** own |
| --- | --- | --- | --- |
| 1 | **Home and Identity** | `ALLBERT_HOME`, paths, `user_id`, single-writer lock, per-Home integrity secret | Any durable schema |
| 2 | **Settings Central** | Layered *resolver*, provenance, validation, migration runner, secret vault | The schema. Kernel ships its own keys; packs own theirs |
| 3 | **Security Central** | Permission classes, policy, risk, confirmation requirement, redaction, audit, and the posture ladder (§5) | Execution; any per-feature policy special case |
| 4 | **Capability Plane** | The Action DSL, response envelope, param contract, `Runner.run/3`, and a registry populated by contribution at boot | The list of actions |
| 5 | **Turn Engine** | The fan-in/fan-out loop as one staged machine: ingest, assemble, route, authorize, execute, observe, join, respond | Routing strategy, decomposition strategy, proposers — those are behaviours |
| 6 | **Surface Plane** | One transport contract: ingress event to turn, egress render, identity mapping, dedupe, receipt and acknowledgement, approval rendering | Any specific channel |
| 7 | **Spine** | Signal bus, Trace, the single Jobs scheduler, Confirmations, Objectives, and the Projection primitive (§7) | Anything domain-shaped |

Concerns 1, 3, and 7 largely exist today and change least. Concerns 2 and 4 are
inversions of existing code. Concern 6 is a generalization of the existing
channel substrate. Concern 5 is the only genuine consolidation, and it is
deliberately sequenced last.

### 3.2 Packs

A **pack** is the single contribution unit. It replaces the current split
between "plugin", "app", and "in-tree subsystem" with one concept at three trust
tiers.

| Tier | Location | Form | May contribute |
| --- | --- | --- | --- |
| `:kernel` | in-tree, own OTP application | compiled | everything |
| `:project` | `./packs/*`, own OTP application, compiled only by explicit build configuration | compiled | everything |
| `:home` | `<ALLBERT_HOME>/packs/*` | **data only, never code** | skills, prompt rules, settings values, job definitions, intent descriptors, surface manifests |

**Tier tokens superseded by [§13.2 decision 5](#132-every-decision-decided):**
`:kernel` / `:native` / `:declared`. The rows above describe the right three
tiers; only the middle and lower names change, because `:project` collides with
Mix projects and the umbrella, and because provenance ("who wrote it") is
orthogonal metadata rather than a tier.

The `:home` tier is the part that gives operators a real extension story without
a compiler, while preserving the durable non-goal in
[ADR 0017](../adr/0017-allbert-plugin-contract.md) and
[ADR 0032](../adr/0032-dynamic-plugin-generation-and-sandboxed-loading.md):
Allbert never compiles or loads arbitrary code from a user-owned folder. A
data-only pack can recombine capabilities that are already registered and
already permitted. It cannot introduce a novel effect. That limit is the point,
not a shortcoming.

### 3.3 The pack contract

One behaviour, every callback optional:

```elixir
defmodule AllbertPack.Telegram do
  use AllbertAssist.Pack, id: "allbert.telegram", tier: :project

  def actions,          do: [...]      # capability modules
  def settings,         do: Fragment   # owns "telegram.*"; kernel schema never sees them
  def channels,         do: [...]      # transport adapters
  def surfaces,         do: [...]      # workspace tiles, CLI group, TUI pane
  def skills,           do: ["skills"] # skill roots relative to the pack
  def jobs,             do: [...]      # managed job definitions
  def stores,           do: [...]      # projection definitions and migrations
  def children,         do: [...]      # supervised processes
  def prompt_rules,     do: [...]      # declarative rules the envelope composes
  def intent_descriptors, do: [...]
  def test_lane,        do: :channels  # gate composition, not a 10k-line task
end
```

Discovery: enumerate `Application.loaded_applications/0`, resolve each
application's declared pack module, validate its contributions, and build a
runtime registry at boot. **No kernel file is edited to add a pack.**

Authority is unchanged and this is what makes the widening safe: a contributed
action still resolves through `Actions.Registry` and executes through
`Actions.Runner.run/3` under Security Central and confirmations; a contributed
channel is still a delivery adapter; a contributed skill still follows skill
trust and enablement policy; a contributed settings fragment still writes only
through Settings Central. Contribution is discovery, never grant.

### 3.4 What leaves the kernel

Indicative, by current subsystem size. These become packs:

`memory` (8.3k), `dynamic_plugins` (6.6k), `coding` (4.2k), `search` (3.9k),
`public_protocol` (3.9k), `voice` (2.8k), `sandbox` (2.5k), `tools` (2.4k),
`marketplace` (2.3k), `mcp` (2.3k), `artifacts` (2.0k), `drafts` (1.6k),
`templates` (1.6k), `workflows` (1.4k), `theme` (1.2k), `first_run` (0.7k),
`packages` (0.7k), `plan_build` (0.7k), `self_improvement` (0.7k),
`portability` (0.5k), `first_model` (0.2k) — plus the majority of the 40,000-line
`actions/` tree, which follows its owning domain.

Kernel-resident remainder: settings resolver, security, capability plane, turn
engine, surface plane, spine, home and identity, plus the parts of `intent`,
`objectives`, `conversations`, `confirmations`, `channels`, `session`,
`execution`, `resources`, and `trace` that are genuinely substrate rather than
feature.

---

## 4. Where Skills Live

### 4.1 Today

`skills/registry.ex:237-266` resolves eleven `root_spec` classes with explicit
precedence: built-in, project `.allbert/skills`, project `.agents/skills`, app
roots, plugin roots, user native, user interoperable, configured scan paths,
marketplace root, and imported root. The tree contains 16 shipped `SKILL.md`
files.

Eleven trust-and-precedence classes for sixteen files is mechanism outrunning
use, and it is a durable source of "which root won?" questions.

### 4.2 Proposal

**A skill is a pack's presentation layer, not a peer of it.** Three locations:

1. `<pack>/skills/` — ships with the pack; trust inherited from the pack tier.
2. `<ALLBERT_HOME>/skills/` — operator-authored; always `:user` trust.
3. `<ALLBERT_HOME>/packs/<id>/skills/` — installed data-only pack; `:reviewed`
   after explicit enablement.

Marketplace, imported, project, and `.agents/skills` roots collapse into
*configured scan paths that resolve to case 2 or case 3*. They become a settings
value, not a trust class.

The rule from [ADR 0003](../adr/0003-skill-manifests-as-capability-contracts.md)
is unchanged: a skill is markdown naming capabilities the pack **already
registered**, plus prompts and examples. It never grants; the capability must
already exist and already be permitted. Mechanism goes from eleven classes to
three; the contract does not move.

---

## 5. Security Central With Defaults That Adapt

The operator requirement is "sane defaults that change over time based on user
preference." Placing that in the profiling job would create a second authority
path. It belongs inside Security Central.

- Defaults become a named **posture profile** — `:guarded`, `:standard`,
  `:trusted` — rather than per-key defaults scattered across the schema.
- A posture transition happens **only** through a confirmed, audited,
  floor-pinned change that displays the exact before-to-after diff. Mechanically
  the same path as the confirmed customization in
  [ADR 0090](../adr/0090-adaptive-usage-profiling-and-confirmed-customization.md).
- A **safety floor** is immutable by construction. Credentials, egress,
  permission classes, confirmation requirements, and sandbox levels are never
  movable by adaptation — only by the operator acting directly.
- Evidence is advisory. "This class has been confirmed forty times and never
  denied" is a *proposal* to move that class's default. It is never an automatic
  grant. This preserves the vision's rule that "the user usually says yes" is not
  equivalent to the user saying yes this time.

---

## 6. The Self-Improvement Loop And Adaptive Prompt Rules

The substrate for this is better than it looks. `Models.PromptEnvelope` already
carries rules as typed `{atom, text}` pairs with a provenance-preserving role
split, and Jobs is already mandated as the sole recurring engine.

Proposed loop, all inside existing boundaries:

> Managed job (bounded, zero-egress) → distill from usage and trace stores →
> propose a **typed delta** → inert suggestion carrying evidence → confirmation →
> audited apply → record descriptive observed outcomes → one-click revert.

The generalization over the 1.4 design is that **delta kinds become an extension
point with a floor**, instead of a hardcoded allowlist that needs a release to
extend:

| Delta kind | Adaptive | Floor |
| --- | --- | --- |
| Prompt rule (style, verbosity, format) | yes | Security and authority rules immutable |
| Settings value | yes | Only within the pack's declared adaptive key set |
| Model role remap | yes | Never crosses the local/egress boundary |
| Router weight or descriptor | yes | Candidate set stays registry-validated |
| Permission, confirmation, egress, credential | **never** | Operator-direct only |

A pack contributes its own prompt rules and declares which of its own settings
keys are adaptive. The self-improvement loop then works on packs written after
it — the property the current design does not have.

---

## 7. The Projection Primitive

v1.3 Memory (8,287 LOC), v1.3 Search (3,940 LOC), and the 1.7/1.8 Knowledge work
are three instances of one pattern:

> append-only authenticated markdown in Allbert Home as the source of truth →
> disposable SQLite projection → managed rebuild job → typed query API →
> a surface

`AllbertAssist.Projection.PromoteProtocol` already exists because two of them
were noticed to rhyme. The proposal is to finish that observation: extract a real
kernel primitive owning projection definition, rebuild and repair jobs, integrity
and hash-chain handling, disposability, and single-writer ownership. Memory,
Search, and Knowledge then become packs over it.

**Sequencing note.** This is the one item where timing genuinely matters. If the
primitive is not extracted before 1.7, Knowledge becomes the third bespoke copy,
and the cost is paid again in 1.8 and in whatever follows. Extracting it first
also makes 1.7 and 1.8 materially smaller releases than currently planned.

---

## 8. Jido — The Recommendation

**Keep `Jido.Signal` and `Jido.Action`. Make `Jido.Agent` a pack-level choice.
Retain `jido_ai` only for its proven specialist consumers until those owners
are deliberately migrated or requalified.**

Grounded in measured usage:

- **Signal** — real value: CloudEvents shape, bus, decoupled channels, jobs, and
  agents. Keep as the kernel message substrate.
- **Action** — real value: schema, validation, structured results, AI tool
  conversion. It is what `use AllbertAssist.Action` (`action.ex`, 154 lines)
  wraps. Keep.
- **Agent** — used by roughly six kernel modules (IntentAgent, Objectives.Engine,
  Jobs.Scheduler, Confirmations.Store, the codegen agent) plus three in plugins,
  and `JidoBacked` (266 lines) already re-wraps its AgentServer plumbing. AGENTS.md
  already codifies a pragmatic "plain GenServer when Jido.Agent buys nothing"
  rule, and most state-bearing modules already are plain GenServers.
  The v1.3 M9.b.4 re-check in
  [§12](#12-amendment--re-check-against-v13-m9b4m9b5-adaptive-fan-out)
  does not narrow this recommendation: its `FanoutManager` is a stateless
  Interface invoked inside the existing DirectAnswer turn, while its temporary
  worker uses `Jido.Agent` for one bounded lifecycle. The proposal formalizes
  the existing reality: the Turn Engine should be an
  explicit, plain, restartable OTP state machine with exactly one owner per
  resource. Given that 1.1 spent eight corrective rounds on resource-ownership
  faults and ended at `pool_size: 1`, deterministic single-ownership is worth
  more here than lifecycle hooks.
- **`jido_ai`** — Measured against committed sources it has two production call sites: model
  alias generation (`settings/provider_catalog.ex:124-131`) and dynamic-plugin
  codegen (`dynamic_plugins/codegen/llm.ex:49`, already guarded by
  `Code.ensure_loaded?/1`), against `ReqLLM` in 24 modules — which read as one
  dependency and one refresh obligation per release for two call sites. v1.3
  M9.b.4 adds no `jido_ai` call site, so it supplies no evidence either for
  keeping or removing that dependency. Retain it for the StockSage and codegen
  consumers that actually use it; remove it only when those owners have an
  accepted replacement and focused parity evidence.

Net against committed sources: the kernel loop stops inheriting a framework's
supervision semantics at precisely the place with the most recorded production
pain. That part of the recommendation stands, and §12 records that the v1.3
amendments now state the same rule normatively.

---

## 9. Migration — Five Inversions, No Rewrite

Each phase is literally "move the list from the kernel to the owner of the
listed thing." Each ships value alone and is independently revertable.

**Placement superseded by [§13.3](#133-sequencing):** the phases below are
unchanged, but their release placement is decided there, together with the
umbrella-app mechanism that makes them enforceable and the hard ordering
constraint that gate inversion must precede module moves.

| Phase | Change | Suggested placement | Rationale |
| --- | --- | --- | --- |
| **0** | Add a Credo check: no kernel file may name a capability module. It fails today; the failure list becomes the burn-down. | Anytime, small | The pattern already exists — `priv/credo_checks/settings_central_no_bypass.ex`. Makes the invariant enforceable before any code moves. |
| **1** | **Registry inversion.** Replace the `Actions.Registry` alias list with boot-time contribution. Action modules stay where they are; each subsystem grows a pack module listing its own actions. | Ride v1.4 | v1.4 already opens all 249 action modules for param contracts and envelope consolidation. One sweep instead of two. Highest-leverage insertion point in the current ladder. |
| **2** | **Settings inversion.** 463 keys become kernel keys plus pack-owned fragments; packs author their own schema rather than having it grouped out of a central module. | Ride v1.4 | v1.4 already builds the migration runner and moves telegram and email settings. Generalize rather than special-case. |
| **3** | **Gate inversion.** Packs own lanes; `release.vN` composes lanes. Retire the 43 historical gates behind one current gate plus archived definitions. | v1.4 M5 (already scoped as absolute suite duration) | Directly attacks the 47.7-minute aggregate and the six burned authoritative attempts. |
| **4** | **Projection primitive** extracted from Memory and Search. | Before v1.5 | Otherwise Knowledge becomes the third bespoke copy. |
| **5** | **OTP application extraction**, one pack at a time, cheapest first. | v1.7 onward, opportunistic | Only after 1–3, because 1–3 remove the reasons extraction is hard today. |
| **6** | **Turn Engine consolidation** — Runtime, IntentAgent, and Fanout into one staged loop with strategy behaviours. | Last, its own release; precondition named in [§12](#12-amendment--re-check-against-v13-m9b4m9b5-adaptive-fan-out) | Use the v1.1 fan-out invariants as the acceptance set. v1.3 M9.b.4/M9.b.5 builds three of these seams with two Adapters each, which is the extraction trigger ADR 0021 §A22 requires. |

Phases 0 through 3 fit inside v1.4 as currently scoped. Doing so changes v1.4's
character from "one large mechanical sweep" to "one large mechanical sweep that
also inverts the three lists," at meaningfully less than twice the cost, because
opening all 249 modules is the expensive part either way.

---

## 10. Honest Limits And Risks

- **This does not shrink 181,000 lines.** It relocates roughly 155,000 of them
  behind boundaries. Kernel LOC drops to an estimated 20,000–25,000. Genuine
  deletion happens only where duplication is removed — envelope boilerplate
  (~4,000 lines), the triplicated SSRF table, and projection duplication —
  plausibly 10,000–15,000 lines total.
- **Phase 6 is genuinely risky.** `runtime.ex` and `agents/intent_agent.ex` are
  5,100 lines encoding correctness won across eight corrective rounds in 1.1. If
  only phases 0 through 4 are done, most of the benefit is still realized. Phase 6
  should stay optional until the invariant has held for two releases. [§12](#12-amendment--re-check-against-v13-m9b4m9b5-adaptive-fan-out)
  revises this downward: v1.3 M9.b.4/M9.b.5 builds the hardest seams under
  operator sign-off, so phase 6 becomes generalization of existing seams rather
  than invention of new ones.
- **Data-only home packs will feel limited.** No code means no novel effects,
  only recombination of registered and permitted capabilities. That is the
  correct trade under ADR 0017 and ADR 0032, but the expectation should be set
  explicitly rather than discovered.
- **The v1.0 public-contract freeze constrains phase 1.** Registry inversion must
  preserve `Actions.Registry.modules/1` and `resolve/2` behaviour exactly. The
  change is additively compatible, but it touches a Tier-2 contract and needs an
  ADR before implementation.
- **Phase 3 interacts with release evidence.** Retiring historical gates changes
  what "the gate passed" has meant historically. Archived gate definitions must
  remain reproducible for audit, not merely deleted.
- **This proposal does not address** hosted multi-user operation, distributed
  nodes, or the parked System Memory Distillation route. Those non-goals stand.

---

## 11. Open Decisions For The Operator

**Superseded in full by [§13](#13-resolved-recommendation--decided-structure-tiers-and-sequencing).**
All five are resolved there. The list is retained because the reasoning in §13
answers these specific questions and reads better against them.

1. **Do phases 0–3 fold into v1.4?** This is the gating decision; v1.4 is the
   release that opens all 249 action modules, and that window does not reopen.
2. **Is `packs` the accepted term**, replacing the current plugin/app split, or
   should the existing `AllbertAssist.Plugin` vocabulary be extended in place?
3. **Does the projection primitive get extracted before 1.7**, accepting a
   schedule cost there, or does Knowledge ship bespoke and get folded later?
4. **Is dropping `jido_ai` acceptable** given its two production call sites, or
   is it retained for future Jido.AI-based specialist work?
5. **Should this proposal become an ADR** (pack contract and kernel inversion)
   plus concrete v1.4 milestone deltas, which is the form the process expects for
   a decision that constrains future design?

Until those are answered this document remains analysis, and the roadmap ladder
stands as written.

---

## 12. Amendment — Re-check Against v1.3 M9.b.4/M9.b.5 Adaptive Fan-Out

Dated 2026-07-31. Sections 1 through 11 were written against sources committed
at that point. This section re-checks them against the revisions to
`docs/adr/0083-objectives-parallel-child-fanout.md`,
`docs/adr/0021-intent-objective-capability-and-advisory-boundary.md` (new §A22),
`docs/plans/allbert-jido-vision.md` (new "Parallel delegation and fan-in"
subsection), and the v1.3 plan/request-flow M9.b.4/M9.b.5 milestones. Those
revisions were uncommitted when this section was written and landed as
`bae38844`; implementation followed.

### 12.1 What the revision changes

The interim Stage-0 regex/classifier decomposer is replaced by four seams:

1. A stateless **`FanoutManager` Interface** owns adaptive admission inside the
   existing registered DirectAnswer turn — it is not a Jido command, registered
   action, intent candidate, permission, or execution route.
2. A **typed inert `FanoutPlan`** plus a deterministic compiler validates the
   closed schema, original-request binding, structural bounds, uniqueness, and
   inert child fields. The model/rubric assesses independence, advisory/read-
   only scope, supplied-text ownership, coverage, and material leverage; code
   does not claim to prove prose semantics. Compact canonical provenance binds
   the parent request and ordered durable child rows.
3. A **Worker Interface with two Adapters** — `ActionAdapter` for the existing
   registered-action Lifecycle and a one-turn `JidoAdapter` hosting the same
   registered DirectAnswer action in a bounded temporary `Jido.Agent`. Resolved
   registered action identity and original-request grounding select the
   Adapter; neither the model nor the compiler can name it. v1.3 adds no worker
   tool loop or `Jido.AI` call.
4. **Durable report composition** after terminal reduction: the last terminal
   child freezes the child/result/receipt snapshot with
   `report_composition_state=queued` and `report_delivery_state=not_ready`; a
   recoverable composer may select only one content-free, versioned
   relationship-section layout over completed children. A deterministic
   Allbert renderer owns all report language, keeps non-completed children
   outside model control, and stores a complete-child fallback. The selected
   source and normalized provenance are digest-bound before delivery becomes
   pending.

### 12.2 What still holds

- **The kernel-list diagnosis (§1.3) is unchanged.** M9.b.4 additively extends
  `Settings.Schema` with fan-out limits but does not invert ownership of that
  list; it does not alter the Registry contribution model or gate ownership.
- **It mildly reinforces the diagnosis.** M9.b.4/M9.b.5 add
  `intent/{fanout_manager,fanout_plan}`, the worker Adapters, and
  `objectives/fanout_report_composer` to the kernel tree, plus two more
  hand-maintained per-milestone test-file lane lists feeding the 10,117-line
  gate task. The kernel grows and the gate list grows.
- **Packs, registry inversion, settings inversion, gate inversion, the
  Projection primitive, skills, and the security posture ladder are not
  touched.** Sections 3 through 7 and phases 0 through 5 stand as written.
- **The kernel/pack line looks correctly placed.** All new work lands in kernel
  concerns 5 (Turn Engine) and 7 (Spine), and none of it is pack-shaped. That is
  evidence for the split in §3.1 rather than against it.

### 12.3 What the implementation does not change

**M9.b.4 does not decide the `jido_ai` dependency question.** Its manager uses
ReqLLM inside a stateless Interface and its worker uses plain `Jido.Agent` for a
single registered DirectAnswer call. The two pre-existing StockSage/codegen
consumers remain the evidence for any keep/remove decision.

**The "Jido.Agent as a pack-level choice" recommendation is not narrowed.** A
one-turn temporary worker is exactly a pragmatic lifecycle use; the stateless
manager is not an Agent and owns no process state.

The principle underneath both — that framework process state is never durable
authority — is unchanged and is now **normative rather than proposed**. ADR 0083
§4 states that Jido child-process tracking and awaits are live execution aids
that never substitute for durable Objectives state; §A22 states that a worker's
process, parentage, state, output, or successful tool call is never durable
authority. That is the same position §8 argued from v1.1's eight corrective
rounds, and it no longer needs arguing here.

### 12.4 What improves

**Phase 6 gains a named precondition and loses risk.** §A22 permits extraction
of the private planner, worker, and composer Interfaces "only after a second
real Adapter exists" — the same evidence rule ADR 0021 §A20 applies to advisory
providers. M9.b.4/M9.b.5 ships two Adapters for three seams simultaneously:

| Seam | Adapter A | Adapter B |
| --- | --- | --- |
| Plan | manager model proposal | exact counted offline protocol |
| Worker | registered-action `ActionAdapter` | one-turn DirectAnswer `JidoAdapter` |
| Report | main-model composition | deterministic complete-child fallback |

Once those land and their focused qualification is accepted, §A22's condition is
satisfied for all three. Phase 6 therefore changes character: from "consolidate
`runtime.ex`, `intent_agent.ex`, and Fanout into a staged loop with strategy
behaviours" — inventing the seams — to "generalize three seams the project has
already built, tested, and signed off on." The v1.1 fan-out invariants remain
the acceptance set, joined by the M9.b.5 composition and delivery invariants.

This does not make phase 6 cheap, and it stays last. It does mean the riskiest
part of the proposal is being de-risked by work already scheduled.

### 12.5 One note on the vision document

The revision adds a "Parallel delegation and fan-in" subsection to
[allbert-jido-vision.md](allbert-jido-vision.md), which carries a stability note
against edits during normal version work. The note permits deliberate
vision-level revision, and the operator approved this one. The added text is
compatible with §3.1 concern 5 and adds useful specificity about where
delegation authority sits; no claim in this analysis depended on the prior
wording.

### 12.6 Net effect on this amendment

No phase is added, removed, or resequenced. M9.b.4 does not change the
dependency or pragmatic-Agent recommendations; it makes three candidate seams
concrete, improves the phase 6 risk estimate, and leaves the §1.5 diagnosis
unchanged. The five open decisions in §11 stood as written at the time of this
amendment; [§13](#13-resolved-recommendation--decided-structure-tiers-and-sequencing)
subsequently resolves them and records the current `jido_ai` disposition.

---

## 13. Resolved Recommendation — Decided Structure, Tiers, And Sequencing

Dated 2026-07-31. This section closes every question §§1–12 left open. It
supersedes §11 in full, the tier tokens in §3.2, and the release placement in §9.
It changes no phase and withdraws no finding; it decides how the phases land.

The prompting question was whether to start a parallel `allbert-kernel` project,
build the kernel correctly there, add sibling projects for the other tiers, and
wipe the existing tree at parity — optionally deferring everything into a 2.0
that renumbers 1.6/1.7/1.8. The answer below keeps the isolation instinct and
rejects the greenfield and the big-bang, on measured grounds.

### 13.1 The measurement that decides the strategy

Kernel-to-pack coupling — the references that must be broken before any pack can
become its own OTP application — is **13 references across 7 files**, and only
two are structural:

| Reference | Location | Kind |
| --- | --- | --- |
| `@shipped_modules`, a 13-entry plugin-id-to-module map | `plugin/discovery.ex:8-22` | **structural** |
| `@reserved_app_owners` — `stocksage: [StockSage.App]` | `app/validator.ex:25` | **structural** |
| `"StockSage.Actions.RunAnalysis"` (×3) | `agents/intent_agent.ex:2316-2349` | documentation example strings |
| the same string (×3) | `objectives/acceptance_criteria.ex:17`, `workspace/emitters.ex:25`, `workspace/fragment/guard.ex:21` | default value and allowlist entries |
| `"StockSage.DataCase" => :db_serial` | `mix/tasks/allbert.test.ex:112` | test-lane mapping |

The barrier between Allbert and a real kernel boundary is essentially one
thirteen-line map. That single fact decides the strategy: **relocate, do not
rebuild.** A greenfield kernel would spend a long arc re-earning correctness that
already exists — the single writer and `pool_size: 1`, bounded idempotent receipt
retry, atomic terminal reduction, the writer lock — in order to escape a coupling
of thirteen lines. Parity would also be unmeasurable, because parity here is
defined by 43 gates and 617 test files that live in the existing tree, while the
target keeps moving underneath it.

Two supporting measurements:

- **Pack-to-kernel coupling is broad but legal.** Plugin code references 144
  distinct `AllbertAssist.*` modules across 37 top-level subsystems. Some of those
  are pack-tier under this proposal (Memory, Search, Coding, Workspace, CLI), so
  they become pack-to-pack dependencies. That is permitted; only kernel-to-pack is
  forbidden.
- **Ownership metadata is nearly absent.** Only 5 of 268 action modules declare
  `plugin_id` and 13 declare `app_id`, so registry inversion cannot lean on
  existing metadata. Each module needs a pack assignment — which is one more field
  in the sweep v1.4 already performs over all of them.

### 13.2 Every decision, decided

| # | Decision | Call | Basis |
| --- | --- | --- | --- |
| 1 | Separate repositories or umbrella applications | **Umbrella applications** | Sibling dependencies are declared and compile-enforced (`in_umbrella: true`, `apps/allbert_assist_web/mix.exs:69`), so the §2 invariant becomes a build failure rather than a lint. Keeps the shared release, cosign, tap, and license machinery. Separate repositories stay available later; nothing forecloses them. |
| 2 | Greenfield or relocate | **Relocate into an initially empty `apps/allbert_kernel`** | §13.1. Module names are independent of application names on the BEAM, so `AllbertAssist.Security` moves without renaming and the v1.0 freeze is untouched. |
| 3 | Do packs need optional compilation | **No — not a requirement** | `stage_plugins` already copies data from every directory under `plugins/`; pack code already compiles in through `elixirc_paths`; enablement is runtime settings (`plugins.enabled`, `plugins.disabled`, `plugins.load_policy`, `plugin/discovery.ex:24-29`). The artifact already ships everything. |
| 4 | How packs are discovered without a kernel list | **`Application.loaded_applications/0` plus a pack-module lookup** | The kernel holds no list; the release manifest does. That is correct rather than a compromise: the v1.2.6 license generator already requires knowing exactly what ships. |
| 5 | Tier tokens | **`:kernel` / `:native` / `:declared`** | Names the capability axis — may it contribute compiled code — instead of provenance, which becomes orthogonal metadata so a user may author a `:native` pack and a vendor a `:declared` one. Rejects `:project` (collides with Mix and the umbrella), `:core` (collides with kernel), `:extension` (vacuous), `:layer1` (opaque). |
| 6 | A middle application between kernel and packs | **None. Two categories only: the kernel, or a named pack** | An `allbert_core` beside `allbert_kernel` is two names for one idea and becomes the drawer everything lands in, reconstructing the monolith with an extra hop. |
| 7 | Where `External.HttpPolicy` and `RequestSpec` live | **Kernel, concern 3** | Egress policy is a security boundary and packs call it 14 times. v1.7 already consolidates the triplicated SSRF table; it should land in the kernel application. |
| 8 | Fate of the `plugins/` directory | **Retires; each becomes `apps/allbert_<name>`** | Data staging moves to each application's `priv/`, which OTP releases handle natively — removing the custom `stage_plugins` release step. `<ALLBERT_HOME>/plugins` remains the `:declared` tier, renamed `packs`, with `plugins` retained as a compatibility scan path. |
| 9 | StockSage | **`apps/allbert_stocksage`** | Whether it ships in the default artifact becomes a one-line release-manifest choice rather than an architectural fact. |
| 10 | Does this become an ADR | **Yes, one** — pack contract, kernel application boundary, and tier model | It constrains future design, which is this project's stated ADR trigger. Amends ADR 0017 and ADR 0031; supersedes neither. |
| 11 | `jido_ai` disposition | **Retain only for current StockSage/codegen consumers; M9.b.4 does not expand its role** | Removing a live dependency without owner migration is not additive; using M9.b.4 to justify it would be factually wrong because that milestone uses ReqLLM plus plain `Jido.Agent`. |

### 13.3 Sequencing

Neither a single long v1.4 nor a 2.0 that absorbs everything and renumbers
1.6/1.7/1.8. Both are the unbounded-scope failure mode this project has already
demonstrated — v1.3 M9.b burned six authoritative attempts and v1.1 required
eight corrective rounds. The seam to split on is the contract line.

Checked rather than assumed: **only the Turn Engine needs a major.** Registry
inversion preserves `modules/1` and `resolve/2` behaviour; settings inversion
preserves key names and semantics; gate inversion is internal tooling; module
relocation preserves module names. All are 1.x-legal. Only response shapes and
signal names — phase 6 — require 2.0.

| Version | Content |
| --- | --- |
| **1.4** | **As planned, untouched.** It lands the preflight gate, which is wanted before any release that relocates large numbers of files. |
| **1.5** | Foundation. Create `apps/allbert_kernel` empty; registry inversion; settings inversion; gate inversion; delete `@shipped_modules` and `@reserved_app_owners`; relocate Home/Paths, Security Central with `HttpPolicy`, and the Capability plane. **Bounded by point tags** (1.5.1, 1.5.2, …), one per inversion, matching the established release model — that is the escape valve against an unbounded release. |
| **1.6** | OAuth as planned — XOAUTH2 is increasingly the only route to a real mailbox and should not wait behind a rearchitecture — plus extraction of three packs (telegram, email, notes_files) to prove the pattern on real code. |
| **1.7** | Projection primitive first, then Knowledge Stage 1 as a pack over it. Both smaller than currently planned. |
| **1.8** | Knowledge Central, unchanged in intent. |
| **2.0** | Turn Engine consolidation, remaining pack extraction, and accumulated Tier-1 cleanup. A bounded major. |
| **2.1** | Self-Hosting Development, moved from the 2.0 slot (`roadmap.md:367`). |

Moving self-hosting is a gain rather than a displacement: a pi-mode surface
developing Allbert against a small kernel and named packs is far more tractable
than against a single 181,000-line application, and self-hosting was always
implicitly gated on the codebase being navigable.

**Hard ordering constraint inside 1.5.** Gate inversion must precede module
relocation. The 43 gates name test paths under `apps/allbert_assist/test/`, and
umbrella applications own their own tests, so relocating a module relocates its
test and breaks every gate list naming it. The order is registry inversion,
settings inversion, gate inversion, then relocation.

### 13.4 Risks and their mitigations

| Risk | Mitigation |
| --- | --- |
| v1.4 runs long | Point tags; each inversion ships standalone |
| Relocation breaks gate file lists | Gate inversion precedes relocation (§13.3) |
| The v1.0 public-contract freeze | Module names unchanged; the freeze covers module and function contracts, not application membership |
| Pack-to-pack dependency tangle across 37 subsystems | Permitted; only kernel-to-pack is forbidden. One dependency-graph pass during the v1.7 extraction |
| `PermissionGate` deletion is not core-only — 7 pack call sites | Scope it in v1.4 as a cross-pack migration rather than a core edit |
| Umbrella applications compile everything | Not a requirement (decision 3); third-party path dependencies already provide build-time optionality if it ever becomes one |

### 13.5 The recommendation in one sentence

Create `apps/allbert_kernel` empty, invert the five kernel lists so the compiler
enforces the boundary, then relocate — v1.8 untouched, v1.4 as point-tagged
foundation, v1.7 through v1.6 keeping their numbers and their features, and 2.0
reserved for the one change that genuinely needs a major.

---

## 14. Amendment — Routines, Typed Execution Graphs, And Learning

Dated 2026-08-01. This amendment evaluates the useful idea behind the linked
"build a graph that runs itself" commentary against its primary sources and
against Allbert's implemented architecture. It does not add a release milestone
or change §13's structure, tiers, or sequencing. It decides how routine-shaped
and graph-shaped work fits the proposed kernel if and when a real consumer
requires it.

### 14.1 What the external example actually establishes

The source presentation is about
[Claude Code Routines](https://code.claude.com/docs/en/routines), not a generic
self-learning graph runtime. A Routine saves an instruction, repository and
connector context, and trigger configuration; a schedule, GitHub event, or API
call starts a managed session that an operator can inspect and continue. The
prompt has not disappeared — it has become versionable configuration used to
start a fresh run. The official
[proactive-agent-workflow session](https://claude.com/code-with-claude/session/ldn-build-a-proactive-agent-workflow-with-claude-code)
demonstrates unattended initiation and event chaining, not automatic model
learning or a universal DAG Interface.

Anthropic's broader guidance makes the useful part more precise:

- use predefined workflows when the path is known and reserve dynamic agents
  for work whose path cannot be predicted;
- use orchestrator/worker fan-out when subtasks are genuinely independent or
  dynamically discovered;
- join results through an explicit synthesis or evaluation step;
- prefer the simplest topology that meets the acceptance criteria because
  dynamic planning, multi-agent execution, and evaluator loops add latency,
  token cost, and compounding failure modes.

Those constraints appear in
[Building effective agents](https://www.anthropic.com/engineering/building-effective-agents),
[dynamic workflows in Claude Code](https://claude.com/blog/a-harness-for-every-task-dynamic-workflows-in-claude-code),
and Anthropic's
[multi-agent research-system retrospective](https://www.anthropic.com/engineering/multi-agent-research-system).
The primary sources support durable, observable orchestration. They do not
support collapsing three separate concepts into "a graph that learns":

| Concept | Interface | What it does not mean |
| --- | --- | --- |
| **Routine definition** | Reusable instruction/context plus trigger, limits, and operator policy | Consent to every later effect or a durable run |
| **Execution graph** | Typed nodes, dependencies, ready-set rules, joins, checkpoints, and terminal state | Semantic correctness, permission, or learning |
| **Improvement loop** | Evidence and evaluation produce a reviewable, versioned change proposal | Silent prompt, topology, routing, or authority mutation |

Keeping these as three Modules produces locality: trigger bugs stay in routine
binding, scheduling and recovery bugs stay in execution, and adaptation bugs
stay in the reviewed improvement loop. Combining them behind one magical
"agent graph" Interface would be shallow — every caller would still need to
understand triggers, authority, recovery, evaluation, and mutation policy.

### 14.2 The Allbert mapping is one deep Interface over existing Modules

The external pattern validates Allbert's existing concern split rather than
adding an eighth concern:

| Routine/product responsibility | Existing Allbert owner |
| --- | --- |
| Inert reusable declaration | Workflow YAML today; a future `:declared` pack artifact only after its contract is accepted |
| Schedule or recurring trigger | Jobs, the single recurring engine |
| Channel or public-protocol trigger | The ingress Adapter into the Turn Engine |
| Turn-scoped plan proposal | A bounded Turn Engine strategy Adapter |
| Structural validation and compilation | A deterministic typed-plan compiler Module |
| Durable nodes, checkpoints, attempts, cancellation, and recovery | Objectives in the Spine |
| Live worker lifecycle | Plain OTP or Jido.Agent under the pragmatic substrate rule |
| Effect execution | Registry → Runner → Security Central → confirmations |
| Wake-up and observation | Signals, followed by a read of durable state |
| Watch, pause, steer, resume, cancel, and result UX | Surface Plane projections shared by TUI, Web, DMs, CLI, and public protocols |

This is an orchestration product contract assembled across existing concerns,
not a `Routines` scheduler, store, or executor. Jobs owns when a run is
requested; Objectives owns whether and how it durably advances. Signals wake
observers but never become run or report authority. Jido process state assists
live lifecycle but never substitutes for Objective rows and events. A routine
id, graph id, Objective id, node id, trigger, saved prompt, or enabled connector
is never permission.

The pack contract therefore should not casually gain a `routines/0` callback.
Its existing `jobs`, `prompt_rules`, `intent_descriptors`, workflow owner, and
action contributions already expose the pieces. A new callback is justified
only if a later ADR finds a distinct, second declaration Adapter that cannot be
expressed through Workflow YAML or a data-only `:declared` pack without a
shallow pass-through Module.

### 14.3 Static plans first; dynamic graphs only behind the same compiler

Allbert already has two deliberately different plan forms:

1. ADR 0041 Workflow YAML is static, schema-validated inert data expanded into
   ordered Objective steps. It rejects cycles and forward references, but v1
   intentionally has no parallel step kind, event trigger, loop, or retry DSL.
2. ADR 0083 M9.b.4/M9.b.5 is one bounded, shallow diamond: a manager proposes
   independent inert children; deterministic policy and compilation may frame
   one durable parent plus ordered child Objectives; workers run in parallel;
   atomic terminal reduction freezes the join; a separate advisory composer
   selects relationships; Allbert renders one durable report. It is not an
   arbitrary dependency graph, nested fan-out, or general workflow language.

They do not yet share a canonical plan type, and this analysis does not pretend
that they do. The additive deepening opportunity is a future
`Objectives.ExecutionGraph` Interface compiled into the existing Objective,
Step, Event, receipt, and recovery Implementation:

```text
operator goal or trigger
        |
        v
static Workflow Adapter ----------- dynamic model proposal Adapter
        \                                  /
         +---- typed inert graph compiler +
                          |
                          v
             durable Objective run/checkpoints
                          |
                  deterministic ready set
                     /            \
             Action Adapter    bounded Jido Adapter
                     \            /
                      terminal join
                          |
                evaluator/composer Adapter
                          |
                 one durable result/outbox
```

Static Workflow expansion should be the first real Adapter. Only after that
Interface is proven should an LLM be considered as a second Adapter producing
the same inert type. The model may propose nodes, dependency edges,
relationships, or a replan; it may not name an implementation, identity,
permission, confirmation result, delivery route, or unregistered capability.
The local compiler owns:

- graph/version schema and source binding;
- node and edge bounds, uniqueness, acyclicity, and complete reference checks;
- deterministic ready-set and terminal-reduction rules;
- action identity resolution from registered capabilities and original
  operator evidence rather than generated prose alone;
- confirmation, cancellation, retry-safety, and budget propagation;
- idempotent replay, monotonic terminal state, partial fan-in, and bounded
  replan rules;
- graph and input digests sufficient to explain exactly what ran.

Every effect still crosses Registry, Runner, Security Central, and ordinary
confirmation. Contribution is not grant; compilation is not grant; a completed
advisory worker is not proof that an effect occurred. A durable effect receipt
remains the evidence for an effect claim.

Simple work must retain a direct path. Normalizing every greeting, lookup, or
single answer into a one-node graph would make the Interface shallower: callers
would pay graph latency and failure modes without gaining concurrency,
checkpointing, or recovery. The Turn Engine should choose the cheapest adequate
topology, and the operator may explicitly request the static/graph path when
deterministic orchestration matters.

### 14.4 The v1.3 finding is an admission lesson, not a graph-runtime lesson

The attended v1.3 FOV-4 finding recorded in the active plan, request flow, and
ADR 0083 occurred before durable planning: fan-out was enabled, but the manager
returned an ordinary answer and created no parent or child Objectives. No
worker, scheduler, join, or composer ran. A better downstream graph executor
could not correct a plan that was never admitted.

That distinction matters systemically. Structural compilation can prove shape,
bounds, binding, references, and acyclicity. It cannot prove that supplied YAML
is data rather than requested work, that two prose analyses are semantically
independent, or that parallelism creates material leverage. Forcing every turn
through graph generation merely moves the same semantic decision into node and
edge generation while increasing false-positive risk for supplied data and
latency for ordinary turns.

The immediate and future acceptance surface therefore spans the entire chain:

> pre-admission evidence → policy decision → typed compile → durable frame →
> ready-set execution → terminal reduction → composition → delivery.

Content-free closed diagnostics must explain the outcome at each seam,
including why an apparently decomposable request was answered directly. Tests
should assert operator-owned semantic rules across multiple supplied-data,
single-task, independent-task, dependent-task, mixed-effect, refusal, timeout,
and malformed-plan scenarios. They should validate durable outcomes and
decision evidence, not exact prompts, model prose, punctuation regexes, or
source formatting. Real-provider operator qualification remains necessary
because a structurally perfect graph harness cannot establish semantic
admission quality.

This also narrows §12.4's de-risking inference. M9.b.4/M9.b.5 created concrete
Plan, Worker, and Report Interfaces with multiple structural Adapters, but the
adaptive-admission seam is not qualified until the attended FOV contract passes.
The existence of the Interfaces reduces implementation uncertainty; it does not
substitute architecture narrative or automated probes for operator evidence.

### 14.5 Derived prompts and learning remain reviewed, bounded work

Operator UX should not depend on prompt engineering. The operator states the
goal, constraints, and desired result; Allbert derives each manager, worker,
evaluator, and composer prompt from typed rules, the compiled plan, bounded
source context, current durable state, model-role policy, and the
`Models.PromptEnvelope` Interface. Prompts remain inspectable implementation
data with provenance, not the primary product Interface.

Likewise, an execution graph does not learn by running. Memory and Search may
supply bounded context and provenance to planning or evaluation, and objective
events, test metrics, traces, and explicit operator feedback may feed §6's
managed improvement job. That job may propose a typed, versioned delta to a
prompt rule, adaptive setting, model-role map, router descriptor, workflow, or
routine definition. Review, confirmation, audit, measurement, and one-click
revert remain required. It may never silently mutate graph topology, action
authority, permissions, confirmations, credentials, egress, or safety floors.

A generator/critic or evaluator/optimizer pair is therefore an optional
strategy Adapter with explicit budget and stop criteria, not the default
topology and never an authority-bearing judge. Deterministic validation should
handle deterministic facts. Model evaluation earns its cost only for semantic
criteria that local code cannot honestly decide.

### 14.6 Operator UX is the graph's acceptance Interface

Operators should not need graph terminology. Before meaningful multi-step work,
surfaces should explain in plain language what Allbert proposes, for example:
"two read-only analyses in parallel, then one joined architecture brief," with
estimated time/model use, effect and confirmation points, and the source of the
plan. During and after execution every surface should project the same durable
facts:

- routine/trigger provenance and graph version/digest;
- current, ready, running, blocked, and terminal work;
- dependency and join reasons rather than an undifferentiated spinner;
- confirmation points, retries, fallbacks, and partial-result treatment;
- pause, steer, resume, cancel, and inspect controls;
- the durable result, receipts, and evaluation outcome.

This provides leverage across TUI, Web, DMs, CLI, Jobs, and public protocols
while keeping locality in Objectives and the Surface Plane. A surface-private
graph, planner, or status store would fail the deletion test: removing it would
merely redistribute the same recovery and authority logic across every Adapter.

### 14.7 Release workflow as a design fixture, not new v1.3 scope

The release pain recorded across 1.1–1.3 is a strong future design fixture for
the same pattern:

```text
preflight
    |
    +-- implementation lanes --+
    +-- docs/drift audit -------+--> focused validation
                                      |
                              operator validation
                                      |
                         one authoritative aggregate
                                      |
                         package / sign / publish
```

An executable remediation should invalidate only its affected node and
downstream evidence; it should not force unchanged operator rows, packaging, or
the aggregate to repeat. This is the dependency-aware behavior the release
cadence now describes. The development workflow may use this as a harness and
evaluation fixture before a product execution-graph Interface exists; the
product must not become a prerequisite for releasing itself.

### 14.8 Net effect on the resolved recommendation

- No kernel concern, pack tier, phase, or release is added, removed, or
  resequenced.
- The future opportunity is one deep typed-graph Interface compiled into
  Objectives, not a second graph runtime or durable store.
- Jobs and ingress Adapters trigger; Objectives executes and recovers; Jido or
  plain OTP supplies bounded live lifecycle; Signals wake; surfaces project;
  Actions and Security Central retain effect authority.
- Static declarations precede dynamic model proposals. Both remain inert until
  deterministic compilation and ordinary authority checks succeed.
- Simple turns bypass graph machinery. Graph depth is earned by dependency,
  concurrency, checkpointing, recovery, or evaluation needs.
- Learning is a separate reviewed typed-delta loop, never autonomous
  self-modification.
- Phase 6 remains last and remains the place to generalize the Turn Engine's
  Plan/Worker/Report strategy Interfaces. Adding dependency-graph semantics
  still requires operator demand and an ADR amending ADR 0041/0083; the external
  research alone does not promote it.
