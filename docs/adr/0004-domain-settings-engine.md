# ADR 0004: Domain Settings Engine

## Status

Accepted.

## Context

Allbert is intended to be operated through CLI, LiveView, scheduled jobs, and
future channels such as chat, email, SMS, browser capture, and native UI
surfaces. Those interfaces will need to inspect and change the same durable
settings: operator profile, trace defaults, skill trust, permission policy,
channel preferences, job schedules, provider profiles, model profiles,
user-supplied credentials, and memory review policy.

Phoenix `config.exs` is application and deployment configuration. It is useful
for boot-time defaults, endpoint setup, repo setup, mailer adapters, and
environment-specific infrastructure. It is not a safe or ergonomic source of
truth for user/operator settings that Allbert should display, validate, edit,
audit, and explain at runtime.

If each subsystem stores its own settings, Allbert will become harder to
operate and future channels will have inconsistent behavior.

## Decision

Allbert will have a first-class domain settings subsystem,
`AllbertAssist.Settings`.

Settings are typed, validated, layered, inspectable, and auditable. They are
the source of truth for user/operator runtime preferences and policy. They are
not a replacement for deployment config; `config.exs`, `runtime.exs`, and
environment variables remain the source for infrastructure and bootstrap
values.

User-supplied secrets belong to Settings Central, not to ad hoc environment
variables or Phoenix config. They are stored through
`AllbertAssist.Settings.Secrets`, encrypted at rest, referenced from
`settings.yml` as `secret://...`, and redacted in CLI output, LiveView, traces,
audits, logs, and tests.

Settings Central lives under Allbert Home by default. Allbert Home is resolved
by ADR 0005 and normally defaults to `~/.allbert`. Specific settings roots may
still be overridden for tests, migrations, compatibility, or operator escape
hatches.

Settings resolution will support layers such as built-in defaults, deployment
overrides, operator/global settings, project/workspace settings,
channel-specific settings, and request/session overrides. Allbert should be
able to explain which layer supplied a resolved value.

Settings will start as local files under the Allbert home settings directory.
`settings.yml` is human-readable. `secrets.yml.enc` is encrypted. Writes must
be validated and audited. CLI, LiveView, and future channels should all use the
same settings actions rather than private subsystem-specific configuration
mechanisms.

## Consequences

- Skill trust, provider profiles, model profiles, permission policy, channel
  behavior, jobs, tracing, and memory review can share one settings foundation.
- Operator preferences can be changed from multiple interfaces without editing
  deployment config.
- User-supplied API keys can be managed through Allbert's operator interfaces
  while remaining redacted from inspectable surfaces.
- Settings changes become traceable and recoverable.
- Direct structured-file dependencies are needed for YAML settings:
  `yaml_elixir` for parsing and `ymlr` for deterministic YAML output. YAML is a
  good fit because Agent Skills frontmatter also needs YAML support.
- Only bootstrap secrets, such as the Settings Central master key, remain
  outside Settings Central.
