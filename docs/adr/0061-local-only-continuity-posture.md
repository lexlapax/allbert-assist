# ADR 0061: Local-only continuity posture — artifact catalog, lockfile, export/import

Date: 2026-04-20
Status: Accepted

> **Planned v0.12.2 amendment**: session-local trace artifacts under `sessions/*/trace.jsonl`, `sessions/*/trace.<n>.jsonl.gz`, and recoverable `sessions/*/current_spans/` are continuity-bearing session artifacts and are included with `sessions/` in profile export/sync by default. Top-level `traces/` remains derived legacy/debug output and stays excluded. Trace GC may remove only trace artifacts, never unrelated session journals, metadata, approvals, attachments, or patch artifacts.

## Context

v0.8 promises "continuity across surfaces" without committing to a hosted sync backend. That commitment is only safe if the filesystem layout is explicitly categorised so that:

- operators who want multi-device continuity via filesystem sync (Syncthing, iCloud Drive, Dropbox, etc.) have stable, sync-friendly paths;
- operators who want local-only continuity have an explicit tarball-based export/import path;
- the daemon refuses to corrupt state under concurrent operation against the same profile;
- derived artifacts, sensitive files, and device-scoped state are clearly excluded from any sync bundle.

Through v0.7 these concerns were implicit: the paths exist, the writes are mostly atomic, but nothing in the documentation told an operator which directories to sync and which to leave alone. Accidental sync of `~/.allbert/index/` would thrash; accidental sync of `~/.allbert/secrets/` would exfiltrate; accidental cross-host daemons on the same profile would corrupt.

v0.8 resolves the sync story without committing to a hosted backend. The daemon stays local-only through v0.12; this ADR codifies the posture.

## Decision

### Artifact catalog

Every file under `~/.allbert/` falls into exactly one category.

**Continuity-bearing** — must travel for meaningful continuity:

| Path | Source |
| --- | --- |
| `identity/user.md` | ADR 0058 |
| `config.toml` and `config/` | operator-owned config plus channel allowlists |
| `memory/MEMORY.md`, `memory/notes/`, `memory/daily/`, `memory/staging/` | ADR 0003, ADR 0045, ADR 0047 |
| `sessions/` (journals, meta, approvals, planned v0.12.2 session trace artifacts) | ADR 0049, ADR 0056, ADR 0060, ADR 0081 |
| `jobs/` | ADR 0022 |
| `skills/installed/` and `skills/incoming/` | ADR 0032, ADR 0037 |
| `SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, `HEARTBEAT.md` | ADR 0010, ADR 0039, ADR 0062 |

**Derived** — excluded from sync/export; rebuilt on demand:

| Path | Purpose |
| --- | --- |
| `memory/index/` | tantivy retrieval index (ADR 0046) |
| `run/` | `daemon.sock` and other live runtime state |
| `logs/` | daemon logs and debug logs |
| `traces/` | legacy/debug trace output and debugging artifacts; planned v0.12.2 replay traces live under `sessions/` |
| future cache subdirs (if introduced) | LLM/media caches or delivery queues, rebuilt or safely disposable |

**Sensitive** — continuity-bearing but excluded by default:

| Path | Why excluded |
| --- | --- |
| `secrets/` | API keys, channel tokens (e.g. ADR 0057 bot token). Re-entered per device. |

**Device-scoped** — never synced:

| Path | Why device-local |
| --- | --- |
| `costs.jsonl` | Per-device accounting (ADR 0051); cap aggregation across devices is out of scope through v0.12. |
| `daemon.lock` | Describes the local daemon process; meaningless elsewhere. |

### Concurrency guard: `daemon.lock`

`~/.allbert/daemon.lock` is written at daemon start:

```yaml
pid: 49271
host: laptop
started_at: 2026-04-20T18:02:11Z
```

On start:

- No lock → write and proceed.
- Lock exists, same host, pid alive → refuse with clear error.
- Lock exists, same host, pid dead → treat as stale; auto-take over with an audit entry.
- Lock exists, different host → refuse unless `--force`. Different-host takeover carries real risk (the other machine might be writing) and requires an operator decision.

Lock is removed on graceful shutdown. `--force` takeover logs a warning and may trigger a reconcile on next start.

### Atomic writes

Every persistence point uses the fsync+rename pattern:

1. Write content to `<path>.tmp` in the same directory.
2. `fsync` the tmp file.
3. Rename `<path>.tmp` → `<path>` atomically.
4. `fsync` the directory.

v0.8 audits existing write paths (journals, meta.json, notes, staged entries, approvals, identity record, HEARTBEAT.md) and fixes any gaps. The pattern becomes a kernel-wide invariant for continuity-bearing writes.

### Profile export

```
allbert-cli profile export <path.tgz> [--include-secrets] [--identity <id>]
```

- Produces a gzipped tarball containing all **Continuity-bearing** paths and a manifest.
- Excludes Derived/Device-scoped/Sensitive paths by default. `--include-secrets` explicitly opts in (operator's responsibility).
- Manifest at tarball root (`.allbert-manifest.json`):
  ```json
  {
    "version": "0.8.0",
    "exported_at": "2026-04-20T18:00:00Z",
    "exported_from_host": "laptop",
    "identity_id": "usr_<ulid>",
    "counts": {
      "sessions": 14,
      "approvals_pending": 0,
      "approvals_resolved": 27,
      "memory_durable": 183,
      "memory_staged": 4,
      "jobs": 5,
      "skills": 12
    },
    "excluded": ["secrets/", "memory/index/", "run/", "logs/", "traces/", "costs.jsonl"]
  }
  ```
- Planned v0.12.2 exports should also report trace artifact counts and bytes in the manifest so operators can understand the size and sensitivity of session trace history.
- Export is safe against a live daemon: the export tool takes a read-lock on the profile and snapshots via copy. Continuity-bearing writes continue but are not reflected in the export after the snapshot boundary.

### Profile import

```
allbert-cli profile import <path.tgz> [--overlay | --replace] [--yes]
```

- **`--overlay` (default)**: per-file mtime comparison. Files present in the tarball overwrite local files iff the tarball's mtime is newer. Conflicts (same path, same-or-newer local mtime) are logged and the local file is preserved.
- **`--replace`**: wipes all Continuity-bearing paths and extracts the tarball. Destructive; requires `--yes` confirmation.
- Refuses to run against a profile with a live daemon (lockfile check).
- After extraction, auto-runs the equivalent of `memory rebuild-index --force` and a lightweight `memory verify`-style sanity check against the manifest.

### Cross-device cost cap: per-device (documented limitation)

`limits.daily_usd_cap` (ADR 0051) stays per-device in v0.8. Operators running the same profile on two devices get an aggregate cap of roughly 2× the configured value. This is documented; cross-device aggregation would require either a central counter or a file-sync-safe CRDT and is out of scope through v0.12 alongside the hosted sync backend.

### Filesystem sync (Syncthing et al.)

Supported but not packaged. Operators configure their sync tool to include Continuity-bearing paths and exclude Derived/Sensitive/Device-scoped. `docs/operator/continuity.md` (new in v0.8 M10) provides a recommended exclude list per popular sync tool.

No conflict-resolution protocol is shipped. The operator promises not to run two daemons concurrently on the same synced profile; the lockfile makes violations loud.

## Consequences

**Positive**

- The sync story is explicit. Operators know what to sync, what to exclude, and why.
- Export/import gives a first-class "move my Allbert to a new machine" path without needing Syncthing.
- The lockfile prevents the worst corruption case (concurrent daemons) without a hosted coordinator.
- Atomic-write invariant means partially-visible state during cloud-sync replication is bounded to single-file anomalies that recover on rewrite.

**Negative**

- No automatic multi-device conflict resolution. Operators who ignore the lockfile on synced profiles can still corrupt state; the only defence is documentation and the lock itself.
- Per-device cost cap is a real wart for operators with multiple devices. Users will ask for aggregation. The ADR acknowledges and defers.
- Secrets-exclusion means setting up a second device requires re-entering tokens. Necessary trade-off; `--include-secrets` is the documented override.

**Neutral**

- Ground-truth layout is unchanged. Everything this ADR lists already exists; the contribution is catalog + lockfile + export/import + atomic-write audit.
- Keeps the door open for a future hosted sync backend (beyond v0.12) without invalidating local-only deployments.
- Compatible with the network-addressable-daemon deferral. Local-only is the safe default; network access is an explicit future design pass.

## References

- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)
- [ADR 0025](0025-v0-2-daemon-shutdown-is-bounded-graceful-and-job-failures-are-surfaced.md)
- [ADR 0032](0032-agentskills-folder-format-is-the-canonical-skill-shape.md)
- [ADR 0037](0037-single-file-skills-have-a-one-release-read-path-then-are-removed.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)
- [ADR 0057](0057-telegram-pilot-uses-teloxide-and-long-polling.md)
- [ADR 0058](0058-local-user-identity-record-unifies-channel-senders.md)
- [ADR 0060](0060-approval-inbox-is-a-derived-cross-session-view.md)
- [ADR 0062](0062-heartbeat-md-joins-the-bootstrap-bundle-in-v0-8.md)
- [ADR 0081](0081-durable-session-trace-artifacts-and-replay-envelope.md)
- [docs/plans/v0.08-continuity-and-sync.md](../plans/v0.08-continuity-and-sync.md)
