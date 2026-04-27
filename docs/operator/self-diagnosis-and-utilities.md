# Self-diagnosis and local utilities

Self-diagnosis and local utilities are current v0.14.2 operator surfaces. Diagnosis reads bounded session trace bundles, writes markdown reports, and explains by default. Local utilities are host-specific helpers that the operator explicitly enables before Allbert can compose them through `unix_pipe`.

Remediation remains review-first and never installs generated code, skills, or memory automatically. Start with the [v0.14.2 operator playbook](../onboarding-and-operations.md) for the full feature-test path.

## Diagnosis

Create a report from recent trace artifacts:

```bash
cargo run -p allbert-cli -- diagnose run
```

Limit diagnosis to one session:

```bash
cargo run -p allbert-cli -- diagnose run --session <session-id>
```

Inspect reports:

```bash
cargo run -p allbert-cli -- diagnose list
cargo run -p allbert-cli -- diagnose show <diagnosis-id>
```

Read-only inspection can bypass the daemon when you are examining local artifacts:

```bash
cargo run -p allbert-cli -- diagnose list --offline
cargo run -p allbert-cli -- diagnose show <diagnosis-id> --offline
```

Reports are session artifacts:

```text
~/.allbert/sessions/<session-id>/artifacts/diagnostics/<diagnosis-id>/report.md
~/.allbert/sessions/<session-id>/artifacts/diagnostics/<diagnosis-id>/bundle.summary.json
```

Diagnosis ids use `diag_<utc_timestamp>_<shortid>`. Reports keep stable sections for summary, classification, evidence, skipped/truncated data, recommended next actions, and remediation status.

## Remediation

Diagnosis does not apply fixes by default. Remediation requires both config opt-in and explicit operator intent:

```bash
cargo run -p allbert-cli -- settings set self_diagnosis.allow_remediation true
cargo run -p allbert-cli -- diagnose run --remediate code --reason "fix failing trace path"
```

Kinds:

- `code` routes through the existing sibling worktree and `patch-approval` flow.
- `skill` drafts into `skills/incoming/` with `provenance: self-diagnosed`.
- `memory` writes staged memory candidates only.

Telegram is structural-only for v0.14 diagnosis. It can show latest diagnosis status, but it does not start patch, skill, or memory writes.

## Local Utilities

Discover catalog utilities:

```bash
cargo run -p allbert-cli -- utilities discover
```

Enable one utility:

```bash
cargo run -p allbert-cli -- utilities enable rg
cargo run -p allbert-cli -- utilities enable jq --path /opt/homebrew/bin/jq
```

Inspect and verify:

```bash
cargo run -p allbert-cli -- utilities list
cargo run -p allbert-cli -- utilities show rg
cargo run -p allbert-cli -- utilities doctor
```

Disable:

```bash
cargo run -p allbert-cli -- utilities disable rg
```

The enablement manifest lives at:

```text
~/.allbert/utilities/enabled.toml
```

It is host-specific and excluded from profile export/sync by default. Enabling a utility never edits `security.exec_allow`; if exec policy still requires approval, the command says so and `unix_pipe` refuses until the executable is allowed.

## Unix Pipe

`unix_pipe` is a structured direct-spawn tool for enabled utilities. It is not a shell runtime. It does not accept shell strings, glob expansion, redirects, process substitution, or environment overrides.

Use Lua scripting when you need a small in-process JSON-in/JSON-out transform that should stay inside the embedded sandbox. Use `unix_pipe` when the useful capability already exists as a local executable, the operator has enabled that utility, and direct-spawn process isolation plus exec policy is the right boundary.

Tool input uses utility ids:

```json
{
  "stages": [
    { "utility_id": "rg", "args": ["TODO"] },
    { "utility_id": "head", "args": ["-n", "20"] }
  ],
  "stdin": null,
  "timeout_s": 30
}
```

Every stage is preflighted before any child starts: utility enabled, manifest status `ok`, central exec policy, trusted `cwd`, argument caps, byte caps, and timeout. Success requires every stage to exit `0` with no timeout or cap violation.

Settings live under:

```text
/settings show local_utilities
/settings show self_diagnosis
```

## unix_pipe Verification Recipe

`unix_pipe` is invoked through the tool system, not as a direct CLI subcommand. A practical operator check is:

1. Enable and verify utility entries:

   ```bash
   cargo run -p allbert-cli -- utilities discover
   cargo run -p allbert-cli -- utilities enable rg
   cargo run -p allbert-cli -- utilities enable head
   cargo run -p allbert-cli -- utilities doctor
   ```

2. Confirm exec policy allows the resolved binaries:

   ```bash
   cargo run -p allbert-cli -- settings show security.exec_allow
   ```

   If needed, add the utility id, executable name, or canonical path through the settings surface.

3. Ask from a trusted workspace:

   ```text
   Use the unix_pipe tool to search this trusted workspace for the text "TODO" with rg, pipe it to head -n 5, and report only the five lines.
   ```

4. Verify `/activity` or trace replay shows `tool_name = "unix_pipe"` with per-stage utility metadata.

If the active skill does not list `unix_pipe` in `allowed-tools`, the utility is not enabled, the manifest status is not `ok`, or exec policy rejects the binary, the run fails before spawning any child process.

## Related Docs

- [v0.14.2 operator playbook](../onboarding-and-operations.md)
- [Tracing guide](tracing.md)
- [Self-improvement guide](self-improvement.md)
- [Continuity and sync posture](continuity.md)
- [v0.14 upgrade notes](../notes/v0.14-upgrade-2026-04-26.md)
