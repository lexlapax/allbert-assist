# ADR 0076: Packaging, Distribution & Unified CLI Entry Points

Status: Proposed (v0.62; accepted at the v0.62 request-flow S8 sign-off).
Date: 2026-06-25 (amended 2026-07-05 by the v0.62 implementation-readiness
pass: Bakeware struck as archived, CLI process model + vault tiering + First-
Model-Path execution authority recorded, Distribution Trust section added).
Related: ADR 0077 (Product Experience Design & IA — designs the entry-point / CLI
UX in v0.60 M5; this release implements it in v0.62), ADR 0078 (First-Model Path —
its chosen option requires detecting/guiding Ollama setup and managing a curated
model pull, without bundling the Ollama runtime into the packaged artifact),
ADR 0070 (TUI operator console — this completes its mix-free
convergence), ADR 0067 (TUI/terminal channel), ADR 0004 / ADR 0031 (Settings
Central), ADR 0069 (onboarding — v0.63 builds on the entry points and vault
model defined here), ADR 0006 (Security Central — packaging changes how Allbert
is installed and invoked, not what any surface may do), and the Allbert Home
layout decisions. Anchors the v0.62 Packaging & Entry Points release.

## Context

Allbert is **mix-only** today. The v0.58 maturity review confirmed: no escript, no
`releases:`, no Burrito/Bakeware, no `rel/`, no install script, no Homebrew, no
Docker. A new user needs a git checkout plus the full Elixir/OTP toolchain, and
the start path is `mix setup` → `mix phx.server` / `mix allbert.onboard`. There
are 55 flat Mix task modules at the 2026-07-05 readiness review (46 core + 9
plugin; "53" was the v0.58 count), with no unified binary, no grouped `--help`,
and operator commands intermixed with developer/CI commands.

For the technical-prosumer 1.0 audience, the toolchain requirement is the
**dominant adoption blocker** — the exact friction that gets powerful-but-
Docker/dev-required tools penalized in every 2026 comparison, while packaged
binaries with one-command install (LM Studio, Jan, OpenClaw, Hermes) win on
first value. This release reshapes Allbert Home layout and entry points before
guided onboarding and the v0.64 product RC lock in the first-run flow.

## Decision

1. **Packaged `allbert` binary.** Ship a release-built artifact (OTP release
   with ERTS bundling — the v0.62 M0 spike chooses between Burrito 1.5.x and a
   hand-wrapped release; **Bakeware is struck: archived upstream 2024**) so no
   Elixir/OTP is required on the user's machine, distributed via **Homebrew**
   and a **curl install script**. Artifacts are **built natively per target
   triple in CI** — cross-compilation is not viable for this dependency tree
   (rebar3-built `erlexec` and the `muontrap`/`erlexec` port *executables* are
   invisible to or mis-built by NIF-oriented cross recompilation).
2. **Unified grouped CLI dispatcher.** A single `allbert <group> <command>`
   surface — `ask | chat | tui | serve | admin <area> | gen`, plus the
   bare-`allbert` first-run/resume dispatcher from the design artifact —
   subsuming the flat mix-task sprawl, with coherent grouped help.
   **Process model (operator decision 2026-07-05): attach-first** — commands
   connect to a running daemon over a local attach transport; an embedded
   runtime boots only when no daemon runs, under single-writer discipline
   (never two BEAM writers on one SQLite file). Operator commands are separated
   from developer/CI commands; the latter stay `mix`-only. The entry-point and CLI
   *UX* (group/command shape, help layout, first-invocation experience) is designed
   in the v0.60 Product Experience Design release (ADR 0077 M5); this release
   implements it.
3. **Background-daemon management.** `allbert serve` plus install/uninstall of a
   launchd / systemd / Scheduled-Task service, with a health check the user can
   see succeed — covering the runtime, web workspace, and channels.
4. **Complete the ADR 0070 convergence.** The mix-free TUI operator console
   absorbs the remaining admin-inspection reads so operators never need raw `mix`
   for day-to-day operation.
5. **OS secret-vault.** Credential storage moves to a **three-tier backend**
   (operator decision 2026-07-05): (1) the OS keychain / secret service via
   shell-out where available — no maintained Elixir vault library exists in
   2026; (2) a documented fallback to the existing encrypted
   `Settings.Secrets` store where no vault is reachable (headless Linux
   daemons cannot assume a D-Bus keyring session); (3) env injection for
   automation. Settings Central keeps holding *references* (the existing
   `secret://` schema types); the v0.63 onboarding wizard teaches this final
   credential path instead of a temporary one.
6. **First-Model-Path packaging hook.** ADR 0078 (decided in v0.60) selects an
   assisted local-model QuickStart, so this release must **detect and guide an
   Ollama install plus curated model pull** alongside the packaged artifact.
   Ollama is a managed external dependency, not bundled into the `allbert`
   binary; BYOK remains the Advanced/fallback path. **Execution authority
   (operator decision 2026-07-05): Allbert executes the guided install and
   pull itself, through the official Ollama channels only, each step behind an
   explicit operator confirmation with trace/egress recording** — this is its
   own v0.62 milestone, not a packaging footnote.

The concrete v0.60 M5 entry-point artifact is
`docs/design/entry-point-cli-ux.md`: command taxonomy, grouped help model,
first-run detection, first-model-state check, wizard launch sequence, and
Mix-to-`allbert` mapping for the v0.62 implementation.

## Consequences

- **Toolchain-free install** — the v1.0 acceptance-matrix install criterion
   becomes achievable for a non-developer-toolchain user.
- The packaged binary and the grouped CLI surface become **Tier-1 freeze
   candidates** at v1.0; settling them before onboarding and product RC is what
   makes the freeze meaningful.
- **No authority change.** Packaging changes how Allbert is installed and invoked;
   it does not change what any surface may do. Security Central, confirmations, and
   the action boundary are unchanged; the `mix` tasks remain available for
   development.
- Allbert Home layout may shift to accommodate packaged-install paths and the OS
   vault — done here, before guided onboarding and product RC lock the
   user-facing flow.

## Distribution Trust (added 2026-07-05)

Packaging is Allbert's **first external distribution surface**; the local-first
and inspectability promises extend to it:

- **Enumerated network touches.** Installation and first-run may touch the
  network in exactly four ways: (1) the install-script artifact fetch, (2) the
  Homebrew tap/artifact fetch, (3) the Ollama installer fetch, (4) the curated
  model pull. (3) and (4) execute only behind explicit operator confirmations
  with trace records. Nothing else; the binary itself performs **no telemetry,
  no phone-home, and no auto-update check**.
- **Verifiable artifacts.** Release artifacts publish SHA256 checksums; both
  install paths verify them (cosign-signed checksums are a recorded candidate,
  not required in v0.62). The bundled ERTS/OTP version is pinned as a CI input
  with portable crypto linkage; its provenance (project-built vs the packaging
  tool's CDN builds) is settled by the M0 spike and recorded here at
  acceptance.
- **Signing posture (operator decision 2026-07-05).** v0.62 ships **unsigned,
  via Homebrew and curl only** — both paths are quarantine-free on macOS;
  browser-download distribution is out of scope. Developer-ID signing +
  notarization is a named **v0.64 RC work item** (including the Apple
  Developer account decision and the self-extraction × hardened-runtime
  interaction test).
- **Inspectable install.** Both install paths install only documented files,
  write an uninstall manifest, and leave Allbert Home untouched on uninstall
  absent an explicit `--purge`. Tap/artifact-hosting ownership (domain, repo)
  is recorded at the v0.62 S3 sign-off.
- **Packaged-plugin constraint.** A packaged install can never gain new plugin
  *code* (plugins compile into the artifact at build time); Home-directory
  declarative entries and operator-confirmed dynamic drafts remain the runtime
  extension paths. This is a documented product fact, not a defect.

## Non-goals and guardrails

- **Not a native desktop GUI client.** A full native client stays post-1.0; the
  web workspace remains the operator UI through v1.0 (the binary serves it).
- **Not hosted/remote distribution or plugin auto-update** — those remain
  future-features items.
- The CLI dispatcher reorganizes entry points; it does not add capability or
  authority — every command still routes through the same runtime/action/settings
  spine (ADR 0073).

## Platform Support Tiers And Feasibility Spike

Two explicit scope decisions, recorded here so they are not assumed downstream:

- **Tier 1 — macOS and Linux** are fully supported and freeze-blocking for v1.0:
  the binary, Homebrew/curl install, `launchd`/`systemd` daemon, and the macOS
  Keychain / Linux Secret Service vaults. **Tier 2 — Windows** is supported via
  WSL2; native Windows packaging, a Scheduled-Task daemon, and Windows Credential
  Manager are best-effort/beta and **not** v1.0 freeze-blocking unless a later ADR
  promotes them.
- **Feasibility spike first.** Because the codebase has no packaging today, the
  packaging mechanism (Burrito 1.5.x or a hand-wrapped OTP release; Bakeware is
  archived and struck) is chosen by a time-boxed v0.62 M0 spike that must prove
  an ERTS-bundled binary boots with the `exqlite` SQLite NIF **and the
  `erlexec`/`muontrap` port executables**, serves the compiled web assets,
  **registers** one source-tree plugin from the packaged layout, drives the TUI
  raw-mode input, and supports the attach transport, on a Tier-1 OS with no
  toolchain present (the full eight-proof list lives in the v0.62 plan M0). The
  spike result selects the mechanism; this ADR does not pre-commit one.
