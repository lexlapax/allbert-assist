# Self-diagnosis and local utilities

v0.14 adds bounded self-diagnosis and a curated local-utility surface. Diagnosis reads existing v0.12.2 session traces, writes markdown reports, and explains by default. Local utilities are host-specific helpers that the operator explicitly enables before Allbert can compose them through `unix_pipe`.

Reality note: remediation routing is present, but concrete candidate generation is partial as of v0.14; tracked by v0.14.1. Until that repair lands, remediation artifacts may be scaffolds that point back to the report.

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

## Related Docs

- [Tracing guide](tracing.md)
- [Self-improvement guide](self-improvement.md)
- [Continuity and sync posture](continuity.md)
- [v0.14 upgrade notes](../notes/v0.14-upgrade-2026-04-26.md)
