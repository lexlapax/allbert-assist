# Changelog

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
