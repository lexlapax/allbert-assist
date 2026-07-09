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

## Historical v0.39 First-Run Onboarding

This section describes the older source-checkout onboarding objective. It remains
useful for historical troubleshooting of legacy Homes and objective records, but it
is not the operator UX target for v0.63 or later.

`docs/plans/v0.39-plan.md` promotes first-run onboarding and provider/model
control into the 1.0 arc, split across two sub-milestones:

- **v0.39** ships the guided onboarding objective (`mix allbert.onboard`,
  `workspace:onboard`), the provider/model control plane
  (`mix allbert.model {list,use,doctor}`), the two-branch provider doctor
  for configured model profiles (credentialed-remote + local-endpoint) with
  the redacted return shape pinned by ADR 0047, optional channel registration
  (telegram or email via the existing `mix allbert.channels` task), and an
  optional `intent.model_assist_enabled` toggle. v0.39 satisfies items 1 and
  2 of the v1.0 acceptance matrix.
- **v0.39b** ships the inert `identity` memory namespace (declared
  through a new non-app system-namespace declarer; surfaced as a 5th
  `Memory` category under `<ALLBERT_HOME>/memory/identity/`) and the
  deterministic direct-answer Active Memory retrieval pass with
  `## Active Memory` trace metadata. See `docs/operator/active-memory.md`
  for the operator-facing story.

Start the durable onboarding objective:

```sh
mix allbert.onboard
```

The CLI onboarding task starts the app and records Objective Runtime state.
When `ALLBERT_HOME` points at a new disposable root, the dev SQLite database is
derived as `$ALLBERT_HOME/db/allbert.sqlite3` and app startup runs migrations
before the normal Repo pool and runtime supervisors start when that canonical
database is missing or empty. This same first-run check applies to other
`mix allbert.*` tasks that start the app. A clean-home first command should not
print `database is locked`; treat that as a startup bootstrap defect.
`DATABASE_PATH` remains an override for tests, migrations, compatibility, and
operator escape hatches.

Resume or record progress from CLI:

```sh
mix allbert.onboard complete welcome_scope
mix allbert.onboard skip optional_channel_registration --note "Later"
mix allbert.onboard channel telegram
```

Open the same objective from the workspace:

```text
http://localhost:4000/workspace?destination=workspace:onboard
```

Try the implemented v0.39b identity and Active Memory path:

```sh
mkdir -p "$ALLBERT_HOME/memory/identity"
cat > "$ALLBERT_HOME/memory/identity/persona.md" <<'EOF'
# Persona

I prefer concise release reports with clear validation notes.
EOF
mix allbert.memory list --user local --category identity
mix allbert.memory review "$ALLBERT_HOME/memory/identity/persona.md" --user local --status kept --note "Operator-authored identity"
mix allbert.memory retrieve --user local --query "concise release reports"
```

Direct-answer replies use Active Memory only when
`intent.direct_answer_model_enabled=true` and the direct-answer model profile is
usable. `mix allbert.memory retrieve` is the trace-free inspection path for
checking retrieval before enabling model-backed replies.

Inspect and choose model profiles:

```sh
mix allbert.model list
mix allbert.model use local --enable-assist
mix allbert.model doctor local
mix allbert.model doctor anthropic_fast
mix allbert.model doctor coding
```

The doctor input is a configured model profile, not a raw URL. It resolves the
profile's provider and branches on `providers.<name>.endpoint_kind`:

- `local_endpoint`: checks the local endpoint and model catalog, sets
  `credential_ok: nil`, and reports `model_available: false` with
  `ollama pull llama3.2:3b` remediation when the shipped default model is not
  installed.
- `credentialed_remote`: checks the provider model catalog with the configured
  encrypted credential reference and returns only the ADR 0047 redacted
  summary shape.

Shipped provider/model defaults are seeded from
`apps/allbert_assist/priv/provider_catalog/models.json`. That file is
operator-inspectable release metadata, not runtime authority: Settings Central
overrides still win, and the doctor still verifies against the live provider
catalog. The catalog includes OpenAI, Anthropic, OpenRouter, Gemini, and local
Ollama seed profiles. The recommended remote code-generation profile is
`coding`; the consistent Ollama fallback is `coding_local`. Jido model aliases
are generated from `model_profiles.*` and optional
`model_profiles.*.aliases`, so there is no second model-list authority to keep
in sync. OpenAI-backed profiles keep `max_tokens` at `16` or higher to satisfy
the OpenAI Responses API minimum, and local Ollama base URL overrides are scoped
to local profiles only. For Anthropic, the shipped default `anthropic_fast` uses
the canonical Claude Haiku 4.5 API ID `claude-haiku-4-5-20251001`; the doctor
also recognizes the provider alias `claude-haiku-4-5` when comparing live model
listings.

Provider credentials still belong in Settings Central secrets. Use the existing
settings/channel tasks rather than shell history or prompt text for raw
secrets.

### Cross-OS Quick-Start

Per the v1.0 acceptance matrix item 1, v0.39 onboarding is designed to succeed
on macOS, Linux, and Windows/WSL2.

- **macOS / Linux**: `mix allbert.onboard` reads selections from the
  terminal; secrets are entered with echo disabled. Default local
  provider expects Ollama on `http://localhost:11434`. If the shipped
  default local model has not been pulled, the doctor reports
  `model_available: false` with remediation instead of auto-running
  `ollama pull`.
- **Windows/WSL2**: run `mix allbert.onboard` inside the WSL2 shell;
  `localhost` reaches the WSL2-side Ollama instance directly. Reaching a
  Windows-host Ollama instance from WSL2 is documented but not required
  for acceptance.
- **Non-interactive runs** can use the explicit subcommands above to record
  progress. Raw provider secrets should still be configured through the
  Settings Central secret helpers.

## v0.38 Templated Creation

`docs/plans/v0.38-plan.md` ships deterministic creation patterns: developers
scaffold reviewed plugin/app/LLM-tool/scheduled-flow/objective patterns through
`mix allbert.gen.{plugin,app,tool,flow}` (`--target` defaults to
`./plugins/<name>`; `--smoke` or `ALLBERT_TEMPLATE_SMOKE=1` writes disposable
validation output to `<ALLBERT_HOME>/template-smoke/<name>`; `--force` plus
preview/diff is required to overwrite an existing root), and operators open a
separate `workspace:create` Canvas
destination to render a vetted template, preview, validate, and choose
developer-scaffold or supported live-integration intent. The Create surface
routes effectful work through registered template actions: developer-scaffold
mode writes inert reviewed source to the default workspace target, or to
`<ALLBERT_HOME>/template-smoke/<name>` when the server runs with
`ALLBERT_TEMPLATE_SMOKE=1`, and denies existing roots (`--target` and `--force`
are CLI-only Mix task controls), while
supported live-integration mode requires the template, dynamic-codegen,
live-loader, and sandbox switches before it writes only a v0.37 draft and
returns the explicit trial/gate/integration next steps.
In v0.38, only the LLM-tool (action)
template can live-integrate; the other patterns are developer-scaffold-only
because the v0.37.5 loader does not accept generated apps, panels, settings
fragments, memory namespaces, or objective wiring as live targets. Templated
drafts share
`<ALLBERT_HOME>/dynamic_plugins/drafts/<slug>/` with v0.37 codegen drafts and
are inspectable through `mix allbert.dynamic drafts list/show/discard`. See
`docs/operator/templated-creation.md` for the operator flow and manual smoke.
The v0.39 onboarding destination is a separate Canvas destination, not the same
as `workspace:create`.

## What To Notice

- User input enters the runtime, not the UI layer.
- Runtime-facing work goes through registered Jido actions and the shared
  action runner.
- Risky work pauses as durable confirmation records before execution.
- CLI and `/workspace` render runtime state through the same action/context
  boundaries.
- Allbert Home contains the local runtime data for settings, confirmations,
  memory, traces, caches, and audits.

## Trying Risky Capabilities

Do not use a real `~/.allbert` while testing risky capabilities. Use the
release request-flow smoke matrix with a disposable home and workspace:

- v0.08 local shell execution: `docs/plans/v0.08-request-flow.md`
- v0.09 trusted skill script execution: `docs/plans/v0.09-request-flow.md`
- v0.10 external service, package install, and online skill import:
  `docs/plans/v0.10-request-flow.md`
- v0.36 generated Elixir/OTP sandbox gate runner:
  `docs/plans/v0.36-request-flow.md`
- v0.37 generated capability integration:
  `docs/plans/v0.37-request-flow.md`

v0.10 external-network testing should confirm that approval and target
execution are distinct. If a source HTTP/transport failure happens after
approval, the operator decision remains `approved` and the target result should
show `target_status=failed` with a visible failure reason.

v0.10 is implemented through M14 after the reopened M6-M9 sequence and was
released and tagged as `v0.10` on 2026-05-04. M12 landed the URI-first
`resource_uri` resource/grant authority. M13 added
`mix allbert.skills import-url` for direct HTTPS skill URLs and
`mix allbert.skills import-local` for local skill directories. Both import
disabled, untrusted, inactive, non-executable candidates under Allbert cache.
M14 added explicit unsupported/deferred UX for URL/document summarization,
document extraction, MCP/agent resource calls, broad web browsing/crawling,
and future channel-native approval handoff.

Remembered grant testing should use disposable confirmations and resources:

```sh
mix allbert.confirmations approve <confirmation-id> --reason "remember exact" --remember exact
mix allbert.resources grants list
mix allbert.resources grants show <grant-id>
mix allbert.resources grants revoke <grant-id> --reason "done testing"
```

For package installs or other multi-resource actions, approve with
`--remember exact --remember-all` only when every exact resource in the
request should be remembered for that operation. A target directory grant
alone does not authorize package registry/package-spec access.

## Safety Defaults

- Keep secrets in Settings Central secrets, not shell history or docs.
- Keep imported skills disabled and untrusted until reviewed separately.
- Treat Level 1 shell/script execution as host execution with policy controls,
  not OS isolation.
- Treat the v0.36 Elixir/OTP sandbox as default-off, report-only OS isolation
  for generated draft trials. Use approved local images only, prepare them
  through `mix allbert.sandbox image build` / `image verify`, and keep network
  disabled for sandbox gate runs.
- Treat v0.37 dynamic generation and live loading as separate default-off
  switches. `dynamic_codegen.enabled=true` may create source-bearing read-only
  action drafts, but those drafts remain untrusted evidence;
  `dynamic_codegen.live_loader_enabled=true` still cannot register authority
  without a v0.36 gate pass, trusted validation, and Security Central
  confirmation from a high-trust operator surface.
- Treat v0.10 network access as approved resource acquisition, not a browser,
  crawler, or arbitrary document summarizer.
- Treat remembered resource grants as Settings Central approval memory, not
  trust or execution authority. Grants are scoped by resource, operation,
  access mode, and downstream consumer, and still require Security Central
  policy re-check with the current action permission.
- Treat canonical `resource_uri` fields as the authority for matching. Redacted
  display URLs and rendered resource lines help operators inspect requests,
  but they are not remembered grant scopes.
- Pre-M12 remembered grants without `resource_uri` are not matched by the
  current pre-1.0 schema; re-create any still-needed grants through approval or
  `mix allbert.resources` flows.
- Use operation-scoped approvals for local path access, URL summaries,
  document inspection, local skill directory import, and direct skill URL
  import work.
- Treat `mcp://`, `agent://`, and `agent+https://` as unsupported future URI
  identities until a later release adds explicit actions, security policy,
  approval UX, adapters, traces, audits, and tests.

## Release Acceptance

Before accepting a release:

- Read `CHANGELOG.md`.
- Read the version plan and request-flow documents.
- Run the documented smoke matrix against a disposable Allbert Home.
- Confirm `git diff --check` and the release gates listed in the version plan
  passed.
- Confirm the expected tag name and whether the tag has already been created.
