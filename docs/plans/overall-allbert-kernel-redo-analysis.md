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
> audited apply → measure effectiveness → one-click revert.

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
Drop `jido_ai`.**

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
  rule, and most state-bearing modules already are plain GenServers. The
  proposal formalizes the existing reality: the Turn Engine should be an
  explicit, plain, restartable OTP state machine with exactly one owner per
  resource. Given that 1.1 spent eight corrective rounds on resource-ownership
  faults and ended at `pool_size: 1`, deterministic single-ownership is worth
  more here than lifecycle hooks.
- **`jido_ai`** — used in two production call sites: model alias generation
  (`settings/provider_catalog.ex:124-131`) and dynamic-plugin codegen
  (`dynamic_plugins/codegen/llm.ex:49`, already guarded by
  `Code.ensure_loaded?/1`). `ReqLLM` is the actual model substrate, referenced by
  24 modules. One dependency and one refresh obligation per release for two call
  sites. Drop it and move alias generation into the model layer Allbert already
  owns.

Net: four Jido dependencies become two, and the kernel loop stops inheriting a
framework's supervision semantics at precisely the place with the most recorded
production pain.

---

## 9. Migration — Five Inversions, No Rewrite

Each phase is literally "move the list from the kernel to the owner of the
listed thing." Each ships value alone and is independently revertable.

| Phase | Change | Suggested placement | Rationale |
| --- | --- | --- | --- |
| **0** | Add a Credo check: no kernel file may name a capability module. It fails today; the failure list becomes the burn-down. | Anytime, small | The pattern already exists — `priv/credo_checks/settings_central_no_bypass.ex`. Makes the invariant enforceable before any code moves. |
| **1** | **Registry inversion.** Replace the `Actions.Registry` alias list with boot-time contribution. Action modules stay where they are; each subsystem grows a pack module listing its own actions. | Ride v1.5 | v1.5 already opens all 249 action modules for param contracts and envelope consolidation. One sweep instead of two. Highest-leverage insertion point in the current ladder. |
| **2** | **Settings inversion.** 463 keys become kernel keys plus pack-owned fragments; packs author their own schema rather than having it grouped out of a central module. | Ride v1.5 | v1.5 already builds the migration runner and moves telegram and email settings. Generalize rather than special-case. |
| **3** | **Gate inversion.** Packs own lanes; `release.vN` composes lanes. Retire the 43 historical gates behind one current gate plus archived definitions. | v1.5 M5 (already scoped as absolute suite duration) | Directly attacks the 47.7-minute aggregate and the six burned authoritative attempts. |
| **4** | **Projection primitive** extracted from Memory and Search. | Before v1.7 | Otherwise Knowledge becomes the third bespoke copy. |
| **5** | **OTP application extraction**, one pack at a time, cheapest first. | v1.6 onward, opportunistic | Only after 1–3, because 1–3 remove the reasons extraction is hard today. |
| **6** | **Turn Engine consolidation** — Runtime, IntentAgent, and Fanout into one staged loop with strategy behaviours. | Last, its own release | Highest risk. Use the v1.1 fan-out invariants as the acceptance set. |

Phases 0 through 3 fit inside v1.5 as currently scoped. Doing so changes v1.5's
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
  should stay optional until the invariant has held for two releases.
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

1. **Do phases 0–3 fold into v1.5?** This is the gating decision; v1.5 is the
   release that opens all 249 action modules, and that window does not reopen.
2. **Is `packs` the accepted term**, replacing the current plugin/app split, or
   should the existing `AllbertAssist.Plugin` vocabulary be extended in place?
3. **Does the projection primitive get extracted before 1.7**, accepting a
   schedule cost there, or does Knowledge ship bespoke and get folded later?
4. **Is dropping `jido_ai` acceptable** given its two production call sites, or
   is it retained for future Jido.AI-based specialist work?
5. **Should this proposal become an ADR** (pack contract and kernel inversion)
   plus concrete v1.5 milestone deltas, which is the form the process expects for
   a decision that constrains future design?

Until those are answered this document remains analysis, and the roadmap ladder
stands as written.
