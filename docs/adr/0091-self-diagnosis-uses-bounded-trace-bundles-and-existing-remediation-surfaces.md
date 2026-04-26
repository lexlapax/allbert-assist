# ADR 0091: Self-diagnosis uses bounded trace bundles and existing remediation surfaces

Date: 2026-04-26
Status: Accepted

## Context

v0.12.2 made session traces durable and replayable under `sessions/<id>/trace*`. v0.14 needs Allbert to consume those traces for diagnosis, but that should not turn trace history into hidden memory, a new retrieval index, or an unbounded prompt payload.

The origin note asked for tracing that Allbert itself could learn from when something went wrong. The review-first posture built in v0.11-v0.13 also says that any state-changing follow-up must move through the subsystem that already owns review: staged memory, patch approval, or skill install preview.

## Decision

v0.14 self-diagnosis reads bounded `TraceDiagnosticBundle` values built from v0.12.2 `TraceReader`. The bundle is a redacted summary for diagnosis, not a new persisted trace format and not a new source of truth.

Default bounds are:

```toml
[self_diagnosis]
lookback_days = 7
max_sessions = 5
max_spans = 1000
max_events = 2000
max_text_snippet_bytes = 32768
max_report_bytes = 262144
allow_remediation = false
```

The bundle includes session ids, span ids, parent ids, names, statuses, durations, bounded attributes/events, read warnings, cap/truncation metadata, and a fixed failure classification. The v0.14 taxonomy is:

- `provider_error`
- `tool_denied`
- `tool_failed`
- `timeout`
- `approval_abandoned`
- `cost_cap`
- `context_pressure`
- `memory_mismatch`
- `adapter_training_failure`
- `unknown_local`

`unknown_local` is a valid diagnosis when local trace data is insufficient.

The internal DTO is owned by `allbert-kernel::self_diagnosis` and has `bundle_version = 1`, active session id, selected session ids, generation timestamp, effective bounds, summarized spans/events, warnings, truncation metadata, and classification. Proto owns only the daemon wire DTOs and must not become the on-disk report schema.

v0.14 does not add a Tantivy trace tier. Diagnosis lists recent trace sessions through `TraceReader::list_sessions()`, reads selected sessions through `TraceReader::read_session()`, and summarizes in memory. If future work needs a derived trace index, it needs a separate decision with schema-version and rebuild rules.

Diagnosis writes markdown reports under the active session:

```text
sessions/<session_id>/artifacts/diagnostics/<diagnosis_id>/report.md
sessions/<session_id>/artifacts/diagnostics/<diagnosis_id>/bundle.summary.json
```

Reports explain by default. Candidate remediation requires an explicit remediation command or slash-command field and `self_diagnosis.allow_remediation = true`.

Diagnosis ids use `diag_<utc_timestamp>_<shortid>`, where the timestamp is UTC `YYYYMMDDTHHMMSSZ` and the short id is generated from local randomness. `bundle.summary.json` contains `schema_version = 1`, diagnosis id, session id, creation timestamp, selected session ids, classification, confidence, report path, effective bounds, truncation metadata, warnings, and remediation summary.

The markdown report keeps stable sections: `Summary`, `Classification`, `Evidence`, `Skipped Or Truncated Data`, `Recommended Next Actions`, and `Remediation Status`.

v0.14 exposes one skill-callable diagnosis tool, `self_diagnose`. Its closed input schema contains only optional `session_id` and optional `lookback_days`. It returns the bounded summary plus report path and never returns raw trace files or unbounded span/event payloads. Its schema is report-only: a model-emitted tool call that includes `remediation` or any unknown field is rejected.

Remediation requires all of the following:

- `self_diagnosis.allow_remediation = true`;
- explicit remediation kind `code`, `skill`, or `memory`;
- non-empty operator reason supplied through `--reason <text>` or an equivalent slash-command field.

Remediation authorization is daemon-owned and command-originated. The daemon builds remediation requests only from parsed CLI/REPL/TUI command input, never from model-emitted tool calls. Ordinary natural-language diagnosis requests may tell the operator what explicit command to run, but they must not start remediation. Telegram remains structural-only and cannot start remediation in v0.14.

When `[self_diagnosis].enabled = false`, `diagnose run` and the `self_diagnose` tool fail closed with a settings remediation hint. Offline report listing/showing may still read existing diagnosis artifacts because those artifacts are passive session history, not a new diagnosis run.

Remediation routes through existing surfaces only:

- Code-shaped remediation uses the v0.12 sibling-worktree path, Tier A validation, and `patch-approval`.
- Skill-shaped remediation uses the v0.12 `skill-author`/quarantine flow with `provenance: self-diagnosed`.
- Memory-shaped remediation writes staged memory candidates and never writes durable memory directly.

No diagnosis path writes directly to installed skills, active source checkout, durable memory, adapters, or bootstrap files.

## Consequences

**Positive**

- Diagnosis remains bounded and provider-free testable.
- v0.14 consumes v0.12.2 trace artifacts without changing trace storage, privacy defaults, retention, or protocol v4.
- Operators get readable reports before any proposed fix.
- All candidate fixes stay inside the cross-release self-change envelope.

**Negative**

- Bounded scans may miss older or very large failures unless the operator narrows/expands the command.
- No trace index means broad historical correlation is slower than a derived search tier would be.

**Neutral**

- Diagnosis reports are session artifacts and travel with sessions.
- `bundle.summary.json` is for rendering and tests; it is not a durable replay schema.

## References

- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [ADR 0042](0042-autonomous-learned-memory-writes-go-to-staging-before-promotion.md)
- [ADR 0067](0067-self-modification-uses-a-sibling-worktree-with-operator-diff-review.md)
- [ADR 0071](0071-self-authored-skills-route-through-the-standard-install-quarantine.md)
- [ADR 0073](0073-rebuild-patch-approval-is-a-new-inbox-kind.md)
- [ADR 0080](0080-self-change-artifacts-share-approval-provenance-and-rollback-envelope.md)
- [ADR 0081](0081-durable-session-trace-artifacts-and-replay-envelope.md)
- [ADR 0082](0082-trace-capture-privacy-and-redaction-posture.md)
