# Entry-Point And CLI UX

Status: v0.60 M5 design artifact and v0.62 design input. This document defines
the packaged `allbert` command taxonomy, grouped help model, first-run detection,
first-model-state check, and wizard launch sequence for ADR 0076. It is design
only: v0.60 ships no binary, escript, release, install script, task, daemon, or
Allbert Home layout change.

## Current Inventory Snapshot

The current product entry surface is source/Mix oriented. A v0.60 source scan
found 55 Mix-task files under `apps/` and `plugins/`, including operator tasks,
developer/CI tasks, generators, package/plugin tools, public protocol utilities,
and plugin-owned commands. That is useful for development but too flat for the
technical-prosumer install and first-run journey.

M5 does not delete or rename Mix tasks. It defines the product-facing `allbert`
taxonomy v0.62 implements while developer/CI tasks remain available through Mix.

## Command Taxonomy

The packaged binary exposes one product entry point:

```text
allbert
  ask "<prompt>"
  chat
  tui
  serve [--open] [--daemon | --foreground]
  admin <area> <command>
  gen <kind> ...
```

Top-level commands:

| Command | Product job | Current source relationship | Notes |
|---|---|---|---|
| `allbert` | First-run/resume dispatcher. | No single equivalent today. | Detects Home/onboarding/model state and routes to wizard, serve/open, or help. |
| `allbert ask` | One-shot prompt. | `mix allbert.ask`. | Convenience path; no persistent channel identity. |
| `allbert chat` | Product chat session in the web workspace. | Split across web `/workspace`, ask, and TUI. | Primary target is the web workspace chat; v0.62 may temporarily fall back to a lightweight terminal/TUI session only while the web/onboarding surfaces are still incomplete or unavailable. |
| `allbert tui` | Persistent terminal operator channel. | `mix allbert.tui`, ADR 0067/0070. | Mix-free daily-use terminal path. |
| `allbert serve` | Run the local product and web workspace. | `mix phx.server` plus app boot. | Supports foreground and daemon/service management in v0.62. |
| `allbert admin` | Grouped operator inspection/configuration. | `mix allbert.settings`, `channels`, `jobs`, `objectives`, `confirmations`, `security`, `mcp`, `public_protocol`, etc. | Thin views over existing registered actions/settings boundaries. |
| `allbert gen` | Extension/developer generation helpers. | `mix allbert.gen.*`. | Kept separate from normal operator flow; never auto-runs from onboarding. |

Developer/CI tasks stay Mix-only unless a later ADR promotes them: release gates,
raw tests, migrations for test/dev, sandbox internals, validation helpers,
plugin-specific CI tasks, and source-tree maintenance commands.

## Grouped Help Model

`allbert --help` should be short enough for first-run and structured enough for
daily use:

```text
Allbert - local-first assistant workspace

Start
  allbert serve --open       Start the local web workspace
  allbert chat               Open or start web workspace chat
  allbert ask "..."          Ask one question
  allbert tui                Open the terminal operator console

Set up
  allbert                    Resume setup or open the product
  allbert admin onboarding   Re-run onboarding or review setup state
  allbert admin models       Check model/provider readiness

Operate
  allbert admin status
  allbert admin settings
  allbert admin channels
  allbert admin jobs
  allbert admin objectives
  allbert admin trust

Extend
  allbert admin apps
  allbert admin mcp
  allbert admin plugins
  allbert gen app|plugin|tool|flow

Development and CI stay under mix.
```

Subcommand help follows `allbert <group> --help` and lists only commands relevant
to that group. It should not expose every Mix task at top level.

## First-Run Detection

The first invocation of `allbert`, `allbert serve --open`, or `allbert chat`
checks product state before showing a raw command list:

| Detection | Meaning | Product response |
|---|---|---|
| Home missing | `ALLBERT_HOME` / default Home has not been initialized. | Explain Home location and route to onboarding initialization. |
| Home exists, schema incompatible | v0.59 settings/version contract blocks boot. | Show repair/upgrade guidance; do not launch partial product. |
| Onboarding incomplete | v0.63 wizard has not completed or was skipped. | Launch the onboarding wizard or show resume choices. |
| First-model state not ready | M3 local/BYOK path cannot yet reach first useful chat. | Launch model setup step with BYOK fallback visible. |
| Profile unreviewed | No persona/profile seed has been confirmed or explicitly skipped. | Show profile review step; never apply silently. |
| Product ready | Home, model path, and onboarding state are usable. | Start/open workspace or requested command. |

v0.60 does not define a new persisted onboarding key. v0.62/v0.63 choose the
read-model and storage shape, subject to Allbert Home, Settings Central, and the
v0.59 version contract.

## First-Model-State Check

Entry points consume the M3 first-model states:

- `local_ready`
- `runtime_missing`
- `runtime_unhealthy`
- `model_missing`
- `below_hardware_floor`
- `byok_ready`
- `blocked`

The CLI never assumes a hosted key or silently chooses egress. If local setup is
blocked, it offers BYOK fallback with egress posture and OS-vault storage called
out.

## Wizard Launch Sequence

```text
allbert
  -> resolve Allbert Home
  -> check settings/version contract
  -> check onboarding state
  -> check first-model state
  -> if setup needed:
       start local server if the web wizard is available
       open web wizard when --open or GUI open is allowed
       otherwise launch the CLI/TUI wizard with the same step ids
     else:
       open/resume workspace or show grouped help
```

Explicit setup entry stays available after first-run:

- `allbert admin onboarding` reopens onboarding state and profile review.
- `allbert admin models` runs model/provider readiness and repair.
- `allbert admin settings` opens settings inspection/editing paths.

The wizard target is `docs/design/onboarding-flow.md`. v0.62 implements entry
points and first-run detection; v0.63 implements wizard semantics.

## Mix-To-allbert Mapping

| Future product group | Existing task families | Rule |
|---|---|---|
| `ask`, `chat`, `tui`, `serve` | `allbert.ask`, `allbert.tui`, Phoenix server boot. | Product entry commands; `chat` is web-workspace-primary, with terminal/TUI fallback only for unavailable or unfinished web/onboarding surfaces. |
| `admin settings/models` | `allbert.settings`, `allbert.model`, model doctor reads. | Settings Central remains authority. |
| `admin channels` | `allbert.channels`, channel plugin doctors. | Channel setup remains confirmation/policy bounded. |
| `admin jobs/objectives` | `allbert.jobs`, `allbert.objectives`. | Operator inspection and control surface. |
| `admin trust` | `allbert.confirmations`, `allbert.security`, traces/audits where present. | No confirmation bypass; read/mutate split remains. |
| `admin apps/plugins/mcp/marketplace` | `allbert.apps`, `allbert.plugins`, `allbert.mcp`, `allbert.marketplace`, `allbert.skills`, `allbert.tools`. | Discovery/setup is explicit and policy-bounded. |
| `admin protocol` | `allbert.public_protocol`, `allbert.mcp_server`, `allbert.acp_server`. | Advanced operator/admin area, not first-run default. |
| `gen` | `allbert.gen.app`, `gen.plugin`, `gen.tool`, `gen.flow`, `gen.support`. | Extension/developer path, separate from onboarding. |
| Mix-only | `allbert.test`, `allbert.test.raw`, `allbert.ecto.migrate`, `allbert.sandbox`, `allbert.validate_app`, source-specific plugin CI tasks. | Development/CI remains source-tree only. |

## Authority And Scope Guardrails

- The `allbert` dispatcher grants no authority by routing to a surface.
- Admin commands route through existing actions, Settings Central, Security
  Central, channel boundaries, and confirmations.
- First-run copy and help text do not imply permission.
- `gen` commands never auto-run package managers, shell scripts, external
  installers, or provider calls from onboarding.
- Developer/CI tasks do not become product commands without explicit v0.62 scope.
- v0.60 does not create the binary, daemon, service files, OS-vault integration,
  guided install, model pull, or wizard launch code.

## Handoff To v0.62

v0.62 implements this taxonomy in ADR 0076 alongside packaging. It must prove the
binary can start the product without Elixir/OTP on a Tier-1 OS, expose grouped
help, route first-run into the v0.63 wizard target, consume M3 first-model-state,
and keep developer/CI tasks out of the first-run product surface.
