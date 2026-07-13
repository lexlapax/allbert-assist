# Allbert Operator Onboarding

This guide is the package-first operator entry path for trying Allbert as a
local assistant. It is not a release test matrix. Release-specific smoke
commands live in the matching request-flow document.

## Orientation

Read these first:

- `README.md` for the project overview and current capability summary.
- `CHANGELOG.md` for release status, safety notes, verification summary, and
  expected tag.
- `docs/plans/roadmap.md` for version sequencing.
- `docs/plans/v0.64-plan.md` and `docs/plans/v0.64-request-flow.md` for the
  trusted-install and non-developer first-run implementation contract.

## First Packaged Run

Install the packaged binary first; it includes its own Erlang/OTP runtime:

```sh
brew install lexlapax/allbert/allbert
brew services start allbert
curl -fsS http://localhost:4000/health
```

If Homebrew 6 refuses the third-party tap until it is trusted, run
`brew trust --formula lexlapax/allbert/allbert`, then repeat the install.

Or use the curl installer from [install.md](install.md), then preview and approve
the user service:

```sh
export PATH="$HOME/.local/bin:$PATH"
allbert admin service install --dry-run
allbert admin service install
allbert admin confirmations approve <ID>
curl -fsS http://localhost:4000/health
```

Open the workspace:

```text
http://localhost:4000/workspace
```

Foreground `allbert serve --open` is a diagnostic or repair fallback when the
platform user service manager is unavailable. Source checkout (`mix setup`,
`mix phx.server`) is for contributors, not the non-developer first-run path.

Try the packaged CLI surface:

```sh
allbert ask "hello"
allbert admin health
allbert admin service status
allbert admin confirmations list
```

## Operator Onboarding

Allbert ships a guided onboarding wizard over one shared flow on both surfaces — the
auto-opening web wizard and the interactive `allbert onboard` TTY wizard — built and
validated at the M7.x closeout. The old command-sequencing onboarding objective is
retired; the shared wizard machine over the `<Home>/onboarding.json` marker is the
sole onboarding source and surface.

How an operator gets running:

- the packaged service starts the runtime and the web wizard auto-opens on first run.
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
- Local runtime/model repair is also confirmation-gated: `allbert onboard
  install-runtime --authorize` previews, and `--authorize --yes` applies; `allbert
  onboard pull-model --authorize` previews the starter-model pull, and
  `--authorize --yes` applies.

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

At the `model_path` step the wizard shows operator readiness and the local-first
repair path first: install/start the local runtime when absent, then pull the single
curated starter model through Ollama's local API. Hosted BYOK and custom endpoints are
the Advanced fallback. When a provider is needed, the wizard shows a masked key entry
(stored in the vault, never echoed), an inline `doctor` round-trip, and a provider/model
switch. Switching a provider writes Settings Central keys and edits no config file. The
wizard surfaces which vault tier a new key lands in (OS vault → encrypted-store); the
env tier is read-only.

If onboarding is complete but the model later becomes unavailable, opening the web
workspace routes to the standalone Models repair panel (`workspace:models`) instead of
reopening the wizard. The panel uses the same readiness guidance and repair actions.
The warm terminal console (`allbert tui`) is a daily-use surface, not a repair wizard:
before setup is complete it prints a one-line pointer to onboarding or the Models repair
panel and exits.

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
stay on your machine unless you connect a hosted provider; hosted-provider egress is
opt-in and shown before network use; provider keys are vault references under OS-vault
or encrypted-store custody; local notes and agent memory stay inspectable and review is
explicit.

## v0.64-v0.66 Planning Direction

The pre-1.0 plan now inserts three product-readiness releases after v0.63:

- v0.64 makes packaged install, installer trust, and first-run repair the
  primary non-developer path.
- v0.65 makes local files, notes, and reviewed agent memory the launch-critical
  first assistant workflow.
- v0.66 validates the complete product path with no-docs evidence and
  implemented-surface regression checks before v1.0.

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
- What Allbert guarantees stable across upgrades (the 1.0 tiered contract freeze) —
  [`docs/developer/public-contract-freeze.md`](../developer/public-contract-freeze.md).
