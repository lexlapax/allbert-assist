# ADR 0076: Packaging, Distribution & Unified CLI Entry Points

Status: Proposed (v0.61).
Date: 2026-06-25
Related: ADR 0070 (TUI operator console — this completes its mix-free
convergence), ADR 0067 (TUI/terminal channel), ADR 0004 / ADR 0031 (Settings
Central), ADR 0069 (onboarding — v0.62 builds on the entry points and vault
model defined here), ADR 0006 (Security Central — packaging changes how Allbert
is installed and invoked, not what any surface may do), and the Allbert Home
layout decisions. Anchors the v0.61 Packaging & Entry Points release.

## Context

Allbert is **mix-only** today. The v0.58 maturity review confirmed: no escript, no
`releases:`, no Burrito/Bakeware, no `rel/`, no install script, no Homebrew, no
Docker. A new user needs a git checkout plus the full Elixir/OTP toolchain, and
the start path is `mix setup` → `mix phx.server` / `mix allbert.onboard`. There
are 53 flat Mix tasks at the v0.58 closeout review, with no unified binary, no grouped `--help`,
and operator commands intermixed with developer/CI commands.

For the technical-prosumer 1.0 audience, the toolchain requirement is the
**dominant adoption blocker** — the exact friction that gets powerful-but-
Docker/dev-required tools penalized in every 2026 comparison, while packaged
binaries with one-command install (LM Studio, Jan, OpenClaw, Hermes) win on
first value. This release reshapes Allbert Home layout and entry points before
guided onboarding and the v0.63 product RC lock in the first-run flow.

## Decision

1. **Packaged `allbert` binary.** Ship a release-built artifact (OTP release via
   Burrito/Bakeware-style ERTS bundling) so no Elixir/OTP is required on the
   user's machine, distributed via **Homebrew** and a **curl install script**.
2. **Unified grouped CLI dispatcher.** A single `allbert <group> <command>`
   surface — `ask | chat | tui | serve | admin <area> | gen` — subsuming the flat
   mix-task sprawl, with coherent grouped help. Operator commands are separated
   from developer/CI commands; the latter stay `mix`-only.
3. **Background-daemon management.** `allbert serve` plus install/uninstall of a
   launchd / systemd / Scheduled-Task service, with a health check the user can
   see succeed — covering the runtime, web workspace, and channels.
4. **Complete the ADR 0070 convergence.** The mix-free TUI operator console
   absorbs the remaining admin-inspection reads so operators never need raw `mix`
   for day-to-day operation.
5. **OS secret-vault.** Credential storage moves to the OS keychain / secret
   service, injected at launch, so the v0.62 onboarding wizard can teach the
   final credential path instead of a temporary one.

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
  packaging mechanism (Burrito, Bakeware, or a hand-wrapped OTP release) is chosen
  by a time-boxed v0.61 M0 spike that must prove an ERTS-bundled binary boots with
  the `exqlite` SQLite NIF, the compiled web assets, and one source-tree plugin on
  a Tier-1 OS with no toolchain present. The spike result selects the mechanism;
  this ADR does not pre-commit one.
