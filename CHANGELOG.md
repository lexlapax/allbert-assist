# Changelog

## v0.14.3 - 2026-04-27

- replaced default semantic keyword routing with a bounded schema-validated intent router while preserving `intent_classifier.rule_only = true` as the legacy compatibility path
- added router-drafted schedule actions that enter the existing durable job preview/confirmation flow before full prompt assembly
- hardened conversational scheduling with flat named-call normalization, a schedule-specific prose-confirmation retry, bounded trace provenance, and a safe `allbert-cli jobs upsert <job-definition.md>` fallback
- added router-drafted explicit-memory staging for high-confidence `remember that ...` requests while preserving review-first promotion and rejection
- repaired OpenAI Responses request mapping so user text uses `input_text`, assistant history uses `output_text`, user images remain `input_image`, and assistant-side image attachments fail locally
- hardened Gemini response parsing for live responses with non-text parts and raised the Gemini credentialed smoke output budget for Gemini 2.5 hidden thinking
- bumped all crates and lockfile package entries to `0.14.3`

More detail: [v0.14.3 upgrade notes](docs/notes/v0.14.3-upgrade-2026-04-27.md), [v0.14.3 plan](docs/plans/v0.14.3-operator-reliability.md), [operator feature test runbook](docs/operator/feature-test-runbook.md), [ADR 0030](docs/adr/0030-intent-routing-is-a-kernel-step-not-a-skill-concern.md), [ADR 0096](docs/adr/0096-tool-call-parser-accepts-schema-variants.md), and [ADR 0066](docs/adr/0066-owned-provider-seam-over-rig-for-v0-10.md).

## v0.14.2 - 2026-04-26

- retired the monolithic `allbert-kernel` crate and moved workspace imports to direct `allbert-kernel-core` and `allbert-kernel-services` crates
- added enforceable kernel size, crate-graph, import-migration, and dependency compactness gates
- kept `allbert-kernel-services/src/` below the <30,000 LOC gate by deduplicating core-owned contracts and preserving the large runtime unit suite as compiled crate-local test support
- hardened default-parallel daemon integration tests against the local socket `Operation not permitted` boot flake
- updated self-improvement source-checkout validation and release docs for the new core/services source layout
- bumped all crates and lockfile package entries to `0.14.2`

More detail: [v0.14.2 upgrade notes](docs/notes/v0.14.2-upgrade-2026-04-26.md), [v0.14.2 plan](docs/plans/v0.14.2-kernel-core-services.md), [ADR 0100](docs/adr/0100-kernel-splits-into-core-and-services.md), [migration inventory](docs/notes/v0.14.2-migration-inventory-2026-04-26.md), [daemon socket reliability note](docs/notes/v0.14.2-daemon-socket-reliability-2026-04-26.md), and [size gate resolution note](docs/notes/v0.14.2-size-gate-resolution-2026-04-26.md).

## v0.14.1 - 2026-04-26

- added a doc-reality gate that fails validation when shipped plans/docs overclaim implementation status without explicit `partial`, `planned`, `reconciled`, `scaffolded`, or `Status: Stub` wording
- made the tool-call parser tolerant of the schema variants emitted by local-default Ollama/Gemma4, including `input`/`arguments`, nested `function`, direct `program`/`args`, one corrective retry, and active skill/exec-policy authorization before direct spawns
- wired daemon protocol v5 adapter handlers to the disk-backed adapter store for list/show/activate/deactivate/remove/status/history/install, plus daemon-owned run ids and cancellation tokens for training starts
- added the production adapter trainer factory so enabled training uses the configured or request-selected backend, fails closed when disabled/missing/disallowed, and reserves fake for explicit fake configuration or tests
- upgraded self-diagnosis remediation to request bounded candidate fixes through the attached daemon provider when available, record normal cost-ledger entries, preserve offline/provider/cost fallback metadata, and route code/skill/memory candidates through existing review surfaces only
- bumped all crates and lockfile package entries to `0.14.1`

More detail: [v0.14.1 upgrade notes](docs/notes/v0.14.1-upgrade-2026-04-26.md), [v0.14.1 plan](docs/plans/v0.14.1-vision-alignment.md), [Personalization guide](docs/operator/personalization.md), and [Self-diagnosis and local utilities guide](docs/operator/self-diagnosis-and-utilities.md).

## v0.14.0 - 2026-04-26

- shipped bounded self-diagnosis over v0.12.2 trace artifacts with report artifacts under session diagnostics directories
- added the first-party `self-diagnose` skill and report-only `self_diagnose` tool, with remediation refused unless explicit config and command intent are present
- routed optional code, skill, and memory remediation through existing `patch-approval`, skill quarantine, and staged-memory review surfaces; concrete candidate generation was reconciled in v0.14.1
- added protocol v6 diagnosis and local-utility messages, `ActivityPhase::Diagnosing`, daemon filtering for older v2-v5 peers, and daemon-backed CLI/REPL/TUI surfaces
- added `allbert-cli diagnose run|list|show` plus REPL/TUI `/diagnose` and structural Telegram `/diagnose last`
- added the curated local-utility catalog, host-specific `utilities/enabled.toml`, utility drift status, and `allbert-cli utilities discover|list|show|enable|disable|doctor`
- added the bounded `unix_pipe` direct-spawn tool for enabled utility ids, with text I/O caps and no shell-string parsing
- added setup and settings support for self-diagnosis/local utilities, including configurable `unix_pipe` limits and `CURRENT_SETUP_VERSION = 6`
- updated profile export dry-run and continuity docs so `utilities/enabled.toml` is named as host-specific and excluded by default
- bumped all crates and lockfile package entries to `0.14.0`

More detail: [v0.14 upgrade notes](docs/notes/v0.14-upgrade-2026-04-26.md), [v0.14 plan](docs/plans/v0.14-self-diagnosis.md), [Self-diagnosis and local utilities guide](docs/operator/self-diagnosis-and-utilities.md), [Tracing guide](docs/operator/tracing.md), and [Self-improvement guide](docs/operator/self-improvement.md).

## v0.13.0 - 2026-04-26

- shipped review-first local personalization with `PersonalityAdapterJob`, protocol v5 adapter messages, and live `ActivityPhase::Training`; daemon adapter handlers were reconciled in v0.14.1
- added the owned `AdapterTrainer` seam with mlx-lm-lora, llama.cpp, and deterministic fake trainer backends behind both `learning.adapter_training.allowed_backends` and `security.exec_allow`; production real-backend trainer selection was reconciled in v0.14.1
- added adapter corpus assembly from `SOUL.md`, accepted `PERSONALITY.md`, approved durable/fact memory, bounded episode summaries, and opt-in redacted v0.12.2 trace excerpts
- added `adapter-approval` inbox items with eval summary, loss curve, behavioral diff artifacts, and accept/reject handling; accepting installs but does not activate
- added explicit single-slot local activation for Ollama, base-model pinning, automatic incompatible-model deactivation, and hosted-provider one-shot ignore notices
- added `allbert-cli adapters ...`, REPL/TUI `/adapters`, Telegram `/adapter status` and `/adapter approvals`, adapter telemetry, and a status-line adapter item
- added setup and settings support for local personalization, including safe `[learning.adapter_training]` default-write for upgraded profiles
- updated profile export so adapter artifacts are excluded by default and `--include-adapters` includes only installed adapters plus `active.json`
- hardened adapter corpus privacy with trace redaction double-pass tests and staged-memory exclusion
- bumped all crates and lockfile package entries to `0.13.0`

More detail: [v0.13 upgrade notes](docs/notes/v0.13-upgrade-2026-04-26.md), [v0.13 plan](docs/plans/v0.13-personalization.md), [Personalization guide](docs/operator/personalization.md), [Personality digest guide](docs/operator/personality-digest.md), and [Telemetry guide](docs/operator/telemetry.md).

## v0.12.2 - 2026-04-25

- shipped durable session-local trace artifacts under `sessions/<session-id>/trace.jsonl`, with rotated trace archives and in-flight span recovery
- added protocol v4 trace read/tail/list responses while keeping v4 daemons compatible with v2 and v3 clients through per-peer filtering
- added `allbert-cli trace show|tail|list|show-span|export|gc` plus REPL/TUI `/trace` commands and structural Telegram `/trace last` / `/trace span` summaries
- added file-based OTLP-JSON export under `ALLBERT_HOME`, aligned for external observability tools without adding any network exporter
- made trace capture useful by default with `capture_messages = true`, bounded disk caps, finite retention, and per-field `capture|summary|drop` policies
- hardened trace privacy with unconditional secret redaction at write/export time, read-only `trace.redaction.secrets = "always"`, and provider/SDK key coverage tests
- added the trace settings group, guided setup trace step, safe existing-profile `[trace]` default-write, and `/settings show trace`
- updated operator tracing docs and upgrade guidance for capture posture, redaction, retention, GC, and export
- bumped all crates and lockfile package entries to `0.12.2`

More detail: [v0.12.2 upgrade notes](docs/notes/v0.12.2-upgrade-2026-04-25.md), [v0.12.2 plan](docs/plans/v0.12.2-tracing-and-replay.md), [Tracing guide](docs/operator/tracing.md), [Telemetry guide](docs/operator/telemetry.md), and [TUI guide](docs/operator/tui.md).

## v0.12.1 - 2026-04-25

- shipped daemon-owned live activity snapshots over protocol v3, with backward-compatible v2 filtering and shared `/activity`/`allbert-cli activity` surfaces
- made the TUI responsive during in-flight turns with activity status, spinner/caret behavior, next-turn draft buffering, separated modal input, and richer local review commands
- added the typed settings hub with path-preserving TOML writes, grouped command descriptors, CLI examples, slash typo suggestions, argument hints, and remediation hints for common operator-facing errors
- added bounded approval context across TUI, REPL, CLI, and Telegram, including patch-preview context while keeping full diffs artifact-backed and install separate
- added recovery affordances for durable-memory trash/restore, staged-memory reject/reconsider, installed-skill enable/disable, and `config.toml.last-good` restore
- improved Telegram with `/activity`, compact `/status`, typing indication, markdown-aware replies, and clearer approval feedback
- updated operator docs for TUI, telemetry/activity, adaptive-memory recovery, skill enablement, self-improvement review, continuity/config recovery, and Telegram
- bumped all crates and lockfile package entries to `0.12.1`

More detail: [v0.12.1 upgrade notes](docs/notes/v0.12.1-upgrade-2026-04-25.md), [v0.12.1 plan](docs/plans/v0.12.1-operator-ux-polish.md), [TUI guide](docs/operator/tui.md), [Telemetry guide](docs/operator/telemetry.md), and [Telegram guide](docs/operator/telegram.md).

## v0.12.0 - 2026-04-25

- shipped review-first self-improvement with source-checkout detection, sibling worktrees, disk-cap-aware GC, and path isolation for rebuild proposals
- added the `rust-rebuild` proposal flow and `patch-approval` inbox kind, with diff artifacts stored outside approval markdown
- added `allbert-cli self-improvement config show|set`, `diff`, `install`, and `gc`; install applies accepted patches to the source checkout and never swaps the running binary
- added append-only self-improvement install history under `~/.allbert/self-improvement/history.md`
- added skill provenance (`external`, `local-path`, `git`, `self-authored`) to previews, installed-skill inspection, and `skills list`
- hardened `create_skill` with explicit `skip_quarantine`; prompt-authored skills write to `skills/incoming/` and first-party seeding remains the only direct install path
- shipped the first-party `skill-author` natural-language authoring skill and seeded it on first run with first-party install metadata
- added the `ScriptingEngine` trait and opt-in Lua 5.4 engine with JSON-only IO, synthetic `exec.lua:<skill>/<script>` hook events, stdlib allowlist, deny floor, and execution/memory/output caps
- documented the end-user trust posture in self-improvement, skill-authoring, and scripting operator guides
- reconciled ADRs and the v0.12 plan with the shipped Lua 5.4 sandbox implementation
- bumped all crates and lockfile package entries to `0.12.0`

More detail: [v0.12 upgrade notes](docs/notes/v0.12-upgrade-2026-04-25.md), [v0.12 plan](docs/plans/v0.12-self-improvement.md), [self-improvement guide](docs/operator/self-improvement.md), [skill authoring guide](docs/operator/skill-authoring.md), and [scripting guide](docs/operator/scripting.md).

## v0.11.0 - 2026-04-25

- shipped the Ratatui/Crossterm TUI as the default interactive surface for fresh profiles, with classic Reedline REPL fallback for upgraded profiles and terminal escape hatches
- added kernel-owned session telemetry across daemon protocol, CLI JSON, REPL/TUI slash commands, and configurable TUI status-line items
- added memory visibility commands for stats and routing, including `/memory stats`, `/memory routing`, `allbert-cli memory stats`, and `allbert-cli memory routing show|set`
- made `memory-curator` always eligible by default while keeping full skill activation governed by configurable routing policy
- added explicit episode and fact search tiers while preserving the v0.5 rule that staged memory and session history are not approved durable memory
- added temporal fact metadata, provenance, and supersession posture for staged/promoted memory
- added an optional semantic retrieval seam that stays disabled by default and ships with a fake deterministic provider for provider-free validation
- added the review-first `LearningJob` seam and `personality-digest` job, including deterministic draft generation, hosted-provider consent posture, atomic accepted install, and `PERSONALITY.md` as a lower-authority learned overlay
- documented the `SOUL.md` versus `PERSONALITY.md` authority boundary across operator docs, ADRs, roadmap, and vision
- accepted ADRs 0074-0080 for TUI boundaries, telemetry ownership, memory routing, episode/fact posture, semantic retrieval, personality digest, and self-change artifact envelopes
- bumped all crates and lockfile package entries to `0.11.0`
- added focused operator docs for TUI, telemetry, adaptive memory, and personality digest, plus v0.11 upgrade and readiness notes

More detail: [v0.11 upgrade notes](docs/notes/v0.11-upgrade-2026-04-24.md), [v0.11 release readiness](docs/notes/v0.11-release-readiness-2026-04-25.md), and [v0.11 plan](docs/plans/v0.11-tui-and-memory.md).

## v0.10.0 - 2026-04-24

- expanded the owned provider seam with direct OpenAI, Gemini, and local Ollama support while preserving Anthropic and OpenRouter
- changed fresh-profile defaults to local-first Ollama with `gemma4` and `http://127.0.0.1:11434`
- allowed keyless local-provider configuration with optional `api_key_env` and provider-specific `base_url`
- added setup, config, CLI, and REPL support for switching among Anthropic, OpenRouter, OpenAI, Gemini, and Ollama providers
- preserved existing profile compatibility for Anthropic/OpenRouter configs and session-local `/model` switching
- documented the provider-framework decision in ADR 0066 and kept provider behavior kernel-owned for cost logs, daemon protocol, jobs, skills, and channel capability checks
- updated README, onboarding, roadmap, vision, and upgrade docs for the v0.10 local-first release posture

More detail: [v0.10 upgrade notes](docs/notes/v0.10-upgrade-2026-04-24.md) and [v0.10 plan](docs/plans/v0.10-provider-expansion.md).

## v0.9.0 - 2026-04-24

- promoted v0.9 as the current source-based end-user release
- carried forward the shipped v0.8 runtime surface without adding a profile migration
- added the pinned Rust `1.94.0` contributor toolchain and required `rustfmt`/`clippy` components
- added `DEVELOPMENT.md`, repo-level `AGENTS.md`, and `.env.example` for reproducible contributor setup
- documented Tier A provider-free validation and optional Tier B live-provider checks
- documented Codex Web as an ephemeral contributor workspace, not hosted Allbert runtime
- clarified the portable temp-home `daemon status` smoke and optional local daemon lifecycle smoke

## v0.8.0 - 2026-04-23

- shipped cross-channel continuity with `identity`, `sessions`, and daemon-backed inbox commands
- added first-class `cost-cap-override` and `job-approval` inbox flows with cross-surface resolution
- shipped `profile export|import` plus explicit continuity/sync operator docs
- added `HEARTBEAT.md` runtime consultation for proactive check-ins, quiet hours, and inbox nags
- hardened continuity-bearing writes around a shared atomic-write helper and regression guardrail
- aligned README, onboarding, roadmap, vision, and operator docs with the shipped v0.8 surface

Earlier release notes remain under `docs/notes/`.
