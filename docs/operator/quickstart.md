# Quickstart: Install, Open, Chat

This is the shortest supported path to a working Allbert 1.2 assistant. You
do not need to complete onboarding, choose a persona, configure an identity
map, or pull a model before opening chat.

> **Version note:** the zero-click behavior in this guide requires Allbert
> 1.2.0 or later. The stable Homebrew and signed-curl paths now install 1.2.0;
> verify the installed package with `allbert --version`. The daemon-backed TUI
> section below begins with 1.2.5; on 1.2.0 use the web workspace until the
> point update is installed.

## 1. Install And Start

Homebrew is the recommended package path on macOS and Linux:

```sh
brew install lexlapax/allbert/allbert
brew services start allbert
curl -fsS http://localhost:4000/health
```

The health response passes when it contains `"status":"ok"`. The signed curl
installer, WSL2 support, upgrades, and uninstall instructions are in
[Installing Allbert](install.md).

## 2. Open The Workspace

Open [http://localhost:4000/workspace](http://localhost:4000/workspace) in a
browser and ask a normal question, for example:

```text
What is the capital of France?
```

Allbert detects what is already usable and keeps chat open in every state:

| What Allbert finds | First-chat behavior |
|---|---|
| A ready DirectAnswer task profile | Selects its task head, enables model answers when that setting has never been written, and shows the applicable local-processing or hosted-egress disclosure once. |
| Only the curated `local` / `llama3.2:3b` starter is ready | Keeps chat open, but reports DirectAnswer unavailable until the selected `direct_answer_local` / `qwen2.5:7b` profile is selected and pulled. Starter readiness is not DirectAnswer readiness. |
| A configured hosted-provider key | Uses it only when that hosted profile is explicitly the DirectAnswer task head (or the task list is empty and the compatibility primary names it), and shows an egress disclosure before the first model-backed send. Detection checks credential presence; it does not make a hidden provider request. |
| No usable provider | Returns a bounded, deterministic answer and shows one primary repair action in Models. Chat and the rest of the workspace remain usable. |
| A missing model or unhealthy local runtime | Keeps the local path selected and offers the relevant repair action. It does not silently switch to hosted inference. |
| Hardware below the curated local-model floor | Offers hosted setup when a configured key is present; otherwise it explains the hardware constraint and available choices. |

Allbert never installs a runtime, pulls a model, sends a hosted prompt, or
changes an explicit model-answer preference just because you opened chat.
Downloads and other effectful repairs require an explicit action and the normal
confirmation flow. If you previously set
`intent.direct_answer_model_enabled=false`, that choice remains disabled.

## 3. Use The Terminal Instead (Optional)

For a terminal-first session, keep the background service running and attach
the thin TUI client:

```sh
brew services start allbert
curl -fsS http://localhost:4000/health
allbert tui
```

On a fresh Allbert Home, the built-in `default` terminal profile is enabled and
mapped to the canonical local user before the first prompt. Ask a question
immediately. Use `/help` for commands, `/models` for current model health,
`/catalog` for the model catalog, and `/quit` to exit.

The TUI owns only terminal input and rendering; the service remains the one
Runtime/database owner. Web and TUI may be used concurrently through that same
daemon, but only one TUI session may attach to a Home. If no daemon is
available, `allbert tui` exits with service/`allbert serve` repair guidance and
does not start an embedded writer. See the [TUI guide](tui-channel.md) for
custom profiles, source-checkout setup, terminal recovery, and web/TUI
continuity.

## Customize Later

Onboarding is an optional customization and repair surface, not a gate to chat:

```sh
allbert onboard
```

Use it to review a profile, add a provider, or repair local-model readiness. The
web Models panel and these packaged commands expose the same operational model
information:

```sh
allbert admin models list
allbert admin models catalog
allbert admin models doctor local
allbert admin models doctor direct_answer_local
allbert admin models use-direct-answer direct_answer_local
allbert admin settings doctor
```

To store a hosted-provider credential without placing the secret on the command
line, use the interactive vault path:

```sh
allbert admin settings providers set-key openai
```

All hosted use remains subject to the egress disclosure. To explicitly disable
or re-enable model answers:

```sh
allbert admin settings set intent.direct_answer_model_enabled false
allbert onboard re-enable-model
```

## If First Chat Is Not Model-Backed

Open the Models panel in the workspace first. It should show one primary action
matching the detected condition:

- **Needs model:** review and confirm the curated model pull, or select an
  already available catalog entry. If the starter `local` profile is already
  ready, use the `direct_answer` catalog row to select/pull
  `direct_answer_local` rather than pulling the starter again.
- **Needs runtime, Ollama is not installed:** select **Install local runtime**,
  review the exact installer action, and approve it. Allbert uses Homebrew's
  Ollama package on macOS and Ollama's upstream installer on Linux; detection
  alone never downloads or installs anything.
- **Needs runtime, Ollama is installed but not answering:** start or repair the
  existing Ollama service instead of reinstalling it. Allbert does not replace
  an unhealthy runtime with hosted inference automatically. See
  [Onboarding: Readiness And Repair](onboarding.md#readiness-and-repair) for the
  preview/apply command path.
- **Needs credentials:** add a hosted-provider key through the vault-backed
  settings path.
- **Needs review:** inspect the selected profile and the explicit
  `intent.direct_answer_model_enabled` setting.

For deeper diagnosis, run:

```sh
allbert admin health
allbert admin settings model-doctor
allbert admin settings providers list
```

Provider keys are redacted in all three surfaces. See
[Model recommendations](model-recommendations.md) for model tradeoffs and
[Security hardening](security-hardening.md) for confirmations, secrets, and
egress controls.

## Continue From Here

- [Workspace](workspace.md) — conversations, Models, settings, objectives, and
  panels.
- [Onboarding](onboarding.md) — optional profiles, providers, integrations, and
  repair.
- [Local knowledge](local-knowledge.md) — connect notes and review memory.
- [Operator docs](README.md) — complete task-based guide index.

Contributors running from source should use [DEVELOPMENT.md](../../DEVELOPMENT.md)
and a disposable `ALLBERT_HOME`; Mix tasks are source-checkout twins, not the
packaged operator interface.
