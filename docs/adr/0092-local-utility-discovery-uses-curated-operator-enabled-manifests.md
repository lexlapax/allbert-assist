# ADR 0092: Local utility discovery uses curated operator-enabled manifests

Date: 2026-04-26
Status: Accepted

## Context

The origin note explicitly valued Unix composition: Allbert should call small utility programs already present on the system instead of absorbing their functionality into the kernel. The existing `process_exec` surface can run commands under central policy, but it does not provide a legible product posture for discovering, describing, enabling, and auditing the utilities Allbert is allowed to compose.

PATH-only discovery would be convenient but unstable: PATH differs per shell, per daemon environment, and per host. A config-only allowlist would be auditable but poor at carrying descriptions, version checks, and drift state.

## Decision

v0.14 uses a curated first-party catalog plus an operator-enabled manifest.

The built-in catalog is compiled into `allbert-kernel`. Each catalog entry has:

- stable utility id;
- display name and description;
- executable candidates;
- catalog-defined bounded version/help probe;
- safe usage notes;
- whether the utility may be used in `unix_pipe`.

The v0.14 initial catalog includes conservative inspection/transform utilities such as `jq`, `rg`, `fd`, `bat`, `pandoc`, `sed`, `awk`, `sort`, `uniq`, `wc`, `head`, and `tail`.

The host-local enablement manifest lives at:

```text
~/.allbert/utilities/enabled.toml
```

Manifest schema is versioned:

```toml
schema_version = 1

[[utility]]
id = "rg"
path = "/opt/homebrew/bin/rg"
path_canonical = "/opt/homebrew/bin/rg"
version = "ripgrep 14.1.1"
help_summary = "rg [OPTIONS] PATTERN [PATH ...]"
enabled_at = "2026-04-26T00:00:00Z"
verified_at = "2026-04-26T00:00:00Z"
status = "ok"
size_bytes = 123456
modified_at = "2026-04-01T00:00:00Z"
pipe_allowed = true
```

The status enum is `ok`, `missing`, `changed`, `denied`, and `needs-review`.

Enabling a utility resolves the chosen executable to an absolute canonical path, records the original path, records bounded version/help text when the catalog defines probes, and stores executable size and modified timestamp for drift detection. Verification marks an entry:

- `missing` when the path no longer exists or is no longer executable;
- `changed` when canonical path, size, or modified timestamp differs from the enabled record;
- `denied` when central exec policy hard-denies the executable;
- `needs-review` when metadata cannot be safely verified.

Only entries with `status = "ok"` and `pipe_allowed = true` may be used by `unix_pipe`.

`utilities enable` does not silently edit `security.exec_allow`. If the executable is allowed, enablement records that it is ready. If it is not hard-denied but will require confirmation at run time, enablement succeeds with an actionable note. If it is hard-denied, enablement refuses until the operator updates exec policy through the existing settings surface.

Enabling a utility requires explicit operator action through CLI, TUI/REPL, or setup. Allbert does not install missing utilities. It reports missing tools and leaves installation to the operator.

The manifest is host-specific and excluded from profile export/sync by default. Export dry-runs name `utilities/enabled.toml` in the excluded host-specific set. A future opt-in export of local utility posture would need to avoid pretending host-local paths are portable.

## Consequences

**Positive**

- Utility use is legible and reviewable.
- Allbert can explain what each enabled utility is for without probing PATH every turn.
- Host drift is detected before pipeline execution.
- The kernel stays compact and delegates specialized work to existing programs.

**Negative**

- Operators must enable utilities before `unix_pipe` can use them.
- The first-party catalog needs maintenance as new utility families are added.

**Neutral**

- `process_exec` remains available under the existing policy envelope.
- Utility enablement is a second gate, not a replacement for `security.exec_allow` / `security.exec_deny`.

## References

- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [ADR 0093](0093-unix-pipe-is-a-structured-direct-spawn-tool-not-a-shell-runtime.md)
