# ADR 0022: Job definitions are markdown with frontmatter and use a bounded schedule DSL

Date: 2026-04-18
Status: Accepted

## Context

The v0.2 plan introduces `JobManagerService` with job definitions under `~/.allbert/jobs/definitions/`, but never specifies the file format or how schedules are expressed. Both are load-bearing decisions:

- The file format dictates parser choice, diff-friendliness, edit UX, and how bundled templates look.
- The schedule expression dictates what users can and cannot automate, how due-job evaluation works, and how portable job definitions are across systems.

Format options considered:

1. TOML/YAML config files — machine-friendly but clumsy for the prompt body.
2. Markdown + YAML frontmatter — matches the existing skills format (v0.1 uses `gray_matter` for skills), lets the job prompt be a readable markdown body, and keeps metadata declarative.
3. A bespoke jobs DSL — new parser, new mental model, poor fit for local-first editing.

Schedule expression options considered:

1. Full cron syntax — expressive but easy to get wrong, hard to read at a glance, and different platforms ship slightly different variants.
2. A bounded DSL that covers the realistic cases (`@daily`, `@hourly`, `@weekly`, `every <duration>`, `at <HH:MM>`) plus a pass-through for explicit cron expressions when needed.
3. Structured interval objects in frontmatter only (`every: 1h`) — simpler but loses one-shot and fixed-time cases.

Option 2 for each pairs well: skills already use markdown+frontmatter, and a bounded DSL with a cron escape hatch covers the maintenance-first scope of v0.2 without forcing users to learn cron.

## Decision

Job definitions are markdown files with YAML frontmatter. Schedules use a bounded DSL with a cron escape hatch. This is the canonical persistence format whether a job is authored from a file, through `allbert-cli jobs upsert`, or later through prompt-native job authoring.

### File format

- Job definitions live at `~/.allbert/jobs/definitions/<name>.md`.
- The filename (minus `.md`) is the canonical job name; it must be kebab-case, unique, and stable.
- The file has YAML frontmatter followed by a markdown body.
- The markdown body is the job prompt, layered on top of any attached skills' prompts (per ADR 0016).

### Frontmatter schema (v0.2)

```yaml
---
name: daily-brief                  # required, matches filename
description: Morning summary ...    # required, one-line
enabled: false                      # required, defaults to false for bundled templates
schedule: "@daily at 07:00"         # required, schedule expression (DSL or cron)
skills: [morning-review]            # optional, ordered list (ADR 0016)
timezone: America/Los_Angeles       # optional; falls back to jobs.default_timezone, then system local time
session_name: morning-routine       # optional; share ephemeral working memory across runs
memory:                             # optional; per-job memory tuning
  prefetch: false                   # optional; disable automatic prefetch for this job
model:                              # optional; same shape as ModelConfig if overriding the daemon default
  provider: anthropic
  model_id: claude-sonnet-4-5
budget:                            # optional; per-turn budgeting for this job's root turn
  max_turn_usd: 0.25               # optional; overrides global limits.max_turn_usd
  max_turn_s: 90                   # optional; overrides global limits.max_turn_s
allowed-tools: [read_memory, write_memory]  # optional; intersects global policy
timeout_s: 600                      # optional, per-run wall-clock cap
report: on_anomaly                  # optional: always | on_failure | on_anomaly
max_turns: 8                        # optional override of global limits
---
```

Unknown frontmatter keys are rejected at parse time (v0.2) to keep the format auditable. A future version may introduce an `extensions` block if user-defined metadata becomes necessary.

`session_name` and `memory.prefetch` are part of the accepted schema as of the shipped v0.5 runtime. `session_name` lets repeated runs share a named ephemeral working buffer for daemon-lifetime continuity. `memory.prefetch: false` opts a job out of the automatic curated-memory prefetch path introduced in v0.5. The canonical persisted shape is nested `memory.prefetch`; runtimes may continue to accept a legacy flat `memory_prefetch` alias for backward compatibility, but docs and future serializers should use the nested form.

`budget.max_turn_usd` and `budget.max_turn_s` are part of the accepted schema as of the v0.7 planning freeze. They override the global per-turn defaults for job-originated root turns only. If omitted, the job inherits `limits.max_turn_usd` and `limits.max_turn_s`. Remaining daily cap still clamps the effective usable budget lower than either source when applicable.

### Schedule DSL (v0.2)

Supported expressions:

- `@hourly`, `@daily`, `@weekly`, `@monthly` — fixed presets anchored to local time
- `@daily at HH:MM` — daily at a specific local time
- `@weekly on <weekday> at HH:MM` — e.g. `@weekly on monday at 09:00`
- `every <duration>` — `every 15m`, `every 2h`, `every 12h`; evaluated from persisted schedule state
- `cron: <expression>` — explicit 5-field cron expression as an escape hatch
- `once at <RFC3339>` — one-shot runs; the job becomes disabled after the run completes

Timezone resolution order is explicit:

1. `timezone:` in the job frontmatter
2. `config.jobs.default_timezone`
3. system local timezone

The schedule engine persists `next_due_at` for every enabled job. If the daemon was down and `next_due_at <= now` at startup, the job becomes due once immediately as a coalesced catch-up run, and then `next_due_at` is advanced until it lands in the future. Missed intervals are not replayed one-by-one. The same coalesced catch-up rule applies to fixed-time schedules and cron expressions.

All time-of-day fields resolve through that timezone order. The DSL is parsed into a single internal `Schedule` representation so due-job evaluation has one code path regardless of surface syntax.

### Bundled templates

Bundled job templates (ADR 0017) must ship with `enabled: false` and use the DSL form (not raw cron) so they read clearly to a user inspecting `~/.allbert/jobs/definitions/`.

## Consequences

**Positive**
- Reuses the skills file shape users already understand.
- Makes the prompt body the primary readable surface, with metadata confined to frontmatter.
- Bounds the surface area of the schedule syntax so due-job evaluation and docs stay small.
- Keeps a cron escape hatch for power users without forcing everyone into cron.
- Rejecting unknown frontmatter keys prevents silent drift as the schema evolves.
- Makes job timing deterministic across daemon restarts and machines whose host timezone differs from the user's intended timezone.

**Negative**
- Adds a small DSL parser plus a cron parser to the daemon. Both must be well-tested.
- Local-time anchoring means jobs can skip or double-fire around DST transitions; behavior must be explicitly documented.
- Coalesced catch-up means v0.2 intentionally prefers "at most one make-up run" over replaying every missed interval during long downtime.

**Neutral**
- Future versions can extend the frontmatter schema (e.g. retry policy, resource limits) behind a version bump.
- `once at …` is the natural seed for a future "queue this job for later" surface without redesigning the format.
- A future UI for authoring jobs would still target this file format directly.
- Prompt-authored jobs should compile into this same canonical format rather than introducing a second persisted representation.

## References

- [ADR 0002](0002-skill-bodies-require-explicit-activation.md)
- [ADR 0016](0016-scheduled-runs-use-fresh-sessions-and-may-attach-ordered-skills.md)
- [ADR 0017](0017-v0-2-ships-bundled-job-templates-disabled-by-default.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
