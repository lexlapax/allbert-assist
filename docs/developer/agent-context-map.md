# Agent Context Map

This is the lazy-loaded routing map for coding agents. It points to the first
documents to read when the active plan and local code are not enough. It is not a
release history mirror; use `CHANGELOG.md` for shipped details and
`docs/plans/roadmap.md` for the version sequence.

## How To Use

1. Read `AGENTS.md`, `DEVELOPMENT.md`, the roadmap, the active plan, the matching
   request-flow, and relevant ADRs first.
2. Use the table below to find the subsystem's anchor docs.
3. Read targeted changelog entries only when released behavior or regression
   history matters.
4. Prefer code and tests over stale prose. Flag conflicts.

## Subsystem Routing

| Area | Start with | Notes |
| --- | --- | --- |
| Runtime, signals, action runner | ADR 0001, ADR 0007, active plan, `docs/developer/runtime-boundary-map.md` | Runtime and actions are the spine; LiveView is a surface. |
| Security, permissions, confirmations, redaction | ADR 0006, ADR 0007, ADR 0008, ADR 0012, active plan | Security Central is the authority boundary. |
| Settings Central | ADR 0004, ADR 0031, ADR 0046, active plan | Operator-tunable config goes through Settings Central; v0.58 enforces access, v0.59 adds the version contract, additive-only enforcement, and fail-closed boot check. |
| Local execution, shell, packages, external services | ADR 0009-0013, relevant plan | OTP is not an OS security boundary; host effects require policy and confirmation. |
| Identity, users, conversations, session scratchpad | ADR 0014, ADR 0057, active plan | IDs and sessions are context, not authority. |
| Objectives and long-running work | ADR 0021, `docs/plans/v0.24-plan.md`, `docs/research/objective-runtime-research.md` | Use shared objective runtime; no private durable goal loops. |
| Apps, plugins, surfaces, catalog | ADR 0015, ADR 0017, ADR 0023, ADR 0024, ADR 0030 | App metadata and descriptors do not grant authority. |
| Web workspace and design system | ADR 0023, ADR 0024, ADR 0074, `docs/developer/web-design-system.md`, `docs/operator/workspace.md` | v0.58 makes chat primary and folds pages into one shell/catalog system. |
| Cross-surface consistency | ADR 0073, `docs/developer/surface-contract.md`, `docs/plans/v0.58-plan.md` | One renderer, event/audit by `surface_id`, identity resolution, action-backed reads. |
| Channels and external identity | ADR 0016, ADR 0056-0059, channel plans, `docs/developer/channel-parity.md` | Adapter identity maps are explicit; channel primitives stay constrained. |
| TUI operator console | ADR 0070, ADR 0067, `docs/operator/tui-channel.md`, v0.55.1 docs | Warm TUI slash commands are operator-only reads through registered actions. |
| Pi-mode coding surface | ADR 0068, ADR 0067, ADR 0056, `docs/operator/pi-mode-coding.md`, v0.57 docs | Gated coding surface; six-tool default; no YOLO-default or generated-code-session default. |
| Intent routing and descriptor lifecycle | ADR 0019, ADR 0034, ADR 0060-0062, ADR 0071, v0.54-v0.56 docs | Intent routing is advisory; ADR 0071 gate blocks regressing promotion. |
| Model recommendations | ADR 0072, `docs/operator/model-recommendations.md`, v0.56 docs | Recommendations inform operators; they do not grant authority. |
| Public protocol surfaces | ADR 0044, ADR 0055, `docs/developer/public-protocol-surfaces.md`, `docs/operator/public-protocol-surfaces.md`, v0.51 docs | MCP/OpenAI/ACP inbound uses public-surface trust and deny-before-allow exposure. |
| MCP client integration | ADR 0038, ADR 0048, `docs/developer/mcp-client.md`, v0.40/v0.42 docs | Outbound MCP uses confirmed external capability and resource policy. |
| Browser and web research | ADR 0040, browser plugin docs, `docs/operator/browser-and-research.md` | Browser actions are plugin-owned and policy-bounded. |
| Artifacts Central and browser | ADR 0053, ADR 0054, `docs/developer/artifact-store.md`, `docs/operator/artifacts-central.md`, `docs/operator/artifacts-browser.md` | Artifact identity and bytes never grant permission. |
| Provider capabilities, voice, vision, image | ADR 0051, ADR 0042, provider/media operator docs, v0.48-v0.49 docs | Real configured endpoints for operator acceptance; fakes are test fixtures only. |
| Plan/Build workflows | ADR 0041, `docs/developer/plan-build.md`, `docs/operator/plan-build-and-workflows.md` | YAML is closed grammar and advisory until confirmed. |
| Marketplace and templates | ADR 0036, ADR 0043, marketplace/template docs, v0.38/v0.45 docs | Installs are reviewed, disabled/untrusted until approved. |
| Dynamic code and plugin drafts | ADR 0032, ADR 0033, ADR 0035, ADR 0037, dynamic-plugin docs | Only sandbox/gate plus confirmed loader can integrate live code. |
| Self-improvement | ADR 0045, self-improvement docs, v0.47/v0.47b docs | Discovery and drafts are inert until existing confirmed paths promote them. |
| StockSage | ADR 0018, ADR 0020, ADR 0022, StockSage plans/changelog | Plugin-owned domain; Python bridge is comparison/reference after native work. |
| Test strategy and gates | ADR 0049, ADR 0050, `docs/developer/test-strategy.md`, `DEVELOPMENT.md` | Lane classification and release-gate evidence live there. |

## Current Release Arc

| Version | Routing summary | Primary docs |
| --- | --- | --- |
| v0.50 / v0.50.1 | Artifacts Central and Artifacts Browser. | ADR 0053/0054, artifact docs, v0.50/v0.50b plans. |
| v0.51 | Public protocol surfaces: MCP tools/resources, OpenAI-compatible HTTP, ACP, inbound trust. | ADR 0044/0055, public-protocol docs, v0.51 plan/request-flow. |
| v0.52 | Discord/Slack plus cross-channel threading substrate. | ADR 0016, ADR 0056/0057, v0.52 docs. |
| v0.53 | Channel pack expansion and channel primitive decisions. | ADR 0058/0059/0066, v0.53 docs. |
| v0.54 | Two-stage intent router and descriptor lifecycle foundation. | ADR 0060-0064, v0.54 docs. |
| v0.55 | Channel parity matrix and basic TUI channel, with split `model_payload`/`surface_payload`. | ADR 0016, ADR 0067, v0.55 docs. |
| v0.55.1 | TUI operator/validation console with read-only slash allowlist. | ADR 0070, v0.55b docs, `docs/operator/tui-channel.md`. |
| v0.56 | Intent descriptor learning, ADR 0071 routing-accuracy gate, ADR 0072 model recommendations, operator-action layer. | ADR 0062, ADR 0070-0072, v0.56 docs. |
| v0.57 | Pi-mode coding surface on the one authority spine. | ADR 0068, v0.57 docs, `docs/operator/pi-mode-coding.md`. |
| v0.58 | Released pre-1.0 consolidation: cross-surface contract (one renderer, events/audit by `surface_id`, identity resolution, action-backed reads), Settings Central enforcement, web design system, operator panels, surface policy, and redundancy cleanup. | ADR 0073/0074, ADR 0024 revision, `docs/developer/surface-contract.md`, `docs/developer/web-design-system.md`, `docs/operator/workspace.md`, v0.58 docs. |
| v0.59 | Released hardening substrate: dry-run-only Allbert Home portability, Settings version contract (ADR 0046; runner deferred), ADR 0065 central param contracts, security sweep, perf/CSP baseline, and RC-substrate handoff. No onboarding or final RC. | ADR 0046/0065, v0.59 docs, `release.v059`. |
| v0.60 | Validation complete and release-ready for `v0.60.0`; post-implementation remediation M8.1-M8.4 and M9.1-M9.6 plus operator validation S0-S6 passed before tag. Pre-1.0 product-experience design (design-first): information architecture, user journeys, onboarding-flow, persona, and entry-point design, the First-Model Path decision, and a walking skeleton. No shipped capability beyond the skeleton scaffold. | ADR 0077, ADR 0078, v0.60 docs, `release.v060`. |
| v0.60b (0.60.1) | Planned pre-1.0 design point release: Visual Design Language & Art Direction — the visual-direction parallel to v0.60's structural design. Produces at least three divergent candidate visual/UX design directions (rendered hero screens), evaluates them against a rubric, and has the operator choose one canonical language that v0.61 implements. Design-only; no shipped capability; does not renumber v0.61-v0.64. | ADR 0079, v0.60b docs, `release.v060b`. |
| v0.61 | Planned pre-1.0 product: Presentation Layer Overhaul — redesigned IA and screen composition rendered in the v0.60b-chosen visual language, brand, motion, visual hierarchy, landing/marketing over the v0.58 design system. | ADR 0074 v0.61 amendment, ADR 0079, v0.61 docs. |
| v0.62 | Planned pre-1.0 product: packaged `allbert` binary, unified CLI, daemon, ADR 0070 TUI convergence, OS secret-vault. | ADR 0076, ADR 0070, v0.62 docs. |
| v0.63 | Planned pre-1.0 product: guided onboarding wizard + repo-maintained user-category profiles/personas over the packaged entry points. | ADR 0069 (re-scoped), ADR 0075, v0.63 docs. |
| v0.64 | Planned product RC: integrated install, serve, onboard, first chat, browser/CLI/TUI, integration, export/import or upgrade, uninstall, and evidence validation. | v0.64 docs. |
| v1.0 | Contract freeze + product launch after v0.64 (extended product acceptance matrix). | v1.0 plan/request-flow and roadmap. |

## Older History Pointers

Use these ranges instead of loading old plans broadly:

| Range | What it established |
| --- | --- |
| v0.01-v0.14 | Runtime loop, signals, memory, traces, security baseline, confirmations, local identity, jobs, session scratchpad. |
| v0.15-v0.24 | App/plugin/channel contracts, StockSage foundation, memory review, Python bridge, Jido substrate, objectives. |
| v0.25-v0.32 | Native StockSage specialists, workspace/canvas substrate, security hardening, catalog/registry/settings consolidation, `/workspace` as operator home. |
| v0.33-v0.39b | Conversational handoff, workspace UX refresh, theming, sandbox/gate, dynamic drafts, templates, onboarding/provider control, identity memory. |
| v0.40-v0.49 | MCP client, developer gates, tool discovery, browser/research, workflows, marketplace, delegation, self-improvement, providers, voice, vision, image. |

## Test And Gate Quick Reference

Use `docs/developer/test-strategy.md` for the full contract.

| Need | Gate |
| --- | --- |
| Docs-only patch | `git diff --check`; run `MIX_ENV=test mix allbert.test docs` when relevant. |
| Quick pure/local check | `mix allbert.test fast-local` |
| High-coverage local check | `mix allbert.test fast-local --core-lanes --stocksage-lanes --web-lanes --partitions N` |
| Release handoff | `mix allbert.test release` or the version-specific release lane. |
| v0.58 release readiness | `mix allbert.test release.v058` and request-flow S0-S6 operator validation passed during M15 closeout. |
| v0.59 release readiness | `mix allbert.test release.v059`, standalone `MIX_ENV=test mix dialyzer`, SQLite startup-lock evidence scan, and request-flow S0-S8 operator validation passed during closeout. |

Primary lane labels: `pure_async`, `db_serial`, `db_partition_safe`,
`app_env_serial`, `home_fs_serial`, `global_process_serial`, `liveview_serial`,
`security_eval_serial`, and `external_runtime_serial`.

## Version specific Guidance

This section holds temporary in-flight guidance while a specific version is being
planned and implemented. It is cleared at release closeout; add the next version's
working notes here when that work begins.
