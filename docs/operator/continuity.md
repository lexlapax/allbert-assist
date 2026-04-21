# Continuity and sync posture (v0.8)

This guide defines which profile paths are safe to sync, which are rebuildable, and which are intentionally device-local.

For cost-limit behavior across multiple devices, see [`docs/operator/cost-caps.md`](cost-caps.md).

## Artifact catalog

### Continuity-bearing (include for continuity)

- `identity/user.md`
- `config.toml`, `config/`
- `memory/MEMORY.md`, `memory/notes/`, `memory/daily/`, `memory/staging/`
- `sessions/` (journals, `meta.json`, approvals)
- `jobs/`
- `skills/installed/`, `skills/incoming/`
- `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `HEARTBEAT.md`

### Derived (exclude; rebuildable/disposable)

- `memory/index/`
- `run/`
- `logs/`
- `traces/`

### Sensitive (exclude by default)

- `secrets/`

### Device-scoped (never sync)

- `costs.jsonl`
- `daemon.lock`

## Daemon lockfile

`~/.allbert/daemon.lock` stores:

```json
{
  "pid": 49271,
  "host": "laptop",
  "started_at": "2026-04-20T18:02:11Z"
}
```

Lifecycle:

- no lock: daemon writes lock and starts;
- lock exists on same host with live pid: daemon refuses to start;
- lock exists on same host with dead pid: daemon logs stale takeover and replaces lock;
- lock exists from different host: daemon refuses to start.

On graceful shutdown, the daemon removes the lock.

## `daemon status` diagnostics

`allbert-cli daemon status` now surfaces:

- lock owner tuple (`pid`, `host`, `started_at`) when available;
- configured `model.api_key_env`;
- whether that env var is visible to the running daemon process.
