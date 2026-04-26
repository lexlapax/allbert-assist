use std::collections::{BTreeMap, BTreeSet};

use allbert_proto::{AttributeValue, Span, SpanStatus};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};

use crate::config::SelfDiagnosisConfig;
use crate::error::KernelError;
use crate::paths::AllbertPaths;
use crate::replay::{DefaultSecretRedactor, SecretRedactor, TraceReader};

pub const TRACE_DIAGNOSTIC_BUNDLE_VERSION: u32 = 1;
pub const DIAGNOSIS_REPORT_SUMMARY_SCHEMA_VERSION: u32 = 1;

#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(default, deny_unknown_fields)]
pub struct SelfDiagnoseInput {
    pub session_id: Option<String>,
    pub lookback_days: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TraceDiagnosticBounds {
    pub lookback_days: u16,
    pub max_sessions: usize,
    pub max_spans: usize,
    pub max_events: usize,
    pub max_text_snippet_bytes: usize,
    pub max_report_bytes: usize,
}

impl TraceDiagnosticBounds {
    pub fn from_config(config: &SelfDiagnosisConfig, lookback_days: u16) -> Self {
        Self {
            lookback_days,
            max_sessions: config.max_sessions,
            max_spans: config.max_spans,
            max_events: config.max_events,
            max_text_snippet_bytes: config.max_text_snippet_bytes,
            max_report_bytes: config.max_report_bytes,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct DiagnosticTruncation {
    pub sessions: bool,
    pub spans: bool,
    pub events: bool,
    pub text: bool,
    pub report: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosticSpan {
    pub session_id: String,
    pub span_id: String,
    pub parent_id: Option<String>,
    pub name: String,
    pub status: DiagnosticSpanStatus,
    pub started_at: DateTime<Utc>,
    pub ended_at: Option<DateTime<Utc>>,
    pub duration_ms: Option<u64>,
    pub attributes: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosticSpanStatus {
    Ok,
    Error { message: String },
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosticEvent {
    pub session_id: String,
    pub span_id: String,
    pub timestamp: DateTime<Utc>,
    pub name: String,
    pub attributes: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "snake_case")]
pub enum FailureKind {
    ProviderError,
    ToolDenied,
    ToolFailed,
    Timeout,
    ApprovalAbandoned,
    CostCap,
    ContextPressure,
    MemoryMismatch,
    AdapterTrainingFailure,
    UnknownLocal,
}

impl FailureKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::ProviderError => "provider_error",
            Self::ToolDenied => "tool_denied",
            Self::ToolFailed => "tool_failed",
            Self::Timeout => "timeout",
            Self::ApprovalAbandoned => "approval_abandoned",
            Self::CostCap => "cost_cap",
            Self::ContextPressure => "context_pressure",
            Self::MemoryMismatch => "memory_mismatch",
            Self::AdapterTrainingFailure => "adapter_training_failure",
            Self::UnknownLocal => "unknown_local",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FailureClassification {
    pub primary: FailureKind,
    pub secondary: Vec<FailureKind>,
    pub confidence: f32,
    pub rationale: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TraceDiagnosticBundle {
    pub bundle_version: u32,
    pub active_session_id: String,
    pub selected_session_ids: Vec<String>,
    pub generated_at: DateTime<Utc>,
    pub bounds: TraceDiagnosticBounds,
    pub spans: Vec<DiagnosticSpan>,
    pub events: Vec<DiagnosticEvent>,
    pub warnings: Vec<String>,
    pub bytes_read: u64,
    pub has_rotated_archives: bool,
    pub recovered_span_count: u64,
    pub truncation: DiagnosticTruncation,
    pub classification: FailureClassification,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisSummary {
    pub primary_failure: FailureKind,
    pub secondary_failures: Vec<FailureKind>,
    pub confidence: f32,
    pub rationale: String,
    pub selected_session_count: usize,
    pub span_count: usize,
    pub event_count: usize,
    pub warning_count: usize,
    pub truncation: DiagnosticTruncation,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosisRemediationStatus {
    NotRequested,
    Refused,
    Routed,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisRemediationSummary {
    pub kind: String,
    pub reason: String,
    pub status: DiagnosisRemediationStatus,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportSummary {
    pub schema_version: u32,
    pub diagnosis_id: String,
    pub created_at: DateTime<Utc>,
    pub summary: DiagnosisSummary,
    pub selected_session_ids: Vec<String>,
    pub bounds: TraceDiagnosticBounds,
    pub report_path: Option<String>,
    pub remediation: Option<DiagnosisRemediationSummary>,
}

pub fn build_trace_diagnostic_bundle(
    paths: &AllbertPaths,
    config: &SelfDiagnosisConfig,
    active_session_id: &str,
    requested_session_id: Option<&str>,
    lookback_days_override: Option<u16>,
) -> Result<TraceDiagnosticBundle, KernelError> {
    let lookback_days = lookback_days_override.unwrap_or(config.lookback_days);
    if !(1..=90).contains(&lookback_days) {
        return Err(KernelError::Request(
            "lookback_days must be between 1 and 90".into(),
        ));
    }

    let bounds = TraceDiagnosticBounds::from_config(config, lookback_days);
    let reader = TraceReader::new(paths.clone());
    let selected_session_ids =
        select_sessions(&reader, active_session_id, requested_session_id, &bounds)?;
    let redactor = DefaultSecretRedactor::new();

    let mut spans = Vec::new();
    let mut events = Vec::new();
    let mut warnings = Vec::new();
    let mut bytes_read = 0u64;
    let mut has_rotated_archives = false;
    let mut recovered_span_count = 0u64;
    let mut truncation = DiagnosticTruncation::default();

    for session_id in &selected_session_ids {
        let result = reader
            .read_session(session_id)
            .map_err(|err| KernelError::Trace(err.to_string()))?;
        bytes_read = bytes_read.saturating_add(result.bytes);
        has_rotated_archives |= result.has_rotated_archives;
        recovered_span_count = recovered_span_count.saturating_add(result.truncated_count);
        for warning in result.warnings {
            warnings.push(format!(
                "{}:{}: {}",
                warning.path.display(),
                warning.line,
                warning.message
            ));
        }
        for span in result.spans {
            if spans.len() >= bounds.max_spans {
                truncation.spans = true;
                continue;
            }
            let mut span_truncation = false;
            let diagnostic_span = diagnostic_span(
                &span,
                &redactor,
                bounds.max_text_snippet_bytes,
                &mut span_truncation,
            );
            if span_truncation {
                truncation.text = true;
            }
            for event in &span.events {
                if events.len() >= bounds.max_events {
                    truncation.events = true;
                    continue;
                }
                let mut event_truncation = false;
                let diagnostic_event = DiagnosticEvent {
                    session_id: span.session_id.clone(),
                    span_id: span.id.clone(),
                    timestamp: event.timestamp,
                    name: redact_text(
                        &event.name,
                        &redactor,
                        bounds.max_text_snippet_bytes,
                        &mut event_truncation,
                    ),
                    attributes: diagnostic_attributes(
                        &event.attributes,
                        &redactor,
                        bounds.max_text_snippet_bytes,
                        &mut event_truncation,
                    ),
                };
                if event_truncation {
                    truncation.text = true;
                }
                events.push(diagnostic_event);
            }
            spans.push(diagnostic_span);
        }
    }

    let classification = classify_failure(&spans, &events);
    Ok(TraceDiagnosticBundle {
        bundle_version: TRACE_DIAGNOSTIC_BUNDLE_VERSION,
        active_session_id: active_session_id.to_string(),
        selected_session_ids,
        generated_at: Utc::now(),
        bounds,
        spans,
        events,
        warnings,
        bytes_read,
        has_rotated_archives,
        recovered_span_count,
        truncation,
        classification,
    })
}

pub fn diagnosis_summary(bundle: &TraceDiagnosticBundle) -> DiagnosisSummary {
    DiagnosisSummary {
        primary_failure: bundle.classification.primary,
        secondary_failures: bundle.classification.secondary.clone(),
        confidence: bundle.classification.confidence,
        rationale: bundle.classification.rationale.clone(),
        selected_session_count: bundle.selected_session_ids.len(),
        span_count: bundle.spans.len(),
        event_count: bundle.events.len(),
        warning_count: bundle.warnings.len(),
        truncation: bundle.truncation.clone(),
    }
}

pub fn diagnosis_report_summary(
    bundle: &TraceDiagnosticBundle,
    report_path: Option<String>,
) -> DiagnosisReportSummary {
    DiagnosisReportSummary {
        schema_version: DIAGNOSIS_REPORT_SUMMARY_SCHEMA_VERSION,
        diagnosis_id: generate_diagnosis_id(Utc::now()),
        created_at: Utc::now(),
        summary: diagnosis_summary(bundle),
        selected_session_ids: bundle.selected_session_ids.clone(),
        bounds: bundle.bounds.clone(),
        report_path,
        remediation: None,
    }
}

pub fn generate_diagnosis_id(now: DateTime<Utc>) -> String {
    let short = uuid::Uuid::new_v4()
        .simple()
        .to_string()
        .chars()
        .take(8)
        .collect::<String>();
    format!("diag_{}_{short}", now.format("%Y%m%dT%H%M%SZ"))
}

fn select_sessions(
    reader: &TraceReader,
    active_session_id: &str,
    requested_session_id: Option<&str>,
    bounds: &TraceDiagnosticBounds,
) -> Result<Vec<String>, KernelError> {
    if let Some(session_id) = requested_session_id {
        return Ok(vec![session_id.to_string()]);
    }

    let summaries = reader
        .list_sessions()
        .map_err(|err| KernelError::Trace(err.to_string()))?;
    let cutoff = Utc::now() - Duration::days(i64::from(bounds.lookback_days));
    let mut selected = Vec::new();
    let mut seen = BTreeSet::new();
    let mut push_session = |session_id: String| {
        if selected.len() < bounds.max_sessions && seen.insert(session_id.clone()) {
            selected.push(session_id);
        }
    };

    if summaries
        .iter()
        .any(|summary| summary.session_id == active_session_id)
    {
        push_session(active_session_id.to_string());
    }

    for summary in summaries {
        if summary.last_touched_at < cutoff {
            continue;
        }
        push_session(summary.session_id);
    }

    Ok(selected)
}

fn diagnostic_span(
    span: &Span,
    redactor: &dyn SecretRedactor,
    max_text_bytes: usize,
    truncated: &mut bool,
) -> DiagnosticSpan {
    DiagnosticSpan {
        session_id: span.session_id.clone(),
        span_id: span.id.clone(),
        parent_id: span.parent_id.clone(),
        name: redact_text(&span.name, redactor, max_text_bytes, truncated),
        status: match &span.status {
            SpanStatus::Ok => DiagnosticSpanStatus::Ok,
            SpanStatus::Error { message } => DiagnosticSpanStatus::Error {
                message: redact_text(message, redactor, max_text_bytes, truncated),
            },
        },
        started_at: span.started_at,
        ended_at: span.ended_at,
        duration_ms: span.duration_ms,
        attributes: diagnostic_attributes(&span.attributes, redactor, max_text_bytes, truncated),
    }
}

fn diagnostic_attributes(
    attributes: &BTreeMap<String, AttributeValue>,
    redactor: &dyn SecretRedactor,
    max_text_bytes: usize,
    truncated: &mut bool,
) -> BTreeMap<String, String> {
    attributes
        .iter()
        .map(|(key, value)| {
            (
                redact_text(key, redactor, max_text_bytes, truncated),
                redact_text(
                    &attribute_value_to_string(value),
                    redactor,
                    max_text_bytes,
                    truncated,
                ),
            )
        })
        .collect()
}

fn attribute_value_to_string(value: &AttributeValue) -> String {
    match value {
        AttributeValue::String(value) => value.clone(),
        AttributeValue::Int(value) => value.to_string(),
        AttributeValue::Float(value) => value.to_string(),
        AttributeValue::Bool(value) => value.to_string(),
        AttributeValue::StringArray(values) => values.join(","),
        AttributeValue::IntArray(values) => values
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join(","),
    }
}

fn redact_text(
    input: &str,
    redactor: &dyn SecretRedactor,
    max_text_bytes: usize,
    truncated: &mut bool,
) -> String {
    let redacted = redactor.redact(input);
    if redacted.len() <= max_text_bytes {
        return redacted;
    }
    *truncated = true;
    let mut boundary = max_text_bytes;
    while boundary > 0 && !redacted.is_char_boundary(boundary) {
        boundary -= 1;
    }
    format!("{}...[truncated]", &redacted[..boundary])
}

fn classify_failure(spans: &[DiagnosticSpan], events: &[DiagnosticEvent]) -> FailureClassification {
    let mut findings = BTreeSet::new();
    for span in spans {
        let status_message = match &span.status {
            DiagnosticSpanStatus::Ok => String::new(),
            DiagnosticSpanStatus::Error { message } => message.clone(),
        };
        let joined = format!(
            "{} {} {}",
            span.name,
            status_message,
            span.attributes
                .values()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
        )
        .to_ascii_lowercase();
        classify_text(&joined, &mut findings);
    }
    for event in events {
        let joined = format!(
            "{} {}",
            event.name,
            event
                .attributes
                .values()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ")
        )
        .to_ascii_lowercase();
        classify_text(&joined, &mut findings);
    }

    let primary = findings
        .iter()
        .copied()
        .next()
        .unwrap_or(FailureKind::UnknownLocal);
    let secondary = findings
        .into_iter()
        .filter(|kind| *kind != primary)
        .collect::<Vec<_>>();
    let confidence = if primary == FailureKind::UnknownLocal {
        if spans.is_empty() {
            0.2
        } else {
            0.35
        }
    } else {
        0.75
    };
    let rationale = if primary == FailureKind::UnknownLocal {
        "No bounded trace signal matched the fixed v0.14 failure taxonomy.".to_string()
    } else {
        format!(
            "Bounded trace text matched the `{}` failure taxonomy entry.",
            primary.label()
        )
    };
    FailureClassification {
        primary,
        secondary,
        confidence,
        rationale,
    }
}

fn classify_text(text: &str, findings: &mut BTreeSet<FailureKind>) {
    if text.contains("approval") && (text.contains("abandon") || text.contains("timeout")) {
        findings.insert(FailureKind::ApprovalAbandoned);
    }
    if text.contains("timeout") || text.contains("timed out") || text.contains("deadline") {
        findings.insert(FailureKind::Timeout);
    }
    if text.contains("denied") || text.contains("policy denied") || text.contains("not allowed") {
        findings.insert(FailureKind::ToolDenied);
    }
    if text.contains("cost") && text.contains("cap") {
        findings.insert(FailureKind::CostCap);
    }
    if text.contains("context") && (text.contains("pressure") || text.contains("window")) {
        findings.insert(FailureKind::ContextPressure);
    }
    if text.contains("memory") && (text.contains("mismatch") || text.contains("conflict")) {
        findings.insert(FailureKind::MemoryMismatch);
    }
    if text.contains("adapter") && text.contains("training") {
        findings.insert(FailureKind::AdapterTrainingFailure);
    }
    if text.contains("provider")
        || text.contains("model")
        || text.contains("api")
        || text.contains("http")
    {
        findings.insert(FailureKind::ProviderError);
    }
    if text.contains("tool") && (text.contains("failed") || text.contains("error")) {
        findings.insert(FailureKind::ToolFailed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::replay::{JsonlTraceWriter, TraceStorageLimits, TraceWriter};
    use allbert_proto::{SpanKind, SpanStatus};

    fn span(session_id: &str, id: &str, name: &str, status: SpanStatus) -> Span {
        Span {
            id: id.into(),
            parent_id: None,
            session_id: session_id.into(),
            trace_id: format!("trace-{session_id}"),
            name: name.into(),
            kind: SpanKind::Internal,
            started_at: Utc::now(),
            ended_at: Some(Utc::now()),
            duration_ms: Some(10),
            status,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        }
    }

    #[test]
    fn builds_bounded_redacted_bundle() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let writer =
            JsonlTraceWriter::new(&paths, "session-a", TraceStorageLimits::default()).unwrap();
        let mut first = span(
            "session-a",
            "span-a",
            "tool failed",
            SpanStatus::Error {
                message: "provider timeout with sk-test_1234567890abcdef".into(),
            },
        );
        first
            .attributes
            .insert("payload".into(), AttributeValue::String("x".repeat(2_000)));
        writer.span_ended(&first).expect("write span");

        let config = SelfDiagnosisConfig {
            max_text_snippet_bytes: 1_024,
            ..SelfDiagnosisConfig::default()
        };
        let bundle =
            build_trace_diagnostic_bundle(&paths, &config, "session-a", None, None).unwrap();
        assert_eq!(bundle.selected_session_ids, vec!["session-a"]);
        assert_eq!(bundle.spans.len(), 1);
        assert!(bundle.truncation.text);
        let rendered = serde_json::to_string(&bundle).unwrap();
        assert!(!rendered.contains("sk-test_1234567890abcdef"));
        assert!(rendered.contains("<redacted:secret>"));
        assert_eq!(bundle.classification.primary, FailureKind::ProviderError);
        assert!(bundle
            .classification
            .secondary
            .contains(&FailureKind::Timeout));
    }

    #[test]
    fn explicit_session_limits_selection() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        for session in ["session-a", "session-b"] {
            let writer =
                JsonlTraceWriter::new(&paths, session, TraceStorageLimits::default()).unwrap();
            writer
                .span_ended(&span(session, session, "ok", SpanStatus::Ok))
                .expect("write span");
        }
        let bundle = build_trace_diagnostic_bundle(
            &paths,
            &SelfDiagnosisConfig::default(),
            "session-a",
            Some("session-b"),
            None,
        )
        .unwrap();
        assert_eq!(bundle.selected_session_ids, vec!["session-b"]);
        assert!(bundle
            .spans
            .iter()
            .all(|span| span.session_id == "session-b"));
    }

    #[test]
    fn rejects_out_of_range_lookback_override() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let err = build_trace_diagnostic_bundle(
            &paths,
            &SelfDiagnosisConfig::default(),
            "session-a",
            None,
            Some(0),
        )
        .unwrap_err();
        assert!(err.to_string().contains("lookback_days"));
    }
}
