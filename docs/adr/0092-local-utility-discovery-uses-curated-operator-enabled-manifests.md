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
- optional version/help probe;
- safe usage notes;
- whether the utility may be used in `unix_pipe`.

The v0.14 initial catalog includes conservative inspection/transform utilities such as `jq`, `rg`, `fd`, `bat`, `pandoc`, `sed`, `awk`, `sort`, `uniq`, `wc`, `head`, and `tail`.

The host-local enablement manifest lives at:

```text
~/.allbert/utilities/enabled.toml
```

Enabled entries record utility id, resolved absolute path, version string or bounded help summary when available, enabled timestamp, last verification timestamp, and verification status. If verification later finds the binary missing, changed, or no longer executable, the entry becomes `needs-review` and cannot be used by `unix_pipe` until re-enabled.

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
