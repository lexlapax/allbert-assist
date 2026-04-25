# Continuity and sync posture

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
- `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, optional `PERSONALITY.md`, `AGENTS.md`, `HEARTBEAT.md`
- `learning/personality-digest/` draft/report artifacts and consent state

### Derived (exclude; rebuildable/disposable)

- `memory/index/`
- `memory/index/semantic/`
- `run/`
- `logs/`
- `traces/`

### Sensitive (exclude by default)

- `secrets/`

### Device-scoped (never sync)

- `costs.jsonl`
- `daemon.lock`

## Profile export/import

`allbert-cli profile export` and `allbert-cli profile import` are the canonical continuity workflow. Use them instead of ad hoc directory copies when you want a predictable archive plus post-import rebuilds.

Recommended flow:

1. On the source machine, stop any live daemon or confirm the profile is idle.
2. Export the profile with `cargo run -p allbert-cli -- profile export /path/to/profile.tgz`.
3. Copy the archive to the destination device through your usual transport.
4. On the destination machine, import with `cargo run -p allbert-cli -- profile import /path/to/profile.tgz --overlay` for normal merges or `--replace --yes` for a full replacement.
5. Recheck state with `cargo run -p allbert-cli -- daemon status`, `cargo run -p allbert-cli -- identity show`, `cargo run -p allbert-cli -- inbox list`, `cargo run -p allbert-cli -- heartbeat show`, and `cargo run -p allbert-cli -- memory verify`.

`--overlay` is the safe default. `--replace` is only for cases where you intentionally want the imported profile to win wholesale and there is no live daemon holding the lock.

## Sync excludes

If you use `rsync`, Syncthing, cloud-drive mirroring, or another file-level sync tool instead of `profile export/import`, keep the continuity-bearing list above and explicitly exclude the rest.

Exclude by default:

- `memory/index/`
- `run/`
- `logs/`
- `traces/`
- `secrets/`
- `costs.jsonl`
- `daemon.lock`

Tool-specific reminder:

- file sync tools should not try to merge `daemon.lock` or any file under `run/`
- index and trace directories are disposable and should be rebuilt, not mirrored
- secrets should move only through an explicit operator action, not through routine sync

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

That makes it the fastest post-import or post-sync sanity check before you resume work on a second device.
