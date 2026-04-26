# ADR 0093: Unix-pipe is a structured direct-spawn tool, not a shell runtime

Date: 2026-04-26
Status: Accepted

## Context

ADR 0004 intentionally avoided shell-string execution for v0.1. That choice keeps command behavior and policy checks auditable. v0.14 wants Unix-style utility composition, but adding a shell-string pipeline such as `"rg foo | head -n 20"` would reintroduce the quoting, redirection, globbing, environment, and injection ambiguity ADR 0004 rejected.

v0.12 also introduced an embedded Lua scripting seam. `unix_pipe` must be distinct from that surface: Lua is in-process, sandboxed, JSON-in/JSON-out; `unix_pipe` is out-of-process composition of operator-enabled local binaries.

## Decision

v0.14 adds a `unix_pipe` tool with a structured JSON contract. It never accepts a shell command string.

Example:

```json
{
  "stages": [
    { "utility": "rg", "args": ["TODO"], "cwd": "/workspace" },
    { "utility": "head", "args": ["-n", "20"] }
  ],
  "stdin": null,
  "timeout_s": 30
}
```

Each stage references an enabled utility id from ADR 0092. The kernel resolves the id to a verified executable path and spawns each process directly, wiring stdout to the next stage stdin. There is no shell parsing, no glob expansion, no redirection syntax, no process substitution, and no free-form environment override.

Default bounds are:

- maximum stages: `5`;
- timeout: `30` seconds for the whole pipeline;
- stdin cap: `1 MiB`;
- final stdout cap: `1 MiB`;
- aggregate stderr cap: `256 KiB`.

`cwd` is optional and must stay inside configured filesystem roots. Stages inherit the daemon's normal environment; v0.14 does not add tool-level env mutation.

Every stage must pass both gates:

1. The utility id must be enabled and verified in `utilities/enabled.toml`.
2. The resolved executable must pass the existing central exec policy (`security.exec_deny` wins over `security.exec_allow`, and confirmation behavior remains unchanged).

Active skills must list `unix_pipe` in `allowed-tools` to call it. Listing `unix_pipe` does not allow arbitrary executables; enabled utility ids and exec policy still apply per stage.

Every stage is preflighted before any process starts. Preflight validates stage count, argument count/length, enabled utility status, `cwd`, byte caps, timeout, active-skill `allowed-tools`, and central exec policy. After preflight succeeds, stages launch as one direct-spawn pipeline. Success requires every stage to exit `0` and no timeout or cap violation. Timeout or cap failure kills every running child.

v0.14 supports text I/O only. `stdin` is UTF-8 text, final stdout is rendered as UTF-8 text, and invalid UTF-8 from child processes is lossy-rendered with an explicit `invalid_utf8` flag. Binary-safe streaming needs a future ADR.

Tool output is a structured JSON string with:

- `ok`;
- `duration_ms`;
- `stage_count`;
- bounded final `stdout`;
- `stdout_bytes`;
- per-stage stderr summaries with byte counts and truncation flags;
- per-stage exit codes;
- `timed_out`;
- aggregate `truncated`;
- `invalid_utf8`.

Hook metadata records utility ids, resolved executables, stage count, exit statuses, byte counts, timeout/cap flags, and truncation flags. v0.12.2 trace spans use `tool.name = "unix_pipe"` with per-stage events.

## Consequences

**Positive**

- Allbert gains practical Unix composition without undoing ADR 0004.
- Policy review remains per executable rather than per opaque shell string.
- Pipeline behavior is provider-free testable.

**Negative**

- Some natural shell idioms are not supported directly.
- Operators must enable each utility before pipeline use.

**Neutral**

- Users can still run direct commands through `process_exec` when policy allows.
- More complex transformations can use Lua when they fit the embedded JSON-in/JSON-out model.

## References

- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0034](0034-skill-scripts-run-under-the-same-exec-policy-as-tools.md)
- [ADR 0069](0069-scripting-engine-trait-with-lua-as-the-v0-12-default-embedded-runtime.md)
- [ADR 0070](0070-embedded-script-sandbox-policy.md)
- [ADR 0092](0092-local-utility-discovery-uses-curated-operator-enabled-manifests.md)
