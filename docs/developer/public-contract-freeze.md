# Allbert 1.0 Public Contract Freeze Notes

> **v1.4 authority transition (operator amendment 2026-08-07).** This v1.0
> inventory is the migration comparison while v1.4 builds the kernel/Pack
> boundary. `mix allbert.test release.v1` remains green through M15 and runs one
> final time beside `release.v14` at M17. Packaged M17 acceptance promotes the
> generated v1.4 component-owner/edge/selector baseline as the current test
> authority and retires `release.v1` from future default qualification. The
> transition does not authorize a breaking external Tier-1 change in 1.x:
> serializers and adapters preserve observable names/shapes unless a major
> version and ADR replace them.

This is the authoritative inventory of the public contracts frozen at v1.0
(`docs/plans/archives/v1.0-plan.md`, roadmap item 67). It is what plugin, app, channel, and
external-client authors may depend on across upgrades. The freeze is **tiered**:

- **Tier 1** — frozen public contracts. Rename, remove, and shape-change are forbidden
  after 1.0.
- **Tier 2** — stabilizing contracts. Frozen against rename/remove; **additive-only**
  changes are permitted post-1.0.
- **Not Frozen** — shapes that remain free to evolve post-1.0 without a contract break.

Enforcement is deterministic: `mix allbert.test release.v1` runs the `:v1` freeze sweep
(`apps/allbert_assist/test/security/v1_sweep_eval_test.exs`), which asserts every frozen
contract below still exists **by exact name**. Renaming or removing a frozen symbol fails
its row; Tier-2 additive changes stay green (the rows assert presence, not exhaustive
equality). See the plan's Freeze Enforcement section for the assertion primitives.
The promotion process is defined by
[ADR 0081](../adr/0081-tier2-to-tier1-promotion-process.md). v1.0.2 establishes
that process only; it promotes no current Tier-2 contract.

Consumer counts are the number of first-party consumers at v1.0 (the "≥ 2 consumers"
Tier-1 rule is nominal against the compressed release timeline; newer surface area
defaults to Tier 2).

## Tier 1 — Frozen Public Contracts

> **The Consumers column is as-of-1.0 and is not itself frozen (noted v1.4
> M17.a).** The counts in it have moved: "23 plugins" and "20 apps" were
> first-party consumer counts before the v1.4 extraction, and the tree now
> carries 14 modules using the plugin behaviour and 8 using the app behaviour,
> with `Plugin.Registry` deriving its set through
> `Pack.CompiledInventory.plugin_modules/1` rather than a static list. The rows
> are left as written because the *contract* each names is what is frozen, not
> its consumer census. Current ownership is in the v1.4 Component Contract
> Baseline below.

| Contract | Consumers | Freeze policy |
|---|---|---|
| `AllbertAssist.Runtime.submit_user_input/1` + turn signals (`allbert.input.received`, `allbert.agent.responded`, `allbert.runtime.turn.started`, `allbert.runtime.turn.completed`) | every surface (web/CLI/TUI/channels) | frozen against rename/remove/shape-change |
| `AllbertAssist.Actions.Registry` + `AllbertAssist.Actions.Runner.run/3` + ADR 0065 `:invalid_params` response shape | every effectful action in the generated registry inventory | frozen |
| Permission classes and safety floors (as of v0.59) via `AllbertAssist.Security.Policy` | Security Central + all actions | frozen against weakening; set may grow additively |
| Plugin contract (`AllbertAssist.Plugin` behaviour + Registry shape) | 23 plugins | frozen |
| App contract (`AllbertAssist.App` behaviour) | 20 apps | frozen |
| Settings Central schema **shape** + per-fragment `schema_version` contract (ADR 0046) | Settings Central + every fragment | shape frozen; individual keys evolve additively |
| Allbert Home layout (`AllbertAssist.Paths` `<ALLBERT_HOME>` roots) | runtime, memory, settings, artifacts, vault, db | frozen root names |
| Channel adapter boundary + identity-mapping shape (ADR 0016/0057): `conversation_threads.id`, `thread_channel_refs`, `conversation_message_refs`, `cross_channel_identity_links`, `owner_scope`, `receiver_account_ref`, `provider_thread_key` | 7 channel adapters | frozen; no second canonical conversation id |
| Resource Access `ResourceURI` shape, operation classes, and grant shape | resource-bearing actions | frozen |
| Model provider/doctor return shape (ADR 0047) | onboarding, `admin models doctor`, first-model path | frozen (roadmap acceptance-matrix item 2) |
| Installer-side cosign **fail-closed** verification (v0.64) | curl installer | trust/safety floor frozen against weakening |

## Tier 2 — Stabilizing Contracts (frozen with additive-only carve-outs)

| Contract | Consumers | Freeze policy |
|---|---|---|
| `AllbertAssist.App.SurfaceProvider` | 10 | rename/remove forbidden; additive components allowed |
| Surface DSL catalog + signed Fragment envelope shape | workspace catalog | rename/remove forbidden; adding components allowed under the registered fragment path |
| Workspace canvas + ephemeral persistence + SignalBridge validation | canvas/ephemeral surfaces | substrate + multi-consumer components frozen; single-emitter atoms not frozen by name |
| v0.38 templated creation: `AllbertAssist.Templates`, `AllbertAssist.Templates.Pattern`, actions `render_template`/`validate_template`/`scaffold_template`/`create_from_template`, `workspace:create` | template surface | rename/remove forbidden; adding patterns/params permitted |
| Template Settings keys `templates.create.enabled`, `templates.allowed_patterns` | template creation | frozen meaning; additive under ADR 0046 |
| v0.51 public-protocol surface policy: `mcp_server.*`, `openai_api.*`, `acp_server.*` Settings + default-off exposure + per-client token auth + self-approval denial + Runner routing | MCP/OpenAI/ACP surfaces | frozen against removal/weakening; wire details track upstream |
| v0.62 packaged-entry: `AllbertAssist.CLI.Commands.operator_table/0` taxonomy, three-tier `AllbertAssist.Settings.Vault` + `token_ref`, `/health` JSON shape + `AllbertAssist.Runtime.Attach` handshake | packaged binary, daemon, external clients | rename/remove/weaken forbidden; additive fields/commands/backends allowed |
| v0.65 local-knowledge: `notes_files` actions (`search_notes`/`read_note`/`write_note`), `set_notes_root` + `apps.notes_files.notes_root` key, memory review-status vocabulary (`:unreviewed`/`:kept`/`:flagged`/`:prune_nominated`) + `:kept`-only recall | notes/memory launch path | rename/remove forbidden; recall-eligible set may not expand beyond `:kept` without an ADR |

## v1.4 Component Contract Baseline

v1.4 did not change what most of the contracts above *are* — it changed **who
owns them**. Before v1.4 the 13 `plugins/` directories were compiled into
`allbert_assist` by path injection (no Mix project, no dependency isolation, no
independent test suite — ADR 0098's Context section), so the Tier 1/Tier 2 tables above
could name a contract without naming an owning application, because there was
effectively one. v1.4 (ADR 0098) replaces that with 17 OTP applications under a
compile-enforced kernel/pack boundary: a dependency-minimal `allbert_kernel`,
the transitional residual `allbert_assist`, two descriptorless composition/
interface hosts, and 13 extracted native packs. This section records, for each
contract already frozen above, which application answers for it today, and for
each application, its Pack identity and what it contributes. It contains no
artifact digest or signature — those are release-validation evidence in
`docs/validation/v1.4/`, generated *from* the exact source SHA this file is
part of, and recording them here would be self-referential.

**The invariant is compile-enforced, not linted.** `allbert_kernel`'s `mix.exs`
declares no `in_umbrella` dependency on `allbert_assist` or any named pack
(verified: its only deps are `exqlite`, `jason`, `jido_action`, `jido_signal`);
a kernel-to-pack edge would be a build failure, not a review finding
(ADR 0098 §2). Pack-to-pack edges are permitted and must be acyclic — e.g.
`allbert_browser` declares `{:allbert_research, in_umbrella: true}`. Module
names are independent of application names on the BEAM, so relocating
`AllbertAssist.Security` into `allbert_kernel` at M8 moved its source and owning
application without renaming the module or changing its public behaviour —
which is what makes relocation a `git mv`, not a rewrite.

### Contract → owning application

Owner-gate ids are the `owner_id` each application's `Pack.test_lanes/0` (or
`GateOwnerManifest.test_lanes/0`) declares. "Dependency edges" below are direct
declared `mix.exs` edges of the owning application, not a transitive closure.

| Contract (Tier) | Owning application | Owner gate | Dependency edges |
| --- | --- | --- | --- |
| `Runtime.submit_user_input/1` + turn signals (T1) | `allbert_assist` | `:core` | depends on `allbert_kernel`'s `Runtime.WriterLock`/`SafeTerm`/`Response` (moved at M8); consumed by every surface application |
| `Actions.Registry` + `Runner.run/3` + `:invalid_params` (T1) | `allbert_kernel` | `:kernel` | no outbound pack edge; consumed (inbound) by every effectful action in every one of the other 16 applications |
| Permission classes/safety floors, `Security.Policy` (T1) | `allbert_kernel` | `:kernel` | no outbound pack edge; consumed wherever `Actions.Runner` is consumed |
| Plugin contract (behaviour + Registry) (T1) | `allbert_assist` | `:core` | reads `priv/allbert_plugin.json` out of the 13 native packs' own app directories (a data read via `Application.app_dir/2`, not a compile edge) plus the `<ALLBERT_HOME>/plugins` compatibility scan root |
| App contract (`AllbertAssist.App` behaviour) (T1) | `allbert_assist` | `:core` | behaviour + `App.Registry` owned here; implemented directly via `use AllbertAssist.App` by `allbert_notes_files`, `allbert_browser`, `allbert_artifacts`, and `stocksage` in addition to residual-native `App` modules |
| Settings Central schema shape + `schema_version` (T1) | `allbert_assist` | `:core` | composes `settings_fragments/0` contributed by all 13 native packs plus 43 residual `Settings.FragmentOwners.*` modules declared in `Pack.Residual` |
| Allbert Home layout (`Paths`, `<ALLBERT_HOME>` roots) (T1) | `allbert_kernel` | `:kernel` | `home_roots/0` is a declared contribution seam on every pack; every pack (including the residual) currently contributes it empty — unexercised outside the kernel's own `Pack.Contracts.HomeRoots` |
| Channel adapter boundary + identity-mapping shape (T1) | `allbert_assist` (schema/runtime: `conversation_threads`, `thread_channel_refs`, `Channels.*`) | `:core` | the 7 channel adapters named in the Tier 1 row are each their own native pack (`allbert_telegram`/`allbert_email`/`allbert_discord`/`allbert_matrix`/`allbert_signal`/`allbert_slack`/`allbert_whatsapp`); **every one of those packs contributes `channels/0` empty** — channel registration still runs through the legacy `Plugin.channels/0` compatibility adapter (ADR 0098 §9) owned by `allbert_assist`'s `Plugin.Registry`, not through the native `Pack` contribution seam |
| Resource Access `ResourceURI` shape (T1) | `allbert_assist` | `:core` | `AllbertAssist.Resources` and children |
| Model provider/doctor return shape (T1) | `allbert_assist` | `:core` | `Settings.ModelDoctor` |
| Installer cosign fail-closed verification (T1) | *not an OTP application* | — | `scripts/install/install.sh` (release/packaging tooling outside the umbrella); no Pack or gate owner applies — recorded here as a contract this baseline cannot assign an application owner to, by design |
| `App.SurfaceProvider` (T2) | `allbert_assist` | `:core` | behaviour owned here; also implemented (`use AllbertAssist.App.SurfaceProvider`) by `allbert_notes_files` and `allbert_browser` |
| Surface DSL catalog + signed Fragment envelope (T2) | `allbert_assist` | `:core` | `Surface`, `Surface.Catalog`, `Surface.Encoder` |
| Workspace canvas + ephemeral persistence + SignalBridge (T2) | `allbert_assist` | `:core` | unmoved; part of the residual extraction queue's "not worth extracting at all" list |
| v0.38 templated creation (`Templates`, `Templates.Pattern`, actions) (T2) | `allbert_assist` | `:core` | unmoved |
| Template Settings keys (T2) | `allbert_assist` | `:core` | `Settings.FragmentOwners.Templates` |
| v0.51 public-protocol surface policy (`mcp_server`/`openai_api`/`acp_server`) (T2) | `allbert_assist` | `:core` | `Settings.FragmentOwners.{Mcp,McpServer,OpenaiApi,AcpServer,PublicProtocol}` |
| v0.62 packaged-entry (`CLI.Commands.operator_table/0`, three-tier `Vault`, `/health`, `Runtime.Attach`) (T2) | `allbert_assist` | `:core` | `allbert_composition`'s `ProductCLI`/`ProductBootstrap` orchestrate attach-first entry and delegate command classification/rendering down into this same residual `CLI` plan contract |
| v0.65 local-knowledge (T2) | **split** | — | `search_notes`/`read_note`/`write_note` actions and the notes `App` are owned by `allbert_notes_files` (`:notes_files`, native, `registry_order` 200); the `set_notes_root` action itself is **still residual** at `apps/allbert_assist/lib/allbert_assist/actions/settings/set_notes_root.ex` (`:core`); the memory review-status vocabulary (`:unreviewed`/`:kept`/`:flagged`/`:prune_nominated`) and `:kept`-only recall are wholly owned by `allbert_assist`'s `Memory` subsystem (`:core`) — this is the plan's explicit "do not extract Memory before v1.5" case |

### Per-application table

| Application | Pack id | Capability tier | `registry_order` | Contributes |
| --- | --- | --- | --- | --- |
| `allbert_kernel` | `allbert_kernel` | `:kernel` | 0 | descriptor only (every contribution callback empty); hosts `Pack.Descriptor`/`Row`/`Projection`/`RowSchemas`, `Actions.Registry`/`Runner`, `Security.Policy`, `Paths`, `Runtime.{WriterLock,SafeTerm,Response}` |
| `allbert_assist` (residual) | `allbert_assist` | `:native` | 100 | `settings_fragments/0` (43 modules), `kernel_contracts/0` (11 sealed adapters: `actions_overlay`, `confirmations`, `grants`, `home_roots`, `membership`, `release_availability`, `resource_refs`, `response_values`, `settings`, `signals`, `skills`), `test_lanes/0` (`:core`); everything not yet extracted — Runtime, Channels, Plugin/App registries, Resources, Memory, Settings store, CLI, Vault, Attach, Templates, Workspace/Surface, public-protocol surfaces |
| `allbert_assist_web` | *descriptorless* | n/a | n/a | Phoenix interface; hosts the generic `PackSurfaceLive` that routes any `AllbertAssist.Pack.WebSurface` implementer; `GateOwnerManifest` test lane `:web` |
| `allbert_composition` | *descriptorless* | n/a | n/a | `CompositionCoordinator`, `ProductBootstrap`, `ProductCLI`; declares the DAG edge that starts every required native pack (deliberately excludes `allbert_artifacts`/`stocksage`, which depend on `allbert_assist_web`, to avoid a `web → composition → pack → web` cycle); `GateOwnerManifest` test lane `:composition` |
| `allbert_notes_files` | `allbert_notes_files` | `:native` | 200 | `settings_fragments/0`, `cli_groups/0` (`admin notes`), `test_lanes/0`; manifest (`priv/allbert_plugin.json`) actions `search_notes`/`read_note`/`write_note` + `App` |
| `allbert_telegram` | `allbert_telegram` | `:native` | 300 | `settings_fragments/0`, `cli_groups/0` (`admin channels telegram`), `test_lanes/0`; manifest channel adapter |
| `allbert_email` | `allbert_email` | `:native` | 400 | `settings_fragments/0`, `cli_groups/0` (`admin channels email`), `test_lanes/0`; manifest channel adapter |
| `allbert_research` | `allbert_research` | `:native` | 500 | `settings_fragments/0`, `test_lanes/0` (no `cli_groups`); manifest research-delegate actions/app |
| `allbert_browser` | `allbert_browser` | `:native` | 600 | `settings_fragments/0`, `test_lanes/0`; manifest browser actions; depends on `allbert_research` (pack-to-pack edge) |
| `allbert_discord` | `allbert_discord` | `:native` | 700 | `settings_fragments/0`, `cli_groups/0`, `test_lanes/0` |
| `allbert_matrix` | `allbert_matrix` | `:native` | 800 | `settings_fragments/0`, `cli_groups/0`, `test_lanes/0` |
| `allbert_signal` | `allbert_signal` | `:native` | 900 | `settings_fragments/0`, `cli_groups/0`, `test_lanes/0` |
| `allbert_slack` | `allbert_slack` | `:native` | 1000 | `settings_fragments/0`, `cli_groups/0`, `test_lanes/0` |
| `allbert_tui` | `allbert_tui` | `:native` | 1100 | `settings_fragments/0`, `cli_groups/0` (`admin channels tui`), `test_lanes/0`; channel registration runs through legacy `AllbertTUI.Plugin.channels/0`, not `Pack.channels/0` |
| `allbert_whatsapp` | `allbert_whatsapp` | `:native` | 1200 | `settings_fragments/0`, `cli_groups/0`, `test_lanes/0` |
| `allbert_artifacts` | `allbert_artifacts` | `:native` | 1300 | `surfaces/0` (`AllbertArtifactsWeb.ArtifactLive` via `Pack.WebSurface`), `test_lanes/0`; depends on `allbert_assist_web` |
| `stocksage` | `allbert_stocksage` | `:native` | 1400 | `settings_fragments/0`, `surfaces/0` (`StockSageWeb.AnalysisLive` via `Pack.WebSurface`), `test_lanes/0`; depends on `allbert_assist_web`. Its pack id is `allbert_stocksage`, not `stocksage`: it is the one plugin whose legacy id carries no dotted prefix, so an app-named pack id would collide byte-for-byte with its own plugin id |

Every native pack's `apps/0` and `actions/0` callbacks are empty by construction:
contributions come from the pack's own `priv/allbert_plugin.json` manifest, and
declaring them a second time in `Pack` would contribute them twice.

### The `allbert_plugin.json` data-only declared-tier subset

`AllbertAssist.Plugin.Validator.normalize_manifest/2` (`apps/allbert_assist/lib/allbert_assist/plugin/validator.ex`)
is the single validator for both the compiled-pack manifest shape (e.g.
`apps/allbert_notes_files/priv/allbert_plugin.json`, source `:shipped`/`:project`,
code-bearing keys permitted) and the `:declared`-tier `<ALLBERT_HOME>/packs`
scan (source `:home`, code-bearing keys rejected — ADR 0098 §4 "Declared Home
packs"). The compatible data-only subset it normalizes to is exactly:

- `plugin_id`, `name`, `version`, `kind` — retained identity strings.
- `skill_paths` — retained, validated to stay inside the manifest's own root.
- `module` and any non-empty `contributions.apps|actions|channels|children` —
  for a `:home`-sourced manifest, presence of any of these fails validation
  with `:code_bearing_home_plugin` (`validate_code_bearing_manifest/3`); the
  manifest is rejected as a unit, not partially admitted.
- Everything else normalizes to inert: `module: nil`, `apps: []`,
  `channels: []`, `actions: []`, `children: :ignore`.

Parsing a `:declared` manifest never loads BEAM code, adds a supervision child,
or grants a permission by itself — it produces the same inert `Entry` struct a
rejected code-bearing manifest would have produced minus the contribution
lists. Existing trust, enablement, confirmation, and Security Central rules
still gate anything the (empty) contribution set could otherwise reach.

### Residual extraction queue

The residual's extraction queue is recorded in
[`docs/plans/v1.4-plan.md`](../plans/v1.4-plan.md) ("Residual extraction
queue — the v1.5/v1.6 intake artifact") and is not duplicated here. In brief:
the residual is 1,003 `.ex` files versus 396 across all 16 other applications
combined, its de-facto public surface is six residual-owned names
(`Settings`, `Channels`, `Runtime`, `Objectives`, `Conversations`,
`Confirmations`) none of which is kernel-owned, and every pack depends on
`allbert_assist` wholesale rather than on a narrower surface. The queue ranks
the Artifacts store first (destination already exists as `allbert_artifacts`),
finishing `allbert_tui` second, and explicitly holds `memory/` back from
extraction before v1.5 for the reason given in the local-knowledge contract
row above. ADR 0098 §1 binds the constraint this queue exists inside: the
residual "may receive compatibility fixes … but no new capability may choose
it as its architectural home."

## Explicitly Not Frozen At 1.0

- ADR 0021 reserved advisory-provider vocabulary (`WorldModelProvider`, … `RouteProvider`).
  Only the `IntentProvider` **role** is implemented — by `AllbertAssist.Intent.Classifier`
  (there is no module literally named `IntentProvider`). Recorded in
  [ADR 0021 A20](../adr/0021-intent-objective-capability-and-advisory-boundary.md).
- Workspace zone/destination names beyond ≥ 2 consumers — incl. `workspace:notes` /
  `workspace:memory` (their *actions* and review contract are frozen in Tier 2).
- Workflow YAML schema (still evolving via v0.47 self-improvement suggestions).
- MCP/OpenAI-compatible/ACP wire and tool shapes (Allbert tracks upstream specs).
- Internal AG-UI bridge semantic mappings (bridge stays internal-only at v1.0).

## Compatibility Guidance For Authors

- **Depending on Tier 1** — plugin/app/channel/external-client authors may depend on Tier 1
  names, shapes, and behaviours across all 1.x releases without churn. A Tier 1 change
  requires a new major version.
- **Depending on Tier 2** — depend on the *names* (they will not be renamed or removed in
  1.x), but expect **additive** growth: new components, patterns, parameters, Settings keys,
  `/health` fields, CLI commands, and vault backends may appear. Write forward-compatible
  consumers (ignore unknown additive fields; do not assume the set is closed).
- **Not Frozen** — do not build load-bearing integrations on Not-Frozen shapes (reserved
  advisory-provider vocabulary, workspace zone names, workflow YAML, protocol wire shapes,
  the AG-UI bridge); they may change without a contract break.

## Upgrade And Rollback

- Allbert Home is forward-compatible within 1.x under the Settings `schema_version` +
  additive-only policy (ADR 0046). A real `v0.66.0` packaged Home upgrades/imports into
  v1.0 with behaviour preserved (DIT-5); export/import is dry-run + rollback-safe
  (`AllbertAssist.Portability.Import.dry_run/2`).
- v1.4 remains additive-only and adds no runtime migration runner, preimage, or
  maintenance contract because ADR 0046 admission found no eligible consumer.
  In a future first qualifying carrier, any non-additive per-fragment migration
  must be an explicit operator operation with redacted preview, confirmation,
  preimage-backed rollback, and audit; it never runs automatically during boot.
- Rollback: an additive-only 1.x → 1.x downgrade keeps the Home readable for
  keys/columns present in the older release; keys added additively by a newer
  release are ignored by an older one. If a non-additive fragment migration is
  applied by a future qualifying carrier, the newer binary must explicitly restore its
  protected preimage/version before the older binary starts; the older binary
  never interprets a forward fragment or guesses rollback. Pre-v0.66 Homes are
  compatibility notes unless a release note explicitly expands support.
- Uninstall preserves Allbert Home unless data removal is explicitly requested (DIT-5).
- Operator release-validation runbook: [release-rehearsal](../operator/release-rehearsal.md).

## Cross-links

- Plan: [`docs/plans/archives/v1.0-plan.md`](../plans/archives/v1.0-plan.md) (Tiered Public Contract Freeze,
  Freeze Enforcement).
- Reserved-vocabulary-not-frozen decision: ADR 0021 A20.
- Migration enforcement through v1.4 M17: `mix allbert.test release.v1` (`:v1`
  sweep).
- Successor component/test authority: ADR 0098 and active v1.4 M15/M17;
  `release.v14` plus affected-component owner selection.
- DIT freeze prerequisites: [`docs/validation/v1.0/`](../validation/v1.0/README.md).
