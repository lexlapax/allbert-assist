# ADR 0069: Operator Onboarding Flow

Status: Proposed (v0.59).
Date: 2026-06-21
Related: ADR 0067 (TUI/terminal channel — the surface this flow is presented
through), ADR 0006 (Security Central — onboarding grants no authority), the
Settings Central decisions (settings still flow through Settings Central), and
the existing secrets, channel-pairing, and `doctor` flows this hardens.

## Context

Allbert already has the pieces an operator needs to get running: settings
(through Settings Central), secrets handling, channel pairing, and a `doctor`
diagnostic flow. What it lacks is a coherent **first-run path** that walks a new
operator through those pieces in order. Today the steps exist but are discovered
piecemeal — an operator has to know which setting to set, which secret to
provide, which channel to pair, and to run `doctor` to find out what is still
missing. That is friction, not a missing capability.

The v0.55 terminal channel (ADR 0067) now gives Allbert a real, persistent,
identity-mapped local surface that can host a guided interactive flow — the
natural place to present onboarding without inventing a new surface.

## Decision

Introduce a guided **operator onboarding flow**: a first-run/setup path that makes
operator onboarding genuinely easy by sequencing the operator through the
existing settings, secrets, channel-pairing, and `doctor` steps.

This is framed deliberately as **hardening and polish of existing paths, not a
new user-facing capability**. The flow layers **over** the settings, secrets,
channel-pairing, and `doctor` flows that already exist; it orchestrates and
presents them, it does not replace or duplicate them.

The flow is surfaced through the **v0.55 TUI/terminal channel (ADR 0067)** — the
guided first-run experience runs as an interactive terminal flow on that channel
rather than as a separate surface or a new runtime.

## Consequences

- **Depends on the TUI channel.** Onboarding is presented through the v0.55
  terminal channel (ADR 0067); it has no surface of its own.
- **No new authority.** The flow only sequences and presents existing steps. It
  grants no new authority and adds no new effectful capability — Security Central
  (ADR 0006) and every existing gate are unchanged.
- **Settings still flow through Settings Central.** Onboarding writes settings
  only through Settings Central; it is not a side channel for configuration. The
  same holds for secrets, channel pairing, and `doctor`, which remain the
  authoritative flows the onboarding path orchestrates.
- Operator first-run friction drops without expanding the surface area of what
  Allbert can do — the value is in legibility and sequencing of paths that
  already exist.
