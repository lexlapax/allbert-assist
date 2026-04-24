# HEARTBEAT.md operator guide

`~/.allbert/HEARTBEAT.md` is the v0.8 operator file for proactive cadence policy. It does two jobs:

- it joins the prompt bootstrap bundle so the assistant can see your preferred cadence and quiet hours
- it gives the daemon an inspectable policy file for `daily-brief`, `weekly-review`, and inbox nags

Use `cargo run -p allbert-cli -- heartbeat show` to inspect the parsed view plus validation warnings, `heartbeat edit` to open the real file in `$EDITOR`, and `heartbeat suggest` to write a scratch proposal you can review before copying into place.

## Shipped schema

Typical frontmatter:

```yaml
---
version: 1
timezone: America/Los_Angeles
primary_channel: telegram
quiet_hours:
  - "22:00-07:00"
check_ins:
  daily_brief:
    enabled: false
    time: "08:30"
    channel: telegram
  weekly_review:
    enabled: false
    day: monday
    time: "09:00"
    channel: telegram
inbox_nag:
  enabled: true
  cadence: daily
  time: "09:00"
  channel: telegram
---
```

Field reference:

- `timezone`: IANA timezone such as `UTC` or `America/Los_Angeles`
- `primary_channel`: default delivery surface for proactive items
- `quiet_hours`: one or more `HH:MM-HH:MM` local-time windows during which proactive delivery is suppressed
- `check_ins.daily_brief.enabled`: opt-in gate for the bundled `daily-brief` job
- `check_ins.daily_brief.time`: local wall-clock time for that job when enabled
- `check_ins.daily_brief.channel`: optional override for the delivery channel; falls back to `primary_channel`
- `check_ins.weekly_review.enabled`: opt-in gate for the bundled `weekly-review` job
- `check_ins.weekly_review.day`: weekday name for the weekly review
- `check_ins.weekly_review.time`: local wall-clock time for the weekly review
- `check_ins.weekly_review.channel`: optional override for the delivery channel
- `inbox_nag.enabled`: opt-in gate for one-line inbox reminders
- `inbox_nag.cadence`: `daily`, `weekly`, or `off`
- `inbox_nag.time`: local wall-clock delivery time
- `inbox_nag.channel`: optional override for the nag delivery channel

## Runtime behavior

Shipped v0.8 behavior:

- missing or malformed `HEARTBEAT.md` fails silent: no proactive check-ins and no inbox nag
- `daily-brief` and `weekly-review` remain default-off until their `enabled` flags are set
- `quiet_hours` suppress unsolicited delivery during the configured local-time window
- inbox nags render from the shared approval inbox rather than from one surface's local view

Current boundary:

- proactive delivery is currently implemented only for `telegram`
- choosing `repl`, `cli`, or `jobs` as a proactive channel is allowed in the file, but `heartbeat show` warns and the daemon skips unsolicited delivery there

## Validation warnings

`heartbeat show` surfaces warnings instead of failing closed with a stack trace. Common warnings:

- unknown timezone name
- malformed quiet-hours range
- missing or invalid `HH:MM` time
- `weekly_review.day` not matching a weekday name
- proactive channel set to something other than `telegram`

The warning path is deliberate: the file stays user-editable, and the daemon falls back to "do nothing proactively" rather than guessing.
