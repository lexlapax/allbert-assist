# Changelog

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
