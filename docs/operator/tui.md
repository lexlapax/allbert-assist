# TUI operator guide

v0.12.1 made the Ratatui/Crossterm terminal UI the main operator-legibility surface. v0.12.2 adds durable trace/replay commands to that same surface. The TUI is still only a frontend adapter: the daemon and kernel own turns, tools, memory, approvals, cost, telemetry, activity, trace state, and session state.

## Launching

Fresh profiles launch the TUI by default:

```bash
cargo run -p allbert-cli --
```

Existing upgraded profiles keep the classic Reedline REPL unless you opt in:

```bash
cargo run -p allbert-cli -- repl --tui
cargo run -p allbert-cli -- repl --classic
```

Those flags affect only the current invocation. Add `--save` when you want to persist the choice in `~/.allbert/config.toml`:

```bash
cargo run -p allbert-cli -- repl --tui --save
```

Equivalent config:

```toml
[repl]
ui = "tui" # or "classic"

[repl.tui]
mouse = true
max_transcript_events = 500
spinner_style = "braille"
tick_ms = 80
```

If raw mode or alternate-screen setup fails, the CLI prints a one-line notice and falls back to classic REPL instead of aborting the session.

## Controls

- Type a message and press Enter to send it.
- Slash commands such as `/help`, `/activity`, `/status`, `/telemetry`, `/trace`, `/settings`, `/inbox`, `/skills`, `/memory`, and `/self-improvement` run locally, matching the classic REPL command shape.
- While a turn is running, the screen redraws asynchronously and shows the daemon-owned activity label, elapsed time, tool summary, and stuck hint when available.
- Text typed during a running turn is kept as a next-turn draft. Pressing Enter while work is in flight keeps the draft and does not queue a concurrent turn.
- Ctrl-D exits the TUI.
- Ctrl-C does not kill the daemon or cancel the active turn; it prints a truthful reminder.
- Confirmation modals accept `y` for allow once, `n` or any other key for deny, and `a` for allow-session when the request is not a durable mutation. Input modals keep their own buffer separate from the next-turn draft.

## Status Line

The status line renders from daemon telemetry, not from shell hooks or client-side scraping. The default catalog is:

```toml
[repl.tui.status_line]
enabled = true
items = ["model", "context", "tokens", "cost", "memory", "intent", "skills", "inbox", "channel", "trace"]
```

Use `/statusline` to inspect or change the configured items:

```text
/statusline show
/statusline toggle cost
/statusline add memory
/statusline remove trace
/statusline disable
/statusline enable
```

The command persists to config immediately. Unknown item names are rejected locally.

## Settings And Discovery

Use `/settings` for supported profile edits without hand-editing TOML:

```text
/settings list ui
/settings show repl.tui.spinner_style
/settings set repl.tui.spinner_style off
/settings reset repl.tui.spinner_style
```

Settings writes are typed, allowlisted, path-preserving TOML edits. Unsupported keys, unsafe paths, secrets, and edits that cannot preserve unrelated TOML structure are rejected with a hint instead of rewriting the whole config.

Unknown slash commands suggest a close match when the typo is small, for example `/stats` suggests `/status`. Typing a supported command with a trailing `--` shows a one-line argument hint.

## Trace Replay

Use `/trace` when you want after-the-fact history rather than live activity:

```text
/trace show
/trace show <session-id>
/trace show-span <span-id>
/trace tail
/trace export <session-id>
/trace settings
```

Trace output is rendered inline in the transcript area. `/trace tail` subscribes to completed span broadcasts for the current or named session. Trace export writes file-based OTLP-JSON under `ALLBERT_HOME`; there is no network exporter.

Trace settings are ordinary typed settings:

```text
/settings show trace
/settings set trace.capture_messages false
/settings set trace.redaction.provider_payloads summary
```

## Review And Recovery

The TUI now exposes the v0.12 review workflows directly:

```text
/inbox list
/inbox show <approval-id>
/inbox accept <approval-id> --reason "reviewed"
/memory staged list
/memory staged show <id>
/skills list
/skills show <name>
/self-improvement diff <approval-id>
/self-improvement install <approval-id>
```

Recovery-only flows remain CLI commands: `allbert-cli memory restore <id>`, `allbert-cli memory reconsider <id>`, `allbert-cli skills disable|enable <name>`, and `allbert-cli config restore-last-good`.

## Narrow Terminals

The TUI compacts the status line when the terminal is narrow. The minimum compact posture keeps model, context, and cost visible when possible. For very small terminals, use classic mode as the escape hatch:

```bash
cargo run -p allbert-cli -- repl --classic
```

## Related Docs

- [Telemetry operator guide](telemetry.md)
- [Tracing operator guide](tracing.md)
- [v0.12.2 upgrade notes](../notes/v0.12.2-upgrade-2026-04-25.md)
