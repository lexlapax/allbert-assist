# ADR 0069: Guided Onboarding Flow

Status: Accepted (v0.63). Re-scoped 2026-06-25 from a v0.59 TUI-only "sequence the
existing steps" hardening sliver into a real guided-onboarding capability for the
v0.63 Guided Onboarding & Profiles release; built and accepted at v0.63 M7 closeout.
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
   stakes for local-first assistants — OpenClaw's documented onboarding path and Claude
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

The wizard is **two-track** and operator-first:

- **QuickStart** — sensible defaults, the fewest decisions, and a **"fastest first
  chat"** path that skips channel/integration setup and gets to a working
  conversation immediately.
- **Advanced** — full control over provider, model, channels, and profile.
- Operator-facing readiness is expressed as `Ready`, `Needs model`,
  `Needs credentials`, `Needs runtime`, and `Needs review`, each with one next
  action. Internal probe atoms remain diagnostic details, not first-run copy.

It covers, with opinionated defaults at each step:

1. **Provider/model setup** as a first-class step — masked-key entry, **inline
   `doctor` verification**, local (Ollama) and hosted (OpenAI/Anthropic/
   OpenRouter) options, switchable without editing config. New secrets write only
   to OS vault or encrypted-store fallback; env-provided secrets are detected and
   verified as read-only.
2. **User-category profile selection** (ADR 0075): the operator picks a persona
   (researcher / developer / writer / ops / general) and the wizard applies the
   repo-maintained preset — seeding Settings Central defaults plus suggested apps,
   channels, and intents — with an explicit review step.
3. A health-check confirmation the operator can *see* succeed (before first chat).
4. Optional channel pairing and integration setup, deferred to last (skipped on the
   fast path).

(The authoritative step-ID sequence is in the v0.63 Build Decisions section below:
`welcome → track_select → model_path → profile_select → profile_review →
health_check → first_chat → optional_connect`. This capabilities list matches it —
health precedes first chat, optional connect is last.)

The concrete v0.60 M4 onboarding artifact is
`docs/design/onboarding-flow.md`: two-track wizard UX, step sequence, surfaces,
QuickStart vs Advanced behavior, review/confirm semantics, and the v0.63 handoff.

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
- **Credential UX uses the three-tier vault.** Masked-key entry writes through the
  v0.62 secret backend: Settings Central stores `*_ref` references and the secret
  value lands in a writable tier (OS vault → encrypted-store fallback). Env
  secrets remain valid read-only inputs supplied outside Allbert. The wizard
  surfaces the tier as a trust feature.
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
open item). ADR 0078 selects assisted local model setup (Ollama install +
one-click pull of a curated default) as the QuickStart default, keeps honest
bring-your-own-key as the Advanced/fallback path, and rejects a managed-hosted
default. The QuickStart fast path and the "first useful chat" acceptance
criterion are built against ADR 0078's chosen option, never against an assumed
pre-existing model. Because assisted-local **shipped as real code in v0.62 M4**
(`first_model_detect`/`install_ollama`/`pull_model`), ADR 0078's BYOK-primary
*degrade* branch does not apply to v0.63.

## v0.63 Build Decisions (resolved for implementation)

Ratified in the v0.63 plan's Locked Decisions (2026-07-07/2026-07-08):

- **One shared state machine (Decision 1).** The existing command-sequencing
  onboarding wizard (`apps/allbert_assist/lib/allbert_assist/onboarding.ex`) is
  upgraded into the authoritative wizard state machine over the 8 design step IDs
  (`welcome`→`track_select`→`model_path`→`profile_select`→`profile_review`→
  `health_check`→`first_chat`→`optional_connect`). Its persistence **unifies** the
  objective-status and the v0.62 `<Home>/onboarding.json` marker into one
  "onboarding complete" source that `cli/first_run.ex` reads; the placeholder
  `profile_reviewed`/`:profile_unreviewed` states become real states written by
  `profile_review`.
- **Two terminal renderings, one flow (Decision 3).** The interactive terminal
  wizard is the TUI console (ADR 0067/0070) when a TTY is present, with a
  line-oriented `allbert onboard` prompt fallback for headless installs — both drive
  identical step IDs. `allbert onboard` is upgraded from the shipped `admin
  onboarding` summary read into this wizard entry point (Decision 7).
- **Official CLI modes (Decisions 7, 9-11).** `allbert onboard` is a **new
  top-level verb** (an `@operator` entry + an `Areas.Onboarding` OptionParser
  dispatcher, off the current flag-dropping `{:read}` disposition). It resumes
  active onboarding or starts with the track chooser; `--quickstart`/`--advanced`
  select the track; confirmed `--reset` clears **both** persistence stores (the
  `<Home>/onboarding.json` marker and the in-flight objective) and nothing else;
  `--non-interactive` suppresses prompts and canonical `--authorize`
  pre-authorizes the confirmation-gated steps (install/pull/persona-apply)
  **through the confirmation approve path** — a durable, traced operator
  authorization, never a floor bypass. Deprecated `--accept-risk` remains a
  warning compatibility alias for older automation and must route to the same
  durable approval path. Automation refuses on missing required input.
- **Operator readiness copy (Decision 12).** Web and terminal surfaces render
  `Ready`, `Needs model`, `Needs credentials`, `Needs runtime`, or `Needs review`
  plus one next action. Raw first-model probe atoms are allowed in traces/tests,
  not in operator UX.
- **Provider choices (Decision 6).** Named local (Ollama) + hosted
  (OpenAI/Anthropic/OpenRouter) providers **plus an OpenAI-compatible custom
  endpoint**; provider switching writes settings and edits no config file.

This ADR is marked Accepted during v0.63 closeout (asserted by the plan's
`adr-0069-accepted-001` eval row).

## Post-Implementation Amendment (v0.63 M7.1–M7.8 remediation, 2026-07-08)

A post-implementation adversarial audit confirmed the onboarding **foundation is
sound** — no authority bypass, no secret leak, personas seed-only — but found that
several *surfaces* shipped thinner than this ADR's decisions, plus eval-gate and doc
gaps. The M7.x remediation (see the plan's Post-Implementation Audit & Remediation
section) resolves them, with these amendments to the decisions above:

- **TUI console (Decision 3), as-built + remediation.** M6 shipped only the
  line-oriented `allbert onboard` fallback; the **TUI console rendering was not built**.
  It is built in remediation **M7.5** (driving the same shared machine + 8 step IDs), so
  "two terminal renderings, one flow" holds as-built only after M7.5.
- **Persistence unification → objective-flow retirement (Decision 1).** Rather than
  keeping the legacy objective onboarding backend coexisting with the marker, remediation
  **M7.3 retires the objective onboarding flow entirely** (backend +
  `mix allbert.onboard` objective path + web panel + tests); the shared wizard machine
  over the `<Home>/onboarding.json` marker becomes the *sole* onboarding source and
  surface, and `mix allbert.onboard` is re-pointed at it. The first-launch reconcile the
  Upgrade § describes is implemented in **M7.6** (a one-time cancel/cleanup of any
  pre-existing in-flight objective).
- **`--authorize` for persona apply becomes two-step (Decision 7).** To satisfy the
  review/confirm contract, `apply-persona <id> --authorize` (M7.4) renders the
  `current→proposed` review diff and requires an explicit `--yes` before it runs the
  durable create+approve path. The durable-confirmation, no-floor-bypass property is
  unchanged.
- **Web wizard drives M3/M4 (Decision 1/6/12).** The web wizard is completed in M7.3 to
  render real masked provider entry, inline doctor, provider switch, and the persona
  review diff (M5 shipped a step-ticker that drove neither); readiness copy stays
  operator-language.
