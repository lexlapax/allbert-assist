# ADR 0062: HEARTBEAT.md joins the bootstrap bundle in v0.8

Date: 2026-04-20
Status: Accepted

## Context

[ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md) established the bootstrap bundle (`SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, optional `BOOTSTRAP.md`) and explicitly deferred `AGENTS.md` and `HEARTBEAT.md` until "broader session surfaces, proactive jobs, or group-chat behavior" made them pull their weight.

[ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md) adopted `AGENTS.md` in v0.3 once agents became first-class runtime participants. It noted: "`HEARTBEAT.md` is a separate question tied to async channel rhythms. v0.6 channel expansion is the right time to reopen it." v0.6 did not reopen it. v0.7 reopened it briefly and deferred again with the note that "channel rhythm alone is not enough reason to add another bootstrap artifact — revisit only if async channels produce demonstrable operator pain."

v0.8 meets the missing condition. Cross-channel continuity means the assistant has legitimate reason to *push* — check-ins, inbox nags, summary nudges — on a channel the operator chose. Without `HEARTBEAT.md`, that push is either silent (useless) or unilateral (wrong). The operator needs an inspectable, editable place to say "here is when I want to be pushed to, on which channel, and when I want to be left alone."

v0.8 also provides concrete downstream demand. v0.6 M5 left `daily-brief` and `weekly-review` jobs disabled with the note "they require operator-confirmed scheduling preferences." `HEARTBEAT.md` is exactly that place, and v0.8 is exactly the moment to provide it.

## Decision

`HEARTBEAT.md` joins the bootstrap bundle in v0.8.

### Location and ownership

`~/.allbert/HEARTBEAT.md`, alongside `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`.

**User-owned**, like `SOUL.md` and `IDENTITY.md`. Kernel seeds a template on first boot in v0.8+ (or on upgrade). Edits are operator-authored; the kernel does not regenerate the file. This is the opposite ownership model from `AGENTS.md` (kernel-regenerated from the skill roster).

### Frontmatter schema

```yaml
---
version: 1
timezone: "America/Los_Angeles"
primary_channel: telegram          # where push nudges go by default
quiet_hours:
  - "22:00-07:00"                  # range in `timezone`; multiple ranges allowed
check_ins:
  daily_brief:
    enabled: false
    time: "08:00"
    channel: telegram
  weekly_review:
    enabled: false
    day: "Sunday"
    time: "20:00"
    channel: telegram
inbox_nag:
  enabled: true
  cadence: daily                   # daily | weekly | off
  time: "09:00"
  channel: telegram
---

# Cadence

<operator-authored notes about preferred rhythm>
```

- `timezone` uses IANA names.
- `quiet_hours` ranges are inclusive-start, exclusive-end.
- `check_ins.<job>` corresponds to v0.6 M5's deferred maintenance jobs. Opt-in by setting `enabled: true`. v0.8 does not flip them on; this ADR provides the schema.
- `inbox_nag` controls the push-model counterpart to the pull-model inbox (ADR 0060). Default: daily at 09:00 to `primary_channel`, which the kernel can render as a one-line pending-items summary.

### Kernel consultation points

- **Push nudges** (inbox nag, check-in output, unsolicited notifications from jobs): consult `quiet_hours` in `timezone`. Inside a quiet range, queue until the window ends. Route to `primary_channel` unless the caller specifies otherwise.
- **Scheduled jobs** (`daily-brief`, `weekly-review`, any future proactive job): execute only if `check_ins.<job>.enabled = true`. The job's own schedule DSL (ADR 0022) can still override for operators who prefer cron-style control; HEARTBEAT.md is the operator-friendly surface.
- **Inbox nag**: if enabled, the kernel composes a short pending-items summary from ADR 0060's inbox view at `time` on the configured `cadence` and sends to `channel` (defaulting to `primary_channel`).
- **Absence is fail-silent**: if `HEARTBEAT.md` is missing or malformed, the kernel defaults to "no push, no proactive check-ins, no inbox nag." This is the conservative stance — the assistant does nothing the operator did not ask for.

### Prompt inclusion

`HEARTBEAT.md` is snapshotted at the start of each user turn and injected ahead of memory and skills, bounded by the same dedicated bootstrap budget ADR 0010 defined. Concretely, v0.8 reuses the existing bootstrap limits: `limits.max_bootstrap_file_bytes` remains the per-file cap and `limits.max_prompt_bootstrap_bytes` remains the aggregate cap across `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, and `HEARTBEAT.md`. The assistant is expected to read and respect cadence context (e.g. avoid suggesting work during quiet hours).

This mirrors how `SOUL.md` et al. behave. `HEARTBEAT.md` is *not* a derived artifact — it is operator ground truth — but it is also not unique in the bootstrap bundle.

### CLI

- `allbert-cli heartbeat show` — render current `HEARTBEAT.md`.
- `allbert-cli heartbeat edit` — open in `$EDITOR`.
- `allbert-cli heartbeat suggest [--channel <kind>]` — a small wizard that proposes defaults based on the current identity (ADR 0058) and registered channels. Writes a proposed `HEARTBEAT.md` to a scratch path; the operator reviews and accepts.

### Continuity-bearing

Per ADR 0061, `HEARTBEAT.md` is continuity-bearing and ships in profile export/import. Across devices, the same cadence applies unless the operator edits per-device.

## Consequences

**Positive**

- Closes the v0.6 M5 gap for operator-confirmed scheduling preferences. `daily-brief` and `weekly-review` have a home without re-enabling them by default.
- Push notifications become legible and respectful: no unexpected pings inside quiet hours; no pings on channels the operator did not bless.
- Natural-interface (ADR 0038) consistency: operators express cadence as markdown, not code.
- Parallels `SOUL.md`/`IDENTITY.md`/`USER.md` ownership: operator-authored, kernel-snapshotted.

**Negative**

- One more bootstrap file; prompt budget grows slightly on every turn.
- The schema introduces operator-facing structured fields (timezones, time ranges, channel references). Validation errors need to be clear, not cryptic. The CLI wizard reduces this risk.
- HEARTBEAT.md's fail-silent default means a misconfigured file quietly disables push behaviour. Preferable to the alternative (loud failure on a non-critical subsystem), but `allbert-cli heartbeat show` should surface validation warnings.

**Neutral**

- `AGENTS.md` remains kernel-regenerated; `HEARTBEAT.md` is user-owned. Distinct ownership models for distinct purposes.
- `BOOTSTRAP.md` (ADR 0010's one-time ritual file) is unchanged.
- Does not unblock `trace-triage` or `system-health-check` maintenance jobs; those remain disabled per v0.6 M5's separate rationale.

## References

- [ADR 0010](0010-bootstrap-personality-files-are-first-class-runtime-context.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0039](0039-agents-md-joins-the-bootstrap-bundle-in-v0-3.md)
- [ADR 0055](0055-channel-trait-with-capability-flags.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [docs/plans/v0.06-foundation-hardening.md](../plans/v0.06-foundation-hardening.md) — M5 deferred jobs that this ADR unblocks.
- [docs/plans/v0.08-continuity-and-sync.md](../plans/v0.08-continuity-and-sync.md)
