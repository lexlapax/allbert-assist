# Optional Onboarding And Customization

Start with [Quickstart: Install, Open, Chat](quickstart.md). In Allbert 1.2,
onboarding is optional: chat opens first, whether a provider is ready or not.
Use this guide when you want a guided profile, provider setup, integration
choices, or model repair.

## Open The Wizard

The web and terminal wizard use one shared state machine and the same
`<Allbert Home>/onboarding.json` progress marker. From a packaged install:

```sh
allbert onboard
```

The interactive flow resumes unfinished progress or offers two tracks:

- **QuickStart** reviews the smallest useful set of customization choices.
- **Advanced** exposes provider, model, persona, and optional integrations up
  front.

Choose a track directly when needed:

```sh
allbert onboard --quickstart
allbert onboard --advanced
```

Completing, skipping, or resetting this wizard does not control access to chat.
Model readiness and onboarding completion are separate state. Reset is
confirmation-gated and clears only onboarding/profile markers; it preserves
settings, secrets, traces, memory, caches, conversations, and other Home data:

```sh
allbert onboard --reset
```

## What First Run Already Did

Before the wizard runs, zero-click detection may already have:

- selected a ready local provider, or a configured hosted provider when no
  usable local provider exists;
- enabled direct model answers only when the enablement setting was absent;
- shown the applicable local-processing or hosted-egress disclosure once; and
- kept chat open with a bounded fallback when no provider was usable.

Detection does not probe a hosted provider, install Ollama, pull a model, or
overwrite an explicit setting. A raw
`intent.direct_answer_model_enabled=false` remains sticky. A completed wizard
may offer one reviewed re-enable action, or use:

```sh
allbert onboard re-enable-model
```

## Readiness And Repair

The wizard and web Models panel use operator language: **Ready**, **Needs
model**, **Needs credentials**, **Needs runtime**, and **Needs review**. Each
repair state presents one primary next action.

The local-first repair sequence is start/install the local runtime, then review
and confirm a curated model pull. Neither action is automatic:

```sh
allbert onboard install-runtime --authorize       # preview
allbert onboard install-runtime --authorize --yes # apply after review
allbert onboard pull-model --authorize             # preview
allbert onboard pull-model --authorize --yes       # apply after review
```

The curated consumer default remains `llama3.2:3b` with an 8 GB RAM floor.
Qwen 3 and Qwen 3.5 remain explicit catalog choices; they did not replace the
cross-platform default in v1.2. Operators can override the curated tag or floor
before a pull:

```sh
allbert admin settings set first_model.curated_model llama3.2:3b
allbert admin settings set first_model.curated_floor_gb 8
```

Inspect available choices and current health with:

```sh
allbert admin models catalog
allbert admin models catalog direct_answer
allbert admin models list
allbert admin settings model-doctor
```

The web Models panel exposes catalog selection and repair. TUI `/catalog`
renders the shared read-only catalog and `/models` renders model health.
Selecting a profile writes Settings Central. Pulling an uninstalled local
model remains confirmation-gated.

If a selected local model later becomes unavailable, the workspace opens the
Models repair panel instead of reopening onboarding. A missing or unhealthy
local runtime does not silently switch to a hosted route. Runtime text fallback
is independently opt-in:

```sh
allbert admin settings set models.fallback.enabled true
allbert admin settings set models.fallback.allow_local_to_hosted true
```

The second setting is required before a local failure may cross the network
boundary. A turn attempts at most one failover. Decisions are audited under
`<Allbert Home>/settings/audit/model_fallback/` without prompts or credentials.

## Hosted Providers And Secrets

Advanced onboarding can store a hosted-provider key through masked input and
run a provider doctor. New secrets become Settings `*_ref` pointers backed by
the OS vault or encrypted-store fallback; they are never written into a config
file or echoed. Environment-provided keys are valid read-only inputs and are
not copied into the vault.

The standalone packaged path is also available:

```sh
allbert admin settings providers set-key openai
allbert admin settings providers list
allbert admin settings doctor
```

A configured key makes a provider eligible for first-run selection, but
detection performs no hidden network validation or inference. The first hosted
send remains behind the egress disclosure.

## Personas Are Reviewed Defaults

The shipped personas are `general`, `researcher`, `developer`, `writer`, and
`ops`. At `profile_review`, onboarding shows every proposed Settings change as
`current → proposed` and writes nothing until confirmation.

| Persona | Seed emphasis |
|---|---|
| `general` | Balanced local-first assistant and modest objective budget. |
| `researcher` | Detailed handoffs, active-memory tuning, and local routing profiles. |
| `developer` | Concise responses, Pi-mode coding profile, and reviewed code search limits. |
| `writer` | Detailed handoffs and active-memory tuning for drafting and revision. |
| `ops` | Brief responses, verbose diagnostics, and local routing profiles. |

Personas are seed-only suggestions. They grant no authority, connect no
channel, store no secret, and lower no confirmation floor. The automation form
retains the same review/apply split:

```sh
allbert onboard apply-persona developer --authorize       # preview
allbert onboard apply-persona developer --authorize --yes # apply
```

## Terminal And Web Continuity

`allbert tui` is a daily-use surface, not a repair wizard. On a fresh Home, an
explicit built-in TUI launch atomically enables the channel and persists the
ordinary `default → local` identity mapping before the first prompt. This does
not mark onboarding complete or skipped. Explicitly disabled TUI state and an
explicit empty/custom identity map remain sticky.

Re-enable a deliberately disabled channel with:

```sh
allbert admin settings set channels.tui.enabled true
```

After `/quit`, the same Home may be opened in the web workspace once no
standalone TUI owns its SQLite database. TUI `default` and web `web-local`
independently resolve to canonical user `local`, so eligible durable data is
shared; the TUI mapping grants no web authorization and the exact TUI thread is
not automatically selected. Never run the service/web runtime and standalone
TUI concurrently against the same Home. See [TUI channel](tui-channel.md).

## Automation And Legacy Homes

`allbert onboard --non-interactive --authorize` is automation-only. It accepts
explicit flags or input references, never prompts, refuses missing required
inputs, and records durable confirmations. Deprecated `--accept-risk` is a
warning-only compatibility alias.

Homes created before v0.63 may contain an obsolete first-run objective. The
wizard reconciles it once; no manual action is required. Retired
`mix allbert.onboard complete|skip|channel` subcommands must not be used.

## Trust Boundaries

Onboarding never grants authority. Sensitive actions still pass through
Security Central and durable confirmation; hosted egress is disclosed; provider
keys remain vault references; local notes and reviewed memory remain
inspectable. See [Security hardening](security-hardening.md) and
[Model recommendations](model-recommendations.md).
