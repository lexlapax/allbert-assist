# TUI operator guide

v0.11 adds a Ratatui/Crossterm terminal UI as the default interactive surface for fresh profiles. The TUI is only a frontend adapter: the daemon and kernel still own turns, tools, memory, approvals, cost, telemetry, and session state.

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
```

If raw mode or alternate-screen setup fails, the CLI prints a one-line notice and falls back to classic REPL instead of aborting the session.

## Controls

- Type a message and press Enter to send it.
- Slash commands such as `/help`, `/status`, `/telemetry`, `/statusline`, `/memory stats`, and `/memory routing` run locally, matching the classic REPL command shape.
- Ctrl-D exits the TUI.
- Ctrl-C does not kill the daemon; it prints a reminder to use `/exit`.
- Confirmation modals accept `y` for allow once, `n` or any other key for deny, and `a` for allow-session when the request is not a durable mutation.

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

The command persists to config immediately in v0.11. Unknown item names are rejected locally.

## Narrow Terminals

The TUI compacts the status line when the terminal is narrow. The minimum compact posture keeps model, context, and cost visible when possible. For very small terminals, use classic mode as the escape hatch:

```bash
cargo run -p allbert-cli -- repl --classic
```

## Related Docs

- [Telemetry operator guide](telemetry.md)
- [v0.11 upgrade notes](../notes/v0.11-upgrade-2026-04-24.md)
