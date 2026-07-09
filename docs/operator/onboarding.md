# Allbert Operator Onboarding

This guide is the operator-facing entry path for trying Allbert from a fresh
checkout. It is not a release test matrix. Release-specific smoke commands live
in the matching request-flow document.

## Orientation

Read these first:

- `README.md` for the project overview and current capability summary.
- `CHANGELOG.md` for release status, safety notes, verification summary, and
  expected tag.
- `docs/plans/roadmap.md` for version sequencing.
- `docs/plans/v0.63-plan.md` and `docs/plans/v0.63-request-flow.md` for the
  active guided-onboarding/profile implementation contract.

## First Local Run

Use a disposable Allbert Home when exploring:

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-operator.XXXXXX)"
export ALLBERT_TRACE_ENABLED=true
```

Set up and run the app:

```sh
mix setup
mix phx.server
```

Open the local operator surfaces:

```text
http://localhost:4000/workspace
```

Try the CLI surface:

```sh
mix allbert.ask "hello"
mix allbert.security status
mix allbert.confirmations list
```

## v0.63 Operator Onboarding

v0.63 ships a guided onboarding wizard over one shared flow on both surfaces — the
auto-opening web wizard and the interactive `allbert onboard` TTY wizard — built and
validated at the M7.x closeout. The old command-sequencing onboarding objective is
retired; the shared wizard machine over the `<Home>/onboarding.json` marker is the
sole onboarding source and surface.

How an operator gets running:

- `allbert serve` starts the runtime and the web wizard auto-opens on first run.
- `allbert onboard` is the primary TTY wizard entry point. It resumes active
  onboarding or starts with a QuickStart/Advanced chooser; no-TTY/headless use falls
  back to the line-oriented flow.
- `allbert onboard --quickstart` takes the fastest safe path to first chat.
- `allbert onboard --advanced` exposes provider, model, profile, and optional
  integration choices up front.
- `allbert onboard --reset` requires confirmation and clears only onboarding and
  profile marker state; it must preserve Home data, settings, secrets, traces,
  memory, and caches.
- `allbert onboard --non-interactive --authorize` is automation-only: it accepts
  explicit flags/input refs, never prompts, refuses missing required inputs, and
  records durable confirmations through the existing approval path. Deprecated
  `--accept-risk` is accepted only as a warning compatibility alias.
- Persona apply is two-step: `apply-persona <id> --authorize` shows the
  current-to-proposed settings diff and writes nothing; only `apply-persona <id>
  --authorize --yes` applies through the durable confirmation path.

The wizard should speak in operator readiness language, not internal probe names:
`Ready`, `Needs model`, `Needs credentials`, `Needs runtime`, and `Needs review`.
Every repair screen should show one next action.

Profile application writes Settings Central keys after review/confirm. The shipped
profiles are `general`, `researcher`, `developer`, `writer`, and `ops`; exact
writes live in `docs/plans/v0.63-plan.md` and
`docs/adr/0075-user-category-settings-profiles.md`. Profiles are seed-only
defaults and suggestions. They do not grant authority, connect channels, store
secrets, lower confirmation floors, or change runtime behavior by themselves.

Credential entry stores new secrets as Settings `*_ref` pointers in OS vault or
encrypted-store fallback. Env-provided secrets are valid read-only inputs: the
wizard can detect and verify them, but does not write to env.

### Provider / model setup and switching

At the `model_path` step the wizard shows operator readiness and, when a provider is
needed, a masked key entry (stored in the vault, never echoed), an inline `doctor`
round-trip, and a provider/model switch. Named local (Ollama) and hosted
(OpenAI/Anthropic/OpenRouter) providers plus an OpenAI-compatible custom endpoint are
supported; switching a provider writes Settings Central keys and edits no config file.
The wizard surfaces which vault tier a new key lands in (OS vault → encrypted-store);
the env tier is read-only.

### User-category profile reference

Pick a persona at `profile_select`; the review at `profile_review` shows every seeded
key as `current → proposed` and writes nothing until you confirm. Personas are
seed-only presets — they grant no authority, connect no channel, store no secret, and
lower no confirmation floor. The exact per-persona `settings_seeds` are pinned in
`docs/plans/v0.63-plan.md` (§Settings Central Keys) and
`docs/adr/0075-user-category-settings-profiles.md`.

| Persona | Emphasis (seed-only) |
|---|---|
| `general` | Balanced local-first assistant; modest objective budget. |
| `researcher` | Detailed handoffs, active-memory tuning, local router/embedding profiles. |
| `developer` | Concise, Pi-mode coding profile + reviewed coding read/search limits. |
| `writer` | Detailed handoffs + active-memory tuning for drafting/revising. |
| `ops` | Concise/brief, verbose diagnostics, debug trace detail, local router profiles. |

After applying a persona, the `first_chat` step suggests that persona's starter
prompts so you reach a first useful chat.

When the `model_path` step confirms a usable model (readiness **Ready**), QuickStart
enables model-backed direct answers automatically (`intent.direct_answer_model_enabled`),
so `allbert ask` works from the first chat with no manual settings edit. If the model is
not yet ready, the flag stays off and the wizard routes you to the concrete repair
(runtime, model, or BYOK) first — a working model is never faked. Applying any persona
also seeds this flag as part of its reviewed settings.

### The trust spine

Onboarding surfaces Allbert's trust spine as a feature (`allbert onboard trust`, and a
section in the web wizard): risky actions pause for your explicit, durable, traced
approval; every action is scoped by Security Central and onboarding grants no new
authority; what Allbert does is recorded and locally inspectable; your data and model
stay on your machine unless you connect a hosted provider.

## Legacy Homes (pre-v0.63)

Homes onboarded before v0.63 may carry a stale first-run *objective* record from the
retired source-checkout onboarding flow. The wizard reconciles it once on first launch —
there is nothing to do manually. The old `mix allbert.onboard complete|skip|channel`
subcommands no longer exist; use `allbert onboard` (or `mix allbert.onboard`), which drives
the shared wizard state machine described above.

## See also

- Provider/model setup, the model doctor, and recommended profiles —
  [model-recommendations.md](model-recommendations.md).
- The three-tier secret vault and where provider keys live —
  [security-hardening.md](security-hardening.md) (§Secret Vault).
- Templated document creation (`workspace:create`) — [templated-creation.md](templated-creation.md).
- What each persona seeds and its exact reviewed keys — `docs/design/persona-model.md`.
