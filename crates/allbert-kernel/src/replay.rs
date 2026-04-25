use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime};

use allbert_proto::{AttributeValue, Span, SpanEvent, SpanKind, SpanStatus, TraceSessionSummary};
use chrono::{DateTime, Utc};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use thiserror::Error;

use crate::atomic_write;
use crate::config::{TraceConfig, TraceFieldPolicy};
use crate::paths::AllbertPaths;

pub const TRACE_RECORD_SCHEMA_VERSION: u16 = 1;
const TRACE_ACTIVE_FILE: &str = "trace.jsonl";
const CURRENT_SPANS_DIR: &str = "current_spans";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct TraceRecord {
    pub schema_version: u16,
    pub record_type: TraceRecordType,
    pub span: Span,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TraceRecordType {
    Span,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TraceRecordError {
    UnsupportedSchemaVersion { found: u16, supported: u16 },
}

impl std::fmt::Display for TraceRecordError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsupportedSchemaVersion { found, supported } => write!(
                f,
                "unsupported trace schema version {found}; this build supports schema version {supported}"
            ),
        }
    }
}

impl std::error::Error for TraceRecordError {}

impl TraceRecord {
    pub fn span(span: Span) -> Self {
        Self {
            schema_version: TRACE_RECORD_SCHEMA_VERSION,
            record_type: TraceRecordType::Span,
            span,
        }
    }

    pub fn validate_schema_version(&self) -> Result<(), TraceRecordError> {
        if self.schema_version == TRACE_RECORD_SCHEMA_VERSION {
            Ok(())
        } else {
            Err(TraceRecordError::UnsupportedSchemaVersion {
                found: self.schema_version,
                supported: TRACE_RECORD_SCHEMA_VERSION,
            })
        }
    }
}

#[derive(Debug, Error)]
pub enum TraceStoreError {
    #[error("trace io error at {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },
    #[error("trace json error at {path}: {source}")]
    Json {
        path: String,
        #[source]
        source: serde_json::Error,
    },
    #[error("{0}")]
    Record(#[from] TraceRecordError),
    #[error("invalid trace path: {0}")]
    InvalidPath(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceReadWarning {
    pub path: PathBuf,
    pub line: usize,
    pub message: String,
}

#[derive(Debug, Clone)]
pub struct TraceReadResult {
    pub spans: Vec<Span>,
    pub warnings: Vec<TraceReadWarning>,
    pub bytes: u64,
    pub has_rotated_archives: bool,
    pub truncated_count: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TraceGcCandidate {
    pub session_id: String,
    pub path: PathBuf,
    pub bytes: u64,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TraceGcPlan {
    pub total_bytes: u64,
    pub cap_bytes: u64,
    pub candidates: Vec<TraceGcCandidate>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TraceGcResult {
    pub removed: usize,
    pub freed_bytes: u64,
}

#[derive(Debug, Clone)]
pub struct TraceStorageLimits {
    pub session_disk_cap_bytes: u64,
}

impl TraceStorageLimits {
    pub fn from_session_cap_mb(session_disk_cap_mb: u64) -> Self {
        Self {
            session_disk_cap_bytes: session_disk_cap_mb.saturating_mul(1024 * 1024),
        }
    }
}

impl Default for TraceStorageLimits {
    fn default() -> Self {
        Self::from_session_cap_mb(50)
    }
}

pub trait TraceWriter: Send + Sync {
    fn span_started(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn span_ended(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn recover_in_flight(&self) -> Result<Vec<Span>, TraceStoreError>;
}

pub trait TracingHooks: Send + Sync {
    fn begin_span(&self, span: &Span) -> Result<(), TraceStoreError>;
    fn end_span(&self, span: &Span) -> Result<(), TraceStoreError>;
}

pub trait SecretRedactor: Send + Sync {
    fn redact(&self, input: &str) -> String;
}

#[derive(Clone)]
pub struct TraceCapturePolicy {
    pub tool_args: TraceFieldPolicy,
    pub tool_results: TraceFieldPolicy,
    pub provider_payloads: TraceFieldPolicy,
    pub redactor: Arc<dyn SecretRedactor>,
}

impl Default for TraceCapturePolicy {
    fn default() -> Self {
        Self {
            tool_args: TraceFieldPolicy::Capture,
            tool_results: TraceFieldPolicy::Capture,
            provider_payloads: TraceFieldPolicy::Capture,
            redactor: Arc::new(DefaultSecretRedactor::new()),
        }
    }
}

impl From<TraceConfig> for TraceCapturePolicy {
    fn from(config: TraceConfig) -> Self {
        Self {
            tool_args: config.redaction.tool_args,
            tool_results: config.redaction.tool_results,
            provider_payloads: config.redaction.provider_payloads,
            redactor: Arc::new(DefaultSecretRedactor::new()),
        }
    }
}

#[derive(Debug)]
pub struct DefaultSecretRedactor {
    patterns: Vec<Regex>,
}

impl DefaultSecretRedactor {
    pub fn new() -> Self {
        let patterns = [
            r"(?i)(AKIA|ASIA)[0-9A-Z]{16}",
            r"(?i)sk-(proj-)?[A-Za-z0-9_-]{16,}",
            r"(?i)sk-ant-[A-Za-z0-9_-]{16,}",
            r"(?i)sk-or-v1-[A-Za-z0-9_-]{16,}",
            r"(?i)xox[baprs]-[A-Za-z0-9-]{16,}",
            r"(?i)gh[pousr]_[A-Za-z0-9_]{20,}",
            r"(?i)github_pat_[A-Za-z0-9_]{20,}",
            r"(?i)glpat-[A-Za-z0-9_-]{20,}",
            r"AIza[0-9A-Za-z_-]{20,}",
            r"ya29\.[0-9A-Za-z_-]{20,}",
            r"hf_[A-Za-z0-9]{20,}",
            r"(?i)(sk|rk)_(live|test)_[A-Za-z0-9]{16,}",
            r#"(?i)\b(?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password)\s*[:=]\s*['"]?[^'"\s,;]+"#,
            r#"(?i)\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|OPENROUTER_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN|GITHUB_TOKEN|GITLAB_TOKEN|SLACK_BOT_TOKEN|TELEGRAM_BOT_TOKEN)\s*[:=]\s*['"]?[^'"\s,;]+"#,
            r"(?i)\bAuthorization\s*[:=]\s*Bearer\s+[A-Za-z0-9._~+/=-]{20,}",
            r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b",
        ];
        Self {
            patterns: patterns
                .into_iter()
                .map(|pattern| Regex::new(pattern).expect("redaction regex should compile"))
                .collect(),
        }
    }

    #[cfg(test)]
    fn contains_secret(&self, input: &str) -> bool {
        self.patterns.iter().any(|pattern| pattern.is_match(input))
    }
}

impl Default for DefaultSecretRedactor {
    fn default() -> Self {
        Self::new()
    }
}

impl SecretRedactor for DefaultSecretRedactor {
    fn redact(&self, input: &str) -> String {
        let mut redacted = input.to_string();
        for pattern in &self.patterns {
            redacted = pattern
                .replace_all(&redacted, "<redacted:secret>")
                .to_string();
        }
        redacted
    }
}

#[derive(Clone)]
pub struct JsonlTraceWriter {
    session_dir: PathBuf,
    active_path: PathBuf,
    current_spans_dir: PathBuf,
    limits: TraceStorageLimits,
    capture_policy: TraceCapturePolicy,
}

impl JsonlTraceWriter {
    pub fn new(
        paths: &AllbertPaths,
        session_id: &str,
        limits: TraceStorageLimits,
    ) -> Result<Self, TraceStoreError> {
        Self::with_policy(paths, session_id, limits, TraceCapturePolicy::default())
    }

    pub fn with_policy(
        paths: &AllbertPaths,
        session_id: &str,
        limits: TraceStorageLimits,
        capture_policy: TraceCapturePolicy,
    ) -> Result<Self, TraceStoreError> {
        validate_session_id(session_id)?;
        let session_dir = paths.sessions.join(session_id);
        let active_path = session_dir.join(TRACE_ACTIVE_FILE);
        let current_spans_dir = session_dir.join(CURRENT_SPANS_DIR);
        fs::create_dir_all(&current_spans_dir).map_err(|source| TraceStoreError::Io {
            path: current_spans_dir.display().to_string(),
            source,
        })?;
        Ok(Self {
            session_dir,
            active_path,
            current_spans_dir,
            limits,
            capture_policy,
        })
    }

    pub fn session_dir(&self) -> &Path {
        &self.session_dir
    }

    fn snapshot_path(&self, span_id: &str) -> PathBuf {
        self.current_spans_dir.join(format!("{span_id}.json"))
    }

    fn append_record(&self, record: &TraceRecord) -> Result<(), TraceStoreError> {
        let record = self.sanitize_record(record);
        fs::create_dir_all(&self.session_dir).map_err(|source| TraceStoreError::Io {
            path: self.session_dir.display().to_string(),
            source,
        })?;
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.active_path)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        serde_json::to_writer(&mut file, &record).map_err(|source| TraceStoreError::Json {
            path: self.active_path.display().to_string(),
            source,
        })?;
        file.write_all(b"\n")
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        file.flush().map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        self.rotate_if_needed()?;
        self.evict_archives_past_cap()
    }

    fn sanitize_record(&self, record: &TraceRecord) -> TraceRecord {
        let mut sanitized = record.clone();
        sanitize_span(&mut sanitized.span, &self.capture_policy);
        sanitized
    }

    fn rotate_if_needed(&self) -> Result<(), TraceStoreError> {
        let Ok(meta) = fs::metadata(&self.active_path) else {
            return Ok(());
        };
        if meta.len() <= self.limits.session_disk_cap_bytes {
            return Ok(());
        }

        let archive_path = self.next_archive_path()?;
        let tmp_path = archive_path.with_extension("jsonl.gz.tmp");
        let mut source = Vec::new();
        File::open(&self.active_path)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?
            .read_to_end(&mut source)
            .map_err(|source| TraceStoreError::Io {
                path: self.active_path.display().to_string(),
                source,
            })?;
        {
            let tmp = File::create(&tmp_path).map_err(|source| TraceStoreError::Io {
                path: tmp_path.display().to_string(),
                source,
            })?;
            let mut encoder = GzEncoder::new(tmp, Compression::default());
            encoder
                .write_all(&source)
                .map_err(|source| TraceStoreError::Io {
                    path: tmp_path.display().to_string(),
                    source,
                })?;
            encoder.finish().map_err(|source| TraceStoreError::Io {
                path: tmp_path.display().to_string(),
                source,
            })?;
        }
        fs::rename(&tmp_path, &archive_path).map_err(|source| TraceStoreError::Io {
            path: format!("{} -> {}", tmp_path.display(), archive_path.display()),
            source,
        })?;
        fs::remove_file(&self.active_path).map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        File::create(&self.active_path).map_err(|source| TraceStoreError::Io {
            path: self.active_path.display().to_string(),
            source,
        })?;
        Ok(())
    }

    fn next_archive_path(&self) -> Result<PathBuf, TraceStoreError> {
        let next = self
            .archive_paths()?
            .into_iter()
            .filter_map(|path| archive_index(&path))
            .max()
            .unwrap_or(0)
            .saturating_add(1);
        Ok(self.session_dir.join(format!("trace.{next}.jsonl.gz")))
    }

    fn archive_paths(&self) -> Result<Vec<PathBuf>, TraceStoreError> {
        if !self.session_dir.exists() {
            return Ok(Vec::new());
        }
        let mut archives = Vec::new();
        for entry in fs::read_dir(&self.session_dir).map_err(|source| TraceStoreError::Io {
            path: self.session_dir.display().to_string(),
            source,
        })? {
            let entry = entry.map_err(|source| TraceStoreError::Io {
                path: self.session_dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if archive_index(&path).is_some() {
                archives.push(path);
            }
        }
        archives.sort_by_key(|path| archive_index(path).unwrap_or(0));
        Ok(archives)
    }

    fn evict_archives_past_cap(&self) -> Result<(), TraceStoreError> {
        let mut archives = self.archive_paths()?;
        let mut total = trace_artifact_bytes(&self.session_dir)?;
        while total > self.limits.session_disk_cap_bytes && !archives.is_empty() {
            let oldest = archives.remove(0);
            let len = fs::metadata(&oldest).map(|meta| meta.len()).unwrap_or(0);
            fs::remove_file(&oldest).map_err(|source| TraceStoreError::Io {
                path: oldest.display().to_string(),
                source,
            })?;
            total = total.saturating_sub(len);
        }
        Ok(())
    }
}

impl TraceWriter for JsonlTraceWriter {
    fn span_started(&self, span: &Span) -> Result<(), TraceStoreError> {
        let record = self.sanitize_record(&TraceRecord::span(span.clone()));
        let bytes = serde_json::to_vec_pretty(&record).map_err(|source| TraceStoreError::Json {
            path: self.snapshot_path(&span.id).display().to_string(),
            source,
        })?;
        atomic_write(&self.snapshot_path(&span.id), &bytes).map_err(|source| TraceStoreError::Io {
            path: self.snapshot_path(&span.id).display().to_string(),
            source,
        })
    }

    fn span_ended(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.append_record(&TraceRecord::span(span.clone()))?;
        let snapshot = self.snapshot_path(&span.id);
        match fs::remove_file(&snapshot) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(source) => Err(TraceStoreError::Io {
                path: snapshot.display().to_string(),
                source,
            }),
        }
    }

    fn recover_in_flight(&self) -> Result<Vec<Span>, TraceStoreError> {
        if !self.current_spans_dir.exists() {
            return Ok(Vec::new());
        }
        let mut recovered = Vec::new();
        for entry in
            fs::read_dir(&self.current_spans_dir).map_err(|source| TraceStoreError::Io {
                path: self.current_spans_dir.display().to_string(),
                source,
            })?
        {
            let entry = entry.map_err(|source| TraceStoreError::Io {
                path: self.current_spans_dir.display().to_string(),
                source,
            })?;
            let path = entry.path();
            if path.extension().and_then(|ext| ext.to_str()) != Some("json") {
                continue;
            }
            let raw = fs::read_to_string(&path).map_err(|source| TraceStoreError::Io {
                path: path.display().to_string(),
                source,
            })?;
            let record: TraceRecord =
                serde_json::from_str(&raw).map_err(|source| TraceStoreError::Json {
                    path: path.display().to_string(),
                    source,
                })?;
            record.validate_schema_version()?;
            let mut span = record.span;
            let now = Utc::now();
            span.ended_at = Some(now);
            span.duration_ms = Some(duration_ms(span.started_at, now));
            span.status = SpanStatus::Error {
                message: "truncated_at_restart".into(),
            };
            span.events.push(SpanEvent {
                timestamp: now,
                name: "truncated_at_restart".into(),
                attributes: BTreeMap::new(),
            });
            sort_span_events(&mut span);
            self.span_ended(&span)?;
            recovered.push(span);
        }
        Ok(recovered)
    }
}

impl TracingHooks for JsonlTraceWriter {
    fn begin_span(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.span_started(span)
    }

    fn end_span(&self, span: &Span) -> Result<(), TraceStoreError> {
        self.span_ended(span)
    }
}

#[derive(Clone)]
pub struct ActiveTraceSpan {
    hooks: Option<Arc<dyn TracingHooks>>,
    span: Span,
    started: Instant,
}

impl ActiveTraceSpan {
    pub fn disabled(
        session_id: &str,
        trace_id: &str,
        parent_id: Option<String>,
        name: impl Into<String>,
    ) -> Self {
        Self::new(
            None,
            session_id,
            trace_id,
            parent_id,
            name,
            SpanKind::Internal,
        )
    }

    pub fn new(
        hooks: Option<Arc<dyn TracingHooks>>,
        session_id: &str,
        trace_id: &str,
        parent_id: Option<String>,
        name: impl Into<String>,
        kind: SpanKind,
    ) -> Self {
        let now = Utc::now();
        let span = Span {
            id: new_span_id(),
            parent_id,
            session_id: session_id.into(),
            trace_id: trace_id.into(),
            name: name.into(),
            kind,
            started_at: now,
            ended_at: None,
            duration_ms: None,
            status: SpanStatus::Ok,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        };
        if let Some(hooks) = hooks.as_ref() {
            if let Err(err) = hooks.begin_span(&span) {
                tracing::warn!(error = %err, span = %span.name, "failed to snapshot trace span");
            }
        }
        Self {
            hooks,
            span,
            started: Instant::now(),
        }
    }

    pub fn id(&self) -> &str {
        &self.span.id
    }

    pub fn trace_id(&self) -> &str {
        &self.span.trace_id
    }

    pub fn set_attribute(&mut self, key: impl Into<String>, value: AttributeValue) {
        self.span.attributes.insert(key.into(), value);
    }

    pub fn add_event(
        &mut self,
        name: impl Into<String>,
        attributes: BTreeMap<String, AttributeValue>,
    ) {
        self.span.events.push(SpanEvent {
            timestamp: Utc::now(),
            name: name.into(),
            attributes,
        });
    }

    pub fn finish_ok(mut self) -> Span {
        self.finish(SpanStatus::Ok)
    }

    pub fn finish_error(mut self, message: impl Into<String>) -> Span {
        self.finish(SpanStatus::Error {
            message: message.into(),
        })
    }

    fn finish(&mut self, status: SpanStatus) -> Span {
        let now = Utc::now();
        self.span.ended_at = Some(now);
        self.span.duration_ms = Some(
            self.started
                .elapsed()
                .as_millis()
                .try_into()
                .unwrap_or(u64::MAX),
        );
        self.span.status = status;
        sort_span_events(&mut self.span);
        if let Some(hooks) = self.hooks.as_ref() {
            if let Err(err) = hooks.end_span(&self.span) {
                tracing::warn!(error = %err, span = %self.span.name, "failed to persist trace span");
            }
        }
        self.span.clone()
    }
}

#[derive(Debug, Clone)]
pub struct TraceReader {
    paths: AllbertPaths,
}

impl TraceReader {
    pub fn new(paths: AllbertPaths) -> Self {
        Self { paths }
    }

    pub fn read_session(&self, session_id: &str) -> Result<TraceReadResult, TraceStoreError> {
        validate_session_id(session_id)?;
        let session_dir = self.paths.sessions.join(session_id);
        read_session_trace_dir(&session_dir)
    }

    pub fn summarize_session(
        &self,
        session_id: &str,
    ) -> Result<TraceSessionSummary, TraceStoreError> {
        let result = self.read_session(session_id)?;
        Ok(summary_for_read_result(session_id, &result))
    }

    pub fn list_sessions(&self) -> Result<Vec<TraceSessionSummary>, TraceStoreError> {
        if !self.paths.sessions.exists() {
            return Ok(Vec::new());
        }
        let mut summaries = Vec::new();
        for entry in fs::read_dir(&self.paths.sessions).map_err(|source| TraceStoreError::Io {
            path: self.paths.sessions.display().to_string(),
            source,
        })? {
            let entry = entry.map_err(|source| TraceStoreError::Io {
                path: self.paths.sessions.display().to_string(),
                source,
            })?;
            if !entry.path().is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
                continue;
            }
            let session_id = entry.file_name().to_string_lossy().to_string();
            let result = read_session_trace_dir(&entry.path())?;
            if result.spans.is_empty() && trace_artifact_count(&entry.path())? == 0 {
                continue;
            }
            summaries.push(summary_for_read_result(&session_id, &result));
        }
        summaries.sort_by(|left, right| {
            right
                .last_touched_at
                .cmp(&left.last_touched_at)
                .then_with(|| left.session_id.cmp(&right.session_id))
        });
        Ok(summaries)
    }

    pub fn latest_session_id(&self) -> Result<Option<String>, TraceStoreError> {
        Ok(self
            .list_sessions()?
            .into_iter()
            .next()
            .map(|summary| summary.session_id))
    }

    pub fn find_span(
        &self,
        session_id: Option<&str>,
        span_id: &str,
    ) -> Result<Option<Span>, TraceStoreError> {
        if let Some(session_id) = session_id {
            let result = self.read_session(session_id)?;
            return Ok(result.spans.into_iter().find(|span| span.id == span_id));
        }

        let mut found = None;
        for summary in self.list_sessions()? {
            let result = self.read_session(&summary.session_id)?;
            for span in result.spans.into_iter().filter(|span| span.id == span_id) {
                if found.is_some() {
                    return Err(TraceStoreError::InvalidPath(format!(
                        "span id `{span_id}` is not unique; retry with --session"
                    )));
                }
                found = Some(span);
            }
        }
        Ok(found)
    }
}

pub fn read_session_trace_dir(session_dir: &Path) -> Result<TraceReadResult, TraceStoreError> {
    let mut spans = Vec::new();
    let mut warnings = Vec::new();
    let mut bytes = trace_artifact_bytes(session_dir)?;
    let archives = archive_paths_for_dir(session_dir)?;
    let has_rotated_archives = !archives.is_empty();
    for archive in &archives {
        let file = File::open(archive).map_err(|source| TraceStoreError::Io {
            path: archive.display().to_string(),
            source,
        })?;
        let decoder = GzDecoder::new(file);
        read_jsonl_records(archive, BufReader::new(decoder), &mut spans, &mut warnings)?;
    }
    let active = session_dir.join(TRACE_ACTIVE_FILE);
    if active.exists() {
        let file = File::open(&active).map_err(|source| TraceStoreError::Io {
            path: active.display().to_string(),
            source,
        })?;
        read_jsonl_records(&active, BufReader::new(file), &mut spans, &mut warnings)?;
    }
    spans.sort_by(|left, right| {
        left.started_at
            .cmp(&right.started_at)
            .then_with(|| left.id.cmp(&right.id))
    });
    let truncated_count = spans
        .iter()
        .filter(|span| matches!(&span.status, SpanStatus::Error { message } if message == "truncated_at_restart"))
        .count()
        .try_into()
        .unwrap_or(u64::MAX);
    if !session_dir.exists() {
        bytes = 0;
    }
    Ok(TraceReadResult {
        spans,
        warnings,
        bytes,
        has_rotated_archives,
        truncated_count,
    })
}

pub fn trace_artifact_bytes(session_dir: &Path) -> Result<u64, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(0);
    }
    let mut total = 0u64;
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && path.file_name().and_then(|name| name.to_str()) == Some(CURRENT_SPANS_DIR)
        {
            total = total.saturating_add(dir_bytes(&path)?);
        } else if is_trace_artifact_file(&path) {
            total = total.saturating_add(
                fs::metadata(&path)
                    .map_err(|source| TraceStoreError::Io {
                        path: path.display().to_string(),
                        source,
                    })?
                    .len(),
            );
        }
    }
    Ok(total)
}

pub fn trace_artifact_count(session_dir: &Path) -> Result<usize, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && path.file_name().and_then(|name| name.to_str()) == Some(CURRENT_SPANS_DIR)
        {
            count = count.saturating_add(count_files(&path)?);
        } else if is_trace_artifact_file(&path) {
            count = count.saturating_add(1);
        }
    }
    Ok(count)
}

pub fn recover_all_in_flight_spans(
    paths: &AllbertPaths,
    limits: TraceStorageLimits,
) -> Result<usize, TraceStoreError> {
    if !paths.sessions.exists() {
        return Ok(0);
    }
    let mut recovered = 0usize;
    for entry in fs::read_dir(&paths.sessions).map_err(|source| TraceStoreError::Io {
        path: paths.sessions.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: paths.sessions.display().to_string(),
            source,
        })?;
        if !entry.path().is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = entry.file_name().to_string_lossy().to_string();
        let writer = JsonlTraceWriter::new(paths, &session_id, limits.clone())?;
        recovered = recovered.saturating_add(writer.recover_in_flight()?.len());
    }
    Ok(recovered)
}

pub fn plan_trace_gc(
    paths: &AllbertPaths,
    retention_days: u16,
    total_disk_cap_mb: u32,
) -> Result<TraceGcPlan, TraceStoreError> {
    let mut artifacts = collect_trace_artifacts(paths)?;
    artifacts.sort_by(|left, right| {
        left.modified
            .cmp(&right.modified)
            .then_with(|| left.path.cmp(&right.path))
    });
    let total_bytes = artifacts
        .iter()
        .map(|artifact| artifact.bytes)
        .fold(0u64, u64::saturating_add);
    let cap_bytes = u64::from(total_disk_cap_mb).saturating_mul(1024 * 1024);
    let retention_cutoff = SystemTime::now()
        .checked_sub(Duration::from_secs(
            u64::from(retention_days) * 24 * 60 * 60,
        ))
        .unwrap_or(SystemTime::UNIX_EPOCH);

    let mut selected = BTreeSet::new();
    for artifact in artifacts
        .iter()
        .filter(|artifact| artifact.modified < retention_cutoff)
    {
        selected.insert(artifact.path.clone());
    }

    let mut remaining_bytes = total_bytes.saturating_sub(
        artifacts
            .iter()
            .filter(|artifact| selected.contains(&artifact.path))
            .map(|artifact| artifact.bytes)
            .fold(0u64, u64::saturating_add),
    );
    if remaining_bytes > cap_bytes {
        for artifact in &artifacts {
            if selected.contains(&artifact.path) {
                continue;
            }
            selected.insert(artifact.path.clone());
            remaining_bytes = remaining_bytes.saturating_sub(artifact.bytes);
            if remaining_bytes <= cap_bytes {
                break;
            }
        }
    }

    let mut candidates = Vec::new();
    for artifact in artifacts {
        if !selected.contains(&artifact.path) {
            continue;
        }
        let reason = if artifact.modified < retention_cutoff {
            format!("older than {retention_days} day trace retention")
        } else {
            format!("total trace artifacts exceed {} MiB cap", total_disk_cap_mb)
        };
        candidates.push(TraceGcCandidate {
            session_id: artifact.session_id,
            path: artifact.path,
            bytes: artifact.bytes,
            reason,
        });
    }

    Ok(TraceGcPlan {
        total_bytes,
        cap_bytes,
        candidates,
    })
}

pub fn apply_trace_gc(plan: &TraceGcPlan) -> Result<TraceGcResult, TraceStoreError> {
    let mut result = TraceGcResult::default();
    for candidate in &plan.candidates {
        match fs::remove_file(&candidate.path) {
            Ok(()) => {
                result.removed += 1;
                result.freed_bytes = result.freed_bytes.saturating_add(candidate.bytes);
            }
            Err(source) if source.kind() == std::io::ErrorKind::NotFound => {}
            Err(source) => {
                return Err(TraceStoreError::Io {
                    path: candidate.path.display().to_string(),
                    source,
                });
            }
        }
    }
    Ok(result)
}

pub fn export_session_otlp_json(
    paths: &AllbertPaths,
    config: &TraceConfig,
    session_id: &str,
    out: Option<&Path>,
) -> Result<PathBuf, TraceStoreError> {
    validate_session_id(session_id)?;
    let reader = TraceReader::new(paths.clone());
    let result = reader.read_session(session_id)?;
    let output_path = resolve_otlp_export_path(paths, config, session_id, out)?;
    let parent = output_path.parent().ok_or_else(|| {
        TraceStoreError::InvalidPath(format!(
            "export path has no parent: {}",
            output_path.display()
        ))
    })?;
    fs::create_dir_all(parent).map_err(|source| TraceStoreError::Io {
        path: parent.display().to_string(),
        source,
    })?;
    let payload = otlp_resource_spans(config, &result.spans);
    let bytes = serde_json::to_vec_pretty(&payload).map_err(|source| TraceStoreError::Json {
        path: output_path.display().to_string(),
        source,
    })?;
    atomic_write(&output_path, &bytes).map_err(|source| TraceStoreError::Io {
        path: output_path.display().to_string(),
        source,
    })?;
    Ok(output_path)
}

pub fn sanitize_span(span: &mut Span, policy: &TraceCapturePolicy) {
    let mut replacements = Vec::new();
    let keys = span.attributes.keys().cloned().collect::<Vec<_>>();
    for key in keys {
        let Some(value) = span.attributes.remove(&key) else {
            continue;
        };
        apply_attribute_policy(&mut replacements, &key, value, policy);
    }
    span.attributes = replacements.into_iter().collect();
    for event in &mut span.events {
        let mut replacements = Vec::new();
        let keys = event.attributes.keys().cloned().collect::<Vec<_>>();
        for key in keys {
            let Some(value) = event.attributes.remove(&key) else {
                continue;
            };
            apply_attribute_policy(&mut replacements, &key, value, policy);
        }
        event.attributes = replacements.into_iter().collect();
    }
}

fn apply_attribute_policy(
    replacements: &mut Vec<(String, AttributeValue)>,
    key: &str,
    value: AttributeValue,
    policy: &TraceCapturePolicy,
) {
    let field_policy = field_policy_for_key(key, policy);
    match field_policy {
        TraceFieldPolicy::Capture => {
            replacements.push((key.to_string(), redact_attribute_value(value, policy)));
        }
        TraceFieldPolicy::Summary => {
            replacements.push((key.to_string(), summarize_attribute_value(value, policy)));
        }
        TraceFieldPolicy::Drop => {
            replacements.push((format!("{key}_dropped"), AttributeValue::Bool(true)));
        }
    }
}

fn field_policy_for_key(key: &str, policy: &TraceCapturePolicy) -> TraceFieldPolicy {
    if key == "allbert.tool.args" || key.ends_with(".tool.args") {
        policy.tool_args
    } else if key == "allbert.tool.result" || key.ends_with(".tool.result") {
        policy.tool_results
    } else if is_provider_payload_key(key) {
        policy.provider_payloads
    } else {
        TraceFieldPolicy::Capture
    }
}

fn is_provider_payload_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    key.contains("provider_payload")
        || key.contains("prompt")
        || key.contains("response")
        || key.contains("request.body")
        || key.contains("response.body")
}

fn redact_attribute_value(value: AttributeValue, policy: &TraceCapturePolicy) -> AttributeValue {
    match value {
        AttributeValue::String(value) => AttributeValue::String(policy.redactor.redact(&value)),
        AttributeValue::StringArray(values) => AttributeValue::StringArray(
            values
                .into_iter()
                .map(|value| policy.redactor.redact(&value))
                .collect(),
        ),
        other => other,
    }
}

fn summarize_attribute_value(value: AttributeValue, policy: &TraceCapturePolicy) -> AttributeValue {
    match value {
        AttributeValue::String(value) => {
            let redacted = policy.redactor.redact(&value);
            AttributeValue::String(summary_for_text(&redacted))
        }
        AttributeValue::StringArray(values) => {
            let joined = values
                .into_iter()
                .map(|value| policy.redactor.redact(&value))
                .collect::<Vec<_>>()
                .join("\n");
            AttributeValue::String(summary_for_text(&joined))
        }
        other => other,
    }
}

fn summary_for_text(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    let digest = hasher.finalize();
    format!(
        "<summary bytes={} chars={} sha256={:x}>",
        value.len(),
        value.chars().count(),
        digest
    )
}

struct TraceArtifact {
    session_id: String,
    path: PathBuf,
    bytes: u64,
    modified: SystemTime,
}

fn collect_trace_artifacts(paths: &AllbertPaths) -> Result<Vec<TraceArtifact>, TraceStoreError> {
    if !paths.sessions.exists() {
        return Ok(Vec::new());
    }
    let mut artifacts = Vec::new();
    for entry in fs::read_dir(&paths.sessions).map_err(|source| TraceStoreError::Io {
        path: paths.sessions.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: paths.sessions.display().to_string(),
            source,
        })?;
        if !entry.path().is_dir() || entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        let session_id = entry.file_name().to_string_lossy().to_string();
        collect_trace_artifacts_for_session(&entry.path(), &session_id, &mut artifacts)?;
    }
    Ok(artifacts)
}

fn collect_trace_artifacts_for_session(
    session_dir: &Path,
    session_id: &str,
    artifacts: &mut Vec<TraceArtifact>,
) -> Result<(), TraceStoreError> {
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir()
            && path.file_name().and_then(|name| name.to_str()) == Some(CURRENT_SPANS_DIR)
        {
            collect_trace_snapshot_artifacts(&path, session_id, artifacts)?;
            continue;
        }
        if !is_trace_artifact_file(&path) {
            continue;
        }
        let metadata = fs::metadata(&path).map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        artifacts.push(TraceArtifact {
            session_id: session_id.to_string(),
            path,
            bytes: metadata.len(),
            modified: metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
        });
    }
    Ok(())
}

fn collect_trace_snapshot_artifacts(
    dir: &Path,
    session_id: &str,
    artifacts: &mut Vec<TraceArtifact>,
) -> Result<(), TraceStoreError> {
    if !dir.exists() {
        return Ok(());
    }
    for entry in fs::read_dir(dir).map_err(|source| TraceStoreError::Io {
        path: dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir() {
            collect_trace_snapshot_artifacts(&path, session_id, artifacts)?;
            continue;
        }
        let metadata = fs::metadata(&path).map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        artifacts.push(TraceArtifact {
            session_id: session_id.to_string(),
            path,
            bytes: metadata.len(),
            modified: metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH),
        });
    }
    Ok(())
}

fn resolve_otlp_export_path(
    paths: &AllbertPaths,
    config: &TraceConfig,
    session_id: &str,
    out: Option<&Path>,
) -> Result<PathBuf, TraceStoreError> {
    let path = match out {
        Some(path) if path.is_absolute() => path.to_path_buf(),
        Some(path) => paths.root.join(path),
        None => {
            let dir = if config.otel_export_dir.trim().is_empty() {
                PathBuf::from("exports").join("traces")
            } else {
                PathBuf::from(config.otel_export_dir.trim())
            };
            paths.root.join(dir).join(format!("{session_id}.otlp.json"))
        }
    };
    ensure_under_allbert_home(paths, &path)?;
    Ok(path)
}

fn ensure_under_allbert_home(paths: &AllbertPaths, path: &Path) -> Result<(), TraceStoreError> {
    if path.components().any(|component| {
        matches!(
            component,
            std::path::Component::ParentDir | std::path::Component::Prefix(_)
        )
    }) {
        return Err(TraceStoreError::InvalidPath(format!(
            "trace export path must stay inside ALLBERT_HOME: {}",
            path.display()
        )));
    }
    if !path.starts_with(&paths.root) {
        return Err(TraceStoreError::InvalidPath(format!(
            "trace export path must stay inside ALLBERT_HOME: {}",
            path.display()
        )));
    }
    Ok(())
}

fn otlp_resource_spans(config: &TraceConfig, spans: &[Span]) -> Value {
    json!({
        "resourceSpans": [{
            "resource": {
                "attributes": [
                    otlp_attribute("service.name", json!({ "stringValue": config.otel_service_name.as_str() })),
                    otlp_attribute("allbert.trace.schema_version", json!({ "intValue": TRACE_RECORD_SCHEMA_VERSION.to_string() }))
                ]
            },
            "scopeSpans": [{
                "scope": {
                    "name": "allbert",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "spans": spans.iter().map(otlp_span).collect::<Vec<_>>()
            }]
        }]
    })
}

fn otlp_span(span: &Span) -> Value {
    let status = match &span.status {
        SpanStatus::Ok => json!({ "code": "STATUS_CODE_OK" }),
        SpanStatus::Error { message } => {
            json!({ "code": "STATUS_CODE_ERROR", "message": message })
        }
    };
    let mut attributes = span
        .attributes
        .iter()
        .map(|(key, value)| otlp_attribute(key, otlp_any_value(value)))
        .collect::<Vec<_>>();
    attributes.push(otlp_attribute(
        "allbert.session.id",
        json!({ "stringValue": span.session_id }),
    ));
    json!({
        "traceId": span.trace_id,
        "spanId": span.id,
        "parentSpanId": span.parent_id,
        "name": span.name,
        "kind": otlp_span_kind(span.kind),
        "startTimeUnixNano": timestamp_nanos(span.started_at),
        "endTimeUnixNano": span.ended_at.map(timestamp_nanos),
        "attributes": attributes,
        "events": span.events.iter().map(otlp_event).collect::<Vec<_>>(),
        "status": status
    })
}

fn otlp_event(event: &SpanEvent) -> Value {
    json!({
        "timeUnixNano": timestamp_nanos(event.timestamp),
        "name": event.name,
        "attributes": event
            .attributes
            .iter()
            .map(|(key, value)| otlp_attribute(key, otlp_any_value(value)))
            .collect::<Vec<_>>()
    })
}

fn otlp_attribute(key: &str, value: Value) -> Value {
    json!({ "key": key, "value": value })
}

fn otlp_any_value(value: &AttributeValue) -> Value {
    match value {
        AttributeValue::String(value) => json!({ "stringValue": value }),
        AttributeValue::Int(value) => json!({ "intValue": value.to_string() }),
        AttributeValue::Float(value) => json!({ "doubleValue": value }),
        AttributeValue::Bool(value) => json!({ "boolValue": value }),
        AttributeValue::StringArray(values) => json!({
            "arrayValue": {
                "values": values.iter().map(|value| json!({ "stringValue": value })).collect::<Vec<_>>()
            }
        }),
        AttributeValue::IntArray(values) => json!({
            "arrayValue": {
                "values": values.iter().map(|value| json!({ "intValue": value.to_string() })).collect::<Vec<_>>()
            }
        }),
    }
}

fn otlp_span_kind(kind: SpanKind) -> &'static str {
    match kind {
        SpanKind::Internal => "SPAN_KIND_INTERNAL",
        SpanKind::Client => "SPAN_KIND_CLIENT",
        SpanKind::Server => "SPAN_KIND_SERVER",
        SpanKind::Producer => "SPAN_KIND_PRODUCER",
        SpanKind::Consumer => "SPAN_KIND_CONSUMER",
    }
}

fn timestamp_nanos(timestamp: DateTime<Utc>) -> String {
    let seconds = timestamp.timestamp();
    let nanos = timestamp.timestamp_subsec_nanos();
    ((i128::from(seconds) * 1_000_000_000) + i128::from(nanos)).to_string()
}

pub fn new_trace_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

pub fn new_span_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()[..16].to_string()
}

pub fn sort_span_events(span: &mut Span) {
    span.events.sort_by(|left, right| {
        left.timestamp
            .cmp(&right.timestamp)
            .then_with(|| left.name.cmp(&right.name))
    });
}

fn summary_for_read_result(session_id: &str, result: &TraceReadResult) -> TraceSessionSummary {
    let started_at = result
        .spans
        .first()
        .map(|span| span.started_at)
        .unwrap_or_else(Utc::now);
    let last_touched_at = result
        .spans
        .iter()
        .filter_map(|span| span.ended_at.or(Some(span.started_at)))
        .max()
        .unwrap_or(started_at);
    let total_duration_ms = result
        .spans
        .iter()
        .filter(|span| span.parent_id.is_none())
        .filter_map(|span| span.duration_ms)
        .sum();
    TraceSessionSummary {
        session_id: session_id.into(),
        span_count: result.spans.len().try_into().unwrap_or(u64::MAX),
        root_span_count: result
            .spans
            .iter()
            .filter(|span| span.parent_id.is_none())
            .count()
            .try_into()
            .unwrap_or(u64::MAX),
        started_at,
        last_touched_at,
        total_duration_ms,
        bytes: result.bytes,
        has_rotated_archives: result.has_rotated_archives,
        truncated_count: result.truncated_count,
    }
}

fn read_jsonl_records<R: BufRead>(
    path: &Path,
    reader: R,
    spans: &mut Vec<Span>,
    warnings: &mut Vec<TraceReadWarning>,
) -> Result<(), TraceStoreError> {
    for (index, line) in reader.lines().enumerate() {
        let line_no = index + 1;
        let line = line.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<TraceRecord>(&line) {
            Ok(record) => {
                record.validate_schema_version()?;
                spans.push(record.span);
            }
            Err(source) => warnings.push(TraceReadWarning {
                path: path.to_path_buf(),
                line: line_no,
                message: source.to_string(),
            }),
        }
    }
    Ok(())
}

fn archive_paths_for_dir(session_dir: &Path) -> Result<Vec<PathBuf>, TraceStoreError> {
    if !session_dir.exists() {
        return Ok(Vec::new());
    }
    let mut archives = Vec::new();
    for entry in fs::read_dir(session_dir).map_err(|source| TraceStoreError::Io {
        path: session_dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: session_dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if archive_index(&path).is_some() {
            archives.push(path);
        }
    }
    archives.sort_by_key(|path| archive_index(path).unwrap_or(0));
    Ok(archives)
}

fn archive_index(path: &Path) -> Option<u64> {
    let name = path.file_name()?.to_str()?;
    let index = name.strip_prefix("trace.")?.strip_suffix(".jsonl.gz")?;
    index.parse::<u64>().ok()
}

fn is_trace_artifact_file(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == TRACE_ACTIVE_FILE || archive_index(path).is_some())
}

fn count_files(path: &Path) -> Result<usize, TraceStoreError> {
    if !path.exists() {
        return Ok(0);
    }
    let mut count = 0usize;
    for entry in fs::read_dir(path).map_err(|source| TraceStoreError::Io {
        path: path.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        if entry.path().is_dir() {
            count = count.saturating_add(count_files(&entry.path())?);
        } else {
            count = count.saturating_add(1);
        }
    }
    Ok(count)
}

fn dir_bytes(path: &Path) -> Result<u64, TraceStoreError> {
    if !path.exists() {
        return Ok(0);
    }
    let mut total = 0u64;
    for entry in fs::read_dir(path).map_err(|source| TraceStoreError::Io {
        path: path.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir() {
            total = total.saturating_add(dir_bytes(&path)?);
        } else {
            total = total.saturating_add(
                fs::metadata(&path)
                    .map_err(|source| TraceStoreError::Io {
                        path: path.display().to_string(),
                        source,
                    })?
                    .len(),
            );
        }
    }
    Ok(total)
}

fn validate_session_id(session_id: &str) -> Result<(), TraceStoreError> {
    if session_id.is_empty()
        || session_id.contains('/')
        || session_id.contains('\\')
        || session_id == "."
        || session_id == ".."
    {
        return Err(TraceStoreError::InvalidPath(format!(
            "invalid session id `{session_id}`"
        )));
    }
    Ok(())
}

fn duration_ms(started_at: DateTime<Utc>, ended_at: DateTime<Utc>) -> u64 {
    (ended_at - started_at)
        .num_milliseconds()
        .max(0)
        .try_into()
        .unwrap_or(u64::MAX)
}

#[cfg(test)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct RedactionLeak {
    path: PathBuf,
    line: usize,
}

#[cfg(test)]
#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct RedactionVerificationReport {
    scanned_files: usize,
    leaks: Vec<RedactionLeak>,
}

#[cfg(test)]
fn verify_trace_redaction_artifacts(
    paths: &AllbertPaths,
) -> Result<RedactionVerificationReport, TraceStoreError> {
    let mut report = RedactionVerificationReport::default();
    if !paths.sessions.exists() {
        return Ok(report);
    }
    let redactor = DefaultSecretRedactor::new();
    scan_trace_redaction_dir(&paths.sessions, &redactor, &mut report)?;
    Ok(report)
}

#[cfg(test)]
fn scan_trace_redaction_dir(
    dir: &Path,
    redactor: &DefaultSecretRedactor,
    report: &mut RedactionVerificationReport,
) -> Result<(), TraceStoreError> {
    for entry in fs::read_dir(dir).map_err(|source| TraceStoreError::Io {
        path: dir.display().to_string(),
        source,
    })? {
        let entry = entry.map_err(|source| TraceStoreError::Io {
            path: dir.display().to_string(),
            source,
        })?;
        let path = entry.path();
        if path.is_dir() {
            scan_trace_redaction_dir(&path, redactor, report)?;
        } else if is_redaction_verification_trace_artifact(&path) {
            scan_trace_redaction_file(&path, redactor, report)?;
        }
    }
    Ok(())
}

#[cfg(test)]
fn scan_trace_redaction_file(
    path: &Path,
    redactor: &DefaultSecretRedactor,
    report: &mut RedactionVerificationReport,
) -> Result<(), TraceStoreError> {
    report.scanned_files += 1;
    if path.extension().is_some_and(|extension| extension == "gz") {
        let file = File::open(path).map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        let reader = BufReader::new(GzDecoder::new(file));
        scan_trace_redaction_lines(path, reader, redactor, report)
    } else {
        let file = File::open(path).map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        scan_trace_redaction_lines(path, BufReader::new(file), redactor, report)
    }
}

#[cfg(test)]
fn scan_trace_redaction_lines<R: BufRead>(
    path: &Path,
    reader: R,
    redactor: &DefaultSecretRedactor,
    report: &mut RedactionVerificationReport,
) -> Result<(), TraceStoreError> {
    for (index, line) in reader.lines().enumerate() {
        let line = line.map_err(|source| TraceStoreError::Io {
            path: path.display().to_string(),
            source,
        })?;
        if redactor.contains_secret(&line) {
            report.leaks.push(RedactionLeak {
                path: path.to_path_buf(),
                line: index + 1,
            });
        }
    }
    Ok(())
}

#[cfg(test)]
fn is_redaction_verification_trace_artifact(path: &Path) -> bool {
    if is_trace_artifact_file(path) {
        return true;
    }
    path.extension()
        .is_some_and(|extension| extension == "json")
        && path
            .parent()
            .and_then(Path::file_name)
            .is_some_and(|name| name == CURRENT_SPANS_DIR)
}

#[cfg(test)]
mod tests {
    use super::*;
    use allbert_proto::{is_valid_otlp_span_id, is_valid_otlp_trace_id};

    fn ts(seconds: i64) -> DateTime<Utc> {
        DateTime::from_timestamp(seconds, 0).expect("fixture timestamp should be valid")
    }

    fn fixture_span(id: &str, parent_id: Option<&str>, started_at: DateTime<Utc>) -> Span {
        Span {
            id: id.into(),
            parent_id: parent_id.map(str::to_string),
            session_id: "session-a".into(),
            trace_id: "33333333333333333333333333333333".into(),
            name: "turn".into(),
            kind: SpanKind::Internal,
            started_at,
            ended_at: Some(started_at),
            duration_ms: Some(1),
            status: SpanStatus::Ok,
            attributes: BTreeMap::new(),
            events: Vec::new(),
        }
    }

    fn secret_fixture(prefix: &str, body: &str) -> String {
        format!("{prefix}{body}")
    }

    fn secret_fixture_parts(prefix_a: &str, prefix_b: &str, body: &str) -> String {
        format!("{prefix_a}{prefix_b}{body}")
    }

    fn secret_fixtures() -> Vec<String> {
        vec![
            secret_fixture("AKIA", "1234567890ABCDEF"),
            secret_fixture("ASIA", "1234567890ABCDEF"),
            secret_fixture_parts("sk", "-proj-", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture_parts("sk", "-ant-api03-", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture_parts("sk", "-or-v1-", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture_parts(
                "xo",
                "xb-123456789012-123456789012-",
                "abcdefghijklmnopqrstuvwx",
            ),
            secret_fixture_parts("gh", "p_", "abcdefghijklmnopqrstuvwxyz1234567890AB"),
            secret_fixture_parts(
                "github",
                "_pat_11ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij_",
                "22ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij",
            ),
            secret_fixture_parts("gl", "pat-", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture_parts("AI", "zaSy", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"),
            secret_fixture_parts("ya", "29.", "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"),
            secret_fixture_parts("h", "f_", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture_parts("sk", "_live_", "abcdefghijklmnopqrstuvwxyz123456"),
            secret_fixture("api_key=", "abcdefghijklmnopqrstuvwxyz1234567890"),
            secret_fixture(
                "Authorization: Bearer ",
                "abcdefghijklmnopqrstuvwxyz1234567890",
            ),
            secret_fixture(
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.",
                "eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnopqrstuvwxyz1234567890",
            ),
        ]
    }

    #[test]
    fn trace_record_roundtrips_schema_version() {
        let span = fixture_span("1111111111111111", None, ts(1));
        let record = TraceRecord::span(span.clone());
        let raw = serde_json::to_string(&record).expect("record serializes");
        let decoded: TraceRecord = serde_json::from_str(&raw).expect("record deserializes");
        decoded
            .validate_schema_version()
            .expect("schema version is supported");
        assert_eq!(decoded.span, span);
    }

    #[test]
    fn trace_record_rejects_future_schema_version() {
        let mut record = TraceRecord::span(fixture_span("1111111111111111", None, ts(1)));
        record.schema_version = TRACE_RECORD_SCHEMA_VERSION + 1;
        let err = record
            .validate_schema_version()
            .expect_err("future schema should reject");
        assert!(err.to_string().contains("unsupported trace schema version"));
    }

    #[test]
    fn trace_ids_are_otlp_compatible_lower_hex() {
        assert!(is_valid_otlp_trace_id(&new_trace_id()));
        assert!(is_valid_otlp_span_id(&new_span_id()));
    }

    #[test]
    fn span_events_sort_by_timestamp() {
        let mut span = fixture_span("1111111111111111", None, ts(3));
        span.events = vec![
            SpanEvent {
                timestamp: ts(3),
                name: "third".into(),
                attributes: BTreeMap::new(),
            },
            SpanEvent {
                timestamp: ts(1),
                name: "first".into(),
                attributes: BTreeMap::new(),
            },
            SpanEvent {
                timestamp: ts(2),
                name: "second".into(),
                attributes: BTreeMap::new(),
            },
        ];
        sort_span_events(&mut span);
        assert_eq!(
            span.events
                .iter()
                .map(|event| event.name.as_str())
                .collect::<Vec<_>>(),
            vec!["first", "second", "third"]
        );
    }

    #[test]
    fn jsonl_writer_snapshots_appends_and_recovers_in_flight_spans() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.ended_at = None;
        span.duration_ms = None;
        writer.span_started(&span).expect("snapshot start");
        assert!(writer.snapshot_path(&span.id).exists());
        span.ended_at = Some(ts(2));
        span.duration_ms = Some(1000);
        writer.span_ended(&span).expect("span end");
        assert!(!writer.snapshot_path(&span.id).exists());

        let mut stale = fixture_span("2222222222222222", None, ts(3));
        stale.ended_at = None;
        stale.duration_ms = None;
        writer.span_started(&stale).expect("snapshot stale");
        let recovered = writer.recover_in_flight().expect("recover stale");
        assert_eq!(recovered.len(), 1);
        assert!(matches!(
            recovered[0].status,
            SpanStatus::Error { ref message } if message == "truncated_at_restart"
        ));

        let read = read_session_trace_dir(&paths.sessions.join("session-a")).expect("read traces");
        assert_eq!(read.spans.len(), 2);
        assert_eq!(read.truncated_count, 1);
    }

    #[test]
    fn rotation_and_reader_include_archives_in_order() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits {
                session_disk_cap_bytes: 1024,
            },
        )
        .expect("writer");
        let mut first = fixture_span("2222222222222222", None, ts(2));
        first
            .attributes
            .insert("payload".into(), AttributeValue::String("x".repeat(4096)));
        let mut second = fixture_span("1111111111111111", None, ts(1));
        second
            .attributes
            .insert("payload".into(), AttributeValue::String("y".repeat(4096)));
        writer.span_ended(&first).expect("first span");
        writer.span_ended(&second).expect("second span");

        let read = read_session_trace_dir(&paths.sessions.join("session-a")).expect("read traces");
        assert!(read.has_rotated_archives);
        assert_eq!(
            read.spans
                .iter()
                .map(|span| span.id.as_str())
                .collect::<Vec<_>>(),
            vec!["1111111111111111", "2222222222222222"]
        );
    }

    #[test]
    fn reader_skips_malformed_jsonl_with_warning() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        let good = serde_json::to_string(&TraceRecord::span(fixture_span(
            "1111111111111111",
            None,
            ts(1),
        )))
        .expect("good record");
        fs::write(
            session_dir.join(TRACE_ACTIVE_FILE),
            format!("{good}\n{{broken\n"),
        )
        .expect("trace write");

        let read = read_session_trace_dir(&session_dir).expect("read traces");
        assert_eq!(read.spans.len(), 1);
        assert_eq!(read.warnings.len(), 1);
    }

    #[test]
    fn redaction_removes_common_secret_patterns_before_write() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.attributes.insert(
            "allbert.tool.args".into(),
            AttributeValue::String(format!("call with {}", secret_fixtures().join(" and "))),
        );
        writer.span_ended(&span).expect("span end");

        let raw = fs::read_to_string(paths.sessions.join("session-a").join(TRACE_ACTIVE_FILE))
            .expect("trace reads");
        for secret in secret_fixtures() {
            assert!(
                !raw.contains(secret.as_str()),
                "trace artifact leaked fixture secret {secret}"
            );
        }
        assert!(raw.contains("<redacted:secret>"));
    }

    #[test]
    fn redaction_pattern_coverage_handles_middle_of_larger_strings() {
        let redactor = DefaultSecretRedactor::new();
        for secret in secret_fixtures() {
            let input = format!("prefix-{secret}-suffix");
            let redacted = redactor.redact(&input);
            assert!(
                !redacted.contains(secret.as_str()),
                "secret fixture was not redacted: {secret}"
            );
            assert!(redacted.contains("<redacted:secret>"));
        }
    }

    #[test]
    fn redaction_verification_harness_reports_no_leaks_after_write() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.attributes.insert(
            "allbert.provider_payload.prompt".into(),
            AttributeValue::String(format!("prompt {}", secret_fixtures().join("\n"))),
        );
        span.events.push(SpanEvent {
            name: "tool".into(),
            timestamp: ts(1),
            attributes: BTreeMap::from([(
                "allbert.tool.result".into(),
                AttributeValue::String(secret_fixture_parts(
                    "OPENROUTER_API_KEY=sk",
                    "-or-v1-",
                    "abcdefghijklmnopqrstuvwxyz123456",
                )),
            )]),
        });
        writer.span_started(&span).expect("span start");
        writer.span_ended(&span).expect("span end");

        let report = verify_trace_redaction_artifacts(&paths).expect("redaction verification");
        assert!(report.scanned_files >= 1);
        assert_eq!(report.leaks, Vec::<RedactionLeak>::new());
    }

    #[test]
    fn redaction_verification_harness_reports_fixture_leaks() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        fs::write(
            session_dir.join(TRACE_ACTIVE_FILE),
            format!(
                "unredacted {}\n",
                secret_fixture_parts("gh", "p_", "abcdefghijklmnopqrstuvwxyz1234567890AB")
            ),
        )
        .expect("fixture trace write");

        let report = verify_trace_redaction_artifacts(&paths).expect("redaction verification");
        assert_eq!(report.scanned_files, 1);
        assert_eq!(report.leaks.len(), 1);
        assert_eq!(report.leaks[0].line, 1);
    }

    #[test]
    fn secret_redaction_cannot_be_disabled_by_trace_config() {
        let mut config = TraceConfig::default();
        config.redaction.secrets = "never".into();
        let policy = TraceCapturePolicy::from(config);
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.attributes.insert(
            "allbert.tool.args".into(),
            AttributeValue::String(secret_fixture_parts(
                "OPENAI_API_KEY=sk",
                "-proj-",
                "abcdefghijklmnopqrstuvwxyz123456",
            )),
        );

        sanitize_span(&mut span, &policy);

        let rendered = serde_json::to_string(&span).expect("span should serialize");
        assert!(!rendered.contains(&secret_fixture_parts(
            "sk",
            "-proj-",
            "abcdefghijklmnopqrstuvwxyz123456"
        )));
        assert!(rendered.contains("<redacted:secret>"));
    }

    #[test]
    fn capture_policy_summary_and_drop_apply_per_field() {
        let mut span = fixture_span("1111111111111111", None, ts(1));
        span.attributes.insert(
            "allbert.tool.args".into(),
            AttributeValue::String("very sensitive args".into()),
        );
        span.attributes.insert(
            "allbert.tool.result".into(),
            AttributeValue::String("very sensitive result".into()),
        );
        span.attributes.insert(
            "allbert.provider_payload.prompt".into(),
            AttributeValue::String("prompt text".into()),
        );
        let policy = TraceCapturePolicy {
            tool_args: TraceFieldPolicy::Summary,
            tool_results: TraceFieldPolicy::Drop,
            provider_payloads: TraceFieldPolicy::Summary,
            redactor: Arc::new(DefaultSecretRedactor::new()),
        };
        sanitize_span(&mut span, &policy);

        assert!(matches!(
            span.attributes.get("allbert.tool.args"),
            Some(AttributeValue::String(value)) if value.starts_with("<summary bytes=")
        ));
        assert_eq!(
            span.attributes.get("allbert.tool.result_dropped"),
            Some(&AttributeValue::Bool(true))
        );
        assert!(matches!(
            span.attributes.get("allbert.provider_payload.prompt"),
            Some(AttributeValue::String(value)) if value.starts_with("<summary bytes=")
        ));
        assert!(!span.attributes.contains_key("allbert.tool.result"));
    }

    #[test]
    fn trace_reader_lists_sessions_and_otlp_export_stays_under_home() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        writer
            .span_ended(&fixture_span("1111111111111111", None, ts(1)))
            .expect("span end");

        let reader = TraceReader::new(paths.clone());
        let sessions = reader.list_sessions().expect("sessions");
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].session_id, "session-a");

        let output = export_session_otlp_json(&paths, &TraceConfig::default(), "session-a", None)
            .expect("export");
        assert!(output.starts_with(&paths.root));
        let raw = fs::read_to_string(output).expect("export reads");
        assert!(raw.contains("\"resourceSpans\""));
        assert!(raw.contains("\"traceId\""));

        let escaped = export_session_otlp_json(
            &paths,
            &TraceConfig::default(),
            "session-a",
            Some(Path::new("../trace.json")),
        );
        assert!(matches!(escaped, Err(TraceStoreError::InvalidPath(_))));
    }

    #[test]
    fn trace_gc_plans_only_trace_artifacts() {
        let temp = tempfile::tempdir().expect("tempdir");
        let paths = AllbertPaths::under(temp.path().join(".allbert"));
        paths.ensure().expect("paths ensure");
        let session_dir = paths.sessions.join("session-a");
        fs::create_dir_all(&session_dir).expect("session dir");
        fs::write(session_dir.join("turns.md"), "do not remove").expect("turns write");
        let writer = JsonlTraceWriter::new(
            &paths,
            "session-a",
            TraceStorageLimits::from_session_cap_mb(5),
        )
        .expect("writer");
        writer
            .span_ended(&fixture_span("1111111111111111", None, ts(1)))
            .expect("span end");

        let plan = plan_trace_gc(&paths, 365, 0).expect("gc plan");
        assert_eq!(plan.candidates.len(), 1);
        assert!(plan.candidates[0].path.ends_with(TRACE_ACTIVE_FILE));
        let result = apply_trace_gc(&plan).expect("gc apply");
        assert_eq!(result.removed, 1);
        assert!(session_dir.join("turns.md").exists());
    }
}
