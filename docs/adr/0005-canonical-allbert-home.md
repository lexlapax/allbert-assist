# ADR 0005: Canonical Allbert Home

## Status

Accepted.

## Context

Allbert is accumulating durable local runtime data: markdown memory, traces,
settings, encrypted secrets, SQLite database files, user skills, imported skill
caches, generated runtime artifacts, and temporary files.

Before v0.02, those paths were drifting. Memory defaulted to a project-local
`var/allbert/memory`, Settings Central was planned under
`var/allbert/settings`, development databases lived beside `config`, and later
skill plans referenced `~/.allbert/skills`.

That split makes backup, migration, inspection, and future profile export more
fragile. It also encourages every subsystem to invent its own path precedence.

## Decision

Allbert will have one canonical local home directory for durable runtime data.

Canonical environment variable:

- `ALLBERT_HOME`

Accepted compatibility alias:

- `ALLBERT_HOME_DIR`

Default:

- `~/.allbert`

The expected layout is:

```text
<ALLBERT_HOME>/
  settings/
    settings.yml
    secrets.yml.enc
    .settings_key
    audit/YYYY-MM.md
  memory/
    notes/
    preferences/
    traces/
    skills/
  db/
    allbert.sqlite3
  skills/
  cache/
    skills/
  tmp/
```

Allbert will add a shared paths module, `AllbertAssist.Paths`, that resolves:

- `home/0`
- `ensure_home!/0`
- `settings_root/0`
- `memory_root/0`
- `db_path/0`
- `skills_root/0`
- `cache_root/0`
- `tmp_root/0`

Path precedence is:

1. Specific override when one exists, for example `ALLBERT_SETTINGS_ROOT`,
   `ALLBERT_MEMORY_ROOT`, `DATABASE_PATH`, or application config used by tests.
2. `ALLBERT_HOME`.
3. `ALLBERT_HOME_DIR`.
4. `~/.allbert`.

Specific overrides remain valid for tests, migrations, compatibility, and
operator escape hatches. Normal runtime code should derive paths from
`AllbertAssist.Paths`.

Tests and CI must set a temporary `ALLBERT_HOME` or a specific temporary root.
They must never write to a real user's `~/.allbert`.

## Consequences

- Backing up or moving `<ALLBERT_HOME>` becomes the simple mental model for
  moving Allbert's durable local state.
- Settings, secrets, memory, database, skills, caches, and temporary runtime
  files share one path convention.
- Future profile export/import has a clear boundary.
- Project-local skill directories such as `./.allbert/skills` remain separate
  trust-gated project scopes; they do not replace user-owned
  `<ALLBERT_HOME>/skills`.
- `config.exs`, `runtime.exs`, and environment variables still own bootstrap
  and deployment concerns, but ordinary user/operator state lives under
  Allbert Home.
