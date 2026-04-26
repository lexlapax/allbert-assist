# ADR 0094: Protocol v6 self-diagnosis and local-utility surfaces

Date: 2026-04-26
Status: Accepted

## Context

ADR 0075 established that operational truth belongs to the kernel/daemon protocol, not frontend inference. v0.12.1 added protocol v3 activity state, v0.12.2 added protocol v4 trace messages, and v0.13 added protocol v5 adapter-management messages.

v0.14 adds diagnosis and local utility state. Those surfaces should be daemon-owned for the same reason: frontends should not infer diagnosis progress from trace files, probe PATH independently, or reconstruct utility enablement from local filesystem guesses.

## Decision

v0.14 bumps the daemon protocol from `5` to `6` additively.

A v6 daemon accepts client protocol versions `2`, `3`, `4`, `5`, and `6`, records the negotiated protocol per connection, and filters outbound messages per peer:

- v2 peers receive only v2-safe messages and fields.
- v3 peers also receive activity messages.
- v4 peers also receive trace messages.
- v5 peers also receive adapter messages.
- v6 peers also receive self-diagnosis and local-utility messages.

Unsupported versions below `2` or above `6` receive `ProtocolError { code: "version_mismatch", ... }` with remediation naming whether to upgrade the client or daemon. A v6 client connected to an older daemon must surface `upgrade the daemon to v0.14 to use self-diagnosis and local utility surfaces` and must not synthesize diagnosis or utility state locally.

Protocol v6 adds additive payloads for:

- diagnosis run status;
- diagnosis report summaries;
- local utility catalog and enabled-manifest status;
- `unix_pipe` run summaries.

Client messages:

- `DiagnoseRun(DiagnosisRunRequest)`
- `DiagnoseList { session_id: Option<String> }`
- `DiagnoseShow { diagnosis_id: String }`
- `UtilitiesDiscover`
- `UtilitiesList`
- `UtilitiesShow { utility_id: String }`
- `UtilitiesEnable(UtilityEnableRequest)`
- `UtilitiesDisable { utility_id: String }`
- `UtilitiesDoctor`

Server messages:

- `DiagnosisStarted { diagnosis_id: String }`
- `Diagnosis(DiagnosisSummary)`
- `Diagnoses(Vec<DiagnosisSummary>)`
- `DiagnosisReport { diagnosis_id: String, report_markdown: String, summary: DiagnosisReportSummary }`
- `UtilityCatalog(Vec<UtilityCatalogEntryPayload>)`
- `Utility(UtilityCatalogEntryPayload)`
- `EnabledUtilities(Vec<EnabledUtilityPayload>)`
- `UtilitiesDoctor(Vec<EnabledUtilityPayload>)`
- `UnixPipeRun(UnixPipeRunSummary)`

The core v6 payloads are `DiagnosisRunRequest`, `DiagnosisRemediationRequest`, `DiagnosisSummary`, `DiagnosisReportSummary`, `UtilityCatalogEntryPayload`, `EnabledUtilityPayload`, and `UnixPipeRunSummary`. They carry only bounded status/report paths and summaries; raw trace files, full utility help text, and unbounded stdout/stderr are not protocol payloads.

`ActivityPhase::Diagnosing` is added for diagnosis runs. `unix_pipe` uses the existing tool activity posture with `tool_name = "unix_pipe"`.

Frontends consume daemon messages and render them. They must not independently classify trace failures, probe PATH for enabled utilities, infer utility verification state, or synthesize diagnosis lifecycle events.

CLI/TUI/Telegram live and mutating v0.14 surfaces use the daemon by default. CLI commands follow the existing `daemon.auto_spawn` setting when the daemon is not running. Mutating commands such as `diagnose run`, remediation, `utilities enable`, `utilities disable`, and `utilities doctor` must use protocol v6. Read-only CLI commands expose explicit `--offline` modes for artifact/catalog inspection, but those results are labeled offline and do not claim daemon-owned live status.

## Consequences

**Positive**

- v0.14 keeps the operator-state lineage from ADR 0075 intact.
- Older clients continue to work against a v6 daemon.
- v6 clients get actionable old-daemon remediation instead of mysterious missing features.

**Negative**

- Per-peer filtering grows again and needs explicit tests.
- TUI/REPL/Telegram renderers need new v6-aware branches.

**Neutral**

- v6 does not change v4 trace storage or v5 adapter semantics.
- `SessionStatus` remains backward-compatible; richer diagnosis/utility payloads are additive.

## References

- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)
- [ADR 0083](0083-protocol-v4-trace-events-and-otlp-json-export.md)
- [ADR 0090](0090-protocol-v5-adapter-management-and-training-progress.md)
- [ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md)
- [ADR 0092](0092-local-utility-discovery-uses-curated-operator-enabled-manifests.md)
- [ADR 0093](0093-unix-pipe-is-a-structured-direct-spawn-tool-not-a-shell-runtime.md)
