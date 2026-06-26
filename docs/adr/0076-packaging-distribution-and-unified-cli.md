# ADR 0076: Packaging, Distribution & Unified CLI Entry Points

Status: Proposed (v0.62).
Date: 2026-06-25
Related: ADR 0070 (TUI operator console — this completes its mix-free
convergence), ADR 0067 (TUI/terminal channel), ADR 0004 / ADR 0031 (Settings
Central), ADR 0069 (onboarding — the vault-ready credential UX lands its OS vault
here), ADR 0006 (Security Central — packaging changes how Allbert is installed and
invoked, not what any surface may do), and the Allbert Home layout decisions.
Anchors the v0.62 Packaging & Entry Points release.

## Context

Allbert is **mix-only** today. The v0.58 maturity review confirmed: no escript, no
`releases:`, no Burrito/Bakeware, no `rel/`, no install script, no Homebrew, no
Docker. A new user needs a git checkout plus the full Elixir/OTP toolchain, and
the start path is `mix setup` → `mix phx.server` / `mix allbert.onboard`. There
are ~48 flat `mix allbert.*` tasks with no unified binary, no grouped `--help`,
and operator commands intermixed with developer/CI commands.

For the technical-prosumer 1.0 audience, the toolchain requirement is the
**dominant adoption blocker** — the exact friction that gets powerful-but-
Docker/dev-required tools penalized in every 2026 comparison, while packaged
binaries with one-command install (LM Studio, Jan, OpenClaw, Hermes) win on
first value. This is the last release that reshapes Allbert Home layout and entry
points, so it lands immediately before the v1.0 freeze.

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
   service, injected at launch, swapping in under the v0.61 vault-ready credential
   UX (ADR 0069).

## Consequences

- **Toolchain-free install** — the v1.0 acceptance-matrix install criterion
   becomes achievable for a non-developer-toolchain user.
- The packaged binary and the grouped CLI surface become **Tier-1 freeze
   candidates** at v1.0; settling them here (the last entry-point churn) is what
   makes the freeze meaningful.
- **No authority change.** Packaging changes how Allbert is installed and invoked;
   it does not change what any surface may do. Security Central, confirmations, and
   the action boundary are unchanged; the `mix` tasks remain available for
   development.
- Allbert Home layout may shift to accommodate packaged-install paths and the OS
   vault — done here, before the freeze locks the layout.

## Non-goals and guardrails

- **Not a native desktop GUI client.** A full native client stays post-1.0; the
  web workspace remains the operator UI through v1.0 (the binary serves it).
- **Not hosted/remote distribution or plugin auto-update** — those remain
  future-features items.
- The CLI dispatcher reorganizes entry points; it does not add capability or
  authority — every command still routes through the same runtime/action/settings
  spine (ADR 0073).
