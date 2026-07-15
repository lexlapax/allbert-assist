# Allbert 1.0 Public Contract Freeze Notes

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

Consumer counts are the number of first-party consumers at v1.0 (the "≥ 2 consumers"
Tier-1 rule is nominal against the compressed release timeline; newer surface area
defaults to Tier 2).

## Tier 1 — Frozen Public Contracts

| Contract | Consumers | Freeze policy |
|---|---|---|
| `AllbertAssist.Runtime.submit_user_input/1` + turn signals (`allbert.input.received`, `allbert.agent.responded`, `allbert.runtime.turn.started`, `allbert.runtime.turn.completed`) | every surface (web/CLI/TUI/channels) | frozen against rename/remove/shape-change |
| `AllbertAssist.Actions.Registry` + `AllbertAssist.Actions.Runner.run/3` + ADR 0065 `:invalid_params` response shape | every effectful action (258 registered) | frozen |
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
- Rollback: because the freeze is name-and-shape stable, a 1.x → 1.x downgrade keeps the
  Home readable for keys/columns present in the older release; keys added additively by a
  newer release are ignored by an older one. Pre-v0.66 Homes are compatibility notes unless
  a release note explicitly expands support.
- Uninstall preserves Allbert Home unless data removal is explicitly requested (DIT-5).
- Operator release-validation runbook: [release-rehearsal](../operator/release-rehearsal.md).

## Cross-links

- Plan: [`docs/plans/archives/v1.0-plan.md`](../plans/archives/v1.0-plan.md) (Tiered Public Contract Freeze,
  Freeze Enforcement).
- Reserved-vocabulary-not-frozen decision: ADR 0021 A20.
- Enforcement: `mix allbert.test release.v1` (`:v1` sweep).
- DIT freeze prerequisites: [`docs/validation/v1.0/`](../validation/v1.0/README.md).
