use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use allbert_proto::{AttributeValue, Span, SpanStatus};
use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;

use crate::atomic_write;
use crate::config::SelfDiagnosisConfig;
use crate::error::KernelError;
use crate::memory::{self, StageMemoryRequest, StagedMemoryKind};
use crate::paths::AllbertPaths;
use crate::replay::{DefaultSecretRedactor, SecretRedactor, TraceReader};
use crate::self_improvement::{
    create_rust_rebuild_worktree, emit_patch_artifact, run_tier_a_validation, PatchArtifact,
    RebuildWorktree, TierAValidationReport,
};
use crate::skills::{SkillProvenance, SkillStore};
use crate::Config;

pub const TRACE_DIAGNOSTIC_BUNDLE_VERSION: u32 = 1;
pub const DIAGNOSIS_REPORT_SUMMARY_SCHEMA_VERSION: u32 = 1;
pub const DIAGNOSIS_ARTIFACT_ROOT: &str = "artifacts/diagnostics";

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
    pub artifact_path: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DiagnosisRemediationKind {
    Code,
    Skill,
    Memory,
}

impl DiagnosisRemediationKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::Code => "code",
            Self::Skill => "skill",
            Self::Memory => "memory",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiagnosisRemediationRequest {
    pub kind: DiagnosisRemediationKind,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportSummary {
    pub schema_version: u32,
    pub diagnosis_id: String,
    pub session_id: String,
    pub created_at: DateTime<Utc>,
    pub selected_session_ids: Vec<String>,
    pub classification: FailureKind,
    pub confidence: f32,
    pub rationale: String,
    pub bounds: TraceDiagnosticBounds,
    pub truncation: DiagnosticTruncation,
    pub warnings: Vec<String>,
    pub span_count: usize,
    pub event_count: usize,
    pub report_path: String,
    pub remediation: Option<DiagnosisRemediationSummary>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportArtifact {
    pub summary: DiagnosisReportSummary,
    pub report_markdown: String,
    pub report_path: PathBuf,
    pub summary_path: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DiagnosisReportIndexEntry {
    pub summary: DiagnosisReportSummary,
    pub report_exists: bool,
    pub summary_path: PathBuf,
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

pub fn run_diagnosis_report(
    paths: &AllbertPaths,
    config: &SelfDiagnosisConfig,
    active_session_id: &str,
    requested_session_id: Option<&str>,
    lookback_days_override: Option<u16>,
) -> Result<DiagnosisReportArtifact, KernelError> {
    if !config.enabled {
        return Err(KernelError::Request(
            "self_diagnosis.enabled is false; run `/settings show self_diagnosis` and enable self_diagnosis.enabled before diagnosing".into(),
        ));
    }
    let bundle = build_trace_diagnostic_bundle(
        paths,
        config,
        active_session_id,
        requested_session_id,
        lookback_days_override,
    )?;
    write_diagnosis_report(paths, config, active_session_id, &bundle)
}

pub fn run_diagnosis_report_with_remediation(
    paths: &AllbertPaths,
    config: &Config,
    active_session_id: &str,
    requested_session_id: Option<&str>,
    lookback_days_override: Option<u16>,
    remediation: DiagnosisRemediationRequest,
) -> Result<DiagnosisReportArtifact, KernelError> {
    validate_remediation_request(&config.self_diagnosis, &remediation)?;
    let bundle = build_trace_diagnostic_bundle(
        paths,
        &config.self_diagnosis,
        active_session_id,
        requested_session_id,
        lookback_days_override,
    )?;
    let mut artifact =
        write_diagnosis_report(paths, &config.self_diagnosis, active_session_id, &bundle)?;
    let remediation_summary = route_remediation(paths, config, &artifact, &remediation)?;
    artifact.summary.remediation = Some(remediation_summary);
    rewrite_diagnosis_artifact(paths, &config.self_diagnosis, &bundle, &mut artifact)?;
    Ok(artifact)
}

fn validate_remediation_request(
    config: &SelfDiagnosisConfig,
    remediation: &DiagnosisRemediationRequest,
) -> Result<(), KernelError> {
    if !config.enabled {
        return Err(KernelError::Request(
            "self_diagnosis.enabled is false; run `/settings show self_diagnosis` and enable self_diagnosis.enabled before diagnosing".into(),
        ));
    }
    if !config.allow_remediation {
        return Err(KernelError::Request(
            "self_diagnosis.allow_remediation is false; run `/settings show self_diagnosis.allow_remediation` and opt in before remediation".into(),
        ));
    }
    if remediation.reason.trim().is_empty() {
        return Err(KernelError::Request(
            "diagnosis remediation requires a non-empty --reason".into(),
        ));
    }
    Ok(())
}

pub fn write_diagnosis_report(
    paths: &AllbertPaths,
    config: &SelfDiagnosisConfig,
    session_id: &str,
    bundle: &TraceDiagnosticBundle,
) -> Result<DiagnosisReportArtifact, KernelError> {
    let created_at = Utc::now();
    let diagnosis_id = generate_diagnosis_id(created_at);
    let report_dir = diagnosis_report_dir(paths, session_id, &diagnosis_id);
    std::fs::create_dir_all(&report_dir).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("create {}: {err}", report_dir.display()),
        ))
    })?;
    let report_path = report_dir.join("report.md");
    let summary_path = report_dir.join("bundle.summary.json");
    let mut summary = diagnosis_report_summary_with_id(
        bundle,
        session_id,
        &diagnosis_id,
        created_at,
        report_path.display().to_string(),
    );
    let mut report_markdown = render_markdown_report(bundle, &summary);
    if report_markdown.len() > config.max_report_bytes {
        summary.truncation.report = true;
        report_markdown = truncate_report(report_markdown, config.max_report_bytes);
    }
    let summary_json = serde_json::to_vec_pretty(&summary)
        .map_err(|err| KernelError::InitFailed(format!("serialize diagnosis summary: {err}")))?;
    atomic_write(&summary_path, &summary_json).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", summary_path.display()),
        ))
    })?;
    atomic_write(&report_path, report_markdown.as_bytes()).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", report_path.display()),
        ))
    })?;
    Ok(DiagnosisReportArtifact {
        summary,
        report_markdown,
        report_path,
        summary_path,
    })
}

fn rewrite_diagnosis_artifact(
    _paths: &AllbertPaths,
    config: &SelfDiagnosisConfig,
    bundle: &TraceDiagnosticBundle,
    artifact: &mut DiagnosisReportArtifact,
) -> Result<(), KernelError> {
    let mut report_markdown = render_markdown_report(bundle, &artifact.summary);
    if report_markdown.len() > config.max_report_bytes {
        artifact.summary.truncation.report = true;
        report_markdown = truncate_report(report_markdown, config.max_report_bytes);
    }
    let summary_json = serde_json::to_vec_pretty(&artifact.summary)
        .map_err(|err| KernelError::InitFailed(format!("serialize diagnosis summary: {err}")))?;
    atomic_write(&artifact.summary_path, &summary_json).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", artifact.summary_path.display()),
        ))
    })?;
    atomic_write(&artifact.report_path, report_markdown.as_bytes()).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", artifact.report_path.display()),
        ))
    })?;
    artifact.report_markdown = report_markdown;
    Ok(())
}

pub fn list_diagnosis_reports(
    paths: &AllbertPaths,
    session_id: Option<&str>,
) -> Result<Vec<DiagnosisReportIndexEntry>, KernelError> {
    let mut entries = Vec::new();
    let session_dirs = diagnosis_session_dirs(paths, session_id)?;
    for session_dir in session_dirs {
        let diagnostics = session_dir.join(DIAGNOSIS_ARTIFACT_ROOT);
        if !diagnostics.exists() {
            continue;
        }
        let read_dir = std::fs::read_dir(&diagnostics).map_err(|err| {
            KernelError::Io(std::io::Error::new(
                err.kind(),
                format!("read {}: {err}", diagnostics.display()),
            ))
        })?;
        for entry in read_dir {
            let entry = entry.map_err(KernelError::Io)?;
            if !entry.path().is_dir() {
                continue;
            }
            let summary_path = entry.path().join("bundle.summary.json");
            if !summary_path.exists() {
                continue;
            }
            let summary = read_summary_file(&summary_path)?;
            let report_exists = entry.path().join("report.md").exists();
            entries.push(DiagnosisReportIndexEntry {
                summary,
                report_exists,
                summary_path,
            });
        }
    }
    entries.sort_by(|left, right| {
        right
            .summary
            .created_at
            .cmp(&left.summary.created_at)
            .then_with(|| left.summary.diagnosis_id.cmp(&right.summary.diagnosis_id))
    });
    Ok(entries)
}

pub fn read_diagnosis_report(
    paths: &AllbertPaths,
    diagnosis_id: &str,
) -> Result<DiagnosisReportArtifact, KernelError> {
    if !valid_diagnosis_id(diagnosis_id) {
        return Err(KernelError::Request(format!(
            "invalid diagnosis id `{diagnosis_id}`"
        )));
    }
    for entry in list_diagnosis_reports(paths, None)? {
        if entry.summary.diagnosis_id != diagnosis_id {
            continue;
        }
        let report_path = entry
            .summary_path
            .parent()
            .map(|path| path.join("report.md"))
            .ok_or_else(|| {
                KernelError::Request(format!(
                    "malformed diagnosis summary path: {}",
                    entry.summary_path.display()
                ))
            })?;
        let report_markdown = std::fs::read_to_string(&report_path).map_err(|err| {
            KernelError::Io(std::io::Error::new(
                err.kind(),
                format!("read {}: {err}", report_path.display()),
            ))
        })?;
        return Ok(DiagnosisReportArtifact {
            summary: entry.summary,
            report_markdown,
            report_path,
            summary_path: entry.summary_path,
        });
    }
    Err(KernelError::Request(format!(
        "diagnosis report not found: {diagnosis_id}"
    )))
}

fn route_remediation(
    paths: &AllbertPaths,
    config: &Config,
    artifact: &DiagnosisReportArtifact,
    remediation: &DiagnosisRemediationRequest,
) -> Result<DiagnosisRemediationSummary, KernelError> {
    match remediation.kind {
        DiagnosisRemediationKind::Code => {
            route_code_remediation(paths, config, artifact, remediation)
        }
        DiagnosisRemediationKind::Skill => route_skill_remediation(paths, artifact, remediation),
        DiagnosisRemediationKind::Memory => {
            route_memory_remediation(paths, config, artifact, remediation)
        }
    }
}

fn route_code_remediation(
    paths: &AllbertPaths,
    config: &Config,
    artifact: &DiagnosisReportArtifact,
    remediation: &DiagnosisRemediationRequest,
) -> Result<DiagnosisRemediationSummary, KernelError> {
    let branch_hint = format!("self-diagnosis-{}", artifact.summary.diagnosis_id);
    let worktree = create_rust_rebuild_worktree(paths, config, Some(&branch_hint))?;
    let target_dir = worktree
        .path
        .join("docs")
        .join("reports")
        .join("self-diagnosis");
    std::fs::create_dir_all(&target_dir).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("create {}: {err}", target_dir.display()),
        ))
    })?;
    let target = target_dir.join(format!("{}.md", artifact.summary.diagnosis_id));
    let body = format!(
        "# Self-Diagnosed Code Remediation\n\nReason: {}\n\nSource report: {}\n\n{}",
        remediation.reason.trim(),
        artifact.summary.report_path,
        artifact.report_markdown
    );
    atomic_write(&target, body.as_bytes()).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", target.display()),
        ))
    })?;

    let validation = run_tier_a_validation(&worktree.path);
    let approval_id = format!("approval_{}", artifact.summary.diagnosis_id);
    let patch = emit_patch_artifact(
        paths,
        &worktree.path,
        &artifact.summary.session_id,
        Some(&artifact.summary.diagnosis_id),
    )?;
    write_patch_approval(
        paths,
        artifact,
        remediation,
        &approval_id,
        &worktree,
        &patch,
        &validation,
    )?;
    Ok(DiagnosisRemediationSummary {
        kind: remediation.kind.label().into(),
        reason: remediation.reason.trim().into(),
        status: DiagnosisRemediationStatus::Routed,
        message: format!(
            "created patch approval {approval_id}; review with `allbert-cli approvals show {approval_id}`"
        ),
        artifact_path: Some(patch.path.display().to_string()),
    })
}

fn route_skill_remediation(
    paths: &AllbertPaths,
    artifact: &DiagnosisReportArtifact,
    remediation: &DiagnosisRemediationRequest,
) -> Result<DiagnosisRemediationSummary, KernelError> {
    let mut skills = SkillStore::discover(&paths.skills);
    let suffix = artifact
        .summary
        .diagnosis_id
        .rsplit('_')
        .next()
        .unwrap_or("diagnosis");
    let name = format!("self-diagnosed-{suffix}");
    let body = format!(
        "# Self-Diagnosed Skill Draft\n\nUse this quarantined draft only after reviewing the diagnosis report.\n\n- Diagnosis: `{}`\n- Reason: {}\n- Classification: `{}`\n- Report: `{}`\n\n## Candidate Behavior\n\nDescribe the repeatable procedure that would prevent or explain this failure. Keep any install decision in the normal skill review flow.\n",
        artifact.summary.diagnosis_id,
        remediation.reason.trim(),
        artifact.summary.classification.label(),
        artifact.summary.report_path
    );
    let skill = skills
        .create(
            &paths.skills_incoming,
            &name,
            "Self-diagnosed remediation draft awaiting operator review.",
            &[],
            &body,
            SkillProvenance::SelfDiagnosed,
        )
        .map_err(|err| KernelError::InitFailed(err.to_string()))?;
    Ok(DiagnosisRemediationSummary {
        kind: remediation.kind.label().into(),
        reason: remediation.reason.trim().into(),
        status: DiagnosisRemediationStatus::Routed,
        message: format!(
            "created quarantined skill draft {}; review with `allbert-cli skills validate {}`",
            skill.name,
            skill.path.display()
        ),
        artifact_path: Some(skill.path.display().to_string()),
    })
}

fn route_memory_remediation(
    paths: &AllbertPaths,
    config: &Config,
    artifact: &DiagnosisReportArtifact,
    remediation: &DiagnosisRemediationRequest,
) -> Result<DiagnosisRemediationSummary, KernelError> {
    let request = StageMemoryRequest {
        session_id: artifact.summary.session_id.clone(),
        turn_id: format!("diagnosis:{}", artifact.summary.diagnosis_id),
        agent: "allbert/self-diagnosis".into(),
        source: "self-diagnosis".into(),
        content: format!(
            "# Self-Diagnosis Memory Candidate\n\nReason: {}\n\nDiagnosis: `{}`\nClassification: `{}`\nReport: `{}`\n\nReview this candidate before promotion. Do not promote if it is only a transient local failure.",
            remediation.reason.trim(),
            artifact.summary.diagnosis_id,
            artifact.summary.classification.label(),
            artifact.summary.report_path
        ),
        kind: StagedMemoryKind::ExplicitRequest,
        summary: format!(
            "Self-diagnosis candidate: {}",
            artifact.summary.classification.label()
        ),
        tags: vec!["self-diagnosis".into(), artifact.summary.classification.label().into()],
        provenance: Some(json!({
            "source": "self-diagnosis",
            "diagnosis_id": artifact.summary.diagnosis_id,
            "report_path": artifact.summary.report_path,
            "reason": remediation.reason.trim(),
        })),
        fingerprint_basis: Some(format!(
            "{}:{}:{}",
            artifact.summary.diagnosis_id,
            remediation.kind.label(),
            remediation.reason.trim()
        )),
        facts: Vec::new(),
    };
    let staged = memory::stage_memory(paths, &config.memory, request)?;
    Ok(DiagnosisRemediationSummary {
        kind: remediation.kind.label().into(),
        reason: remediation.reason.trim().into(),
        status: DiagnosisRemediationStatus::Routed,
        message: format!(
            "staged memory candidate {}; review with `allbert-cli memory staged list`",
            staged.id
        ),
        artifact_path: Some(staged.path),
    })
}

fn write_patch_approval(
    paths: &AllbertPaths,
    artifact: &DiagnosisReportArtifact,
    remediation: &DiagnosisRemediationRequest,
    approval_id: &str,
    worktree: &RebuildWorktree,
    patch: &PatchArtifact,
    validation: &TierAValidationReport,
) -> Result<(), KernelError> {
    let approvals_dir = paths
        .sessions
        .join(&artifact.summary.session_id)
        .join("approvals");
    std::fs::create_dir_all(&approvals_dir).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("create {}: {err}", approvals_dir.display()),
        ))
    })?;
    let requested_at = Utc::now();
    let expires_at = requested_at + Duration::hours(24);
    let validation_status = if validation.steps.iter().all(|step| step.success) {
        "passed"
    } else {
        "needs-review"
    };
    let body = format!(
        "---\nid: {approval_id}\nsession_id: {}\nchannel: repl\nsender: local\nagent: allbert/root\ntool: self-diagnosis\nrequest_id: 0\nkind: patch-approval\nrequested_at: {}\nexpires_at: {}\nstatus: pending\nsource_checkout: {}\nbranch: {}\nworktree_path: {}\nvalidation: {validation_status}\noverall: {}\nartifact_path: {}\n---\n\n# Self-diagnosed code remediation\n\nReason: {}\n\nDiagnosis report: {}\n\nThis approval was generated only from an explicit diagnose remediation command. Accepting records approval; install remains a separate `allbert-cli self-improvement install {approval_id}` action.\n",
        artifact.summary.session_id,
        requested_at.to_rfc3339(),
        expires_at.to_rfc3339(),
        worktree.source_checkout.display(),
        worktree.branch,
        worktree.path.display(),
        validation.overall.label(),
        patch.path.display(),
        remediation.reason.trim(),
        artifact.summary.report_path
    );
    let path = approvals_dir.join(format!("{approval_id}.md"));
    atomic_write(&path, body.as_bytes()).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("write {}: {err}", path.display()),
        ))
    })?;
    Ok(())
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
    session_id: &str,
    report_path: String,
) -> DiagnosisReportSummary {
    let created_at = Utc::now();
    diagnosis_report_summary_with_id(
        bundle,
        session_id,
        &generate_diagnosis_id(created_at),
        created_at,
        report_path,
    )
}

fn diagnosis_report_summary_with_id(
    bundle: &TraceDiagnosticBundle,
    session_id: &str,
    diagnosis_id: &str,
    created_at: DateTime<Utc>,
    report_path: String,
) -> DiagnosisReportSummary {
    DiagnosisReportSummary {
        schema_version: DIAGNOSIS_REPORT_SUMMARY_SCHEMA_VERSION,
        diagnosis_id: diagnosis_id.to_string(),
        session_id: session_id.to_string(),
        created_at,
        selected_session_ids: bundle.selected_session_ids.clone(),
        classification: bundle.classification.primary,
        confidence: bundle.classification.confidence,
        rationale: bundle.classification.rationale.clone(),
        bounds: bundle.bounds.clone(),
        truncation: bundle.truncation.clone(),
        warnings: bundle.warnings.clone(),
        span_count: bundle.spans.len(),
        event_count: bundle.events.len(),
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

fn diagnosis_report_dir(paths: &AllbertPaths, session_id: &str, diagnosis_id: &str) -> PathBuf {
    paths
        .sessions
        .join(session_id)
        .join(DIAGNOSIS_ARTIFACT_ROOT)
        .join(diagnosis_id)
}

fn diagnosis_session_dirs(
    paths: &AllbertPaths,
    session_id: Option<&str>,
) -> Result<Vec<PathBuf>, KernelError> {
    if let Some(session_id) = session_id {
        return Ok(vec![paths.sessions.join(session_id)]);
    }
    if !paths.sessions.exists() {
        return Ok(Vec::new());
    }
    let mut dirs = Vec::new();
    for entry in std::fs::read_dir(&paths.sessions).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("read {}: {err}", paths.sessions.display()),
        ))
    })? {
        let entry = entry.map_err(KernelError::Io)?;
        if entry.path().is_dir() && !entry.file_name().to_string_lossy().starts_with('.') {
            dirs.push(entry.path());
        }
    }
    Ok(dirs)
}

fn read_summary_file(path: &Path) -> Result<DiagnosisReportSummary, KernelError> {
    let raw = std::fs::read_to_string(path).map_err(|err| {
        KernelError::Io(std::io::Error::new(
            err.kind(),
            format!("read {}: {err}", path.display()),
        ))
    })?;
    serde_json::from_str(&raw)
        .map_err(|err| KernelError::Request(format!("parse {}: {err}", path.display())))
}

fn valid_diagnosis_id(input: &str) -> bool {
    input.starts_with("diag_")
        && input.len() >= "diag_20260426T000000Z_00000000".len()
        && input.chars().all(|ch| {
            ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '_' || ch == 'T' || ch == 'Z'
        })
}

fn render_markdown_report(
    bundle: &TraceDiagnosticBundle,
    summary: &DiagnosisReportSummary,
) -> String {
    let mut report = String::new();
    report.push_str("# Allbert Diagnosis Report\n\n");
    report.push_str("## Summary\n\n");
    report.push_str(&format!("- Diagnosis id: `{}`\n", summary.diagnosis_id));
    report.push_str(&format!("- Session artifact: `{}`\n", summary.session_id));
    report.push_str(&format!("- Created: `{}`\n", summary.created_at));
    report.push_str(&format!(
        "- Selected sessions: `{}`\n",
        if summary.selected_session_ids.is_empty() {
            "(none)".to_string()
        } else {
            summary.selected_session_ids.join("`, `")
        }
    ));
    report.push_str(&format!(
        "- Spans/events: {}/{}\n\n",
        summary.span_count, summary.event_count
    ));

    report.push_str("## Classification\n\n");
    report.push_str(&format!(
        "- Primary: `{}`\n- Confidence: {:.2}\n- Rationale: {}\n",
        summary.classification.label(),
        summary.confidence,
        summary.rationale
    ));
    if bundle.classification.secondary.is_empty() {
        report.push_str("- Secondary: none\n\n");
    } else {
        report.push_str(&format!(
            "- Secondary: `{}`\n\n",
            bundle
                .classification
                .secondary
                .iter()
                .map(|kind| kind.label())
                .collect::<Vec<_>>()
                .join("`, `")
        ));
    }

    report.push_str("## Evidence\n\n");
    append_evidence(bundle, &mut report);

    report.push_str("\n## Skipped Or Truncated Data\n\n");
    append_truncation(bundle, summary, &mut report);

    report.push_str("\n## Recommended Next Actions\n\n");
    for action in recommended_actions(summary.classification) {
        report.push_str("- ");
        report.push_str(action);
        report.push('\n');
    }

    report.push_str("\n## Remediation Status\n\n");
    match &summary.remediation {
        Some(remediation) => {
            report.push_str(&format!(
                "- `{}` remediation: {:?}. {}\n",
                remediation.kind, remediation.status, remediation.message
            ));
        }
        None => report.push_str(
            "- No remediation was requested. Run an explicit diagnose remediation command with `--reason` when you want Allbert to propose a reviewed fix.\n",
        ),
    }
    report
}

fn append_evidence(bundle: &TraceDiagnosticBundle, report: &mut String) {
    let error_spans = bundle
        .spans
        .iter()
        .filter(|span| matches!(span.status, DiagnosticSpanStatus::Error { .. }))
        .take(8)
        .collect::<Vec<_>>();
    if error_spans.is_empty() && bundle.events.is_empty() {
        report.push_str("No error spans or events were present in the bounded trace bundle.\n");
        return;
    }
    if !error_spans.is_empty() {
        report.push_str("Error spans:\n");
        for span in error_spans {
            let status = match &span.status {
                DiagnosticSpanStatus::Ok => "ok".to_string(),
                DiagnosticSpanStatus::Error { message } => format!("error: {message}"),
            };
            report.push_str(&format!(
                "- `{}` in `{}` at `{}`: {}\n",
                span.name, span.session_id, span.started_at, status
            ));
        }
    }
    if !bundle.events.is_empty() {
        report.push_str("Events:\n");
        for event in bundle.events.iter().take(8) {
            report.push_str(&format!(
                "- `{}` in span `{}` at `{}`\n",
                event.name, event.span_id, event.timestamp
            ));
        }
    }
}

fn append_truncation(
    bundle: &TraceDiagnosticBundle,
    summary: &DiagnosisReportSummary,
    report: &mut String,
) {
    report.push_str(&format!(
        "- Bounds: sessions={}, spans={}, events={}, text_bytes={}, report_bytes={}\n",
        summary.bounds.max_sessions,
        summary.bounds.max_spans,
        summary.bounds.max_events,
        summary.bounds.max_text_snippet_bytes,
        summary.bounds.max_report_bytes
    ));
    report.push_str(&format!(
        "- Truncated: sessions={}, spans={}, events={}, text={}, report={}\n",
        yes_no(summary.truncation.sessions),
        yes_no(summary.truncation.spans),
        yes_no(summary.truncation.events),
        yes_no(summary.truncation.text),
        yes_no(summary.truncation.report)
    ));
    report.push_str(&format!(
        "- Bytes read: {}; rotated archives: {}; recovered stale spans: {}\n",
        bundle.bytes_read,
        yes_no(bundle.has_rotated_archives),
        bundle.recovered_span_count
    ));
    if bundle.warnings.is_empty() {
        report.push_str("- Warnings: none\n");
    } else {
        report.push_str("- Warnings:\n");
        for warning in bundle.warnings.iter().take(8) {
            report.push_str(&format!("  - {warning}\n"));
        }
    }
}

fn recommended_actions(kind: FailureKind) -> &'static [&'static str] {
    match kind {
        FailureKind::ProviderError => &[
            "Check provider availability, model configuration, and visible API key environment.",
            "Use `allbert-cli trace show` for nearby provider spans if more detail is needed.",
        ],
        FailureKind::ToolDenied => &[
            "Review the denied command or path against `security.exec_allow` and filesystem roots.",
            "Keep approval policy changes explicit; diagnosis does not weaken security settings.",
        ],
        FailureKind::ToolFailed => &[
            "Inspect the failing tool inputs and stderr summary in the trace evidence.",
            "Retry only after correcting the local command, path, or prerequisite.",
        ],
        FailureKind::Timeout => &[
            "Check whether the operation needs a smaller input, a larger configured timeout, or a manual retry.",
        ],
        FailureKind::ApprovalAbandoned => &[
            "Open the approval inbox and decide, reject, or recreate the stale request intentionally.",
        ],
        FailureKind::CostCap => &[
            "Inspect cost caps before retrying; use an explicit override only when the task warrants it.",
        ],
        FailureKind::ContextPressure => &[
            "Reduce prompt size, summarize older context, or use narrower retrieval before retrying.",
        ],
        FailureKind::MemoryMismatch => &[
            "Review staged and durable memory before promoting or correcting any memory candidate.",
        ],
        FailureKind::AdapterTrainingFailure => &[
            "Inspect adapter training artifacts and trainer environment before starting another run.",
        ],
        FailureKind::UnknownLocal => &[
            "No fixed taxonomy match was found; inspect the report evidence and nearby trace session manually.",
        ],
    }
}

fn truncate_report(mut report: String, max_bytes: usize) -> String {
    let marker = "\n\n[diagnosis report truncated at configured max_report_bytes]\n";
    let keep = max_bytes.saturating_sub(marker.len());
    let mut boundary = keep.min(report.len());
    while boundary > 0 && !report.is_char_boundary(boundary) {
        boundary -= 1;
    }
    report.truncate(boundary);
    report.push_str(marker);
    report
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
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
    use crate::self_improvement::{ValidationOverall, ValidationStepResult};
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

    #[test]
    fn code_remediation_writes_patch_approval_surface() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths");
        let writer =
            JsonlTraceWriter::new(&paths, "session-a", TraceStorageLimits::default()).unwrap();
        writer
            .span_ended(&span(
                "session-a",
                "span-a",
                "provider call",
                SpanStatus::Error {
                    message: "provider timeout".into(),
                },
            ))
            .unwrap();
        let bundle = build_trace_diagnostic_bundle(
            &paths,
            &SelfDiagnosisConfig::default(),
            "session-a",
            None,
            None,
        )
        .unwrap();
        let artifact = write_diagnosis_report(
            &paths,
            &SelfDiagnosisConfig::default(),
            "session-a",
            &bundle,
        )
        .unwrap();
        let worktree_path = temp.path().join("worktree");
        std::fs::create_dir_all(&worktree_path).unwrap();
        let patch_path = temp.path().join("patch.diff");
        std::fs::write(&patch_path, "diff --git a/a b/a\n").unwrap();
        let worktree = RebuildWorktree {
            branch: "self-diagnosis-test".into(),
            path: worktree_path.clone(),
            source_checkout: temp.path().join("source"),
        };
        let patch = PatchArtifact {
            artifact_id: "diag-patch".into(),
            path: patch_path.clone(),
            bytes: 12,
        };
        let validation = TierAValidationReport {
            worktree_path,
            overall: ValidationOverall::SafeToMerge,
            steps: vec![ValidationStepResult {
                label: "fixture".into(),
                command: "true".into(),
                success: true,
                exit_code: Some(0),
                stdout_tail: String::new(),
                stderr_tail: String::new(),
            }],
        };
        let request = DiagnosisRemediationRequest {
            kind: DiagnosisRemediationKind::Code,
            reason: "Review a code fix.".into(),
        };
        write_patch_approval(
            &paths,
            &artifact,
            &request,
            "approval_diag_test",
            &worktree,
            &patch,
            &validation,
        )
        .unwrap();
        let approval = std::fs::read_to_string(
            paths
                .sessions
                .join("session-a")
                .join("approvals")
                .join("approval_diag_test.md"),
        )
        .unwrap();
        assert!(approval.contains("kind: patch-approval"));
        assert!(approval.contains(&patch_path.display().to_string()));
    }
}
