# TUI Channel Operator Guide

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

The TUI is Allbert's persistent terminal channel. Normal turns, read-only
inspection, typed approvals, fan-out status, and Pi-mode coding share the same
runtime, Settings Central, Security Central, traces, and identity boundary as
the web workspace.

## Start A Session

Stop any web/service runtime that owns this Allbert Home, then run:

```sh
allbert tui
```

For a source checkout, the twin is `mix allbert.tui`. Do not run either
standalone TUI beside `allbert serve`, a packaged service, or another Mix
runtime against the same Home.

The prompt is line-oriented:

```text
allbert:default>
```

Enter a complete turn on one line. Type `/help` to list current commands and
`/quit` or `/exit` to stop the launcher. Responses and coalesced progress remain
in normal terminal scrollback; the TUI does not require a full-screen or
alternate-screen terminal.

## Fresh-Home Identity Bootstrap

On a fresh Home, the built-in local launcher atomically writes these keys before
the adapter starts:

- `channels.tui.enabled=true`
- an enabled `default → local` entry in `channels.tui.identity_map`

The first normal question therefore needs no setup command. The transaction is
idempotent across restarts and does not complete, skip, or otherwise mutate
onboarding.

Raw-present operator state is binding. The launcher does not replace an
explicit `channels.tui.enabled=false`, an empty map, a disabled entry, or a
custom map. Unmapped or disabled input produces a bounded `Message not sent`
explanation and never reaches Runtime.

Re-enable a deliberately disabled built-in channel with:

```sh
allbert admin settings set channels.tui.enabled true
```

## Custom Profiles And Users

Set the full mapping before launch when the terminal profile should resolve to
a user other than built-in `local`:

```sh
allbert admin settings set channels.tui.identity_map \
  '[{"external_user_id":"work","user_id":"alice","enabled":true}]'
allbert admin settings set channels.tui.profile work
allbert admin settings get channels.tui.identity_map
allbert admin channels show tui
```

Identity mapping admits a terminal sender; it grants no capability, file,
provider, confirmation, or web authorization.

## Slash Commands

Slash commands are local operator controls. They do not become model turns or
create ordinary channel-event rows.

| Command | Purpose |
|---|---|
| `/status` | Runtime/operator status. |
| `/confirmations` | Bounded confirmation list. |
| `/events` | Recent operator events. |
| `/channels` | Channel health and configuration summary. |
| `/intents` | Redacted intent-coverage report. |
| `/models` | Redacted model-doctor report. |
| `/catalog` | Shared redacted model catalog, including Llama and Qwen choices. |
| `/jobs` | Current job list. |
| `/objective <id>` | Inspect one objective. |
| `/trace`, `/registry`, `/memory`, `/health` | Read-only diagnostics. |
| `/model-detect` | Run the bounded first-model readiness read. |
| `/settings get <key>` | Read one non-secret setting. |
| `/pi`, `/mode`, `/model`, `/clear`, `/init`, `/diff`, `/compact` | Pi-mode session controls. |

Commands that read operator data require the mapped TUI identity. Unknown or
malformed slash input is inert and points to `/help`; it is never forwarded to
the model. Secret-bearing settings remain redacted.

## Model Readiness And First Chat

The TUI starts even when a model is not ready. On a fresh Home, first-run
detection applies the same local-first selection and sticky-disable rules as
the web workspace:

- a usable provider can answer the first normal question without onboarding;
- the applicable local-processing or hosted-egress disclosure appears once per
  surface/provider selection;
- missing or unhealthy local state returns the bounded fallback and a repair
  direction rather than blocking the prompt; and
- no runtime install, model pull, hosted probe, or inference happens silently.

Use `/catalog` to compare choices and `/models` to diagnose configured purpose
profiles. Use the web Models panel or `allbert admin models …` for selection,
confirmed pulls, and deeper repair.

## Confirmations

When an action needs approval, the TUI prints exact typed commands and numbered
options, including:

```text
ALLBERT:SHOW:<id>
ALLBERT:APPROVE:<id>
ALLBERT:DENY:<id>
```

Enter one exact command at the same prompt. Approval resumes only the named
durable confirmation through Security Central; ordinary text such as `yes`
never approves an action. Terminal presentation uses `surface_payload`, while
conversation history retains only `model_payload`.

## Fan-Out And Steering

An eligible multi-task turn prints its kickoff before child work begins. The
TUI then shows `[fan-out]` lifecycle lines and one honest joined report. Mixed
terminal outcomes are `partial`; all-cancelled work is `cancelled`. A failed
terminal write leaves the exact report receipt pending so the report can return
on a later turn.

One session can track multiple fan-outs. Plain replies can steer or cancel a
named child. If more than one fan-out is active, an unqualified Escape
cancellation asks which target you mean instead of guessing. Attached TUI
reporting does not enable default-off autonomous remote notifications.

## Pi-Mode Coding

Pi mode extends this same channel with streaming, tool-call, and Escape-cancel
behavior. It does not create a separate authority boundary. Configure a trusted
operator, repository jail, command allowlist, model profile, and confirmation
posture before entering `/pi`. See [Pi-mode coding](pi-mode-coding.md).

## Web Continuity

After `/quit`, start the service/web runtime with the same Home and open
`/workspace`. TUI `default` and web `web-local` independently resolve to
canonical user `local`, so eligible durable user and conversation data is
shared. The TUI mapping does not authorize web access, and opening the workspace
does not automatically select the exact TUI thread; choose it explicitly when
continuity is wanted.

## Diagnostics

Post-start application logs are quiet by default. Enable or suppress them for
one session without hiding operator-facing lifecycle output:

```sh
ALLBERT_TUI_LOG_LEVEL=debug allbert tui
ALLBERT_TUI_LOG_LEVEL=none allbert tui
```

If a normal turn is rejected, inspect:

```text
/settings get channels.tui.enabled
/settings get channels.tui.identity_map
/models
/health
```

If the launcher says another runtime owns the database, stop that runtime; do
not bypass the writer lock or point two processes at the same Home.

## Release Validation Is Separate

Release-specific transcript capture, fresh-Home audit counts, cross-platform
commands, and PASS criteria live in the active
[request-flow document](../plans/README.md). Historical TUI release replay lives
with archived request flows, not in this everyday guide.
