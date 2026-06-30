# ADR 0069: Guided Onboarding Flow

Status: Proposed (v0.63). Re-scoped 2026-06-25 from a v0.59 TUI-only "sequence the
existing steps" hardening sliver into a real guided-onboarding capability for the
v0.63 Guided Onboarding & Profiles release.
Date: 2026-06-21 (re-scoped 2026-06-25)
Related: ADR 0077 (Product Experience Design & IA — designs this onboarding flow
in v0.60 M4; this ADR builds it in v0.63), ADR 0078 (First-Model Path — the
QuickStart "fastest first chat" model decision, decided in v0.60), ADR 0074 (web
design system — the web wizard renders through it), ADR 0067 (TUI/terminal
channel — the CLI/terminal wizard surface), ADR 0075 (user-category settings
profiles — onboarding applies them), ADR 0076 (packaging and the final `allbert`
entry points onboarding teaches), ADR 0006 (Security Central — onboarding grants
no authority), the Settings Central decisions (settings still flow through
Settings Central), and the existing secrets, channel-pairing, provider/model, and
`doctor` flows this wizard drives.

## Context

Allbert already has the pieces an operator needs to get running: settings
(through Settings Central), secrets handling, provider/model selection, channel
pairing, and a `doctor` diagnostic. The original v0.59 framing treated onboarding
as *sequencing* those existing steps — explicitly "hardening, not a new
capability," surfaced only through the TUI.

Two things changed that framing for the v0.63 product release:

1. **The competitive bar.** A 2026 review found a guided, two-track onboarding
   wizard (QuickStart vs Advanced, with a "fastest first chat" path) is now table
   stakes for local-first assistants — OpenClaw's install wizard and Claude
   Desktop's opinionated-preset onboarding are the reference. A blank field or a
   list of steps to run yourself reads as sub-1.0 for a non-trivial first-run.
2. **The current state.** The v0.58 maturity review found Allbert's onboarding is
   prototype-grade: `mix allbert.onboard` is *not* interactive (it prints
   copy-paste shell commands), the web onboarding panel is not auto-launched on
   first run, credential entry is punted to a separate form, and there are no
   user-category presets. The pieces exist; the *experience* does not.

For the technical-prosumer 1.0 audience, onboarding is a genuine capability gap,
not a polish sliver.

## Decision

Build a real **guided onboarding wizard** as a first-class v0.63 capability. The
onboarding *flow* itself — step sequence, two-track shape, and copy — is designed
in the v0.60 Product Experience Design release (ADR 0077 M4); this ADR **builds**
that design in v0.63. It is surfaced on **two** surfaces over the same underlying
flow:

- **Web** (ADR 0074): auto-launched on first run, the primary surface.
- **Interactive CLI/TUI** (ADR 0067): a genuinely interactive terminal wizard —
  prompts and verifies in place, not copy-paste shell commands.

The wizard is **two-track**:

- **QuickStart** — sensible defaults, the fewest decisions, and a **"fastest first
  chat"** path that skips channel/integration setup and gets to a working
  conversation immediately.
- **Advanced** — full control over provider, model, channels, and profile.

It covers, with opinionated defaults at each step:

1. **Provider/model setup** as a first-class step — masked-key entry, **inline
   `doctor` verification**, local (Ollama) and hosted (OpenAI/Anthropic/
   OpenRouter) options, switchable without editing config.
2. **User-category profile selection** (ADR 0075): the operator picks a persona
   (researcher / developer / writer / ops / general) and the wizard applies the
   repo-maintained preset — seeding Settings Central defaults plus suggested apps,
   channels, and intents — with an explicit review step.
3. Optional channel pairing and integration setup (skipped on the fast path).
4. A health-check confirmation the operator can *see* succeed.

The wizard **surfaces the trust spine as a feature**: it presents the
confirmation/permission/trace model as the safety property it is, not as friction —
the differentiator the autonomous-agent competitors cannot copy.

## Consequences

- **Two surfaces, one flow.** The web wizard (ADR 0074) and the interactive
  CLI/TUI wizard (ADR 0067) drive the same underlying onboarding steps; neither
  forks the logic.
- **A real capability, not just sequencing.** Unlike the v0.59 framing, this adds
  interactive provider/credential/profile flows and persona application — but it
  still adds **no new authority**: every effectful step routes through the existing
  gates, Security Central (ADR 0006) is unchanged, and profiles seed defaults only.
- **Settings still flow through Settings Central.** Onboarding writes settings and
  applies profile presets only through Settings Central; it is not a configuration
  side channel. Secrets, provider/model, channel pairing, and `doctor` remain the
  authoritative flows the wizard drives.
- **Credential UX uses the OS vault.** Masked-key entry writes through the v0.62
  OS-vault reference model: Settings Central stores references, the OS vault
  stores secret values.
- **Depends on the v0.60→v0.63 arc and ADR 0075.** The wizard builds on the
  v0.60 onboarding/IA design (ADR 0077), the v0.61 Presentation Layer Overhaul
  affordances (empty states, suggested actions) the web wizard renders through,
  and the packaged v0.62 `allbert` entry points it teaches; profile application
  depends on the user-category profile system (ADR 0075).

## First-Model Path (decided in ADR 0078)

QuickStart's "fastest first chat" requires a reachable model. This ADR does **not**
assume the user already has a hosted API key or a local model; the behaviour for a
user with neither is the **First-Model Path decision, now owned by ADR 0078 and
decided in the v0.60 Product Experience Design release** (no longer a v0.63 M0
open item). It chooses one of: (a) an assisted local model (Ollama install +
one-click pull of a small default), (b) a managed hosted free/low-tier default
with its own credential, abuse, and cost policy, or (c) an honestly-framed
bring-your-own-key path that states the requirement up front with the most
assisted setup possible. The QuickStart fast path and the "first useful chat"
acceptance criterion are built against ADR 0078's chosen option, never against an
assumed pre-existing model.
